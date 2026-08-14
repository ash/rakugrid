# Rakugrid

A behavioural test suite for the Raku language, organised as a grid.

[Roast](https://github.com/Raku/roast) tells you whether an implementation *is*
Raku. Rakugrid tells you whether it **survives contact with real Raku
programs**. Those are not the same question, and we learned it the hard way:
Raku++ passed the large majority of Roast's ~216,000 assertions and still could
not run ordinary programs without hitting hundreds of bugs.

Rakugrid is built from what those bugs taught us.

| | |
|---|---|
| **atoms** | 312 |
| **tests** | 4,004 — 3,745 generated, 259 curated |
| **engines on record** | `rakudo-2026.07`, `rakupp-3.14.0` |
| **divergences** | 891 observations in 74 clusters |
| **crashes on record** | 2 |
| **signed rulings** | 28 |

<sub>Refresh with `rakugrid stats` — these are printed, not hand-maintained.</sub>

## The three things Roast does not do

1. **Provenance.** Every test records *why it exists* — a bug we fixed, a
   corpus program that broke, a module that would not install, a documented
   rule. Nothing is here because it seemed like a good test.

2. **Exhaustiveness by construction.** Coverage is measured against a
   machine-extracted inventory of the language: 182 operators, 198 subroutines,
   667 methods, ~110 types and the syntactic forms around them. An atom with
   zero tests is a *visible hole*, not an unknown unknown.

3. **Combinations.** Most of our hard bugs were constructs that each worked
   alone and broke together — `return` inside `CATCH`, `next` inside `.map`
   inside `for`, a dynamic variable crossing a regex subrule boundary. Rakugrid
   tests the crossings systematically, not anecdotally.

## Atoms, molecules, and the grid

- An **atom** is one construct exercising one behaviour in isolation. Atoms
  *prevent* regressions.
- A **molecule** is constructs in combination, where each part is known to work
  alone. Molecules *find* bugs.
- The **grid** is the facet space both live in: eight orthogonal axes —
  nesting, exit, container, context, evaluation, dispatch, scope, type shape —
  whose levels were extracted from the grammar and from our own bug history.
  Atoms are points in it, molecules are covering arrays over it, and the
  shrinker walks its axes to minimise a failure to one coordinate.
- A **ladder** is the corner values a position accepts — `Inf`, `-Inf`, `NaN`,
  `-0e0`, empty, the bignum boundary, the type object. Every atom must cross its
  ladders in both directions: corner against corner, and corner against
  ordinary. An atom with a hole in its ladder is reported as uncovered no matter
  how many tests it has.

## Rakudo is the oracle, but not the arbiter

Every test stores both what Rakudo actually did (`oracle:`) and what we assert
(`expect:`). Usually they are identical. Where they differ, the test carries a
signed **verdict** with a rationale and a date, and a divergence without one
*fails the build*. Sometimes the documentation wins; sometimes plain reason
does; sometimes Rakudo yields no observation at all — `[+] 1..Inf` does not
answer — and there is nothing to defer to.

Divergence from the reference implementation is always possible here. It is
never silent.

## Engine-neutral

Rakugrid runs under any Raku implementation. It is developed alongside
[Raku++](https://github.com/ash/rakupp) because that is where the evidence came
from, but nothing in the suite depends on it.

## Layout

| Path | What it is |
|---|---|
| `atoms/` | curated single-behaviour tests, by category, with provenance |
| `molecules/` | facet skeletons and the covering arrays over them |
| `gen/` | generators — the source of truth for combinatorial families |
| `oracle/` | frozen oracle snapshots, one per reference-implementation version |
| `adjudications/` | signed rulings where `expect` diverges from `oracle` |
| `lib/`, `bin/` | the harness, written in Raku |
| `docs/` | [the plan](docs/PLAN.md), [the file format](docs/FORMAT.md) |

## Running it

```sh
rakugrid fire                                  # run everything, emit TAP
rakugrid fire --engine=/path/to/rakupp         # …against another implementation
rakugrid check                                 # the build rule: no unsigned divergences
rakugrid stats                                 # the counters at the top of this file
rakugrid cover                                 # which atoms have tests
rakugrid diverge                               # where recorded engines disagree, clustered
rakugrid matrix infix-divide                   # a ladder cross rendered as a matrix
rakugrid isolate grid:operators/infix-plus#0041
rakugrid adjudications                         # the ledger of signed rulings
```

The harness runs on any implementation and tests any implementation — the two
need not be the same one.

## Status

Phase 0. Working: the `.grid` parser, `fire` (in-process assertions — `is`,
`type`, `throws`, `same-as`), `check`, `cover`, `diverge`, `matrix`, `isolate`,
`adjudications`, and two generators: `gen/ladder.raku` (edge-ladder crosses for
operators and methods) and `gen/import-regression.raku` (whole-program repros
imported with provenance, fixtures included). Two engines on record throughout.

The isolated lane runs `output`, `finishes`, `parses` and `no-parse` a process
each, under a shell watchdog, and any record that kills the dense program is
re-run alone so a crash costs one result rather than a file.

Not yet built: the atom and facet inventory extractors, ladder-completeness in
`cover`, and the molecule layer.

See [docs/PLAN.md](docs/PLAN.md) for the full plan.
