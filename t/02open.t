use strict;
use warnings;
use Test::More tests => 11;
use File::Dropbox;
use Fcntl qw{ SEEK_CUR SEEK_SET SEEK_END };
use Errno qw{ ENOENT EISDIR EINVAL EPERM EACCES };

my $app     = do 'app.conf';
my $dropbox = File::Dropbox->new(%$app);
my $file    = time. '.test';

sub is_closed {
	subtest Closed => sub {
		no warnings 'void';

		eval { tell $dropbox };

		like $@, qr{Tell is not supported on this handle},
			'Tell failed on unopened handle';

		eval { seek $dropbox, 0, SEEK_CUR };

		like $@, qr{Seek is not supported on this handle},
			'Seek failed on unopened handle';

		eval { read $dropbox, $_, 16 };

		like $@, qr{Read is not supported on this handle},
			'Read failed on unopened handle';

		eval { readline $dropbox };

		like $@, qr{Readline is not supported on this handle},
			'Readline failed on unopened handle';

		eval { print $dropbox 'test' };

		like $@, qr{Write is not supported on this handle},
			'Write failed on unopened handle';

		eval { eof $dropbox };

		like $@, qr{Eof is not supported on this handle},
			'Eof failed on unopened handle';

		my $self = *$dropbox{'HASH'};
		ok !$self->{'mode'},  'Mode is not set';
		ok $self->{'closed'}, 'Closed flag is set';
	};
} # is_closed

SKIP: {
	skip 'No API key found', 10
		unless $app->{'app_key'} and $app->{'app_secret'};

	is_closed();

	# Try to open not existing file for reading
	my $result = open $dropbox, '<', $file;

	is $result, 0,      'Failed to open not existing file';
	is int $!,  ENOENT, 'Error is set';

	is_closed();

	# Try to open it for writing
	$result = open $dropbox, '>', $file;

	is $result, 1, 'File opened for write';
	ok !$!,        'Error is not set';

	# Open for reading again
	$result = open $dropbox, '<', $file;

	is $result, 1, 'Empty file created';
	ok !$!,        'Error is not set';

	# Check end and close
	ok eof   $dropbox, 'File is empty';
	ok close $dropbox, 'File is closed';
} # SKIP

is_closed();
