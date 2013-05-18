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

my $version = 1;

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

	$self->{'chunk'}   //= 4 << 20;
	$self->{'root'}    //= 'sandbox';

	die 'Unexpected root value'
		unless $self->{'root'} =~ m{^(?:drop|sand)box$};

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

	substr($_[1] //= '', $offset // 0) = '', return 0
		if $self->EOF();

	$curl = $self->{'curl'};

	$url  = 'https://';
	$url .= join '/', $hosts->{'content'}, $version;
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

	$self->__flush__() or return 0
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
				@{ $self }{qw{ closed mode }} = (1, '') and return 0
					unless $self->__flush__();
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

	$self->{'length'}   = 0;
	$self->{'position'} = 0;
	$self->{'buffer'}   = '';

	delete $self->{'offset'};
	delete $self->{'revision'};
	delete $self->{'upload_id'};
	delete $self->{'meta'};
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
	$url .= join '/', $hosts->{'content'}, $version;

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
	$url .= join '/', $hosts->{'api'}, $version;
	$url .= join '/', '/metadata', $self->{'root'}, $self->{'path'};

	$url .= '?hash='. delete $self->{'hash'}
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

	if (open $handle, '<', $path || '/' or $! != EISDIR) {
		delete *$handle->{'meta'};
		return;
	}

	undef $!;
	return @{ *$handle->{'meta'}{'contents'} };
} # contents

sub putfile ($$$) {
	my ($handle, $path, $data) = @_;

	die 'GLOB reference expected'
		unless ref $handle eq 'GLOB';

	close $handle or return 0;

	my $self = *$handle{'HASH'};
	my $curl = $self->{'curl'};
	my ($url, $length);

	$url  = 'https://';
	$url .= join '/', $hosts->{'content'}, $version;
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

    my $dropbox = File::Dropbox->new(%app);

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

=head1 DESCRIPTION

C<File::Dropbox> provides high-level Dropbox API abstraction based on L<Tie::Handle>. Code required to get C<access_token> and
C<access_secret> for signed OAuth requests is not included in this module.

At this moment Dropbox API is not fully supported, C<File::Dropbox> covers file read/write and directory listing methods. If you need full
API support take look at L<WebService::Dropbox>. C<File::Dropbox> main purpose is not 100% API coverage,
but simple and high-performance file operations.

Due to API limitations and design you can not do read and write operations on one file at the same time. Therefore handle can be in read-only
or write-only state, depending on last call to L<open|perlfunc/open>. Supported functions for read-only state are: L<open|perlfunc/open>,
L<close|perlfunc/close>, L<seek|perlfunc/seek>, L<tell|perlfunc/tell>, L<readline|perlfunc/readline>, L<read|perlfunc/read>,
L<sysread|perlfunc/sysread>, L<getc|perlfunc/getc>, L<eof|perlfunc/eof>. For write-only state: L<open|perlfunc/open>, L<close|perlfunc/close>,
L<syswrite|perlfunc/syswrite>, L<print|perlfunc/print>, L<printf|perlfunc/printf>, L<say|perlfunc/say>.

All API requests are done using L<WWW::Curl> module and libcurl will reuse same connection as long as possible.
This greatly improves overall module performance. To go even further you can share L<WWW::Curl::Easy> object between different C<File::Dropbox>
objects, see L</new> for details.

=head1 METHODS

=head2 new

    my $dropbox = File::Dropbox->new(
        access_secret => 'secret',
        access_token  => 'token',
        app_secret    => 'app secret',
        app_key       => 'app key',
        chunk         => 8 * 1024 * 1024,
        curl          => $curl,
        root          => 'dropbox',
    );

Constructor, takes key-value pairs list

=over

=item access_secret

OAuth access secret

=item access_token

OAuth access token

=item app_secret

OAuth app secret

=item app_key

OAuth app key

=item chunk

Upload chunk size in bytes. Also buffer size for C<readline>. Optional. Defaults to 4MB.

=item curl

C<WWW::Curl::Easy> object to use. Optional.

    # Get curl object
    my $curl = *$dropbox->{'curl'};

    # And share it
    my $dropbox2 = File::Dropbox->new(%app, curl => $curl);

=item root

Access type, C<sandbox> for app-folder only access and C<dropbox> for full access.

=item debug

Enable libcurl debug output.

=back

=head1 FUNCTIONS

All functions are not exported by default but can be exported on demand.

    use File::Dropbox qw{ contents metadata putfile };

First argument for all functions should be GLOB reference, returned by L</new>.

=head2 contents

Arguments: $dropbox [, $path]

Function returns list of hashrefs representing directory content. Hash fields described in L<Dropbox API
docs|https://www.dropbox.com/developers/core/docs#metadata>. C<$path> defaults to C</>. If there is
unfinished chunked upload on handle, it will be commited.

    foreach my $file (contents($dropbox, '/data')) {
        next if $file->{'is_dir'};
        say $file->{'path'}, ' - ', $file->{'bytes'};
    }

=head2 metadata

Arguments: $dropbox

Function returns stored metadata for read-only handle, closed write handle or after
call to L</contents> or L</putfile>.

    open $dropbox, '<', '/data/2013.dat' or die $!;

    my $meta = metadata($dropbox);

    if ($meta->{'bytes'} > 1024) {
        # Do something
    }

=head2 putfile

Arguments: $dropbox, $path, $data

Function is useful for uploading small files (up to 150MB possible) in one request (at least
two API requests required for chunked upload, used in open-write-close cycle). If there is
unfinished chunked upload on handle, it will be commited.

    local $/;
    open my $data, '<', '2012.dat' or die $!;

    putfile($dropbox, '/data/2012.dat', <$data>) or die $!;

    say 'Uploaded ', metadata($dropbox)->{'bytes'}, ' bytes';

    close $data;

=head1 SEE ALSO

L<WWW::Curl>, L<WebService::Dropbox>, L<Dropbox API|https://www.dropbox.com/developers/core/docs>

=head1 AUTHOR

Alexander Nazarov <nfokz@cpan.org>

=head1 COPYRIGHT AND LICENSE

Copyright 2013 Alexander Nazarov

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
