#!/usr/bin/env raku
# gen/operators.raku — the operator matrix, driven by the documented inventory.
#
#   rakupp gen/operators.raku --engines=raku,/path/to/rakupp \
#                             --inventory=/path/to/inventory.json [--jobs=2]
#
# gen/ladder.raku works from a hand-written table of 53 operators, which is a
# guess about what the language contains. This one reads the inventory extracted
# from the official documentation — 125 infix, 18 prefix, 2 postfix — and
# crosses every one of them with a ladder. An operator the language documents and
# nobody tested becomes impossible rather than merely unlikely, which is the
# whole point of measuring coverage against an inventory instead of against
# whatever occurred to the person writing tests.
#
# One atom per operator, so `rakugrid matrix infix-plus` renders its cross.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

# Deliberately mixed rather than numeric: an operator's own type domain is
# already covered by gen/ladder.raku, and what an inventory-wide sweep adds is
# what happens ACROSS the type boundary, where the coercion bugs live.
constant @LADDER =
    '0', '1', '-1', '1/2', '0e0', 'NaN', '""', '"a"', 'True', 'Any', '(1,2)', '{a=>1}';

# Operators whose result depends on reaching an endpoint, and which therefore do
# not terminate for some perfectly ordinary operands: `0e0 ... NaN` never
# arrives. They need their own ladder rather than this one, so they are left to
# a later pass instead of being generated wrongly here.
constant @SKIP-SYM = '...', '...^', '^...', '^...^', 'xx', 'X~', 'X*';

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
    my $base = $TMP.add('op-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; pkill -9 -f op-probe 2>/dev/null; kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit 0";
    my $p = run('/bin/sh', '-c', $script);
    my $rc = $p.exitcode;
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;
    return { out => $out, exit => $rc };
}

sub run-parallel($cmd, @exprs, $jobs, $batch = 200, $secs = 120) {
    my $probe = $TMP.add('op-probe.raku');
    $probe.spurt($VALUE-PROBE);

    my %seen;
    my $total  = @exprs.elems;
    my $offset = 0;

    while $offset < $total {
        my @cmds;
        my @parts;
        for ^$jobs -> $j {
            my $from = $offset + $j * $batch;
            last if $from >= $total;
            my $to = min($from + $batch, $total) - 1;
            my $list = $TMP.add("op-list-$j.txt");
            $list.spurt(@exprs[$from .. $to].join("\n") ~ "\n");
            my $out = $TMP.add("op-out-$j.txt").absolute;
            $out.IO.unlink if $out.IO.e;
            @parts.push: $out;
            @cmds.push: "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) } > { sh-quote($out) } 2>/dev/null &";
        }
        last unless @cmds;

        my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; " ~ @cmds.join(' ') ~ " wait";
        my $proc = run('/bin/sh', '-c',
            "( $script ) & p=\$!; "
          ~ "( sleep $secs; pkill -9 -f op-probe 2>/dev/null; kill -9 \$p 2>/dev/null ) & w=\$!; "
          ~ "wait \$p; kill \$w 2>/dev/null; exit 0");
        my $ignored = $proc.exitcode;

        for @parts -> $f {
            next unless $f.IO.e;
            for $f.IO.slurp.lines -> $l {
                my @c = $l.split("\t");
                next unless @c >= 3;
                %seen{@c[0]} = { value => @c[1], type => @c[2] };
            }
            $f.IO.unlink;
        }
        $offset += $jobs * $batch;
        note "#     { min($offset, $total) } / $total" if min($offset, $total) %% 2000;
    }
    return %seen;
}

