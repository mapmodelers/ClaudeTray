# tools/unit-keys.ps1 - shortcuts and placements, without Windows: the real functions from ClaudeTray.ps1, a fake panel window and screen.
#   pwsh -NoProfile -File tools/unit-keys.ps1
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeTray.ps1'
$tk = $null; $er = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$er)
$want = 'Close-Panel', 'Get-PopW', 'Hold-PopOnScreen', 'Set-WebZoom', 'ConvertTo-HotKey', 'Get-Places', 'Get-PlaceIx', 'Get-PlaceLabels', 'Save-PlaceNow', 'New-Place', 'Set-Place', 'Step-Place', 'Set-DockHere', 'Set-DockMemo'
foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $want -contains $n.Name }, $true)) { . ([scriptblock]::Create($f.Extent.Text)) }
$lim = [regex]::Match([IO.File]::ReadAllText($path), "(?s)\`$LimitSrc = @'\r?\n(.*?)\r?\n'@"); . ([scriptblock]::Create($lim.Groups[1].Value))
$fails = 0; function Ok($c, $t) { if ($c) { "ok   $t" } else { "FAIL $t"; $script:fails++ } }

# ---- shortcut text
$cases = [ordered]@{ 'Ctrl+Alt+Space' = '3,32,Ctrl+Alt+Space'; ' ctrl + alt + p ' = '3,80,Ctrl+Alt+P'; 'win+shift+c' = '12,67,Shift+Win+C'; 'Alt+F4' = '1,115,Alt+F4'; 'CTRL+ALT+PGDN' = '3,34,Ctrl+Alt+PageDown'; 'Control+Home' = '2,36,Ctrl+Home'; 'Ctrl+9' = '2,57,Ctrl+9'
    'P' = ''; 'Shift+P' = ''; 'Ctrl+Alt' = ''; 'Ctrl+Alt+' = ''; 'Ctrl+Foo' = ''; '' = ''; 'Space+Ctrl' = ''; 'Ctrl+P+Q' = '' }
$bad = @(); foreach ($c in $cases.Keys) { $r = ConvertTo-HotKey $c; $got = if ($r) { "$($r.Mod),$($r.Vk),$($r.Text)" } else { '' }; if ($got -ne $cases[$c]) { $bad += "'$c' -> '$got' (wanted '$($cases[$c])')" } }
Ok (-not $bad.Count) ("shortcut texts are read as written, bare keys and nonsense refused" + $(if ($bad.Count) { ': ' + ($bad -join '; ') } else { " ($($cases.Count) cases)" }))

# ---- placements: fake window, config that goes through JSON like the real file
$Cfg = @{ panelWidth = $null; panelHeight = $null }; $k = 1.0
function Save-CfgKey([string]$name, $value) { $o = [ordered]@{}; foreach ($kk in $Cfg.Keys) { $o[$kk] = $Cfg[$kk] }; $o[$name] = $value; $back = ([pscustomobject]$o | ConvertTo-Json) | ConvertFrom-Json; $script:Cfg = @{}; foreach ($pp in $back.PSObject.Properties) { $script:Cfg[$pp.Name] = $pp.Value } }
$UI = @{ Docked = $false; Zoom = 1.0; WebReady = $true }; $QS = @{ Place = $null; Dock = $null; DockB = $null }
$pop = [pscustomobject]@{ Left = 1500; Top = 600; Width = 340; Height = 400 }; $pop | Add-Member ScriptProperty Bottom { $this.Top + $this.Height }; $pop | Add-Member ScriptProperty Location { New-Object System.Drawing.Point $this.Left, $this.Top }
function px($v) { [int]$v }; function Get-PanelW { if ($Cfg.panelWidth) { [int]$Cfg.panelWidth } else { 340 } }
$pop | Add-Member ScriptProperty Right { $this.Left + $this.Width }; $pop | Add-Member NoteProperty Visible $true; $pop | Add-Member ScriptMethod SetBounds { param($x, $y, $w, $h) $this.Left = $x; $this.Top = $y; $this.Width = $w; $this.Height = $h }
function Place-SideWins { }
function Get-WorkArea([int]$sx, [int]$sy) { [pscustomobject]@{ Left = 0; Top = 0; Right = 1920; Bottom = 1040; Width = 1920; Height = 1040 } }
function Get-TrayPoint { New-Object System.Drawing.Point 1750, 1060 }
$script:toasts = @(); function Send-PanelKey($a, $b = '') { if ($a -eq 'toast') { $script:toasts += $b } }
function Log($t, $l = '') { }; function Pin-Pop { }; function Save-State { }; function Push-WebState($f) { }; function Refresh-Quests($f) { }; function Show-PanelKb { }
function Fit-WebPop { $h = if ([int]$Cfg.panelHeight -gt 0) { [int]$Cfg.panelHeight } else { 400 }; $bot = if ($UI.Docked) { [int]$QS.DockB } else { $pop.Bottom }; $pop.Height = $h; $pop.Top = $bot - $h }
function Show-Pop($why) { if ($UI.Docked -and $UI.DockPos) { $pop.Left = $UI.DockPos.X; $pop.Top = [int]$QS.DockB - $pop.Height } else { $pop.Left = 1750 - [int]($pop.Width / 2); $pop.Top = 1040 - 8 - $pop.Height }; $UI.Shown = $true }
function Now9 { "$($pop.Left),$($pop.Bottom) $($pop.Width)x$($pop.Height) place=$($QS.Place) docked=$($UI.Docked)" }
function Drag([int]$x, [int]$top) { $pop.Left = $x; $pop.Top = $top; Set-DockHere }
function Resize([int]$w, [int]$h) { $pop.Width = $w; $bot = $pop.Bottom; $pop.Height = $h; $pop.Top = $bot - $h; Save-CfgKey 'panelWidth' $w; Save-CfgKey 'panelHeight' $h; Save-PlaceNow }

