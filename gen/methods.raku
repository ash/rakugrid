#!/usr/bin/env raku
# gen/methods.raku — the method matrix, driven by introspection.
#
#   rakupp gen/methods.raku --engines=raku,/path/to/rakupp [--jobs=8]
#
# The other generators work from a hand-written spec table, which does not
# scale and is not exhaustive by construction: an operator nobody thought of is
# simply absent, and nothing says so. This one asks the implementation what
# methods a type HAS — `.^methods` — and crosses every one of them with that
# type's edge ladder. A method that exists and is untested becomes impossible.
#
# One atom per type, so `rakugrid matrix Int` renders methods × values and a
# hole is visible at a glance.
#
# Safety: only value types are introspected, and any method that could touch the
# outside world is refused by name. A generated suite must never be able to
# delete a file because some type grew an `.unlink`.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

# type => the edge ladder of instances for it. Value types only.
#
# NOTE on unordered containers. A Set, Bag, Mix or Hash with more than one
# distinct key renders in hash order, and Rakudo randomises that per process —
# `set(1,2)` is "1,2" in one run and "2,1" in the next. Probing twice agrees by
# luck about half the time, so the reproducibility check cannot catch it. Rather
# than assert a coin flip, these ladders carry only instances whose order cannot
# vary: empty, or a single distinct key. Multi-key behaviour belongs in atoms
# that assert order-independent properties (`.elems`, `.total`, `.keys.sort`).
constant %TYPES =
    'Int'      => ['0', '1', '-1', '2**64', '-2**64', '42', '2', '10', '-42', '2**63-1'],
    'Rat'      => ['1/3', '0/1', '-1/3', '1/1', '(2**64)/3', '1/2', '3/1', '-1/1'],
    'Num'      => ['0e0', '-0e0', '1e0', '-1e0', 'Inf', '-Inf', 'NaN', '2e0', '0.5e0', '1e308'],
    'Complex'  => ['1+2i', '0+0i', '-1-1i', 'Inf+0i', '0+1i', '-0e0+0e0i', 'NaN+0i', '1e0+1e0i'],
    'Str'      => ['""', '" "', '"0"', '"a"', '"ABC"', '"e\c[COMBINING ACUTE ACCENT]"', '"a b  c"', '"-1"', '"Inf"', '"\n"', '"aa"'],
    'Bool'     => ['True', 'False', 'so(1)', 'not(1)', '(1 == 1)', '(1 == 2)'],
    'List'     => ['()', '(1,)', '(1,2,3)', '(1,(2,3))', '("a","b")', '(Any,)', '(1,Nil)', '(1..3).list'],
    'Array'    => ['[]', '[1]', '[1,2,3]', '[[1],[2]]', '[Any]', '["a","b"]', '[1,"a"]'],
    'Hash'     => ['{}', '{a=>1}', '{"" => 1}'],
    'Pair'     => ['(a => 1)', '(1 => "x")', '(a => Any)', '("" => 0)', '(a => (1,2))'],
    'Range'    => ['(1..3)', '(1^..^3)', '(3..1)', '("a".."c")'],
    'Seq'      => ['(1..3).Seq', '().Seq', '(1,).Seq', '<a b>.Seq', '(1..3).map(*+1).Seq'],
    'Set'      => ['set(1)', 'set()'],
    'Bag'      => ['bag(1,1)', 'bag()'],
    'Map'      => ['Map.new((a=>1))', 'Map.new()'],
    'Capture'  => ['\\(1, :a)', '\\()', '\\(1,2)', '\\(:a, :b)', '\\(Any)'],
    'Version'  => ['v1.2.3', 'v0', 'v1', 'v1.2.3+', 'v0.0.1'],
    'Order'    => ['Order::Less', 'Order::Same', 'Order::More'],
    'Instant'  => ['Instant.from-posix(0)'],
    'Duration' => ['Duration.new(1)', 'Duration.new(0)', 'Duration.new(-1)', 'Duration.new(1/3)'],
    'Date'     => ['Date.new(2000,1,1)', 'Date.new(2000,2,29)', 'Date.new(1970,1,1)', 'Date.new(2026,12,31)'],
    'DateTime' => ['DateTime.new(2000,1,1,0,0,0)'],
    'Blob'     => ['Blob.new(1,2,3)', 'Blob.new()', 'Blob.new(0)', 'Blob.new(255)'],
    'Buf'      => ['Buf.new(1,2,3)', 'Buf.new()', 'Buf.new(0)', 'Buf.new(255)'],
    'Junction' => ['any(1,2)', 'all(1,2)', 'one(1,2)', 'none(1,2)', 'any()', 'all()'],
    'Nil'      => ['Nil'],
    'Mu'       => ['Any', 'Mu', 'Int', 'Str', '1', '0', '-1', '"a"', '""', '(1,2)', '{a=>1}', 'Nil', 'True', 'False', '1e0', '1/2', '(1..3)', 'set(1)'],
    'Any'      => ['Any', 'Mu', 'Int', 'Str', '1', '0', '-1', '"a"', '""', '(1,2)', '{a=>1}', 'Nil', 'True', 'False', '1e0', '1/2', '(1..3)', 'set(1)'],
    'Signature' => [':(Int $a)', ':()', ':($a, $b)', ':(*@a)', ':(:$a)', ':($a where * > 0)'],
    'Match'    => ['("abc" ~~ /b/)', '("abc" ~~ /x/)', '("abc" ~~ /(b)/)', '("abc" ~~ /\\w+/)'],
    'Failure'  => ['(try { die "x" } // $!)'],

    # --- widened: more of the value surface ---------------------------------
    'Mix'      => ['mix(1,1)', 'mix()'],
    'SetHash'  => ['SetHash.new(1)', 'SetHash.new'],
    'BagHash'  => ['BagHash.new(1,1)', 'BagHash.new'],
    'MixHash'  => ['MixHash.new(1)', 'MixHash.new'],
    'Slip'     => ['slip(1,2)', 'Empty'],
    'Code'     => ['{ 1 }', '-> $x { $x }'],
    'Block'    => ['{ 1 }', '{ $_ }'],
    'Regex'    => ['/a/', '/^ \\d+ $/'],
    'Cool'     => ['1', '"a"', '1/2', '0', '""', '1e0', '-1', '"0"', 'True', '2**64', '"ABC"', '" "', '42', '-1e0', 'False'],
    'Numeric'  => ['1', '1e0', '1/2', '1+0i', '0', '-1', 'Inf', 'NaN', '-Inf', '2**64', '0e0', '-0e0', '42', '1/3'],
    'Real'     => ['1', '1e0', '1/2', '0', '-1', 'Inf', 'NaN', '2**64', '-Inf', '0e0', '-0e0', '42', '1/3', 'True'],
    'Stringy'  => ['"a"', '""', '" "', '"0"', '"ABC"', '"a b"', '"-1"', '"Inf"', '"aa"', '"e\c[COMBINING ACUTE ACCENT]"'],
    'Iterable' => ['(1,2)', '[1,2]', '(1..2)', '()', '(1,)', '<a b>', '(1..3).Seq', '[]', '(Any,)', '(1,"a")', 'set(1)', 'bag(1,1)'],
    'Positional' => ['[1,2]', '()', '[]', '(1,2,3)', '[Any]', '(1,)', '<a b>', '[1,"a"]', '[[1],[2]]'],
    'Associative' => ['{a=>1}', '{}', '{"" => 1}', 'Map.new((a=>1))', '{a=>Any}', 'Map.new()', 'SetHash.new(1)'],
    'Callable' => ['{ 1 }', '&say', '-> $x { $x }', '{ $_ }', '(* + 1)', '(* > 0)', '{ ; }', '-> { 1 }'],
    'Exception' => ['X::AdHoc.new(payload => "x")'],
    'IntStr'   => ['<42>', '<-1>'],
    'RatStr'   => ['<1.5>', '<0.0>'],
    'NumStr'   => ['<1e0>'],
    'Uni'      => ['Uni.new(97)', 'Uni.new'],
    'utf8'     => ['"a".encode', '"".encode'],
    'Whatever' => ['*'],
    'WhateverCode' => ['(* + 1)', '(* > 0)'],
    'Enumeration'  => ['Order::Less'],
    'Attribute'    => ['(class { has $.x }).^attributes[0]'],
    'Parameter'    => [':(Int $a)'.words[0] eq 'x' ?? ':()' !! ':(Int $a)'],
    'Method'   => ['(class { method m() { 1 } }).^find_method("m")'],
    'Routine'  => ['&say', '{ 1 }'];

