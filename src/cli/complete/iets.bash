# bash completion for iets: 'source <(iets completion bash)'
_iets() {
    local out directive line
    local -a words=("${COMP_WORDS[@]:1:COMP_CWORD}")
    words=("${words[@]//\\/}")
    out=$("${COMP_WORDS[0]}" __complete "${words[@]}" 2>/dev/null) || return
    directive=${out##*$'\n'}
    COMPREPLY=()
    while IFS= read -r line; do
        [[ $line == :* ]] || COMPREPLY+=("${line%%$'\t'*}")
    done <<<"$out"
    directive=${directive#:}
    if (( (directive & 4) == 0 && ${#COMPREPLY[@]} == 0 )); then
        compopt -o default 2>/dev/null
    else
        compopt +o default 2>/dev/null
    fi
    # a candidate that is not the end of the word gets no space after it
    if (( directive & 2 )); then compopt -o nospace 2>/dev/null; fi
}
complete -F _iets iets
