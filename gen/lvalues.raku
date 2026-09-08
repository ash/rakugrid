#!/usr/bin/env raku
# gen/lvalues.raku — the write-through grid: does a write reach the container?
#
#   rakupp gen/lvalues.raku
#
# Every other generator asks what an expression PRODUCES. This one asks where a
# write LANDS, which is a different question and the one the others cannot pose:
# their cells are shaped `code → .raku`, so the answer has to be a value, and
# "the caller's variable changed" is not a value.
#
# The gap is not hypothetical. `signatures.raku` covers `is rw` in 13,912 cells,
# every one of them a BINDING question —
#
#     my $A = \(1); sub f($a is rw) { $a }; f(|$A)
#
# — which asks whether the argument binds and what the body sees. None asks what
# `is rw` is FOR:
#
#     sub f($x is rw) is rw { return-rw $x }; my $v = 1; f($v) = 7; $v
#
# Raku++ shipped for months with that second form silently writing into a frame
# copy: `is rw` worked on a method and not on a sub, a sigilless `\c` bound a
# copy rather than the caller's container, and `return-rw` of a local handed out
# a pointer to a dead frame. Roast passed throughout — it asserts values, and a
# lost write leaves a perfectly ordinary value behind.
#
# The law is oracle-free, which is why this generator records no observations:
#
#     writing through ANY route reaches the same container as writing directly.
#
# `same-as` carries it. An engine that disagrees with itself is wrong without
# anyone deciding what the right answer was, so these cells need no reference
# run, no documentation and no ruling — only the two spellings.
#
# Ids come from position within an atom, so new cells must be APPENDED: add
# targets and writes at the END of their lists, and new routes anywhere (each
# route is its own atom).

my $ROOT = $*PROGRAM.IO.absolute.IO.parent.parent;

# --- the containers a write can land in ----------------------------------
# `setup` builds it, `at` is the place, `read` is how we look afterwards.
# Everything is declared inside the cell's own `do` block, so two cells in one
# process never collide — the redeclaration trap that bites named classes and
# subs does not arise.
constant @TARGETS =
    { name => 'scalar',        setup => 'my $v = 1;',                   at => '$v',       read => '$v'       },
    { name => 'array-elem',    setup => 'my @a = 1, 2, 3;',             at => '@a[1]',    read => '@a[1]'    },
    { name => 'hash-elem',     setup => 'my %h = :a(1);',               at => '%h<a>',    read => '%h<a>'    },
    { name => 'hash-nested',   setup => 'my %h = :a({:b(1)});',         at => '%h<a><b>', read => '%h<a><b>' },
    { name => 'array-of-hash', setup => 'my @a = ({:k(1)},);',          at => '@a[0]<k>', read => '@a[0]<k>' },
    { name => 'attribute',     setup => 'my $o = (class { has $.x is rw }).new(:x(1));',
                                                                        at => '$o.x',     read => '$o.x'     },
    # an element that does not exist yet: the write has to autovivify it, and
    # the route must not lose the container it vivified
    { name => 'autoviv-elem',  setup => 'my %h;',                       at => '%h<new>',  read => '%h<new>'  },
    { name => 'autoviv-deep',  setup => 'my %h;',                       at => '%h<a><b>', read => '%h<a><b>' };

