<#
.SYNOPSIS
    Static code analysis for IBM DOORS DXL (.dxl) scripts.

.DESCRIPTION
    Scans one or more .dxl files and reports common issues found in DXL
    source: unbalanced delimiters, unterminated comments/strings, missing
    semicolons, style problems, risky calls, memory leaks, unused variables,
    hard-coded file paths, TODO markers, global variables, and complexity metrics.

.PARAMETER Path
    A .dxl file or a directory to analyze. Defaults to the current directory.
    Alias: -FilePath

.EXAMPLE
    pwsh -File ./dxl-analysis.ps1 -Path ./test.dxl
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [Alias('FilePath')]
    [string]$Path = ".",

    [switch]$Recurse,

    [ValidateSet('Console', 'Csv', 'Html')]
    [string]$OutputFormat = 'Console',

    [string]$OutputFile,

    [int]$MaxLineLength = 120,

    [int]$ComplexityThreshold = 10,

    [int]$FunctionLengthThreshold = 75,

    [ValidateSet('Error', 'Warning', 'Info', 'All')]
    [string]$SeverityFilter = 'All',

    [switch]$FailOnWarning
)

# ----------------------------------------------------------------------------
# File Discovery
# ----------------------------------------------------------------------------

function Get-DxlFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Recurse
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return @(Get-Item -LiteralPath $Path)
    }

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "Path not found: $Path"
    }

    $gciParams = @{
        Path   = $Path
        Filter = '*.dxl'
        File   = $true
    }
    if ($Recurse) { $gciParams['Recurse'] = $true }

    return @(Get-ChildItem @gciParams)
}

# ----------------------------------------------------------------------------
# Tokenizer
# ----------------------------------------------------------------------------

function Get-DxlTokenizedSource {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$Lines = @()
    )

    $cleanLines = [System.Collections.Generic.List[string]]::new()
    $comments   = [System.Collections.Generic.List[object]]::new()
    $strings    = [System.Collections.Generic.List[object]]::new()
    $issues     = [System.Collections.Generic.List[object]]::new()

    if ($null -eq $Lines -or $Lines.Count -eq 0) {
        return [PSCustomObject]@{
            CleanLines = $cleanLines
            Comments   = $comments
            Strings    = $strings
            Issues     = $issues
        }
    }

    $inBlockComment    = $false
    $blockCommentStart = 0
    $commentBuffer     = [System.Text.StringBuilder]::new()

    for ($lineIndex = 0; $lineIndex -lt $Lines.Count; $lineIndex++) {
        $line    = $Lines[$lineIndex]
        $lineNum = $lineIndex + 1
        $clean   = [System.Text.StringBuilder]::new()

        $inString     = $false
        $escaped      = $false
        $stringBuffer = [System.Text.StringBuilder]::new()

        $charIndex = 0
        while ($charIndex -lt $line.Length) {
            $ch     = $line[$charIndex]
            $nextCh = if (($charIndex + 1) -lt $line.Length) { $line[$charIndex + 1] } else { [char]0 }

            if ($inBlockComment) {
                [void]$commentBuffer.Append($ch)
                if ($ch -eq '*' -and $nextCh -eq '/') {
                    [void]$commentBuffer.Append('/')
                    $comments.Add([PSCustomObject]@{ Line = $blockCommentStart; Text = $commentBuffer.ToString() })
                    [void]$commentBuffer.Clear()
                    $inBlockComment = $false
                    [void]$clean.Append('  ')
                    $charIndex += 2
                    continue
                }
                [void]$clean.Append(' ')
                $charIndex++
                continue
            }

            if ($inString) {
                [void]$stringBuffer.Append($ch)
                if ($escaped) {
                    $escaped = $false
                }
                elseif ($ch -eq '\') {
                    $escaped = $true
                }
                elseif ($ch -eq '"') {
                    $inString = $false
                    $strings.Add([PSCustomObject]@{ Line = $lineNum; Text = $stringBuffer.ToString() })
                    [void]$stringBuffer.Clear()
                }
                [void]$clean.Append(' ')
                $charIndex++
                continue
            }

            if ($ch -eq '/' -and $nextCh -eq '/') {
                $commentText = $line.Substring($charIndex)
                $comments.Add([PSCustomObject]@{ Line = $lineNum; Text = $commentText })
                break
            }

            if ($ch -eq '/' -and $nextCh -eq '*') {
                $inBlockComment    = $true
                $blockCommentStart = $lineNum
                [void]$commentBuffer.Append('/*')
                [void]$clean.Append('  ')
                $charIndex += 2
                continue
            }

            if ($ch -eq '"') {
                $inString = $true
                [void]$stringBuffer.Append('"')
                [void]$clean.Append(' ')
                $charIndex++
                continue
            }

            [void]$clean.Append($ch)
            $charIndex++
        }

        if ($inString) {
            $issues.Add([PSCustomObject]@{
                Line     = $lineNum
                Severity = 'Error'
                Rule     = 'UnterminatedString'
                Message  = 'String literal is not closed before the end of the line.'
            })
        }

        $cleanLines.Add($clean.ToString())
    }

    if ($inBlockComment) {
        $issues.Add([PSCustomObject]@{
            Line     = $blockCommentStart
            Severity = 'Error'
            Rule     = 'UnterminatedComment'
            Message  = "Block comment opened at line $blockCommentStart with /* is never closed with */."
        })
    }

    return [PSCustomObject]@{
        CleanLines = $cleanLines
        Comments   = $comments
        Strings    = $strings
        Issues     = $issues
    }
}

