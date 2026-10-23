# Changes

## Unreleased

- A two-item list of expected tokens no longer has a comma before "or":
  "Expecting ')' or an operator." instead of "Expecting ')', or an operator.".
- `stele tune` finds the `%on_error_reduce` annotations wherever menhir does:
  in several declarations, indented, spread over lines, with comments. It
  edits them in place, so each keeps its priority level. It used to read only
  the first declaration line and rewrite every such line with its list.
- `stele tune` can now try removing the last annotation (it used to write an
  empty declaration, which menhir rejects, and reported the move as skipped),
  and advises on additions for a grammar that has no annotation yet.
- `stele tune` counts the rule names that read as code jargon, as `stats`
  reports under "jargon-rendered nonterminals". New jargon, token or rule, no
  longer makes a move harmful when the move improves something else: the
  config fixes a name, so the report lists the names as a caveat instead. A
  move whose only effect is new jargon is still harmful.
- `stele tune` reports a grammar menhir rejects with menhir's own error, and a
  bad config as such. The timing line now goes to stderr.
- "jargon-rendered nonterminals" in `stats` also catches a rule name shown
  through its list ("Expecting '}' or a stmt." for a list of `stmt`).
- An override whose prose contains '<' no longer counts as a delimiter hint in
  `stats`; only a line starting with a `<N>` marker does.
- Two overrides for the same sentence, an override with no message, and a
  `<^N>` marker outside the state's stack are now errors.
- A duplicate `[names]` entry is now an error, and config syntax errors give
  the file and line.
- A missing input file or an unreadable `.cmly` gives a one-line `stele: ...`
  error instead of an exception.
- "Assuming that the X is complete": a `[names]` value written without an
  article now gets "is" or "are" from its last word, instead of always "are".
- The runtime helper finds an opening delimiter on an earlier line when it has
  to walk back to it.
- `stele suggest-classes` writes "entries" instead of "entrie(s)".

## 0.1.0

First release as a standalone project. stele was previously developed inside
the [Wax](https://github.com/ocsigen/wax) toolchain, which uses it for the error
messages of both its grammars.

- `stele generate` writes a message for every error state of a Menhir grammar,
  from `menhir --list-errors` and the grammar's `.cmly`: the list of what could
  come next, a hint pointing at the unclosed delimiter, and an "Assuming that
  ... is complete" message where the grammar uses `%on_error_reduce`.
- A per-grammar config file improves the wording (readable names, token classes,
  extra delimiters), and an overrides file holds hand-written messages. Stale
  entries in either fail the build.
- `stats`, `census`, `names`, `fallbacks`, `suggest-classes` and `transitions`
  help review and improve the messages; `stats` and `census` are meant to be
  pinned as golden files.
- `stele tune` suggests changes to the grammar's `%on_error_reduce`
  annotations.
- The `stele.runtime` library turns the location markers in a message into
  source spans at parse time. It depends only on `menhirLib`, so it also works
  under `js_of_ocaml` and `wasm_of_ocaml`.
- A tutorial and a runnable example (`example/`).
