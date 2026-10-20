<#
 tools\check.ps1 - static checks to run before every deploy (PowerShell 5.1 or 7, any OS):
   1. parse errors
   2. locals that shadow script-level globals (PS variable names are case-insensitive and scoping is
      dynamic: a handler's `$k = ...` breaks every px() call made while it runs - it happened)
 Usage: pwsh -File tools/check.ps1 [-Path ClaudeTray.ps1]     exit code 1 = problems
#>
param([string]$Path = (Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeTray.ps1'))
$errs = $null; $tokens = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errs)
$bad = 0
foreach ($e in $errs) { Write-Host ("PARSE {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message); $bad++ }
# globals = variables assigned at the top level of the script (outside any function / scriptblock literal)
$isNested = { param($n) $p = $n.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst] -or $p -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { return $true }; $p = $p.Parent }; return $false }
$assigns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [System.Management.Automation.Language.VariableExpressionAst] }, $true)
$globals = @{}
foreach ($a in $assigns) { if (-not (& $isNested $a)) { $nm = $a.Left.VariablePath.UserPath; if ($nm -notmatch '^(script|global):') { $globals[$nm.ToLower()] = $a.Extent.StartLineNumber } } }
$ignore = @('_', 'e', 'sender', 'p', 'i', 'r', 'w', 'd', 'c', 'n', 'l', 'f', 'b', 'x', 'y', 'h', 'o', 'm', 'a', 'u', 'v', 'j', 'old', 'txt', 'text', 'ok', 'err', 'ex', 'res', 'out', 'q', 'null')   # throwaway names reused on purpose at top level
foreach ($a in $assigns) {
    if (-not (& $isNested $a)) { continue }
    $nm = $a.Left.VariablePath.UserPath; if ($nm -match '^(script|global):') { continue }
    $low = $nm.ToLower()
    if ($globals.ContainsKey($low) -and $ignore -notcontains $low) {
        Write-Host ("SHADOW line {0}: `${1} assigned in a function/handler; global `${2} is defined at line {3}" -f $a.Extent.StartLineNumber, $nm, $nm, $globals[$low]); $bad++
    }
}
# foreach loop variables count too
$loops = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ForEachStatementAst] }, $true)
foreach ($l in $loops) { if (& $isNested $l) { $low = $l.Variable.VariablePath.UserPath.ToLower(); if ($globals.ContainsKey($low) -and $ignore -notcontains $low) { Write-Host ("SHADOW line {0}: foreach `${1} in a function/handler; global defined at line {2}" -f $l.Extent.StartLineNumber, $l.Variable.VariablePath.UserPath, $globals[$low]); $bad++ } } }
# 2b. function/scriptblock parameters named like a global (e.g. Open-Chat($web) hid the $Web engine object while it ran)
#     ($Probe / $Web are fine: the runspace scripts receive that same object as their parameter)
$params = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
foreach ($pa in $params) { $low = $pa.Name.VariablePath.UserPath.ToLower(); if (@('probe', 'web') -contains $low) { continue }; if ($globals.ContainsKey($low) -and $ignore -notcontains $low) { Write-Host ("SHADOW line {0}: parameter `${1} hides the global defined at line {2}" -f $pa.Extent.StartLineNumber, $pa.Name.VariablePath.UserPath, $globals[$low]); $bad++ } }
# 3. comments that swallowed code (an end-of-line comment inserted before more statements: happened twice)
foreach ($tk in $tokens) {
    if ($tk.Kind -ne 'Comment') { continue }
    $tx = $tk.Text
    if ($tx -match '^#[^\r\n]*(;\s*\$\w+(\.\w+)*\s*=|\}\s*(else|catch|finally)\b|;\s*(if|foreach|try|return)\b|\$\w+\.(Add|Remove|Dispose)\()') { Write-Host ("COMMENT line {0}: looks like it contains code: {1}" -f $tk.Extent.StartLineNumber, $tx.Substring(0, [Math]::Min(90, $tx.Length))); $bad++ }
}
# 4. JavaScript syntax (if node is installed): the panel pages and the scripts injected into claude.ai
#    (one stray quote in a tooltip once broke the whole panel)
if (Get-Command node -ErrorAction SilentlyContinue) {
    $root0 = Split-Path -Parent $PSScriptRoot; $tmpJs = Join-Path ([IO.Path]::GetTempPath()) 'ct_check.js'
    $chunks = @()
    foreach ($pg in 'ui\panel.html', 'ui\side.html') { $fp = Join-Path $root0 ($pg -replace '\\', [IO.Path]::DirectorySeparatorChar); if (Test-Path $fp) { $h = [IO.File]::ReadAllText($fp); $m0 = [regex]::Match($h, '(?s)<script>(.*?)</script>'); if ($m0.Success) { $chunks += , @($pg, $m0.Groups[1].Value) } } }
    $srcAll = [IO.File]::ReadAllText($path)
    foreach ($vn in 'js', 'msgJs', 'fileJs', 'catJs', 'pickJs') { $m1 = [regex]::Match($srcAll, '(?s)\$' + $vn + " = @'\r?\n(.*?)\r?\n'@"); if ($m1.Success) { $chunks += , @("`$$vn", ('const __x = ' + $m1.Groups[1].Value.Replace('__FILES__', '(() => [])').Replace('__N__', '20'))) } }
    foreach ($ch in $chunks) { [IO.File]::WriteAllText($tmpJs, $ch[1]); $o = & node --check $tmpJs 2>&1; if ($LASTEXITCODE) { Write-Host ("JS {0}: {1}" -f $ch[0], (($o | Select-Object -First 4) -join ' | ')); $bad++ } }
    Remove-Item $tmpJs -ErrorAction SilentlyContinue
}
if ($bad) { Write-Host "$bad problem(s)"; exit 1 } else { Write-Host 'check: OK' }