# ----------------------------------------------------------------------------
# Rule Checks
# ----------------------------------------------------------------------------

function Test-DxlVariableUsage {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $types  = 'int|string|real|bool|Char|Buffer|Skip|Array|Stat|History|Object|Module|Stream|Item|Folder|Project'
    $declRegex = [regex]"\b($types)\s+([A-Za-z_]\w*)\b"
    $declarations = @{}

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        $lineNum = $i + 1
        $line    = $CleanLines[$i]

        $matches = $declRegex.Matches($line)
        foreach ($m in $matches) {
            $varName = $m.Groups[2].Value
            if ($varName -in @('main', 'null', 'void', 'true', 'false')) { continue }

            if (-not $declarations.ContainsKey($varName)) {
                $declarations[$varName] = [System.Collections.Generic.List[int]]::new()
            }
            $declarations[$varName].Add($lineNum)
        }
    }

    $allCleanText = $CleanLines -join "`n"

    foreach ($varName in $declarations.Keys) {
        $usagePattern = "\b$([regex]::Escape($varName))\b"
        $matches = [regex]::Matches($allCleanText, $usagePattern)

        if ($matches.Count -eq $declarations[$varName].Count) {
            foreach ($declLine in $declarations[$varName]) {
                $issues.Add([PSCustomObject]@{
                    Line     = $declLine
                    Severity = 'Warning'
                    Rule     = 'UnusedVariable'
                    Message  = "Variable '$varName' is declared but never referenced again."
                })
            }
        }
    }

    return $issues
}

function Test-DxlMemoryAllocation {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $allocRegex = [regex]'\b(Buffer|Skip|Array|Stat)\s+([A-Za-z_]\w*)\s*=\s*(create|createString|createM)\b'
    $reallocRegex = [regex]'\b([A-Za-z_]\w*)\s*=\s*(create|createString|createM)\b'

    $allocatedVars = @{}

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        $lineNum = $i + 1
        $line    = $CleanLines[$i]

        if ($line -match $allocRegex) {
            $type = $Matches[1]
            $varName = $Matches[2]
            if (-not $allocatedVars.ContainsKey($varName)) {
                $allocatedVars[$varName] = @{ Line = $lineNum; Type = $type }
            }
        }
        elseif ($line -match $reallocRegex) {
            $varName = $Matches[1]
            if (-not $allocatedVars.ContainsKey($varName)) {
                $allocatedVars[$varName] = @{ Line = $lineNum; Type = 'HeapObject' }
            }
        }
    }

    $allCleanText = $CleanLines -join "`n"

    foreach ($varName in $allocatedVars.Keys) {
        $allocInfo = $allocatedVars[$varName]
        $deletePattern = "\b(delete|close)\s*\(?\s*\b$([regex]::Escape($varName))\b\s*\)?"

        if ($allCleanText -notmatch $deletePattern) {
            $issues.Add([PSCustomObject]@{
                Line     = $allocInfo.Line
                Severity = 'Warning'
                Rule     = 'MemoryLeak'
                Message  = "$($allocInfo.Type) '$varName' is allocated here, but no corresponding 'delete($varName)' or 'close($varName)' call was found."
            })
        }
    }

    return $issues
}

