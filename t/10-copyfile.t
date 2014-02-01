use strict;
use warnings;
use lib 't/lib';
use Test::More;
use Test::Common qw{ :func ENOENT };
use File::Dropbox qw{ putfile copyfile };

my $app     = conf();
my $dropbox = File::Dropbox->new(%$app);
my $path    = 'test';
my $filea   = $path. '/a'. time;
my $fileb   = $path. '/b'. time;
my $filec   = $path. '/c'. time;

unless (keys %$app) {
	plan skip_all => 'DROPBOX_AUTH is not set or has wrong value';
	exit;
}

plan tests => 16;

okay { putfile $dropbox, $filea, 'Y' x 1024 } 'Put 1k file';

okay { copyfile $dropbox, $filea, $fileb } 'Create copy';

okay { open $dropbox, '<', $fileb } 'Open target for reading';

# Read file
my $data = readline $dropbox;

# Check content
is $data, join('', 'Y' x 1024), 'Content is okay';

# Source file remains
okay { open $dropbox, '<', $filea } 'Open source for reading';

# Read file
$data = readline $dropbox;

# Check content
is $data, join('', 'Y' x 1024), 'Content is okay';

# Copy not existing file
errn {
	copyfile $dropbox, $filec, $filea;
} ENOENT, 'Failed to copy not existing file';

# Copy file to itself
okay { movefile $dropbox, $fileb, $fileb } 'File copied to same name';

# Overwrite file
okay { movefile $dropbox, $fileb, $filea } 'File overwritten';
