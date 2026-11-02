# fish completion for iets: 'iets completion fish | source'
function __iets_complete
    set -l cur (commandline -ct)
    set -l words (commandline -opc)[2..-1] "$cur"
    set -l out (command $argv[1] __complete $words 2>/dev/null)
    or return
    set -l directive (string replace -r '^:' '' -- $out[-1])
    set -e out[-1]
    if test (count $out) -gt 0
        printf '%s\n' $out
    else if test "$directive" = 0
        __fish_complete_path "$cur"
    end
end
complete -c iets -f -a '(__iets_complete (commandline -opc)[1])'
