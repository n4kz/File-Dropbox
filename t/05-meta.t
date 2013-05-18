use strict;
use warnings;
use lib 't/lib';
use Test::More tests => 31;
use Test::Common qw{ EISDIR :func };
use File::Dropbox 'metadata';

my $app     = do 'app.conf';
my $dropbox = File::Dropbox->new(%$app, chunk => 4096);
my $path    = 'test';
my $file    = $path. '/'. time;

# Closed handle
is metadata $dropbox, undef, 'No metadata for closed handle';

eval { metadata $app };

like $@, qr{GLOB reference expected},
	'Function called on wrong reference';

SKIP: {

skip 'No API key found', 29
	unless $app->{'app_key'} and $app->{'app_secret'};

# Create empty file
okay { open  $dropbox, '>', $file } 'File opened for writing';

eval { metadata $dropbox };

like $@, qr{Meta is unavailable},
	'No metadata for handle in write mode';

okay { close $dropbox } 'File committed';

# Get meta from closed handle
my $meta = metadata $dropbox;

is ref $meta, 'HASH', 'Got hashref from metadata()';

is $meta->{'bytes'},  0,           'File size is set';
is $meta->{'is_dir'}, JSON::false, 'File type is set';
is $meta->{'path'},   '/'. $file,  'File path is set';

ok exists $meta->{'rev'},          'Rev number is present';
ok exists $meta->{'root'},         'File root is present';
ok exists $meta->{'revision'},     'Rev hash is present';
ok exists $meta->{'modified'},     'File mtime is present';

# Reopen file for reading
okay { open  $dropbox, '<', $file } 'File opened for reading';

my $meta2 = metadata $dropbox;

is_deeply $meta, $meta2, 'Meta for write mode matches meta for read mode';

# Open directory
errn { open $dropbox, '<', $path } EISDIR, 'Directory opened';

$meta = metadata $dropbox;

# Get contents
my $contents = $meta->{'contents'};

is ref $meta,     'HASH',  'Metadata is hash';
is ref $contents, 'ARRAY', 'Directory files are in array';

ok !(grep { ref $_ ne 'HASH' } @$contents), 'Metadata for each file is hash';

is $meta->{'bytes'},  0,           'File size is set';
is $meta->{'is_dir'}, JSON::true,  'File type is set';
is $meta->{'path'},   '/'. $path,  'File path is set';

ok exists $meta->{'rev'},      'Rev number is present';
ok exists $meta->{'hash'},     'Cache hash is present';
ok exists $meta->{'root'},     'File root is present';
ok exists $meta->{'revision'}, 'Rev hash is present';
ok exists $meta->{'modified'}, 'File mtime is present';

} # SKIP