function Test-BalancedDelimiters {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $stack  = [System.Collections.Generic.Stack[object]]::new()
    $pairs  = @{ ')' = '('; '}' = '{'; ']' = '[' }

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        $lineNum = $i + 1
        foreach ($ch in $CleanLines[$i].ToCharArray()) {
            if ($ch -eq '(' -or $ch -eq '{' -or $ch -eq '[') {
                $stack.Push([PSCustomObject]@{ Char = $ch; Line = $lineNum })
            }
            elseif ($ch -eq ')' -or $ch -eq '}' -or $ch -eq ']') {
                if ($stack.Count -eq 0) {
                    $issues.Add([PSCustomObject]@{
                        Line = $lineNum; Severity = 'Error'; Rule = 'UnbalancedDelimiter'
                        Message = "Unexpected closing '$ch' with no matching opener."
                    })
                }
                else {
                    $top = $stack.Pop()
                    if ($top.Char -ne $pairs[$ch]) {
                        $issues.Add([PSCustomObject]@{
                            Line = $lineNum; Severity = 'Error'; Rule = 'UnbalancedDelimiter'
                            Message = "Mismatched '$ch' -- expected the closer for '$($top.Char)' opened at line $($top.Line)."
                        })
                    }
                }
            }
        }
    }

    while ($stack.Count -gt 0) {
        $top = $stack.Pop()
        $issues.Add([PSCustomObject]@{
            Line = $top.Line; Severity = 'Error'; Rule = 'UnbalancedDelimiter'
            Message = "'$($top.Char)' opened here is never closed."
        })
    }

    return $issues
}

function Test-DxlSemicolons {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $controlHeaderPattern = '^\s*(if|else\s+if|while|for|switch)\s*\(.*\)\s*$'
    $skipPattern          = '^\s*(else|do|try|finally)\s*$'
    $directivePattern     = '^\s*#'
    $continuationChars    = @('{', '}', ';', ',', ':', '(', '+', '-', '*', '/', '=', '&', '|', '<', '>', '!')

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        $lineNum = $i + 1
        $trimmed = $CleanLines[$i].Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        if ($trimmed -match $directivePattern) { continue }
        if ($trimmed -match $controlHeaderPattern) { continue }
        if ($trimmed -match $skipPattern) { continue }

        $lastChar = $trimmed.Substring($trimmed.Length - 1, 1)
        if ($continuationChars -contains $lastChar) { continue }

        $issues.Add([PSCustomObject]@{
            Line = $lineNum; Severity = 'Info'; Rule = 'PossibleMissingSemicolon'
            Message = "Line does not end with ';', '{' or '}' -- verify the statement is terminated."
        })
    }

    return $issues
}

function Test-DxlLineStyle {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$RawLines = @(),
        [int]$MaxLineLength = 120
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $RawLines -or $RawLines.Count -eq 0) { return $issues }

    $usesTabs   = $false
    $usesSpaces = $false

    for ($i = 0; $i -lt $RawLines.Count; $i++) {
        $lineNum = $i + 1
        $line    = $RawLines[$i]

        if ($line.Length -gt $MaxLineLength) {
            $issues.Add([PSCustomObject]@{
                Line = $lineNum; Severity = 'Info'; Rule = 'LineTooLong'
                Message = "Line is $($line.Length) characters long (limit: $MaxLineLength)."
            })
        }

        if ($line -match '\s+$') {
            $issues.Add([PSCustomObject]@{
                Line = $lineNum; Severity = 'Info'; Rule = 'TrailingWhitespace'
                Message = 'Line has trailing whitespace.'
            })
        }

        if ($line -match '^\t') { $usesTabs = $true }
        if ($line -match '^    ') { $usesSpaces = $true }
    }

    if ($usesTabs -and $usesSpaces) {
        $issues.Add([PSCustomObject]@{
            Line = 1; Severity = 'Warning'; Rule = 'MixedIndentation'
            Message = 'File mixes tab-indented and space-indented lines. Pick one indentation style consistently.'
        })
    }

    return $issues
}

