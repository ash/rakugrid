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
my $TMP-DIR = $ROOT.add('tmp');
$TMP-DIR.mkdir unless $TMP-DIR.e;

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

    bool    => ['True', 'False', '0', '1', '""', '"0"', 'Nil', 'Any'],

    # finite only: an endless list would hang anything that walks it
    list    => ['()', '(1,)', '(1,2,3)', '[1,2,3]', '(1..3)', '(1,(2,3))',
                '<a b>', '(Any,)', '(1,Nil,2)', '(1,"a")'],

    hash    => ['{}', '{a=>1}', '{a=>1,b=>2}', '{"" => 1}', '{a=>Any}'],

    # walked by the method, so bounded
    range   => ['(1..3)', '(1^..3)', '(1..^3)', '(3..1)', '(1..1)', '("a".."c")'],

    # only for methods that answer from the bounds without walking
    endless => ['(1..Inf)', '(-Inf..0)', '(-Inf..Inf)', '(1..3)', '(3..1)'],

    # indices, including the ones that fall outside
    index   => ['0', '1', '2', '-1', '99', '1/2', 'Inf'];

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
    { atom => 'methods/ords',              form => '({A}).ords',      left => 'string'  },
    # --- list methods -----------------------------------------------------
    { atom => 'methods/elems',             form => '({A}).elems',     left => 'list'    },
    { atom => 'methods/list-Bool',         form => '({A}).Bool',      left => 'list'    },
    { atom => 'methods/head',              form => '({A}).head',      left => 'list'    },
    { atom => 'methods/tail',              form => '({A}).tail',      left => 'list'    },
    { atom => 'methods/reverse',           form => '({A}).reverse',   left => 'list'    },
    { atom => 'methods/sort',              form => '({A}).sort',      left => 'list'    },
    { atom => 'methods/unique',            form => '({A}).unique',    left => 'list'    },
    { atom => 'methods/flat',              form => '({A}).flat',      left => 'list'    },
    { atom => 'methods/join',              form => '({A}).join(",")', left => 'list'    },
    { atom => 'methods/list-min',          form => '({A}).min',       left => 'list'    },
    { atom => 'methods/list-max',          form => '({A}).max',       left => 'list'    },
    { atom => 'methods/sum',               form => '({A}).sum',       left => 'list'    },
    { atom => 'methods/list-Str',          form => '({A}).Str',       left => 'list'    },
    { atom => 'methods/list-raku',         form => '({A}).raku',      left => 'list'    },
    { atom => 'methods/index-into',        form => '({A})[{B}]',      left => 'list',   right => 'index' },

    # --- hash methods -----------------------------------------------------
    { atom => 'methods/hash-elems',        form => '({A}).elems',     left => 'hash'    },
    { atom => 'methods/hash-Bool',         form => '({A}).Bool',      left => 'hash'    },
    { atom => 'methods/keys',              form => '({A}).keys.sort', left => 'hash'    },
    { atom => 'methods/values',            form => '({A}).values.sort(*.raku)', left => 'hash' },
    { atom => 'methods/antipairs',         form => '({A}).antipairs.sort(*.raku)', left => 'hash' },
    { atom => 'methods/hash-raku',         form => '({A}).raku',      left => 'hash'    },

    # --- ranges -----------------------------------------------------------
    { atom => 'types/range-elems',         form => '({A}).elems',     left => 'range'   },
    { atom => 'types/range-list',          form => '({A}).list',      left => 'range'   },
    { atom => 'types/range-Bool',          form => '({A}).Bool',      left => 'range'   },
    { atom => 'types/range-reverse',       form => '({A}).reverse',   left => 'range'   },
    { atom => 'types/range-bounds-min',    form => '({A}).min',       left => 'endless' },
    { atom => 'types/range-bounds-max',    form => '({A}).max',       left => 'endless' },
    { atom => 'types/range-infinite',      form => '({A}).infinite',  left => 'endless' },
    { atom => 'types/range-bounds-elems',  form => '({A}).elems',     left => 'endless' },

    # --- matching ---------------------------------------------------------
    { atom => 'operators/infix-smartmatch', form => '({A}) ~~ ({B})', left => 'mixed',  right => 'mixed' },
    { atom => 'operators/infix-str-cmp',   form => '({A}) cmp ({B})', left => 'string', right => 'string' },

    # --- two-argument string methods --------------------------------------
    { atom => 'methods/substr',            form => '({A}).substr({B})',  left => 'string', right => 'index' },
    { atom => 'methods/str-index',         form => '({A}).index("a")',   left => 'string'  },
    { atom => 'methods/split',             form => '({A}).split("")',    left => 'string'  },
    { atom => 'methods/comb',              form => '({A}).comb',         left => 'string'  },
    { atom => 'methods/ord',               form => '({A}).ord',          left => 'string'  },
    { atom => 'methods/starts-with',       form => '({A}).starts-with({B})', left => 'string', right => 'string' },
    { atom => 'methods/str-contains',      form => '({A}).contains({B})',    left => 'string', right => 'string' },

    # --- introspection ----------------------------------------------------
    { atom => 'methods/WHAT-name',         form => '({A}).WHAT.^name',   left => 'mixed'   },
    { atom => 'methods/raku-roundtrip',    form => '({A}).raku',         left => 'mixed'   },
    { atom => 'methods/gist',              form => '({A}).gist',         left => 'mixed'   },
    { atom => 'methods/WHICH',             form => '({A}).WHICH.Str',    left => 'mixed'   };


