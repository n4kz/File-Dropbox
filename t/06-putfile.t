use strict;
use warnings;
use lib 't/lib';
use Test::More tests => 9;
use Test::Common qw{ :func EINVAL };
use File::Dropbox qw{ putfile metadata };

my $app     = do 'app.conf';
my $dropbox = File::Dropbox->new(%$app);
my $path    = 'test';
my $file    = $path. '/'. time;

eval { putfile $app, $file, 'ABCD' };

like $@, qr{GLOB reference expected},
	'Function called on wrong reference';

SKIP: {

skip 'No API key found', 8
	unless $app->{'app_key'} and $app->{'app_secret'};

# Normal upload
okay { putfile $dropbox, $file, 'A' x 1024 } 'Put 1k file';

# Get meta from closed handle
my $meta = metadata $dropbox;

okay { open $dropbox, '<', $file } 'Open file for reading';

# Get meta from opened handle
my $meta2 = metadata $dropbox;

# Compare
is_deeply $meta, $meta2, 'Metadata matches';

# Read file
my $data = readline $dropbox;

# Check content
is $data, join('', 'A' x 1024),
	'Content is okay';

# Wrong file name
errn { putfile $dropbox, $path, 'A' x 1024 } EINVAL, 'Invalid parameters';
} # SKIP
