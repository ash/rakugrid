# The Rakugrid plan

## 1. Why

Raku++ reached ~90% of Roast's declared assertions and still could not run
ordinary Raku programs without hitting hundreds of bugs. Every one of those
bugs was found somewhere other than Roast: writing example programs, running
the corpus of real-world code, installing ecosystem modules, generating the
documentation sites, building the showcase interpreters.

Those bugs were then fixed and, mostly, recorded — in `t/regression`, in
`TRIAGE.md`, in the divergence logs, in the module findings. What does not
exist is a *suite* that holds all of it, in one addressable form, that any Raku
implementation can run.

Rakugrid is that suite.

It is not a replacement for Roast and not a fork of it. Roast defines the
language; Rakugrid measures whether an implementation of it holds together.

## 2. Principles

1. **One test, one behaviour.** If it fails, the failing construct is named by
   the test's own identity. No bisecting a 400-line file.

2. **The oracle proposes; a written ruling disposes.** Every test stores
   `oracle:` (what the reference implementation did, with its version) and
   `expect:` (what we assert). Where they differ, the test carries a verdict
   from the closed set below, with a rationale and a date. A divergence with no
   signed verdict fails the build.

   | verdict | meaning |
   |---|---|
   | `docs` | documentation is explicit and the implementation contradicts it |
   | `reason` | neither docs nor implementation settle it; the ruling follows from the language's own consistency |
   | `impl-bug` | we believe it is a defect; links the upstream issue |
   | `unanswerable` | the implementation yields no observation at all — hang, OOM, crash |
   | `underspecified` | more than one answer is legitimate; assert only the property they share |
   | `disputed` | unresolved; the test is parked and does not run |

   **Standing rulings.** Some questions are settled once and then applied
   consistently rather than re-argued per cell:

   - **IEEE-754 beats the reference.** Where two engines return doubles
     differing in the last place, the correctly-rounded value wins — decided by
     high-precision arithmetic, not by either implementation. Verified at 60
     digits, rakupp is exact on `asinh`, `log10`, `log2`, `atanh` and `acotanh`
     while Rakudo is 1–3 ULP out; those cells are ruled `impl-bug` against the
     reference. Check with independent arithmetic, never with another libm,
     which may share an implementation with the engine under test.
   - **Diagnostic wording is never asserted.** Only the exception type, or the
     structural fact that something did or did not compile.
   - **Unspecified order is never asserted.** Hash and set iteration order, and
     anything derived from it.

3. **Provenance is mandatory.** Every test names its origin: a Roast coverage
   point, a fixed bug, a corpus program, a module failure, a documented rule.

4. **Exhaustiveness by construction.** Coverage is measured against a
   machine-extracted inventory. Atoms with zero tests are reported as holes.

5. **Generators are the source; oracle snapshots are the artifact.**
   Combinatorial families live as generator scripts plus a frozen TSV of oracle
   results. Re-oracling on a new implementation release is one command.

6. **Curated and generated never share a tree.** A regeneration can never
   clobber a hand-written test.

7. **Dense to run, isolated to debug.** The fast path emits ~100 dense files of
   ~5,000 assertions each; `rakugrid isolate <id>` writes any single test out as
   a standalone minimal program.

8. **Parse failures get their own lane.** Compile-fail tests run batched with
   bisect-on-failure, since one parse error kills a whole file.

9. **Engine-neutral, and written in Raku.**

## 3. The grid

### 3.1 Atoms

An atom is one construct — `infix:<+>`, `Str.subst`, `gather`, `where` on a
parameter. Atoms are grouped by documentation topic, not by Synopsis:

```
operators/  subs/     methods/   types/       variables/
literals/   quoting/  control/   phasers/     signatures/
regexes/    grammars/ modules/   concurrency/ errors/     native/
```

Roughly 1,800 atoms, drawn from the machine-extracted inventory: 182 operators,
198 subroutines, 667 methods, ~110 types, and the syntactic forms around them.

Identity is stable and citable: `grid:operators/infix-plus#0041` — the atom, then
a four-digit number unique within it, never reused and never renumbered.

