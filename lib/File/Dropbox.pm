package File::Dropbox 0.1;
use strict;
use warnings;
use feature ':5.10';
use base qw{ Tie::Handle Exporter };
use Symbol;
use JSON;
use WWW::Curl::Easy;
use Errno qw{ ENOENT EISDIR EINVAL EPERM EACCES };
use Fcntl qw{ SEEK_CUR SEEK_SET SEEK_END };
our @EXPORT_OK = qw{ contents putfile metadata };

my $hosts = {
	content => 'api-content.dropbox.com',
	api     => 'api.dropbox.com',
};

my $header = <<'';
Authorization: OAuth oauth_version="1.0", oauth_signature_method="PLAINTEXT", oauth_consumer_key="%s", oauth_token="%s", oauth_signature="%s&%s"

chomp $header;

sub new {
	my $self = Symbol::gensym;
	tie *$self, __PACKAGE__, my $this = { @_[1 .. @_ - 1] };

	*$self = $this;

	return $self;
} # new

sub TIEHANDLE {
	my $self = bless $_[1], ref $_[0] || $_[0];

	$self->{'version'} //= 1;
	$self->{'chunk'}   //= 4 << 20;
	$self->{'root'}    //= 'sandbox';

	unless ($self->{'curl'}) {
		my $curl = $self->{'curl'} = WWW::Curl::Easy->new();

		$curl->setopt(CURLOPT_PROTOCOLS,       CURLPROTO_HTTPS);
		$curl->setopt(CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTPS);
	}

	$self->{'closed'}   = 1;
	$self->{'length'}   = 0;
	$self->{'position'} = 0;
	$self->{'mode'}     = '';
	$self->{'buffer'}   = '';

	return $self;
} # TIEHANDLE

sub READ {
	my ($self, undef, $length, $offset) = @_;
	my ($url, $curl);

	die 'Read is not supported on this handle'
		if $self->{'mode'} ne '<';

	return 0
		if $self->EOF();

	$curl = $self->{'curl'};

	$url  = 'https://';
	$url .= join '/', $hosts->{'content'}, $self->{'version'};
	$url .= join '/', '/files', $self->{'root'}, $self->{'path'};

	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_VERBOSE, $self->{'debug'}? 1 : 0);
	$curl->setopt(CURLOPT_HTTPGET, 1);
	$curl->setopt(CURLOPT_HTTPHEADER, [&__header__]);
	$curl->setopt(CURLOPT_WRITEDATA, \(my $response));
	$curl->setopt(CURLOPT_WRITEHEADER, \(my $headers));
	$curl->setopt(CURLOPT_RANGE, join '-', $self->{'position'}, $self->{'position'} + ($length || 1));

	my $code = $curl->perform();

	die join ' ', $curl->strerror($code), $curl->errbuf()
		unless $code == 0;

	$code = $curl->getinfo(CURLINFO_HTTP_CODE);

	die join ' ', $code, $response
		unless $code == 206;

	my %headers = map {
		my ($header, $value) = split m{: *}, $_, 2;
		lc $header => $value
	} split m{\r\n}, $headers;

	my $meta  = from_json($headers{'x-dropbox-metadata'});
	my $bytes = length $response;

	$self->{'position'} += $bytes > $length? $length : $bytes;

	substr($_[1] //= '', $offset // 0) = substr $response, 0, $length;

	return $bytes;
} # READ

sub READLINE {
	my ($self) = @_;
	my $length;

	die 'Readline is not supported on this handle'
		if $self->{'mode'} ne '<';

	if ($self->EOF()) {
		return if wantarray;

		# Special case: slurp mode + scalar context + empty file
		# return '' for first call and undef for subsequent
		return ''
			unless $self->{'eof'} or defined $/;

		$self->{'eof'} = 1;
		return undef;
	}

	{
		$length = length $self->{'buffer'};

		if (not wantarray and $length and defined $/) {
			my $position = index $self->{'buffer'}, $/;

			if (~$position) {
				$self->{'position'} += ($position += length $/);
				return substr $self->{'buffer'}, 0, $position, '';
			}
		}

		local $self->{'position'} = $self->{'position'} + $length;

		my $bytes = $self->READ($self->{'buffer'}, $self->{'chunk'}, $length);
		redo if not $length or $bytes;
	}

	$length = length $self->{'buffer'};

	if ($length) {
		# Multiline
		if (wantarray and defined $/) {
			$self->{'position'} += $length;

			my ($position, $length) = (0, length $/);
			my @lines;

			foreach ($self->{'buffer'}) {
				while (~(my $offset = index $_, $/, $position)) {
					$offset += $length;
					push @lines, substr $_, $position, $offset - $position;
					$position = $offset;
				}

				push @lines, substr $_, $position
					if $position < length;

				$_ = '';
			}

			return @lines;
		}

		# Slurp or last chunk
		$self->{'position'} += $length;
		return substr $self->{'buffer'}, 0, $length, '';
	}

	return undef;
} # READLINE

