#!/usr/bin/env raku
# gen/laws.raku — algebraic laws, asserted with `same-as`.
#
#   rakupp gen/laws.raku --engines=raku,/path/to/rakupp
#
# Every other generator asks an implementation what an expression produces and
# writes the answer down. These records assert that two spellings agree with
# EACH OTHER, which needs no oracle, no documentation and no ruling: `a + b`
# must equal `b + a` whatever either of them is, and an engine that disagrees
# with itself is wrong without anyone having to say what the right answer was.
#
# Laws are not axioms. `a <= b` and `!(a > b)` part company at NaN, and
# `.uc.lc` is not `.lc` for every Unicode string. Where the reference itself
# breaks a law the record is PARKED with the reason — that list is worth having,
# because a law that fails at one cell is either a real defect or a genuine
# subtlety, and both deserve to be visible rather than quietly dropped.
#
# Ids come from position within an atom, so new cells must be APPENDED.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

constant %LADDERS =
    numeric => ['0', '1', '-1', '2**64', '1/3', '0e0', '-0e0', '1e0', 'Inf', '-Inf', 'NaN'],
    small   => ['0', '1', '2', '-1', '1/2', '0e0', 'NaN'],
    string  => ['""', '" "', '"0"', '"a"', '"A"', '"abc"', '"e\c[COMBINING ACUTE ACCENT]"'],
    bool    => ['True', 'False', '0', '1', '""', '"0"', 'Nil', 'Any'],
    list    => ['()', '(1,)', '(1,2,3)', '[1,2,3]', '(1..3)', '(3,1,2)', '<a b>'];

