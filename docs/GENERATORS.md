# How the generators work

96% of Rakugrid is generated. Six programs in `gen/` produce every `.grid` file
outside `atoms/`, and they all run on **rakupp**:

```sh
rakupp gen/methods.raku --engines=raku,/path/to/rakupp --jobs=2
```

`--engines` lists the implementations to record observations from. **The first
is the reference** — the one whose answers become the expectations. Everything
else is recorded alongside for comparison and never asserted.

## The shape they all share

Every generator is the same four steps:

```
    enumerate  →  probe  →  confirm  →  emit
```

1. **Enumerate.** Produce the expressions to test. This is the only part that
   differs meaningfully between generators — a spec table, an inventory, a
   crossing of two axes, or the implementation's own `.^methods`.

2. **Probe.** Run every expression under each engine and record what it did:
   a value and a type, an exception name, or a refusal to compile.

3. **Confirm.** Ask again, differently, before believing the answer. A cell that
   cannot be reproduced, cannot be compiled, or cannot be answered at all must
   not become an expectation.

4. **Emit.** Write `.grid` records with the assertion, one `oracle` line per
   engine, and — where step 3 found trouble — a signed `verdict` that parks the
   record instead of asserting something untrue.

A generator never invents an expected value. If the reference cannot produce a
usable, reproducible answer, the record is parked with a written reason and
counted separately. That is the difference between a suite that is green because
it is right and one that is green because it looked away.

## The ten generators

| Generator | Enumerates | Produces |
|---|---|---|
| `ladder.raku` | a hand-written table of operators and methods × edge ladders | value assertions per cell |
| `operators.raku` | the **documented inventory** — 143 usable of 180 operators | one atom per operator, mixed-ladder cross |
| `methods.raku` | the implementation's own `.^methods(:all)` for 60 types | one atom per type, methods × instance ladder |
| `syntax.raku` | hand-built syntax fragments — declarators, signatures, phasers, quoting | `parses` / `no-parse` only |
| `laws.raku` | algebraic laws over ladders | `same-as` — no oracle needed |
| `molecules.raku` | two facet axes crossed | one atom per crossing |
| `import-regression.raku` | an existing repository's regression programs | curated whole-program records |
| `regex.raku` | 94 patterns × 16 subjects × 8 match forms | derived facts, never Match objects |
| `signatures.raku` | parameter forms × arguments × call forms, and parameter **pairs** | what bound, or what it threw |
| `spelling.raku` | every infix operator × operand pairs × **three ways of writing it** | `same-as`, or `no-parse`, or the value the bare spelling gives |

`syntax.raku` is the odd one: it compiles complete programs with `-c` and never
runs them, and it asserts only whether they compile — never the wording of the
diagnostic, which is not specified.

`regex.raku` asserts *derived facts* — `so(…)`, `.from`, the captures joined,
`.subst`, `.comb.elems` — never a Match object, whose rendering is not
specified and differs between engines for reasons that are not bugs.

`signatures.raku` is the only generator whose ladder crosses itself: one
parameter against every argument answers what a parameter accepts, but two
parameters dividing one argument list is where binding actually gets
interesting — an optional before a slurpy, a named after a positional, two
constraints competing for one value.

Its call forms deliberately use an **anonymous** class. `class C {...}` installs
a symbol, and Rakudo throws `X::Redeclaration` the second time one process
compiles it; since both the probe and `fire` evaluate many cells per process, a
named class would have recorded a redeclaration error as the binding result for
every method cell but the first.

`spelling.raku` is the answer to a gap the other operator generators created.
They parenthesise both operands — see the first safeguard below — which is right
for the semantics and blind to the lexer: until it existed, not one test in the
suite exercised `1 * 2` or `1*2`, only `(1) * (2)`. So the parens stay where the
value is asserted, and spelling becomes an axis of its own:

```
({A}) op ({B})     the baseline — what the other generators assert
{A} op {B}         spaced and bare
{A}op{B}           tight
```

The assertion depends on what the reference does with the bare form, and the
**baseline is compile-checked too**, because a spelling rejected in a crossing
that is illegal however it is written (`1:=2`, and equally `(1) := (2)`) is not
a finding about spelling:

| Baseline | Bare spelling | Assertion |
|---|---|---|
| compiles | rejected | `no-parse` — **the spelling is what broke it** |
| compiles | compiles, agrees | `same-as` the parenthesised form — needs no oracle |
| compiles | compiles, differs | `is` / `type` — pin what the bare spelling really means |
| rejected | rejected | `no-parse`, marked illegal-however-written |
| rejected | compiles | `is` / `type` — only the bare form is legal here |

`laws.raku` is the other odd one: it needs no reference at all. `a + b` must
equal `b + a` whatever either is, so an engine that disagrees with *itself* is
wrong without anyone deciding what the right answer was.

## Ladders

A **ladder** is the set of corner values a position accepts — `Inf`, `-Inf`,
`NaN`, `-0e0`, the bignum boundary, the empty string, the type object. Binary
operators cross their ladder with itself in **both directions**, because order
matters even for operators that ought to commute; "ought to" is the thing being
tested.

Ladders are **order-sensitive**: ids are derived from a cell's position in the
cross, and ids are permanent. New values must be **appended**, never inserted.

## The safeguards, and what each one is for

Every item here exists because it went wrong. None is hypothetical.