Where an atom corresponds to a numbered rule on the
[Raku Rules](https://raku.online/rules/) site, the test links to it. That site
numbers every statement it makes, so each is individually citable: on a page,
each heading under `## Rules` becomes `R1`, `R2`, `R3`…, each under `## Traps`
becomes `T1`, `T2`…, and each under `## Errors` becomes `E1`, `E2`…. So
`spec:infix-plus.R3` is *the third rule on the `infix-plus` page*, and
`spec:infix-plus.T1` its first documented trap.

The link runs both ways: from a failing test to the rule it violates, and from a
rule to every test that holds it. A rule with no test behind it is as much a
hole as an atom with no test.

### 3.2 Facets

Constructs interact when they share a mechanism — a call frame, a container, a
context, a scope, a dispatch decision, a laziness boundary. The grid has eight
axes:

| Facet | Levels (indicative; extracted in phase 0) |
|---|---|
| **Nesting** | top-level · sub · method · bare block · loop body · `do` · `gather` · `start` · `CATCH` · phaser · regex code block · `given`/`when` · thunk · lazy map body · `react`/`whenever` |
| **Exit** | fall-through · `return` · `last` · `next` · `redo` · `die` · `take` · `emit` · `succeed` · `fail` · `warn` |
| **Container** | scalar · array · hash · bound `:=` · native-typed · readonly · itemized · attribute · dynamic `$*` · `state` · `constant` |
| **Context** | item · list · sink · Bool · Str · Num · Int · slurpy argument · hash key |
| **Evaluation** | eager · lazy · infinite · gathered · hyper · threaded · precompiled |
| **Dispatch** | sub · multi · method · private · meta-operator · operator · `&f` reference · `.&` · indirect |
| **Scope** | file · block · closure · role · class · module · `EVAL` · precompiled module |
| **Type shape** | definite · type object · subset · coercion · `but` mixin · junction · `Failure` · `Nil` |

The full cartesian product is ~74 million points before payloads, which is why
this needs covering arrays rather than enumeration.

The levels are not invented. They come from two checkable sources: what the
**grammar** permits as a nesting, a container or a dispatch form, and what our
**bug history** proves actually interacts. Extracting them is the first
substantial task of phase 0.

### 3.3 Molecules

A molecule is a point in facet space with more than one axis engaged. The case
for the layer is our own defect record — each of these needed two or three
facets to reproduce, and none is reachable by testing either construct alone:

| Bug | Crossing |
|---|---|
| `return` inside `CATCH` yields `Nil` | Exit × Nesting |
| `next` in `.map` escapes to the enclosing loop | Exit × Nesting × Evaluation |
| a method loses `return` inside a loop | Exit × Nesting × Dispatch |
| `rw` parameters do not write back through multis | Container × Dispatch |
| `:my $*` not restored on regex subrule exit | Container × Scope × Nesting |
| `gather` with an infinite `for` yields `()` | Evaluation × Nesting |
| `\|@a` does not flatten inside an array literal | Context × Container |
| the whenever-transform-chain hang | Evaluation × Nesting × Dispatch |

Empirical fault studies of combinatorial testing (NIST) found essentially all
defects triggered by six or fewer interacting factors, with 2-way interaction
coverage already catching the large majority and 3-way catching nearly all. So
interaction *strength* is a dial, and the suite is generated at a chosen
strength rather than enumerated.

Three mechanics make the layer work:

- **Composition by template.** A skeleton is an AST-shaped template with a hole;
  the payload goes in the hole. This guarantees well-formedness and, more
  importantly, lets the expected result be **derived** from the composition rule
  rather than merely observed. When the oracle disagrees with a derived
  expectation, that is a finding, routed into the adjudication ledger.

- **`same-as:` assertions.** A composed scenario must equal the same
  computation written flat: `sub f { for 1..3 { return 1 } }` is `1`. These need
  no oracle, no ruling and no documentation, and they scale to every skeleton
  automatically.

- **Directed shrinking.** When a molecule fails, the shrinker walks the facet
  axes to the minimal failing coordinate. Because the axes are known, shrinking
  converges instead of guessing. The result is already a valid minimal repro and
  is auto-promoted into `atoms/` with full provenance. Molecules find; atoms
  then hold the line.

Not every combination is legal Raku. Each cell is classified **legal** (assert a
value), **illegal** (assert which exception, raised where) or **undefined**
(adjudicate). The illegality grid is where "cannot parse real programs" defects
live, and it is close to untested today.

### 3.4 Edge ladders

Facets say *where* a construct sits. Ladders say *what flows through it*.

Every atom carries a mandatory **ladder** for each operand or argument position:
the corner values of the types that position accepts. An atom is not covered
because it has tests — it is covered when every position's ladder is complete
and the legal crosses between positions are exercised, **in both orders**.

| Type | Ladder |
|---|---|
| `Int` | `0`, `1`, `-1`, `2`, `2⁶³-1`, `2⁶⁴`, `-2⁶⁴` — the bignum boundary in both directions |
| `Rat` | `0/1`, `1/1`, `-1/1`, `1/3`, a denominator past `uint64` — the Rat→Num boundary |
| `Num` | `0e0`, `-0e0`, `1e0`, `-1e0`, `Inf`, `-Inf`, `NaN`, a denormal, max finite |
| `Str` | `""`, `" "`, `"0"`, `"a"`, a multi-codepoint grapheme, an embedded NUL, a very long string |
| `List`/`Array` | `()`, `(1,)`, nested, lazy, infinite, self-referential |
| `Hash` | empty, one key, colliding keys |
| `Range` | empty (`5..1`), `1..Inf`, `-Inf..Inf`, reversed, non-numeric |
| undefined | the type object, `Any`, `Mu`, `Nil`, an unhandled `Failure` |

The rule is **corner × corner, corner × mid, and mid × corner** — both orders,
always. Mid-to-corner finds as much as corner-to-corner, and order matters even
for operators that ought to commute, because "ought to" is precisely the thing
under test.

For `infix:<+>` that is the numeric ladder crossed with itself: `Inf + 1`,
`1 + Inf`, `Inf + -Inf`, `-Inf + Inf`, `Inf + Inf`, `-Inf + -Inf`, `Inf + NaN`,
`0e0 + -0e0`, `2⁶⁴ + 1`, `1/3 + Inf`, and so on. Real defects sit exactly there:
`Inf + -Inf` must be `NaN` and not `0`, `-0e0` must survive an addition, and a
`Rat` whose denominator crosses `uint64` must degrade to `Num` rather than wrap
— which is a defect Raku++ actually shipped.

It applies just as much to methods, where the corners are positional: `.substr`
at `0`, at `-1`, past the end, at `Inf`, at a fractional index; `.rotate` by
`0`, by more than the length, by a negative amount.

Two consequences worth stating:

- **Algebraic laws become assertions rather than assumptions.** `a + b`
  `same-as` `b + a` across the whole ladder cross; `a - a` is `0` except where
  the ladder says otherwise. These need no oracle at all.
- **The ladder cross is what §5's "~800 operand/context cells" actually is.**
  The coverage meter enforces it: an atom whose ladder has holes is reported
  incomplete even with a hundred passing tests behind it.

## 4. Where the tests come from

Most of the evidence is already public, in the
[Raku++ repository](https://github.com/ash/rakupp) and alongside it.

| Source | What is extracted | Seeds |
|---|---|---|
| [`t/regression`](https://github.com/ash/rakupp/tree/main/t/regression) | already-minimal repros of fixed bugs, one file each | 259 |
| [`TRIAGE.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/TRIAGE.md), [`BUGS.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/BUGS.md), [`BUGS-JS-SHOWCASE.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/BUGS-JS-SHOWCASE.md) | one test per symptom, plus its neighbourhood | ~150 |
| [`SPEC-DIVERGENCES.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/SPEC-DIVERGENCES.md) | 217 clusters, one test per member | ~400 |
| [the spec](https://raku.online/spec/) and [rules](https://raku.online/rules/) sites | every numbered rule's verified example | ~580 |
| [raku-corpus](https://github.com/ash/raku-corpus) (920 real programs) | differential-harness divergences, via [`CORPUS-DIFF.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/CORPUS-DIFF.md) | ~300 |
| the module battery (top 200 distributions, private) | every engine bug that blocked a distribution | ~120 |
| [`CONFORMANCE.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/CONFORMANCE.md), [`PWC-`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/PWC-DIVERGENCES.md) / [`ROSETTACODE`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/ROSETTACODE.md) / [`COURSE-DIVERGENCES.md`](https://github.com/ash/rakupp/blob/main/docs/dev/findings/COURSE-DIVERGENCES.md) | failing documentation examples | ~250 |
| the [showcase](https://github.com/ash/rakupp/tree/main/showcase) interpreters | quirks found writing large Raku programs (JS, Perl, Python) | ~80 |
| [Roast](https://github.com/Raku/roast) | its coverage *map* — see below | ~55k after dedup |
| generators | the inventory, crossed with itself | the bulk |

Everything imported keeps a `from:` pointing back at these, so any test can be
traced to the failure that motivated it.

### Roast: coverage, not code

We take what Roast *covers*, never what it *contains*:

1. Parse each of the 1,462 `.t` files into an AST with a real Raku parser.
2. Extract every assertion — `is`, `ok`, `isa-ok`, `is-deeply`, `throws-like`,
   `dies-ok` — as a triple `(expression, expected, kind)`.
3. Classify each triple by the constructs its expression contains, and
   attribute it to an atom.
4. Emit a **coverage map**: "atom `infix-plus` is exercised across these 40
   operand shapes." No test code is emitted at this step.
5. Feed the map to the generators. Where a shape is already covered, nothing is
   written. Where it is not, a test is generated from our own template against a
   fresh oracle run.

Two guards make this checkable rather than aspirational: the expected value
always comes from re-running the oracle, never from Roast's literal; and a
similarity check rejects any generated test whose source text overlaps a Roast
line beyond a threshold. It is also cleaner on licensing — Roast is Artistic
2.0, and a suite derived by re-derivation carries no lineage question.

## 5. Size

At full density:

| Family | Basis | Tests |
|---|---|---|
| Operator semantics | 182 operators × ~800 operand/context cells | 145k |
| Operator syntax | precedence and associativity pairs, meta-operators, adverbs | 40k |
| Method matrix | 667 methods × ~35 invocant/argument/context cells | 23k |
| Sub matrix | 198 subroutines × ~35 | 7k |
| Type system | ~110 types: typecheck grid, coercion grid, `.new`/`.gist`/`.raku`, MOP | 28k |
| Signatures and dispatch | parameter kinds × constraints × multi tie-breaks × capture shapes | 20k |
| Regexes and grammars | ~220 constructs × modifiers × subject cells | 22k |
| Contexts and containers | 8 contexts × 5 container flavours over ~1,200 base expressions | 20k |
| Quoting and literals | `Q` adverb combinations, heredocs, number-literal grammar, escapes | 25k |
| Unicode and strings | properties, graphemes, case folding, collation — sampled | 45k |
| Errors and exceptions | ~200 exception types × trigger × payload | 6k |
| Roast-derived residue | behaviours no generator above reaches | 55k |
| Curated regressions | ~900 real seeds × ~8 neighbours | 7k |
| **Atoms** | | **~443k** |
| Universal scenario array | 3-wise covering array over the 8 facets (~2,000 skeletons) × ~30 payloads | 60k |
| Per-atom facet array | ~150 core atoms × 2-wise over the 4–5 facets each engages | 15k |
| Bug-neighbourhood walk | ~900 historical seeds, one facet varied at a time | 25k |
| Mechanism-sharing pairs | ~3,000 atom pairs computed to share a live facet × ~10 shapes | 30k |
| Illegality grid | combinations that must fail, and with which exception | 8k |
| **Molecules** | | **~138k** |
| **Total** | | **~580k** |

Roast declares ~216,000 assertions today. Rakugrid at full density is roughly
2.7× that, with every test traceable to a reason.

### Density levels

Both breadth (how many payloads) and interaction strength (how many facets vary
at once) are dials:

| Level | Tests | Budget | When |
|---|---|---|---|
| L0 | ~3k | seconds | every build; touches every atom once |
| L1 | ~30k | <1 min | commit gate |
| L2 | ~150k | few minutes | pre-push |
| L3 | ~580k | nightly | release gate |
| L4 | past 1M | on demand | 4-wise on core atoms, or one atom exhaustively |

L4 crosses a million tests through interaction depth rather than through
per-codepoint padding, which is the only way that number carries information.

## 6. Phases

| Phase | Deliverable | Tests after |
|---|---|---|
| **0** | repo, `.grid` format, harness (`fire` / `isolate` / `oracle` / `cover` / `adjudications`), the unsigned-divergence build rule, the atom and facet inventory extractors | 0 |
| **1** | curated import: `t/regression`, TRIAGE, divergence logs, spec rules — with provenance | ~2k |
| **2** | atom generators: type grid, operator grid, method and sub matrices, contexts | ~150k |
| **2.5** | the molecule layer: facet arrays, template composition, directed shrinking, illegality grid | ~290k |
| **3** | Roast harvest → coverage map → residue tests | ~440k |
| **4** | corpus and battery mining, error/Unicode/regex families, holes closed to zero | ~580k |
| **5** | publish: repo, CI matrix across implementations, a coverage page on raku.online | — |

Phases 1 and 2.5 carry most of the value. Phase 1 alone gives a suite already
better at catching our real defects than Roast is; phase 2.5 is the part that
finds defects nobody has reported yet.
