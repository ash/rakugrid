#!/usr/bin/env raku
# gen/regex.raku — the regex grid: constructs × subjects × match forms.
#
#   rakupp gen/regex.raku --engines=raku,/path/to/rakupp [--jobs=auto]
#
# Regexes are the largest part of the language the suite has never touched, and
# historically the richest source of surprises — our own defect record has a
# dynamic variable lost across a subrule boundary, `|` behaving as LTM where
# `||` does not, and a character class read as a group.
#
# A cell asks a DERIVED question rather than comparing Match objects. A Match
# renders with positions and internals that differ between implementations for
# reasons that are not about matching, so `so($s ~~ /p/)`, `.Str`, `.from` and
# the result of a substitution are the observable facts worth asserting.
#
# Ladders are APPEND ONLY: ids come from position, and the pattern index is the
# density level, so the early patterns are the smoke set.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

# --- the axes ---------------------------------------------------------------

# Regex bodies, roughly in order of how ordinary they are: the first is the
# smoke cell, the early ones the core, the later ones the exotic.
constant @PATTERNS =
    # literal and dot
    'a', 'abc', '.', 'a b', '\\.', '\\w', '\\d', '\\s', '\\W', '\\D', '\\S',
    # character classes
    '<[abc]>', '<-[abc]>', '<[a..z]>', '<[a..z0..9]>', '<alpha>', '<digit>',
    '<upper>', '<lower>', '<space>', '<punct>', '<xdigit>', '<[\\d_]>',
    # quantifiers
    'a*', 'a+', 'a?', 'a ** 2', 'a ** 1..3', 'a ** 2..*', '.*', '.+',
    'a*?', 'a+?', 'a??', '[ab]*', '\\d+', '\\w*',
    # anchors
    '^ a', 'a $', '^^ a', 'a $$', '<< a', 'a >>', '^ .* $', '<|w> a',
    # alternation and grouping
    'a | b', 'a || b', '[a | b]', '[a || b]', 'ab | a', 'a [b | c]',
    # captures
    '(a)', '(a) (b)', '(a) (b) (c)', '[a] (b)', '(a+)', '(\\w) (\\w)',
    '$<x> = (a)', '$<x> = [a]', '<x = .alpha>',
    # backreference
    '(a) $0', '(\\w) $0',
    # lookaround
    '<?[a]>', '<![a]>', 'a <?before b>', 'a <!before b>',
    '<?after a> b', '<!after a> b', '<?[a]> \\w',
    # built-in rules and whitespace
    '<ws>', '<alpha>+', '<!alpha>', '<.ws> a', 'a <.ws> b',
    # adverbs on the regex itself
    ':i a', ':i ABC', ':m a', ':r a+', ':s a b', ':i <[a..z]>',
    # nested and quantified groups
    '[a b]+', '[a | b]+', '(a | b)+', '[\\d ** 2]+', '[<alpha> <digit>]',
    # interpolation-free specials
    '\\n', '\\t', '\\0', '.**2', '<[\\x41]>',
    # empty and near-empty, which is where zero-width behaviour shows
    '', '[]';

# What to match against.
constant @SUBJECTS =
    '"a"', '"abc"', '""', '"aaa"', '"ABC"', '"a b"', '"a,b"', '"123"',
    '"a\\nb"', '" a "', '"aä"', '"e\\c[COMBINING ACUTE ACCENT]"', '"abcabc"',
    '"0"', '"_"', '"a1b2"';

# How the match is observed. `{S}` is the subject, `{P}` the pattern.
constant @FORMS =
    { name => 'matches',   form => 'so({S} ~~ /{P}/)' },
    { name => 'matched',   form => '({S} ~~ /{P}/).Str' },
    { name => 'from',      form => '({S} ~~ /{P}/).from' },
    { name => 'captures',  form => '({S} ~~ /{P}/).list.map(*.Str).join(",")' },
    { name => 'subst',     form => '{S}.subst(/{P}/, "X")' },
    { name => 'subst-g',   form => '{S}.subst(/{P}/, "X", :g)' },
    { name => 'comb-count', form => '{S}.comb(/{P}/).elems' },
    { name => 'split',     form => '{S}.split(/{P}/).elems' };

