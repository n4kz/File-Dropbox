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
		'Net::Curl' => '0.28',
		'JSON'      => '2.0',
	},
);

$builder->create_build_script();
