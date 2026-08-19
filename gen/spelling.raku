#!/usr/bin/env raku
# gen/spelling.raku — the spelling grid: does an operator mean the same thing
# however it is written?
#
#   rakupp gen/spelling.raku --engines=raku,/path/to/rakupp [--jobs=6]
#
# Every other operator generator parenthesises both operands — `(1) * (2)` —
# and GENERATORS.md explains why: without the parens `1/2 ** 2` reads as
# `1/(2**2)` and a cell silently tests something other than what its label says.
# That safeguard is right, and it has a cost nobody was paying attention to:
# `(1) * (2)` is not the spelling real programs contain, and until this
# generator existed not one of the suite's 102,809 tests exercised `1 * 2` or
# `1*2`. An engine whose lexer wrongly accepted `1eq2`, or wrongly rejected
# `1-1`, passed everything.
#
# So the parens stay where the semantics are asserted, and spelling becomes an
# axis of its own. Three ways to write the same crossing:
#
#     ({A}) {OP} ({B})     the baseline — what the other generators assert
#     {A} {OP} {B}         spaced and bare
#     {A}{OP}{B}           tight
#
# and three things can be true of a bare spelling:
#
#   * it does not compile        → `no-parse`. All 38 word-like infixes are
#                                  here for the tight spelling: `1eq2` and
#                                  `1x3` are not operators, they are confused
#                                  identifiers, and an engine that accepts them
#                                  is broken in a way no value test can see.
#   * it compiles and agrees     → `same-as` the parenthesised form. This needs
#                                  NO oracle: an engine that disagrees with
#                                  ITSELF across two spellings is wrong without
#                                  anyone deciding what the right answer was.
#   * it compiles and differs    → the spelling changed the parse, which is a
#                                  fact worth pinning down rather than hiding.
#                                  The record asserts the VALUE the bare
#                                  spelling actually produces, so the precedence
#                                  difference is permanent and visible.
#
# Two safeguards from the others carry over, and one is new:
#
#   * Compile failures are confirmed against a REAL FILE with `-c`, never under
#     EVAL — of 38 compile failures flagged by EVAL elsewhere in this repo, 28
#     were EVAL artefacts. EVAL is used only for the value question, and only
#     after a file has already settled the legality question.
#   * The file compiled here is byte-for-byte the `code` field the harness will
#     later compile for a `no-parse` record, so the generator and the harness
#     cannot disagree about what was tested.
#   * Every cell is probed TWICE and parked if the two runs differ, because a
#     spelling test that is flaky by construction is worse than no test.
#
# Operand pairs are chosen for their LEXICAL SHAPES, not their values — what
# decides whether a tight spelling lexes is the character either side of the
# operator, so the pairs end and begin with a digit, a minus, a quote and a
# paren. Pairs and spellings are ORDER-SENSITIVE: ids come from position in the
# cross, so new ones must be APPENDED, never inserted.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

# Lexical shapes, not values: digit·digit, digit·minus, quote·quote, paren·paren.
constant @PAIRS =
    { a => '1',     b => '2',    note => 'digit · digit' },
    { a => '1',     b => '-1',   note => 'digit · minus' },
    { a => '"a"',   b => '"b"',  note => 'quote · quote' },
    { a => '(1,2)', b => '(3,)', note => 'paren · paren' };

constant @SPELLINGS =
    { key => 'spaced', note => 'spaced and bare' },
    { key => 'tight',  note => 'no whitespace at all' };

# A standing ruling of this suite: unspecified order is never asserted. The set
# and hash types render their elements in whatever order the implementation
# iterates them, so two runs of ONE engine disagree with each other and a cell
# built from either answer is flaky by construction. The double-probe below
# catches them by accident and would park a different subset every run, which
# also makes the generator non-deterministic; naming the types instead makes the
# outcome stable and states the actual reason.
constant %UNORDERED = <Set SetHash Bag BagHash Mix MixHash Hash Map QuantHash>.Set;

sub order-unspecified($type, $value) {
    return True if %UNORDERED{$type};
    return True if $value.contains('Set.new(') || $value.contains('.Bag')
                || $value.contains('.Mix')     || $value.contains('.Set');
    return False;
}

sub spell($key, $a, $op, $b) {
    return "($a) $op ($b)" if $key eq 'paren';
    return "$a $op $b"     if $key eq 'spaced';
    return "$a$op$b";
}