# Refused by NAME, whatever type carries them. A generated suite must not be
# able to touch the filesystem, spawn a process, or block on something.
# What to hand a one-argument method. Deliberately across the type boundary:
# `.substr("a")` and `.abs(1)` are as interesting as the well-typed calls.
constant @ARGS = ['0', '1', '-1', '"a"', 'Any'];

# The all-caps names that ARE language surface rather than plumbing.
constant @CAPS-KEEP = <ACCEPTS WHAT WHO WHY HOW WHICH DEFINITE VAR REPR EVAL AST DUMP>;

constant @FORBIDDEN =
    'run', 'shell', 'exit', 'unlink', 'rmdir', 'mkdir', 'spurt', 'slurp',
    'open', 'close', 'print', 'print-nl', 'say', 'note', 'put', 'printf',
    'sink', 'wait', 'await', 'start', 'sleep', 'BUILD', 'DESTROY', 'CALL-ME',
    'STORE', 'BIND-POS', 'BIND-KEY', 'ASSIGN-POS', 'ASSIGN-KEY', 'push', 'pop',
    'shift', 'unshift', 'splice', 'append', 'prepend', 'chdir', 'symlink',
    'link', 'rename', 'copy', 'move', 'watch', 'lines', 'words', 'get', 'getc',
    'readchars', 'read', 'write', 'seek', 'tell', 'lock', 'unlock', 'signal',
    'Supply', 'Channel', 'Promise', 'tap', 'emit', 'done', 'quit', 'schedule',
    'cue', 'kill', 'perl', 'encode', 'decode',
    # where an object was DEFINED, never what it is: 1 under a probe, 962
    # inside a dense program, and neither is a fact about the language
    'line', 'file';

