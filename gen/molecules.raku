#!/usr/bin/env raku
# gen/molecules.raku — the interaction layer: constructs that each work alone.
#
#   rakupp gen/molecules.raku --engines=raku,/path/to/rakupp
#
# Every ladder cell tests ONE construct. This tests CROSSINGS, because that is
# where our hard bugs actually lived: `return` inside `CATCH` yielding Nil,
# `next` inside `.map` escaping to the enclosing loop, a method losing `return`
# inside a loop. Each of those needed two facets to reproduce and none is
# reachable by testing either construct alone.
#
# The first cross is Exit × Nesting — the two axes that produced most of the
# defect record. A cell is a small program written from a template, so it is
# well-formed by construction rather than by string-splicing.
#
# Cells are ORDER-SENSITIVE: ids come from position, so new levels must be
# APPENDED to the axis, never inserted.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

# --- the axes ---------------------------------------------------------------

# Where the exit happens. `{X}` is the exit statement; each skeleton is an
# EXPRESSION, so its value is what the crossing actually produced.
# A crossing is two axes: `rows` carry the skeleton with a `{X}` hole, `cols`
# carry what goes in it. `{U}` becomes a per-cell unique suffix so cells cannot
# collide once they are packed into one file.
constant @CROSSINGS =

# ---------------------------------------------------------------------------
# Exit × Nesting — the two axes behind most of the defect record: `return`
# inside CATCH yielding Nil, `next` in .map escaping to the enclosing loop, a
# method losing `return` inside a loop.
{
    name => 'exit-nesting',
    rows => [
        { name => 'sub-body',      form => 'do { sub f() { {X}; "fell" }; f() }' },
        { name => 'method-body',   form => 'do { class C{U} { method m() { {X}; "fell" } }; C{U}.new.m }' },
        { name => 'bare-block',    form => 'do { {X}; "fell" }' },
        { name => 'loop-body',     form => 'do { my @r; for 1..3 { {X}; @r.push("b") }; @r.join(",") }' },
        { name => 'loop-in-sub',   form => 'do { sub f() { for 1..3 { {X} }; "end" }; f() }' },
        { name => 'gather',        form => 'do { gather { {X}; take "after" }.list.raku }' },
        { name => 'catch',         form => 'do { sub f() { die "boom"; CATCH { default { {X} } } }; f() }' },
        { name => 'map-body',      form => 'do { (1..3).map({ {X}; $_ }).list.raku }' },
        { name => 'map-in-loop',   form => 'do { my @r; for 1..2 { @r.push((1..3).map({ {X}; $_ }).elems) }; @r.join(",") }' },
        { name => 'given-when',    form => 'do { given 1 { when 1 { {X}; "w" }; "after" } }' },
        { name => 'leave-phaser',  form => 'do { sub f() { LEAVE { {X} }; "body" }; f() }' },
        { name => 'thunk-rhs',     form => 'do { my $v = False || do { {X}; "x" }; $v }' },
        { name => 'sort-callback', form => 'do { (3,1,2).sort({ {X}; $^a <=> $^b }).list.raku }' },
        { name => 'nested-blocks', form => 'do { my $v = do { do { {X}; "inner" } }; $v }' },
    ],
    cols => [
        { name => 'fall-through', stmt => '1'           },
        { name => 'return',       stmt => 'return "R"'  },
        { name => 'last',         stmt => 'last'        },
        { name => 'next',         stmt => 'next'        },
        { name => 'die',          stmt => 'die "D"'     },
        { name => 'take',         stmt => 'take "T"'    },
        { name => 'fail',         stmt => 'fail "F"'    },
        { name => 'succeed',      stmt => 'succeed "S"' },
        { name => 'emit',         stmt => 'emit "E"'    },
        { name => 'warn',         stmt => 'warn "W"'    },
    ],
},