function Test-DxlTodoMarkers {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Comments = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Comments -or $Comments.Count -eq 0) { return $issues }

    foreach ($c in $Comments) {
        if ($c.Text -match '\b(TODO|FIXME|HACK|XXX)\b') {
            $marker = $Matches[1]
            $issues.Add([PSCustomObject]@{
                Line     = $c.Line
                Severity = 'Info'
                Rule     = 'TodoMarker'
                Message  = "Found $marker marker in comment."
            })
        }
    }

    return $issues
}

function Test-DxlHardcodedPaths {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Strings = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Strings -or $Strings.Count -eq 0) { return $issues }

    $driveLetterPattern = '[A-Za-z]:\\'
    $uncPathPattern     = '\\\\[\w.$-]+\\'

    foreach ($s in $Strings) {
        if ($s.Text -match $driveLetterPattern -or $s.Text -match $uncPathPattern) {
            $issues.Add([PSCustomObject]@{
                Line     = $s.Line
                Severity = 'Warning'
                Rule     = 'HardcodedPath'
                Message  = 'String literal looks like a hard-coded absolute file path -- consider a configurable or relative path instead.'
            })
        }
    }

    return $issues
}

function Test-DxlRiskyCalls {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        $lineNum = $i + 1
        if ($CleanLines[$i] -match '\bsystem\s*\(') {
            $issues.Add([PSCustomObject]@{
                Line = $lineNum; Severity = 'Warning'; Rule = 'SystemCall'
                Message = 'Call to system() runs an OS-level command -- review for injection risk and portability across DOORS installations.'
            })
        }
    }

    return $issues
}

function Test-DxlResourceHandles {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @()
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $openPattern  = '\b(Module|Stream)\s+\w+\s*=\s*(edit|read|write|append)\s*\('
    $closePattern = '\bclose\s*\('

    $openLines  = [System.Collections.Generic.List[int]]::new()
    $closeCount = 0

    for ($i = 0; $i -lt $CleanLines.Count; $i++) {
        if ($CleanLines[$i] -match $openPattern) { $openLines.Add($i + 1) }
        $closeCount += [regex]::Matches($CleanLines[$i], $closePattern).Count
    }

    if ($openLines.Count -gt $closeCount) {
        $issues.Add([PSCustomObject]@{
            Line = $openLines[0]; Severity = 'Warning'; Rule = 'PossibleUnclosedHandle'
            Message = "File opens $($openLines.Count) Module/Stream handle(s) (lines: $($openLines -join ', ')) but only $closeCount close() call(s) were found."
        })
    }

    return $issues
}

function Get-DxlStructureAnalysis {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [string[]]$CleanLines = @(),
        [int]$ComplexityThreshold = 10,
        [int]$FunctionLengthThreshold = 75
    )

    $issues = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $CleanLines -or $CleanLines.Count -eq 0) { return $issues }

    $funcHeaderPattern = '^\s*(void|int|string|real|bool|Object|Module|Item|Skip|Stream)\s+([A-Za-z_]\w*)\s*\(([^)]*)\)\s*\{?\s*$'
    $declPattern       = '^\s*(int|string|real|bool|Object|Module|Item|Skip|Stream)\s+[A-Za-z_]\w*\s*='

    $depth = 0
    $i = 0
    while ($i -lt $CleanLines.Count) {
        $lineNum = $i + 1
        $line    = $CleanLines[$i]
        $trimmed = $line.Trim()

        if ($depth -eq 0 -and $trimmed -match $funcHeaderPattern) {
            $funcName = $Matches[2]

            $braceLineIndex = $i
            while ($braceLineIndex -lt $CleanLines.Count -and $CleanLines[$braceLineIndex] -notmatch '\{') {
                $braceLineIndex++
            }

            if ($braceLineIndex -ge $CleanLines.Count) {
                $i++
                continue
            }

            $localDepth = 0
            $bodyStart  = $braceLineIndex
            $bodyEnd    = $braceLineIndex
            $started    = $false

            for ($j = $braceLineIndex; $j -lt $CleanLines.Count; $j++) {
                foreach ($ch in $CleanLines[$j].ToCharArray()) {
                    if ($ch -eq '{') { $localDepth++; $started = $true }
                    elseif ($ch -eq '}') { $localDepth-- }
                }
                if ($started -and $localDepth -eq 0) { $bodyEnd = $j; break }
            }

            $bodyLines = ($CleanLines[$bodyStart..$bodyEnd]) -join "`n"

            $decisionCount  = 0
            $decisionCount += ([regex]::Matches($bodyLines, '\bif\s*\(')).Count
            $decisionCount += ([regex]::Matches($bodyLines, '\bwhile\s*\(')).Count
            $decisionCount += ([regex]::Matches($bodyLines, '\bfor\s*\(')).Count
            $decisionCount += ([regex]::Matches($bodyLines, '\bcase\b')).Count
            $decisionCount += ([regex]::Matches($bodyLines, '&&')).Count
            $decisionCount += ([regex]::Matches($bodyLines, '\|\|')).Count

            $complexity = $decisionCount + 1
            $funcLength = ($bodyEnd - $bodyStart) + 1

            if ($complexity -gt $ComplexityThreshold) {
                $issues.Add([PSCustomObject]@{
                    Line = $lineNum; Severity = 'Warning'; Rule = 'HighComplexity'
                    Message = "Function '$funcName' has an estimated cyclomatic complexity of $complexity (threshold: $ComplexityThreshold)."
                })
            }
            if ($funcLength -gt $FunctionLengthThreshold) {
                $issues.Add([PSCustomObject]@{
                    Line = $lineNum; Severity = 'Info'; Rule = 'LongFunction'
                    Message = "Function '$funcName' is about $funcLength lines long (threshold: $FunctionLengthThreshold)."
                })
            }

            $i = $bodyEnd + 1
            continue
        }

        if ($depth -eq 0 -and $trimmed -match $declPattern) {
            $issues.Add([PSCustomObject]@{
                Line = $lineNum; Severity = 'Info'; Rule = 'GlobalVariable'
                Message = 'Variable declared at top level. DXL top-level state persists across execution cycles.'
            })
        }

        foreach ($ch in $line.ToCharArray()) {
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') { $depth-- }
        }

        $i++
    }

    return $issues
}

