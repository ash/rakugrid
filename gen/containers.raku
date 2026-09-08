#!/usr/bin/env raku
# gen/containers.raku — the construction grid: does this spelling flatten?
#
#   rakupp gen/containers.raku
#
# `[X]`, `(X,)`, `Array.new(X)` and `List.new(X)` are four ways to put one thing
# in a container, and they do NOT all mean the same. The one-argument rule says
# `[@a]` is the elements of @a while `[@a,]` is @a itself; `Array.new` flattens
# where `List.new` takes its arguments as elements; and an ITEMISED value —
# anything reached through a `$` — is one element however it is spelled.
#
# None of that is an operator or a method, so the inventory-driven generators do
# not reach it: `operators.raku` enumerates 182 operators and `methods.raku` 667
# methods, and a bracket is neither. Raku++ had four defects living in exactly
# that hole at once — `[{}]` was a one-element array where Raku says it is
# EMPTY, `[%h]` did not spread to its pairs, `List.new([1,2])` flattened to two
# elements, and `qw<8>` produced an allomorph so a word behaved like an Int.
# Every one produced a perfectly ordinary value of the wrong SHAPE, which is
# why an assertion-based suite walked past them.
#
# The laws below are oracle-free — they relate two spellings to each other, so
# `same-as` carries them and no reference run is needed.
#
# Two ladder rules, both learned by probing rather than reasoning:
#
#   * The ladder holds only NON-ITEMISED spellings. `[$s].elems` is 1 while
#     `$s.elems` is 3, and that is the rule working, not breaking it — so the
#     itemised case gets its own law with its own ladder rather than polluting
#     this one.
#   * A multi-key hash renders its pairs in iteration order, which is
#     unordered by spec. `Array.new({:a(1),:b(2)})` and `[{:a(1),:b(2)}]` agree
#     on content and disagree on rendering, which is noise these laws are not
#     about. Single-key hashes only.
#
# `Empty` is left out for a third reason: it is a vanishing Slip, so `[Empty,]`
# has no elements and the trailing-comma law genuinely does not apply to it.
# That is the Slip law's business.
#
# Ids come from position within an atom, so new cells must be APPENDED.

my $ROOT = $*PROGRAM.IO.absolute.IO.parent.parent;

# Declared in every cell, so a cell is self-contained and two cells in one
# process cannot collide.
constant SETUP = 'my %h = :a(1); my @a = 1, 2, 3; my $s = (1, 2, 3);';

constant @LADDER =
    '1', '"a"', '(1,2,3)', '[1,2,3]', '{}', '{:a(1)}', '(1..3)',
    '<a b>', '()', '(1,)', 'Nil', '%h', '@a', '$s.list';

# the itemised ladder: values reached through a `$`, where the one-argument
# rule does NOT reach through
constant @ITEMISED = '1', '(1,2,3)', '[1,2,3]', '{:a(1)}', '(1..3)', '<a b>';

constant @LAWS =
    # the one-argument rule itself: a lone container spreads into the literal
    { atom => 'containers/one-arg-spreads',
      lhs  => '[{X}].elems',   rhs => '({X}).elems',
      why  => 'a lone container argument spreads, so the literal has its elements',
      bug  => 'rakupp-single-hash-does-not-spread' },

    # …and a trailing comma takes the argument OUT of the rule
    { atom => 'containers/trailing-comma-is-one',
      lhs  => '[{X},].elems', rhs => '1',
      why  => 'a trailing comma defeats the one-argument rule: one element, whatever it is',
      bug  => '' },

    { atom => 'containers/trailing-comma-holds-it',
      lhs  => '[{X},][0]',    rhs => '({X})',
      why  => 'and the one element it holds is the argument itself',
      bug  => '' },

    # Array.new flattens; the bracket does too
    { atom => 'containers/array-new-is-bracket',
      lhs  => 'Array.new({X})', rhs => '[{X}]',
      why  => 'Array.new and the bracket literal are the same construction',
      bug  => '' },

    # List.new does NOT flatten — its arguments are elements
    { atom => 'containers/list-new-takes-elements',
      lhs  => 'List.new({X})', rhs => '({X},)',
      why  => 'List.new takes its arguments AS ELEMENTS, unlike Array.new',
      bug  => 'rakupp-list-new-flattened' },

    # an explicit slip always flattens, whatever the one-argument rule does
    { atom => 'containers/slip-flattens',
      lhs  => '[|{X}].elems', rhs => '({X}).elems',
      why  => 'an explicit slip flattens regardless of the one-argument rule',
      bug  => '' },

    { atom => 'containers/paren-comma-is-one',
      lhs  => '({X},).elems', rhs => '1',
      why  => 'the parenthesised trailing comma is the one-element list',
      bug  => '' },

    { atom => 'containers/seq-preserves-count',
      lhs  => '({X}).Seq.elems', rhs => '({X}).elems',
      why  => 'reifying as a Seq changes the type, not the element count',
      bug  => '' },

    { atom => 'containers/flat-is-idempotent',
      lhs  => '[{X}].flat.elems', rhs => '[{X}].flat.flat.elems',
      why  => 'flattening twice is flattening once',
      bug  => '' };

# The itemised counterpart stands alone: its ladder is values held in a `$`,
# where the one-argument rule does not reach through the container.
constant ITEMISED-LAW =
    { atom => 'containers/itemised-is-one',
      lhs  => 'do { my $it = {X}; [$it].elems }', rhs => '1',
      why  => 'a value reached through a `$` is ONE element however it is spelled',
      bug  => '' };

sub fill($tpl, $x) { $tpl.subst('{X}', $x, :g) }

sub emit(%law, @ladder, $with-setup) {
    my @out;
    @out.push: "atom     { %law<atom> }";
    @out.push: "source   generated";
    @out.push: "gen      gen/containers.raku";
    @out.push: "law      { %law<lhs> }  ===  { %law<rhs> }";
    @out.push: "why      { %law<why> }";
    @out.push: "ladder   { @ladder.elems } spellings";
    @out.push: '';

    my $i = 0;
    for @ladder -> $x {
        $i++;
        my $from = 'law:' ~ %law<atom>.split('/')[*-1];
        $from ~= ' · bug:' ~ %law<bug> if %law<bug>;
        my $pre = $with-setup ?? SETUP ~ ' ' !! '';

        # built in pieces: `$pre{ … }` reads as an associative index on $pre,
        # not as interpolation next to it
        my $lhs = $pre ~ fill(%law<lhs>, $x);
        my $rhs = $pre ~ fill(%law<rhs>, $x);

        @out.push: "- id     { sprintf('%04d', $i) }";
        @out.push: "  from   $from";
        @out.push: "  cell   $x";
        @out.push: "  code   do \{ $lhs \}";
        @out.push: "  same-as do \{ $rhs \}";
        @out.push: '';
    }
    my $path = $ROOT.add("generated/{ %law<atom> }.grid");
    $path.parent.mkdir unless $path.parent.e;
    $path.spurt(@out.join("\n"));
    return @ladder.elems;
}

my $cells = 0;
$cells += emit($_, @LADDER, True) for @LAWS;
$cells += emit(ITEMISED-LAW, @ITEMISED, False);

say "# gen/containers.raku: { @LAWS.elems + 1 } atoms, $cells cells in generated/containers/";
say "# no observations recorded — `same-as` is the oracle-free lane";