sub SEEK {
	my ($self, $position, $whence) = @_;

	die 'Seek is not supported on this handle'
		if $self->{'mode'} ne '<';

	$self->{'buffer'} = '';

	delete $self->{'eof'};

	given ($whence) {
		$self->{'position'} = $position
			when SEEK_SET;

		$self->{'position'} += $position
			when SEEK_CUR;

		$self->{'position'} = $self->{'length'} + $position
			when SEEK_END;

		default {
			$! = EINVAL;
			return 0;
		}
	}

	$self->{'position'} = 0
		if $self->{'position'} < 0;

	return 1;
} # SEEK

sub TELL {
	my ($self) = @_;

	die 'Tell is not supported on this handle'
		if $self->{'mode'} ne '<';

	return $self->{'position'};
} # TELL

sub WRITE {
	my ($self, $buffer, $length, $offset) = @_;

	die 'Write is not supported on this handle'
		if $self->{'mode'} ne '>';

	die 'Append-only writes supported'
		if $offset and $offset != $self->{'offset'} + $self->{'length'};

	$self->{'offset'} //= $offset;
	$self->{'buffer'}  .= $buffer;
	$self->{'length'}  += $length;

	$self->__flush__()
		while $self->{'length'} >= $self->{'chunk'};

	return 1;
} # WRITE

sub CLOSE {
	my ($self) = @_;
	undef $!;

	return 1
		if $self->{'closed'};

	my $mode = $self->{'mode'};

	if ($mode eq '>') {
		if ($self->{'length'} or not $self->{'upload_id'}) {
			do {
				$self->__flush__()
			} while length $self->{'buffer'};
		}
	}

	$self->{'closed'} = 1;
	$self->{'mode'}   = '';

	return $self->__flush__()
		if $mode eq '>';

	return 1;
} # CLOSE

sub OPEN {
	my ($self, $mode, $file) = @_;
	undef $!;

	($mode, $file) = $mode =~ m{^([<>]?)(.*)$}s
		unless $file;

	given ($mode ||= '<') {
		1 when '>';
		1 when '<';

		$mode = '<' when 'r';
		$mode = '>' when 'a';
		$mode = '>' when 'w';

		default {
			die 'Unsupported mode';
		}
	}

	$self->CLOSE()
		unless $self->{'closed'};

	$self->{'length'} = 0;
	$self->{'buffer'} = '';

	delete $self->{'offset'};
	delete $self->{'revision'};
	delete $self->{'upload_id'};
	delete $self->{'meta'};
	delete $self->{'hash'};
	delete $self->{'eof'};

	$self->{'path'} = $file
		or die 'Path required';

	return 0
		if $mode eq '<' and not $self->__meta__();

	$self->{'mode'}   = $mode;
	$self->{'closed'} = 0;

	return 1;
} # OPEN

sub EOF {
	my ($self) = @_;

	die 'Eof is not supported on this handle'
		if $self->{'mode'} ne '<';

	return $self->{'position'} >= $self->{'length'};
} # EOF

sub BINMODE { 1 }

sub __header__ { sprintf $header, @{ $_[0] }{qw{ app_key access_token app_secret access_secret }} }

sub __flush__ {
	my ($self) = @_;
	my $curl = $self->{'curl'};
	my $url;

	$url  = 'https://';
	$url .= join '/', $hosts->{'content'}, $self->{'version'};

	$url .= join '/', '/commit_chunked_upload', $self->{'root'}, $self->{'path'}
		if $self->{'closed'};

	$url .= '/chunked_upload'
		unless $self->{'closed'};

	$url .= '?';

	$url .= join '=', 'upload_id', $self->{'upload_id'}
		if $self->{'upload_id'};

	$url .= '&'
		if $self->{'upload_id'};

	$url .= join '=', 'offset', $self->{'offset'} || 0
		unless $self->{'closed'};

	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_VERBOSE, $self->{'debug'}? 1 : 0);

	my $headers = [
		'Transfer-Encoding:',
		'Expect:',
		&__header__
	];

	$curl->setopt(CURLOPT_WRITEDATA, \(my $response));

	unless ($self->{'closed'}) {
		use bytes;

		my $buffer = substr $self->{'buffer'}, 0, $self->{'chunk'}, '';
		my $length = length $buffer;
		$self->{'length'} -= $length;
		$self->{'offset'} += $length;

		push @$headers, "Content-Length: $length";

		open my $upload, '<', \$buffer;
		$curl->setopt(CURLOPT_READDATA, $upload);
		$curl->setopt(CURLOPT_UPLOAD, 1);
	} else {
		$curl->setopt(CURLOPT_UPLOAD, 0);
		$curl->setopt(CURLOPT_POSTFIELDS, '');
	}

	$curl->setopt(CURLOPT_HTTPHEADER, $headers);

	my $code = $curl->perform();

	die join ' ', $curl->strerror($code), $curl->errbuf()
		unless $code == 0;

	$code = $curl->getinfo(CURLINFO_HTTP_CODE);

	given ($code) {
		$! = EACCES, return 0
			when 403;

		$! = EINVAL, return 0
			when 400;

		when (200) {
			$self->{'meta'} = from_json($response)
				if $self->{'closed'};
		}

		default {
			die join ' ', $code, $response
		}
	}

	unless ($self->{'upload_id'}) {
		$response = from_json($response);
		$self->{'upload_id'} = $response->{'upload_id'};
	}

	return 1;
} # __flush__