# ----------------------------------------------------------------------------
# Orchestrator
# ----------------------------------------------------------------------------

function Invoke-DxlFileAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [int]$MaxLineLength = 120,
        [int]$ComplexityThreshold = 10,
        [int]$FunctionLengthThreshold = 75
    )

    $rawText = Get-Content -LiteralPath $FilePath -Raw -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($rawText) -or $rawText.Contains("`0")) {
        $rawText = Get-Content -LiteralPath $FilePath -Raw -Encoding Unicode -ErrorAction SilentlyContinue
    }

    if ([string]::IsNullOrWhiteSpace($rawText)) {
        return [PSCustomObject]@{
            File         = $FilePath
            TotalLines   = 0
            BlankLines   = 0
            CommentLines = 0
            Issues       = @()
            ErrorCount   = 0
            WarningCount = 0
            InfoCount    = 0
        }
    }

    $rawText  = $rawText -replace "`0", ""
    $rawLines = $rawText -split '\r\n|\r|\n'

    $tokenized  = Get-DxlTokenizedSource -Lines $rawLines
    $cleanLines = $tokenized.CleanLines

    $allIssues = [System.Collections.Generic.List[object]]::new()
    $allIssues.AddRange([object[]]$tokenized.Issues)
    $allIssues.AddRange([object[]]@(Test-BalancedDelimiters -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Test-DxlSemicolons -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Test-DxlLineStyle -RawLines $rawLines -MaxLineLength $MaxLineLength))
    $allIssues.AddRange([object[]]@(Test-DxlTodoMarkers -Comments $tokenized.Comments))
    $allIssues.AddRange([object[]]@(Test-DxlHardcodedPaths -Strings $tokenized.Strings))
    $allIssues.AddRange([object[]]@(Test-DxlRiskyCalls -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Test-DxlResourceHandles -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Test-DxlVariableUsage -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Test-DxlMemoryAllocation -CleanLines $cleanLines))
    $allIssues.AddRange([object[]]@(Get-DxlStructureAnalysis -CleanLines $cleanLines -ComplexityThreshold $ComplexityThreshold -FunctionLengthThreshold $FunctionLengthThreshold))

    $sorted = @($allIssues | Sort-Object Line)

    $commentLineCount = @($tokenized.Comments | Select-Object -ExpandProperty Line -Unique).Count
    $blankLineCount   = @($rawLines | Where-Object { $_.Trim() -eq '' }).Count

    return [PSCustomObject]@{
        File         = $FilePath
        TotalLines   = $rawLines.Count
        BlankLines   = $blankLineCount
        CommentLines = $commentLineCount
        Issues       = $sorted
        ErrorCount   = @($sorted | Where-Object Severity -eq 'Error').Count
        WarningCount = @($sorted | Where-Object Severity -eq 'Warning').Count
        InfoCount    = @($sorted | Where-Object Severity -eq 'Info').Count
    }
}