# --- the routes a write can travel ---------------------------------------
# `pre` runs after the setup and may mention {T}; `lv` is the place to assign
# to. `direct` is the reference every other route is compared against and emits
# no cells of its own.
constant @ROUTES =
    { name => 'direct', pre => '', lv => '{T}', bug => '' },

    { name => 'rw-sub',
      pre  => 'sub rr($x is rw) is rw { return-rw $x };',
      lv   => 'rr({T})',
      bug  => 'rakupp-is-rw-sub-not-assignable' },

    # the same routine with an IMPLICIT return — the two spellings of `is rw`
    { name => 'rw-sub-implicit',
      pre  => 'sub ri($x is rw) is rw { $x };',
      lv   => 'ri({T})',
      bug  => 'rakupp-is-rw-sub-not-assignable' },

    # `\c` binds the caller's container, so returning it rw must reach back
    { name => 'rw-sub-sigilless',
      pre  => 'sub rs(\c) is rw { return-rw c };',
      lv   => 'rs({T})',
      bug  => 'rakupp-sigilless-param-is-callers-container' },

    { name => 'rw-sub-raw',
      pre  => 'sub rz($x is raw) is rw { return-rw $x };',
      lv   => 'rz({T})',
      bug  => '' },

    # the method spelling, which is the one that happened to work
    { name => 'rw-method',
      pre  => 'my $K = class { method m($x is rw) is rw { return-rw $x } };',
      lv   => '$K.m({T})',
      bug  => '' },

    { name => 'rw-method-sigilless',
      pre  => 'my $K = class { method m(\c) is rw { return-rw c } };',
      lv   => '$K.m({T})',
      bug  => 'rakupp-sigilless-param-is-callers-container' },

    # two hops: the container has to survive being handed on
    { name => 'two-rw-subs',
      pre  => 'sub ra($x is rw) is rw { return-rw $x }; sub rb($x is rw) is rw { return-rw ra($x) };',
      lv   => 'rb({T})',
      bug  => '' },

    # …and a hop that changes routine kind on the way
    { name => 'method-then-sub',
      pre  => 'sub rc($x is rw) is rw { return-rw $x }; my $K = class { method m($x is rw) is rw { return-rw rc($x) } };',
      lv   => '$K.m({T})',
      bug  => 'rakupp-method-rw-result-subscript' },

    # a multi chosen by a `where` clause, which is how a path-walking module
    # spells its recursion (Crane's whole at/in/set family is this shape)
    { name => 'rw-multi-where',
      pre  => 'multi rm($x is rw, @s where { .elems == 0 }) is rw { return-rw $x };',
      lv   => 'rm({T}, ())',
      bug  => '' },

    # anonymous NAMED parameters as dispatch discriminators — three of them
    # share the bare sigil for a name, and sharing one slot made a `where` on
    # the first read the last one's value
    { name => 'rw-multi-anon-named',
      pre  => 'multi rn($x is rw, Bool :k($), Bool :v($)) is rw { return-rw $x };',
      lv   => 'rn({T}, :k)',
      bug  => 'rakupp-anonymous-params-share-a-slot' },

    # binding is not a routine at all, and must still reach the container
    { name => 'bind',
      pre  => 'my $bnd := {T};',
      lv   => '$bnd',
      bug  => '' },

    # a local bound to the place and handed OUT of a routine: the slot dies
    # with the frame, so the route has to carry the container, not the slot
    { name => 'rw-sub-bound-local',
      pre  => 'sub rl(\c) is rw { my $r := c; return-rw $r };',
      lv   => 'rl({T})',
      bug  => 'rakupp-return-rw-dangling-frame-slot' };

# --- what the write is ----------------------------------------------------
constant @WRITES =
    { name => 'assign', code => '{LV} = 7'  },
    { name => 'incr',   code => '{LV}++'    },
    { name => 'addto',  code => '{LV} += 5' };

sub fill($tpl, $t) { $tpl.subst('{T}', $t, :g) }

sub cell-code(%target, %route, %write) {
    my $pre = %route<pre> ?? ' ' ~ fill(%route<pre>, %target<at>) !! '';
    my $lv  = fill(%route<lv>, %target<at>);
    my $wr  = %write<code>.subst('{LV}', $lv, :g);
    return "do \{ { %target<setup> }$pre $wr; { %target<read> } \}";
}

my $outdir = $ROOT.add('generated/lvalues');
$outdir.mkdir unless $outdir.e;

my $atoms = 0;
my $cells = 0;

for @ROUTES -> %route {
    next if %route<name> eq 'direct';
    my %ref = @ROUTES.first({ $_<name> eq 'direct' });

    my @out;
    @out.push: "atom     lvalues/{ %route<name> }";
    @out.push: "source   generated";
    @out.push: "gen      gen/lvalues.raku";
    @out.push: "law      a write through `{ %route<lv> }`  ===  a write straight to `\{T\}`";
    @out.push: "ladder   { @TARGETS.elems } targets x { @WRITES.elems } writes";
    @out.push: '';

    my $i = 0;
    for @TARGETS -> %target {
        for @WRITES -> %write {
            $i++;
            my $from = 'law:write-through';
            $from ~= ' · bug:' ~ %route<bug> if %route<bug>;

            @out.push: "- id     { sprintf('%04d', $i) }";
            @out.push: "  from   $from";
            @out.push: "  cell   { %target<name> } | { %route<name> } | { %write<name> }";
            @out.push: "  code   { cell-code(%target, %route, %write) }";
            @out.push: "  same-as { cell-code(%target, %ref, %write) }";
            @out.push: '';
            $cells++;
        }
    }

    $outdir.add(%route<name> ~ '.grid').spurt(@out.join("\n"));
    $atoms++;
}

say "# gen/lvalues.raku: $atoms atoms, $cells cells in generated/lvalues/";
say "# no observations recorded — `same-as` is the oracle-free lane";
