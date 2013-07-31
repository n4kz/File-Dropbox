use 5.012;

use strict;
use warnings;
use Module::Build;

my $builder = Module::Build->new(
	module_name    => 'File::Dropbox',
	license        => 'perl',
	create_license => 1,
	create_readme  => 1,

	configure_requires => {
		'Module::Build' => '0.40',
	},

	requires => {
		'WWW::Curl' => '4.0',
		'JSON'      => '2.0',
	},
);

$builder->create_build_script();
