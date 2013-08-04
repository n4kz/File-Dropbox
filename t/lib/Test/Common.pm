package Test::Common;
use strict;
use warnings;
use Exporter 'import';
use Test::More;
use Fcntl qw{ SEEK_CUR SEEK_SET SEEK_END };
use Errno qw{ ENOENT EISDIR EINVAL EPERM EACCES ECANCELED };

our %EXPORT_TAGS = (
	seek  => [qw{ SEEK_CUR SEEK_SET SEEK_END }],
	fcntl => [qw{ ENOENT EISDIR EINVAL EPERM EACCES ECANCELED }],
	func  => [qw{ okay errn conf }],
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

sub conf {
	my %app;

	@app{qw{ app_key app_secret access_token access_secret }} = split ':', $ENV{'DROPBOX_AUTH'} || '';

	%app = ()
		if grep { not defined or not length } values %app;

	return \%app;
} # conf

1;