constant $METHOD-PROBE = q:to/END/;
    # print the local methods of each named type, with their arity
    for @*ARGS[0].IO.lines -> $tname {
        my $t = try ::($tname);
        next unless $t.defined || $t !~~ Failure;
        my @m = try { $t.^methods(:all).list } // ();
        for @m -> $m {
            my $n = try { $m.name } // '';
            next unless $n && $n ~~ /^ <[A..Za..z_-]> <[\w'-]>* $/;
            my $c = try { $m.count } // 99;
            say join("\t", $tname, $n, $c);
        }
    }
    END

constant $VALUE-PROBE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $expr {
        my $r = try EVAL $expr;
        if $! {
            say join("\t", $expr, 'ERR:' ~ $!.^name, '-');
        }
        else {
            my $v = try { $r.raku } // 'UNRENDERABLE';
            my $t = try { $r.WHAT.^name } // '-';
            say join("\t", $expr, $v, $t);
        }
        $*OUT.flush;
    }
    END

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

sub run-sh($line, $secs) {
    my $base = $TMP.add('m-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; wait \$w 2>/dev/null; exit \$rc";
    my $p = run('/bin/sh', '-c', $script);
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;
    return { out => $out, exit => $p.exitcode };
}

# Probing is the bottleneck at this size, and it parallelises perfectly: the
# expressions are independent.
#
# Work is cut into SMALL batches rather than one chunk per job. A single chunk
# needs a timeout long enough for thousands of expressions, which means a
# genuine hang costs that whole timeout — and a timeout short enough to catch a
# hang kills healthy work instead. With small batches the timeout is honest at
# both ends: a hang costs one batch, and a slow batch is still only a batch.
# $partial, when given, is the cache file for the engine being probed; each
# batch is appended as soon as it lands, so a hang costs the batch in flight
# rather than the whole pass. cache-load skips a truncated line.
sub run-parallel($cmd, @exprs, $probe-src, $jobs, $batch = 200, $secs = 120, $partial = Str) {
    my $probe = $TMP.add('mm-probe-' ~ $GUARD++ ~ '.raku');
    $probe.spurt($probe-src);

    my %seen;
    my $total  = @exprs.elems;
    my $done   = 0;
    my $offset = 0;

    while $offset < $total {
        my @cmds;
        my @parts;

        for ^$jobs -> $j {
            my $from = $offset + $j * $batch;
            last if $from >= $total;
            my $to = min($from + $batch, $total) - 1;

            my $list = $TMP.add("mm-list-$j.txt");
            $list.spurt(@exprs[$from .. $to].join("\n") ~ "\n");
            my $out = $TMP.add("mm-out-$j.txt").absolute;
            $out.IO.unlink if $out.IO.e;
            @parts.push: $out;
            @cmds.push: "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) } > { sh-quote($out) } 2>/dev/null &";
        }
        last unless @cmds;

        my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; " ~ @cmds.join(' ') ~ " wait";
        # A killed batch makes `sh` exit non-zero, and a Proc that is merely
        # sunk THROWS on that — which killed the whole run three hours in.
        # Capture it and read the code instead.
        my $proc = run('/bin/sh', '-c',
            "( $script ) & p=\$!; "
          ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
          ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; wait \$w 2>/dev/null; exit 0");
        my $ignored = $proc.exitcode;

        my @fresh-rows;
        for @parts -> $f {
            next unless $f.IO.e;
            for $f.IO.slurp.lines -> $l {
                my @c = $l.split("\t");
                next unless @c >= 3;
                %seen{@c[0]} = { value => @c[1], type => @c[2] };
                @fresh-rows.push: join("\t", @c[0], @c[1], @c[2]);
            }
            $f.IO.unlink;
        }
        if $partial && @fresh-rows {
            $partial.IO.spurt(@fresh-rows.join("\n") ~ "\n", :append);
        }

        # @parts is what this round actually launched — never more than $jobs,
        # and fewer on the last round. `$now` was never declared: this line only
        # runs when there are new cells to probe, and until the ladders widened
        # every run was served entirely from cache, so it never executed.
        $offset += @parts.elems * $batch;
        $done = min($offset, $total);
        note "#     { $done } / $total" if $done %% 2000 || $done == $total;
    }
    return %seen;
}

# Anything the parallel pass missed — a batch that died takes its tail with it.
# Recovering one expression at a time costs one process per lost cell, which is
# what made generation slow: a single fatal expression in a 200-cell batch cost
# 199 extra process spawns. Bisect instead. A batch that dies is split in half
# and retried, so isolating one killer costs log2(n) runs, and the healthy cells
# around it come back in bulk.
sub recover($cmd, @missing, $probe-src, $depth = 0) {
    return {} unless @missing;

    my $list  = $TMP.add("mm-rec-$depth.txt");
    my $probe = $TMP.add('mm-rec-probe.raku');
    $list.spurt(@missing.join("\n") ~ "\n");
    $probe.spurt($probe-src);

    # The timeout must scale with the work. Healthy cells run at ~190/sec, so a
    # flat 60s for every level means each HANG costs the full minute at each of
    # ~9 bisection depths — nine minutes to isolate one bad cell. Give each
    # level only the time its list could honestly need.
    my $secs = @missing == 1 ?? 6 !! max(6, (@missing / 20).ceiling);
    my %r = run-sh("{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) }", $secs);

    my %got;
    for %r<out>.lines -> $l {
        my @c = $l.split("\t");
        next unless @c >= 3;
        %got{@c[0]} = { value => @c[1], type => @c[2] };
    }

    my @still = @missing.grep({ !%got{$_} });
    return %got unless @still;

    if @still == 1 {
        # one expression, and it still produced nothing: it is the killer
        %got{@still[0]} = { value => (%r<exit> == 137 ?? 'HANG' !! 'CRASH:' ~ %r<exit>), type => '-' };
        return %got;
    }

    my $half = (@still / 2).Int;
    my %a = recover($cmd, @still[0 ..^ $half].list, $probe-src, $depth + 1);
    my %b = recover($cmd, @still[$half .. *].list,  $probe-src, $depth + 1);
    for %a.keys -> $k { %got{$k} = %a{$k} }
    for %b.keys -> $k { %got{$k} = %b{$k} }
    return %got;
}

sub cache-load($id) {
    my $f = $TMP.add("mm-cache-$id.tsv");
    return {} unless $f.e;
    my %c;
    for $f.slurp.lines -> $l {
        my @p = $l.split("\t");
        next unless @p >= 3;
        %c{@p[0]} = { value => @p[1], type => @p[2] };
    }
    return %c;
}

sub cache-save($id, %seen) {
    my @lines;
    for %seen.keys.sort -> $k {
        @lines.push: join("\t", $k, %seen{$k}<value>, %seen{$k}<type>);
    }
    $TMP.add("mm-cache-$id.tsv").spurt(@lines.join("\n") ~ "\n");
}


# An engine can answer with bytes that are not valid UTF-8 — rakupp renders
# `(-1).chrs` as \xff\xbf\xbf\xbf. Storing that verbatim puts a byte sequence in
# the record that no strict reader can decode, so one cell breaks every tool that
# reads the suite. Keep WHAT happened, in a form that is text.
sub textual($v) {
    return $v if try { $v.encode('utf-8').decode('utf-8') === $v };
    return 'INVALID-UTF8:' ~ (try { $v.ords.map(*.base(16)).join(' ') } // 'unrenderable');
}


# How many probes to run at once. `--jobs=auto` samples the machine each round
# and takes what is going spare: cores, minus the current load, minus one to
# leave the person using this machine a core of their own. Clamped to a sane
# band so a quiet moment does not spawn a swarm and a busy one never stalls
# entirely. A fixed --jobs=N still overrides.
sub cores() {
    my $p = run('sysctl', '-n', 'hw.ncpu', :out, :err);
    my $n = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);
    return +$n || 4;
}

sub load-now() {
    my $p = run('sysctl', '-n', 'vm.loadavg', :out, :err);
    my $t = $p.out.slurp(:close);
    $p.err.slurp(:close);
    # `{ 2.03 2.80 2.84 }` — take the one-minute figure. Returning 0 on a parse
    # failure would be the dangerous default: it makes a busy machine look idle
    # and the sampler ask for every core. Fall back to the ceiling instead.
    return +$0 if $t ~~ / (\d+ '.' \d+) /;
    return 999;
}

sub adaptive-jobs($requested, $ceiling = 6) {
    return $requested unless $requested ~~ Str && $requested eq 'auto';
    my $spare = (cores() - load-now() - 1).floor;
    return max(1, min($ceiling, $spare));
}

sub PREFIX() { "mm" }
sub TMPD() { $TMP }

# Every observation already on record for one implementation, whatever build
# made it. A development build moves faster than the suite can re-measure it, so
# re-probing 50,000 cells because five commits landed is waste — but carrying an
# old observation forward under the new build's name would be a lie. Each
# expression therefore remembers WHICH build answered it, and only genuinely new
# cells are put to the current one.
sub build-distance($s) {
    return +$0 if $s ~~ / '-' (\d+) '-g' /;
    return 0;
}

sub cache-load-family($short) {
    my %seen;
    my @files = TMPD().dir.grep({ .basename.starts-with(PREFIX() ~ '-cache-' ~ $short) && .extension eq 'tsv' });
    for @files.sort({ build-distance(.basename) }) -> $f {
        my $label = $f.basename.subst(PREFIX() ~ '-cache-', '').subst('.tsv', '');
        next if $label.ends-with('-again');
        for $f.slurp.lines -> $l {
            my @p = $l.split("\t");
            next unless @p >= 3;
            %seen{@p[0]} = { value => @p[1], type => @p[2], label => $label };
        }
    }
    return %seen;
}

sub engine-id($cmd) {
    my $p = run($cmd, '-e', 'print $*RAKU.compiler.name', :out, :err);
    my $name = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);
    # Prefer what the engine says about its BUILD over what it says about its
    # version. A development build changes behaviour without changing its
    # version, and `$*RAKU.compiler.build` is a git describe — tag, distance,
    # commit, and a `-dirty` flag when the tree was not clean. That last part
    # matters: it says the build is not reproducible from the commit alone, so
    # an observation recorded against it should be read with that in mind.
    my $b = run($cmd, '-e', 'print (try $*RAKU.compiler.build) // ""', :out, :err);
    my $build = $b.out.slurp(:close).trim;
    $b.err.slurp(:close);

    my $short = $name.contains('Raku++') || $name.lc.contains('rakupp')
        ?? 'rakupp'
        !! ($name || 'unknown');

    return "$short-$build" if $build;

    if $name.contains('Raku++') || $name.lc.contains('rakupp') {
        my $v = run($cmd, '--version', :out, :err);
        my $text = $v.out.slurp(:close);
        $v.err.slurp(:close);
        my $ver = $text ~~ /(\d+ '.' \d+ '.' \d+)/ ?? ~$0 !! 'unknown';
        # A development build changes behaviour without changing its version, so
        # `rakupp-3.14.0` alone cannot tell yesterday's snapshot from today's.
        # Stamp it with the binary's build date: observations accumulate, and two
        # observations of the same engine must be distinguishable or the record
        # silently claims a fixed engine still has the old bug.
        my $stamp = '';
        if $cmd.IO.e {
            my $d = DateTime.new($cmd.IO.modified);
            $stamp = sprintf('%04d%02d%02d', $d.year, $d.month, $d.day);
        }
        return $stamp ?? "rakupp-$ver+$stamp" !! "rakupp-$ver";
    }
    my $p2 = run($cmd, '-e', 'print $*RAKU.compiler.version', :out, :err);
    my $ver = $p2.out.slurp(:close).trim;
    $p2.err.slurp(:close);
    return ($name || 'unknown') ~ '-' ~ ($ver || 'unknown');
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
my $JOBS = 2;   # or --jobs=auto to take what the machine has spare
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $JOBS    = ($a.substr(7) eq 'auto' ?? 'auto' !! +$a.substr(7)) if $a.starts-with('--jobs=');
}
# Standing rulings, applied at emit time so that generated files stay
# generated. A row here says: the reference's answer for this expression is not
# the right one, and here is what to assert instead. See docs/PLAN.md §2.
my %RULED;
my $adj = $ROOT.add('adjudications/numeric-ieee.tsv');
if $adj.e {
    for $adj.slurp.lines -> $l {
        next if $l.starts-with('#') || !$l.trim;
        my @f = $l.split("\t");
        next unless @f >= 3;
        %RULED{@f[0]} = { is => @f[1], why => @f[2] };
    }
    say "# { %RULED.elems } standing ruling{ %RULED.elems == 1 ?? '' !! 's' } loaded";
}

my @ids = @engines.map({ engine-id($_) });

# --- step 1: ask the reference what methods each type has -------------------

my $tlist = $TMP.add('mm-types.txt');
$tlist.spurt(%TYPES.keys.sort.join("\n") ~ "\n");
my $mprobe = $TMP.add('mm-methods.raku');
$mprobe.spurt($METHOD-PROBE);

my %r = run-sh("{ sh-quote(@engines[0]) } { sh-quote($mprobe.absolute) } { sh-quote($tlist.absolute) }", 120);

my %methods;
my %arity;
for %r<out>.lines -> $l {
    my @c = $l.split("\t");
    next unless @c >= 3;
    my ($t, $n, $count) = @c;
    next if @FORBIDDEN.first({ $_ eq $n });
    # Raku spells identifiers with hyphens; an underscore marks an NQP-side
    # internal (BUILD_LEAST_DERIVED, FLATTENABLE_HASH, CURSOR_NEXT), which no
    # independent implementation owes anyone.
    next if $n.contains('_');

    # A run of capitals marks the REPR/metamodel plumbing — CREATE, POPULATE,
    # COERCE, RAW-HASH, INSTANTIATE-GENERIC. Two reasons to refuse them, and the
    # second is the expensive one: they are noise in any list of what a Raku
    # implementation is missing, AND they die in ways `try` cannot catch, taking
    # the whole probe batch down. Rakugrid's own generation was spending most of
    # its time restarting after these. Raku's user-facing shouting API is a small
    # closed set, so it is easier to name what to keep.
    next if $n ~~ / <[A..Z]> ** 3..* / && !@CAPS-KEEP.first({ $_ eq $n });
    # invocant only, or invocant plus one argument we can supply from a ladder
    next unless +$count == 1 || +$count == 2;
    %arity{"$t\t$n"} = +$count;
    %methods{$t} = [] unless %methods{$t}:exists;
    %methods{$t}.push: $n;
}
for %methods.keys -> $t {
    %methods{$t} = %methods{$t}.unique.sort.list;
}

say "# { %TYPES.elems } types, { %methods.values.map(*.elems).sum } nullary methods on record";

# --- step 2: build every cell ----------------------------------------------

my @all;
my %cells;
for %TYPES.keys.sort -> $t {
    next unless %methods{$t};
    my @c;
    for %methods{$t}.list -> $m {
        my $n = %arity{"$t\t$m"} // 1;
        for %TYPES{$t}.list -> $v {
            if $n == 1 {
                @c.push: { method => $m, value => $v, expr => "($v).$m" };
            }
            else {
                for @ARGS -> $a {
                    @c.push: { method => "$m\($a)", value => $v, expr => "($v).$m\($a)" };
                }
            }
        }
    }
    %cells{$t} = @c;
    @all.append: @c.map(*<expr>);
}
@all = @all.unique;
my $records = 0;
for %cells.keys -> $t { $records += %cells{$t}.elems }
say "# { @all.elems } distinct expressions to probe, { $records } records to write";
exit 0 if @*ARGS.first({ $_ eq '--count-only' });

# --- step 3: observe, in parallel -------------------------------------------

my @obs;
for ^@engines -> $e {
    # Incremental: widening the type table or a ladder should cost only the
    # NEW cells. Everything already on record is reused verbatim.
    my $short = @ids[$e].split('-')[0];
    my %seen = cache-load-family($short);
    my @todo = @all.grep({ !%seen{$_} });
    if !@todo {
        say "# all { @all.elems } cells already on record for { @ids[$e] }";
        @obs.push: %seen;
        next;
    }
    say "# probing { @ids[$e] }: { @todo.elems } new of { @all.elems } ({ @all.elems - @todo.elems } carried forward from earlier builds), $JOBS jobs …";
    my %fresh = run-parallel(@engines[$e], @todo, $VALUE-PROBE, $JOBS, 200, 120, $TMP.add("mm-cache-{@ids[$e]}.tsv").absolute);
    for %fresh.keys -> $k { %fresh{$k}<label> = @ids[$e]; %seen{$k} = %fresh{$k} }
    my @missing = @todo.grep({ !%seen{$_} });
    if @missing {
        say "#   recovering { @missing.elems } lost cells by bisection …";
        my %filled = recover(@engines[$e], @missing, $VALUE-PROBE);
        for %filled.keys -> $k { %filled{$k}<label> = @ids[$e]; %seen{$k} = %filled{$k} }
    }
    my %mine;
    for %seen.keys -> $k { %mine{$k} = %seen{$k} if (%seen{$k}<label> // '') eq @ids[$e] }
    cache-save(@ids[$e], %mine) if %mine;
    @obs.push: %seen;
}

my %again = cache-load(@ids[0] ~ '-again');
my @re = @all.grep({ !%again{$_} });
if @re {
    say "# re-probing { @ids[0] }: { @re.elems } cells, to check the observations reproduce …";
    my %fresh = run-parallel(@engines[0], @re, $VALUE-PROBE, $JOBS, 200, 120, $TMP.add("mm-cache-{@ids[0]}-again.tsv").absolute);
    for %fresh.keys -> $k { %again{$k} = %fresh{$k} }
    cache-save(@ids[0] ~ '-again', %again);
}

my $ref = @obs[0];

# --- step 4: write one atom per type ----------------------------------------

my $outdir = $ROOT.add('generated/types');
$outdir.mkdir unless $outdir.e;

my $written = 0;
my $parked  = 0;

for %TYPES.keys.sort -> $t {
    next unless %cells{$t};
    my @out;
    @out.push: "atom     methods/$t";
    @out.push: "source   generated";
    @out.push: "gen      gen/methods.raku";
    @out.push: "kind     method matrix — every nullary method the type reports";
    @out.push: "axes     { %methods{$t}.join(' | ') }";
    @out.push: "cols     { %TYPES{$t}.join(' | ') }";
    @out.push: '';

    my $i = 0;
    for %cells{$t}.list -> %c {
        $i++;
        my $r = $ref{%c<expr>};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   inventory:{ $t }.^methods";
        @out.push: "  cell   { %c<method> } | { %c<value> }";
        @out.push: "  code   { %c<expr> }";

        my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG'
                         || $r<value> eq 'UNRENDERABLE');

        # Some values describe WHERE they were evaluated rather than what they
        # are: `.file` on a block renders as EVAL_59 under a probe and as a real
        # path in a dense program, and an object address renders as a long bare
        # integer. Both reproduce perfectly across identical probe runs — they
        # are stable and still worthless as expectations, so the reproducibility
        # check cannot see them. Match them by shape instead.
        #
        # The deeper fix is for probes to execute the way the harness does,
        # rather than through EVAL. That removes this class at the root.
        my $portable = !($r<value> ~~ / 'EVAL_' \d+ /
                      || $r<value>.contains('<anon|')
                      || $r<value>.contains($ROOT.Str)
                      || $r<value> ~~ /^ \d ** 12..* $/);
        my $stable = %again{%c<expr>} && %again{%c<expr>}<value> eq $r<value>;

        my $ruling = %RULED{%c<expr>};

        if $r<value>.starts-with('ERR:') {
            @out.push: "  throws { $r<value>.substr(4) }";
        }
        elsif $ruling {
            @out.push: "  is     { $ruling<is> }";
            @out.push: "  type   { $r<type> }";
        }
        else {
            @out.push: "  is     { textual($r<value>) }";
            @out.push: "  type   { $r<type> }";
        }

        for ^@engines -> $e {
            my $o = @obs[$e]{%c<expr>};
            next unless $o;
            @out.push: "  oracle { @ids[$e] } → { textual($o<value>) }";
        }

        if $ruling {
            @out.push: "  verdict impl-bug";
            @out.push: "  why    { $ruling<why> }";
            @out.push: "  ruled  2026-08-16 against { @ids[0] }";
        }
        elsif !$portable {
            @out.push: "  verdict disputed";
            @out.push: "  why    the value describes where it was evaluated (an EVAL frame name, a path, an object address) rather than what it is, so it is stable under the probe and still not an expectation";
            @out.push: "  ruled  2026-08-16 against { @ids[0] }";
            $parked++;
        }
        elsif !$answered {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference produced no usable answer for this cell";
            @out.push: "  ruled  2026-08-15 against { @ids[0] }";
            $parked++;
        }
        elsif !$stable {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference answers differently on two identical runs, so there is nothing stable to assert";
            @out.push: "  ruled  2026-08-15 against { @ids[0] }";
            $parked++;
        }
        @out.push: '';
        $written++;
    }

    $outdir.add("methods-$t.grid").spurt(@out.join("\n"));
}

say "# wrote $written cells across { %cells.elems } types, $parked parked";
