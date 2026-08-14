#!/usr/bin/env raku
# gen/import-regression.raku — import a repository's regression programs.
#
#   rakupp gen/import-regression.raku --from=/path/to/rakupp/t/regression \
#                                     --engines=raku,/path/to/rakupp
#
# Each program becomes one curated record under atoms/regression/, keeping the
# source verbatim — the header comments are the provenance narrative and are
# worth more than the code.
#
# These are whole programs, not atoms, and they are labelled as such. They earn
# their place because each one is a minimal repro of a bug that was actually
# found and actually fixed. Reducing them into proper atoms is later work; the
# `from` line survives that move.
#
# Where the reference implementation cannot run a program at all — it needs
# modules that are not installed, or exercises something only one engine has —
# the record is PARKED with a signed `disputed` verdict rather than asserting
# the other engine's behaviour by default. A suite must not quietly promote
# "the only engine that ran it" into "correct".

my $ROOT = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP  = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

sub run-guarded($cmd, @args, $secs, $cwd = '') {
    my $line = ([$cmd, |@args].map({ sh-quote($_) })).join(' ');
    $line = "cd { sh-quote($cwd) } && $line" if $cwd;

    # Files, not pipes — a killed program can leave a grandchild holding an
    # inherited pipe, and the read then waits for an EOF that never arrives.
    my $base = $TMP.add('guard-' ~ $*PID ~ '-' ~ $GUARD++);
    my $o = $base.absolute ~ '.out';
    my $e = $base.absolute ~ '.err';

    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($o) } 2> { sh-quote($e) } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit \$rc";

    my $p = run('/bin/sh', '-c', $script);
    my $out = $o.IO.e ?? $o.IO.slurp !! '';
    my $err = $e.IO.e ?? $e.IO.slurp !! '';
    $o.IO.unlink if $o.IO.e;
    $e.IO.unlink if $e.IO.e;
    return { out => $out, err => $err, exit => $p.exitcode };
}

sub engine-id($cmd) {
    my $p = run($cmd, '-e', 'print $*RAKU.compiler.name', :out, :err);
    my $name = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);

    if $name.contains('Raku++') || $name.lc.contains('rakupp') {
        my $v = run($cmd, '--version', :out, :err);
        my $text = $v.out.slurp(:close);
        $v.err.slurp(:close);
        my $ver = $text ~~ /(\d+ '.' \d+ '.' \d+)/ ?? ~$0 !! 'unknown';
        return "rakupp-$ver";
    }

    my $p2 = run($cmd, '-e', 'print $*RAKU.compiler.version', :out, :err);
    my $ver = $p2.out.slurp(:close).trim;
    $p2.err.slurp(:close);
    return ($name || 'unknown') ~ '-' ~ ($ver || 'unknown');
}

# One line describing what an engine did with a whole program.
sub observation(%g, $secs) {
    return "TIMEOUT after {$secs}s" if %g<exit> == 137;
    return "exit { %g<exit> }"      if %g<exit> != 0;
    my $out = %g<out>.chomp;
    return 'no output'              if $out eq '';
    return $out.lines == 1 ?? $out !! $out.lines[0] ~ " …({ $out.lines.elems } lines)";
}

sub indent-block($text) {
    return $text.lines.map({ $_ eq '' ?? '' !! '    ' ~ $_ }).join("\n");
}

# ------------------------------------------------------------------------ run

my $FROM = '/Users/ash/raku++/t/regression';
my @engines = 'raku';
my $BUDGET = 20;

for @*ARGS -> $a {
    $FROM    = $a.substr(7)          if $a.starts-with('--from=');
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $BUDGET  = +$a.substr(9)         if $a.starts-with('--budget=');
}

my $src = $FROM.IO;
die "no such directory: $FROM" unless $src.d;

my @files = $src.dir.grep({ .extension eq 'raku' }).sort;
say "# { @files.elems } programs in $FROM";

my @ids = @engines.map({ engine-id($_) });
say "# engines: { @ids.join(', ') }";

