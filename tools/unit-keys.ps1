# tools/unit-keys.ps1 - shortcuts and placements, without Windows: the real functions from ClaudeTray.ps1, a fake panel window and screen.
#   pwsh -NoProfile -File tools/unit-keys.ps1
$path = Join-Path (Split-Path -Parent $PSScriptRoot) 'ClaudeTray.ps1'
$tk = $null; $er = $null; $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tk, [ref]$er)
$want = 'Invoke-HotKey', 'Close-Panel', 'Get-PopW', 'Hold-PopOnScreen', 'Set-WebZoom', 'ConvertTo-HotKey', 'Get-Places', 'Get-PlaceIx', 'Get-PlaceLabels', 'Save-PlaceNow', 'New-Place', 'Set-Place', 'Step-Place', 'Set-DockHere', 'Set-DockMemo'
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
# Ctrl+wheel changes the text, not the frame: same pixels before and after, sizes re-expressed for the new zoom (also the placements not in use)
$Cfg.places = @([ordered]@{ x = 27; b = 1036; w = 1874; h = 996 }, [ordered]@{ x = 900; b = 1000; w = 600; h = 500 }); $pop.Left = 27; $pop.Width = 1874; $pop.Height = 988; $pop.Top = 48
$w0 = $pop.Width; $h0 = $pop.Height; $worst = ''; foreach ($d in 1, 1, 1, 1, 1, 1) { Set-WebZoom $d; if ($pop.Width -ne $w0 -or [Math]::Abs($pop.Height - $h0) -gt 3 -or $pop.Left -lt 0 -or $pop.Right -gt 1920) { $worst = " at $($UI.Zoom): $(Now9)" } }
Ok (-not $worst -and $UI.Zoom -eq 1.3 -and [int]$Cfg.panelWidth -eq [int][Math]::Round(1874 / 1.3)) "zooming in keeps the frame as it is, to the pixel in width ($(Now9), stored width $($Cfg.panelWidth))$worst"
Ok ([Math]::Abs((Get-Places)[1].w * 1.3 - 600) -le 2 -and [Math]::Abs((Get-Places)[1].h * 1.3 - 500) -le 2 -and (Get-Places)[0].w -eq [int]$Cfg.panelWidth) "the other placement keeps its pixels too: 600 x 500 is now stored as $((Get-Places)[1].w) x $((Get-Places)[1].h) at 130 %"
foreach ($d in -1, -1, -1, -1, -1, -1) { Set-WebZoom $d }
Ok ($pop.Width -eq $w0 -and [Math]::Abs($pop.Height - $h0) -le 3 -and [int]$Cfg.panelWidth -eq 1874 -and [Math]::Abs([int]$Cfg.panelHeight - 996) -le 2 -and [Math]::Abs((Get-Places)[1].w - 600) -le 2) "and back out: same frame, sizes back to what they were ($(Now9), $($Cfg.panelWidth) x $($Cfg.panelHeight), other $((Get-Places)[1].w) x $((Get-Places)[1].h))"
$Cfg.panelWidth = $null; $Cfg.panelHeight = $null; $Cfg.places = @(); $UI.Docked = $false; $QS.Place = 0; $pop.Width = 340; $UI.Zoom = 1.0; Set-WebZoom 4
Ok ($UI.Zoom -eq 1.2 -and $pop.Width -eq 340 -and -not $Cfg.panelWidth) "the small tray panel stays 340 wide at 120 % ($($pop.Width))"
$UI.Zoom = 1.0; $Cfg.panelWidth = 1874; $Cfg.panelHeight = 996; $UI.Docked = $true; $QS.Place = -1
$pop.Left = -1162; $pop.Top = 212; $pop.Width = 2203; Hold-PopOnScreen
Ok ($pop.Left -eq 0 -and $pop.Width -eq 1920 -and $pop.Top -ge 0 -and $pop.Bottom -le 1040) "a panel found outside the screen is brought back when shown ($(Now9))"
Ok (((Get-Content -Raw $path) -match "'placedel' \{") -and ((Get-Content -Raw $path) -match "'hotkey' \{")) 'menu actions are wired'
$Cfg.panelWidth = $null; $Cfg.panelHeight = $null; $UI.Docked = $false; $QS.Place = 0
# Ctrl+Alt+D: the tray panel, and a second press goes back to the window you came from
function Show-PanelKb { }; $Cfg.places = @([ordered]@{ x = 27; b = 1036; w = 900; h = 700 }, [ordered]@{ x = 500; b = 900; w = 600; h = 500 }); $UI.Zoom = 1.0; $UI.Shown = $true; $UI.PlaceBack = $null
Set-Place 2 $false; Invoke-HotKey 3; $a9 = Get-PlaceIx; $w9 = $pop.Width; Invoke-HotKey 3
Ok ($a9 -eq 0 -and $w9 -eq 340 -and (Get-PlaceIx) -eq 2 -and $pop.Width -eq 600 -and $UI.Docked) "the tray-panel shortcut: from placement 2 to the small panel, and again: back to placement 2 ($a9 / $w9, then $(Now9))"
$UI.PlaceBack = $null; Set-Place 0 $false; Invoke-HotKey 3; Ok ((Get-PlaceIx) -eq 1) "pressed on the small panel with nothing to go back to: your first placement ($(Get-PlaceIx))"
$UI.Shown = $false; Set-Place 0 $false; $UI.Shown = $false; Invoke-HotKey 3; Ok ((Get-PlaceIx) -eq 0) 'pressed while the panel is hidden: it shows the small panel'
$UI.Shown = $true
foreach ($d in 1..30) { Set-WebZoom 1 }; $zmax9 = $UI.Zoom; foreach ($d in 1..40) { Set-WebZoom -1 }; Ok ($zmax9 -eq 2.0 -and $UI.Zoom -eq 0.5) "zoom goes from 50 % to 200 % ($($UI.Zoom) - $zmax9)"; $UI.Zoom = 1.0
# the window's close button: hidden, next open = the small panel next to the tray, the spot it leaves is kept
function Hide-Pop($why, $force) { $script:hid9 = "$why/$force"; $UI.Shown = $false }
$Cfg.places = @([ordered]@{ x = 0; b = 1006; w = 1874; h = 996 }); $Cfg.panelWidth = 570; $Cfg.panelHeight = 663; $UI.Docked = $true; $UI.Shown = $true; $QS.Place = -1
$pop.Left = 700; $pop.Top = 200; $pop.Width = 570; $pop.Height = 663; $QS.DockB = 863; Close-Panel
Ok ($script:hid9 -eq 'close/True' -and -not $UI.Docked -and $QS.Place -eq 0 -and -not $Cfg.panelWidth -and -not $Cfg.panelHeight -and $pop.Width -eq 340) "close: hidden, unpinned, back to the compact default ($script:hid9, place $($QS.Place), width $($pop.Width))"
Ok ((Get-Places).Count -eq 2 -and (Get-Places)[1].w -eq 570 -and (Get-Places)[1].x -eq 700 -and (Get-Places)[1].b -eq 863) "close: the window spot it left is kept as placement 2 ($((Get-Places).Count))"
$UI.Shown = $true; Close-Panel; Ok ((Get-Places).Count -eq 2) 'close from the default spot adds nothing'
# dictation: the recorder's native line compiles, the one-time download script is valid PowerShell, and the click / poll logic behaves
$mc9 = [regex]::Match((Get-Content -Raw $path), '(?m)^\s*\[DllImport\("winmm\.dll".*mciSendString\(.*$').Value
$okm9 = $true; try { Add-Type -TypeDefinition ("using System; using System.Runtime.InteropServices; namespace M9 { public static class N { " + $mc9 + "`n } }") -ErrorAction Stop } catch { $okm9 = $false; "$_" }
Ok ($mc9 -and $okm9) 'mciSendString is declared and compiles'
$ds9 = [regex]::Match((Get-Content -Raw $path), "(?s)\`$DictSetupSrc = @'\r?\n(.*?)\r?\n'@").Groups[1].Value; $pe9 = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($ds9, [ref]$null, [ref]$pe9)
Ok ($ds9.Length -gt 800 -and $pe9.Count -eq 0 -and $ds9 -match 'SHA256' -and $ds9 -match 'SHA1' -and $ds9 -notmatch 'Select-Object') "the download script parses, checks both checksums ($($ds9.Length) chars, $($pe9.Count) errors)"
Ok ((Get-Content -Raw $path) -match "BinSha256 = '[0-9A-F]{64}'" -and (Get-Content -Raw $path) -match "ModelSha1 = '[0-9A-F]{40}'" -and (Get-Content -Raw $path) -match "releases/download/b5454/whisper-bin-x64\.zip") 'the program and the model are pinned to one build and their checksums'
$acs9 = foreach ($sec9 in 2.8, 13.5, 16.5, 40) { [Math]::Max(448, [Math]::Min(1500, [int][Math]::Ceiling($sec9 * 50) + 192)) }
Ok ((Get-Content -Raw $path) -match '\[Math\]::Max\(448, \[Math\]::Min\(1500, \[int\]\[Math\]::Ceiling\(\$long9 \* 50\) \+ 192\)\)' -and ($acs9 -join ',') -eq '448,867,1017,1500' -and (Get-Content -Raw $path) -match "' -bs 1 -bo 1'") "whisper's window follows the length of the recording (2.8 / 13.5 / 16.5 / 40 s -> $($acs9 -join ', ') of 1500), first answer taken"
Ok ((Get-Content -Raw $path) -match "GpuSha256 = '[0-9A-F]{64}'" -and (Get-Content -Raw $path) -match 'whisper-bin-win-cuda-12\.4\.0-x64\.zip' -and $ds9 -match '\$sub') 'the graphics-card program is pinned to the same build with its checksum, and installs in its own folder'
# cutting a recording at its pauses (the real C# from the tray, on made-up sound: tone = speech, near-silence = pause)
$au9 = [regex]::Match((Get-Content -Raw $path), "(?s)\`$DictAudioSrc = @'\r?\n(.*?)\r?\n'@").Groups[1].Value
Add-Type -TypeDefinition ($au9 -replace 'namespace ClaudeTray', 'namespace A9')
Ok ((Get-Content -Raw $path) -match "if \(-not \('ClaudeTray\.Audio' -as \[type\]\)\) \{ Add-Type -TypeDefinition \`$DictAudioSrc \}" -and $au9 -notmatch '\$"|\bout var\b|=>|\?\.') 'the cutting code is compiled at first use, apart from the tray''s own start, and uses no newer C# than Windows PowerShell has'
function Wav9([string]$f, [object[]]$spec) { $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms; $rnd = New-Object Random 7
    foreach ($sp in $spec) { $nn = [int]($sp[0] * 16000); for ($i = 0; $i -lt $nn; $i++) { $v = if ($sp[1]) { [int](9000 * [Math]::Sin($i * 0.05)) } else { $rnd.Next(-30, 30) }; $w.Write([int16]$v) } }
    $pcm = $ms.ToArray(); $fs = [IO.File]::Create($f); $o = New-Object IO.BinaryWriter $fs; $o.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $o.Write([int](36 + $pcm.Length)); $o.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $o.Write([int]16); $o.Write([int16]1); $o.Write([int16]1); $o.Write([int]16000); $o.Write([int]32000); $o.Write([int16]2); $o.Write([int16]16); $o.Write([Text.Encoding]::ASCII.GetBytes('data')); $o.Write([int]$pcm.Length); $o.Write($pcm); $o.Close() }
