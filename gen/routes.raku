#!/usr/bin/env raku
# gen/routes.raku — the route grid: do two ways to the same answer agree?
#
#   rakupp gen/routes.raku
#
# A construct is usually reachable more than one way. A type relationship can be
# asked with `~~`, by binding a parameter, or by letting multi dispatch choose.
# A named regex can be reached as `<R>` inside another regex, as the `&R`
# Callable, or through `.ACCEPTS`. The routes are different code paths in an
# implementation, and nothing makes them agree except that they must.
#
# They are also where Raku++ kept breaking, in a way no single-route test could
# see. `(a => 1) ~~ Associative` answered True while an `Associative:D`
# parameter refused to bind the same Pair — each route was self-consistent and
# they contradicted each other. `sub f(WhateverCode:D $x)` given `*-0` failed
# its own bind with "expected WhateverCode but got WhateverCode", because `~~`
# answered from one table and the binder from another. And `my rule R { ab cd }`
# matched "ab cd" as `<R>` and "abcd" as `&R` — the exact inverse — because the
# declarator's sigspace flag reached one path and not the other.
#
# These laws need no oracle: two routes disagreeing inside ONE engine is a
# defect without anyone deciding which answer was right. `same-as` carries them.
#
# One trap is already on record in this repo and applies here. An argument
# passed LITERALLY (`f("a")` against `Int $a`) is rejected by Rakudo at COMPILE
# time, which `fire` reads as a dead program rather than a binding answer. Every
# argument below therefore travels through a capture — `my $A = \(…); f(|$A)` —
# which keeps each cell a runtime question.
#
# The `regex`/`token` cells whose pattern is `ab cd` draw a "space is not
# significant here" warning from Rakudo. That is the point of the cell, not a
# problem with it: the same source spaces under `rule` and concatenates under
# the other two, and an engine that gets that backwards through one route only
# is what this grid is for.
#
# Ids come from position within an atom, so new cells must be APPENDED.

my $ROOT = $*PROGRAM.IO.absolute.IO.parent.parent;

# --- type relationships ---------------------------------------------------
constant @VALUES =
    '1', '"a"', '1.5', '(a => 1)', '(1,2)', '[1,2]', '{:a(1)}', '*-0',
    '{ $_ }', '/x/', 'Any', 'Nil', '1..3', 'True', 'set(1)', 'now.Date';

# `Any` and `Mu` are left out on purpose: `multi m(Any $x)` and `multi m($x)`
# are the SAME signature, so the dispatch route cannot be posed for them.
constant @TYPES =
    'Int', 'Str', 'Cool', 'Associative', 'Positional', 'Iterable',
    'Callable', 'Numeric', 'Pair';

# --- named regexes --------------------------------------------------------
constant @KINDS    = 'regex', 'token', 'rule';
constant @PATTERNS = "'ab'", "'ab' 'cd'", 'ab cd', '\d+', "'a' | 'b'",
                     '[<[a..c]>]+', "'x' \\s* 'y'";
constant @SUBJECTS = "'ab'", "'abcd'", "'ab cd'", "'zab'", "'123'", "''", "'x  y'";

sub smartmatch($v, $t) { "so(($v) ~~ $t)" }

sub by-binding($v, $t) {
    # through a capture: a literal argument would be a COMPILE-time rejection
    'so(do { my $A = \\(' ~ $v ~ '); sub f(' ~ $t ~ ' $x) { True }; (try f(|$A)) // False })'
}

sub by-dispatch($v, $t) {
    'so(do { my $A = \\(' ~ $v ~ '); multi m(' ~ $t ~ ' $x) { True }; multi m($x) { False }; m(|$A) })'
}

sub rx-decl($kind, $pat) { 'my ' ~ $kind ~ ' r { ' ~ $pat ~ ' }; ' }
sub by-callable($kind, $pat, $subj) { 'do { ' ~ rx-decl($kind, $pat) ~ 'so(' ~ $subj ~ ' ~~ &r) }' }
sub by-subrule($kind, $pat, $subj)  { 'do { ' ~ rx-decl($kind, $pat) ~ 'so(' ~ $subj ~ ' ~~ / <r> /) }' }
sub by-accepts($kind, $pat, $subj)  { 'do { ' ~ rx-decl($kind, $pat) ~ 'so(&r.ACCEPTS(' ~ $subj ~ ')) }' }

sub emit($atom, $law, $why, $bug, @cells) {
    my @out;
    @out.push: "atom     $atom";
    @out.push: "source   generated";
    @out.push: "gen      gen/routes.raku";
    @out.push: "law      $law";
    @out.push: "why      $why";
    @out.push: "ladder   { @cells.elems } crossings";
    @out.push: '';

    my $i = 0;
    for @cells -> %c {
        $i++;
        my $from = 'law:' ~ $atom.split('/')[*-1];
        $from ~= ' · bug:' ~ $bug if $bug;
        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   $from";
        @out.push: "  cell   { %c<cell> }";
        @out.push: "  code   { %c<lhs> }";
        @out.push: "  same-as { %c<rhs> }";
        @out.push: '';
    }
    my $path = $ROOT.add("generated/$atom.grid");
    $path.parent.mkdir unless $path.parent.e;
    $path.spurt(@out.join("\n"));
    return @cells.elems;
}

my @bind;
my @disp;
for @VALUES -> $v {
    for @TYPES -> $t {
        @bind.push: { cell => "$v ~~ $t", lhs => smartmatch($v, $t), rhs => by-binding($v, $t) };
        @disp.push: { cell => "$v ~~ $t", lhs => smartmatch($v, $t), rhs => by-dispatch($v, $t) };
    }
}

my @sub;
my @acc;
for @KINDS -> $k {
    for @PATTERNS -> $p {
        for @SUBJECTS -> $s {
            @sub.push: { cell => "$k \{ $p \} vs $s",
                         lhs => by-callable($k, $p, $s), rhs => by-subrule($k, $p, $s) };
            @acc.push: { cell => "$k \{ $p \} vs $s",
                         lhs => by-callable($k, $p, $s), rhs => by-accepts($k, $p, $s) };
        }
    }
}

my $cells = 0;
$cells += emit('routes/smartmatch-is-binding',
    'V ~~ T  ===  binding V to a T parameter',
    'the type check a parameter performs is the one `~~` answers',
    'rakupp-pair-not-associative', @bind);

$cells += emit('routes/smartmatch-is-dispatch',
    'V ~~ T  ===  multi dispatch choosing the T candidate',
    'the type a multi dispatches on is the one `~~` answers',
    'rakupp-whatevercode-not-in-type-matcher', @disp);

$cells += emit('routes/callable-is-subrule',
    '$s ~~ &R  ===  $s ~~ / <R> /',
    'a named regex means the same reached as a Callable as it does as a subrule',
    'rakupp-named-regex-callable-lost-its-flags', @sub);

$cells += emit('routes/callable-is-accepts',
    '$s ~~ &R  ===  &R.ACCEPTS($s)',
    'smartmatching a Callable IS calling its ACCEPTS',
    'rakupp-named-regex-callable-lost-its-flags', @acc);

say "# gen/routes.raku: 4 atoms, $cells cells in generated/routes/";
say "# no observations recorded — `same-as` is the oracle-free lane";
