#!/usr/bin/perl

# Real faults, saved signal contexts, alternate stacks, and bounded traces.

use warnings;
use strict;

use JSON::PP qw(decode_json);
use POSIX qw(WNOHANG);
use Test::More;

BEGIN { use FindBin; chdir($FindBin::Bin); }

use Test::Nginx;

my $t = Test::Nginx->new()->has(qw/http ngx_backtrace_module
    ngx_http_backtrace_test_module/);
my @cases;
for my $format (qw/default json/) {
	push @cases, map { [$format, $_, ''] } qw/null stack access closedfd/;
	push @cases, map { [$format, 'stack', $_] } (1, 2);
}
$t->plan(scalar @cases);

for my $case (@cases) {
	my ($format, $mode, $limit) = @$case;
	my $name = join '-', $format, $mode, $limit || 'default';
	my $extra = $limit ? "backtrace_max_stack_size $limit;" : '';
	my $file = "$name.log";

	subtest $name => sub {
		$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
backtrace_log %%TESTDIR%%/$file format=$format;
$extra
events { worker_connections 64; }
http {
    %%TEST_GLOBALS_HTTP%%
    server {
        listen 127.0.0.1:8080;
        location / { return 200 alive; }
        location /fault { backtrace_test_fault; }
    }
}
EOF
		$t->run();
		my $pid = $t->read_file('nginx.pid');
		chomp $pid;
		ok($t->waitforsocket('127.0.0.1:' . port(8080)), 'nginx listens');
		like(http_get('/'), qr/\r\n\r\nalive$/, 'serves before fault');
		http_get("/fault?mode=$mode");

		my ($exited, $status);
		for (1 .. 100) {
			if (waitpid($pid, WNOHANG) == $pid) {
				$exited = 1;
				$status = $?;
				last;
			}
			select undef, undef, undef, 0.02;
		}
		if (!$exited) {
			kill 'KILL', $pid;
			waitpid($pid, 0);
			$status = $?;
		}
		ok($exited, 'fault terminates without forced cleanup');
		is($status & 127, 11, 'terminates with original SIGSEGV');
		$t->stop();
		unlink $t->testdir() . '/nginx.pid';

		my $trace = $t->read_file($file);
		like($t->read_file('error.log'), qr/ngx_backtrace: got signal 11/,
			'diagnostic is written to error log');

		if ($mode eq 'closedfd') {
			is($trace, '', 'closed trace file remains empty');
			like($t->read_file('error.log'), qr/cannot write into the file/,
				'closed file diagnosis is visible');
			done_testing();
			return;
		}

		my ($frames, $first);
		my $reason = $mode eq 'access' ? 'SEGV_ACCERR' : 'SEGV_MAPERR';
		if ($format eq 'json') {
			my $data = eval { decode_json($trace) };
			ok(defined $data && !$@, 'entire trace file is valid JSON');
			$data ||= {};
			is($data->{signal_number}, 11, 'JSON records SIGSEGV');
			is($data->{pid}, 0 + $pid, 'JSON records faulting process');
			like($data->{signal_reason} // '', qr/^$reason\b/,
				'JSON records the fault reason');
			my $stack = $data->{stack_trace} || [];
			$frames = scalar @$stack;
			$first = $frames ? $stack->[0]->{function} : '';
		} else {
			like($trace, qr/Received signal 11 \(SIGSEGV\)/,
				'text records SIGSEGV');
			like($trace, qr/^ PID: $pid$/m, 'text records faulting process');
			like($trace, qr/Signal Reason: $reason\b/,
				'text records the fault reason');
			like($trace, qr/End of stack trace\./, 'text trace is complete');
			my @frames = $trace =~ /^\s*#[0-9]+: .* in ([^(]+)\(\)/gm;
			$frames = scalar @frames;
			$first = $frames ? $frames[0] : '';
		}
		cmp_ok($frames, '>', 0, 'trace includes frames');
		my $function = $mode eq 'stack' ? 'recurse' : 'handler';
		like($first, qr/^ngx_http_backtrace_test_$function$/,
			'first frame is the faulting function');
		if ($mode eq 'stack') {
			is($frames, $limit || 30, 'stack trace stops at configured limit');
		}
		done_testing();
	};
}
