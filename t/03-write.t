use strict;
use warnings;
use feature 'say';
use lib 't/lib';
use Test::More tests => 52;
use Test::Common qw{ EINVAL :func };
use File::Dropbox;

my $app     = do 'app.conf';
my $dropbox = File::Dropbox->new(%$app, chunk => 16 * 1024);
my $path    = 'test/';
my $file    = $path. time;

SKIP: {

skip 'No API key found', 52
	unless $app->{'app_key'} and $app->{'app_secret'};

# Try to open directory for writing
okay { open  $dropbox, '>', $path }                  'Path opened';
okay { say   $dropbox 'Test directory for writing' } 'Test string written';
errn { close $dropbox } EINVAL,                      'Commit Failed';

# Write plain file
okay { open  $dropbox, '>', $file } 'File opened for writing';
okay { print $dropbox  'A' x 1024 } '1k';
okay { print $dropbox  'B' x 1024 } '2k';
okay { print $dropbox  'C' x 1024 } '3k';
okay { print $dropbox  'D' x 1024 } '4k';
okay { close $dropbox }             'Committed';

# Check file content
okay { open $dropbox, '<', $file } 'File opened for reading';

is readline $dropbox, join('', 'A' x 1024, 'B' x 1024, 'C' x 1024, 'D' x 1024),
	'Content is okay';

# Rewrite file
okay { open  $dropbox, '>', $file }       'File opened for writing';
okay { printf $dropbox '%s', 'E' x 4096 } '4k';
okay { printf $dropbox '%s', 'F' x 4096 } '8k';

# Check file content
okay { open $dropbox, '<', $file } 'File opened for reading';

is readline $dropbox, join('', 'E' x 4096, 'F' x 4096),
	'Content is okay';

# Multipart upload
okay { open $dropbox, '>', $file } 'File opened for writing';
okay { print $dropbox 'G' x 4096 } '4k';
okay { print $dropbox 'H' x 8192 } '12k';
okay { print $dropbox 'I' x 8192 } '20k';
okay { close $dropbox }            'Committed';

# Check file content
okay { open $dropbox, '<', $file } 'File opened for reading';

is readline $dropbox, join('', 'G' x 4096, 'H' x 8192, 'I' x 8192),
	'Content is okay';

# Truncate file
okay { open $dropbox, '>', $file } 'File opened for writing';
okay { close $dropbox }            'Committed';

# Check file content
okay { open $dropbox, '<', $file } 'File opened for reading';
is readline $dropbox, undef,       'Content is okay';
okay { close $dropbox }            'All done';

} # SKIP
