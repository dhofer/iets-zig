# elvish completion for iets: put 'eval (iets completion elvish | slurp)' in rc.elv
use str

set edit:completion:arg-completer[iets] = {|@words|
  var out = [(try { (external $words[0]) __complete (all $words[1..]) } catch e { put :4 })]
  var directive = (str:trim-prefix $out[-1] ':')
  var found = $false
  for line $out[..-1] {
    var p = [(str:split &max=2 "\t" $line)]
    var display = $p[0]
    if (> (count $p) 1) {
      set display = $p[0]'  '$p[1]
    }
    edit:complex-candidate $p[0] &display=$display
    set found = $true
  }
  if (and (not $found) (eq $directive 0)) {
    edit:complete-filename $words[-1]
  }
}
