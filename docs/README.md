# How these docs are written

The docs follow [Diátaxis](https://diataxis.fr/). Each page has one job, and
the folder it lives in says which job that is. When a page starts doing a
second job, that part belongs on another page.

| folder | the reader wants to | the page gives them |
|---|---|---|
| `reference/` | look something up | complete, accurate facts, in tables where it fits |
| `explanation/` | understand why | the reasons, the tradeoffs, the history |

`reference/` is a link to `src/cli/docs/`: those pages are embedded in the
binary and printed by `iets help`. They began as copies of Rust iets's, and
`scripts/cli-parity.sh` compares them with `../iets/docs/reference/`. A page
that changes because iets in Zig behaves differently gets that difference
mapped back in the script's `ours`, so the comparison keeps catching the
rest.

Rust iets also has tutorial and how-to pages (`../iets/docs/tutorial/`,
`../iets/docs/how-to/`); they are not carried here.

## What goes where

- **Reference.** Describe what the reader can call, set or read, and what it
  does. Keep the same shape for every entry, so people and programs can scan
  it. Do not teach, and do not tell the story of the code.
- **Explanation.** Talk about why iets works the way it does. This is the
  place for design, tradeoffs, internals and dated measurements. Say which
  binary a measurement was made on: numbers from before the port were
  measured on Rust iets.

Code tours, file paths and struct names are for contributors. They go in
`AGENTS.md` or the module's own doc comment, not on these
pages.

## Voice and style

Write the way you'd explain it to a colleague at their desk. The mechanics
follow the Google developer documentation style guide, applied with
judgment.

**Prose**

- Open with the reader's situation: "You have a derivation and a machine
  that should build it", not "This page describes remote builds".
- Say you, use contractions, and give an opinion when it's true.
- Say what is so. Name the mechanism, give the reason in one clause, and
  stop. No "it is worth noting", no tour of the page.
- State the positive. Cut a trailing "not y" that restates the point, and
  keep a contrast only when the reader would otherwise guess wrong.
- One idea per sentence, in the plain word. Don't invent a name for an idea
  the reader has never seen.
- Show an example early.
- Describe what the code does. Skip courtroom words ("rule", "law", "must
  obey") for design properties. "Rule" is fine for a lint rule or a grammar rule.
- Say plainly where iets differs from Nix.
- Don't announce counts ("Two rules keep a walk safe"). Count only when the
  number is the fact: exit code 100, a limit of 500 paths.
- Leave out what isn't built. Avoid time words ("now", "today", "no longer")
  and put history on the history page.

**Headings**

- Sentence case, no numbers, no "X and Y".
- Say what the section holds. A short noun is enough when it does
  ("Deadlocks", "Stack limits"). A label that could head any page
  ("Searching", "Scope") needs a clause: "Search speed".
- Don't write a sentence where a noun will do.
- Section headings are short nouns ("Error handling", "Build derivations").
  Page titles use a bare verb ("Build on a remote builder"). Reference pages
  name the thing, in code font when it is a name.
- Introduce a list or procedure with a sentence that names its items. "Each
  part does one job:" names nothing.

**Links and spelling**

- Link text is the target page's title. `reference/` pages are embedded in
  the binary (`iets help`), so they name other pages with a plain `docs/…`
  path in code font.
- American spelling, except Nix's own terms ("realise").
- Name a section instead of saying "above" or "below".