Show-Pop 'x'; Ok ((Get-PlaceIx) -eq 0 -and (Get-Places).Count -eq 0) 'fresh install: default placement, nothing saved'
Step-Place; Ok ($toasts[-1] -like 'No placement yet*' -and (Get-PlaceIx) -eq 0) 'the shortcut with nothing saved: says how to make one'
Drag 100 300; Ok ((Get-PlaceIx) -eq 1 -and (Get-Places).Count -eq 1 -and (Get-Places)[0].x -eq 100 -and (Get-Places)[0].b -eq 700) "dragging the panel away from the tray makes placement 1 ($(Now9))"
Resize 500 457; Ok ((Get-Places)[0].w -eq 500 -and (Get-Places)[0].h -eq 457 -and (Get-Places)[0].b -eq 700) 'resizing it updates placement 1'
Step-Place; Ok ((Get-PlaceIx) -eq 0 -and -not $UI.Docked -and $pop.Width -eq 340 -and $pop.Left -eq 1580 -and $toasts[-1] -eq 'Default placement') "shortcut: back to the default spot at its own size ($(Now9))"
Step-Place; Ok ((Get-PlaceIx) -eq 1 -and $UI.Docked -and (Now9) -like '100,700 500x457*' -and $toasts[-1] -eq 'Placement 1 of 1') "shortcut again: placement 1 exactly as left ($(Now9))"
Drag 200 100; Ok ((Get-Places).Count -eq 1 -and (Get-Places)[0].x -eq 200 -and (Get-Places)[0].b -eq 557) 'dragging while on placement 1 moves that placement, no new one'
# a second one: 'new placement here' then drag it
Save-PlaceNow; $n2 = New-Place; $QS.Place = $n2; Drag 900 500; Resize 340 300
Ok ($n2 -eq 2 -and (Get-Places).Count -eq 2 -and (Get-Places)[1].x -eq 900 -and (Get-Places)[1].w -eq 340 -and (Get-Places)[0].x -eq 200) "a second placement, moved and resized on its own ($(Now9))"
Step-Place; $a = Now9; Step-Place; $b = Now9; Step-Place; $c = Now9; Step-Place; $d = Now9
Ok ($a -like '1580,* 340x400 place=0*' -and $b -like '200,557 500x457 place=1*' -and $c -like '900,957 340x300 place=2*' -and $d -like '1580,* place=0*') "the shortcut cycles default -> 1 -> 2 -> default ($a | $b | $c)"
Ok ((Get-PlaceLabels) -join ' | ' -eq '500 x 457 | 340 x 300') "the menu labels ($((Get-PlaceLabels) -join ' | '))"
# the default spot is always compact; a size you gave it there is kept as a placement when you move on
Resize 420 380; Step-Place; $p3 = (Get-Places)[2]
Ok ((Get-Places).Count -eq 3 -and $p3.w -eq 420 -and $p3.h -eq 380 -and (Get-PlaceIx) -eq 3 -and $UI.Docked -and $toasts[-1] -eq 'Kept as placement 3') "resized at the default spot, then the shortcut: that spot is kept as placement 3 ($(Now9))"
Step-Place; Ok ((Now9) -like '1580,* 340x400 place=0*') "and the next press is the compact default ($(Now9))"
Resize 600 500; Set-Place 0; Ok ((Now9) -like '1580,* 340x400 place=0*' -and (Get-Places).Count -eq 3 -and -not $Cfg.panelWidth -and -not $Cfg.panelHeight) "'default placement' always gives the compact panel, whatever its size was ($(Now9))"
# upgrade: a panel already pinned somewhere, nothing saved about placements
$Cfg = @{ panelWidth = 500; panelHeight = 457 }; $QS = @{ Place = $null; Dock = @(1143, 569); DockB = 1026 }; $UI.Docked = $true; $UI.DockPos = New-Object System.Drawing.Point 1143, 569
$pop.Left = 1143; $pop.Width = 500; $pop.Height = 457; $pop.Top = 569
Ok ((Get-PlaceIx) -eq -1) 'upgrade with a pinned panel: its spot counts as not saved yet'
Step-Place; Ok ((Get-Places).Count -eq 1 -and (Get-Places)[0].x -eq 1143 -and (Get-Places)[0].b -eq 1026 -and (Get-PlaceIx) -eq 0) "first shortcut press keeps that spot as placement 1, then goes to default ($(Now9))"
Step-Place; Ok ((Now9) -like '1143,1026 500x457 place=1*') "and the next press is back there ($(Now9))"
# a fourth spot: the three are taken
Save-PlaceNow; $QS.Place = (New-Place); Drag 10 10; Save-PlaceNow; $QS.Place = (New-Place); Drag 20 20
Ok ((Get-Places).Count -eq 3 -and (New-Place) -eq 0) 'three placements at most'
# a monitor that is gone: the placement comes back on screen
Save-CfgKey 'places' @([ordered]@{ x = 3000; b = 2000; w = 340; h = 300 }); $QS.Place = 0; $UI.Docked = $false; Set-Place 1 $false
Ok ($pop.Left -eq 1580 -and $pop.Bottom -eq 1040) "a placement on a screen that is gone is brought back on screen ($(Now9))"
# Ctrl+wheel on a panel that nearly fills the screen (it went off the screen and out of reach, 0.3.26)
$Cfg = @{ panelWidth = 1874; panelHeight = 996; panelZoom = 1 }; $QS = @{ Place = 1; Dock = @(27, 40); DockB = 1036 }; $UI.Docked = $true; $UI.Zoom = 1.0; $UI.Sides = @{}; $UI.DockPos = New-Object System.Drawing.Point 27, 40
$pop.Left = 27; $pop.Top = 40; $pop.Width = 1874; $pop.Height = 996
function Fit-WebPop { $h = [Math]::Min([int]([int]$Cfg.panelHeight * $UI.Zoom), [int](1040 * 0.95)); $bot = [int]$QS.DockB; $pop.Height = $h; $pop.Top = [Math]::Max(0, $bot - $h) }
$worst = ''; foreach ($d in 1, 1, 1, 1, 1, 1) { Set-WebZoom $d; if ($pop.Left -lt 0 -or $pop.Right -gt 1920 -or $pop.Top -lt 0 -or $pop.Bottom -gt 1040) { $worst = Now9 } }
Ok (-not $worst -and $UI.Zoom -eq 1.3 -and $pop.Width -eq 1920 -and $pop.Height -gt 900) "zooming in on a near full-screen panel keeps it inside the screen ($(Now9))$worst"
foreach ($d in -1, -1, -1, -1, -1, -1) { Set-WebZoom $d }
Ok ($pop.Width -eq 1874 -and $pop.Left -ge 0 -and $pop.Right -le 1920 -and [int]$Cfg.panelWidth -eq 1874 -and [int]$Cfg.panelHeight -eq 996) "zooming back out gives the same size, and the saved size never changed ($(Now9))"
$pop.Left = -1162; $pop.Top = 212; $pop.Width = 2203; Hold-PopOnScreen
Ok ($pop.Left -eq 0 -and $pop.Width -eq 1920 -and $pop.Top -ge 0 -and $pop.Bottom -le 1040) "a panel found outside the screen is brought back when shown ($(Now9))"
Ok (((Get-Content -Raw $path) -match "'placedel' \{") -and ((Get-Content -Raw $path) -match "'hotkey' \{")) 'menu actions are wired'
# the window's close button: hidden, next open = the small panel next to the tray, the spot it leaves is kept
function Hide-Pop($why, $force) { $script:hid9 = "$why/$force"; $UI.Shown = $false }
$Cfg.places = @([ordered]@{ x = 0; b = 1006; w = 1874; h = 996 }); $Cfg.panelWidth = 570; $Cfg.panelHeight = 663; $UI.Docked = $true; $UI.Shown = $true; $QS.Place = -1
$pop.Left = 700; $pop.Top = 200; $pop.Width = 570; $pop.Height = 663; $QS.DockB = 863; Close-Panel
Ok ($script:hid9 -eq 'close/True' -and -not $UI.Docked -and $QS.Place -eq 0 -and -not $Cfg.panelWidth -and -not $Cfg.panelHeight -and $pop.Width -eq 340) "close: hidden, unpinned, back to the compact default ($script:hid9, place $($QS.Place), width $($pop.Width))"
Ok ((Get-Places).Count -eq 2 -and (Get-Places)[1].w -eq 570 -and (Get-Places)[1].x -eq 700 -and (Get-Places)[1].b -eq 863) "close: the window spot it left is kept as placement 2 ($((Get-Places).Count))"
$UI.Shown = $true; Close-Panel; Ok ((Get-Places).Count -eq 2) 'close from the default spot adds nothing'
# an unpinned panel leaves when another program's window comes to the front (Alt+Tab, Start menu) - the real C# lines compile, the rule runs on a stand-in
$cs9 = @([regex]::Matches((Get-Content -Raw $path), '(?m)^\s*(\[DllImport\("user32\.dll", EntryPoint = "Get(WindowThreadProcessId|ClassNameW)".*|public static string WinInfo\(IntPtr h\).*)$') | ForEach-Object { $_.Value })
Ok ($cs9.Count -eq 3) "the three native lines for 'which window is in front' are there ($($cs9.Count))"
$okc9 = $true; try { Add-Type -TypeDefinition ("using System; using System.Runtime.InteropServices; namespace T9 { public static class N { " + ($cs9 -join "`n") + "`n } }") -ErrorAction Stop } catch { $okc9 = $false; "$_" }
Ok $okc9 'and they compile'
Add-Type -TypeDefinition 'using System; namespace ClaudeTray { public static class Native { public static IntPtr Fg; public static string Info; public static IntPtr GetForegroundWindow() { return Fg; } public static string WinInfo(IntPtr h) { return Info; } } }'
. ([scriptblock]::Create(@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-FgElsewhere' }, $true))[0].Extent.Text))
function Fg9([int]$h, [string]$info) { [ClaudeTray.Native]::Fg = [IntPtr]$h; [ClaudeTray.Native]::Info = $info; Test-FgElsewhere }
$UI.FgSeen = $null; $UI.FgHold = $null
Ok (-not (Fg9 100 '4242|Notepad')) 'the window in front when the panel opens is only noted'
Ok (-not (Fg9 100 '4242|Notepad')) 'nothing changes: the panel stays'
Ok (-not (Fg9 200 "$PID|WindowsForms10")) 'you click in the panel (its own window in front): it stays'
Ok (-not (Fg9 300 '777|Shell_TrayWnd')) 'the taskbar in front (a click on the tray icon): left to the click rule'
Ok ((Fg9 400 '555|Chrome_WidgetWin_1') -and $UI.FgWhy -eq 'Chrome_WidgetWin_1') 'Alt+Tab to another program: the panel leaves'
$UI.FgSeen = $null; [void](Fg9 100 '4242|Notepad'); $UI.FgHold = (Get-Date).AddSeconds(3)
Ok (-not (Fg9 500 '888|CabinetWClass')) 'a window that opens right after you ran a step in the panel: it stays'
$UI.FgHold = (Get-Date).AddSeconds(-1)
Ok (-not (Fg9 500 '888|CabinetWClass')) 'and that window is not counted again later'
Ok (Fg9 100 '4242|Notepad') 'going to yet another window after that: the panel leaves'
Ok (-not (Fg9 0 '')) 'no window in front (lock screen, admin prompt): nothing happens'
if ($fails) { "$fails FAILED"; exit 1 } else { 'ALL OK' }
