# How `print-dev-env` makes a shell

`iets print-dev-env` gives you the same bash as `nix print-dev-env`. It
follows Nix's own `develop.cc`, and once you know the steps you can tell when
a run will be slow.

1. **Evaluate the shell derivation** through the normal flake path, so the
   tracing cache applies.
2. **Make the `-env` derivation in memory**, as Nix's
   `getDerivationEnvironment` does: the same inputs, Nix's own `get-env.sh`
   as its arguments (embedded as it is), the same `bash` builder, and `-env`
   added to the name. The output checks are removed and the output paths
   computed again. The result is the same `.drv` Nix writes, and a unit test
   checks that, so a shell that `nix develop` already built is not built
   again.
3. **Ask the daemon** whether it has the environment's output. If not, plan
   the closure from the derivations in memory, upload what the daemon
   lacks, and build.
4. **Read the first non-empty output** (from disk for a local daemon, over
   the protocol for `ssh-ng://`), and parse it.
5. **Print the same script Nix prints**: the same header, the same ignored
   variables, the same footer, and the same rewrite of every output path to
   `<cwd>/outputs/<name>`. A `__structuredAttrs` shell gets its `.attrs.sh`
   and `.attrs.json` written next to the garbage-collection root, or in a
   temporary directory when there is none. Nix writes them to a temporary
   directory that it deletes on exit.

A cache hit skips every step: iets checks the read set, looks at the output,
reads the link of the garbage-collection root, and prints. It talks to the
daemon only when the root must be made again. If the environment was garbage
collected, the run goes through all the steps. A cached run takes tens of
milliseconds, where `nix print-dev-env` takes seconds.

For direnv, `print-dev-env --entry-to FILE` writes the path of the cache
entry it used, and `iets cache paths` turns that entry into the files to
watch.