# A few programs `use lib $?FILE.IO.parent.parent.add('fixtures')`. Bring the
# fixtures along so the suite stands on its own rather than reaching back into
# the repository it was imported from.
sub copy-tree($from, $to) {
    $to.mkdir unless $to.e;
    my $n = 0;
    for $from.dir -> $e {
        if $e.d {
            $n += copy-tree($e, $to.add($e.basename));
        }
        else {
            $to.add($e.basename).spurt($e.slurp(:bin));
            $n++;
        }
    }
    return $n;
}

my $fixsrc = $src.parent.add('fixtures');
if $fixsrc.d {
    my $n = copy-tree($fixsrc, $ROOT.add('fixtures'));
    say "# copied $n fixture files";
}

my $outdir = $ROOT.add('atoms/regression');
$outdir.mkdir unless $outdir.e;

# The staging directory mirrors what `rakugrid fire` uses: tmp/run, with
# fixtures one level up.
my $stage = $ROOT.add('tmp/run');
$ROOT.add('tmp').mkdir unless $ROOT.add('tmp').e;
$stage.mkdir unless $stage.e;
my $link = $ROOT.add('tmp/fixtures');
if !$link.e && $ROOT.add('fixtures').d {
    run('ln', '-s', $ROOT.add('fixtures').absolute, $link.absolute, :out, :err);
}

my $clean  = 0;
my $parked = 0;

for @files -> $f {
    my $name = $f.basename.subst(/'.raku' $/, '');
    my $code = $f.slurp;

    # Capture the oracle from the SAME staged location the harness will run the
    # record from. Running it in place instead would record an observation the
    # test can never reproduce: a program that resolves `use lib` relative to
    # its own path behaves differently once it is staged elsewhere, and the
    # expectation would then be captured under conditions that never recur.
    my $staged = $stage.add($f.basename);
    $staged.spurt($code);

    my @obs;
    my $elapsed = 0;
    for @engines -> $e {
        my $t0 = now;
        @obs.push: run-guarded($e, [$staged.absolute], $BUDGET, $stage.absolute);
        my $took = now - $t0;
        $elapsed = $took if $took > $elapsed;
    }

    # The budget is MEASURED, not guessed. A fixed ceiling makes a program that
    # re-invokes the interpreter a few times pass or fail depending on how busy
    # the machine is, and a flaky test is worse than no test.
    my $budget = ($elapsed * 4).ceiling;
    $budget = $BUDGET if $budget < $BUDGET;

    # These programs declare their own contract in a header comment: exit 0 and
    # a last line of PASS. Exit 0 alone is not enough — several print `FAIL:`
    # lines and still exit 0 under an engine that lacks the feature, and taking
    # that as the expectation would enshrine the failure as correct.
    my $ref      = @obs[0];
    my @ref-out  = $ref<out>.chomp.lines;
    my $runnable = $ref<exit> == 0 && @ref-out && @ref-out[*-1] eq 'PASS';
    my $expected = $runnable ?? $ref<out>.chomp !! 'PASS';

    my @out;
    @out.push: "atom     regression/$name";
    @out.push: "source   curated";
    @out.push: "kind     whole-program — a minimal repro, not yet reduced to an atom";
    @out.push: '';
    @out.push: "- id     0001";
    @out.push: "  from   rakupp:t/regression/{ $f.basename }";
    @out.push: "  budget {$budget}s";
    @out.push: "  code";
    @out.push: indent-block($code);

    if $expected.lines > 1 {
        @out.push: "  output";
        @out.push: indent-block($expected);
    }
    else {
        @out.push: "  output $expected";
    }

    for ^@engines -> $e {
        @out.push: "  oracle { @ids[$e] } → { observation(@obs[$e], $BUDGET) }";
    }

    if $runnable {
        $clean++;
    }
    else {
        @out.push: "  verdict disputed";
        @out.push: "  why    the reference implementation does not satisfy the program's own contract here (exit 0 with a last line of PASS) — it needs modules that are not installed, or exercises something only one engine implements; there is no reference observation to rule against";
        @out.push: "  ruled  2026-08-14 against { @ids[0] }";
        $parked++;
    }
    @out.push: '';

    $outdir.add("$name.grid").spurt(@out.join("\n"));
}

say "# wrote { @files.elems } records: $clean active, $parked parked";
