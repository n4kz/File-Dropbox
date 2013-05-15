package Test::Common;
use strict;
use warnings;
use Exporter 'import';
use Test::More;
use Fcntl qw{ SEEK_CUR SEEK_SET SEEK_END };
use Errno qw{ ENOENT EISDIR EINVAL EPERM EACCES };

our %EXPORT_TAGS = (
	seek  => [qw{ SEEK_CUR SEEK_SET SEEK_END }],
	fcntl => [qw{ ENOENT EISDIR EINVAL EPERM EACCES }],
	func  => [qw{ okay errn }],
);

our @EXPORT_OK = map { @$_ } values %EXPORT_TAGS;
$EXPORT_TAGS{'all'} = \@EXPORT_OK;

sub okay (&$) {
	local $\;

	my $result = &{ $_[0] };

	ok $result, $_[1];
	ok !$!,     'Error is not set';
} # okay

sub errn (&$$) {
	my $result = &{ $_[0] };

	ok !$result,      $_[2];
	is int $!, $_[1], 'Error is set';
} # errn

1;