# ---------------------------------------------------------------------------
# Container × Dispatch — does a writable parameter write back, and does the
# answer survive the call form? This is the family behind "rw params do not
# write back through multis": the parameter mode works, the dispatch works, and
# the crossing does not.
{
    name => 'writeback-dispatch',
    rows => [
        { name => 'sub',        form => 'do { sub f($v {X}) { $v = "set" }; my $x = "orig"; f($x); $x }' },
        { name => 'multi',      form => 'do { multi g{U}($v {X}) { $v = "set" }; my $x = "orig"; g{U}($x); $x }' },
        { name => 'method',     form => 'do { class K{U} { method m($v {X}) { $v = "set" } }; my $x = "orig"; K{U}.new.m($x); $x }' },
        { name => 'code-ref',   form => 'do { sub f($v {X}) { $v = "set" }; my $x = "orig"; my &c = &f; c($x); $x }' },
        { name => 'scalar-ref', form => 'do { sub f($v {X}) { $v = "set" }; my $x = "orig"; my $c = &f; $c($x); $x }' },
        { name => 'dot-amp',    form => 'do { sub f($v {X}) { $v = "set" }; my $x = "orig"; $x.&f; $x }' },
        { name => 'pointy',     form => 'do { my &b = -> $v {X} { $v = "set" }; my $x = "orig"; b($x); $x }' },
        { name => 'through-two', form => 'do { sub inner($v {X}) { $v = "set" }; sub outer($w {X}) { inner($w) }; my $x = "orig"; outer($x); $x }' },
    ],
    cols => [
        { name => 'plain',    stmt => ''         },
        { name => 'is-rw',    stmt => 'is rw'    },
        { name => 'is-copy',  stmt => 'is copy'  },
        { name => 'is-raw',   stmt => 'is raw'   },
    ],
},

# ---------------------------------------------------------------------------
# Declarator × Nesting — a `state` variable keeps its value between calls, and
# where it is DECLARED decides which calls those are. The same question for
# `my`, `our`, a constant and a dynamic.
{
    name => 'declarator-nesting',
    rows => [
        { name => 'sub-body',    form => 'do { sub f() { {X} $n{U} = 0; $n{U}++; $n{U} }; f(); f() }' },
        { name => 'method-body', form => 'do { class D{U} { method m() { {X} $n{U} = 0; $n{U}++; $n{U} } }; my $o = D{U}.new; $o.m; $o.m }' },
        { name => 'bare-block',  form => 'do { my $r; for 1..2 { {X} $n{U} = 0; $n{U}++; $r = $n{U} }; $r }' },
        { name => 'loop-body',   form => 'do { my @r; for 1..3 { {X} $n{U} = 0; $n{U}++; @r.push($n{U}) }; @r.join(",") }' },
        { name => 'map-body',    form => 'do { (1..3).map({ {X} $n{U} = 0; $n{U}++; $n{U} }).list.raku }' },
        { name => 'nested-sub',  form => 'do { sub outer() { sub inner() { {X} $n{U} = 0; $n{U}++; $n{U} }; inner(); inner() }; outer() }' },
        { name => 'gather',      form => 'do { gather { for 1..2 { {X} $n{U} = 0; $n{U}++; take $n{U} } }.list.raku }' },
        { name => 'thunk-rhs',   form => 'do { my @r; for 1..2 { @r.push(False || do { {X} $n{U} = 0; $n{U}++; $n{U} }) }; @r.join(",") }' },
    ],
    cols => [
        { name => 'state',    stmt => 'state'    },
        { name => 'my',       stmt => 'my'       },
        { name => 'our',      stmt => 'our'      },
        { name => 'constant', stmt => 'constant' },
    ],
};

# --- probing ----------------------------------------------------------------