# --- machinery (same discipline as the other generators) --------------------

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
    my $base = $TMP.add('rx-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
    my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; "
               ~ "$line > { sh-quote($base ~ '.out') } 2> { sh-quote($base ~ '.err') } & p=\$!; "
               ~ "( sleep $secs; kill -9 \$p 2>/dev/null ) & w=\$!; "
               ~ "wait \$p; rc=\$?; kill \$w 2>/dev/null; exit 0";
    my $p = run('/bin/sh', '-c', $script);
    my $rc = $p.exitcode;
    my $out = ($base ~ '.out').IO.e ?? ($base ~ '.out').IO.slurp !! '';
    ($base ~ '.out').IO.unlink if ($base ~ '.out').IO.e;
    ($base ~ '.err').IO.unlink if ($base ~ '.err').IO.e;
    return { out => $out, exit => $rc };
}

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
    return +$0 if $t ~~ / (\d+ '.' \d+) /;
    return 999;
}

sub adaptive-jobs($requested, $ceiling = 6) {
    return $requested unless $requested ~~ Str && $requested eq 'auto';
    return max(1, min($ceiling, (cores() - load-now() - 1).floor));
}

# A zero-width pattern under :g can match forever. The batch timeout plus
# bisection is what makes that survivable rather than fatal.
sub run-parallel($cmd, @exprs, $jobs, $batch = 200, $secs = 120) {
    my $probe = $TMP.add('rx-probe.raku');
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
            my $list = $TMP.add("rx-list-$j.txt");
            $list.spurt(@exprs[$from .. $to].join("\n") ~ "\n");
            my $out = $TMP.add("rx-out-$j.txt").absolute;
            $out.IO.unlink if $out.IO.e;
            @parts.push: $out;
            @cmds.push: "{ sh-quote($cmd) } { sh-quote($probe.absolute) } { sh-quote($list.absolute) } > { sh-quote($out) } 2>/dev/null &";
        }
        last unless @cmds;

        my $script = "exec >/dev/null 2>&1; set -m 2>/dev/null || true; " ~ @cmds.join(' ') ~ " wait";
        my $proc = run('/bin/sh', '-c',
            "( $script ) & p=\$!; "
          ~ "( sleep $secs; kill -9 \$p 2>/dev/null ) & w=\$!; "
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
        $offset += $now * $batch;
        note "#     { min($offset, $total) } / $total" if min($offset, $total) %% 2000;
    }
    return %seen;
}

