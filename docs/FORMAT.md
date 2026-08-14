# The `.grid` file format

Line-oriented, greppable, diff-friendly, and cheap to parse — the harness reads
hundreds of thousands of records per run, so the format is a flat stanza list
rather than nested markup.

A file holds the tests for **one atom**. Curated files live under `atoms/`;
generated files under `molecules/` and `gen/`'s output, and are never
hand-edited.

## Shape

```
atom     operators/infix-plus
spec     infix-plus
source   curated

- id     0041
  from   roast:S03-operators/arith.t
  code   1 + 2
  is     3
  type   Int

- id     0042
  from   corpus:programs/stats.raku · bug:rat-num-degradation
  code   1 + 2.5
  is     3.5
  type   Rat
  oracle rakudo-2026.05 → 3.5
```

A header of `name value` lines, then records separated by blank lines. A record
opens with `- id`; its remaining fields are indented two spaces. Field names are
lowercase, values run to end of line.

Multi-line values need no marker. Leave the field's own line empty, and the
indented lines that follow are the value, ending at the first line that dedents:

```
- id     0107
  from   t/regression/catch-in-method.raku
  code
    sub f { die "x"; CATCH { default { return 42 } } }
    f()
  is     42
```

The code stays code — no fence, no continuation character, nothing to escape,
and a block can be lifted straight into a file and run.

Values needing exact leading or trailing whitespace are quoted (`is  " a "`).
An empty string is `""`, which is also what distinguishes it from a block.

## Fields

### Identity and origin

| Field | Meaning |
|---|---|
| `id` | four digits, unique within the atom. Never reused, never renumbered. Full identity is `grid:<atom>#<id>`. |
| `from` | provenance, one or more entries separated by ` · `. Required. |
| `tags` | free-form labels for selection (`slow`, `native`, `unicode`). |
| `level` | lowest density level that includes this test (0–4, default 1). |
| `budget` | wall-clock allowance for this record in the isolated lane, e.g. `20s`. Default 10s. Not an assertion — `finishes` is the assertion that a program terminates; `budget` is how long anything else is given before it is killed. |

