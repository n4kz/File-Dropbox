use strict;
use warnings;
use lib 't/lib';
use Test::More tests => 14;
use Test::Common qw{ :func ENOENT };
use File::Dropbox qw{ putfile metadata contents };

my $app     = do 'app.conf';
my $dropbox = File::Dropbox->new(%$app);
my $path    = 'test/contents'. time;
my $file    = $path. '/'. time;

eval { contents $app };

like $@, qr{GLOB reference expected},
	'Function called on wrong reference';

SKIP: {

skip 'No API key found', 12
	unless $app->{'app_key'} and $app->{'app_secret'};

# Create test file and directory
okay { putfile $dropbox, $file, 'A' x 1024 } 'Put 1k file';

# Get metadata and directory contents
my $filemeta = metadata $dropbox;
my @contents = contents $dropbox, $path;
my $meta     = metadata $dropbox;
my $hash     = $meta->{'hash'};

# FIXME: Looks like dropbox API always returns 'dropbox' in directory listing
local $contents[0]{'root'} = 'app_folder';

is scalar @contents, 1,            'One file is present in directory';
is_deeply $contents[0], $filemeta, 'Contents meta matches file meta';

is_deeply \@contents, $meta->{'contents'}, 'Meta contents are equal';

## Supply hash
@contents = contents $dropbox, $path, $hash;
$meta     = metadata $dropbox;

is scalar @contents, 0, 'Empty list returned';
is $meta, undef,        'Metadata is undefined';

# Try to get contents on file
@contents = contents $dropbox, $file;
$meta     = metadata $dropbox;

is scalar @contents, 0, 'Empty list returned';
is $meta, undef,        'Metadata is undefined';

# Get contents from /
@contents = contents $dropbox;
$meta     = metadata $dropbox;

ok scalar @contents,  'Not empty list returned';
is ref $meta, 'HASH', 'Metadata is set';

errn { contents $dropbox, $path. '/not_exists' } ENOENT, 'Open invalid directory';
} # SKIP
