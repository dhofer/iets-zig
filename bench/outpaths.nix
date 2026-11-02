# The whole-nixpkgs universe, from fix (github.com/psyclyx/fix,
# test/nixpkgs/outpaths.nix at e0c1f6d6, MIT License, Copyright (c) 2026
# psyclyx). Unchanged below this header.
# Differential-eval universe for fix vs a reference Nix: flattens nixpkgs'
# own CI eval job tree (ci/eval/outpaths.nix — the same universe nixpkgs CI
# evaluates per-PR) into a single attrset of
#
#   { "<attr.path>" = "<drvPath>" | null; }
#
# where null means the attr threw during evaluation (caught with tryEval).
# The drvPath hashes the complete derivation closure, so equality of this
# attrset between two evaluators certifies agreement on everything that fed
# into each package. Both engines evaluate this same file, so the recursion
# and error-catching policy are identical on both sides by construction.
{
  nixpkgs, # path to the pinned nixpkgs checkout
  subtree ? null, # dotted attr path to restrict the universe, e.g. "haskellPackages"
  only ? null, # list of top-level attr names to keep — bisection aid for hard errors
  # null = the HOST platform (nixpkgs ci/eval treats null as
  # [ builtins.currentSystem ]). The universe is always the native one —
  # never cross-eval: nixpkgs' enumeration machinery names attrs with
  # currentSystem (e.g. dotnet's -linux-arm64 runtimes), so a pinned
  # foreign system aborts on non-x86 hosts.
  systems ? null,
  # Trace each attr path before forcing it: with --workers 1 the last traced
  # path on stderr names the attr whose hard (non-tryEval-catchable) error
  # killed the eval.
  trace ? false,
}:
let
  lib = import (nixpkgs + "/lib");

  jobs = import (nixpkgs + "/ci/eval/outpaths.nix") {
    path = nixpkgs;
    inherit systems;
  };

  root0 = if subtree == null then jobs else lib.getAttrFromPath (lib.splitString "." subtree) jobs;
  root =
    if only == null then
      root0
    else
      builtins.intersectAttrs (lib.genAttrs only (_: null)) root0;

  isDerivation = v: (builtins.tryEval (v.type or null)).value or null == "derivation";

  drvPathOf =
    v:
    let
      attempt = builtins.tryEval v.drvPath;
    in
    if attempt.success then attempt.value else null;

  recurse =
    prefix: value:
    let
      attempt = builtins.tryEval value;
      v = attempt.value;
    in
    if !attempt.success then
      [
        {
          name = prefix;
          value = null;
        }
      ]
    else if isDerivation v then
      [
        {
          name = prefix;
          value = drvPathOf (if trace then builtins.trace prefix v else v);
        }
      ]
    # The root of the job tree is not itself marked recurseForDerivations
    # (nixpkgs' tweak only marks nested sets), so always recurse at the top.
    else if
      builtins.isAttrs v
      && (prefix == "" || (builtins.tryEval (v.recurseForDerivations or false)).value or false)
    then
      builtins.concatLists (
        lib.mapAttrsToList (n: sub: recurse (if prefix == "" then n else prefix + "." + n) sub) (
          removeAttrs v [ "recurseForDerivations" ]
        )
      )
    else
      [ ];
in
builtins.listToAttrs (recurse "" root)
