# nushell completion for iets. Nushell cannot source a pipe, so:
#   iets completion nushell | save -f ($nu.default-config-dir | path join iets-completions.nu)
# and 'source' that file from config.nu. It keeps the completer set before it.
let iets_previous = $env.config.completions.external.completer?
$env.config.completions.external.enable = true
$env.config.completions.external.completer = {|spans|
    if ($spans | first) != "iets" {
        if $iets_previous == null { return null }
        return (do $iets_previous $spans)
    }
    let out = try {
        run-external ($spans | first) "__complete" ...($spans | skip 1) | lines
    } catch { return null }
    if ($out | is-empty) { return null }
    let directive = ($out | last | str replace ':' '' | into int)
    let cands = $out | drop 1 | each {|l|
        let p = ($l | split row "\t")
        {value: $p.0, description: ($p | get 1? | default "")}
    }
    # null is nushell's own file completion, [] is none at all
    if ($cands | is-empty) and $directive == 0 { null } else { $cands }
}
