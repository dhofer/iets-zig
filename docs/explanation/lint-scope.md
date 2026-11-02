# What iets lints

iets warns you that `x == "a"` can never be true when `x` is a number. It
won't tell you that a `let` binding is unused, or that you should have
written `inherit`. This page explains where that line is and why, and how to
write the style rules you want yourself. The lints themselves are in
[Lints](../reference/lints.md).

## No style opinions

> iets reports what only an evaluator can know. It has no opinion about
> how code looks.

A lint belongs in the registry when it needs evaluation to decide (its
stage in `iets lint list` is `evaluator`) and tells you what the code does,
in correctness, performance or purity.

`x == "a"` is fine syntax. The comparison is always false only when `x` is a
number, and only the evaluator knows the value of `x`. Likewise only the
evaluator knows which directory a coercion copies to the store, for
`git-in-source`.

## Existing tools

Style is the project's call. nixpkgs has its own style, and it changes with
the kind of file and the path. A lint about `with`, an unused binding or
`a = a;` asks you to change code that is correct.

Tools that read only the syntax already exist: statix and deadnix. Copying
their rules into iets makes the binary bigger and tells you nothing new.

## Syntactic lints

A few lints don't need evaluation. Each stays for its own reason.

| Lint | Reason |
|---|---|
| `absolute-path-literal`, `short-path-literal`, `url-literal` | Nix 2.34 has a setting for each (`lint-absolute-path-literals`, `lint-short-path-literals`, `lint-url-literals`). iets follows Nix here. |
| `unknown-allow` | It checks that a `# iets: allow` comment names a lint in the registry. Without it, a typo silences nothing and tells nobody. |

## Finding sites

A site in your repository is reported, and a site in an input stays quiet
([Lints](../reference/lints.md#scope), under "Scope").

`tree-meta-in-drv` and `rev-count` break it, on purpose.
`tree-meta-in-drv` reports source tree metadata (`self.rev`,
`self.lastModifiedDate`) that ends up in a derivation. That value changes
with every commit, so every commit rebuilds the derivation and everything
that depends on it.

Consider these cases:

- You set `system.configurationRevision = self.rev`. nixpkgs writes the
  value into the `nixos-version` derivation. The site is in nixpkgs, but
  the value is yours, and your commits cause the rebuild.
- nixpkgs writes its own `lastModifiedDate` and `shortRev` into the NixOS
  version. That value changes only when you update the lock file, and then
  a rebuild is right.

So the tree the value comes from sets the level. The root tree gets the
lint's level, `warn` by default. A locked input stays quiet unless
`[lint.inputs.<node>]` gives it a level.

`rev-count` splits the same way: the root tree's count changes with every
commit, and a locked input's count is a number in the lock file
([The tree that a value comes from](../reference/lints.md#the-tree-that-a-value-comes-from)).

iets knows the tree because each metadata string carries a mark, a string
context element that Nix doesn't have. It travels with the string through
`+`, interpolation, `substring` and `concatStringsSep`, like a store path
reference. Nix never sees it: `getContext`, `hasContext`, `==`, `toJSON` and
the `.drv` files stay the same.

## Your own rules

A rule is a program you write. `iets parse --json` prints the syntax tree
with the byte span of every node, and iets's own findings carry the same
spans. iets never applies an edit itself.

## Left out

- A language for rules.
- A plug-in loader.
- A syntax tree that keeps every byte of the file. Comments and
  parentheses are not in the tree.
- A command that applies the edits of the findings.

## Unknown lint names

Your `iets.toml` can name a lint that iets doesn't have, for example after
you downgrade iets. iets warns once for each such name, with the code
`unknown-lint`, and carries on. `--lint` on the command line gives an error
instead. [Lints](../reference/lints.md) says why.

## Defaults

A lint that fires on nixpkgs or on the language tests defaults to `off`, and
only a lint that fires nowhere may default to `warn`. `dir-copy-unfiltered`
is the exception. It fires on three language tests and is `warn`, because
outside a flake nothing else stops `"${./.}"` from taking your untracked
files with it.

## Cost

An `off` lint is one byte compare at the site, and turning every lint on
doesn't change evaluation time beyond run-to-run noise.