# ----------------------------------------------------------------------------
# Output
# ----------------------------------------------------------------------------

function Write-ConsoleReport {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @(),

        [string]$SeverityFilter = 'All'
    )

    if ($null -eq $Results -or $Results.Count -eq 0) {
        Write-Host "No analysis results to display." -ForegroundColor Yellow
        return
    }

    $severityColor = @{ Error = 'Red'; Warning = 'Yellow'; Info = 'Cyan' }

    foreach ($result in $Results) {
        $issuesToShow = $result.Issues
        if ($SeverityFilter -ne 'All') {
            $issuesToShow = @($issuesToShow | Where-Object Severity -eq $SeverityFilter)
        }

        Write-Host ""
        Write-Host "== $($result.File) ==" -ForegroundColor White
        Write-Host "   Lines: $($result.TotalLines)  Blank: $($result.BlankLines)  Comment: $($result.CommentLines)  |  Errors: $($result.ErrorCount)  Warnings: $($result.WarningCount)  Info: $($result.InfoCount)" -ForegroundColor Gray

        if ($issuesToShow.Count -eq 0) {
            Write-Host "   No issues found." -ForegroundColor Green
            continue
        }

        foreach ($issue in $issuesToShow) {
            $color = $severityColor[$issue.Severity]
            Write-Host ("   [{0,-7}] Line {1,-5} {2,-24} {3}" -f $issue.Severity, $issue.Line, $issue.Rule, $issue.Message) -ForegroundColor $color
        }
    }

    $totalErrors   = ($Results | Measure-Object -Property ErrorCount -Sum).Sum
    $totalWarnings = ($Results | Measure-Object -Property WarningCount -Sum).Sum
    $totalInfo     = ($Results | Measure-Object -Property InfoCount -Sum).Sum

    Write-Host ""
    Write-Host "==================== Summary ====================" -ForegroundColor White
    Write-Host ("Files analyzed : {0}" -f $Results.Count)
    Write-Host ("Errors         : {0}" -f $totalErrors)   -ForegroundColor Red
    Write-Host ("Warnings       : {0}" -f $totalWarnings) -ForegroundColor Yellow
    Write-Host ("Info           : {0}" -f $totalInfo)     -ForegroundColor Cyan
}

function Export-DxlReportCsv {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @(),

        [Parameter(Mandatory)][string]$OutputFile
    )

    $rows = foreach ($result in $Results) {
        foreach ($issue in $result.Issues) {
            [PSCustomObject]@{
                File     = $result.File
                Line     = $issue.Line
                Severity = $issue.Severity
                Rule     = $issue.Rule
                Message  = $issue.Message
            }
        }
    }

    if (-not $rows) {
        [PSCustomObject]@{ File = ''; Line = ''; Severity = ''; Rule = ''; Message = 'No issues found.' } |
            Export-Csv -LiteralPath $OutputFile -NoTypeInformation
    }
    else {
        $rows | Export-Csv -LiteralPath $OutputFile -NoTypeInformation
    }

    Write-Host "CSV report written to $OutputFile"
}

function ConvertTo-HtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $Text = $Text -replace '&', '&amp;'
    $Text = $Text -replace '<', '&lt;'
    $Text = $Text -replace '>', '&gt;'
    $Text = $Text -replace '"', '&quot;'
    return $Text
}

