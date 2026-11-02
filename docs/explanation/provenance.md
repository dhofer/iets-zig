# Trace a store path back to its source

A store path doesn't say which tree it came from, and a `.drv` path doesn't
say which attribute made it. iets remembers both while it evaluates and shows
them to you.

So when `iets build .#packages.x86_64-linux.boom` fails, you see this:

```
▶ building packages.x86_64-linux.boom (/home/u/repo/flake.nix:4:7)
✘  packages.x86_64-linux.boom failed after 2s (status 9: …), defined at /home/u/repo/flake.nix:4:7
```

And a line in the build log says `tree is /home/u/repo` where it would have
said `tree is /nix/store/3nma1…-source`.

## Recording

A store path is a hash of everything that went into it, so it hides where it
came from. That's a problem when a build fails and names a `.drv` among
thousands, or when a build log names a file under a copy of a tree you are
editing. The information is expensive to rebuild after evaluation, so iets
records it during.

## The source map

A source map maps store path prefixes to local directories, and the longest
match comes first. One function resolves a single path and another rewrites
every store path in a line of text. When a mapping points at another mapped
tree, iets resolves it when it builds the map, so `./.` inside a flake that
is already in the store still lands on your working copy.

The map is filled from these sources:

1. **Every tree the evaluation copied.** `./path`, `filterSource`,
   `builtins.path`, the root flake's tree, and every locked flake input of
   type `path`. This is the repository you are working on.
2. **The `source-map` setting**, for trees this evaluation did not copy: a
   list of `"STOREPATH=LOCALDIR"` strings in your user `iets.toml`. Use it
   to map a nixpkgs checkout onto the store path of the nixpkgs the lock
   names. Nothing checks that the directory holds the same tree as the store
   path.
3. **A revision**, for display only, when the root flake is a git working
   tree: the `HEAD` commit, with `-dirty` added when the tree is dirty.

## Positions

iets records **the position of the `name` attribute's value**. `derivation` is
a wrapper, written in Nix, around the `derivationStrict` primop, so for a
normal call the primop's own position is inside an internal file. (A direct
`builtins.derivationStrict` call keeps its own position.) Nix names the same
position when it says "whose name attribute is located at".

`stdenv.mkDerivation` computes `name` in `make-derivation.nix`, but it
passes the package's `pname` through. So the position of `pname` comes
first, which is also what nixpkgs' own `meta.position` does. A package that
sets `pname` points at its own file.

A package that sets only `name` through a nixpkgs builder, like `runCommand`,
loses that binding to `make-derivation.nix`. Then iets falls back to the first
attribute the set still holds from a lint root, usually `src`. The value lints
use the same fallback.

A `runCommand` or `writeText` call holds none of these, and points into
nixpkgs. That's true when you call it yourself, and for most NixOS units,
which the `systemd` module makes from your options. The call stack can't
help: `derivationStrict` runs when something reads `drvPath`, and by then
the call that made the attribute set has returned. That position is the
same for every such derivation, so it can't tell them apart. iets doesn't put a position on the `building` line when another
derivation of the evaluation has the same position. The failure line
always has the position.

A position in a locked input that no local directory stands for shows the
lock node name in place of the store path:
`nixpkgs/pkgs/stdenv/generic/make-derivation.nix:651:11`. The build log
keeps the store path, because the node name isn't a path.

**The attribute path comes from the command line walk.** Classic mode records
the path it walked, and `iets build` uses `-A` or the flake fragment.

## Output that carries provenance

| place | with provenance | without |
|---|---|---|
| build started (`iets build`) | `▶ building <attr> (<file>:<line>:<col>)`, the position only when no other derivation shares it | `▶ building <attr>` |
| build failed (`iets build`) | `✘  <attr> failed after <time> (<reason>), defined at <file>:<line>:<col>` | `✘  <attr> failed after <time> (<reason>)` |
| build failed (`print-dev-env`) | `build of <attr> failed (<drv basename>), defined at <file>:<line>:<col>: <reason>` | `build of <drv path> failed: <reason>` |
| build log | every mapped store path replaced | the store path |
| evaluation errors | positions and messages mapped | the store path |
| `eval-jobs --provenance` | a `pos` key per job | no `pos` key |

Classic `nix-build` and `nix-instantiate` keep the same stdout, and only
stderr carries provenance. `nix-eval-jobs` 2.35 has no position field, which
is why `pos` needs a flag: the default output must match Nix's.

These stay unmapped:

- **A derivation read from `/nix/store`**: an `import` of a `.drv`, a build
  of a `.drv` path, or a run that hit the evaluation cache. There is no
  position and no attribute, because the cache keeps neither. A cache hit
  does rewrite store paths in text, but it names no derivation.
- **Outputs.** An output path is not a source. Whatever tree an output came
  from, the output is not that tree, so rewriting it would be a lie.
- **nixpkgs and other inputs that are not `path`.** Their trees were fetched,
  so no local directory is their source. Use `source-map`.
- **`builtins.toFile` texts.** They live in memory and come from no local
  tree.

Set `IETS_PROVENANCE=0` to turn off every rewrite and every provenance line.

## Build renderer pitfalls

**The position is added in one place.** A caller passes the bare
attribute. The dispatcher writes `<attr> (<pos>)` for the state-change
lines and `, defined at <pos>` for the failure line. A caller that passed a
composed name would get the position twice.

**A remote build makes two activities for one derivation.** A local daemon
with a remote builder runs the build behind a build hook, so there is the
hook's own `building X on 'ssh-ng://…'` and the build itself. The renderer
drops a start for a derivation it already shows. While a build operation owns
a derivation, the end of an activity prints no verdict, because the protocol
message says a build ended, not whether it worked, and the hook's activity
ends first. The operation's own result decides, and until then the log buffer
stays open, so the daemon's error text lands inside that build's log block.
A derivation the operation does not own, such as a dependency, takes its
verdict from the daemon's failure messages.