**Parenthesise the operands.** `1/2 ** 2` parses as `1/(2**2)`. Without parens a
cell silently tests something other than what its label says. The cost of that
safeguard is that the parenthesised spelling is not the one real programs
contain — which is why `spelling.raku` exists, and why it treats the parens as a
baseline to compare against rather than as the only way to write a test.

**Ask whether it compiles separately from what it does.** `try EVAL` catches a
compile failure as though it were a runtime exception, so a cell that cannot be
compiled at all was being recorded as `throws` — and then killed every other
test in its dense file.

**Confirm compile failures against a real file.** EVAL is not a file. Rakudo
compiles `sub { (0) ~~ (Nil) }` from a file happily and dies on the identical
text under EVAL. Of 38 flagged compile failures, **28 were EVAL artefacts**.

**Compile-check in a different process from the evaluation.** Compiling
`sub { EXPR }` *declares* whatever EXPR declares. A cell containing `class C {…}`
was declared once by the compile check and again by the evaluation, so every
class-bearing cell reported a redeclaration that existed only inside the probe.

**Give every cell its own names.** Cells share a file once packed into a dense
program. Ten cells declaring `class C` are ten redeclarations; `our $n` is
package-scoped and collides the same way. Names are derived from the cell's
coordinates.

**Probe the reference twice.** `.WHICH` on a reference type carries an address,
so a test built from one run is flaky by construction. A cell that answers
differently on two identical runs is parked, and that guard is general rather
than a `.WHICH` special case.

**Never assert a non-answer.** `CRASH:1` was once written into an `is` field. A
reference that crashed or hung gives us nothing to assert.

**Refuse the plumbing.** All-caps REPR and metamodel methods — `CREATE`,
`POPULATE`, `COERCE`, `RAW-HASH` — die in ways `try` cannot catch, taking the
whole probe batch down. They are also noise in any list of what an
implementation is missing. Raku's user-facing shouting API is a small closed set
(`WHAT`, `WHO`, `WHY`, `HOW`, `WHICH`, `ACCEPTS`, `DEFINITE`, `VAR`, `REPR`,
`EVAL`, `AST`), so the filter names what to keep. Underscored names
(`BUILD_LEAST_DERIVED`, `FLATTENABLE_HASH`) go too — Raku spells identifiers
with hyphens.

**Nothing dangerous, ever.** Only value types are introspected, and any method
that could reach the outside world is refused by name. A generated suite must
never be able to delete a file because some type grew an `.unlink`.

## Making probing survive, and finish

The expensive thing is not evaluation. Measured: 300 cells through EVAL take
1.6 seconds, and the same 300 compiled once into a dense program take 1.6
seconds. **The cost is expressions that kill the process** — and recovering from
them badly.

**Output goes to files, never pipes.** A killed program can leave a grandchild
holding an inherited pipe, and the read then waits for an EOF that never comes:
the watchdog fires, the process dies, and the harness hangs anyway.

**The watchdog must actually kill.** `kill -9 -$p` needs a process group that
`( … ) &` does not create. With no fallback it silently did nothing, and one
expression stalled a run for 87 minutes.

**Batches must be small.** A fixed timeout over a 7,276-expression chunk is
wrong at both ends: long enough for the chunk means a hang costs the whole
timeout; short enough to catch a hang kills healthy work. It discarded 5,200
good cells. Work is cut into 200-expression batches.

**Recover by bisection, not iteration.** A batch that dies is split in half and
retried, so isolating one killer costs log₂(n) runs instead of n. Recovering one
cell at a time meant a single fatal expression in a 200-cell batch cost 199
extra process spawns — which is where the hours went.

**Scale the recovery timeout.** Healthy cells run at ~190/sec, so a flat 60s at
each of nine bisection depths is nine minutes to isolate one bad cell. Each
level gets `max(6s, cells/20)`.

**Cache per engine, and probe only what is new.** A sunk `Proc` with a non-zero
exit throws, and a killed batch makes `sh` exit non-zero — which destroyed a
three-hour run at its last step, after both engine passes had completed in
memory. Observations are now written to `tmp/<gen>-cache-<engine>.tsv` and
reloaded, so widening a type table or a ladder costs only the new cells, and a
late failure costs seconds.

## Adding a generator

Copy the machinery. It is duplicated across `gen/` on purpose: rakupp's
`is export` on many-sub modules is still unreliable, and a generator that cannot
run is worse than one that repeats a hundred lines.

What a new generator owes:

1. **Enumerate deterministically.** Same inputs, same expressions, same order —
   ids come from position and are permanent.
2. **Give every cell a `from`.** Provenance is not optional; `inventory:…`,
   `law:…`, `molecule:…`, `ladder:…` all say where a test came from.
3. **Park rather than guess.** No answer, no reproducibility, no compile — write
   a `verdict`, a `why` and a `ruled` date, and let it be counted as an open
   question.
4. **Record every engine, assert only the reference.**
5. **Be safe by construction**, not by hoping the ladder contains nothing
   destructive.

Then check your work the way the suite checks everything else:

```sh
rakupp bin/rakugrid check     # no unsigned divergences
rakupp bin/rakugrid fire      # the reference must pass its own observations
```

If `fire` under the reference is not green, the generator recorded something the
reference cannot reproduce — and that is a bug in the generator, not a finding
about the language.