sub recover($cmd, @missing, $depth = 0) {
    return {} unless @missing;
    my $list  = $TMP.add("rx-rec-$depth.txt");
    my $probe = $TMP.add('rx-probe.raku');
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

sub build-distance($s) {
    return +$0 if $s ~~ / '-' (\d+) '-g' /;
    return 0;
}

sub cache-load-family($short) {
    my %seen;
    my @files = $TMP.dir.grep({ .basename.starts-with('rx-cache-' ~ $short) && .extension eq 'tsv' });
    for @files.sort({ build-distance(.basename) }) -> $f {
        my $label = $f.basename.subst('rx-cache-', '').subst('.tsv', '');
        next if $label.ends-with('-again');
        for $f.slurp.lines -> $l {
            my @p = $l.split("\t");
            next unless @p >= 3;
            %seen{@p[0]} = { value => @p[1], type => @p[2], label => $label };
        }
    }
    return %seen;
}

sub cache-save($id, %seen) {
    my @lines;
    for %seen.keys.sort -> $k {
        @lines.push: join("\t", $k, %seen{$k}<value>, %seen{$k}<type>);
    }
    $TMP.add("rx-cache-$id.tsv").spurt(@lines.join("\n") ~ "\n");
}

sub textual($v) {
    return $v if try { $v.encode('utf-8').decode('utf-8') === $v };
    return 'INVALID-UTF8:' ~ (try { $v.ords.map(*.base(16)).join(' ') } // 'unrenderable');
}

sub engine-id($cmd) {
    my $p = run($cmd, '-e', 'print $*RAKU.compiler.name', :out, :err);
    my $name = $p.out.slurp(:close).trim;
    $p.err.slurp(:close);

    my $b = run($cmd, '-e', 'print (try $*RAKU.compiler.build) // ""', :out, :err);
    my $build = $b.out.slurp(:close).trim;
    $b.err.slurp(:close);

    my $short = $name.contains('Raku++') || $name.lc.contains('rakupp')
        ?? 'rakupp' !! ($name || 'unknown');
    return "$short-$build" if $build;

    my $p2 = run($cmd, '-e', 'print $*RAKU.compiler.version', :out, :err);
    my $ver = $p2.out.slurp(:close).trim;
    $p2.err.slurp(:close);
    return "$short-" ~ ($ver || 'unknown');
}

# Lowercase and digits pass through; EVERYTHING else is hex-encoded, uppercase
# letters included. That last part is not fussiness: macOS filesystems are
# case-insensitive, so a case-preserving slug puts `\D` and `\d` in the same
# file and the second write silently destroys the first. It cost the `\D`,
# `\S` and `\W` atoms — 384 records — before anyone noticed, because the
# generator's own count was right and only the files were missing.
sub slug($p) {
    my $s = $p.trim;
    return 'empty' unless $s;
    return $s.comb.map({ /<[a..z0..9]>/ ?? $_ !! sprintf('%02x', .ord) }).join.substr(0, 40);
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
my $JOBS = 2;
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
    $JOBS    = ($a.substr(7) eq 'auto' ?? 'auto' !! +$a.substr(7)) if $a.starts-with('--jobs=');
}

my @cells;
for ^@PATTERNS.elems -> $pi {
    my $pat = @PATTERNS[$pi];
    my $lvl = $pi == 0 ?? 0 !! $pi <= 10 ?? 1 !! $pi <= 40 ?? 2 !! 3;
    for @SUBJECTS -> $subj {
        for @FORMS -> %f {
            @cells.push: {
                pattern => $pat, subject => $subj, form => %f<name>, level => $lvl,
                expr => %f<form>.subst('{S}', $subj, :g).subst('{P}', $pat, :g),
            };
        }
    }
}
my @all = @cells.map(*<expr>).unique;

say "# { @PATTERNS.elems } patterns × { @SUBJECTS.elems } subjects × { @FORMS.elems } forms";
say "# { @all.elems } distinct expressions, { @cells.elems } records to write";
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
    my %fresh = run-parallel(@engines[$e], @todo, $JOBS);
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

my %again = cache-load-family(@ids[0].split('-')[0] ~ '-again');
my @re = @all.grep({ !%again{$_} });
if @re {
    say "# re-probing { @ids[0] }: { @re.elems } cells …";
    my %fresh = run-parallel(@engines[0], @re, $JOBS);
    for %fresh.keys -> $k { %again{$k} = %fresh{$k} }
    cache-save(@ids[0] ~ '-again', %again);
}

my $ref = @obs[0];
my $outdir = $ROOT.add('generated/regex');
$outdir.mkdir unless $outdir.e;

# One atom per pattern: `rakugrid matrix` then renders subjects × forms for it.
my %by-pattern;
for @cells -> %c {
    %by-pattern{%c<pattern>} = [] unless %by-pattern{%c<pattern>}:exists;
    %by-pattern{%c<pattern>}.push: %c;
}

my $written = 0;
my $parked  = 0;

for @PATTERNS.unique -> $pat {
    my @out;
    @out.push: "atom     regexes/{ slug($pat) }";
    @out.push: "source   generated";
    @out.push: "gen      gen/regex.raku";
    @out.push: "pattern  /{ $pat }/";
    @out.push: "axes     { @SUBJECTS.join(' | ') }";
    @out.push: "cols     { @FORMS.map(*<name>).join(' | ') }";
    @out.push: '';

    my $i = 0;
    for %by-pattern{$pat}.list -> %c {
        $i++;
        my $r = $ref{%c<expr>};
        next unless $r;

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   regex:{ %c<form> }";
        @out.push: "  cell   { %c<subject> } | { %c<form> }";
        @out.push: "  level  { %c<level> }";
        @out.push: "  code   { %c<expr> }";

        my $answered = !($r<value>.starts-with('CRASH') || $r<value> eq 'HANG'
                         || $r<value> eq 'UNRENDERABLE');

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

        unless $answered {
            @out.push: "  verdict disputed";
            @out.push: "  why    the reference produced no usable answer for this cell — a zero-width pattern under :g, or a construct it cannot complete";
            @out.push: "  ruled  2026-08-18 against { @ids[0] }";
            $parked++;
        }
        @out.push: '';
        $written++;
    }

    $outdir.add(slug($pat) ~ '.grid').spurt(@out.join("\n"));
}

say "# wrote $written cells across { @PATTERNS.unique.elems } patterns, $parked parked";