# TWO probes, in two processes, on purpose. Compiling `sub { EXPR }` to see
# whether EXPR compiles also DECLARES anything EXPR declares — so a cell
# containing `class C {…}` was being declared once by the compile check and
# again by the evaluation, and every such cell reported a redeclaration that
# exists only inside the probe.
constant $PROBE-COMPILE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $expr {
        try EVAL "sub \{ $expr \}";
        if $! {
            say join("\t", $expr, 'NOCOMPILE', '-', ($!.message.lines[0] // '').subst("\t", ' ', :g));
        }
        else {
            say join("\t", $expr, 'COMPILES', '-', '');
        }
        $*OUT.flush;
    }
    END

constant $PROBE-VALUE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $expr {
        my $r = try EVAL $expr;
        if $! {
            say join("\t", $expr, 'ERR:' ~ $!.^name, '-');
        }
        else {
            say join("\t", $expr, $r.raku, $r.WHAT.^name);
        }
        $*OUT.flush;
    }
    END

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

sub run-sh($line, $secs) {
    my $base = $TMP.add('mol-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit \$rc";
    my $p = run('/bin/sh', '-c', $script);
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    my $err = ($base ~ '.err').IO.e ?? ($base ~ '.err').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;
    return { out => $out, err => $err, exit => $p.exitcode };
}

sub run-batch($cmd, @exprs, $secs = 180, $src = $PROBE-VALUE) {
    my $probe = $TMP.add('mol-probe.raku');
    my $list  = $TMP.add('mol-exprs.txt');
    $probe.spurt($src);
    $list.spurt(@exprs.join("\n") ~ "\n");

    my %g = run-sh("{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) }", $secs);
    my %by;
    for %g<out>.lines -> $l {
        my @f = $l.split("\t");
        next unless @f >= 3;
        %by{@f[0]} = { value => @f[1], type => @f[2], msg => (@f[3] // '') };
    }
    return { seen => %by, exit => %g<exit> };
}

# A crossing can loop forever — `redo` is the obvious one, but so is any exit
# that restarts its own block. Resume past whatever killed the run rather than
# recording the rest as a silent gap.
sub observe($cmd, @exprs, $src = $PROBE-VALUE) {
    my %seen;
    my @todo = @exprs;
    while @todo {
        my %r = run-batch($cmd, @todo, 180, $src);
        for @todo -> $e {
            %seen{$e} = %r<seen>{$e} if %r<seen>{$e};
        }
        my @missing = @todo.grep({ !%seen{$_} });
        last unless @missing;
        my $bad  = @missing[0];
        my %solo = run-batch($cmd, [$bad], 15, $src);
        %seen{$bad} = %solo<seen>{$bad}
            // { value => (%solo<exit> == 137 ?? 'HANG' !! 'CRASH:' ~ %solo<exit>), type => '-', msg => '' };
        note "#   no answer for: $bad" unless %solo<seen>{$bad};
        @todo = @missing.elems > 1 ?? @missing[1 .. *] !! [];
    }
    return %seen;
}

# EVAL is not a file. Confirm every compile-failure candidate the way the
# harness will actually compile it.
sub probe-file($cmd, $expr) {
    my $f = $TMP.add('mol-confirm.raku');
    $f.spurt("my \$r = try \{ $expr \};\n"
           ~ "if \$\! \{ say 'ERR:' ~ \$\!.^name ~ \"\\t-\" \}\n"
           ~ "else \{ say \$r.raku ~ \"\\t\" ~ \$r.WHAT.^name \}\n");

    my %c = run-sh("{ sh-quote($cmd) } -c { sh-quote($f.absolute) }", 20);
    if %c<exit> != 0 {
        my $msg = (%c<err> ~ %c<out>).lines.grep({ .trim }).head(1).join(' ').subst("\t", ' ', :g);
        return { value => 'NOCOMPILE', type => '-', msg => $msg };
    }
    my %r = run-sh("{ sh-quote($cmd) } { sh-quote($f.absolute) }", 20);
    my @f2 = (%r<out>.lines[0] // '').split("\t");
    return { value => 'CRASH:' ~ %r<exit>, type => '-', msg => '' } unless @f2 >= 2;
    return { value => @f2[0], type => @f2[1], msg => '' };
}


# Cells share a file once they are packed into a dense program, so any name a
# skeleton introduces must be unique to its cell. `class C` in ten cells is ten
# redeclarations, and the tests then fail on each other rather than on the
# language.
sub expr-for(%c, %n, %x) {
    my $u = (%c<name> ~ '_' ~ %n<name> ~ '_' ~ %x<name>).subst('-', '_', :g);
    return %n<form>.subst('{X}', %x<stmt>, :g).subst('{U}', $u, :g);
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
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
}
my @ids = @engines.map({ engine-id($_) });

my @all;
for @CROSSINGS -> %c {
    for %c<rows>.list -> %n {
        for %c<cols>.list -> %x {
            @all.push: expr-for(%c, %n, %x);
        }
    }
}
@all = @all.unique;

say "# { @CROSSINGS.elems } crossings, { @all.elems } cells";
for @CROSSINGS -> %c {
    say "#   { %c<name> }: { %c<rows>.elems } × { %c<cols>.elems }";
}
say "# engines: { @ids.join(', ') }";

my @obs;
for @engines -> $e {
    say "# probing $e …";
    my %v = observe($e, @all);
    my %c = observe($e, @all, $PROBE-COMPILE);
    for @all -> $x {
        if %c{$x} && %c{$x}<value> eq 'NOCOMPILE' {
            %v{$x} = { value => 'NOCOMPILE', type => '-', msg => (%c{$x}<msg> // '') };
        }
    }
    @obs.push: %v;
}

# A cell the batch probe could not answer is a CANDIDATE too, not a dead end.
# `last` outside a loop kills the probe process, but it is a clean compile-time
# error in a real file — parking it would have hidden a perfectly good test.
my @candidates = @all.grep({
    my $v = @obs[0]{$_} ?? @obs[0]{$_}<value> !! '';
    $v eq 'NOCOMPILE' || $v.starts-with('CRASH') || $v eq 'HANG'
});
if @candidates {
    say "# confirming { @candidates.elems } compile-failure candidates against real files …";
    my $overturned = 0;
    for @candidates -> $expr {
        for ^@engines -> $e {
            my %real = probe-file(@engines[$e], $expr);
            $overturned++ if $e == 0 && %real<value> ne 'NOCOMPILE';
            @obs[$e]{$expr} = %real;
        }
    }
    say "#   $overturned were EVAL artefacts" if $overturned;
}

say "# re-probing { @ids[0] } to check the observations reproduce …";
my %again = observe(@engines[0], @all);
for @candidates -> $e {
    %again{$e} = @obs[0]{$e};
}

my $ref = @obs[0];
# ONE atom per crossing: the crossing IS the thing under test, so its whole
# grid belongs in a single file where `rakugrid matrix` can render it and a hole
# is visible at a glance.
my $outdir = $ROOT.add('molecules');
$outdir.mkdir unless $outdir.e;

my $written = 0;
my $parked  = 0;

for @CROSSINGS -> %c {
    my @out;
    @out.push: "atom     molecules/{ %c<name> }";
    @out.push: "source   generated";
    @out.push: "gen      gen/molecules.raku";
    @out.push: "facets   { %c<name>.subst('-', ' × ') }";
    @out.push: "axes     { %c<rows>.map(*<name>).join(' | ') }";
    @out.push: "cols     { %c<cols>.map(*<name>).join(' | ') }";
    @out.push: '';

    my $i = 0;
    for %c<rows>.list -> %n {
        for %c<cols>.list -> %x {
            $i++;
            my $expr = expr-for(%c, %n, %x);
            my $r = $ref{$expr};
            next unless $r;

            @out.push: "- id     { sprintf('%04d', $i) }";
            @out.push: "  from   molecule:{ %c<name> }";
            @out.push: "  cell   { %n<name> } | { %x<name> }";
            @out.push: "  facets row={ %n<name> } col={ %x<name> }";

            my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG');
            my $stable   = %again{$expr} && %again{$expr}<value> eq $r<value>;

            if $r<value> eq 'NOCOMPILE' {
                @out.push: "  code   sub \{ $expr \}";
                @out.push: "  no-parse the crossing does not compile";
            }
            elsif $r<value>.starts-with('ERR:') {
                @out.push: "  code   $expr";
                @out.push: "  throws { $r<value>.substr(4) }";
            }
            else {
                @out.push: "  code   $expr";
                @out.push: "  is     { $r<value> }";
                @out.push: "  type   { $r<type> }";
            }

            for ^@engines -> $e {
                my $o = @obs[$e]{$expr};
                next unless $o;
                my $obs = $o<value> eq 'NOCOMPILE' && $o<msg> ?? 'NOCOMPILE: ' ~ $o<msg> !! $o<value>;
                @out.push: "  oracle { @ids[$e] } → $obs";
            }

            if !$answered {
                @out.push: "  verdict disputed";
                @out.push: "  why    the reference produced no usable answer for this crossing (it crashed or did not terminate)";
                @out.push: "  ruled  2026-08-14 against { @ids[0] }";
                $parked++;
            }
            elsif !$stable {
                @out.push: "  verdict disputed";
                @out.push: "  why    the reference answers differently on two identical runs, so there is nothing stable to assert";
                @out.push: "  ruled  2026-08-14 against { @ids[0] }";
                $parked++;
            }
            @out.push: '';
            $written++;
        }
    }

    $outdir.add("{ %c<name> }.grid").spurt(@out.join("\n"));
}

say "# wrote $written crossings, $parked parked";
