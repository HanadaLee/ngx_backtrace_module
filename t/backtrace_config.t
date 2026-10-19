#!/usr/bin/perl

# Validate restored frame bounds while preserving JSON and off semantics.

use warnings;
use strict;
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my $t = Test::Nginx->new()->has(qw/ngx_backtrace_module/);
my @cases = (
	['off', 'backtrace_log off;', 1],
	['default', 'backtrace_log trace.log;', 1],
	['json', 'backtrace_log trace.log format=json;', 1],
	['minimum', 'backtrace_max_stack_size 1;', 1],
	['custom', 'backtrace_max_stack_size 2;', 1],
	['zero', 'backtrace_max_stack_size 0;', 0, qr/equal to or greater than 1/],
	['negative', 'backtrace_max_stack_size -1;', 0, qr/invalid number/],
	['not a number', 'backtrace_max_stack_size abc;', 0, qr/invalid number/],
	['duplicate limit', 'backtrace_max_stack_size 1; backtrace_max_stack_size 2;',
		0, qr/is duplicate/],
	['duplicate log', 'backtrace_log trace.log; backtrace_log other.log;',
		0, qr/is duplicate/],
	['duplicate off', 'backtrace_log off; backtrace_log trace.log;',
		0, qr/is duplicate/],
	['missing path', 'backtrace_log format=json;', 0, qr/requires log path/],
	['invalid format', 'backtrace_log trace.log format=xml;',
		0, qr/invalid format parameter/],
);
$t->plan(2 * @cases + 1);

for my $case (@cases) {
	my ($name, $line, $valid, $diagnosis) = @$case;
	$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
$line
events {}
EOF
	my $output = $t->dump_config();
	my $status = $?;
	if ($valid) {
		is($status, 0, "$name accepted");
		unlike($output, qr/\[emerg\]/, "$name no configuration error");
	} else {
		isnt($status, 0, "$name rejected");
		like($output, $diagnosis, "$name diagnosis");
	}
	if ($name eq 'off') {
		ok(!-e $t->testdir() . '/off', 'off does not create a log named off');
	}
}
