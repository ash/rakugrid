#!/usr/bin/env raku
# gen/syntax.raku — the parse grid: which spellings compile, and which do not.
#
#   rakupp gen/syntax.raku --engines=raku,/path/to/rakupp
#
# Every other generator asks what an expression EVALUATES to. This one asks
# whether it compiles at all, which is a different question and the one that
# actually blocks running real programs: an engine that cannot parse a
# declarator, a parameter form or a phaser placement never reaches the point
# where a value could be wrong.
#
# Each fragment is a COMPLETE program, compiled with `-c` and never run. The
# expected answer comes from the reference implementation, and the assertion is
# only ever "compiles" or "does not compile" — never the wording of the
# diagnostic. Message prose is not specified, and asserting one engine's phrasing
# would test the message instead of the language.
#
# Fragments are ORDER-SENSITIVE within an atom: ids come from position, so new
# ones must be APPENDED.

my $ROOT  = $*PROGRAM.IO.absolute.IO.parent.parent;
my $TMP   = $ROOT.add('tmp');
$TMP.mkdir unless $TMP.e;
my $GUARD = 0;

sub sh-quote($s) {
    return "'" ~ $s.subst("'", "'\\''", :g) ~ "'";
}

sub run-cmd($cmd, @args, $secs = 20) {
    my $base = $TMP.add('syn-' ~ $*PID ~ '-' ~ $GUARD++).absolute;
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

sub compiles($cmd, $code, $n) {
    my $f = $TMP.add("frag-$n.raku");
    $f.spurt($code ~ "\n");
    my %r = run-cmd($cmd, ['-c', $f.absolute]);
    $f.unlink if $f.e;
    my $msg = (%r<err> ~ %r<out>).lines.grep({ .trim }).head(1).join(' ').subst("\t", ' ', :g);
    return { ok => %r<exit> == 0, msg => $msg.chars > 120 ?? $msg.substr(0, 117) ~ '…' !! $msg };
}

# ------------------------------------------------------------------ fragments

my @frags;      # { atom, code, note }

sub frag($atom, $code, $note = '') {
    @frags.push: { atom => $atom, code => $code, note => $note };
}

# --- declarators ------------------------------------------------------------
# scope × sigil × twigil × type. `has` needs a class around it; the rest stand
# alone. Many of these are illegal, which is the point — an engine that accepts
# `my $!x` at file scope is as wrong as one that rejects `has $!x` in a class.
for <my our state has> -> $scope {
    for <$ @ % &> -> $sigil {
        for ('', '!', '.', '*', '?', '^') -> $twigil {
            for ('', 'Int ') -> $type {
                my $decl = "$scope $type$sigil$twigil" ~ 'x';
                my $code = $scope eq 'has'
                    ?? "class C \{ $decl; \}"
                    !! "$decl;";
                frag('syntax/declarator', $code, "$scope $sigil$twigil");
            }
        }
    }
}

# --- declarator traits ------------------------------------------------------
for <my has> -> $scope {
    for ('is rw', 'is readonly', 'is default(1)', 'is required', 'is built',
         'is DEPRECATED', 'is Awkward', 'is rw is default(1)') -> $trait {
        my $decl = "$scope \$x $trait";
        frag('syntax/declarator-traits',
             $scope eq 'has' ?? "class C \{ $decl; \}" !! "$decl;",
             "$scope … $trait");
    }
}

# --- signature parameters ---------------------------------------------------
my @params =
    '$a', '$a?', '$a = 1', '$a is rw', '$a is copy', '$a is raw',
    'Int $a', 'Int:D $a', 'Int:U $a', 'Int:_ $a', '$a where * > 0',
    ':$a', ':$a!', ':$a = 1', ':a($b)', ':$a is copy',
    '*@a', '**@a', '+@a', '*%h', '|c', '\a',
    '@a', '%h', '&f', '&f:(Int)', '[$a, $b]', '$ ', '@',
    'Int', 'Int $', '::T $a', 'T', '$a where { $_ > 0 }';

for @params -> $p {
    frag('syntax/signature-param', "sub f($p) \{ \}", $p);
}

# two-parameter orderings: the interesting illegalities are about ORDER
for ('$a, $b', '$a?, $b', '$a, $b?', '*@a, $b', '$a, *@b', ':$a, $b',
     '$a, :$b', '*%h, $a', '$a, *%h', '|c, $a', '$a, |c', '\a, $b') -> $pair {
    frag('syntax/signature-order', "sub f($pair) \{ \}", $pair);
}

# --- phaser placement -------------------------------------------------------
my @phasers = <BEGIN CHECK INIT END ENTER LEAVE KEEP UNDO FIRST NEXT LAST
               PRE POST CATCH CONTROL DOC QUIT CLOSE COMPOSE>;

for @phasers -> $ph {
    frag('syntax/phaser-file',  "$ph \{ 1 \}",                      "$ph at file scope");
    frag('syntax/phaser-sub',   "sub f() \{ $ph \{ 1 \} \}",        "$ph in a sub");
    frag('syntax/phaser-loop',  "for 1..2 \{ $ph \{ 1 \} \}",       "$ph in a loop");
    frag('syntax/phaser-class', "class C \{ $ph \{ 1 \} \}",        "$ph in a class");
}

# --- quoting forms ----------------------------------------------------------
for <q qq Q> -> $q {
    for ('', ':s', ':!s', ':c', ':!c', ':b', ':!b', ':a', ':h', ':f', ':x',
         ':w', ':ww', ':v', ':to', ':q', ':qq', ':s:c', ':w:v') -> $adv {
        frag('syntax/quoting-adverbs', "my \$x = $q$adv\{abc\};", "$q$adv");
    }
}

for ('<a b>', '<<a b>>', '«a b»', 'qw/a b/', 'qww/a b/', 'q:w/a b/',
     'Q:b/a\nb/', 'q[a]', 'q{a}', 'q(a)', 'q!a!', 'q«a»') -> $form {
    frag('syntax/quoting-forms', "my \@x = $form;", $form);
}

# --- colonpairs in an argument list ----------------------------------------
for (':a', ':!a', ':a(1)', ':a<b>', ':a<b c>', ':$a', ':a{1}', 'a => 1',
     ':a[1,2]', ':1a', ':2nd', ':a«b»', ':::a') -> $cp {
    frag('syntax/colonpair', "sub f(|c) \{ \}; my \$a = 1; f($cp);", $cp);
}

# --- statement modifiers ----------------------------------------------------
for ('if 1', 'unless 0', 'while 0', 'until 1', 'for 1..2', 'given 1',
     'with 1', 'without Nil', 'if 1 for 1..2', 'for 1..2 if 1',
     'when 1', 'orwith 1') -> $mod {
    frag('syntax/statement-modifier', "my \$x; \$x = 1 $mod;", $mod);
}

# --- terms and operators in term position -----------------------------------
for ('&infix:<+>', '&prefix:<->', '&postfix:<++>', '&circumfix:<[ ]>',
     '&postcircumfix:<[ ]>', '&infix:«+»', '&term:<foo>', '&infix:<does>',
     '&infix:<+>(1,2)', '(&infix:<+>)(1,2)') -> $t {
    frag('syntax/routine-term', "my \$x = $t;", $t);
}

# ------------------------------------------------------------------------ run

my @engines = 'raku';
for @*ARGS -> $a {
    @engines = $a.substr(10).split(',') if $a.starts-with('--engines=');
}

my @ids = @engines.map({ engine-id($_) });
say "# { @frags.elems } fragments across { @frags.map(*<atom>).unique.elems } atoms";
say "# engines: { @ids.join(', ') }";

my %by-atom;
for @frags -> %f {
    %by-atom{%f<atom>} = [] unless %by-atom{%f<atom>}:exists;
    %by-atom{%f<atom>}.push: %f;
}

my $n = 0;
my $parses = 0;
my $rejects = 0;

for %by-atom.keys.sort -> $atom {
    my @out;
    @out.push: "atom     $atom";
    @out.push: "source   generated";
    @out.push: "gen      gen/syntax.raku";
    @out.push: "kind     parse grid — compiled with -c, never run";
    @out.push: '';

    my $i = 0;
    for %by-atom{$atom}.list -> %f {
        $i++;
        $n++;
        my @obs = @engines.map({ compiles($_, %f<code>, $n) });
        my $ref = @obs[0];

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   syntax:{ %f<note> || 'grid' }";
        @out.push: "  code   { %f<code> }";

        if $ref<ok> {
            @out.push: "  parses yes";
            $parses++;
        }
        else {
            @out.push: "  no-parse the reference rejects this spelling";
            $rejects++;
        }

        for ^@engines -> $e {
            my $o = @obs[$e];
            @out.push: "  oracle { @ids[$e] } → { $o<ok> ?? 'compiles' !! 'rejected: ' ~ $o<msg> }";
        }
        @out.push: '';
    }

    my $file = $ROOT.add("generated/$atom.grid");
    $file.parent.mkdir unless $file.parent.e;
    $file.spurt(@out.join("\n"));
    say "  $atom: { $i }";
}

say "# wrote $n fragments — $parses compile, $rejects are rejected by the reference";