sub sh-quote($s) { return "'" ~ $s.subst("'", "'\\''", :g) ~ "'" }

# ------------------------------------------------------------------ engine id

sub engine-id($cmd) {
    my $p = run($cmd, '-e', 'print $*RAKU.compiler.name', :out, :err);
    my $name = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);

    # Prefer the BUILD over the version: a development build changes behaviour
    # without changing its version, and a `-dirty` build is not reproducible
    # from its commit alone — an observation recorded against one should say so.
    my $b = run($cmd, '-e', 'print (try $*RAKU.compiler.build) // ""', :out, :err);
    my $build = $b.out.slurp(:close).trim;
    $b.err.slurp(:close);

    my $short = $name.contains('Raku++') || $name.lc.contains('rakupp')
        ?? 'rakupp' !! ($name || 'unknown');
    return "$short-$build" if $build;

    my $p2 = run($cmd, '-e', 'print $*RAKU.compiler.version', :out, :err);
    my $ver = $p2.out.slurp(:close).trim;
    $p2.err.slurp(:close);
    return ($name || 'unknown') ~ '-' ~ ($ver || 'unknown');
}

# --------------------------------------------------------- the inventory list

# The operator list comes from the atoms the inventory generator already wrote,
# which came from the documentation. Reading it here rather than re-extracting
# keeps the two families over exactly the same set of operators.
sub infix-operators() {
    my @ops;
    my $dir = $ROOT.add('generated/inventory');
    die "no generated/inventory — run gen/operators.raku first" unless $dir.e;
    for $dir.dir.grep(*.extension eq 'grid').sort -> $f {
        my $head = $f.lines.head(8).join("\n");
        next unless $head ~~ /^^ 'from-inventory' \s+ 'infix' \s+ (\S+) \s* $$/;
        @ops.push: { file => $f.basename.subst(/'.grid'$/, ''), op => ~$0 };
    }
    return @ops;
}

# ------------------------------------------------------- compile, on a file

# One process per candidate, on a real file, with `-c`. This is the expensive
# half and the only half that may decide legality — see the header.
sub compile-batch($cmd, @exprs, $jobs, $secs = 30) {
    my %rc;
    my $i = 0;
    while $i < @exprs.elems {
        my @cmds;
        my @slots;
        for ^$jobs -> $j {
            last if $i + $j >= @exprs.elems;
            my $expr = @exprs[$i + $j];
            my $src  = $TMP.add("spell-$j.raku");
            # Exactly what the harness will compile for a no-parse record —
            # the bare expression, with the trailing newline it stores.
            $src.spurt($expr ~ "\n");
            my $rc = $TMP.add("spell-rc-$j.txt");
            $rc.unlink if $rc.e;
            @slots.push: { expr => $expr, rc => $rc };
            @cmds.push: "\{ { sh-quote($cmd) } -c { sh-quote($src.absolute) } >/dev/null 2>&1; "
                      ~ "echo \$? > { sh-quote($rc.absolute) }; \} &";
        }
        last unless @cmds;

        # `exec >/dev/null 2>&1` FIRST, and it is not cosmetic: without it the
        # backgrounded compile jobs inherit this program's stdout, and an
        # orphan left behind by the watchdog holds that pipe open forever. A
        # run wedged for ten hours that way — the generator had long finished
        # and the reader upstream was still waiting for EOF. `set -m` puts the
        # batch in its own process group so the watchdog can kill the group
        # rather than just the shell that spawned it.
        my $script = @cmds.join(' ') ~ ' wait';
        # A killed batch makes `sh` exit non-zero, and a sunk Proc THROWS on
        # that. Capture the code instead of letting it end the run.
        my $proc = run('/bin/sh', '-c',
            "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
          ~ "( $script ) & p=\$!; "
          ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
          ~ "wait \$p; kill \$w 2>/dev/null; wait \$w 2>/dev/null; exit 0");
        my $ignored = $proc.exitcode;

        for @slots -> %s {
            %rc{%s<expr>} = %s<rc>.e ?? (%s<rc>.slurp.trim eq '0') !! False;
            %s<rc>.unlink if %s<rc>.e;
        }
        $i += @slots.elems;
        note "#     compiled { $i } / { @exprs.elems }" if $i %% 200 || $i >= @exprs.elems;
    }
    return %rc;
}

# ------------------------------------------------- value, and agreement