# Flushed after every line on purpose: an engine that dies mid-probe takes its
# buffered output with it, and then the crash looks like 3,000 missing
# observations instead of one.
# Two questions per expression, not one: does it COMPILE, and what does it do?
# `try EVAL` cannot tell them apart — it catches a compile-time failure as a
# runtime exception, and the cell then looks like `throws` when in truth the
# expression cannot be compiled at all. Inlined into a dense program that kills
# every other test in the file. Compiling `sub { EXPR }` answers the first
# question without running anything.
constant $PROBE = q:to/END/;
    use MONKEY-SEE-NO-EVAL;
    for @*ARGS[0].IO.lines -> $expr {
        my $cmsg = '';
        my $compiles = 1;
        {
            try EVAL "sub \{ $expr \}";
            if $! {
                $compiles = 0;
                $cmsg = ($!.message.lines[0] // '').subst("\t", ' ', :g);
            }
        }
        if !$compiles {
            say join("\t", $expr, 'NOCOMPILE', '-', $cmsg);
            $*OUT.flush;
            next;
        }
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

sub cache-load($id) {
    my $f = $TMP-DIR.add("ladder-cache-$id.tsv");
    return {} unless $f.e;
    my %c;
    for $f.slurp.lines -> $l {
        my @p = $l.split("\t");
        next unless @p >= 3;
        %c{@p[0]} = { value => @p[1], type => @p[2], msg => (@p[3] // '') };
    }
    return %c;
}

sub cache-save($id, %seen) {
    my @lines;
    for %seen.keys.sort -> $k {
        @lines.push: join("\t", $k, %seen{$k}<value>, %seen{$k}<type>, %seen{$k}<msg> // '');
    }
    $TMP-DIR.add("ladder-cache-$id.tsv").spurt(@lines.join("\n") ~ "\n");
}


# An engine can answer with bytes that are not valid UTF-8 — rakupp renders
# `(-1).chrs` as \xff\xbf\xbf\xbf. Storing that verbatim puts a byte sequence in
# the record that no strict reader can decode, so one cell breaks every tool that
# reads the suite. Keep WHAT happened, in a form that is text.
sub textual($v) {
    return $v if try { $v.encode('utf-8').decode('utf-8') === $v };
    return 'INVALID-UTF8:' ~ (try { $v.ords.map(*.base(16)).join(' ') } // 'unrenderable');
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

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

my $GUARD = 0;

# Guarded, and through files rather than pipes: a probe that hangs or is killed
# can leave a descendant holding an inherited pipe, and the read then waits on
# an EOF that never comes.
sub run-batch($cmd, @exprs, $tmp, $secs = 180) {
    my $probe = $tmp.add('probe.raku');
    my $list  = $tmp.add('exprs.txt');
    $probe.spurt($PROBE);
    $list.spurt(@exprs.join("\n") ~ "\n");

    my $base = $tmp.add('probe-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $line = "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) }";
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit \$rc";

    my $p = run('/bin/sh', '-c', $script);
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;

    my %by-expr;
    for $out.lines -> $l {
        my @f = $l.split("\t");
        next unless @f >= 3;
        %by-expr{@f[0]} = { value => @f[1], type => @f[2], msg => (@f[3] // '') };
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
        my %solo = run-batch($cmd, [$bad], $tmp, 15);
        if %solo<seen>{$bad} {
            %seen{$bad} = %solo<seen>{$bad};
        }
        else {
            my $how = %solo<exit> == 137 ?? 'HANG' !! 'CRASH:' ~ %solo<exit>;
            %seen{$bad} = { value => $how, type => '-' };
            $crashes++;
            note "#   { $how.lc } : $bad";
        }
        @todo = @missing.elems > 1 ?? @missing[1 .. *] !! [];
    }

    note "#   $crashes crash{ $crashes == 1 ?? '' !! 'es' } recorded" if $crashes;
    return %seen;
}


# EVAL is not the same compiler context as a file: Rakudo compiles
# `sub { (0) ~~ (Nil) }` from a file happily and dies on the identical text
# under EVAL. So a NOCOMPILE flagged by the batch probe is only a CANDIDATE —
# it is confirmed by compiling a real file, the way `rakugrid fire` will. Same
# lesson as staging: capture the observation the way the test reproduces it.
sub run-cmd($cmd, @args, $tmp, $secs = 15) {
    my $base = $tmp.add('cmd-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $line = ([$cmd, |@args].map({ sh-quote($_) })).join(' ');
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

sub probe-file($cmd, $expr, $tmp) {
    my $f = $tmp.add('confirm.raku');
    $f.spurt("my \$r = try \{ $expr \};\n"
           ~ "if \$\! \{ say 'ERR:' ~ \$\!.^name ~ \"\\t-\" \}\n"
           ~ "else \{ say \$r.raku ~ \"\\t\" ~ \$r.WHAT.^name \}\n");

    my %c = run-cmd($cmd, ['-c', $f.absolute], $tmp);
    if %c<exit> != 0 {
        my $msg = (%c<err> ~ %c<out>).lines.grep({ .trim }).head(2).join(' ').subst("\t", ' ', :g);
        return { value => 'NOCOMPILE', type => '-', msg => $msg };
    }

    my %r = run-cmd($cmd, [$f.absolute], $tmp);
    my @f = (%r<out>.lines[0] // '').split("\t");
    return { value => 'CRASH:' ~ %r<exit>, type => '-', msg => '' } unless @f >= 2;
    return { value => @f[0], type => @f[1], msg => '' };
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
# Incremental, so re-measuring one engine costs nothing for the other. The
# reference does not move between runs; a development build of the engine under
# test moves every morning, and only its cells need re-probing.
my @ids-early = @engines.map({ engine-id($_) });
my @obs;
for ^@engines -> $e {
    my %seen = cache-load(@ids-early[$e]);
    my @todo = @all.grep({ !%seen{$_} });
    if !@todo {
        say "# all { @all.elems } cells already on record for { @ids-early[$e] }";
        @obs.push: %seen;
        next;
    }
    say "# probing { @ids-early[$e] }: { @todo.elems } new of { @all.elems } …";
    my %fresh = observe(@engines[$e], @todo, $tmp);
    for %fresh.keys -> $k { %seen{$k} = %fresh{$k} }
    cache-save(@ids-early[$e], %seen);
    @obs.push: %seen;
}
my $ref = @obs[0];

# The reference is probed TWICE. An expression whose observation changes between
# two identical runs cannot be asserted at all — .WHICH on a reference type
# carries an address, and a test built from one run of it is flaky by
# construction. Those cells are parked, not silently dropped.
# A cell the batch probe could not answer is a CANDIDATE too, not a dead end.
# `last` outside a loop kills the probe process, but it is a clean compile-time
# error in a real file — parking it would have hidden a perfectly good test.
my @candidates = @all.grep({
    my $v = @obs[0]{$_} ?? @obs[0]{$_}<value> !! '';
    $v eq 'NOCOMPILE' || $v.starts-with('CRASH') || $v eq 'HANG'
});
if @candidates {
    say "# confirming { @candidates.elems } compile-failure candidate{ @candidates == 1 ?? '' !! 's' } against real files …";
    my $overturned = 0;
    for @candidates -> $expr {
        for ^@engines -> $e {
            my %real = probe-file(@engines[$e], $expr, $tmp);
            $overturned++ if $e == 0 && %real<value> ne 'NOCOMPILE';
            @obs[$e]{$expr} = %real;
        }
    }
    say "#   $overturned were EVAL artefacts, not compile failures" if $overturned;
}

my %again = cache-load(@ids-early[0] ~ '-again');
my @re = @all.grep({ !%again{$_} });
if @re {
    say "# re-probing { @ids-early[0] }: { @re.elems } cells, to check the observations reproduce …";
    my %fresh = observe(@engines[0], @re, $tmp);
    for %fresh.keys -> $k { %again{$k} = %fresh{$k} }
    cache-save(@ids-early[0] ~ '-again', %again);
}
for @candidates -> $expr {
    %again{$expr} = @obs[0]{$expr};      # already confirmed against a real file
}
my $unstable = 0;
my $noanswer = 0;

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

        if $r<value> eq 'NOCOMPILE' {
            # The expression is compiled in the same VALUE context the probe
            # used. Context matters: Rakudo compiles `(0) ~~ (Nil)` at
            # statement level and refuses it inside `sub { }`, so a test that
            # dropped the wrapper would be checking a different question.
            @out.push: "  code   sub \{ { %c<expr> } \}";
            # Deliberately no `error` field: the diagnostic's wording is not
            # specified, and asserting one engine's prose would test the message
            # rather than the language. The requirement is that it not compile.
            @out.push: "  no-parse compile-time failure";
        }
        elsif $r<value>.starts-with('ERR:') {
            @out.push: "  code   { %c<expr> }";
            @out.push: "  throws { $r<value>.substr(4) }";
        }
        else {
            @out.push: "  code   { %c<expr> }";
            @out.push: "  is     { textual($r<value>) }";
            @out.push: "  type   { $r<type> }";
        }

        my $reproducible = %again{%c<expr>} && %again{%c<expr>}<value> eq $r<value>;

        # A reference that crashed, hung, or otherwise produced no usable answer
        # gives us nothing to assert. Park it — never turn "CRASH:1" into an
        # expected value.
        my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG');

        for ^@engines -> $e {
            my $o = @obs[$e]{%c<expr>};
            next unless $o;
            my $obs = $o<value> eq 'NOCOMPILE' && $o<msg>
                ?? 'NOCOMPILE: ' ~ $o<msg>
                !! $o<value>;
            @out.push: "  oracle { @ids[$e] } → { textual($obs) }";
        }

        if !$answered {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference produced no usable answer for this cell (it crashed or did not terminate), so there is nothing to assert";
            @out.push: "  ruled  2026-08-14 against { @ids[0] }";
            $noanswer++;
        }
        elsif !$reproducible {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference gives a different answer on two identical runs, so there is nothing stable to assert — typically an address inside .WHICH or an unordered container";
            @out.push: "  ruled  2026-08-14 against { @ids[0] }";
            $unstable++;
        }
        @out.push: '';
        $tests++;
    }

    my $file = $ROOT.add("generated/$atom.grid");
    $file.parent.mkdir unless $file.parent.e;
    $file.spurt(@out.join("\n"));
    $files++;
}

say "# $unstable cell{ $unstable == 1 ?? '' !! 's' } parked as not reproducible" if $unstable;
say "# $noanswer cell{ $noanswer == 1 ?? '' !! 's' } parked with no reference answer" if $noanswer;
say "# wrote $files files, $tests tests, { @engines.elems } engine{ @engines == 1 ?? '' !! 's' } on record";