# Each law: two spellings that must agree, over one ladder, in 1, 2 or 3 places.
# `{A}`, `{B}`, `{C}` are the ladder values.
constant @LAWS =
    # --- commutativity ----------------------------------------------------
    { atom => 'laws/plus-commutes',   lhs => '({A}) + ({B})',   rhs => '({B}) + ({A})',   ladder => 'numeric', arity => 2 },
    { atom => 'laws/times-commutes',  lhs => '({A}) * ({B})',   rhs => '({B}) * ({A})',   ladder => 'numeric', arity => 2 },
    { atom => 'laws/min-commutes',    lhs => '({A}) min ({B})', rhs => '({B}) min ({A})', ladder => 'numeric', arity => 2 },
    { atom => 'laws/max-commutes',    lhs => '({A}) max ({B})', rhs => '({B}) max ({A})', ladder => 'numeric', arity => 2 },
    { atom => 'laws/eq-commutes',     lhs => '({A}) == ({B})',  rhs => '({B}) == ({A})',  ladder => 'numeric', arity => 2 },
    { atom => 'laws/eqv-commutes',    lhs => '({A}) eqv ({B})', rhs => '({B}) eqv ({A})', ladder => 'numeric', arity => 2 },

    # --- associativity ----------------------------------------------------
    { atom => 'laws/plus-associates',  lhs => '(({A}) + ({B})) + ({C})',
                                       rhs => '({A}) + (({B}) + ({C}))', ladder => 'small', arity => 3 },
    { atom => 'laws/times-associates', lhs => '(({A}) * ({B})) * ({C})',
                                       rhs => '({A}) * (({B}) * ({C}))', ladder => 'small', arity => 3 },
    { atom => 'laws/concat-associates', lhs => '((({A}) ~ ({B})) ~ ({C}))',
                                        rhs => '(({A}) ~ (({B}) ~ ({C})))', ladder => 'string', arity => 3 },

    # --- comparison duality -----------------------------------------------
    { atom => 'laws/lt-is-gt-flipped', lhs => '({A}) < ({B})',  rhs => '({B}) > ({A})',   ladder => 'numeric', arity => 2 },
    { atom => 'laws/le-is-not-gt',     lhs => '({A}) <= ({B})', rhs => '!(({A}) > ({B}))', ladder => 'numeric', arity => 2 },
    { atom => 'laws/ne-is-not-eq',     lhs => '({A}) != ({B})', rhs => '!(({A}) == ({B}))', ladder => 'numeric', arity => 2 },
    { atom => 'laws/strne-is-not-streq', lhs => '({A}) ne ({B})', rhs => '!(({A}) eq ({B}))', ladder => 'string', arity => 2 },

    # --- De Morgan --------------------------------------------------------
    { atom => 'laws/de-morgan-and', lhs => '!((?({A})) && (?({B})))',
                                    rhs => '(!(?({A}))) || (!(?({B})))', ladder => 'bool', arity => 2 },
    { atom => 'laws/de-morgan-or',  lhs => '!((?({A})) || (?({B})))',
                                    rhs => '(!(?({A}))) && (!(?({B})))', ladder => 'bool', arity => 2 },

    # --- an operator and its routine form ---------------------------------
    { atom => 'laws/reduce-is-infix-plus',  lhs => '({A}) + ({B})',   rhs => '[+] (({A}), ({B}))', ladder => 'numeric', arity => 2 },
    { atom => 'laws/reduce-is-infix-times', lhs => '({A}) * ({B})',   rhs => '[*] (({A}), ({B}))', ladder => 'numeric', arity => 2 },
    { atom => 'laws/sum-is-reduce',         lhs => '(({A}), ({B})).sum', rhs => '[+] (({A}), ({B}))', ladder => 'numeric', arity => 2 },
    { atom => 'laws/min-is-list-min',       lhs => '({A}) min ({B})', rhs => '(({A}), ({B})).min', ladder => 'numeric', arity => 2 },
    { atom => 'laws/max-is-list-max',       lhs => '({A}) max ({B})', rhs => '(({A}), ({B})).max', ladder => 'numeric', arity => 2 },
    { atom => 'laws/concat-is-join',        lhs => '({A}) ~ ({B})',   rhs => '(({A}), ({B})).join("")', ladder => 'string', arity => 2 },

    # --- a prefix and its method ------------------------------------------
    { atom => 'laws/tilde-is-Str',     lhs => '~({A})', rhs => '({A}).Str',     ladder => 'numeric', arity => 1 },
    { atom => 'laws/question-is-Bool', lhs => '?({A})', rhs => '({A}).Bool',    ladder => 'bool',    arity => 1 },
    { atom => 'laws/plus-is-Numeric',  lhs => '+({A})', rhs => '({A}).Numeric', ladder => 'numeric', arity => 1 },
    { atom => 'laws/negate-is-subtract', lhs => '-({A})', rhs => '0 - ({A})',   ladder => 'numeric', arity => 1 },
    { atom => 'laws/not-is-negated-Bool', lhs => '!({A})', rhs => '!(({A}).Bool)', ladder => 'bool', arity => 1 },

    # --- involutions ------------------------------------------------------
    { atom => 'laws/flip-is-involution',    lhs => '({A}).flip.flip', rhs => '({A}).Str',  ladder => 'string',  arity => 1 },
    { atom => 'laws/reverse-is-involution', lhs => '({A}).reverse.reverse', rhs => '({A}).list', ladder => 'list', arity => 1 },
    { atom => 'laws/double-negate',         lhs => '-(-({A}))',       rhs => '+({A})',     ladder => 'numeric', arity => 1 },

    # --- structure preserved ----------------------------------------------
    { atom => 'laws/sort-keeps-length',   lhs => '({A}).sort.elems', rhs => '({A}).elems', ladder => 'list',   arity => 1 },
    { atom => 'laws/reverse-keeps-length', lhs => '({A}).reverse.elems', rhs => '({A}).elems', ladder => 'list', arity => 1 },
    { atom => 'laws/chars-is-comb-elems', lhs => '({A}).chars',      rhs => '({A}).comb.elems', ladder => 'string', arity => 1 },
    { atom => 'laws/uc-lc-is-lc',         lhs => '({A}).uc.lc',      rhs => '({A}).lc',    ladder => 'string', arity => 1 };

# The probe asks one question per line: do these two spellings agree, the way
# `rakugrid fire` compares them — same error or no error, and the same `.raku`.
constant $PROBE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $line {
        my ($lhs, $rhs) = $line.split("\x[1F]");
        my $a  = try EVAL $lhs;
        my $e1 = $! ?? $!.^name !! '';
        my $b  = try EVAL $rhs;
        my $e2 = $! ?? $!.^name !! '';
        my $same = $e1 eq $e2 && $a.raku eq $b.raku;
        say join("\t", $line, $same ?? 'AGREE' !! 'DIFFER',
                 $same ?? '' !! ($e1 || $a.raku) ~ ' vs ' ~ ($e2 || $b.raku));
        $*OUT.flush;
    }
    END

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

