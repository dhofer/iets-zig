# Events

Set `IETS_EVENTS` to watch parts of a run. Each thing that happens becomes
one JSON object on one line:

```
$ IETS_EVENTS=store iets eval --no-cache --expr 'builtins.toFile "x" "y"'
{"event":"store-add","path":"/nix/store/lfngsssysp6h1v4ccqg23c52s9sjl779-x","kind":"text","size":1,"from":"text","at":"«string»:1:1"}
"/nix/store/lfngsssysp6h1v4ccqg23c52s9sjl779-x"
```

`IETS_EVENTS` takes one or more groups. `IETS_EVENTS_TO` says where the
records go: a file, a unix socket, or `-` for stderr, which is the default.

```
IETS_EVENTS=store                       # one group, to stderr
IETS_EVENTS=store,fetch                 # two
IETS_EVENTS=all IETS_EVENTS_TO=/tmp/e.jsonl
```

`IETS_STATS` counts how much an evaluation did (`docs/reference/settings.md`),
and `IETS_PROFILE=eval` shows where the time went
(`docs/reference/profile.md`).

Match on the `event` field and read the fields you know. A new field or event
name may appear at any time, so ignore what you don't know. A field that is
there keeps its meaning, and the order of the fields is not fixed. With no
group named, no record is built. A watched run costs about 0.4 % of its
instructions, and each line is one `write`.

## The groups

A cold group is cheap, and `all` turns on every cold group. A warm group
fires often, so `all` leaves it out and you must name it.

Only `store` writes events (`store-add`). The other groups are accepted
names that write nothing:

| Class | Groups |
|:---|:---|
| cold | `syntax`, `ir`, `import`, `store`, `fetch`, `flake`, `cache`, `build`, `lint`, `error` |
| warm | `drv`, `io` |

A name that is not a group is an error. Otherwise a typo would watch
nothing and look like a quiet run:

```
$ IETS_EVENTS=stor iets eval -f . -A x
error: IETS_EVENTS: 'stor' is not an event group (all, syntax, ir, import, …)
```

## `store-add`

One store path that the evaluation made from a source. Each event is an
`addToStore` or `addTextToStore` call of Nix. iets writes nothing to the
store, so the path names content that only an upload or a build puts there
(`docs/explanation/evaluation.md`).

| Field | Meaning |
|---|---|
| `path` | the store path |
| `kind` | `tree` for the NAR of a tree, `flat` for one file added as itself, `text` for `builtins.toFile` |
| `size` | NAR bytes for `tree`, the file's or the text's own bytes for `flat` and `text` |
| `from` | the local tree or input store entry the bytes came from, with `(filtered)` when a filter keeps part of it out of the copy; `text` for a `toFile` |
| `at` | the expression that made it, as `file:line:column` |

Each call gives one line, in the order the calls finished. A path appears
once per call: two derivations that name the same patch add it twice, as
they do in Nix. A locked flake input is already in the store, so it is
not an add.

The `store_adds` counter of `IETS_STATS` counts the same calls, but it can
miss the last task of a worker. The events are the exact record.

```
$ IETS_EVENTS=store iets eval --no-cache --raw -f ./nixpkgs -A hello.drvPath
{"event":"store-add","path":"/nix/store/d0h3b1fj9hahy3lvh2kpny75w47la15s-builder.sh","kind":"tree","size":5288,"from":"/tmp/nixpkgs/pkgs/build-support/fetchurl/builder.sh","at":"/tmp/nixpkgs/pkgs/stdenv/generic/make-derivation.nix:693:11"}
```

This gets the total size and the five biggest adds:

```
$ IETS_EVENTS=store IETS_EVENTS_TO=/tmp/e.json iets eval --no-cache --raw -f ./nixpkgs -A hello.drvPath
$ jq -s 'map(.size) | add' /tmp/e.json
$ jq -s -r 'sort_by(-.size)[:5][] | "\(.size)\t\(.from)"' /tmp/e.json
```