Provenance schemes: `roast:<file>`, `bug:<slug>`, `corpus:<path>`,
`module:<dist>`, `docs:<page>`, `showcase:<name>`,
`shrunk:<molecule-id>` (auto-promoted from a molecule failure), `review:<date>`,
and `spec:<page>.<rule>` — a numbered rule on the
[Raku Rules](https://raku.online/rules/) site, where `R` is a rule, `T` a trap
and `E` an error, so `spec:infix-plus.R3` is the third rule on the `infix-plus`
page.

### The subject

| Field | Meaning |
|---|---|
| `setup` | optional preamble, run before `code`, not itself asserted |
| `code` | the expression or program under test. Required. |

### The assertion — exactly one per record

| Field | Asserts |
|---|---|
| `is` | the expected value, written exactly as the engine's `.raku` renders it, and compared **as text** |
| `type` | the result's type (may accompany `is`; on its own it is the assertion) |
| `throws` | an exception type, optionally with `message` / `payload` |
| `output` | what the program writes to stdout |
| `finishes` | terminates within a budget: `finishes 2s` |
| `same-as` | equals another expression — no oracle needed |
| `parses` | compiles, without being run |
| `no-parse` | fails to compile; an optional `error` field names text the diagnostic must contain |

The first four run in-process, many to a program. The last four —
`output`, `finishes`, `parses`, `no-parse` — need a process each, because a
parse failure, a hang or a crash would otherwise take every other test in the
file down with it. A record that crashes the dense program is automatically
re-run alone, so a fault costs one result rather than a whole file.

`same-as` is the oracle-free lane and carries much of the molecule layer:
internal consistency is checkable without deciding who is right.

`is` is compared as **text**, never by re-compiling the expected value. Two
reasons, both learned the hard way: a value's own `.raku` is not always
re-parseable — `(2**64 / 1).raku` gives `18446744073709551616.0`, which Rakudo
then refuses to compile — and text comparison makes `NaN` equal `NaN`, which is
what a test wants and what `==` will never give.

### The oracle and its ruling

| Field | Meaning |
|---|---|
| `oracle` | `<impl>-<version> → <observation>`. **Repeatable.** |
| `verdict` | required when the assertion differs from the authoritative oracle. One of `docs`, `reason`, `impl-bug`, `unanswerable`, `underspecified`, `disputed`. |
| `why` | one-line rationale. Required with `verdict`. |
| `ruled` | `<date> against <impl>-<version>` — when the ruling was made, and which observation it was made against. Required with `verdict`. |

Observations **accumulate**; they are never overwritten. A record carries as
many `oracle` lines as we have run it against — across implementations, and
across versions of the same one:

```
  oracle rakudo-2026.05 → 3.5
  oracle rakudo-2026.08 → 3.5
  oracle rakupp-1.2.0   → 3.500000
  oracle moarvm-js-2026.03 → 3.5
```

- The **authoritative** observation is the newest entry for the designated
  reference implementation — Rakudo by default, changed with
  `rakugrid oracle --reference=`. That is what the build rule compares the
  assertion against.
- Every other line is informational and worth keeping. The set of lines *is* the
  lifecycle of a divergence: it shows whether an implementation moved, converged
  or regressed, and it is what lets the suite report on more than one engine at
  once.
- Lines are appended, never edited. If a re-run of an impl-version already on
  record yields a different observation, that is itself a finding: the run stops
  rather than silently rewriting history.
- `ruled … against …` pins each verdict to the observation it answered. When a
  newer authoritative line differs from the pinned one, the verdict is
  automatically reopened for review — the implementation may have fixed the
  defect, or moved.

**A record whose assertion differs from its `oracle` without a `verdict`, `why`
and `ruled` fails the build.** Divergence from the reference implementation is
always permitted and never silent.

A `disputed` verdict **parks** the record: it does not run, and it counts as
neither a pass nor a failure but as an open question, reported separately. That
is what keeps an unanswered case visible instead of letting it drain away as a
skip. It is also the honest home for a test the reference implementation cannot
run at all in this environment — the alternative would be to promote "the only
engine that ran it" into "correct", which is exactly the mistake this format
exists to prevent.

Worked example — the reference implementation does not answer at all:

```
- id     0003
  from   bug:endless-reduce · docs:book/17-lazy
  code   [+] 1..Inf
  is     Inf
  oracle rakudo-2026.05 → no answer in 8s
  oracle rakupp-1.2.0   → Inf
  verdict unanswerable
  why    partial sums are unbounded and the range's bounds fix the limit; folding a prefix and presenting it as the total is wrong
  ruled  2026-08-14 against rakudo-2026.05

- id     0004
  from   bug:endless-reduce
  code   [+] 1..Inf
  finishes 5s
  oracle rakudo-2026.05 → no answer in 8s
  oracle rakupp-1.2.0   → 0.01s
  verdict impl-bug
  why    a fold over an endless range must terminate, whatever value it settles on
  ruled  2026-08-14 against rakudo-2026.05
```

Note the split: one record rules on the *value*, the other on *termination*.
One test, one behaviour.

### Facet coordinates

```
  facets nesting=method exit=return container=scalar
```

Optional on atoms — recorded where known, since it feeds the coverage meter and
tells the shrinker where a curated test sits. Mandatory on molecules, where the
coordinate *is* the test's reason for existing.

## Generated families

Generated tests are not checked in as expanded stanzas. The source of truth is
the generator in `gen/`; alongside it sits a frozen oracle snapshot in
`oracle/<impl>-<version>.tsv`, one row per test:

```
grid:operators/infix-plus#g0041	1 + 2	3	Int
```

`rakugrid oracle` regenerates a snapshot against a given implementation. Any
adjudicated record whose oracle observation *changed* between snapshots is
automatically reopened for review — the implementation may have fixed the
defect, or moved.

## Adjudications

`adjudications/<atom>.grid` collects the rulings for an atom in the same stanza
format, so `rakugrid adjudications` can publish the ledger: every place where
the implementation, the documentation, and reason disagree, each with a dated
ruling and the person who made it.