# EVAL is used ONLY here, and only for expressions a real file has already
# accepted. It answers what the spelling produces and whether that is what the
# parenthesised form produces — the same comparison `fire` makes for `same-as`.
constant $PROBE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $line {
        my ($cand, $base) = $line.split("\x[1F]");
        my $a  = try EVAL $cand;
        my $e1 = $! ?? $!.^name !! '';
        my $b  = try EVAL $base;
        my $e2 = $! ?? $!.^name !! '';
        my $same = $e1 eq $e2 && (!$e1 ?? $a.raku eq $b.raku !! True);
        say join("\t", $line, $same ?? 'AGREE' !! 'DIFFER',
                 $e1 ?? 'ERR:' ~ $e1 !! $a.raku,
                 $e1 ?? '-' !! $a.WHAT.^name);
        $*OUT.flush;
    }
    END

sub value-probe($cmd, @pairs, $secs = 300) {
    my $probe = $TMP.add('spell-probe.raku');
    my $list  = $TMP.add('spell-pairs.txt');
    $probe.spurt($PROBE);
    $list.spurt(@pairs.join("\n") ~ "\n");

    my $base = $TMP.add('spell-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $line = "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) }";
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2>/dev/null & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; kill \$w 2>/dev/null; exit 0";
    run('/bin/sh', '-c', $script);

    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;

    my %r;
    for $out.lines -> $l {
        my @f = $l.split("\t");
        next unless @f >= 4;
        %r{@f[0]} = { verdict => @f[1], value => @f[2], type => @f[3] };
    }
    return %r;
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
my $JOBS = 6;
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $JOBS    = +$a.substr(7)            if $a.starts-with('--jobs=');
}
my @ids = @engines.map({ engine-id($_) });

my @ops = infix-operators();
say "# { @ops.elems } infix operators × { @PAIRS.elems } operand pairs × { @SPELLINGS.elems } bare spellings";
say "# engines: { @ids.join(', ') }";

# Every cell, in a fixed order: operator, then pair, then spelling. Ids come
# from this order and are permanent.
my @cells;
for @ops -> %o {
    for @PAIRS -> %p {
        for @SPELLINGS -> %s {
            @cells.push: {
                file  => %o<file>,
                op    => %o<op>,
                pair  => %p,
                spell => %s,
                cand  => spell(%s<key>, %p<a>, %o<op>, %p<b>),
                base  => spell('paren', %p<a>, %o<op>, %p<b>),
            };
        }
    }
}
say "# { @cells.elems } cells";

# Observations are cached per engine and reloaded, so a failure late in the run
# — or a second engine, or a widened pair list — costs only the new cells. The
# emit step above once died on its last line after both probe passes had
# finished, and without this that was the whole run.
sub cache-file($id) { return $TMP.add('spelling-cache-' ~ $id.subst(/<-[\w.+-]>/, '_', :g) ~ '.tsv') }

sub load-cache($id) {
    my %c = compiles => {}, value => {};
    my $f = cache-file($id);
    return %c unless $f.e;
    for $f.lines -> $l {
        my @x = $l.split("\t");
        next unless @x >= 3;
        if @x[0] eq 'C' { %c<compiles>{@x[1]} = @x[2] eq '1' }
        elsif @x[0] eq 'V' && @x >= 5 {
            %c<value>{@x[1]} = { verdict => @x[2], value => @x[3], type => @x[4] };
        }
    }
    return %c;
}

sub save-cache($id, %compiles, %value) {
    my @l;
    @l.push: "C\t$_\t{ %compiles{$_} ?? 1 !! 0 }" for %compiles.keys.sort;
    @l.push: "V\t$_\t{ %value{$_}<verdict> }\t{ %value{$_}<value> }\t{ %value{$_}<type> }"
        for %value.keys.sort;
    cache-file($id).spurt(@l.join("\n") ~ "\n");
}

my @obs;
for ^@engines -> $e {
    my %cached = load-cache(@ids[$e]);
    # The BASELINE is compile-checked as well. Without it a rejected bare
    # spelling reads as a lexer finding even when the parenthesised form is
    # equally illegal — `1:=2` does not compile, but neither does `(1) := (2)`,
    # and only the first of those is about spelling.
    my @want = (@cells.map(*<cand>).Slip, @cells.map(*<base>).Slip).unique.list;
    my @todo = @want.grep({ !(%cached<compiles>{$_}:exists) });
    say "# { @ids[$e] }: { @todo.elems } candidates to compile of { @want.elems } "
      ~ "({ @want.elems - @todo.elems } carried forward), $JOBS at a time …";
    my %compiles = %cached<compiles>;
    if @todo {
        my %fresh = compile-batch(@engines[$e], @todo, $JOBS);
        %compiles{$_} = %fresh{$_} for %fresh.keys;
    }

    my @live = @cells.grep({ %compiles{$_<cand>} }).map({ $_<cand> ~ "\x[1F]" ~ $_<base> }).unique;
    my @vtodo = @live.grep({ !(%cached<value>{$_}:exists) });
    say "#   { @live.elems } compile, { @cells.elems - @live.elems } are rejected — "
      ~ "{ @vtodo.elems } to probe twice, { @live.elems - @vtodo.elems } carried forward";
    my %v1 = %cached<value>;
    my %v2 = %cached<value>;
    if @vtodo {
        my %a = value-probe(@engines[$e], @vtodo);
        my %b = value-probe(@engines[$e], @vtodo);
        %v1{$_} = %a{$_} for %a.keys;
        %v2{$_} = %b{$_} for %b.keys;
    }

    my %flaky;
    for @live -> $k {
        next unless %v1{$k} && %v2{$k};
        %flaky{$k} = True unless %v1{$k}<verdict> eq %v2{$k}<verdict>
                              && %v1{$k}<value>   eq %v2{$k}<value>;
    }
    say "#   { %flaky.elems } cells answered differently on two identical runs — parked" if %flaky;

    # Only stable observations are cached; a flaky cell must be re-probed, not
    # frozen at whichever answer happened to be written down first.
    my %keep = %v1.keys.grep({ !%flaky{$_} }).map({ $_ => %v1{$_} }).Hash;
    save-cache(@ids[$e], %compiles, %keep);

    @obs.push: { compiles => %compiles, value => %v1, flaky => %flaky };
}

my $ref = @obs[0];
my $outdir = $ROOT.add('generated/spelling');
$outdir.mkdir unless $outdir.e;

my ($n-noparse, $n-same, $n-differs, $n-parked) = 0, 0, 0, 0;
my ($n-illegal, $n-baseonly, $n-unordered, $n-compsplit) = 0, 0, 0, 0;

for @ops -> %o {
    my @mine = @cells.grep({ $_<file> eq %o<file> });
    my @out;
    @out.push: "atom     spelling/{ %o<file> }";
    @out.push: "source   generated";
    @out.push: "gen      gen/spelling.raku";
    @out.push: "operator { %o<op> }";
    # `{A}` inside a double-quoted string is a CODE BLOCK in Raku, not a
    # literal — spelling this line as an interpolation cost a whole run with
    # `Undeclared name 'A'` after the probes had already finished.
    @out.push: 'forms    ({A}) ' ~ %o<op> ~ ' ({B})  ·  {A} ' ~ %o<op> ~ ' {B}  ·  {A}' ~ %o<op> ~ '{B}';
    @out.push: "axes     { @PAIRS.map({ $_<a> ~ ' | ' ~ $_<b> }).join(' · ') }";
    @out.push: "cols     { @SPELLINGS.map(*<key>).join(' | ') }";
    @out.push: '';

    my $i = 0;
    for @mine -> %c {
        $i++;
        my $key = %c<cand> ~ "\x[1F]" ~ %c<base>;
        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   spelling:{ %c<spell><key> } · lexical:{ %c<pair><note> }";
        @out.push: "  cell   { %c<pair><a> } | { %c<pair><b> } | { %c<spell><key> }";
        @out.push: "  code   { %c<cand> }";

        my $assertion = 'same-as';   # set by the branches below
        my $compiles = $ref<compiles>{%c<cand>};
        my $base-ok  = $ref<compiles>{%c<base>};
        my $v = $ref<value>{$key};

        @out.push: "  baseline { $base-ok ?? 'compiles' !! 'rejected too — this crossing is illegal however it is written' }";

        if !$compiles {
            # Never the wording of the diagnostic — only the structural fact.
            @out.push: "  no-parse the reference rejects this spelling";
            $assertion = 'no-parse';
            $base-ok ?? $n-noparse++ !! $n-illegal++;
        }
        elsif $v && $v<value>.contains('X::Comp') {
            # `-c` accepts this spelling and running it does not: the refusal
            # is a compile-time SORRY that only the optimizer raises, so the
            # cell passes the legality gate and then kills the dense program it
            # is packed into. It cannot be asserted in-process at all, so it
            # goes to the isolated lane asserting the one thing that is true of
            # it — that it compiles — with the split written down.
            @out.push: "  parses yes";
            @out.push: "  verdict underspecified";
            @out.push: "  why    the reference compiles this under -c and then refuses it when the program is actually built ({ $v<value>.substr(4) }); a value assertion has no lane to run in, so only the structural fact is asserted";
            @out.push: "  ruled  2026-08-19 against { @ids[0] }";
            $assertion = 'parses';
            $n-compsplit++;
        }
        elsif $v && order-unspecified($v<type>, $v<value>) {
            @out.push: "  same-as { %c<base> }";
            @out.push: "  verdict underspecified";
            @out.push: "  why    this crossing produces a { $v<type> }, whose rendering order is not specified — the standing ruling of this suite is that unspecified order is never asserted, in either spelling";
            @out.push: "  ruled  2026-08-19 against { @ids[0] }";
            $assertion = 'same-as';
            $n-unordered++;
        }
        elsif $ref<flaky>{$key} {
            @out.push: "  same-as { %c<base> }";
            @out.push: "  verdict disputed";
            @out.push: "  why    this cell answered differently on two identical probe runs, so any assertion built from it would be flaky by construction";
            @out.push: "  ruled  2026-08-18 against { @ids[0] }";
            $n-parked++;
        }
        elsif !$v {
            @out.push: "  same-as { %c<base> }";
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference produced no observation for this cell";
            @out.push: "  ruled  2026-08-18 against { @ids[0] }";
            $n-parked++;
        }
        elsif $v<verdict> eq 'AGREE' {
            # The oracle-free lane: two spellings of one crossing must agree.
            @out.push: "  same-as { %c<base> }";
            $n-same++;
        }
        else {
            # Either the spelling changed the parse, or the bare form is the only
            # legal one. Both are facts about the language rather than defects,
            # and both are exactly what the parenthesised forms hide — so pin
            # the value the bare spelling actually produces.
            $base-ok ?? $n-differs++ !! $n-baseonly++;
            $assertion = 'value';
            if $v<value>.starts-with('ERR:') {
                @out.push: "  throws { $v<value>.substr(4) }";
            }
            else {
                @out.push: "  is     { $v<value> }";
                @out.push: "  type   { $v<type> }" unless $v<type> eq '-';
            }
        }

        # The oracle line records the OBSERVATION, and what counts as one
        # depends on the assertion. `same-as` asserts a relation, so its
        # observation is whether the two spellings agreed — `check` reads it
        # by looking for AGREE. Every other assertion is about a value, so its
        # observation is that value. Writing the probe's own `DIFFER:` prefix
        # in front of a value made `check` compare `DIFFER: 1.2` against `1.2`
        # and report seven correct records as unsigned divergences.
        my $relational = $assertion eq 'same-as';
        for ^@engines -> $e {
            my $c = @obs[$e]<compiles>{%c<cand>};
            my $o = @obs[$e]<value>{$key};
            my $text = !$c            ?? 'no-parse'
                    !! !$o            ?? 'no observation'
                    !! $relational    ?? ($o<verdict> eq 'AGREE'
                                            ?? 'AGREE'
                                            !! "DIFFER: { $o<value> }")
                    !!                   $o<value>;
            @out.push: "  oracle { @ids[$e] } → $text";
        }
        @out.push: '';
    }

    $outdir.add(%o<file> ~ '.grid').spurt(@out.join("\n"));
}

say "# wrote { @ops.elems } atoms, { @cells.elems } cells";
say "#   $n-same agree with the parenthesised form (same-as — no oracle needed)";
say "#   $n-noparse rejected BY THE SPELLING (the parenthesised form compiles)";
say "#   $n-differs where the spelling changes the parse";
say "#   $n-baseonly where only the bare spelling is legal at all";
say "#   $n-illegal illegal however written (the parenthesised form is rejected too)";
say "#   $n-unordered produce an unordered type — never asserted, by standing ruling";
say "#   $n-compsplit accepted by -c and refused at build time — structural assertion only";
say "#   $n-parked parked as flaky";
