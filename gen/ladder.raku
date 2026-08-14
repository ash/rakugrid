#!/usr/bin/env raku
# gen/ladder.raku — edge-ladder crosses for operators and methods.
#
#   rakupp gen/ladder.raku --engines=raku,/path/to/rakupp
#
# Writes generated/<category>/<atom>.grid, one record per ladder cell, each
# carrying an oracle line per engine. Output is never hand-edited; to change it,
# change this generator and re-run.
#
# Ladders are ORDER-SENSITIVE: ids come from a cell's position in the cross, so
# new values must be APPENDED, never inserted. Ids are permanent.
#
# Operands are always parenthesised in the emitted code. Without it `1/2 ** 2`
# reads as `1/(2**2)` and the cell would silently test something else.

my $ROOT = $*PROGRAM.IO.absolute.IO.parent.parent;

constant %LADDERS =
    # the numeric corners: both bignum boundaries, the Rat→Num boundary,
    # signed zero, both infinities and NaN
    numeric => ['0', '1', '-1', '2**64', '1/3', '0e0', '-0e0', '1e0', 'Inf', '-Inf', 'NaN'],

    # for operators that grow their result — no bignum, no infinity as exponent
    small   => ['0', '1', '2', '-1', '1/2', '0e0', '-0e0', 'NaN'],

    # empty, blank, numeric-looking, single, multi-codepoint grapheme, case
    string  => ['""', '" "', '"0"', '"a"', '"A"', '"abc"', '"e\c[COMBINING ACUTE ACCENT]"', '"\0"'],

    # repetition counts that cannot build an endless string
    count   => ['0', '1', '2', '-1', '1/2', '0e0', 'NaN'],

    # across the type boundaries, where coercion bugs live
    mixed   => ['0', '1', '-1', '0e0', 'NaN', '""', '"0"', '"a"', 'True', 'False',
                'Nil', 'Any', '()', '(1,)', '{}'],

    bool    => ['True', 'False', '0', '1', '""', '"0"', 'Nil', 'Any'];

