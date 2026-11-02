#compdef iets
# zsh completion for iets: put this file in $fpath as _iets, or
# 'source <(iets completion zsh)' after compinit
_iets() {
    local out directive line
    local -a cands
    out=$("${words[1]}" __complete "${(@Q)words[2,CURRENT]}" 2>/dev/null) || return
    directive=${${(f)out}[-1]#:}
    for line in "${(@f)out}"; do
        [[ $line == :* ]] && continue
        # _describe takes NAME:DESCRIPTION, a colon in the name escaped
        local name=${line%%$'\t'*} about=
        [[ $line == *$'\t'* ]] && about=${line#*$'\t'}
        cands+=("${name//:/\\:}${about:+:$about}")
    done
    local -a nospace
    # a candidate that is not the end of the word gets no space after it
    (( directive & 2 )) && nospace=(-S '')
    if (( ${#cands} )); then
        _describe -t iets 'iets' cands "${nospace[@]}"
    elif (( ! (directive & 4) )); then
        _files
    fi
}
if [[ $funcstack[1] == _iets ]]; then
    _iets "$@"
else
    compdef _iets iets
fi