function Export-DxlReportHtml {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @(),

        [Parameter(Mandatory)][string]$OutputFile
    )

    $totalErrors   = ($Results | Measure-Object -Property ErrorCount -Sum).Sum
    $totalWarnings = ($Results | Measure-Object -Property WarningCount -Sum).Sum
    $totalInfo     = ($Results | Measure-Object -Property InfoCount -Sum).Sum
    $fileCount     = $Results.Count

    $sb = [System.Text.StringBuilder]::new()

    [void]$sb.Append(@"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>DXL Code Analysis Report</title>
<style>
  body { font-family: 'Segoe UI', Arial, sans-serif; margin: 24px; color: #222; }
  h1 { margin-bottom: 4px; }
  .summary { margin-bottom: 20px; }
  .summary span { margin-right: 18px; font-weight: bold; }
  .err  { color: #c0392b; }
  .warn { color: #b8860b; }
  .info { color: #2980b9; }
  table { border-collapse: collapse; width: 100%; margin-bottom: 28px; }
  th, td { border: 1px solid #ddd; padding: 6px 10px; font-size: 13px; text-align: left; }
  th { background: #f4f4f4; }
  tr.Error   { background: #fdecea; }
  tr.Warning { background: #fdf6ea; }
  tr.Info    { background: #eaf4fd; }
  .file-header { background: #333; color: #fff; padding: 6px 10px; font-weight: bold; margin-top: 18px; }
</style>
</head>
<body>
<h1>DXL Code Analysis Report</h1>
<div class="summary">
  <span class="err">Errors: $totalErrors</span>
  <span class="warn">Warnings: $totalWarnings</span>
  <span class="info">Info: $totalInfo</span>
  <span>Files analyzed: $fileCount</span>
</div>
"@)

    foreach ($result in $Results) {
        $safeFile = ConvertTo-HtmlSafe -Text $result.File
        [void]$sb.Append("<div class=""file-header"">$safeFile &mdash; $($result.TotalLines) lines, $($result.ErrorCount) errors, $($result.WarningCount) warnings, $($result.InfoCount) info</div>`n")

        if ($result.Issues.Count -eq 0) {
            [void]$sb.Append("<p>No issues found.</p>`n")
            continue
        }

        [void]$sb.Append("<table><tr><th>Line</th><th>Severity</th><th>Rule</th><th>Message</th></tr>`n")
        foreach ($issue in $result.Issues) {
            $safeMsg  = ConvertTo-HtmlSafe -Text $issue.Message
            $safeRule = ConvertTo-HtmlSafe -Text $issue.Rule
            [void]$sb.Append("<tr class=""$($issue.Severity)""><td>$($issue.Line)</td><td>$($issue.Severity)</td><td>$safeRule</td><td>$safeMsg</td></tr>`n")
        }
        [void]$sb.Append("</table>`n")
    }

    [void]$sb.Append("</body></html>")

    Set-Content -LiteralPath $OutputFile -Value $sb.ToString() -Encoding UTF8
    Write-Host "HTML report written to $OutputFile"
}

# ----------------------------------------------------------------------------
# Main Execution Path
# ----------------------------------------------------------------------------

$files = Get-DxlFiles -Path $Path -Recurse:$Recurse

if ($files.Count -eq 0) {
    Write-Warning "No .dxl files found at '$Path'."
    exit 0
}

$results = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
    try {
        $result = Invoke-DxlFileAnalysis -FilePath $file.FullName -MaxLineLength $MaxLineLength -ComplexityThreshold $ComplexityThreshold -FunctionLengthThreshold $FunctionLengthThreshold
        if ($null -ne $result) {
            $results.Add($result)
        }
    }
    catch {
        Write-Warning "Failed to analyze '$($file.FullName)': $($_.Exception.ToString())"
    }
}

if ($results.Count -eq 0) {
    Write-Host "Analysis completed, but no file results were produced." -ForegroundColor Yellow
    exit 0
}

switch ($OutputFormat) {
    'Console' {
        Write-ConsoleReport -Results $results -SeverityFilter $SeverityFilter
    }
    'Csv' {
        if (-not $OutputFile) { $OutputFile = 'dxl-analysis-report.csv' }
        Export-DxlReportCsv -Results $results -OutputFile $OutputFile
        Write-ConsoleReport -Results $results -SeverityFilter $SeverityFilter
    }
    'Html' {
        if (-not $OutputFile) { $OutputFile = 'dxl-analysis-report.html' }
        Export-DxlReportHtml -Results $results -OutputFile $OutputFile
        Write-ConsoleReport -Results $results -SeverityFilter $SeverityFilter
    }
}

$totalErrors   = ($results | Measure-Object -Property ErrorCount -Sum).Sum
$totalWarnings = ($results | Measure-Object -Property WarningCount -Sum).Sum

if ($FailOnWarning -and ($totalErrors -gt 0 -or $totalWarnings -gt 0)) {
    exit 1
}
elseif ($totalErrors -gt 0) {
    exit 1
}

exit 0