# Bisection, with a timeout that scales: a hang costs log2(n) waits, each only
# as long as its list could honestly need.
sub recover($cmd, @missing, $depth = 0) {
    return {} unless @missing;
    my $list  = $TMP.add("op-rec-$depth.txt");
    my $probe = $TMP.add('op-probe.raku');
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
    my $f = $TMP.add("op-cache-$id.tsv");
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
    $TMP.add("op-cache-$id.tsv").spurt(@lines.join("\n") ~ "\n");
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
sub slug($cat, $sym) {
    my $s = $sym.trim;
    my %named =
        '+' => 'plus', '-' => 'minus', '*' => 'times', '/' => 'divide',
        '%' => 'modulo', '**' => 'power', '~' => 'concat', 'x' => 'repeat',
        '==' => 'num-eq', '!=' => 'num-ne', '<' => 'lt', '>' => 'gt',
        '<=' => 'le', '>=' => 'ge', '<=>' => 'num-cmp', 'eq' => 'str-eq',
        'ne' => 'str-ne', 'lt' => 'str-lt', 'gt' => 'str-gt', 'le' => 'str-le',
        'ge' => 'str-ge', '&&' => 'and', '||' => 'or', '//' => 'defined-or',
        '^^' => 'xor', '=' => 'assign', ':=' => 'bind', ',' => 'comma',
        '..' => 'range', '..^' => 'range-excl-hi', '^..' => 'range-excl-lo',
        '^..^' => 'range-excl-both', '=>' => 'fatarrow', '~~' => 'smartmatch',
        '!~~' => 'not-smartmatch', '+&' => 'bit-and', '+|' => 'bit-or',
        '+^' => 'bit-xor', '+<' => 'shift-left', '+>' => 'shift-right',
        '?' => 'question', '!' => 'not', '++' => 'increment', '--' => 'decrement';

    return "$cat-{ %named{$s} }" if %named{$s}:exists;

    my $safe = $s.comb.map({
        /<[A..Za..z0..9-]>/ ?? $_ !! sprintf('u%02x', .ord)
    }).join;
    return "$cat-$safe";
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
my $JOBS = 2;
my $INV = '/Users/ash/raku.online/sites/spec/src/data/inventory.json';
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $JOBS    = +$a.substr(7)            if $a.starts-with('--jobs=');
    $INV     = $a.substr(12)            if $a.starts-with('--inventory=');
}

die "no inventory at $INV" unless $INV.IO.e;
my $raw = $INV.IO.slurp;

# The inventory is a small, flat JSON document; pull the fields we need without
# depending on a JSON module being installed for whichever engine runs this.
my @ops;
for $raw.split('{') -> $chunk {
    next unless $chunk.contains('"cat"') && $chunk.contains('"sym"');
    my $cat = $chunk ~~ /'"cat"' \s* ':' \s* '"' (<-["]>*) '"'/ ?? ~$0 !! '';
    my $sym = $chunk ~~ /'"sym"' \s* ':' \s* '"' (<-["]>*) '"'/ ?? ~$0 !! '';
    next unless $cat && $sym;
    @ops.push: { cat => $cat, sym => $sym };
}

my @wanted = @ops.grep({ .<cat> eq 'infix' | 'prefix' | 'postfix' })
                 .grep({ !@SKIP-SYM.first(-> $x { $x eq .<sym>.trim }) });

say "# inventory: { @ops.elems } operators, { @wanted.elems } usable here";

my %cells;
my @all;
for @wanted -> %o {
    my $sym = %o<sym>.trim;
    my @c;
    if %o<cat> eq 'infix' {
        for @LADDER -> $a {
            for @LADDER -> $b {
                @c.push: { a => $a, b => $b, expr => "($a) $sym ($b)" };
            }
        }
    }
    elsif %o<cat> eq 'prefix' {
        for @LADDER -> $a {
            @c.push: { a => $a, b => Nil, expr => "$sym($a)" };
        }
    }
    else {
        for @LADDER -> $a {
            @c.push: { a => $a, b => Nil, expr => "($a)$sym" };
        }
    }
    my $atom = slug(%o<cat>, $sym);
    %cells{$atom} = { cat => %o<cat>, sym => $sym, cells => @c };
    @all.append: @c.map(*<expr>);
}
@all = @all.unique;

say "# { %cells.elems } atoms, { @all.elems } cells";
exit 0 if @*ARGS.first({ $_ eq '--count-only' });

my @ids = @engines.map({ engine-id($_) });
my @obs;
for ^@engines -> $e {
    my %seen = cache-load(@ids[$e]);
    my @todo = @all.grep({ !%seen{$_} });
    if !@todo {
        say "# all { @all.elems } cells already on record for { @ids[$e] }";
        @obs.push: %seen;
        next;
    }
    say "# probing { @ids[$e] }: { @todo.elems } new of { @all.elems } …";
    my %fresh = run-parallel(@engines[$e], @todo, $JOBS);
    for %fresh.keys -> $k { %seen{$k} = %fresh{$k} }

    my @missing = @todo.grep({ !%seen{$_} });
    if @missing {
        say "#   recovering { @missing.elems } lost cells by bisection …";
        my %filled = recover(@engines[$e], @missing);
        for %filled.keys -> $k { %seen{$k} = %filled{$k} }
    }
    cache-save(@ids[$e], %seen);
    @obs.push: %seen;
}

my %again = cache-load(@ids[0] ~ '-again');
my @re = @all.grep({ !%again{$_} });
if @re {
    say "# re-probing { @ids[0] }: { @re.elems } cells …";
    my %fresh = run-parallel(@engines[0], @re, $JOBS);
    for %fresh.keys -> $k { %again{$k} = %fresh{$k} }
    cache-save(@ids[0] ~ '-again', %again);
}

my $ref = @obs[0];
my $outdir = $ROOT.add('generated/inventory');
$outdir.mkdir unless $outdir.e;

my $written = 0;
my $parked  = 0;

for %cells.keys.sort -> $atom {
    my %spec = %cells{$atom};
    my @out;
    @out.push: "atom     operators/$atom";
    @out.push: "source   generated";
    @out.push: "gen      gen/operators.raku";
    @out.push: "from-inventory { %spec<cat> } { %spec<sym> }";
    @out.push: "ladder   mixed";
    if %spec<cat> eq 'infix' {
        @out.push: "axes     { @LADDER.join(' | ') }";
        @out.push: "cols     { @LADDER.join(' | ') }";
    }
    @out.push: '';

    my $i = 0;
    for %spec<cells>.list -> %c {
        $i++;
        my $r = $ref{%c<expr>};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   inventory:{ %spec<cat> }:{ %spec<sym> }";
        @out.push: %c<b>.defined ?? "  cell   { %c<a> } | { %c<b> }" !! "  cell   { %c<a> }";
        @out.push: "  code   { %c<expr> }";

        my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG'
                         || $r<value> eq 'UNRENDERABLE');
        my $stable = %again{%c<expr>} && %again{%c<expr>}<value> eq $r<value>;

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

        if !$answered {
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

    $outdir.add("$atom.grid").spurt(@out.join("\n"));
}

say "# wrote $written cells across { %cells.elems } operators, $parked parked";