$wb9 = Join-Path ([IO.Path]::GetTempPath()) ('ct-split9-' + [guid]::NewGuid().ToString('N'))
Wav9 "$wb9.wav" @(@(0.3, $false), @(3.0, $true), @(1.0, $false), @(3.5, $true), @(0.3, $false), @(2.5, $true), @(0.4, $false))
$sp9 = [A9.Audio]::Split("$wb9.wav", $wb9, 0.6, 1.8, 8)
Ok ($sp9.Count -eq 2 -and [Math]::Abs($sp9[0] - 3.8) -lt 0.2 -and [Math]::Abs($sp9[1] - 7.2) -lt 0.2 -and (Test-Path "$wb9-0.wav") -and (Test-Path "$wb9-1.wav") -and -not (Test-Path "$wb9-2.wav")) "speech, a 1 s pause, speech with a short 0.3 s breath: cut once, at the long pause ($(@($sp9 | ForEach-Object { [Math]::Round($_, 2) }) -join ' + ') s)"
Ok (((Get-Item "$wb9-0.wav").Length + (Get-Item "$wb9-1.wav").Length - 88) -eq ((Get-Item "$wb9.wav").Length - 44)) 'the parts hold all of the sound, nothing lost at the cut'
Wav9 "$wb9.wav" @(@(4.0, $true), @(0.9, $false), @(0.8, $true), @(0.9, $false), @(4.0, $true)); $sp9 = [A9.Audio]::Split("$wb9.wav", $wb9, 0.6, 1.8, 8)
Ok ($sp9.Count -eq 2) "a 0.8 s word between two pauses is too short to tell its language: it joins a neighbour ($($sp9.Count) parts)"
Wav9 "$wb9.wav" (, @(6.0, $true)); $sp9 = [A9.Audio]::Split("$wb9.wav", $wb9, 0.6, 1.8, 8); Ok ($sp9.Count -eq 1 -and [Math]::Abs($sp9[0] - 6.0) -lt 0.1) 'no pause: not cut'
Get-ChildItem ([IO.Path]::GetTempPath()) -Filter 'ct-split9-*' | Remove-Item -Force
Ok ((Get-Content -Raw $path) -match '\[ClaudeTray\.Audio\]::Split\(' -and (Get-Content -Raw $path).Contains('-f "{0}-{1}.wav" -of "{0}-{1}"')) 'the tray cuts the recording when the language is detected, and gives the parts to one run of the program'
. ([scriptblock]::Create(@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-DictOn' }, $true))[0].Extent.Text))
function Get-DictExe { Join-Path ([IO.Path]::GetTempPath()) 'ct-none9.exe' }; function Get-DictModel { Join-Path ([IO.Path]::GetTempPath()) 'ct-none9.bin' }
$Cfg.dictation = $null; $o1 = Test-DictOn; $Cfg.dictation = $true; $o2 = Test-DictOn; $Cfg.dictation = $false; $o3 = Test-DictOn
Ok (-not $o1 -and $o2 -and -not $o3) "the option: off on a PC that never had it, on when set, off when set off ($o1 $o2 $o3)"
Ok ((Get-Content -Raw $path) -match "'dict' \{[\s\S]{0,900}Save-CfgKey 'dictation' \`$true[\s\S]{0,200}Start-DictSetup" -and @([regex]::Matches((Get-Content -Raw $path), '(?m)^\s*(if .*)?Start-DictSetup\b|\{ Start-DictSetup')).Count -ge 1 -and (Get-Content -Raw $path) -notmatch 'Click the microphone again to get it') 'the download starts from the Settings entry, not from a click on a microphone'
foreach ($fn9 in 'Invoke-Mic', 'Poll-Dict') { . ([scriptblock]::Create(@($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $fn9 }, $true))[0].Extent.Text)) }
$said9 = New-Object System.Collections.ArrayList; $did9 = New-Object System.Collections.ArrayList; $script:dst9 = 'none'
function Send-PanelDict($st, $id9, $box9, $t9) { [void]$said9.Add("$st|$id9|$box9|$t9") }; function Get-DictState { $script:dst9 }; function Start-DictSetup { [void]$did9.Add('setup') }; function Start-DictRec($a, $b) { [void]$did9.Add("rec $a $b") }; function Stop-DictRec($c) { [void]$did9.Add("stop $c") }
$DictSpec = @{ Mb = 475 }; $DictDir = Join-Path ([IO.Path]::GetTempPath()) 'ctdict9'; $UI.Dict = $null; $UI.DictDl = $null; $UI.DictAsk = $null
function Test-DictOn { $script:don9 }; $script:don9 = $false
Invoke-Mic ([pscustomobject]@{ id = 'chat/a'; box = 'ta' }); Ok ($did9.Count -eq 0 -and $said9.Count -eq 0) 'dictation off (the default): a microphone message does nothing, nothing is downloaded'
$script:don9 = $true; Invoke-Mic ([pscustomobject]@{ id = 'chat/a'; box = 'ta' }); Ok ($did9[-1] -eq 'setup' -and $said9[-1] -like 'msg|||The dictation files are missing*475 MB*') 'on but the files are gone: they are downloaded again, and it says so'
$script:dst9 = 'dl'; Invoke-Mic ([pscustomobject]@{ id = 'chat/a'; box = 'ta' }); Ok ($said9[-1] -like '*still downloading*' -and $did9.Count -eq 1) 'a click during the download only says so'
$script:dst9 = 'ready'; Invoke-Mic ([pscustomobject]@{ id = 'chat/a'; box = 'mi' }); Ok ($did9[-1] -eq 'rec chat/a mi') 'model there: a click starts listening for that box'
$UI.Dict = @{ St = 'rec'; Id = 'chat/a'; Box = 'mi'; At = (Get-Date) }; Invoke-Mic ([pscustomobject]@{ id = 'chat/a'; box = 'mi' }); Ok ($did9[-1] -eq 'stop False') 'a click while it listens: stop and write it down'
Invoke-Mic ([pscustomobject]@{ cancel = $true }); Ok ($did9[-1] -eq 'stop True') 'Esc: the recording is dropped'
$UI.Dict.At = (Get-Date).AddSeconds(-121); Poll-Dict; Ok ($did9[-1] -eq 'stop False') 'after two minutes it stops by itself'
$b9 = Join-Path ([IO.Path]::GetTempPath()) ('ct-dict-test' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText("$b9.txt", " [BLANK_AUDIO] Bonjour  le monde,`n and hello (music) ", [Text.Encoding]::UTF8); [IO.File]::WriteAllText("$b9.wav", 'x')
$UI.Dict = @{ St = 'run'; Id = 'chat/a'; Box = 'ta'; Base = $b9; RunAt = (Get-Date); Secs = 3.2; P = [pscustomobject]@{ HasExited = $true; ExitCode = 0 } }; Poll-Dict
Ok ($said9[-1] -eq 'text|chat/a|ta|Bonjour le monde, and hello' -and -not $UI.Dict -and -not (Test-Path "$b9.txt") -and -not (Test-Path "$b9.wav")) "whisper done: the text goes to the box without whisper's own notes, temporary files are removed ($($said9[-1]))"
function Start-DictRun($d) { [void]$did9.Add("run gpu=$([bool](Test-DictGpu))"); $d.P = [pscustomobject]@{ HasExited = $false; ExitCode = 0 }; $d.Gpu = [bool](Test-DictGpu); $d.RunAt = Get-Date }; function Test-DictGpu { -not $UI.DictGpuBad }; function Push-WebState($f) { }
$UI.DictGpuBad = $false; $UI.Dict = @{ St = 'run'; Id = 'chat/a'; Box = 'ta'; Base = (Join-Path ([IO.Path]::GetTempPath()) 'ct-dict-none9'); RunAt = (Get-Date); Secs = 3.2; Gpu = $true; P = [pscustomobject]@{ HasExited = $true; ExitCode = 3 } }; Poll-Dict
Ok ($UI.DictGpuBad -and $did9[-1] -eq 'run gpu=False' -and $UI.Dict -and $UI.Dict.St -eq 'run' -and $said9[-1] -like 'msg|||The graphics card could not be used*') "the graphics-card program fails: the same sound is written down on the processor, and the card is left alone afterwards ($($did9[-1]))"
$UI.Dict = $null
$b9 = Join-Path ([IO.Path]::GetTempPath()) ('ct-dict-test' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllText("$b9-0.txt", " Bonjour, je teste.`n", [Text.Encoding]::UTF8); [IO.File]::WriteAllText("$b9-1.txt", " And now in English.`n", [Text.Encoding]::UTF8); foreach ($x in '.wav', '-0.wav', '-1.wav') { [IO.File]::WriteAllText("$b9$x", 'x') }
$UI.Dict = @{ St = 'run'; Id = 'chat/a'; Box = 'ta'; Base = $b9; Parts = 2; RunAt = (Get-Date); Secs = 9; Gpu = $false; P = [pscustomobject]@{ HasExited = $true; ExitCode = 0 } }; Poll-Dict
Ok ($said9[-1] -eq 'text|chat/a|ta|Bonjour, je teste. And now in English.' -and -not @(Get-ChildItem ([IO.Path]::GetTempPath()) -Filter ([IO.Path]::GetFileName($b9) + '*')).Count) "two parts: their texts are joined in order and every temporary file is removed ($($said9[-1]))"
New-Item -ItemType Directory -Force -Path $DictDir | Out-Null; [IO.File]::WriteAllText((Join-Path $DictDir 'setup.txt'), 'model 47'); $UI.DictDl = @{ P = [pscustomobject]@{ HasExited = $false }; At = (Get-Date); Said = '' }; Poll-Dict
Ok ($said9[-1] -eq 'msg|||Speech model: 40 %') "download progress is said in steps of 20 % ($($said9[-1]))"
[IO.File]::WriteAllText((Join-Path $DictDir 'setup.txt'), 'err the speech model is not the expected one (checksum)'); Poll-Dict; Ok (-not $UI.DictDl -and $said9[-1] -like 'msg|||Dictation could not be set up: the speech model is not the expected one*') 'a failed check is reported and nothing is kept running'
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
