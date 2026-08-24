#!/usr/bin/perl

# Tests for ngx_backtrace_module.

###############################################################################

use warnings;
use strict;

use JSON::PP qw(decode_json);
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

###############################################################################

select STDERR; $| = 1;
select STDOUT; $| = 1;

my $t = Test::Nginx->new()->has(qw/http ngx_backtrace_module/)->plan(21);

sub write_config {
	my ($t, $file, $format) = @_;

	$t->write_file_expand('nginx.conf', <<EOF);

%%TEST_GLOBALS%%

daemon off;
worker_processes 1;

backtrace_log %%TESTDIR%%/$file format=$format;

events {
}

http {
    %%TEST_GLOBALS_HTTP%%

    server {
        listen       127.0.0.1:8080;
        server_name  localhost;

        location / {
            return 200 alive;
        }
    }
}

EOF
}

sub worker_pid {
	my ($t) = @_;
	my $master = $t->read_file('nginx.pid');
	chomp $master;

	for (1 .. 50) {
		my @workers = $t->read_file('error.log')
			=~ /start worker process ([0-9]+)/g;

		return ($workers[-1], $master) if @workers;

		select undef, undef, undef, 0.1;
	}

	die "no worker process found for master $master";
}

sub wait_for_log {
	my ($t, $file, $re) = @_;

	for (1 .. 100) {
		my $log = $t->read_file($file);
		return $log if $log =~ $re;

		select undef, undef, undef, 0.05;
	}

	return $t->read_file($file);
}

###############################################################################

write_config($t, 'backtrace.log', 'default');
$t->run();

my ($worker, $master) = worker_pid($t);

is(kill('ABRT', $worker), 1, 'default format signal delivered');

my $log = wait_for_log($t, 'backtrace.log', qr/End of stack trace/);

like($log, qr/Received signal 6 \(SIGABRT\)/,
	'default format records signal');
like($log, qr/^Stack trace:$/m, 'default format starts stack trace');
like($log, qr/^End of stack trace\.$/m, 'default format ends stack trace');
like($log, qr/^ PID: \Q$worker\E$/m, 'default format records worker pid');
like($log, qr/^\s+#[0-9]+: .* in .*\(\), sp = /m,
	'default format records stack frame');
like(http_get('/'), qr/^HTTP\/1\.1 200 .*\x0d\x0a\x0d\x0aalive$/s,
	'worker continues after default trace');

$t->stop();

write_config($t, 'backtrace.json.log', 'json');
$t->run();

($worker, $master) = worker_pid($t);

is(kill('ABRT', $worker), 1, 'JSON format signal delivered');

$log = wait_for_log($t, 'backtrace.json.log',
	qr/^\{.*"stack_trace":\[.*\]\}$/m);

my ($json) = $log =~ /^(\{.*"stack_trace":\[.*\]\})$/m;
ok(defined $json, 'JSON trace is written as one object');

my $data = eval { decode_json($json // '') };
ok(defined $data && !$@, 'JSON trace parses');
$data ||= {};

is($data->{signal_number}, 6, 'JSON records signal number');
is($data->{signal_name}, 'SIGABRT', 'JSON records signal name');
is($data->{signal_reason}, 'Unknown reason',
	'JSON records fallback signal reason');
is($data->{pid}, 0 + $worker, 'JSON records worker pid');
is($data->{ppid}, 0 + $master, 'JSON records master pid');
like($data->{binary_name} // '', qr{/nginx$}, 'JSON records binary path');
like($data->{time_local} // '', qr/^[A-Z][a-z]{2} /,
	'JSON records local time');
is(ref($data->{stack_trace}), 'ARRAY', 'JSON records stack trace array');
ok(@{$data->{stack_trace} || []}, 'JSON records at least one frame');

my $frame = $data->{stack_trace} && $data->{stack_trace}[0] || {};
ok(defined $frame->{frame} && defined $frame->{ip}
	&& defined $frame->{function} && defined $frame->{sp},
	'JSON frame contains required fields');
like(http_get('/'), qr/^HTTP\/1\.1 200 .*\x0d\x0a\x0d\x0aalive$/s,
	'worker continues after JSON trace');

###############################################################################
