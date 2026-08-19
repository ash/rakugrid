#!/usr/bin/env raku
# gen/signatures.raku — parameter binding and dispatch.
#
#   rakupp gen/signatures.raku --engines=raku
#
# Two families: one parameter against every argument in every call form, and
# two parameters dividing one argument list between them. The second is where
# the binder gets interesting — an optional before a slurpy, a named after a
# positional, two constraints competing for one value.
#
# Ladders are APPEND ONLY and enumerated in shells, so widening never
# renumbers an existing cell.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
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
    my $base = $TMP.add('sig-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 -\$p 2>/dev/null || kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit 0";
    my $p = run('/bin/sh', '-c', $script);
    my $rc = $p.exitcode;
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;
    return { out => $out, exit => $rc };
}

# $partial, when given, is the cache file for the engine being probed, and
# every batch is appended to it as soon as it lands. A pass used to keep all
# of its results in memory until the end, so one hang discarded hours of
# probing — 36,000 cells, once. A truncated final line is skipped by
# cache-load, so a kill mid-write costs at most the batch in flight.
sub run-parallel($cmd, @exprs, $jobs, $batch = 200, $secs = 120, $partial = Str) {
    my $probe = $TMP.add('sig-probe.raku');
    $probe.spurt($VALUE-PROBE);

    my %seen;
    my $total  = @exprs.elems;
    my $offset = 0;

    while $offset < $total {
        my $now = adaptive-jobs($jobs);
        my @cmds;
        my @parts;
        for ^$now -> $j {
            my $from = $offset + $j * $batch;
            last if $from >= $total;
            my $to = min($from + $batch, $total) - 1;
            my $list = $TMP.add("sig-list-$j.txt");
            $list.spurt(@exprs[$from .. $to].join("\n") ~ "\n");
            my $out = $TMP.add("sig-out-$j.txt").absolute;
            $out.IO.unlink if $out.IO.e;
            @parts.push: $out;
            @cmds.push: "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) } > { sh-quote($out) } 2>/dev/null &";
        }
        last unless @cmds;

        my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; " ~ @cmds.join(' ') ~ " wait";
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
        $offset += $now * $batch;
        note "#     { min($offset, $total) } / $total" if min($offset, $total) %% 2000;
        $*ERR.flush;
    }
    return %seen;
}

# Bisection, with a timeout that scales: a hang costs log2(n) waits, each only
# as long as its list could honestly need.
sub recover($cmd, @missing, $depth = 0) {
    return {} unless @missing;
    my $list  = $TMP.add("sig-rec-$depth.txt");
    my $probe = $TMP.add('sig-probe.raku');
    $list.spurt(@missing.join("\n") ~ "\n");
    $probe.spurt($VALUE-PROBE);

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
        %got{@still[0]} = { value => (%r<exit> == 137 ?? 'HANG' !! 'CRASH:' ~ %r<exit>), type => '-' };
        return %got;
    }
    my $half = (@still / 2).Int;
    my %a = recover($cmd, @still[0 ..^ $half].list, $depth + 1);
    my %b = recover($cmd, @still[$half .. *].list,  $depth + 1);
    for %a.keys -> $k { %got{$k} = %a{$k} }
    for %b.keys -> $k { %got{$k} = %b{$k} }
    return %got;
}

