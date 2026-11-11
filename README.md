# Language Tooling

Transport-neutral editor and tooling foundations shared by language kits.

The package owns UTF-16 coordinate mapping, portable completion/navigation/
semantic-index values, deterministic semantic-token encoding, formatting
mechanics, and reusable conformance validation. It does not own a grammar,
parser, AST, name-binding policy, type system, compiler, editor, or LSP
transport.

Dependency direction is one way:

```text
language kits and hosts
          |
          v
  Language-Tooling
          |
          v
 Incremental-Parsing
```

PL/0 and Pascal supply language policy through projections into these values.

## Products

- `LanguageTooling` defines provider sessions, UTF-16 source mapping, editor
  values, semantic graphs and navigation queries, semantic-token encoding, and
  `LanguageToolingDocument`, a revision-validating consumer lifecycle actor.
- `LanguageToolingFormatting` provides deterministic indentation and whitespace
  mechanics. A language kit still decides where indentation and line breaks
  belong.
- `LanguageToolingTesting` validates semantic graphs and semantic-token streams
  without importing a particular language kit.
- `LanguageExperimentProtocol` owns transport-neutral experiment bundles,
  artifact identities, recovery/reuse evidence, and deterministic fingerprints.
  It was extracted from PL0-LanguageKit in Phase 32 and has no language or
  parser dependency.

## Ownership boundary

Language kits own grammar artifacts, lexical and syntactic projections,
binding and type rules, formatter policy, and compiler semantics. Hosts own
transport, UI, document lifetime, and visualization. Shared tooling contains
only mechanisms that are meaningful for more than one language and does not
depend on PL/0, Pascal, ModEdit, or a parser implementation.

PL/0 is the first semantic/navigation adopter: it projects its native scopes,
symbols, and references into `ToolingSemanticIndex`. Pascal is the independent
lightweight adopter: its provider exposes grammar-derived keyword completion
and encoded lexical semantic tokens through `LanguageToolingSession` without
adding a semantic model prematurely.

ModEdit, Grammar-REPL, and Grammar-Workbench now build their consumer adapters
on `LanguageToolingDocument`. The actor owns a provider session and the current
snapshot; it deliberately does not own provider selection, transport, UI, or
document persistence.

## Project-scale services

`LanguageToolingProject` extends that lifecycle to a revisioned collection of
URI-addressed documents. It aggregates diagnostics, reports rebuilt, reused,
and removed documents, and offers one definition, references, and workspace
rename surface to editors, REPLs, workbenches, and language-server transports.

Cross-file policy remains language-owned. A `LanguageToolingProjectResolver`
receives deterministic project snapshots and implements imports, visibility,
overload selection, and project symbol identity. Providers may override the
URI-aware session factory so every location refers to the actual document.
