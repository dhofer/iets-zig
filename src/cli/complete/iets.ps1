# PowerShell completion for iets (7.3 or later, which passes an empty
# argument on): 'iets completion powershell | Out-String | Invoke-Expression'
Register-ArgumentCompleter -Native -CommandName iets -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)
    # the words that end before the cursor, then the one under it
    $before = @($commandAst.CommandElements |
        Select-Object -Skip 1 |
        Where-Object { $_.Extent.EndOffset -lt $cursorPosition } |
        ForEach-Object { $_.ToString() })
    $words = $before + @($wordToComplete)
    $out = @(& $commandAst.CommandElements[0].ToString() __complete @words 2>$null)
    if ($out.Count -eq 0) { return }
    $directive = [int]($out[-1] -replace '^:', '')
    $lines = @($out | Select-Object -SkipLast 1)
    if ($lines.Count -eq 0) {
        # nothing returned is PowerShell's own file completion; to offer
        # nothing, offer what is typed, as a result cannot be empty
        if ($directive -ne 0) {
            $same = if ($wordToComplete) { $wordToComplete } else { ' ' }
            [System.Management.Automation.CompletionResult]::new(
                $same, $same, 'ParameterValue', ' ')
        }
        return
    }
    foreach ($line in $lines) {
        $name, $about = $line -split "`t", 2
        if (-not $about) { $about = $name }
        [System.Management.Automation.CompletionResult]::new(
            $name, $name, 'ParameterValue', $about)
    }
}
