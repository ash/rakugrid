# Presentation

A self-contained slide deck introducing Rakugrid — what it is, what it is for,
and how it is built: [`index.html`](index.html). No build step and no
dependencies: open the file in a browser, or serve the directory statically.

**Just want to look?** [`rakugrid-presentation.pdf`](rakugrid-presentation.pdf)
is a 16-page PDF export — download it and flip through in any PDF viewer (the
text stays selectable). GitHub's inline blob viewer is unreliable with PDFs, so
download it rather than expecting a preview. The interactive `index.html` is the
real thing: keyboard navigation, a light/dark toggle, hover states. Regenerate
the PDF from the deck:

```sh
# force the dark theme, print one slide per 1280x720 landscape page
sed 's/<html lang="en">/<html lang="en" data-theme="dark">/' index.html > /tmp/grid-print.html
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --no-pdf-header-footer --virtual-time-budget=4000 \
  --print-to-pdf="rakugrid-presentation.pdf" "file:///tmp/grid-print.html"
```

Chrome emits PDF 1.4 with the text selectable, so that single step is the whole
recipe. Do not pipe it through Ghostscript — a `gs -sDEVICE=pdfwrite` pass
silently drops gradient fills, which is where the bar chart on slide 14 lives.
Check the export before committing it, since nothing else will:

```sh
pdftoppm -f 14 -l 14 -r 60 -png rakugrid-presentation.pdf /tmp/deck-p14   # then look at it
```

- **Navigate:** `←` / `→` (also PageUp/PageDown, Space), `Home` / `End`, the dot
  rail, or the on-screen arrows.
- **Theme:** light/dark toggle, top-right (follows the OS setting by default).

Sixteen slides: what it is → why it exists → the gap Roast leaves → atoms,
molecules and ladders → the eight facet axes → edge ladders → every operator on
ordinary values → one operator taken to its edges → two atoms composed into a
program → oracle vs arbiter → the `.grid` format → the generators → the
safeguards → where it stands → density levels and roadmap → running it.

Slides 7, 8 and 9 are the three grids, and they are meant to be read in that
order: **breadth** (many operators, everyday operands), then **depth** (one
operator, its ladder out to the corners), then **combination** (two atoms
composed). Slide 7 exists to make the point that the suite is not only corner
cases — the mixed ladder is mostly ordinary values, with the corners inside the
same cross.

Every figure is printed by the harness, not hand-written. Refresh them with:

```sh
rakugrid stats
```

and move the numbers on slides 1 and 14 when they change — the counters there
are `571` atoms, `102,809` tests (`102,539` generated, `270` curated), `21,639`
divergence observations in `3,683` clusters, `113` crashes, `1,812` signed
rulings. The per-family bars on slide 14 come from the `families` array in the
deck's script; regenerate them with:

```sh
for d in generated/*/ molecules atoms; do echo "$d $(grep -rhc '^- id' $d | paste -sd+ - | bc)"; done
```

All three grids are built from the `.grid` records themselves rather than
written by hand — parse the records, pull the `code`, `is` and `type` fields,
and lay them out.

**Slide 7** takes ten everyday operators from
[`../generated/inventory/`](../generated/inventory) and four ordinary operand
pairs out of the mixed ladder (`1 | -1`, `1 | 1/2`, `"a" | "0"`,
`(1,2) | (1..3)`). The counts in the caption are the whole family, not the
sample:

```sh
ls generated/inventory | wc -l                          # 139 operator atoms
grep -rhc '^- id' generated/inventory | paste -sd+ - | bc   # 69,576 tests
```

**Slide 8** shows an atom's own form filled from its ladders. The five values,
the twenty-five expressions and their recorded value-and-type all come from
[`../generated/operators/infix-plus.grid`](../generated/operators/infix-plus.grid),
whose header carries the form (`({A}) + ({B})`) and the eleven-value numeric
ladder; the slide shows a 5 × 5 corner of the 121.

**Slide 9** shows the molecule layer as composition rather than as results: a
nesting skeleton with a hole, an exit payload, and the program the two make.
The skeletons, the composed programs and the assertions all come straight out
of the records in [`../molecules/exit-nesting.grid`](../molecules/exit-nesting.grid)
— the `code` field of the `fall-through` column supplies each row's skeleton
(swap its `1` for the hole), and each cell is that row's code with the payload
highlighted. Twelve of the 140 cells fit on the slide; the caption carries the
full count.

The design deliberately mirrors the [Raku++ deck](https://github.com/ash/rakupp/tree/main/presentation)
— same palette, same chrome, same print rules — so the two read as one family.