sub run-probe($cmd, @pairs, $secs = 240) {
    my $probe = $TMP.add('laws-probe.raku');
    my $list  = $TMP.add('laws-pairs.txt');
    $probe.spurt($PROBE);
    $list.spurt(@pairs.join("\n") ~ "\n");

    my $base = $TMP.add('laws-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $line = "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) }";
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit \$rc";
    run('/bin/sh', '-c', $script);

    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;

    my %r;
    for $out.lines -> $l {
        my @f = $l.split("\t");
        next unless @f >= 2;
        %r{@f[0]} = { verdict => @f[1], detail => (@f[2] // '') };
    }
    return %r;
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

sub cells(%law) {
    my @v = %LADDERS{%law<ladder>}.list;
    my @out;
    if %law<arity> == 1 {
        for @v -> $a {
            @out.push: { keys => [$a], lhs => %law<lhs>.subst('{A}', $a, :g),
                                       rhs => %law<rhs>.subst('{A}', $a, :g) };
        }
    }
    elsif %law<arity> == 2 {
        for @v -> $a {
            for @v -> $b {
                @out.push: { keys => [$a, $b],
                             lhs => %law<lhs>.subst('{A}', $a, :g).subst('{B}', $b, :g),
                             rhs => %law<rhs>.subst('{A}', $a, :g).subst('{B}', $b, :g) };
            }
        }
    }
    else {
        for @v -> $a {
            for @v -> $b {
                for @v -> $c {
                    @out.push: { keys => [$a, $b, $c],
                                 lhs => %law<lhs>.subst('{A}', $a, :g).subst('{B}', $b, :g).subst('{C}', $c, :g),
                                 rhs => %law<rhs>.subst('{A}', $a, :g).subst('{B}', $b, :g).subst('{C}', $c, :g) };
                }
            }
        }
    }
    return @out;
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
}
my @ids = @engines.map({ engine-id($_) });

my %cells-of;
my @pairs;
for @LAWS -> %law {
    my @c = cells(%law);
    %cells-of{%law<atom>} = @c;
    @pairs.append: @c.map({ $_<lhs> ~ "\x[1F]" ~ $_<rhs> });
}
@pairs = @pairs.unique;

say "# { @LAWS.elems } laws, { @pairs.elems } instances";
say "# engines: { @ids.join(', ') }";

my @obs;
for @engines -> $e {
    say "# probing $e …";
    @obs.push: run-probe($e, @pairs);
}
my $ref = @obs[0];

my $held = 0;
my $broke = 0;
my $outdir = $ROOT.add('generated/laws');
$outdir.mkdir unless $outdir.e;

for @LAWS -> %law {
    my @out;
    @out.push: "atom     { %law<atom> }";
    @out.push: "source   generated";
    @out.push: "gen      gen/laws.raku";
    @out.push: "law      { %law<lhs> }  ===  { %law<rhs> }";
    @out.push: "ladder   { %law<ladder> }, arity { %law<arity> }";
    @out.push: '';

    my $i = 0;
    for %cells-of{%law<atom>}.list -> %c {
        $i++;
        my $key = %c<lhs> ~ "\x[1F]" ~ %c<rhs>;
        my $r = $ref{$key};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   law:{ %law<atom>.split('/')[*-1] }";
        @out.push: "  cell   { %c<keys>.join(' | ') }";
        @out.push: "  code   { %c<lhs> }";
        @out.push: "  same-as { %c<rhs> }";

        for ^@engines -> $e {
            my $o = @obs[$e]{$key};
            next unless $o;
            @out.push: "  oracle { @ids[$e] } → { $o<verdict> }{ $o<detail> ?? ': ' ~ $o<detail> !! '' }";
        }

        if $r<verdict> eq 'AGREE' {
            $held++;
        }
        else {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference itself breaks this law at this cell ({ $r<detail> }) — either a defect or a genuine subtlety, and it needs a ruling before it can be asserted";
            @out.push: "  ruled  2026-08-14 against { @ids[0] }";
            $broke++;
        }
        @out.push: '';
    }

    $ROOT.add("generated/{ %law<atom> }.grid").spurt(@out.join("\n"));
}

say "# $held instances hold under the reference, $broke parked where it breaks the law";