sub cache-load($id) {
    my $f = $TMP.add("sig-cache-$id.tsv");
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
    $TMP.add("sig-cache-$id.tsv").spurt(@lines.join("\n") ~ "\n");
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

sub PREFIX() { "sig" }
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

# A symbol turns into a filename-safe atom name.
# ---------------------------------------------------------------- the axes

# Parameter forms. Each binds to a fixed name so one render expression serves
# every cell: scalars to $a, positionals to @a, associatives to %h, callables
# to &c, captures to |c or \a.
#
# APPEND ONLY, for the same reason as the operator ladder: ids come from a
# cell's position in the cross, enumerated in shells, so appending adds shells
# without moving an existing cell.
constant @PARAMS =
    # --- the plain positional and its type constraints -------------------
    { sig => '$a',                  show => '$a'  },
    { sig => 'Int $a',              show => '$a'  },
    { sig => 'Str $a',              show => '$a'  },
    { sig => 'Num $a',              show => '$a'  },
    { sig => 'Any $a',              show => '$a'  },
    { sig => 'Mu $a',               show => '$a'  },
    { sig => 'Cool $a',             show => '$a'  },
    { sig => 'Numeric $a',          show => '$a'  },

    # --- definedness, the smartmatch constraint, subsets ------------------
    { sig => 'Int:D $a',            show => '$a'  },
    { sig => 'Int:U $a',            show => '$a'  },
    { sig => 'Any:D $a',            show => '$a'  },
    { sig => '$a where * > 0',      show => '$a'  },
    { sig => '$a where Int',        show => '$a'  },

    # --- optional and defaulted -------------------------------------------
    { sig => '$a?',                 show => '$a'  },
    { sig => '$a = 42',             show => '$a'  },
    { sig => 'Int $a = 42',         show => '$a'  },
    { sig => '$a = Nil',            show => '$a'  },

    # --- named -------------------------------------------------------------
    { sig => ':$a',                 show => '$a'  },
    { sig => ':$a!',                show => '$a'  },
    { sig => ':$a = 42',            show => '$a'  },
    { sig => 'Int :$a',             show => '$a'  },
    { sig => ':a($a)',              show => '$a'  },

    # --- slurpy -------------------------------------------------------------
    { sig => '*@a',                 show => '@a.raku' },
    { sig => '**@a',                show => '@a.raku' },
    { sig => '+@a',                 show => '@a.raku' },
    { sig => '*%h',                 show => '%h.raku' },
    { sig => '*@a, *%h',            show => '(@a, %h).raku' },

    # --- traits: the ones that change what the callee may do to the caller --
    { sig => '$a is rw',            show => '$a'  },
    { sig => '$a is copy',          show => '$a'  },
    { sig => '$a is raw',           show => '$a'  },

    # --- sigils that impose a shape ----------------------------------------
    { sig => '@a',                  show => '@a.raku' },
    { sig => '%h',                  show => '%h.raku' },
    { sig => '&c',                  show => '&c.WHAT.^name' },

    # --- capture and destructuring -----------------------------------------
    { sig => '|c',                  show => 'c.raku'  },
    { sig => '\a',                  show => 'a.raku'  },
    { sig => '[$x, $y]',            show => '($x, $y).raku' },
    { sig => '::T $a',              show => '(T.^name, $a).raku' };

# What we try to bind to it.
constant @ARGS =
    '1', '"a"', '0', 'Any', 'Nil', '()', '(1,2)', '[1,2]', '{a=>1}',
    ':a', ':a(1)', '\(1)', '1, 2', '', '1e0', '(1,)';

# Arguments always reach the callee through a CAPTURE. Passed literally,
# `f("a")` against `Int $a` is rejected by Rakudo at compile time — "will never
# work with declared signature" — and a compile error is not a value this
# generator can assert, nor what the probe observed. Routing through `\(...)`
# keeps every cell a RUNTIME binding question, which is what this generator is
# for. Compile-time signature analysis belongs in gen/syntax.raku, which has
# the separate compile probe it needs.
#
# How the callee is reached. Binding is not one algorithm — a multi candidate
# is chosen before it is bound, a method has an invocant in front, and a block
# binds without a dispatcher at all.
constant @FORMS =
    { name => 'sub',    code => 'my $A = \\(ARGS); sub f(SIG) { SHOW }; f(|$A)' },
    { name => 'multi',  code => 'my $A = \\(ARGS); multi f(SIG) { SHOW }; f(|$A)' },
    # An ANONYMOUS class, deliberately: `class C {...}` installs a symbol, and
    # Rakudo throws X::Redeclaration the second time one process compiles it.
    # Both the probe and `fire` evaluate many cells per process, so a named
    # class would record a redeclaration error as if it were the binding result
    # for every method cell but the first.
    { name => 'method', code => 'my $A = \\(ARGS); my $C = class { method m(SIG) { SHOW } }; $C.m(|$A)' },
    { name => 'block',  code => 'my $A = \\(ARGS); my $b = -> SIG { SHOW }; $b.(|$A)' },
    { name => 'ampcall', code => 'my $A = \\(ARGS); sub f(SIG) { SHOW }; my &g = &f; g(|$A)' };

# Argument lists for the two-parameter family: the interesting question is not
# what one parameter accepts but how two of them divide a list between them.
constant @PAIR-ARGS = '1, 2', '1', '', ':a, :b', '1, :b', '(1,2)', 'Any, Any', '1, 2, 3';

# The second parameter of a pair needs its own names — two parameters cannot
# both be `$a`. Rename identifiers, not text: `:a($a)` has to become `:b($b)`
# in both halves or the named argument stops matching.
sub rename2($s) {
    my $r = $s;
    $r = $r.subst('$a', '$b', :g);
    $r = $r.subst('@a', '@b', :g);
    $r = $r.subst('%h', '%g', :g);
    $r = $r.subst('&c', '&d', :g);
    $r = $r.subst('|c', '|d', :g);
    $r = $r.subst('\a', '\b', :g);
    $r = $r.subst('a(',  'b(', :g);
    $r = $r.subst('$x', '$p', :g);
    $r = $r.subst('$y', '$q', :g);
    $r = $r.subst('::T', '::U', :g);
    $r = $r.subst('T.^name', 'U.^name', :g);
    $r = $r.subst('c.raku', 'd.raku', :g);
    $r = $r.subst('a.raku', 'b.raku', :g);
    return $r;
}

sub argslug($s) {
    return 'none' if $s.trim eq '';
    my $safe = $s.comb.map({ /<[A..Za..z0..9]>/ ?? $_ !! sprintf('u%02x', .ord) }).join;
    return $safe;
}

sub level-of($shell) {
    return $shell == 0 ?? 0 !! $shell <= 3 ?? 1 !! $shell <= 9 ?? 2 !! 3;
}

sub build($form, $sig, $show, $args) {
    my $c = $form<code>;
    $c = $c.subst('SIG',  $sig);
    $c = $c.subst('SHOW', $show);
    $c = $c.subst('ARGS', $args);
    return $c;
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
my $JOBS = 2;
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $JOBS    = ($a.substr(7) eq 'auto' ?? 'auto' !! +$a.substr(7)) if $a.starts-with('--jobs=');
}

my %cells;
my @all;

# --- family one: one parameter, every argument, every way of calling --------
for @FORMS -> %f {
    my @c;
    for ^max(@PARAMS.elems, @ARGS.elems) -> $shell {
        my $lvl = level-of($shell);
        for ^($shell + 1) -> $i {
            next unless $i < @PARAMS.elems && $shell < @ARGS.elems;
            @c.push: { a => @PARAMS[$i]<sig>, b => @ARGS[$shell], level => $lvl,
                       expr => build(%f, @PARAMS[$i]<sig>, @PARAMS[$i]<show>, @ARGS[$shell]) };
        }
        for ^$shell -> $j {
            next unless $shell < @PARAMS.elems && $j < @ARGS.elems;
            @c.push: { a => @PARAMS[$shell]<sig>, b => @ARGS[$j], level => $lvl,
                       expr => build(%f, @PARAMS[$shell]<sig>, @PARAMS[$shell]<show>, @ARGS[$j]) };
        }
    }
    %cells{"bind-{ %f<name> }"} = { kind => 'unary', form => %f<name>, cells => @c };
    @all.append: @c.map(*<expr>);
}

# --- family two: two parameters dividing one argument list ------------------
# This is where the binder actually gets interesting: an optional before a
# slurpy, a named after a positional, two constraints competing for one value.
for @PAIR-ARGS -> $args {
    my @c;
    for ^@PARAMS.elems -> $shell {
        my $lvl = level-of($shell);
        for ^($shell + 1) -> $i {
            my $sig  = @PARAMS[$i]<sig> ~ ', ' ~ rename2(@PARAMS[$shell]<sig>);
            my $show = '(' ~ @PARAMS[$i]<show> ~ ', ' ~ rename2(@PARAMS[$shell]<show>) ~ ').raku';
            @c.push: { a => @PARAMS[$i]<sig>, b => @PARAMS[$shell]<sig>, level => $lvl,
                       expr => "my \$A = \\($args); sub f($sig) \{ $show \}; f(|\$A)" };
        }
        for ^$shell -> $j {
            my $sig  = @PARAMS[$shell]<sig> ~ ', ' ~ rename2(@PARAMS[$j]<sig>);
            my $show = '(' ~ @PARAMS[$shell]<show> ~ ', ' ~ rename2(@PARAMS[$j]<show>) ~ ').raku';
            @c.push: { a => @PARAMS[$shell]<sig>, b => @PARAMS[$j]<sig>, level => $lvl,
                       expr => "my \$A = \\($args); sub f($sig) \{ $show \}; f(|\$A)" };
        }
    }
    %cells{"pair-{ argslug($args) }"} = { kind => 'pair', args => $args, cells => @c };
    @all.append: @c.map(*<expr>);
}

@all = @all.unique;
say "# { %cells.elems } atoms, { @all.elems } cells";
exit 0 if @*ARGS.first({ $_ eq '--count-only' });

my @ids = @engines.map({ engine-id($_) });
my @obs;
for ^@engines -> $e {
    my $short = @ids[$e].split('-')[0];
    my %seen = cache-load-family($short);
    my @todo = @all.grep({ !%seen{$_} });
    if !@todo {
        say "# all { @all.elems } cells already on record for { @ids[$e] }";
        @obs.push: %seen;
        next;
    }
    say "# probing { @ids[$e] }: { @todo.elems } new of { @all.elems } …";
    my %fresh = run-parallel(@engines[$e], @todo, $JOBS, 200, 120, $TMP.add("sig-cache-{@ids[$e]}.tsv").absolute);
    for %fresh.keys -> $k { %fresh{$k}<label> = @ids[$e]; %seen{$k} = %fresh{$k} }

    my @missing = @todo.grep({ !%seen{$_} });
    if @missing {
        say "#   recovering { @missing.elems } lost cells by bisection …";
        my %filled = recover(@engines[$e], @missing);
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
    say "# re-probing { @ids[0] }: { @re.elems } cells …";
    my %fresh = run-parallel(@engines[0], @re, $JOBS, 200, 120, $TMP.add("sig-cache-{@ids[0]}-again.tsv").absolute);
    for %fresh.keys -> $k { %again{$k} = %fresh{$k} }
    cache-save(@ids[0] ~ '-again', %again);
}

# ----------------------------------------------------------------------- emit

my $ref = @obs[0];
my $outdir = $ROOT.add('generated/signatures');
$outdir.mkdir unless $outdir.e;

my $written = 0;
my $parked  = 0;

for %cells.keys.sort -> $atom {
    my %spec = %cells{$atom};
    my @out;
    @out.push: "atom     signatures/$atom";
    @out.push: "source   generated";
    @out.push: "gen      gen/signatures.raku";
    @out.push: %spec<kind> eq 'pair'
        ?? "arguments { %spec<args> eq '' ?? '(none)' !! %spec<args> }"
        !! "callform { %spec<form> }";
    @out.push: '';

    my $i = 0;
    for %spec<cells>.list -> %c {
        $i++;
        my $r = $ref{%c<expr>};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   signatures:{ %spec<kind> }";
        @out.push: "  cell   { %c<a> } | { %c<b> }";
        @out.push: "  level  { %c<level> // 3 }";
        @out.push: "  code   { %c<expr> }";

        my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG'
                         || $r<value> eq 'UNRENDERABLE');
        my $stable = %again{%c<expr>} && %again{%c<expr>}<value> eq $r<value>;

        if $r<value>.starts-with('ERR:') {
            @out.push: "  throws { $r<value>.substr(4) }";
        }
        else {
            @out.push: "  is     { textual($r<value>) }";
            @out.push: "  type   { $r<type> }";
        }

        for ^@engines -> $e {
            my $o = @obs[$e]{%c<expr>};
            next unless $o;
            @out.push: "  oracle { $o<label> // @ids[$e] } → { textual($o<value>) }";
        }

        if !$answered {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference produced no usable answer for this cell";
            @out.push: "  ruled  2026-08-18 against { @ids[0] }";
            $parked++;
        }
        elsif !$stable {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference answers differently on two identical runs, so there is nothing stable to assert";
            @out.push: "  ruled  2026-08-18 against { @ids[0] }";
            $parked++;
        }
        @out.push: '';
        $written++;
    }

    $outdir.add("$atom.grid").spurt(@out.join("\n"));
}

say "# wrote $written cells across { %cells.elems } signature atoms, $parked parked";