sub __meta__ {
	my ($self) = @_;
	my ($url, $meta, $curl);

	$curl = $self->{'curl'};

	$url  = 'https://';
	$url .= join '/', $hosts->{'api'}, $self->{'version'};
	$url .= join '/', '/metadata', $self->{'root'}, $self->{'path'};

	$url .= '?hash='. $self->{'hash'}
		if $self->{'hash'};

	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_VERBOSE, $self->{'debug'}? 1 : 0);
	$curl->setopt(CURLOPT_HTTPGET, 1);
	$curl->setopt(CURLOPT_HTTPHEADER, [&__header__]);
	$curl->setopt(CURLOPT_WRITEDATA, \(my $response));

	my $code = $curl->perform();

	die join ' ', $curl->strerror($code), $curl->errbuf()
		unless $code == 0;

	$code = $curl->getinfo(CURLINFO_HTTP_CODE);

	given ($code) {
		$! = EACCES, return 0
			when 403;

		$! = ENOENT, return 0
			when 404;

		$! = EPERM, return 0
			when 406;

		$meta = $self->{'meta'} = from_json($response)
			when 200;

		1 when 304;

		default {
			die join ' ', $code, $response;
		}
	}

	$! = EISDIR, return 0
		if $meta->{'is_dir'};

	$self->{'revision'} = $meta->{'rev'};
	$self->{'length'}   = $meta->{'bytes'};

	return 1;
} # __meta__

sub contents ($;$$) {
	my ($handle, $path, $hash) = @_;

	die 'GLOB reference expected'
		unless ref $handle eq 'GLOB';

	*$handle->{'hash'} = $hash
		if $hash;

	return if open $handle, '<', $path || '/' or $! != EISDIR;

	undef $!;
	return @{ *$handle->{'meta'}{'contents'} };
} # contents

sub putfile ($$$) {
	my ($handle, $path, $data) = @_;

	die 'GLOB reference expected'
		unless ref $handle eq 'GLOB';

	close $handle;

	my $self = *$handle{'HASH'};
	my $curl = $self->{'curl'};
	my ($url, $length);

	$url  = 'https://';
	$url .= join '/', $hosts->{'content'}, $self->{'version'};
	$url .= join '/', '/files_put', $self->{'root'}, $path;

	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_VERBOSE, $self->{'debug'}? 1 : 0);
	$curl->setopt(CURLOPT_WRITEDATA, \(my $response));

	{
		use bytes;
		$length = length $data;
	}

	my $headers = [
		'Transfer-Encoding:',
		'Expect:',
		"Content-Length: $length",
		__header__($self)
	];

	open my $upload, '<', \$data;

	$curl->setopt(CURLOPT_UPLOAD, 1);
	$curl->setopt(CURLOPT_HTTPHEADER, $headers);
	$curl->setopt(CURLOPT_READDATA, $upload);

	my $code = $curl->perform();

	die join ' ', $curl->strerror($code), $curl->errbuf()
		unless $code == 0;

	$code = $curl->getinfo(CURLINFO_HTTP_CODE);

	given ($code) {
		$! = EACCES, return 0
			when 403;

		$! = EINVAL, return 0
			when 400;

		when (200) {
			$self->{'path'} = $path;
			$self->{'meta'} = from_json($response);
		}

		default {
			die join ' ', $code, $response
		}
	}

	return 1;
} # putfile

sub metadata ($) {
	my ($handle) = @_;

	die 'GLOB reference expected'
		unless ref $handle eq 'GLOB';

	my $self = *$handle{'HASH'};

	die 'Meta is unavailable for incomplete upload'
		if $self->{'mode'} eq '>';

	return $self->{'meta'};
} # metadata

=head1 NAME

File::Dropbox - Convenient and fast Dropbox API abstraction

=head1 SYNOPSIS

    use File::Dropbox;
    use Fcntl;
   
    # Application credentials
    my %app = (
        app_key       => 'app key', 
        app_secret    => 'app secret',
        access_token  => 'access token',
        access_secret => 'access secret',
    );
    
    my $dropbox = File::Dropbox->new(%$app);
   
    # Open file for writing
    open $dropbox, '>', 'example' or die $!;
    
    while (<>) {
        # Upload data using 4MB chunks
        print $dropbox $_;
    }
   
    # Commit upload (optional, close will be called on reopen)
    close $dropbox or die $!;
    
    # Open for reading
    open $dropbox, '<', 'example' or die $!;
   
    # Download and print to STDOUT
    # Buffered, default buffer size is 4MB
    print while <$dropbox>;

    # Reset file position
    seek $dropbox, 0, Fcntl::SEEK_SET;

    # Get first character (unbuffered)
    say getc $dropbox;
   
    close $dropbox;

=head1 SEE ALSO

L<WWW::Curl>, L<WebService::Dropbox>

=head1 AUTHOR

Alexander Nazarov <nfokz@cpan.org>

=head1 COPYRIGHT

Copyright 2013 Alexander Nazarov, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