# atom => [ form, left ladder, right ladder ].  `{A}` and `{B}` are the operands;
# a spec with no `{B}` is unary and produces one row rather than a cross.
constant @SPECS =
    # --- arithmetic -------------------------------------------------------
    { atom => 'operators/infix-plus',      form => '({A}) + ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-minus',     form => '({A}) - ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-times',     form => '({A}) * ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-divide',    form => '({A}) / ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-modulo',    form => '({A}) % ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-int-div',   form => '({A}) div ({B})', left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-int-mod',   form => '({A}) mod ({B})', left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-power',     form => '({A}) ** ({B})',  left => 'small',   right => 'small'   },

    # --- numeric comparison ----------------------------------------------
    { atom => 'operators/infix-num-eq',    form => '({A}) == ({B})',  left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-ne',    form => '({A}) != ({B})',  left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-lt',    form => '({A}) < ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-le',    form => '({A}) <= ({B})',  left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-gt',    form => '({A}) > ({B})',   left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-ge',    form => '({A}) >= ({B})',  left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-num-cmp',   form => '({A}) <=> ({B})', left => 'numeric', right => 'numeric' },

    # --- numeric selection ------------------------------------------------
    { atom => 'operators/infix-min',       form => '({A}) min ({B})', left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-max',       form => '({A}) max ({B})', left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-gcd',       form => '({A}) gcd ({B})', left => 'numeric', right => 'numeric' },
    { atom => 'operators/infix-lcm',       form => '({A}) lcm ({B})', left => 'numeric', right => 'numeric' },

    # --- string -----------------------------------------------------------
    { atom => 'operators/infix-concat',    form => '({A}) ~ ({B})',   left => 'string',  right => 'string'  },
    { atom => 'operators/infix-repeat',    form => '({A}) x ({B})',   left => 'string',  right => 'count'   },
    { atom => 'operators/infix-str-eq',    form => '({A}) eq ({B})',  left => 'string',  right => 'string'  },
    { atom => 'operators/infix-str-ne',    form => '({A}) ne ({B})',  left => 'string',  right => 'string'  },
    { atom => 'operators/infix-str-lt',    form => '({A}) lt ({B})',  left => 'string',  right => 'string'  },
    { atom => 'operators/infix-str-gt',    form => '({A}) gt ({B})',  left => 'string',  right => 'string'  },
    { atom => 'operators/infix-leg',       form => '({A}) leg ({B})', left => 'string',  right => 'string'  },

    # --- across the type boundary ----------------------------------------
    { atom => 'operators/infix-cmp',       form => '({A}) cmp ({B})', left => 'mixed',   right => 'mixed'   },
    { atom => 'operators/infix-eqv',       form => '({A}) eqv ({B})', left => 'mixed',   right => 'mixed'   },
    { atom => 'operators/infix-and',       form => '({A}) && ({B})',  left => 'bool',    right => 'bool'    },
    { atom => 'operators/infix-or',        form => '({A}) || ({B})',  left => 'bool',    right => 'bool'    },
    { atom => 'operators/infix-defined-or', form => '({A}) // ({B})', left => 'mixed',   right => 'mixed'   },

    # --- prefixes ---------------------------------------------------------
    { atom => 'operators/prefix-minus',    form => '-({A})',          left => 'numeric' },
    { atom => 'operators/prefix-plus',     form => '+({A})',          left => 'mixed'   },
    { atom => 'operators/prefix-tilde',    form => '~({A})',          left => 'mixed'   },
    { atom => 'operators/prefix-question', form => '?({A})',          left => 'mixed'   },
    { atom => 'operators/prefix-not',      form => '!({A})',          left => 'mixed'   },

    # --- coercion methods -------------------------------------------------
    { atom => 'methods/Int',               form => '({A}).Int',       left => 'mixed'   },
    { atom => 'methods/Num',               form => '({A}).Num',       left => 'mixed'   },
    { atom => 'methods/Str',               form => '({A}).Str',       left => 'mixed'   },
    { atom => 'methods/Bool',              form => '({A}).Bool',      left => 'mixed'   },
    { atom => 'methods/defined',           form => '({A}).defined',   left => 'mixed'   },

    # --- numeric methods --------------------------------------------------
    { atom => 'methods/abs',               form => '({A}).abs',       left => 'numeric' },
    { atom => 'methods/sign',              form => '({A}).sign',      left => 'numeric' },
    { atom => 'methods/floor',             form => '({A}).floor',     left => 'numeric' },
    { atom => 'methods/ceiling',           form => '({A}).ceiling',   left => 'numeric' },
    { atom => 'methods/round',             form => '({A}).round',     left => 'numeric' },
    { atom => 'methods/sqrt',              form => '({A}).sqrt',      left => 'numeric' },

    # --- string methods ---------------------------------------------------
    { atom => 'methods/chars',             form => '({A}).chars',     left => 'string'  },
    { atom => 'methods/uc',                form => '({A}).uc',        left => 'string'  },
    { atom => 'methods/lc',                form => '({A}).lc',        left => 'string'  },
    { atom => 'methods/flip',              form => '({A}).flip',      left => 'string'  },
    { atom => 'methods/trim',              form => '({A}).trim',      left => 'string'  },
    { atom => 'methods/ords',              form => '({A}).ords',      left => 'string'  };

# Flushed after every line on purpose: an engine that dies mid-probe takes its
# buffered output with it, and then the crash looks like 3,000 missing
# observations instead of one.
constant $PROBE = q:to/END/;
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

sub engine-id($cmd) {
    my $p = run($cmd, '-e', 'print $*RAKU.compiler.name', :out, :err);
    my $name = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);

    if $name.contains('Raku++') || $name.lc.contains('rakupp') {
        # rakupp reports Rakudo's version through $*RAKU; take its own instead.
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

sub run-batch($cmd, @exprs, $tmp) {
    my $probe = $tmp.add('probe.raku');
    my $list  = $tmp.add('exprs.txt');
    $probe.spurt($PROBE);
    $list.spurt(@exprs.join("\n") ~ "\n");

    my $p = run($cmd, $probe.absolute, $list.absolute, :out, :err);
    my $out = $p.out.slurp(:close);
    $p.err.slurp(:close);

    my %by-expr;
    for $out.lines -> $l {
        my @f = $l.split("\t");
        next unless @f >= 3;
        %by-expr{@f[0]} = { value => @f[1], type => @f[2] };
    }
    return { seen => %by-expr, exit => $p.exitcode };
}

# An engine that dies takes the rest of the batch with it. Rather than record a
# gap — which reads as "no divergence" and is the worst thing a test suite can
# say — resume after the expression that killed it and record the crash itself
# as the observation.
sub observe($cmd, @exprs, $tmp) {
    my %seen;
    my @todo = @exprs;
    my $crashes = 0;

    while @todo {
        my %r = run-batch($cmd, @todo, $tmp);
        for @todo -> $e {
            %seen{$e} = %r<seen>{$e} if %r<seen>{$e};
        }
        my @missing = @todo.grep({ !%seen{$_} });
        last unless @missing;

        # with per-line flushing, the first unobserved expression is the one
        # that killed the run
        my $bad  = @missing[0];
        my %solo = run-batch($cmd, [$bad], $tmp);
        if %solo<seen>{$bad} {
            %seen{$bad} = %solo<seen>{$bad};
        }
        else {
            %seen{$bad} = { value => 'CRASH:' ~ %solo<exit>, type => '-' };
            $crashes++;
            note "#   crash (exit { %solo<exit> }): $bad";
        }
        @todo = @missing.elems > 1 ?? @missing[1 .. *] !! [];
    }

    note "#   $crashes crash{ $crashes == 1 ?? '' !! 'es' } recorded" if $crashes;
    return %seen;
}

sub build-cells(%spec) {
    my @left  = %LADDERS{%spec<left>}.list;
    my @cells;

    if %spec<form>.contains('{B}') {
        my @right = %LADDERS{%spec<right>}.list;
        for @left -> $a {
            for @right -> $b {
                @cells.push: { a => $a, b => $b,
                               expr => %spec<form>.subst('{A}', $a).subst('{B}', $b) };
            }
        }
    }
    else {
        for @left -> $a {
            @cells.push: { a => $a, b => Nil,
                           expr => %spec<form>.subst('{A}', $a) };
        }
    }
    return @cells;
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
}

my $tmp = $ROOT.add('tmp');
$tmp.mkdir unless $tmp.e;

# One probe run per engine for every expression in every spec — process startup
# dominates otherwise.
my @all;
my %cells-of;
for @SPECS -> %spec {
    my @cells = build-cells(%spec);
    %cells-of{%spec<atom>} = @cells;
    @all.append: @cells.map(*<expr>);
}
@all = @all.unique;

say "# { @SPECS.elems } atoms, { @all.elems } distinct expressions";

my @ids = @engines.map({ engine-id($_) });
my @obs;
for @engines -> $e {
    say "# probing $e …";
    @obs.push: observe($e, @all, $tmp);
}
my $ref = @obs[0];

my $files = 0;
my $tests = 0;

for @SPECS -> %spec {
    my $atom  = %spec<atom>;
    my @cells = %cells-of{$atom}.list;
    my $binary = %spec<form>.contains('{B}');

    my @out;
    @out.push: "atom     $atom";
    @out.push: "source   generated";
    @out.push: "gen      gen/ladder.raku";
    @out.push: "form     { %spec<form> }";
    if $binary {
        @out.push: "ladder   { %spec<left> } × { %spec<right> }, both orders";
        @out.push: "axes     { %LADDERS{%spec<left>}.join(' | ') }";
        @out.push: "cols     { %LADDERS{%spec<right>}.join(' | ') }";
    }
    else {
        @out.push: "ladder   { %spec<left> }";
    }
    @out.push: '';

    my $n = 0;
    for @cells -> %c {
        $n++;
        my $r = $ref{%c<expr>};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $n) }";
        @out.push: "  from   ladder:{ %spec<left> }{ $binary ?? '×' ~ %spec<right> !! '' }";
        @out.push: $binary ?? "  cell   { %c<a> } | { %c<b> }" !! "  cell   { %c<a> }";
        @out.push: "  code   { %c<expr> }";

        if $r<value>.starts-with('ERR:') {
            @out.push: "  throws { $r<value>.substr(4) }";
        }
        else {
            @out.push: "  is     { $r<value> }";
            @out.push: "  type   { $r<type> }";
        }

        for ^@engines -> $e {
            my $o = @obs[$e]{%c<expr>};
            next unless $o;
            @out.push: "  oracle { @ids[$e] } → { $o<value> }";
        }
        @out.push: '';
        $tests++;
    }

    my $file = $ROOT.add("generated/$atom.grid");
    $file.parent.mkdir unless $file.parent.e;
    $file.spurt(@out.join("\n"));
    $files++;
}

say "# wrote $files files, $tests tests, { @engines.elems } engine{ @engines == 1 ?? '' !! 's' } on record";
