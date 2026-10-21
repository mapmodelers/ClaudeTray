<#
 ClaudeTray.ps1 - Claude in your Windows tray: plan usage now, your active sessions next.

 Shows, next to the clock, how much of your Claude subscription you have left before the next limit.

 Icon : a thin monochrome ring that fills as you use Claude, with the % used in the middle - for whichever
        limit you're closest to (session or weekly). Matches the light/dark taskbar like the other tray glyphs.
 Hover: a flyout listing every limit (session, week, ...) with % used and when it resets.
 Click: pin the flyout + refresh now.  Double-click: open the Claude app.
 Right-click: menu (refresh, open usage page, open logs, start with Windows, log out, exit).

 Data : your Claude subscription usage, read from api.anthropic.com (the same figures the Claude apps
        show). You log in once with -Login: a browser opens to claude.ai, you approve, and paste back a
        short code. The token is stored locally in oauth.json, encrypted for your Windows account (DPAPI),
        and auto-refreshed; nothing is sent anywhere except Anthropic's own servers. Same OAuth sign-in
        that Claude Code uses. No telemetry.

 Requirements: Windows 10 (1809+) or Windows 11, and a paid Claude plan (Pro / Max / Team). Uses only
        built-in Windows PowerShell 5.1 and .NET - nothing to install, no admin rights.

 The tray runs as its own hidden background process, so you can close the window you launch it from and
 it keeps going; it also starts automatically with Windows once you've logged in.

 Usage (PowerShell or cmd):
   powershell -NoProfile -ExecutionPolicy Bypass -File ClaudeTray.ps1 -Login     log in, then start the tray
   ... (no switch)   start (or restart) the background tray, then exit - safe to close the window
   ... -Install      add Start-menu + Windows-startup shortcuts, then start the tray
   ... -Uninstall    remove those shortcuts and stop the tray
   ... -Logout       delete the stored token and stop the tray
   ... -WebLogin     sign the tray's own browser in to claude.ai (once): chats + usage. Start here.
   ... -Once         one fetch + write logs and preview PNGs, then exit (diagnostic)
   ... -Run          internal: the actual hidden worker that hosts the tray (used by the shortcuts)
   ... -Screens      maintainers: render the README images into docs\ (mock data)

 This is an unofficial, community tool. It is not affiliated with or endorsed by Anthropic, and it relies
 on an endpoint that may change at any time. Log: <folder>\logs\claudetray.log

 MIT licensed - see LICENSE.
#>
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Restart,
    [switch]$Login,
    [switch]$Logout,
    [switch]$WebLogin,
    [switch]$Run,
    [switch]$WaitClaude,                              # with -Run: stay asleep (no icon) until the Claude app opens - the Windows-startup shortcut in "start with Claude" mode
    [switch]$Screens,
    [string]$QuestRoot,
    [string]$Set                                      # -Set key=value : change one setting in config.json
)

$ErrorActionPreference = 'Stop'
$Version = '0.3.4'
$Root    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Script  = $MyInvocation.MyCommand.Path
$LogDir  = Join-Path $Root 'logs'
$LogFile = Join-Path $LogDir 'claudetray.log'
$CfgFile = Join-Path $Root 'config.json'
$AppName = 'ClaudeTray'
$UsageUrl = 'https://claude.ai/settings/usage'
$EN = [Globalization.CultureInfo]::GetCultureInfo('en-US')

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) { Move-Item $LogFile "$LogFile.old" -Force }

function Log([string]$msg, [string]$lvl = 'INFO') {
    if ($lvl -eq 'DEBUG' -and -not $Cfg.debugLog -and -not ($Once -or $Screens)) { return }     # "Debug logs" setting (on: everything I need to analyse a bug)
    $msg = $msg -replace 'sk-ant-[A-Za-z0-9_\-]+', 'sk-ant-***' -replace '(?i)(bearer\s+)\S+', '$1***'
    # logs get shared for support: no Windows user name or profile path in them
    if ($env:USERPROFILE) { $msg = $msg.Replace($env:USERPROFILE, '%USERPROFILE%') }
    if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { $msg = [regex]::Replace($msg, '(?i)(?<![\w])' + [regex]::Escape($env:USERNAME) + '(?![\w])', '<user>') }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $lvl, $msg
    try {
        $script:LogN++; if ($script:LogN % 500 -eq 0 -and (Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 2MB) { Move-Item $LogFile "$LogFile.old" -Force }   # long runs rotate too
        [IO.File]::AppendAllText($LogFile, $line + "`r`n")
    } catch { }
    if ($Once -or $Install -or $Uninstall -or $Login -or $Logout -or $Screens) { Write-Host $line }
}
function Mask([string]$text) {                    # message text in the log only if logMessages is on (default off: logs may be shared for support)
    if (-not $text) { return '' }
    if ($Cfg.logMessages) { $t1 = $text -replace '\s+', ' '; if ($t1.Length -gt 60) { $t1 = $t1.Substring(0, 60) + '...' }; return "'$t1'" }
    return "<$($text.Length) chars>"
}
function Short([string]$text, [int]$n = 300) {
    if (-not $text) { return '' }
    $text = $text -replace '\s+', ' '
    if ($text.Length -gt $n) { return $text.Substring(0, $n) + '...' }
    return $text
}

# ---------------------------------------------------------------- config
$Cfg = @{ pollSeconds = 180; refreshToken = $true; credentialsPath = ''; questRoots = @(); theme = 'auto'; holdWhileWorking = $false; engine = 'auto'; webPort = 0; logMessages = $false; resultChars = 1500; webProfile = ''; screenshots = $false; sideWindows = $false; debugLog = $false; usageAlerts = $true; ui = 'web'; panelWidth = 340; panelZoom = 0.9; webDevTools = $false; terse = $true; compact = $false }
if (Test-Path $CfgFile) {
    try {
        $j = [IO.File]::ReadAllText($CfgFile) | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { $Cfg[$p.Name] = $p.Value }
    } catch { Log "config.json unreadable: $($_.Exception.Message)" 'WARN' }
}
if ([int]$Cfg.pollSeconds -lt 60) { $Cfg.pollSeconds = 60 }
function Save-CfgKey([string]$name, $value) {       # update one key in config.json, keeping the others
    $cfgObj = [ordered]@{}; if (Test-Path $CfgFile) { try { (([IO.File]::ReadAllText($CfgFile)) | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfgObj[$_.Name] = $_.Value } } catch { } }
    $cfgObj[$name] = $value; $Cfg[$name] = $value
    [IO.File]::WriteAllText($CfgFile, (([pscustomobject]$cfgObj) | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
}
if ($Set) {
    $kv = $Set -split '=', 2; if ($kv.Count -ne 2) { Write-Host 'Use -Set key=value'; return }
    $val = switch -Regex ($kv[1]) { '^(true|false)$' { [bool]::Parse($kv[1]) } '^\d+$' { [int]$kv[1] } default { $kv[1] } }
    Save-CfgKey $kv[0].Trim() $val; Write-Host ("{0} = {1} (restart the tray to apply)" -f $kv[0].Trim(), $val); return
}
if ($QuestRoot) {                                   # -QuestRoot <folder>: remember it in config.json and exit
    Save-CfgKey 'questRoots' @([string]$QuestRoot)
    # personal copy of the skill with this folder filled in (skill\tray-personal.zip, git-ignored) - upload that one
    try {
        $src = Join-Path $Root 'skill\tray\SKILL.md'
        if (Test-Path $src) {
            Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
            $md = [IO.File]::ReadAllText($src) -replace '<QUEST_ROOT>', $QuestRoot
            $zip = Join-Path $Root 'skill\tray-personal.zip'; if (Test-Path $zip) { Remove-Item $zip -Force }
            $za = [IO.Compression.ZipFile]::Open($zip, 'Create'); $en = $za.CreateEntry('tray/SKILL.md'); $sw2 = New-Object IO.StreamWriter($en.Open(), (New-Object Text.UTF8Encoding $false)); $sw2.Write($md); $sw2.Dispose(); $za.Dispose()
            Write-Host "Personal skill written: $zip  (upload it in Claude: Settings > Skills)"
        }
    } catch { Write-Host "Could not write the personal skill zip: $($_.Exception.Message)" }
    foreach ($sub in 'quests', 'results') { $d = Join-Path $QuestRoot $sub; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
    Write-Host "Quest root set to $QuestRoot (quests\ and results\ created). Restart the tray to apply."; return
}
$QuestRoots = @(@($Cfg.questRoots) | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables([string]$_) })
if (-not $QuestRoots) { $QuestRoots = @((Join-Path $env:USERPROFILE 'ClaudeTray')) }
$StateFile = Join-Path $Root 'state.json'

# ---------------------------------------------------------------- native (window styling only)
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClaudeTray {
    public static class Native {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
        [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
        [DllImport("user32.dll")] public static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
        [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
        [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
        [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr hProcess, uint flags);
        [DllImport("user32.dll")] public static extern IntPtr FindWindow(string cls, string name);
        [DllImport("user32.dll")] public static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string name);
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
        // sweeps the mouse (virtually) over the notification area so Windows drops icons of dead processes
        public static void RefreshTray() {
            IntPtr tray = FindWindow("Shell_TrayWnd", null); if (tray == IntPtr.Zero) return;
            IntPtr notify = FindWindowEx(tray, IntPtr.Zero, "TrayNotifyWnd", null); if (notify == IntPtr.Zero) return;
            IntPtr pager = FindWindowEx(notify, IntPtr.Zero, "SysPager", null);
            IntPtr bar = pager == IntPtr.Zero ? IntPtr.Zero : FindWindowEx(pager, IntPtr.Zero, "ToolbarWindow32", null);
            IntPtr target = bar == IntPtr.Zero ? notify : bar;
            RECT r; if (!GetWindowRect(target, out r)) return;
            int w = r.R - r.L, h = r.B - r.T;
            for (int y = 2; y < h; y += 6) for (int x = 2; x < w; x += 6) SendMessage(target, 0x0200, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF)));
            IntPtr ovf = FindWindow("NotifyIconOverflowWindow", null);
            if (ovf != IntPtr.Zero) { IntPtr ob = FindWindowEx(ovf, IntPtr.Zero, "ToolbarWindow32", null); if (ob != IntPtr.Zero && GetWindowRect(ob, out r)) { w = r.R - r.L; h = r.B - r.T; for (int y = 2; y < h; y += 6) for (int x = 2; x < w; x += 6) SendMessage(ob, 0x0200, IntPtr.Zero, (IntPtr)((y << 16) | (x & 0xFFFF))); } }
        }
    }
}
'@
Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Security
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System; using System.Drawing; using System.Runtime.InteropServices; using System.Windows.Forms;
namespace ClaudeTray {
    public class WheelToHover : IMessageFilter {          // wheel goes to the box under the cursor; at its top/bottom it scrolls the panel instead
        [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point p);
        [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        public static IntPtr TopHit = IntPtr.Zero;            // a text box was wheeled up while already at its top (-> load earlier messages)
        static readonly uint Me = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
        public bool PreFilterMessage(ref Message m) {
            if (m.Msg != 0x020A) return false;
            IntPtr h = WindowFromPoint(Cursor.Position);
            if (h == IntPtr.Zero) return false;
            uint pid; GetWindowThreadProcessId(h, out pid);
            if (pid != Me) return false;
            int delta = (short)(((long)m.WParam >> 16) & 0xFFFF);
            Control c = Control.FromHandle(h);
            while (c != null) {
                TextBoxBase tb = c as TextBoxBase;
                if (tb != null && tb.IsHandleCreated) {
                    int total = (int)SendMessage(tb.Handle, 0xBA, IntPtr.Zero, IntPtr.Zero);
                    int first = (int)SendMessage(tb.Handle, 0xCE, IntPtr.Zero, IntPtr.Zero);
                    int vis = Math.Max(1, tb.ClientSize.Height / Math.Max(1, tb.Font.Height));
                    bool can = delta > 0 ? first > 0 : first + vis < total;
                    // EM_LINESCROLL: works without a visible scrollbar (WM_MOUSEWHEEL is ignored then)
                    if (can) { int lines = -Math.Sign(delta) * 3 * Math.Max(1, Math.Abs(delta) / 120); SendMessage(tb.Handle, 0x00B6, IntPtr.Zero, (IntPtr)lines); tb.Invalidate(); return true; }
                    if (delta > 0) TopHit = tb.Handle;
                }
                ScrollableControl sc = c as ScrollableControl;
                if (sc != null && sc.AutoScroll && sc.DisplayRectangle.Height > sc.ClientSize.Height + 2) {
                    int y = -sc.AutoScrollPosition.Y;
                    int step = Math.Max(24, sc.ClientSize.Height / 6) * Math.Max(1, Math.Abs(delta) / 120);
                    int max = sc.DisplayRectangle.Height - sc.ClientSize.Height;
                    int ny = Math.Max(0, Math.Min(max, y - Math.Sign(delta) * step));
                    if (ny != y) { sc.AutoScrollPosition = new Point(0, ny); return true; }
                }
                c = c.Parent;
            }
            return true;
        }
    }
    public static class Scroll { [DllImport("user32.dll")] public static extern bool ShowScrollBar(IntPtr h, int bar, bool show); }
}
'@
try { [void][ClaudeTray.Native]::SetProcessDPIAware() } catch { }
$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $k = $g0.DpiX / 96.0; $g0.Dispose()
function px([double]$v) { return [int][Math]::Round($v * $k) }
# ---------------------------------------------------------------- icon set: drawn with GDI+, one stroke weight, cached per name/colour/size
$Gly = @{}; foreach ($gn in 'app', 'web', 'bell', 'belloff', 'x', 'run', 'copy', 'dir', 'ok', 'pin', 'unpin', 'send', 'bot', 'cmd', 'file', 'eye', 'hand', 'key', 'spin', 'down', 'up', 'boxok', 'skip', 'stop', 'gear', 'chat', 'full') { $Gly[$gn] = $gn }; $Gly['url'] = 'web'
$IconCache = @{}
function Get-IconBmp([string]$name, [System.Drawing.Color]$color, [int]$sz) {
    $ck = "$name|$($color.ToArgb())|$sz"
    if ($IconCache.ContainsKey($ck)) { return $IconCache[$ck] }
    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $bmp.SetResolution([single](96 * $k), [single](96 * $k))          # else WinForms scales the image by the DPI ratio and clips it
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $sw = [single][Math]::Max(1.3, $sz * 0.09); $pad = [single]($sw); $box = [single]($sz - 2 * $pad)
    $pen = New-Object System.Drawing.Pen ($color, $sw); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $br = New-Object System.Drawing.SolidBrush $color
    function pt([double]$x, [double]$y) { return New-Object System.Drawing.PointF ([single]($pad + $x * $box)), ([single]($pad + $y * $box)) }
    function rc([double]$x, [double]$y, [double]$w, [double]$h) { return New-Object System.Drawing.RectangleF ([single]($pad + $x * $box)), ([single]($pad + $y * $box)), ([single]($w * $box)), ([single]($h * $box)) }
    function ln { param([double[]]$c) $pts = @(); for ($i = 0; $i -lt $c.Count; $i += 2) { $pts += pt $c[$i] $c[$i + 1] }; $g.DrawLines($pen, [System.Drawing.PointF[]]$pts) }
    function poly { param([double[]]$c) $pts = @(); for ($i = 0; $i -lt $c.Count; $i += 2) { $pts += pt $c[$i] $c[$i + 1] }; $g.DrawPolygon($pen, [System.Drawing.PointF[]]$pts) }
    function fpoly { param([double[]]$c) $pts = @(); for ($i = 0; $i -lt $c.Count; $i += 2) { $pts += pt $c[$i] $c[$i + 1] }; $g.FillPolygon($br, [System.Drawing.PointF[]]$pts) }
    function slash { ln 0.12, 0.12, 0.88, 0.88 }
    switch ($name) {
        'app'     { ln 0.55, 0.14, 0.14, 0.14, 0.14, 0.86, 0.86, 0.86, 0.86, 0.45; ln 0.45, 0.55, 0.88, 0.12; ln 0.58, 0.12, 0.88, 0.12, 0.88, 0.42 }
        'web'     { $g.DrawEllipse($pen, (rc 0.08 0.08 0.84 0.84)); $g.DrawEllipse($pen, (rc 0.33 0.08 0.34 0.84)); ln 0.08, 0.5, 0.92, 0.5 }
        { $_ -in 'bell', 'belloff' } { $g.DrawArc($pen, (rc 0.2 0.1 0.6 0.6), [single]180, [single]180); ln 0.2, 0.4, 0.2, 0.62, 0.08, 0.78, 0.92, 0.78, 0.8, 0.62, 0.8, 0.4; $g.DrawArc($pen, (rc 0.38 0.74 0.24 0.2), [single]0, [single]180); if ($name -eq 'belloff') { slash } }
        'gear'    { $g.DrawEllipse($pen, (rc 0.34 0.34 0.32 0.32)); for ($ti = 0; $ti -lt 8; $ti++) { $an = $ti * [Math]::PI / 4; ln (0.5 + 0.27 * [Math]::Cos($an)), (0.5 + 0.27 * [Math]::Sin($an)), (0.5 + 0.43 * [Math]::Cos($an)), (0.5 + 0.43 * [Math]::Sin($an)) }; $g.DrawEllipse($pen, (rc 0.2 0.2 0.6 0.6)) }
        'x'       { ln 0.22, 0.22, 0.78, 0.78; ln 0.78, 0.22, 0.22, 0.78 }
        'run'     { fpoly 0.28, 0.14, 0.86, 0.5, 0.28, 0.86 }
        'copy'    { poly 0.34, 0.34, 0.88, 0.34, 0.88, 0.88, 0.34, 0.88; ln 0.22, 0.66, 0.12, 0.66, 0.12, 0.12, 0.66, 0.12, 0.66, 0.22 }
        'dir'     { poly 0.1, 0.22, 0.4, 0.22, 0.5, 0.34, 0.9, 0.34, 0.9, 0.82, 0.1, 0.82 }
        'ok'      { ln 0.15, 0.52, 0.4, 0.78, 0.86, 0.24 }
        { $_ -in 'pin', 'unpin' } { ln 0.32, 0.1, 0.68, 0.1; ln 0.4, 0.1, 0.4, 0.44, 0.2, 0.6, 0.8, 0.6, 0.6, 0.44, 0.6, 0.1; ln 0.5, 0.6, 0.5, 0.92; if ($name -eq 'unpin') { slash } }
        'send'    { poly 0.1, 0.5, 0.9, 0.12, 0.62, 0.9, 0.48, 0.56; ln 0.48, 0.56, 0.9, 0.12 }
        'bot'     { $g.DrawRectangle($pen, [single]($pad + 0.14 * $box), [single]($pad + 0.34 * $box), [single](0.72 * $box), [single](0.54 * $box)); $g.FillEllipse($br, (rc 0.3 0.52 0.14 0.14)); $g.FillEllipse($br, (rc 0.56 0.52 0.14 0.14)); ln 0.5, 0.34, 0.5, 0.16; $g.FillEllipse($br, (rc 0.43 0.06 0.14 0.14)) }
        'cmd'     { $g.DrawRectangle($pen, [single]($pad + 0.1 * $box), [single]($pad + 0.18 * $box), [single](0.8 * $box), [single](0.64 * $box)); ln 0.25, 0.38, 0.4, 0.5, 0.25, 0.62; ln 0.5, 0.64, 0.72, 0.64 }
        'file'    { ln 0.6, 0.1, 0.2, 0.1, 0.2, 0.9, 0.8, 0.9, 0.8, 0.3, 0.6, 0.1, 0.6, 0.3, 0.8, 0.3 }
        'eye'     { $g.DrawBezier($pen, (pt 0.06 0.5), (pt 0.3 0.14), (pt 0.7 0.14), (pt 0.94 0.5)); $g.DrawBezier($pen, (pt 0.06 0.5), (pt 0.3 0.86), (pt 0.7 0.86), (pt 0.94 0.5)); $g.FillEllipse($br, (rc 0.37 0.37 0.26 0.26)) }
        'hand'    { $pth = New-RoundPath ($pad + 0.1 * $box) ($pad + 0.1 * $box) (0.8 * $box) (0.8 * $box) (0.2 * $box); $g.DrawPath($pen, $pth); $pth.Dispose() }
        'key'     { poly 0.5, 0.08, 0.86, 0.22, 0.82, 0.56, 0.5, 0.92, 0.18, 0.56, 0.14, 0.22 }
        'spin'    { $g.DrawArc($pen, (rc 0.14 0.14 0.72 0.72), [single]-90, [single]270) }
        'down'    { ln 0.2, 0.36, 0.5, 0.66, 0.8, 0.36 }
        'boxok'   { $pth = New-RoundPath ($pad + 0.08 * $box) ($pad + 0.08 * $box) (0.84 * $box) (0.84 * $box) (0.2 * $box); $g.FillPath($br, $pth); $pth.Dispose(); $wp = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, $sw); $wp.StartCap = 'Round'; $wp.EndCap = 'Round'; $wp.LineJoin = 'Round'; $g.DrawLines($wp, [System.Drawing.PointF[]]@((pt 0.26 0.52), (pt 0.44 0.7), (pt 0.76 0.32))); $wp.Dispose() }
        'skip'    { $g.DrawEllipse($pen, (rc 0.12 0.12 0.76 0.76)); ln 0.26, 0.74, 0.74, 0.26 }
        'chat'    { $pth = New-RoundPath ($pad + 0.08 * $box) ($pad + 0.12 * $box) (0.84 * $box) (0.6 * $box) (0.18 * $box); $g.DrawPath($pen, $pth); $pth.Dispose(); ln 0.3, 0.72, 0.24, 0.92, 0.46, 0.72 }
        'full'    { $g.DrawRectangle($pen, [single]($pad + 0.08 * $box), [single]($pad + 0.14 * $box), [single](0.84 * $box), [single](0.72 * $box)); ln 0.56, 0.14, 0.56, 0.86; ln 0.66, 0.36, 0.84, 0.36; ln 0.66, 0.52, 0.84, 0.52; ln 0.66, 0.68, 0.8, 0.68 }
        'stop'    { $pth = New-RoundPath ($pad + 0.2 * $box) ($pad + 0.2 * $box) (0.6 * $box) (0.6 * $box) (0.12 * $box); $g.FillPath($br, $pth); $pth.Dispose() }
        'up'      { ln 0.2, 0.64, 0.5, 0.34, 0.8, 0.64 }
    }
    $pen.Dispose(); $br.Dispose(); $g.Dispose()
    $IconCache[$ck] = $bmp
    return $bmp
}

$LightTaskbar = $false
try { $LightTaskbar = ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction Stop).SystemUsesLightTheme -eq 1) } catch { }

# ---------------------------------------------------------------- state
$S = @{ Limits = @(); Error = ''; Updated = $null; Source = ''; Plan = ''; Backoff = 1 }

# ---------------------------------------------------------------- http
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'ClaudeTray/' + $Version

function Invoke-Http([string]$Method, [string]$Url, [hashtable]$Headers, [string]$Body) {
    $req = [Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.Timeout = 15000
    $req.ReadWriteTimeout = 15000
    $req.Accept = 'application/json'
    $req.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate
    foreach ($key in $Headers.Keys) {
        if ($key -eq 'User-Agent') { $req.UserAgent = $Headers[$key] }
        elseif ($key -eq 'Content-Type') { $req.ContentType = $Headers[$key] }
        elseif ($key -eq 'Accept') { $req.Accept = $Headers[$key] }
        else { $req.Headers[$key] = $Headers[$key] }
    }
    $resp = $null
    try {
        if ($Body) {
            $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
            if (-not $req.ContentType) { $req.ContentType = 'application/json' }
            $req.ContentLength = $bytes.Length
            $st = $req.GetRequestStream(); $st.Write($bytes, 0, $bytes.Length); $st.Close()
        }
        $resp = $req.GetResponse()
    } catch {
        $ex = $_.Exception
        while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
        if ($ex -and $ex.Response) { $resp = $ex.Response }
        else { return @{ Code = 0; Body = $_.Exception.Message } }
    }
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        $txt = $sr.ReadToEnd(); $sr.Close()
        return @{ Code = [int]$resp.StatusCode; Body = $txt }
    } finally { $resp.Close() }
}

# ---------------------------------------------------------------- OAuth login (same flow as Claude Code)
$ClientId     = '9d1c250a-e61b-44d9-88ed-5944d1962f5e'
$TokenUrls    = @('https://platform.claude.com/v1/oauth/token', 'https://console.anthropic.com/v1/oauth/token')
$OAuthFile    = Join-Path $Root 'oauth.json'
$RedirectUri  = 'https://console.anthropic.com/oauth/code/callback'
$OAuthScope   = 'org:create_api_key user:profile user:inference'
$UsageApi     = 'https://api.anthropic.com/api/oauth/usage'

function Get-CredPath {
    if ($Cfg.credentialsPath) { return [string]$Cfg.credentialsPath }
    if (Test-Path $OAuthFile) { return $OAuthFile }
    $dir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
    return (Join-Path $dir '.credentials.json')      # also works with an existing Claude Code login
}
# Our own token file is encrypted with Windows DPAPI (current user): copied to another account or
# machine - or synced to a cloud folder - it is useless. A Claude Code credentials file is read as-is
# and never written to (refreshing it would rotate Claude Code's own refresh token).
$Entropy = [Text.Encoding]::UTF8.GetBytes('ClaudeTray')
function Read-Creds {
    $p = Get-CredPath
    if (-not (Test-Path $p)) { return $null }
    $j = [IO.File]::ReadAllText($p) | ConvertFrom-Json
    if ($j.format -eq 'dpapi') {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String([string]$j.data), $Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return ([Text.Encoding]::UTF8.GetString($plain) | ConvertFrom-Json)
    }
    return $j
}
function Write-OAuth($j) {
    $enc = [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes(($j | ConvertTo-Json -Depth 20 -Compress)), $Entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllText($OAuthFile, (@{ format = 'dpapi'; data = [Convert]::ToBase64String($enc) } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
}
function NowMs { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function MsToLocal($ms) { return [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime.ToString('yyyy-MM-dd HH:mm') }
function B64Url([byte[]]$b) { return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }

function Invoke-Login {
    $rng = New-Object byte[] 32; ([Security.Cryptography.RNGCryptoServiceProvider]::new()).GetBytes($rng)
    $verifier = B64Url $rng
    $challenge = B64Url ([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::ASCII.GetBytes($verifier)))
    $rs = New-Object byte[] 24; ([Security.Cryptography.RNGCryptoServiceProvider]::new()).GetBytes($rs)
    $state = B64Url $rs                          # the verifier stays secret: only its hash goes in the URL
    $p = [ordered]@{ code = 'true'; client_id = $ClientId; response_type = 'code'; redirect_uri = $RedirectUri; scope = $OAuthScope; code_challenge = $challenge; code_challenge_method = 'S256'; state = $state }
    $qstr = ($p.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join '&'
    $url = "https://claude.ai/oauth/authorize?$qstr"
    Write-Host ''
    Write-Host 'A browser is opening so you can log in to your Claude account and authorize this app.'
    Write-Host 'After you approve, the page shows a short code. Copy it and paste it below.'
    Write-Host ''
    Write-Host "If no browser opens, open this URL manually:`n$url`n"
    try { Start-Process $url } catch { Log "Start-Process authorize: $($_.Exception.Message)" 'WARN' }
    $pasted = (Read-Host 'Paste the code').Trim().Trim('"')
    if (-not $pasted) { Write-Host 'Nothing entered - aborted.'; return $false }
    $code = $pasted; $st = $state
    if ($pasted -match '#') {
        $parts = $pasted.Split('#', 2); $code = $parts[0]; $st = $parts[1]
        if ($st -ne $state) { Log 'Login: state mismatch - code not from this login attempt' 'WARN'; Write-Host 'That code belongs to a different login attempt. Run -Login again and paste the new code.'; return $false }
    }
    $body = @{ grant_type = 'authorization_code'; code = $code; state = $st; client_id = $ClientId; redirect_uri = $RedirectUri; code_verifier = $verifier } | ConvertTo-Json -Compress
    foreach ($u in $TokenUrls) {
        $r = Invoke-Http 'POST' $u @{ 'Content-Type' = 'application/json'; 'User-Agent' = $UA } $body
        Log "Login token exchange $u -> HTTP $($r.Code)"
        if ($r.Code -eq 200) {
            $tok = $r.Body | ConvertFrom-Json
            if (-not $tok.access_token) { Log "Login: no access_token (keys: $(($tok.PSObject.Properties.Name) -join ','))" 'WARN'; continue }
            $o = [ordered]@{ accessToken = [string]$tok.access_token; refreshToken = [string]$tok.refresh_token; expiresAt = [int64]((NowMs) + [int64]$(if ($tok.expires_in) { $tok.expires_in } else { 3600 }) * 1000); scopes = @(([string]$tok.scope) -split ' '); subscriptionType = '' }
            Write-OAuth @{ claudeAiOauth = $o }
            Log "Login OK; token saved (DPAPI-encrypted) to $OAuthFile; expires $(MsToLocal $o.expiresAt); scopes $($o.scopes -join ',')"
            return $true
        }
        Log "Login token reply: $(Short $r.Body)" 'WARN'
    }
    Write-Host 'Login failed - the code may have expired or been mistyped. Run -Login again.'
    return $false
}

function Update-Token {
    $p = Get-CredPath
    if ($p -ne $OAuthFile) { Log "Token comes from another app ($p) - read-only, not refreshing; run -Login to get this app's own login" 'WARN'; return $false }
    $j = Read-Creds
    $o = $j.claudeAiOauth
    if (-not $o.refreshToken) { Log 'No refreshToken in token file' 'WARN'; return $false }
    $body = @{ grant_type = 'refresh_token'; refresh_token = [string]$o.refreshToken; client_id = $ClientId } | ConvertTo-Json -Compress
    foreach ($u in $TokenUrls) {
        $r = Invoke-Http 'POST' $u @{ 'Content-Type' = 'application/json'; 'User-Agent' = $UA } $body
        Log "Token refresh $u -> HTTP $($r.Code)"
        if ($r.Code -eq 200) {
            $tok = $r.Body | ConvertFrom-Json
            if (-not $tok.access_token) { Log "Token refresh: no access_token (keys: $(($tok.PSObject.Properties.Name) -join ','))" 'WARN'; continue }
            $o | Add-Member -NotePropertyName accessToken -NotePropertyValue ([string]$tok.access_token) -Force
            if ($tok.refresh_token) { $o | Add-Member -NotePropertyName refreshToken -NotePropertyValue ([string]$tok.refresh_token) -Force }
            if ($tok.expires_in) { $o | Add-Member -NotePropertyName expiresAt -NotePropertyValue ([int64]((NowMs) + [int64]$tok.expires_in * 1000)) -Force }
            Write-OAuth $j
            Log "Token refreshed; expires $(MsToLocal $o.expiresAt)"
            return $true
        }
        Log "Token refresh reply: $(Short $r.Body)" 'WARN'
    }
    return $false
}

function Invoke-OAuthUsage([string]$tok) {
    return (Invoke-Http 'GET' $UsageApi @{ 'Authorization' = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20'; 'User-Agent' = $UA } $null)
}
function Get-UsageOAuth {
    $j = Read-Creds
    if (-not $j -or -not $j.claudeAiOauth -or -not $j.claudeAiOauth.accessToken) { throw "Not logged in - run -Login" }
    $o = $j.claudeAiOauth
    if ($o.subscriptionType) { $S.Plan = [string]$o.subscriptionType }
    $exp = 0; if ($o.expiresAt) { $exp = [int64]$o.expiresAt }
    Log ("Token: len={0} expires={1} scopes={2}" -f ([string]$o.accessToken).Length, $(if ($exp) { MsToLocal $exp } else { '?' }), (@($o.scopes) -join ','))
    $tok = [string]$o.accessToken
    if ($exp -and $exp -lt (NowMs) + 60000) {
        Log 'Access token near expiry, refreshing' 'INFO'
        if ($Cfg.refreshToken -and (Update-Token)) { $tok = [string](Read-Creds).claudeAiOauth.accessToken }
    }
    $r = Invoke-OAuthUsage $tok
    if ($r.Code -eq 401 -and $Cfg.refreshToken) {
        Log "Usage 401, refreshing token" 'WARN'
        if (Update-Token) { $r = Invoke-OAuthUsage ([string](Read-Creds).claudeAiOauth.accessToken) }
    }
    return $r
}

# ---------------------------------------------------------------- parse
$Labels = [ordered]@{
    five_hour = 'Session (5 h)'; seven_day = 'Week - all models'; seven_day_opus = 'Week - Opus'
    seven_day_sonnet = 'Week - Sonnet'; seven_day_oauth_apps = 'Week - apps'; extra_usage = 'Extra usage'
}
function ConvertTo-Limits($j) {
    $out = @()
    $keys = @($Labels.Keys)
    foreach ($p in $j.PSObject.Properties) {
        $v = $p.Value
        if (-not ($v -is [System.Management.Automation.PSCustomObject])) { continue }
        $names = @($v.PSObject.Properties.Name)
        if ($names -notcontains 'utilization' -or $null -eq $v.utilization) { continue }
        if ($names -contains 'is_enabled' -and -not $v.is_enabled) { continue }
        $reset = $null
        if ($v.resets_at) {
            if ($v.resets_at -is [datetime]) { $reset = $v.resets_at.ToLocalTime() }
            else { try { $reset = [DateTimeOffset]::Parse([string]$v.resets_at, $EN).LocalDateTime } catch { } }
        }
        $label = if ($Labels.Contains($p.Name)) { $Labels[$p.Name] } else { (Get-Culture).TextInfo.ToTitleCase(($p.Name -replace '_', ' ')) }
        $ord = [array]::IndexOf($keys, $p.Name); if ($ord -lt 0) { $ord = 99 }
        $out += [pscustomobject]@{ Key = $p.Name; Label = $label; Used = [double]$v.utilization; Reset = $reset; Order = $ord }
    }
    return @($out | Sort-Object Order)
}
function Get-Limit([string]$key) { return ($S.Limits | Where-Object { $_.Key -eq $key } | Select-Object -First 1) }

# ---------------------------------------------------------------- fetch
function Update-Usage {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        # first choice: claude.ai's own usage, read by the tray's signed-in browser (no extra sign-in, no borrowed client)
        $wu = if ($webEnabled -and $Web) { $Web.Usage } else { $null }
        if ($wu -and $wu.Code -eq 200 -and $wu.Body -and ((Get-Date) - $wu.At).TotalMinutes -lt 8) {
            $lim0 = @(ConvertTo-Limits ($wu.Body | ConvertFrom-Json))
            if ($lim0.Count) {
                $S.Source = 'claude.ai'; $S.Limits = $lim0; $S.Error = ''; $S.Updated = $wu.At; $S.Backoff = 1
                [IO.File]::WriteAllText((Join-Path $LogDir 'last_usage.json'), $wu.Body)
                Log ('Usage via claude.ai: ' + (($S.Limits | ForEach-Object { '{0}={1}%' -f $_.Key, $_.Used }) -join '  '))
                return
            }
            Log "usage via claude.ai: no limits in the reply ($(Short $wu.Body 300))" 'WARN'
        }
        $cp = Get-CredPath
        if (-not (Test-Path $cp) -and $webEnabled) { $S.Source = 'claude.ai'; if (-not @($S.Limits).Count) { $S.Error = $(if ($wu -and [int]$wu.Code -eq 403) { 'usage: claude.ai wants a browser check - Settings > Open claude.ai in the tray browser' } else { 'usage: waiting for claude.ai' }) }; return }     # say why (Cloudflare check)      # the browser brings it on its next pass
        if (-not (Test-Path $cp)) { $S.Source = 'not logged in'; throw 'Not logged in - run -Login' }
        $S.Source = 'OAuth'
        $r = Get-UsageOAuth
        Log ("Usage -> HTTP {0} in {1} ms" -f $r.Code, $sw.ElapsedMilliseconds)
        if ($r.Code -eq 200) {
            [IO.File]::WriteAllText((Join-Path $LogDir 'last_usage.json'), $r.Body)
            $S.Limits = @(ConvertTo-Limits ($r.Body | ConvertFrom-Json))
            $S.Error = ''; $S.Updated = Get-Date; $S.Backoff = 1
            Log ('Parsed: ' + (($S.Limits | ForEach-Object { '{0}={1}%@{2}' -f $_.Key, $_.Used, $(if ($_.Reset) { $_.Reset.ToString('ddd HH:mm', $EN) } else { '-' }) }) -join '  '))
            if ($S.Limits.Count -eq 0) { $S.Error = 'No usage limits in reply'; Log "Raw: $(Short $r.Body 800)" 'WARN' }
        } else {
            switch ($r.Code) {
                0       { $S.Error = "Network error: $($r.Body)" }
                401     { $S.Error = 'Login expired - run -Login again' }
                403     { $S.Error = 'Access refused (HTTP 403)' }
                429     { $S.Error = 'Rate limited - slowing down'; $S.Backoff = [Math]::Min($S.Backoff * 2, 5) }
                default { $S.Error = "HTTP $($r.Code)" }
            }
            Log "Usage error reply: $(Short $r.Body)" 'WARN'
        }
    } catch {
        $S.Error = Short $_.Exception.Message 160
        Log ("FAIL: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR'
    }
}

# ---------------------------------------------------------------- drawing helpers
function C([int]$r, [int]$g, [int]$b, [int]$a = 255) { return [System.Drawing.Color]::FromArgb($a, $r, $g, $b) }
function Lerp([int]$a, [int]$b, [double]$frac) { return [int][Math]::Round($a + ($b - $a) * $frac) }
function Blend([System.Drawing.Color]$ca, [System.Drawing.Color]$cb, [double]$f) { return [System.Drawing.Color]::FromArgb(255, (Lerp $ca.R $cb.R $f), (Lerp $ca.G $cb.G $f), (Lerp $ca.B $cb.B $f)) }
function Fill([System.Drawing.Graphics]$g, [System.Drawing.Color]$c, [int]$x, [int]$y, [int]$w, [int]$h) {
    if ($w -le 0 -or $h -le 0) { return }
    $br = New-Object System.Drawing.SolidBrush $c; $g.FillRectangle($br, $x, $y, $w, $h); $br.Dispose()
}
function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $d = [single][Math]::Min(2 * $r, [Math]::Min($w, $h))
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($d -le 0.5) { $p.AddRectangle((New-Object System.Drawing.RectangleF $x, $y, $w, $h)); return , $p }
    $p.AddArc($x, $y, $d, $d, [single]180, [single]90)
    $p.AddArc([single]($x + $w - $d), $y, $d, $d, [single]270, [single]90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), $d, $d, [single]0, [single]90)
    $p.AddArc($x, [single]($y + $h - $d), $d, $d, [single]90, [single]90)
    $p.CloseFigure()
    return , $p
}
function Fill-Round([System.Drawing.Graphics]$g, [System.Drawing.Color]$c, [single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    if ($w -le 0 -or $h -le 0) { return }
    $p = New-RoundPath $x $y $w $h $r
    $br = New-Object System.Drawing.SolidBrush $c; $g.FillPath($br, $p); $br.Dispose(); $p.Dispose()
}
# Windows accent colour (Settings > Colours), used for the flyout bars so it matches the system
$Accent = C 0 120 215
try {
    $av = [int64](Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor -band 0xFFFFFFFF
    $Accent = C ([int]($av -band 0xFF)) ([int](($av -shr 8) -band 0xFF)) ([int](($av -shr 16) -band 0xFF))
} catch { }
# flyout bar colour: accent normally, amber / red as a limit fills up
function BarColor([double]$used) {
    if ($used -ge 90) { return (C 214 64 58) }
    if ($used -ge 75) { return (C 222 150 30) }
    return $Accent
}
# digits font for the icon: a condensed face reads best at tray sizes (Bahnschrift ships with Windows 10 1709+)
$NumFont = $null
$famNames = @([System.Drawing.FontFamily]::Families | ForEach-Object { $_.Name })
foreach ($fn in @('Bahnschrift SemiBold SemiConden', 'Bahnschrift SemiBold', 'Bahnschrift', 'Segoe UI Semibold', 'Segoe UI', 'Arial')) {
    if ($famNames -contains $fn) { $NumFont = $fn; break }
}
function New-NumFont([single]$em) {
    foreach ($st in @([System.Drawing.FontStyle]::Bold, [System.Drawing.FontStyle]::Regular)) {
        if ($st -eq [System.Drawing.FontStyle]::Bold -and $NumFont -match 'Semi[Bb]old') { continue }
        try { return (New-Object System.Drawing.Font($NumFont, $em, $st, [System.Drawing.GraphicsUnit]::Pixel)) } catch { }
    }
    return (New-Object System.Drawing.Font('Arial', $em, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel))
}

# ---------------------------------------------------------------- tray icon: monochrome ring gauge
# A thin ring whose arc fills clockwise from the top with the % USED of the limit you're closest to,
# with that number in the middle (from 20 px up). Theme-coloured like the other tray glyphs.
# $used = % used (0-100+), or $null for no data. $err = show the "no reading" state.
function New-TrayIcon([int]$isz, $used, [bool]$err, [bool]$light, [string]$badge = '', [int]$phase = 0, $flags = $null) {
    $bmp = New-Object System.Drawing.Bitmap $isz, $isz, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $fg = if ($light) { C 24 24 24 } else { C 245 245 245 }
    $track = [System.Drawing.Color]::FromArgb($(if ($light) { 64 } else { 80 }), $fg)
    $w = [single][Math]::Max(1.6, $isz * 0.12)
    $m = [single]($w / 2 + [Math]::Max(0.5, $isz * 0.03))
    $rect = New-Object System.Drawing.RectangleF $m, $m, ([single]($isz - 2 * $m)), ([single]($isz - 2 * $m))
    # state (see docs/DESIGN.md "Tray icon"): needs you > working > unread reply > idle; the number (usage) always stays
    if (-not $flags) { $flags = @{ Ask = ($badge -eq 'ask'); Needs = ($badge -eq 'act' -or $badge -eq 'ask'); Working = ($badge -eq 'working'); Unread = ($badge -eq 'done') } }
    $cBlue = C 78 150 230; $cOrange = C 232 128 90; $cPurple = C 150 120 230
    if ($flags.Needs -and -not $err) { $track = [System.Drawing.Color]::FromArgb(200, $cBlue) }        # needs you: blue ring (still)
    $pt = New-Object System.Drawing.Pen ($track, $w); $g.DrawEllipse($pt, $rect); $pt.Dispose()
    $show = (-not $err) -and ($null -ne $used)
    if ($show -and [double]$used -gt 0) {
        $u = [Math]::Min(100.0, [double]$used)
        $ucol = if ($u -ge 95) { C 230 80 70 } elseif ($u -ge 80) { $cOrange } else { $fg }
        $pa = New-Object System.Drawing.Pen ($ucol, $w)
        if ($u -lt 100) { $pa.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pa.EndCap = [System.Drawing.Drawing2D.LineCap]::Round }
        $g.DrawArc($pa, $rect, [single]-90, [single](360 * $u / 100.0)); $pa.Dispose()
    }
    if ($show -and $isz -ge 20) {
        $txt = if ([double]$used -ge 100) { '!' } else { [string][int][Math]::Round([double]$used) }
        $inner = [single]($isz - 2 * ($m + $w))
        $sf = [System.Drawing.StringFormat]::GenericTypographic
        $em = [single][Math]::Max(5, $inner * 0.92)
        $f = New-NumFont $em
        while ($em -gt 5) {
            $sz = $g.MeasureString($txt, $f, [System.Drawing.PointF]::Empty, $sf)
            if ($sz.Width -le $inner * 0.94 -and ($em * 0.70) -le $inner * 0.66) { break }
            $f.Dispose(); $em = [single]($em - 0.5); $f = New-NumFont $em
        }
        $sz = $g.MeasureString($txt, $f, [System.Drawing.PointF]::Empty, $sf)
        $fam = $f.FontFamily; $st = $f.Style
        $ascent = $em * $fam.GetCellAscent($st) / $fam.GetEmHeight($st)
        $capH = $em * 0.70
        $x = [single](($isz - $sz.Width) / 2)
        $y = [single](($isz + $capH) / 2 - $ascent)
        $tb = New-Object System.Drawing.SolidBrush $fg
        $g.DrawString($txt, $f, $tb, $x, $y, $sf); $tb.Dispose(); $f.Dispose()
    } elseif (-not $show) {
        $pd = New-Object System.Drawing.Pen ($fg, $w)
        $pd.StartCap = [System.Drawing.Drawing2D.LineCap]::Round; $pd.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $g.DrawLine($pd, [single]($isz * 0.36), [single]($isz / 2), [single]($isz * 0.64), [single]($isz / 2)); $pd.Dispose()
    }
    $bd = [single][Math]::Max(6, $isz * 0.42)           # top-right badge: the most urgent state (small enough to keep the number readable)
    $bx = [single]($isz - $bd); $by = [single]0
    if (-not $err -and ($flags.Working -or $flags.Needs -or $flags.Unread -or $flags.Ask)) {
        $hb = New-Object System.Drawing.SolidBrush ($(if ($light) { C 250 250 250 } else { C 22 22 22 }))
        $g.FillEllipse($hb, [single]($bx - 1), [single]($by - 1), [single]($bd + 2), [single]($bd + 2)); $hb.Dispose()
    }
    if ($flags.Working -and -not $err) {             # Claude working: 2x2 dots, one lit, going round TL > TR > BR > BL (big, high contrast)
        $r0 = [single]($bd * 0.21); $o0 = [single]($bd * 0.25); $cx = $bx + $bd / 2; $cy = $by + $bd / 2
        $pos = @(@(-1, -1), @(1, -1), @(1, 1), @(-1, 1)); $lit = $phase % 4
        for ($i = 0; $i -lt 4; $i++) {
            $al = if ($i -eq $lit) { 255 } elseif ($i -eq (($lit + 3) % 4)) { 170 } else { 95 }
            $db = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($al, $cOrange))
            $g.FillEllipse($db, [single]($cx + $pos[$i][0] * $o0 - $r0), [single]($cy + $pos[$i][1] * $o0 - $r0), [single](2 * $r0), [single](2 * $r0)); $db.Dispose()
        }
    } elseif ($flags.Ask -and -not $err) {             # Claude asks you (Allow / Deny, a question): blue disc with a "?" - stands out from the plain dot
        $bb = New-Object System.Drawing.SolidBrush $cBlue; $g.FillEllipse($bb, $bx, $by, $bd, $bd); $bb.Dispose()
        if ($bd -ge 7) { $qf = New-NumFont ([single]($bd * 0.78)); $qsz = $g.MeasureString('?', $qf, [System.Drawing.PointF]::Empty, [System.Drawing.StringFormat]::GenericTypographic); $wb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
            $g.DrawString('?', $qf, $wb, [single]($bx + ($bd - $qsz.Width) / 2), [single]($by + ($bd - $qsz.Height) / 2), [System.Drawing.StringFormat]::GenericTypographic); $wb.Dispose(); $qf.Dispose() }
    } elseif (($flags.Needs -or $flags.Unread) -and -not $err) {     # still dot: blue = needs you, purple = new reply
        $dd = [single]($bd * 0.72); $off = [single](($bd - $dd) / 2)
        $bb = New-Object System.Drawing.SolidBrush ($(if ($flags.Needs) { $cBlue } else { $cPurple }))
        $g.FillEllipse($bb, [single]($bx + $off), [single]($by + $off), $dd, $dd); $bb.Dispose()
    }
    $g.Dispose()
    return , $bmp
}

# ---------------------------------------------------------------- flyout bitmap
function Format-Reset($dt) {
    if (-not $dt) { return 'Not started - no usage in this window yet' }
    $span = $dt - (Get-Date)
    if ($span.TotalSeconds -le 0) { return 'Resetting now' }
    if ($span.TotalHours -ge 24) { $rel = '{0} d {1} h' -f [int][Math]::Floor($span.TotalDays), $span.Hours }
    elseif ($span.TotalHours -ge 1) { $rel = '{0} h {1:00} min' -f [int][Math]::Floor($span.TotalHours), $span.Minutes }
    else { $rel = '{0} min' -f [Math]::Max(1, [int][Math]::Ceiling($span.TotalMinutes)) }
    $abs = if ($span.TotalHours -ge 20) { $dt.ToString('ddd d MMM, HH:mm', $EN) } else { $dt.ToString('HH:mm') }
    return "Resets in $rel  " + [char]0x00B7 + "  $abs"
}

function New-PanelBitmap {
    param([object[]]$limits = @(), [string]$errText = '', $updated = $null, [string]$source = '', [string]$plan = '')
    $limits = @($limits | Where-Object { $null -ne $_ -and $_.PSObject.Properties['Used'] })
    $W = px 320; $P = px 16
    $fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', [single](15 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fLabel = New-Object System.Drawing.Font('Segoe UI', [single](13 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fPct   = New-Object System.Drawing.Font('Segoe UI Semibold', [single](13 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    $fSm = New-Object System.Drawing.Font('Segoe UI', [single](11.5 * $k), [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel)
    if ($LightTaskbar) { $cBg = C 243 243 243; $cText = C 26 26 26; $cDim = C 96 96 96; $cTrack = C 218 218 218; $cErr = C 196 43 28; $cLine = C 222 222 222; $cBorder = C 196 196 196 }
    else { $cBg = C 36 36 36; $cText = C 242 242 242; $cDim = C 160 160 160; $cTrack = C 66 66 66; $cErr = C 255 140 120; $cLine = C 58 58 58; $cBorder = C 70 70 70 }
    $hTitle = [int][Math]::Ceiling(15 * $k * 1.4); $hLabel = [int][Math]::Ceiling(13 * $k * 1.4); $hSmall = [int][Math]::Ceiling(11.5 * $k * 1.4)
    $barH = px 6

    $errH = 0
    if ($errText) {
        $mb = New-Object System.Drawing.Bitmap 1, 1; $mg = [System.Drawing.Graphics]::FromImage($mb)
        $errH = [int][Math]::Ceiling($mg.MeasureString($errText, $fSm, $W - 2 * $P).Height) + (px 4)
        $mg.Dispose(); $mb.Dispose()
    }
    $n = @($limits).Count
    $blockH = $hLabel + (px 3) + $barH + (px 4) + $hSmall + (px 12)
    $H = $P + $hTitle + (px 10) + ($n * $blockH) + $(if ($n -eq 0) { $hLabel + (px 8) } else { 0 }) + (px 1) + (px 10) + $errH + $hSmall + $P

    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($cBg)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $bText = New-Object System.Drawing.SolidBrush $cText
    $bDim  = New-Object System.Drawing.SolidBrush $cDim
    $bErr  = New-Object System.Drawing.SolidBrush $cErr

    $y = $P
    $g.DrawString('Tray for Claude', $fTitle, $bText, [single]($P - (px 2)), [single]$y)
    if ($plan) {
        $pt = (Get-Culture).TextInfo.ToTitleCase($plan.ToLower()) + ' plan'
        $sz = $g.MeasureString($pt, $fSm)
        $g.DrawString($pt, $fSm, $bDim, [single]($W - $P - $sz.Width), [single]($y + ($hTitle - $hSmall) / 2))
    }
    $y += $hTitle + (px 10)

    if ($n -eq 0) {
        $g.DrawString('No usage data yet', $fLabel, $bDim, [single]($P - (px 2)), [single]$y)
        $y += $hLabel + (px 8)
    }
    foreach ($l in @($limits)) {
        $used = [Math]::Max(0, [Math]::Min(100, [double]$l.Used))
        $g.DrawString($l.Label, $fLabel, $bText, [single]($P - (px 2)), [single]$y)
        $pct = ('{0}% used' -f [Math]::Round($used))
        $sz = $g.MeasureString($pct, $fPct)
        $g.DrawString($pct, $fPct, $bText, [single]($W - $P - $sz.Width + (px 2)), [single]$y)
        $y += $hLabel + (px 3)
        Fill-Round $g $cTrack $P $y ($W - 2 * $P) $barH ($barH / 2)
        $fw = ($W - 2 * $P) * $used / 100.0
        if ($used -gt 0) { Fill-Round $g (BarColor $used) $P $y ([Math]::Max($barH, $fw)) $barH ($barH / 2) }
        $y += $barH + (px 4)
        $g.DrawString((Format-Reset $l.Reset), $fSm, $bDim, [single]($P - (px 2)), [single]$y)
        $y += $hSmall + (px 12)
    }

    Fill $g $cLine $P $y ($W - 2 * $P) ([Math]::Max(1, (px 1)))
    $y += (px 1) + (px 10)
    if ($errText) {
        $g.DrawString($errText, $fSm, $bErr, (New-Object System.Drawing.RectangleF ([single]($P - (px 2))), ([single]$y), ([single]($W - 2 * $P)), ([single]$errH)))
        $y += $errH
    }
    $foot = if ($updated) {
        $age = ((Get-Date) - $updated).TotalSeconds
        $stale = if ($age -gt 3 * [int]$Cfg.pollSeconds) { ' (stale)' } else { '' }
        'Updated ' + $updated.ToString('HH:mm') + $stale
    } else { 'Not updated yet' }
    $g.DrawString($foot, $fSm, $bDim, [single]($P - (px 2)), [single]$y)

    $pb = New-Object System.Drawing.Pen $cBorder; $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None; $g.DrawRectangle($pb, 0, 0, $W - 1, $H - 1); $pb.Dispose()
    $bText.Dispose(); $bDim.Dispose(); $bErr.Dispose()
    $fTitle.Dispose(); $fLabel.Dispose(); $fPct.Dispose(); $fSm.Dispose(); $g.Dispose()
    return , $bmp
}

# ---------------------------------------------------------------- previews (so the look can be checked)
function Save-Previews {
    $levels = @(8, 38, 64, 92, 100)          # % USED
    $sizes = @(16, 20, 24, 32)
    $zoom = 4; $cell = 32 * $zoom + 8
    $sheet = New-Object System.Drawing.Bitmap ($cell * ($levels.Count + 1)), ($cell * $sizes.Count * 2)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
    $row = 0
    foreach ($light in @($false, $true)) {
        foreach ($isz in $sizes) {
            Fill $g $(if ($light) { C 238 238 238 } else { C 28 28 28 }) 0 ($row * $cell) $sheet.Width $cell
            $col = 0
            foreach ($used in $levels) {
                $b = New-TrayIcon $isz $used $false $light
                $g.DrawImage($b, (New-Object System.Drawing.Rectangle ($col * $cell + 4), ($row * $cell + 4), ($isz * $zoom), ($isz * $zoom)))
                $b.Dispose(); $col++
            }
            $b = New-TrayIcon $isz $null $true $light
            $g.DrawImage($b, (New-Object System.Drawing.Rectangle ($col * $cell + 4), ($row * $cell + 4), ($isz * $zoom), ($isz * $zoom)))
            $b.Dispose(); $row++
        }
    }
    $g.Dispose()
    $f1 = Join-Path $LogDir 'preview_icons.png'; $sheet.Save($f1, [System.Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
    # tray icon states (docs/DESIGN.md): idle, working (3 frames), needs you (2 frames), unread, needs + working - dark and light taskbars
    $cases = @(@{ F = @{}; P = 0 }, @{ F = @{ Working = $true }; P = 0 }, @{ F = @{ Working = $true }; P = 1 }, @{ F = @{ Working = $true }; P = 2 }, @{ F = @{ Working = $true }; P = 3 }, @{ F = @{ Needs = $true }; P = 0 }, @{ F = @{ Unread = $true }; P = 0 }, @{ F = @{ Needs = $true; Working = $true }; P = 1 })
    $zs = 4; $cs = 32 * $zs + 8; $st2 = New-Object System.Drawing.Bitmap ($cs * $cases.Count), ($cs * 4)
    $g2 = [System.Drawing.Graphics]::FromImage($st2); $g2.InterpolationMode = 'NearestNeighbor'; $g2.PixelOffsetMode = 'Half'
    $r2 = 0
    foreach ($light in @($false, $true)) { foreach ($isz in @(16, 24)) {
        Fill $g2 $(if ($light) { C 238 238 238 } else { C 28 28 28 }) 0 ($r2 * $cs) $st2.Width $cs
        for ($ci = 0; $ci -lt $cases.Count; $ci++) { $b2 = New-TrayIcon $isz 42 $false $light '' $cases[$ci].P $cases[$ci].F; $g2.DrawImage($b2, (New-Object System.Drawing.Rectangle ($ci * $cs + 4), ($r2 * $cs + 4), ($isz * $zs), ($isz * $zs))); $b2.Dispose() }
        $r2++ } }
    $g2.Dispose(); $st2.Save((Join-Path $LogDir 'preview_states.png'), [System.Drawing.Imaging.ImageFormat]::Png); $st2.Dispose()

    $p = New-PanelBitmap -limits $S.Limits -errText $S.Error -updated $S.Updated -source $S.Source -plan $S.Plan
    $f2 = Join-Path $LogDir 'preview_popup.png'; $p.Save($f2, [System.Drawing.Imaging.ImageFormat]::Png); $p.Dispose()

    $now = Get-Date
    $mock = @(
        [pscustomobject]@{ Key = 'five_hour'; Label = 'Session (5 h)'; Used = 34; Reset = $now.AddMinutes(134) }
        [pscustomobject]@{ Key = 'seven_day'; Label = 'Week - all models'; Used = 78; Reset = $now.AddDays(3.4) }
        [pscustomobject]@{ Key = 'seven_day_opus'; Label = 'Week - Opus'; Used = 93; Reset = $now.AddDays(3.4) }
    )
    $p = New-PanelBitmap -limits $mock -errText '' -updated $now -source 'OAuth' -plan 'max'
    $f3 = Join-Path $LogDir 'preview_popup_mock.png'; $p.Save($f3, [System.Drawing.Imaging.ImageFormat]::Png); $p.Dispose()
    Log "Previews: $f1 | $f2 | $f3 (dpi scale $k, light taskbar $LightTaskbar)"
}

# ---------------------------------------------------------------- README images (maintainers: -Screens)
function Save-IconSheet([string]$path) {
    $names = @('app', 'web', 'bell', 'belloff', 'x', 'run', 'copy', 'dir', 'ok', 'pin', 'unpin', 'send', 'bot', 'cmd', 'file', 'eye', 'hand', 'key', 'spin', 'down', 'up', 'boxok', 'skip', 'stop', 'gear')
    $cell = 40; $sheet = New-Object System.Drawing.Bitmap ($cell * $names.Count), ($cell * 2)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $g.FillRectangle([System.Drawing.Brushes]::White, 0, 0, $sheet.Width, $cell); $g.FillRectangle((New-Object System.Drawing.SolidBrush (C 38 38 36)), 0, $cell, $sheet.Width, $cell)
    for ($i = 0; $i -lt $names.Count; $i++) {
        $g.DrawImage((Get-IconBmp $names[$i] (C 60 60 58) 28), $i * $cell + 6, 6)
        $g.DrawImage((Get-IconBmp $names[$i] (C 200 198 188) 28), $i * $cell + 6, $cell + 6)
    }
    $g.Dispose(); $sheet.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
}
function Save-DocImages {
    Save-IconSheet (Join-Path $LogDir 'iconset.png')     # review sheets (the README images come from tools/readme-shots.js)
    $docs = $LogDir
    if (-not (Test-Path $docs)) { New-Item -ItemType Directory -Path $docs | Out-Null }
    $levels = @(8, 38, 64, 92, 100, -1)              # -1 = no data
    $isz = 48; $pad = 18
    $W = $pad + $levels.Count * ($isz + $pad); $rowH = $isz + 2 * $pad
    $sheet = New-Object System.Drawing.Bitmap $W, (2 * $rowH)
    $g = [System.Drawing.Graphics]::FromImage($sheet)
    $row = 0
    foreach ($light in @($true, $false)) {
        Fill $g $(if ($light) { C 238 238 238 } else { C 32 32 32 }) 0 ($row * $rowH) $W $rowH
        $col = 0
        foreach ($u in $levels) {
            $b = if ($u -lt 0) { New-TrayIcon $isz $null $true $light } else { New-TrayIcon $isz $u $false $light }
            $g.DrawImage($b, ($pad + $col * ($isz + $pad)), ($row * $rowH + $pad)); $b.Dispose(); $col++
        }
        $row++
    }
    $g.Dispose(); $sheet.Save((Join-Path $docs 'icons.png'), [System.Drawing.Imaging.ImageFormat]::Png); $sheet.Dispose()
    $now = Get-Date
    $mock = @(
        [pscustomobject]@{ Key = 'five_hour'; Label = 'Session (5 h)'; Used = 38; Reset = $now.AddMinutes(134) }
        [pscustomobject]@{ Key = 'seven_day'; Label = 'Week - all models'; Used = 64; Reset = $now.AddDays(2.3) }
    )
    $keep = $script:LightTaskbar
    foreach ($thm in @('light', 'dark')) {
        $script:LightTaskbar = ($thm -eq 'light')
        $p = New-PanelBitmap -limits $mock -errText '' -updated $now -source 'OAuth' -plan ''
        $p.Save((Join-Path $docs "flyout-$thm.png"), [System.Drawing.Imaging.ImageFormat]::Png); $p.Dispose()
    }
    $script:LightTaskbar = $keep
    Log "README images written to $docs (mock data)"
}

# ---------------------------------------------------------------- shortcuts
$PsExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$LnkStart = Join-Path ([Environment]::GetFolderPath('Programs')) "$AppName.lnk"
$LnkBoot  = Join-Path ([Environment]::GetFolderPath('Startup')) "$AppName.lnk"
$LegacyLnks = @('Claude Usage.lnk', 'ClaudePlus.lnk') | ForEach-Object { (Join-Path ([Environment]::GetFolderPath('Programs')) $_); (Join-Path ([Environment]::GetFolderPath('Startup')) $_) }
function Remove-LegacyLnks { foreach ($f in $LegacyLnks) { if (Test-Path $f) { Remove-Item $f -Force; Log "Removed pre-rename shortcut $f" } } }
function Restart-Tray([string]$from) {            # a fresh instance: it signals this one to quit, then takes over
    Log "restart (from the $from)"
    try { Start-Process $PsExe -ArgumentList "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Restart" -WorkingDirectory $Root -WindowStyle Hidden } catch { Log "restart: $($_.Exception.Message)" 'ERR' }
}
# ---- updates: only when you ask (Settings > Check for updates). A git clone fetches tags with your own git (works
# for a private repo you can read); a zip install asks GitHub's release list (public repo only). Nothing else is sent.
$UpdRepo = 'mapmodelers/ClaudeTray'
$UpdScript = {
    param([string]$rootDir, [string]$ver, [string]$repo, [string]$mode, [string]$want)
    $r = @{ St = 'none'; New = ''; How = ''; Msg = '' }
    $env:GIT_TERMINAL_PROMPT = '0'
    $vOf = { param($tg) try { [version]([string]$tg -replace '^v', '') } catch { [version]'0.0.0' } }
    $git = Get-Command git -ErrorAction SilentlyContinue
    try {
        if ($git -and (Test-Path (Join-Path $rootDir '.git'))) {
            $r.How = 'git'
            if ($mode -eq 'check') {
                $lr = @(& git -C $rootDir ls-remote --tags --refs origin 'v*' 2>$null); if ($LASTEXITCODE) { $r.St = 'err'; $r.Msg = 'git could not reach GitHub (signed in?)'; return $r }     # asks GitHub, changes nothing here (a fetch of all tags fails on a tag that was re-made)
                $best = $lr | ForEach-Object { ($_ -split '\s+')[-1] -replace '^refs/tags/', '' } | Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } | Sort-Object { & $vOf $_ } | Select-Object -Last 1
                if ($best -and (& $vOf $best) -gt [version]$ver) { $r.St = 'avail'; $r.New = $best.Substring(1) }
                return $r
            }
            if (@(& git -C $rootDir status --porcelain --untracked-files=no).Count) { $r.St = 'err'; $r.Msg = 'files changed in the folder: update by hand'; return $r }
            if ((& git -C $rootDir rev-parse --abbrev-ref HEAD) -ne 'main') { $r.St = 'err'; $r.Msg = 'not on main: update by hand'; return $r }
            $null = & git -C $rootDir fetch --quiet --no-tags origin "refs/tags/v$want" 2>&1; if ($LASTEXITCODE) { $r.St = 'err'; $r.Msg = 'git could not download it'; return $r }
            $null = & git -C $rootDir merge --ff-only --quiet FETCH_HEAD 2>&1; if ($LASTEXITCODE) { $r.St = 'err'; $r.Msg = 'local commits: update by hand'; return $r }
            $r.St = 'done'; $r.New = $want; return $r
        }
        $r.How = 'zip'
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        if ($mode -eq 'check') {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases?per_page=10" -Headers @{ 'User-Agent' = 'ClaudeTray'; 'Accept' = 'application/vnd.github+json' } -TimeoutSec 15 -UseBasicParsing
            $best = @($rel) | Where-Object { -not $_.draft -and $_.tag_name -match '^v\d+\.\d+\.\d+$' } | Sort-Object { & $vOf $_.tag_name } | Select-Object -Last 1
            if ($best -and (& $vOf $best.tag_name) -gt [version]$ver) { $r.St = 'avail'; $r.New = $best.tag_name.Substring(1) }
            return $r
        }
        $tmp = Join-Path $env:TEMP ('ClaudeTray-update-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $zipF = Join-Path $tmp 'u.zip'
        Invoke-WebRequest -Uri "https://github.com/$repo/archive/refs/tags/v$want.zip" -OutFile $zipF -UseBasicParsing -TimeoutSec 60 -Headers @{ 'User-Agent' = 'ClaudeTray' }
        Expand-Archive -Path $zipF -DestinationPath $tmp -Force
        $top = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
        if (-not $top -or -not (Test-Path (Join-Path $top.FullName 'ClaudeTray.ps1'))) { $r.St = 'err'; $r.Msg = 'the download looks wrong'; return $r }
        Copy-Item -Path (Join-Path $top.FullName '*') -Destination $rootDir -Recurse -Force     # your config, state, sign-in and logs are not in the archive: kept
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
        $r.St = 'done'; $r.New = $want; return $r
    } catch {
        $r.St = 'err'; $m0 = $_.Exception.Message
        $r.Msg = if ($m0 -match '404') { 'no public release list (private repository?)' } elseif ($m0 -match 'resolve|connect|timed out') { 'GitHub not reachable' } else { 'failed' }
        return $r
    }
}
function Start-Update([string]$mode) {                # check / apply in the background; Poll-Update picks up the result
    if ($UI.UpdPs) { return }
    if ($mode -eq 'apply' -and $UI.Upd.St -ne 'avail') { return }
    $UI.Upd.St = $(if ($mode -eq 'apply') { 'applying' } else { 'checking' }); $UI.Upd.Mode = $mode
    $ps = [powershell]::Create(); [void]$ps.AddScript($UpdScript).AddArgument($Root).AddArgument($Version).AddArgument($UpdRepo).AddArgument($mode).AddArgument([string]$UI.Upd.New)
    $UI.UpdPs = $ps; $UI.UpdH = $ps.BeginInvoke(); $UI.UpdAt = Get-Date
    Log "update: $mode"; Push-WebState
}
function Poll-Update {
    $ps = $UI.UpdPs; if (-not $ps) { return }
    if (-not $UI.UpdH.IsCompleted -and ((Get-Date) - $UI.UpdAt).TotalSeconds -lt 120) { return }
    $r = $null; try { if ($UI.UpdH.IsCompleted) { $r = @($ps.EndInvoke($UI.UpdH))[-1] } } catch { }
    try { $ps.Dispose() } catch { }; $UI.UpdPs = $null
    if (-not $r) { $r = @{ St = 'err'; Msg = 'timed out'; How = ''; New = '' } }
    $UI.Upd.St = [string]$r.St; $UI.Upd.How = [string]$r.How; $UI.Upd.Msg = [string]$r.Msg; if ($r.New) { $UI.Upd.New = [string]$r.New }
    Log ("update: {0} -> {1} {2} {3}" -f $UI.Upd.Mode, $UI.Upd.St, $UI.Upd.New, $UI.Upd.Msg)
    if ($UI.Upd.St -eq 'done') { try { $tray.ShowBalloonTip(3000, 'Tray for Claude', "Updated to $($UI.Upd.New). Restarting.", [System.Windows.Forms.ToolTipIcon]::Info) } catch { }; Restart-Tray 'update'; return }
    Push-WebState
}
function New-BootLnk {                             # Windows-startup shortcut for the chosen mode: 'windows' (default), 'claude' (wakes when the app opens), 'manual' (none)
    $mode = [string]$Cfg.startWith; if (-not $mode) { $mode = 'windows' }
    if ($mode -eq 'manual') { if (Test-Path $LnkBoot) { Remove-Item $LnkBoot -Force }; return }
    New-Lnk $LnkBoot $(if ($mode -eq 'claude') { ' -WaitClaude' } else { '' })
}
function New-Lnk([string]$path, [string]$extra = '') {
    $ws = New-Object -ComObject WScript.Shell
    $l = $ws.CreateShortcut($path)
    $l.TargetPath = $PsExe
    $l.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$Script`" -Run$extra"
    $l.WorkingDirectory = $Root
    $l.WindowStyle = 7
    $l.Description = 'ClaudeTray - Claude in your tray'
    $l.Save()
}
function Stop-Others {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" |
        Where-Object { $_.ProcessId -ne $PID -and ($_.CommandLine -like '*ClaudeTray.ps1*' -or $_.CommandLine -like '*ClaudePlus.ps1*') -and $_.CommandLine -notmatch '-(Once|Install|Uninstall|Login|Logout|Screens)\b' })
    if ($procs) {                                   # ask nicely first: the worker disposes its icon (no ghost icon left behind)
        try { $ev = [System.Threading.EventWaitHandle]::OpenExisting('Local\ClaudeTray.Quit'); [void]$ev.Set(); $ev.Close(); Log 'Quit signal sent' } catch { }
        foreach ($p in $procs) { try { Wait-Process -Id $p.ProcessId -Timeout 4 -ErrorAction SilentlyContinue } catch { } }
    }
    foreach ($p in $procs) {
        if (-not (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue)) { Log "Previous tray pid $($p.ProcessId) exited on request"; continue }
        try { Stop-Process -Id $p.ProcessId -Force; Wait-Process -Id $p.ProcessId -Timeout 3 -ErrorAction SilentlyContinue; Log "Stopped previous tray pid $($p.ProcessId)" }
        catch { Log "Could not stop pid $($p.ProcessId): $($_.Exception.Message)" 'WARN' }
    }
}
function Start-Tray {
    try { [ClaudeTray.Native]::RefreshTray() } catch { }
    Start-Process -FilePath $PsExe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$Script`"", '-Run')
    Log 'Tray launched (hidden, detached)'
}

function Find-Edge {                                 # Edge: machine-wide, per-user, or wherever App Paths says
    $c = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe")
    foreach ($rk in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe') { try { $v = (Get-ItemProperty $rk -ErrorAction Stop).'(default)'; if ($v) { $c += [string]$v } } catch { } }
    return @($c | Where-Object { $_ -and (Test-Path $_) }) | Select-Object -First 1
}
function Get-WebProfile { if ($Cfg.webProfile) { return [Environment]::ExpandEnvironmentVariables([string]$Cfg.webProfile) }; return (Join-Path $env:LOCALAPPDATA 'ClaudeTray\browser-profile') }
function Stop-OurBrowser {                           # the tray's own headless Edge (signed in to claude.ai, DevTools port open): never left behind on exit
    $prof = Get-WebProfile
    try { foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($prof) -and $_.CommandLine -match 'remote-debugging-port' })) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue } } catch { }
}
# ================================================================ entry
Log ("==== ClaudeTray v{0} | args: {1} | PS {2} | dpi {3} | light taskbar {4}" -f $Version, (($PSBoundParameters.Keys | ForEach-Object { "-$_" }) -join ' '), $PSVersionTable.PSVersion, $k, $LightTaskbar)
try {
    if ($Uninstall) {
        foreach ($f in @($LnkStart, $LnkBoot)) { if (Test-Path $f) { Remove-Item $f -Force; Log "Removed $f" } }
        Remove-LegacyLnks
        Stop-Others; Stop-OurBrowser
        Write-Host 'Uninstalled: shortcuts removed and the tray stopped. Your login (oauth.json) is kept - use -Logout to remove it.'
        return
    }
    if ($WebLogin) {
        $ed = Find-Edge; if (-not $ed) { Write-Host 'Microsoft Edge not found - live chats in the panel need it.'; return }
        Stop-OurBrowser; $wprof = Get-WebProfile; New-Item -ItemType Directory -Path $wprof -Force | Out-Null
        Write-Host 'An Edge window opens on claude.ai: sign in there, then close that window. The tray uses this sign-in for live chats.'
        $pw = Start-Process $ed -ArgumentList @("--user-data-dir=`"$wprof`"", '--no-first-run', '--new-window', 'https://claude.ai/login') -PassThru
        Log 'web login: Edge opened with the tray profile'
        try { $pw.WaitForExit() } catch { }
        if (-not (Test-Path $LnkStart)) { Remove-LegacyLnks; New-Lnk $LnkStart; New-BootLnk; Write-Host 'Added to the Start menu and set to start with Windows.' }
        Write-Host 'Starting the tray...'; Stop-Others; Start-Tray; return
    }
    if ($Logout) {
        Stop-Others
        foreach ($f in @($OAuthFile, "$OAuthFile.claudetray.bak")) { if (Test-Path $f) { Remove-Item $f -Force; Log "Removed $f" } }
        Stop-OurBrowser
        Write-Host 'Logged out: stored token deleted and the tray stopped.'
        Write-Host "The tray's browser is still signed in to claude.ai: delete $env:LOCALAPPDATA\ClaudeTray\browser-profile to sign it out too."
        Log 'logout: token removed, browser stopped (its profile is kept)'
        return
    }
    if ($Login) {
        if (Invoke-Login) {
            Update-Usage; Save-Previews
            if ($S.Error) { Write-Host "`nLogged in, but the usage fetch failed: $($S.Error)" }
            else { Write-Host "`nWorks - $(@($S.Limits).Count) limit(s) read. Adding shortcuts and starting the tray..."; Remove-LegacyLnks; New-Lnk $LnkStart; New-BootLnk; Start-Tray; Write-Host 'Done. Look for the gauge near the clock (check the hidden-icons area ^ and drag it onto the taskbar).' }
            Log ("LOGIN RESULT: error='{0}' limits={1}" -f $S.Error, @($S.Limits).Count)
        }
        return
    }
    if ($Screens) { Save-DocImages; return }
    if ($Once) {
        Log ("Logged in: {0}" -f (Test-Path (Get-CredPath)))
        Update-Usage
        Save-Previews
        Log ("ONCE RESULT: error='{0}' limits={1}" -f $S.Error, @($S.Limits).Count)
    }
    if ($Install) {
        if (-not (Test-Path (Get-CredPath))) { Write-Host 'Not logged in yet - run with -Login first.'; return }
        Remove-LegacyLnks
        New-Lnk $LnkStart; Log "Start-menu shortcut: $LnkStart"
        New-BootLnk;  Log "Startup shortcut: $LnkBoot"
        Start-Tray
    }
    if ($Once -or $Install) { return }
} catch {
    Log ("FATAL: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR'
    return
}

# ---------------------------------------------------------------- start request -> launch the detached background tray
# Running the tray directly in this console would die when the window closes, so unless we ARE the
# detached worker (-Run), (re)launch it hidden and exit. This covers the no-switch and -Restart cases.
if (-not $Run) {
    Stop-Others
    Start-Tray
    Write-Host 'ClaudeTray is running in the background (look near the clock). You can close this window.'
    return
}

# ---------------------------------------------------------------- tray mode (detached worker)
Stop-Others
$created = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeTray', [ref]$created)
if (-not $created) { Log 'Another tray is already running; exiting (use -Restart)' 'WARN'; return }
if ($WaitClaude) {                                 # "start with the Claude app": asleep, no icon, one cheap process check every 3 s
    Log 'waiting for the Claude app (start mode: with Claude)'
    while (-not @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }).Count) { Start-Sleep -Seconds 3 }
    Log 'Claude app opened - starting'
}

$UI = @{ FoldAll = $true; Upd = @{ St = ''; New = ''; How = ''; Msg = ''; Mode = '' }; UpdPs = $null; Shown = $false; Pinned = $false; Docked = $false; Pending = $false; PendSince = (Get-Date); Anchor = [System.Drawing.Point]::Empty; IconHandle = [IntPtr]::Zero; LastPollAt = (Get-Date); ShownAt = (Get-Date); ShowWhy = ''; Phase = 0; Queue = @{}; QueuedAt = @{}; Drafts = @{}; FocusReply = $null; ProbeKey = ''; Fields = @(); Tick = 0; Live = @{}; ViewSig = ''; Bars = @(); Built = $false; PreBuild = $true; WebSig = ''; FocusTarget = $null; FocusTries = 0; WebSends = @{}; ShotAt = $null; ShotWhy = ''; WebWas = @{}; UsageAlerted = @{}; Chats = @{}; Sending = @{}; RenderAfterBuild = @(); ClockWarned = @{}; WorkSince = $null; IdleSince = $null; LastWorking = $false; Expanded = @{}; AnsOpen = @{}; Inputs = @(); Markers = @(); FocusAfter = $null; Rows = @(); Drag = $null; UsageOpen = $false }
$tol = px 10
# theme: config 'theme' = auto (follow Windows app mode) | light | dark. Claude-like palette.
$T = @{}
function Get-AppsLight {
    switch ([string]$Cfg.theme) { 'light' { return $true } 'dark' { return $false } }
    try { return ((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 1) } catch { return $LightTaskbar }
}
function Apply-Theme {
    $light = Get-AppsLight
    if ($UI.ContainsKey('Light') -and $UI.Light -eq $light) { return }
    $UI.Light = $light
    $pal = if ($light) { @{ Bg = C 250 249 245; Card = C 255 255 255; Tx = C 20 20 19; Mu = C 125 122 114; Ln = C 230 227 218; Acc = C 201 99 63; Ok = C 63 138 74; Pur = C 126 107 196; Act = C 58 118 184; Field = C 255 255 255 } }
           else { @{ Bg = C 38 38 36; Card = C 48 48 46; Tx = C 238 236 226; Mu = C 154 151 141; Ln = C 59 58 55; Acc = C 217 119 87; Ok = C 111 168 118; Pur = C 126 107 196; Act = C 98 150 214; Field = C 38 38 36 } }
    foreach ($pk in $pal.Keys) { $T[$pk] = $pal[$pk] }
    if ($UI.WebUi) { try { $UI.WebUi.DefaultBackgroundColor = $T.Bg } catch { } }
    if ($UI.Sides) { foreach ($sd in @($UI.Sides.Values)) { try { $sd.Wv.DefaultBackgroundColor = $T.Bg; $sd.Form.BackColor = $T.Bg; if ($sd.Ready) { Send-Side $sd @{ type = 'theme'; theme = (Get-SideTheme) } } } catch { } } }
    if ($UI.ContainsKey('PopReady')) { $pop.BackColor = $T.Bg; $pop.ForeColor = $T.Tx; $content.BackColor = $T.Bg; Request-Build }
    Log ("Theme: {0} ({1})" -f $(if ($light) { 'light' } else { 'dark' }), $Cfg.theme)
}
Apply-Theme
$AppsLight = $UI.Light
$TT = New-Object System.Windows.Forms.ToolTip; $TT.InitialDelay = 350; $TT.ReshowDelay = 100; $TT.ShowAlways = $true; $TT.AutoPopDelay = 8000   # ONE tooltip for every control (one per control = a window each, leaked on rebuild)
$FUi = New-Object System.Drawing.Font('Segoe UI', 9); $FBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$FStrike = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Strikeout)
$FSmall = New-Object System.Drawing.Font('Segoe UI', 8); $FMono = New-Object System.Drawing.Font('Consolas', 8)
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($sender, $e) try { $ex = $e.Exception; $pos = ''; if ($ex.ErrorRecord) { $pos = ' @ line ' + $ex.ErrorRecord.InvocationInfo.ScriptLineNumber }; Log ("UI exception: {0}{1} | {2}" -f $ex.Message, $pos, (($ex.StackTrace -split "`n" | Select-Object -First 2) -join ' / ')) 'ERR' } catch { } })
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Tray for Claude'
$QuitEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, 'Local\ClaudeTray.Quit')
[void]$QuitEvent.Reset()
function Exit-Tray([string]$why) { Write-Heartbeat 'exit'; Log "Exit: $why"; try { if ($script:Park) { Undo-DesktopPark $false } } catch { }; if ($why -notmatch 'restart') { Stop-OurBrowser }; try { $Probe.Stop = $true } catch { }; try { $uiTimer.Stop(); $pollTimer.Stop(); $questTimer.Stop(); $animTimer.Stop() } catch { }; try { $pop.Hide() } catch { }; $tray.Visible = $false; $tray.Dispose(); [System.Windows.Forms.Application]::Exit() }

# ---------------------------------------------------------------- quests: read / state / results
$QS = @{ List = @(); Prev = @{}; Running = @{}; Hidden = @{}; Pins = [ordered]@{}; Layout = $null; Proj = @{}; Anchor = @{}; Bells = @{}; Dock = $null; DockB = $null; Titles = @{}; DeskOnly = @{}; Alerts = @{}; Read = @{} }
if (Test-Path $StateFile) { try { $stj = [IO.File]::ReadAllText($StateFile) | ConvertFrom-Json; if ($stj.hidden) { $stj.hidden.PSObject.Properties | ForEach-Object { $QS.Hidden[$_.Name] = [string]$_.Value } }; if ($stj.bells) { $stj.bells.PSObject.Properties | ForEach-Object { $QS.Bells[$_.Name] = [bool]$_.Value } }; if ($stj.pins) { foreach ($pk in @($stj.pins)) { $QS.Pins[[string]$pk] = $true } }; if ($stj.layout) { $QS.Layout = $stj.layout }; if ($stj.alias) { $QS.AliasIn = @{}; $stj.alias.PSObject.Properties | ForEach-Object { $QS.AliasIn[$_.Name] = [string]$_.Value } }; if ($stj.anchor) { $stj.anchor.PSObject.Properties | ForEach-Object { $QS.Anchor[$_.Name] = @{ U = [string]$_.Value.U; T = [string]$_.Value.T; L = [string]$_.Value.L } } }; if ($stj.proj) { $stj.proj.PSObject.Properties | ForEach-Object { $QS.Proj[$_.Name] = [string]$_.Value } }; if ($stj.alerts) { foreach ($ak in @($stj.alerts)) { $QS.Alerts[[string]$ak] = $true } }; if ($stj.read) { $stj.read.PSObject.Properties | ForEach-Object { $QS.Read[$_.Name] = @{ K = [string]$_.Value.k; At = $(try { [DateTimeOffset]::Parse([string]$_.Value.at, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { $null }) } } }; if ($stj.docked) { $UI.RestoreDock = $true }; if ($stj.deskonly) { $stj.deskonly.PSObject.Properties | ForEach-Object { $QS.DeskOnly[$_.Name] = $true } }; if ($stj.titles) { $stj.titles.PSObject.Properties | ForEach-Object { $QS.Titles[$_.Name] = [string]$_.Value } }; if ($stj.dock -and @($stj.dock).Count -eq 2) { $QS.Dock = @([int]$stj.dock[0], [int]$stj.dock[1]); $UI.DockPos = New-Object System.Drawing.Point $QS.Dock[0], $QS.Dock[1] }; if ($null -ne $stj.dockb) { $QS.DockB = [int]$stj.dockb } } catch { } }
function Get-ReadForSave { $o = @{}; foreach ($rk in @($QS.Read.Keys)) { $o[$rk] = @{ k = $QS.Read[$rk].K; at = $(if ($QS.Read[$rk].At) { Get-Iso $QS.Read[$rk].At } else { '' }) } }; return $o }
function Save-State { try { [IO.File]::WriteAllText($StateFile, (@{ hidden = $QS.Hidden; pins = @($QS.Pins.Keys); layout = $QS.Layout; proj = $QS.Proj; anchor = $QS.Anchor; alias = $(if ($Web -and $Web.Alias) { $Web.Alias } else { @{} }); bells = $QS.Bells; dock = $QS.Dock; dockb = $QS.DockB; titles = $QS.Titles; deskonly = $QS.DeskOnly; docked = [bool]($UI.Docked -or $UI.RestoreDock); alerts = @($QS.Alerts.Keys | Select-Object -Last 40); read = $(Get-ReadForSave) } | ConvertTo-Json -Compress -Depth 8), (New-Object Text.UTF8Encoding $false)) } catch { Log "state save: $($_.Exception.Message)" 'WARN' } }
function Get-Iso($dt) { return ([datetime]$dt).ToString('yyyy-MM-ddTHH:mm:ssK') }
function Parse-Iso($txt) { try { if (-not $txt) { return $null }; if ($txt -is [datetime]) { return $txt }; return ([DateTimeOffset]::Parse([string]$txt, $EN)).LocalDateTime } catch { return $null } }
function Get-SentText([string]$txt0) { $txt0 = ($txt0 -replace '\s+', ' ').Trim(); if ($txt0.Length -gt 120) { $txt0 = $txt0.Substring(0, 120) + "…" }; return $txt0 }   # Claude has the full text in the chat: the results file only needs to recognise it
# capabilities that proved unreliable on this setup (Claude Enterprise + Claude Desktop MSIX, Cowork local sessions); code kept, switched off. Author: enable per setup once verified.
$Caps = @{ Local = $true; Park = $true; Ghost = $true }     # Claude Desktop local chats: on by themselves when Desktop has some (nothing runs for them until one is tracked); parking / hiding Desktop are settings that only show then
function Get-HideAfterMin { if ($null -ne $Cfg.hideAfterMin -and "$($Cfg.hideAfterMin)" -ne '') { return [double]$Cfg.hideAfterMin }; return 10 }     # minutes; 0 = never
function Get-LastActivity($q) {     # latest of quest write, your send, your read, re-show, the chat's own activity (claude.ai tab / local transcript)
    $id = [string]$q.id; $last = $q.Upd
    foreach ($tx in @($q.LastSent, $(if ($QS.Read[$id]) { $QS.Read[$id].At } else { $null }), $(if ($script:CoolTouch) { $script:CoolTouch[$id] } else { $null }))) { if ($tx -is [datetime] -and (-not $last -or $tx -gt $last)) { $last = $tx } }
    $wc = $Web.Chats[$id]; if ($wc -and $wc.EndAt -is [datetime] -and $wc.EndAt -gt [datetime]::MinValue -and (-not $last -or $wc.EndAt -gt $last)) { $last = $wc.EndAt }
    if ($id.StartsWith('local/')) { try { $ls = Get-LocalState $q; if ($ls -and $ls.Mt) { $lm = ([datetime]$ls.Mt).ToLocalTime(); if (-not $last -or $lm -gt $last) { $last = $lm } } } catch { } }
    return $last
}
function Test-Cooled($q) {     # an idle chat (not pinned, nothing for you, not working, card closed) leaves the tray after the cooldown; Browse still lists it
    $mn = Get-HideAfterMin; if ($mn -le 0) { return $false }
    $id = [string]$q.id
    if ($QS.Pins.Contains($id) -or [string]$q.St -in 'act', 'working' -or (@($UI.WebOpen) -contains $id)) { return $false }
    try { if ((Test-ChatWorking $q) -or (Test-ChatAsks $q)) { return $false } } catch { }
    $last = Get-LastActivity $q; if (-not $last) { return $false }
    return (((Get-Date) - $last).TotalMinutes -ge $mn)
}
function Get-QVisible($q) { $id = [string]$q.id; if ($id.StartsWith('local/') -and -not $Caps.Local) { return $false }; if ($QS.Pins.Contains($id)) { return $true }; if ($QS.Hidden.ContainsKey($id) -and $QS.Hidden[$id] -eq [string]$q.updated) { return $false }; return -not (Test-Cooled $q) }
function Get-FileId([string]$id) { return ($id -replace '[\\/]', '__') }
function Read-Results($q) {
    $f = Join-Path $q.Root ('results\' + (Get-FileId $q.id) + '.json')
    if (-not (Test-Path $f)) { return $null }
    try { return ([IO.File]::ReadAllText($f) | ConvertFrom-Json) } catch { Log "results parse $f : $($_.Exception.Message)" 'WARN'; return $null }
}
function Save-Results($q, $res) {
    $d = Join-Path $q.Root 'results'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $f = Join-Path $d ((Get-FileId $q.id) + '.json')
    $res | Add-Member -NotePropertyName style -NotePropertyValue $(if ($Cfg.terse) { 'terse' } else { 'normal' }) -Force     # the skill: terse = shortest replies for the tray (default), normal = usual    # Claude reads this file on 'check': the toggle costs no tokens
    try { [IO.File]::WriteAllText($f, ($res | ConvertTo-Json -Depth 8 -Compress), (New-Object Text.UTF8Encoding $false)) } catch { Log "results save: $($_.Exception.Message)" 'WARN' }
}
function New-Results($q) { return [pscustomobject]@{ v = 1; id = $q.id; quest_updated = [string]$q.updated; steps = @(); sent = @() } }
function Get-Results($q) {
    $r = Read-Results $q
    if (-not $r -or [string]$r.quest_updated -ne [string]$q.updated) { $r = New-Results $q }   # new quest version: fresh results
    if ($null -eq $r.steps) { $r | Add-Member -NotePropertyName steps -NotePropertyValue @() -Force }
    if ($null -eq $r.sent) { $r | Add-Member -NotePropertyName sent -NotePropertyValue @() -Force }
    return $r
}
function Set-StepResult($q, [int]$n, [hashtable]$fields) {
    $r = Get-Results $q
    $rec = @($r.steps) | Where-Object { [int]$_.n -eq $n } | Select-Object -First 1
    if (-not $rec) { $rec = [pscustomobject]@{ n = $n; status = 'pending' }; $r.steps = @(@($r.steps) + $rec) }
    foreach ($fk in $fields.Keys) { $rec | Add-Member -NotePropertyName $fk -NotePropertyValue $fields[$fk] -Force }
    Save-Results $q $r
}
function Read-Quests {
    $out = @()
    foreach ($qroot in $QuestRoots) {
        $d = Join-Path $qroot 'quests'; if (-not (Test-Path $d)) { continue }
        foreach ($f in Get-ChildItem $d -Filter *.json -File -ErrorAction SilentlyContinue) {
            try {
                $q = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                if (-not $q.id) { continue }
                $q | Add-Member -NotePropertyName Root -NotePropertyValue $qroot -Force
                $q | Add-Member -NotePropertyName File -NotePropertyValue $f.FullName -Force
                $upd = $f.LastWriteTime                     # real time on this PC; the 'updated' field is only a version key (writers may get the clock wrong)
                $claimed = Parse-Iso $q.updated
                if ($claimed -and [Math]::Abs(($claimed - $upd).TotalMinutes) -gt 5 -and -not $UI.ClockWarned.ContainsKey([string]$q.id)) { $UI.ClockWarned[[string]$q.id] = $true; Log ("quest {0}: 'updated' {1:HH:mm} differs from the file time {2:HH:mm} - using the file time" -f $q.id, $claimed, $upd) 'WARN' }
                $q | Add-Member -NotePropertyName Upd -NotePropertyValue $upd -Force
                if ($null -eq $q.steps) { $q | Add-Member -NotePropertyName steps -NotePropertyValue @() -Force }
                $res = Get-Results $q
                $q | Add-Member -NotePropertyName Res -NotePropertyValue $res -Force
                # derived state: working = something was sent back after this quest version
                $lastSent = $null; foreach ($sx in @($res.sent)) { $ts = Parse-Iso $sx.at; if ($ts -and (-not $lastSent -or $ts -gt $lastSent)) { $lastSent = $ts } }
                $st = if ($lastSent -and $lastSent -gt $upd) { 'working' } elseif ([string]$q.state -eq 'act' -and @($q.steps).Count -gt 0) { 'act' } else { 'done' }
                $q | Add-Member -NotePropertyName St -NotePropertyValue $st -Force
                $q | Add-Member -NotePropertyName LastSent -NotePropertyValue $lastSent -Force
                $q | Add-Member -NotePropertyName Visible -NotePropertyValue (Get-QVisible $q) -Force     # pinned = always shown; idle chats leave the tray after the cooldown
                $out += $q
            } catch {
                # caught mid-write (Claude rewriting it): keep the last good version for this file, don't drop the chat for a pass
                $prevQ = @($QS.List | Where-Object { $_.File -eq $f.FullName }) | Select-Object -First 1
                if ($prevQ) { $out += $prevQ } else { Log "quest parse $($f.Name): $($_.Exception.Message)" 'WARN' }
                if (-not $UI.ParseWarn) { $UI.ParseWarn = @{} }; if (-not $UI.ParseWarn.ContainsKey($f.Name)) { $UI.ParseWarn[$f.Name] = $true; Log "quest parse $($f.Name): $($_.Exception.Message) (kept the previous version)" 'DEBUG' }
            }
        }
    }
    $order = @{ act = 0; done = 1; working = 2 }
    return @($out | Sort-Object @{ e = { $order[$_.St] } }, @{ e = { $_.Upd }; Descending = $true })
}
function Get-IconFlags {
    $v = @($QS.List | Where-Object { $_.Visible })
    $ask = [bool]($v | Where-Object { Test-ChatAsks $_ })      # Claude waits on you inside the chat (Allow / Deny, a question): first, even while its turn is still running
    $needs = $ask -or [bool]($v | Where-Object { $_.St -eq 'act' -and -not $UI.Answered[[string]$_.id] })
    $working = (-not $ask) -and [bool]($v | Where-Object { Test-ChatWorking $_ })
    $unread = [bool]($v | Where-Object { Test-Unread $_ })
    return @{ Ask = $ask; Needs = $needs; Working = $working; Unread = $unread }
}
function Test-ChatAsks($q) { if (Get-LocalAsk $q) { return $true }; $wc = $Web.Chats[[string]$q.id]; return [bool]($wc -and (@($wc.Prompts).Count -or $wc.Q)) }
function Get-Badge { $fl = Get-IconFlags; if ($fl.Ask) { return 'ask' }; if ($fl.Needs) { return 'act' }; if ($fl.Working) { return 'working' }; if ($fl.Unread) { return 'done' }; return '' }
function Format-Age($dt) { if (-not $dt) { return '' }; $sp = (Get-Date) - $dt; if ($sp.TotalMinutes -lt 1) { return 'now' }; if ($sp.TotalHours -lt 1) { return ('{0}m' -f [int]$sp.TotalMinutes) }; if ($sp.TotalDays -lt 1) { return ('{0}h' -f [int]$sp.TotalHours) }; return ('{0}d' -f [int]$sp.TotalDays) }

# ---------------------------------------------------------------- actions: open / send / run steps
# ---------------------------------------------------------------- app watcher: which chat is open in the desktop app, and is Claude generating?
# runs in its own runspace (UI Automation walks can take 100-500 ms; the UI thread never waits on them)
$Probe = [hashtable]::Synchronized(@{ Page = ''; Working = $false; Buttons = ''; At = [datetime]::MinValue; Err = ''; Stop = $false; Fast = $false; StopName = ''; VerifySnip = ''; VerifyUntil = [datetime]::MinValue; VerifyResult = ''; Ms = 0; VerifyBase = 0; LastUser = ''; VerifyPrev = ''; AppQueued = $false; VerifyHadQueue = $false; LiveText = ''; LivePage = ''; LiveAt = [datetime]::MinValue; ExpectAt = [datetime]::MinValue; ExpectPage = ''; SawStop = $true; Starting = $false; DiagSig = ''; DiagLog = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)) })
$probeScript = {
    param($Probe)
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $btnC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $docC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
    $txtC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $stopRx = '(?i)^(stop|arr[eê]t|interromp|annuler la r)|stop (response|generating)|arr[eê]ter (la )?(r[eé]ponse|g[eé]n[eé]ration)'
    $idleN = 0
    while (-not $Probe.Stop) {
        if ($Probe.Pause -and -not $Probe.VerifySnip) { Start-Sleep -Milliseconds 1000; continue }
        $t0 = [Diagnostics.Stopwatch]::StartNew()
        try {
            $w = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' -and $_.MainWindowHandle -ne 0 })[0]
            if (-not $w) { $Probe.Page = ''; $Probe.Working = $false; $Probe.Ask = $null; $Probe.At = Get-Date }
            else {
                $r = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.MainWindowHandle)
                $page = ''
                foreach ($d in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $docC))) { $nm = [string]$d.Current.Name; if ($nm -and $nm -ne 'Claude') { $page = $nm; break } }
                $names = @(); $work = $false; $stopName = ''; $seenN = 0; $lastUser = ''; $appQueued = $false; $qOpt = @()     # qOpt = Cowork question-card rows
                $snip = [string]$Probe.VerifySnip
                $diag = ((Get-Date) - $Probe.ExpectAt).TotalSeconds -lt 30; $allBtn = @()
                foreach ($b in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnC))) {
                    $nm = [string]$b.Current.Name
                    if ($diag -and $nm -match '(?i)^(arr|stop|envoy|send|annul|cancel|interr|pause|reprend|resume|joindre|attach|ajouter)') { $allBtn += ('{0}{1}' -f $nm.Substring(0, [Math]::Min(30, $nm.Length)), $(if ($b.Current.IsEnabled) { '' } else { '(off)' })) }   # composer controls only - never sidebar / chat names
                    if ($nm -match $stopRx) { $work = $true; $stopName = $nm }
                    if ([string]$b.Current.ClassName -like 'group/row *') { $qOpt += $b }     # question choices (class, not text: any language)
                    if ($nm -match '(?i)^(envoyer maintenant|send now)') { $appQueued = $true }
                    if ($snip -and ($nm -replace '\s+', ' ').Contains($snip)) { $seenN++ }
                    if ($nm -match '(?i)(vous avez dit|you said)\s*:\s*(.*)$') { $lastUser = ($Matches[2] -replace '\s+', ' ').Trim() }
                    if ($nm -match '(?i)^(stop|arr|interr|envoy|send|annul)') { $names += $nm }
                }
                if ($snip) {
                    if ($seenN -gt [int]$Probe.VerifyBase -or ($lastUser -and $lastUser -ne $Probe.VerifyPrev -and $lastUser.Contains($snip))) { $Probe.VerifyResult = $(if ($lastUser.StartsWith($snip)) { 'landed' } else { 'landed (inside a longer message?)' }); $Probe.VerifySnip = '' }
                    elseif ($lastUser -and $lastUser -ne $Probe.VerifyPrev) { $Probe.VerifyResult = 'landed (new message, text differs)'; $Probe.VerifySeen = $lastUser; $Probe.VerifySnip = '' }
                    elseif ($appQueued -and -not $Probe.VerifyHadQueue) { $Probe.VerifyResult = 'queued in the app (it sends when Claude finishes)'; $Probe.VerifySnip = '' }
                    elseif ((Get-Date) -gt $Probe.VerifyUntil) { $Probe.VerifyResult = 'not seen'; $Probe.VerifySnip = '' }
                }
                $Probe.LastUser = $lastUser; $Probe.AppQueued = $appQueued
                # Cowork question card (AskUserQuestion) = rounded-composer + cds-question group holding 'group/row' choice buttons, an 'other' Edit and a skip button
                $ask = $null
                if ($qOpt.Count) {
                    $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker; $card = $null
                    foreach ($qo in $qOpt) { $cd0 = $tw.GetParent($qo); for ($kq = 0; $kq -lt 4 -and $cd0 -and -not ([string]$cd0.Current.ClassName -match 'rounded-composer.*cds-question'); $kq++) { $cd0 = $tw.GetParent($cd0) }; if ($cd0 -and [string]$cd0.Current.ClassName -match 'rounded-composer.*cds-question') { $card = $cd0; break } }     # other 'group/row' buttons (sidebar) ignored
                    if ($card) {
                        $cball = @($card.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnC)); $cb = @($cball | Where-Object { -not ([string]$_.Current.ClassName -like 'group/row *') })
                        $ask = @{ T = [string]$card.Current.Name; O = @($cball | Where-Object { [string]$_.Current.ClassName -like 'group/row *' } | ForEach-Object { [string]$_.Current.Name }); Skip = $(if ($cb.Count -gt 1) { [string]$cb[-1].Current.Name } else { '' }); Page = $page }
                    }
                }
                $wantCards = (Get-Date) -lt $Probe.CardsUntil     # request-card scans only while a local chat's tool call waits
                if (-not $ask -and $wantCards) {     # any other card above the composer (permission / approval / connector requests...): its text + all its buttons, whatever the language
                    $grpC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group)
                    foreach ($g in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $grpC))) {
                        if (-not ([string]$g.Current.ClassName -match 'rounded-composer')) { continue }
                        $gEd = @($g.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, 'tiptap ProseMirror'))))
                        if ($gEd.Count) { continue }                                   # the normal message box, not a request
                        $gb = @(@($g.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnC)) | Where-Object { $_.Current.IsEnabled -and ([string]$_.Current.Name).Trim() } | ForEach-Object { ([string]$_.Current.Name).Trim() })
                        if (-not $gb.Count -or @($gb | Where-Object { $_ -match '(?i)^(mod.le|model)\b|microphone|dicter|dictate|joindre|attach' }).Count) { continue }     # composer chrome, not a request
                        $gt = ([string]$g.Current.Name).Trim()
                        if (-not $gt) { $gt = (@(@($g.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txtC)) | ForEach-Object { [string]$_.Current.Name } | Where-Object { $_ }) -join ' ') -replace '\s+', ' ' }
                        if ($gt.Length -gt 600) { $gt = $gt.Substring(0, 600) + '...' }
                        $ask = @{ T = $(if ($gt) { $gt } else { 'Claude Desktop asks' }); O = @($gb | Select-Object -Unique); Skip = ''; Page = $page; Gen = $true }; break
                    }
                }
                if (-not $ask -and $wantCards) {     # inline request card (permission, folder access...): Text + Button children of the conversation scroller, after the message list
                    $grpC2 = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group)
                    $tw2 = [System.Windows.Automation.TreeWalker]::ControlViewWalker; $fbRx = '(?i)comment se passe|how.s this|session going|feedback|commentaires'
                    foreach ($sc in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $grpC2))) {
                        if (-not ([string]$sc.Current.ClassName).StartsWith('overflow-y-auto')) { continue }
                        $kids = @(); $ch = $tw2.GetFirstChild($sc); while ($ch) { $kids += $ch; $ch = $tw2.GetNextSibling($ch) }
                        $start = 0; for ($ki = 0; $ki -lt $kids.Count; $ki++) { if ($kids[$ki].Current.ControlType -eq [System.Windows.Automation.ControlType]::Group -and ([string]$kids[$ki].Current.Name).Trim()) { $start = $ki + 1; break } }
                        $blocks = @(); $bt = @(); $bb = @()
                        for ($ki = $start; $ki -lt $kids.Count; $ki++) {
                            $kq = $kids[$ki]; $kct = $kq.Current.ControlType; $kcl = [string]$kq.Current.ClassName
                            $kb = @(); $kt = ''
                            if ($kct -eq [System.Windows.Automation.ControlType]::Button) { $kb = @(([string]$kq.Current.Name).Trim()) }
                            elseif ($kct -eq [System.Windows.Automation.ControlType]::Text) { $kt = [string]$kq.Current.Name }
                            elseif ($kct -eq [System.Windows.Automation.ControlType]::Group) {
                                if ($kcl -eq 'contents') { $kb = @(@($kq.FindAll([System.Windows.Automation.TreeScope]::Descendants, $btnC)) | ForEach-Object { ([string]$_.Current.Name).Trim() }) }
                                else { $kt = (@(@($kq.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txtC)) | ForEach-Object { [string]$_.Current.Name }) -join ' ') }
                            }
                            if ($kt -and $bb.Count) { $blocks += ,@{ T = ($bt -join ' '); B = $bb }; $bt = @(); $bb = @() }
                            if ($kt) { $bt += $kt }; if ($kb.Count) { $bb += @($kb | Where-Object { $_ }) }
                        }
                        if ($bb.Count) { $blocks += ,@{ T = ($bt -join ' '); B = $bb } }
                        foreach ($bk in $blocks) {
                            $bkt = (([string]$bk.T) -replace '\s+', ' ').Trim(); if ($bkt -match $fbRx) { continue }
                            if ($bkt.Length -gt 600) { $bkt = $bkt.Substring(0, 600) + '...' }
                            $ask = @{ T = $(if ($bkt) { $bkt } else { 'Claude Desktop asks' }); O = @($bk.B | Select-Object -Unique); Skip = ''; Page = $page; Gen = $true; Inline = $true }; break
                        }
                        if ($ask) { break }
                    }
                }
                $Probe.Ask = $ask
                # live answer: text nodes after the last user message (only while working / shortly after, it's the heavier walk)
                if (-not $Probe.NoLive -and ($work -or ((Get-Date) - $Probe.LiveAt).TotalSeconds -lt 8)) {     # live reply text: only the classic panel uses it
                    if ($work) { $Probe.LiveAt = Get-Date }
                    # walk the page in order: text after the last user message, up to the end of Claude's reply
                    # (its action buttons, or the composer) - anything after that is app chrome (feedback prompts, hints)
                    $all = $r.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
                    $buf = New-Object System.Collections.Generic.List[string]; $state = 0     # 0 before, 1 in Claude's reply, 2 ended
                    foreach ($el in $all) {
                        $ct = $el.Current.ControlType; $nm = [string]$el.Current.Name
                        if ($ct -eq [System.Windows.Automation.ControlType]::Button -and $nm -match '(?i)(vous avez dit|you said)\s*:') { $buf.Clear(); $state = 1; continue }
                        if ($state -ne 1) { continue }
                        if ($ct -eq [System.Windows.Automation.ControlType]::Edit) { $state = 2; continue }
                        if ($ct -eq [System.Windows.Automation.ControlType]::Button -and $nm -match '(?i)^(bonne r[eé]ponse|mauvaise r[eé]ponse|good response|bad response|copier|copy|r[eé]essayer|retry|envoyer|send|arr[eê]ter|stop)') { $state = 2; continue }
                        if ($ct -ne [System.Windows.Automation.ControlType]::Text -or -not $nm) { continue }
                        if ($nm -match '(?i)^(claude (a termin|a r[eé]pondu|est une ia|finished|replied|can make|is an ai))|session going|se passe cette session|comment se passe|how.s this|feedback|commentaires') { continue }
                        $buf.Add($nm)
                    }
                    $lt = ($buf -join ' ') -replace '\s+', ' '
                    if ($lt.Length -gt 1200) { $lt = '...' + $lt.Substring($lt.Length - 1200) }
                    $Probe.LiveText = $lt; $Probe.LivePage = $page
                }
                if ($diag) {                                  # after a send: record what the app shows while Claude starts (to learn the 'thinking' state)
                    $st = @(); foreach ($el in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $txtC))) { $nm = [string]$el.Current.Name; if ($nm -match '(?i)^(claude (a termin|r[eé]fl[eé]ch|est en train|r[eé]pond|is thinking|is working|finished))|^(r[eé]flexion|thinking)') { $st += $nm.Substring(0, [Math]::Min(40, $nm.Length)) } }
                    $sig = ($allBtn -join ' | ') + ' // ' + ($st -join ' | ')
                    if ($sig -ne $Probe.DiagSig) { $Probe.DiagSig = $sig; $Probe.DiagLog.Add(('{0:HH:mm:ss.fff} +{1:0.0}s buttons=[{2}] status=[{3}]' -f (Get-Date), ((Get-Date) - $Probe.ExpectAt).TotalSeconds, ($allBtn -join ' | '), ($st -join ' | '))) }
                }
                if ($work) { $idleN = 0; $Probe.SawStop = $true } else { $idleN++ }
                # expectation: right after a delivered send Claude is starting even if the stop button isn't there yet
                if (-not $work -and -not $Probe.SawStop -and ((Get-Date) - $Probe.ExpectAt).TotalSeconds -lt 30 -and $page -eq $Probe.ExpectPage) { $work = $true; $Probe.Starting = $true } else { $Probe.Starting = $false }
                $work = $work -or ($Probe.Working -and $idleN -lt 2 -and $page -eq $Probe.Page)
                $Probe.Page = $page; $Probe.Working = $work; $Probe.StopName = $stopName; $Probe.Buttons = ($names | Select-Object -Unique) -join ' | '; $Probe.At = Get-Date; $Probe.Err = ''
            }
        } catch { $Probe.Err = $_.Exception.Message }
        $Probe.Ms = $t0.ElapsedMilliseconds
        $ms = if ($Probe.VerifySnip -or ($Probe.Fast -and $Probe.Working)) { 450 } elseif ($Probe.Fast -or (Get-Date) -lt $Probe.FastUntil) { 800 } else { 1500 }
        Start-Sleep -Milliseconds $ms
    }
}
$probeRs = [runspacefactory]::CreateRunspace(); $probeRs.ApartmentState = 'MTA'; $probeRs.Open()
$probePs = [powershell]::Create(); $probePs.Runspace = $probeRs; [void]$probePs.AddScript($probeScript).AddArgument($Probe)
$probeHandle = $probePs.BeginInvoke()
# ---------------------------------------------------------------- web watcher: the same chats in a browser the tray controls (Edge + DevTools protocol)
# Edge runs with its own profile (browser-profile\, signed in once by the user), a debug port bound to 127.0.0.1 only, and its
# window off-screen. One tab per tracked chat. Exact reply text and generating state for EVERY chat, without touching the app.
# Content stays in memory: only lengths/timings are logged.
$Web = [hashtable]::Synchronized(@{ Ok = $false; Err = ''; Chats = [hashtable]::Synchronized(@{}); Want = @(); Stop = $false; Log = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Port = [int]$Cfg.webPort; Profile = (Join-Path $Root 'browser-profile'); Ms = 0; Headless = ([string]$Cfg.webWindow -ne 'visible'); Checked = $false; OpenedAt = @{}; LaunchedHeadless = $false; Cmds = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList)); Results = [hashtable]::Synchronized(@{}) })
$Web.Alias = [hashtable]::Synchronized(@{}); if ($QS.AliasIn) { foreach ($ak in $QS.AliasIn.Keys) { $Web.Alias[$ak] = $QS.AliasIn[$ak] } }     # chats claude.ai moved to a new address (kept across restarts)
$webScript = {
    param($Web)
    function WL([string]$m) { [void]$Web.Log.Add(('{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m)) }
    # debug port: random per launch (a fixed, known port would let any local program drive the signed-in browser);
    # after a tray restart, find the port of the Edge that runs our profile
    $port = [int]$Web.Port
    if ($port -le 0) {
        $own = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$($Web.Profile)*" -and $_.CommandLine -match 'remote-debugging-port=(\d+)' })
        if ($own.Count -and ($own[0].CommandLine -match 'remote-debugging-port=(\d+)')) { $port = [int]$Matches[1]; WL "found our Edge on port $port" }
        else { $port = Get-Random -Minimum 20000 -Maximum 60000 }
    }
    $Web.Port = $port; $base = "http://127.0.0.1:$port"
    $socks = @{}                                            # targetId -> ClientWebSocket
    $script:cid = 0
    function Cdp($ws, [string]$method, $params) {
        $script:cid++; $my = $script:cid
        $msg = @{ id = $my; method = $method; params = $params } | ConvertTo-Json -Depth 8 -Compress
        $b = [Text.Encoding]::UTF8.GetBytes($msg)
        if (-not $ws.SendAsync((New-Object ArraySegment[byte] (, $b)), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000)) { throw 'send timeout' }
        $buf = New-Object byte[] 262144
        while ($true) {
            $ms = New-Object IO.MemoryStream
            do { $r = $ws.ReceiveAsync((New-Object ArraySegment[byte] (, $buf)), [Threading.CancellationToken]::None); if (-not $r.Wait(8000)) { throw "timeout $method" }; $ms.Write($buf, 0, $r.Result.Count) } while (-not $r.Result.EndOfMessage)
            $o = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
            if ($o.id -eq $my) { return $o }
        }
    }
    $js = @'
(() => {
  const qa = s => Array.from(document.querySelectorAll(s));
  const composer = document.querySelector('div.ProseMirror[contenteditable="true"]');
  // working = the composer's own stop button (a 'Stop…' button elsewhere on the page - a message, a menu - doesn't count)
  const isStop = b => /^(stop|arr[eê]t)/i.test((b.getAttribute('aria-label') || '').trim()) && !b.closest('[data-testid="user-message"], [data-testid="assistant-message"], .font-claude-response');
  let stop = false; for (let a = composer, i = 0; a && i < 8 && !stop; a = a.parentElement, i++) stop = Array.from(a.querySelectorAll('button')).some(isStop);
  if (!composer) stop = qa('button').some(isStop);
  // paint clock: a background tab whose frames stop is a frozen tab (diagnostic for 'working' that never ends)
  if (!window.__ctRafOn) { window.__ctRafOn = 1; const f = () => { window.__ctRaf = Date.now(); requestAnimationFrame(f); }; requestAnimationFrame(f); }
  const streamingEl = document.querySelector('[data-is-streaming="true"]');
  const users = qa('[data-testid="user-message"]');
  const replies = qa('[data-testid="assistant-message"], .font-claude-response, .font-claude-message');
  const clean = t => (t || '').replace(/^\s*(Claude a répondu|Claude replied)\s*:\s*/i, '').replace(/\n{3,}/g, '\n\n').trim();
  const lastUser = users.length ? users[users.length - 1] : null;
  // Claude's current reply = every assistant block after the last user message (document order)
  const after = replies.filter(r => !lastUser || (lastUser.compareDocumentPosition(r) & Node.DOCUMENT_POSITION_FOLLOWING));
  // reply text without the turn heading / step rows / screen-reader labels / the tray's own quest block (previews show only what Claude wrote)
  const isQ = t => /^\s*\{[\s\S]*"steps"\s*:/.test(t || '') && /"v"\s*:\s*1/.test(t || '');
  const txtOf = r => { let tx = r.innerText || ''; for (const e of r.querySelectorAll('[class~="group/status"], .sr-only, [role="button"][aria-expanded], pre')) { if (e.tagName === 'PRE' && !isQ(e.textContent)) continue; const s0 = e.innerText; if (s0 && s0.trim()) tx = tx.replace(s0, ''); } return tx; };
  let reply = after.map(r => clean(txtOf(r))).filter(Boolean).join('\n\n');
  // what Claude is doing right now: its last step row (tool use / status) in the current reply
  const vis = e => !!(e && e.offsetParent !== null);
  const lastRep = after[after.length - 1];
  let act = '';
  const ts = lastRep && (lastRep.querySelector('[class~="group/status"]') || lastRep.querySelector('[data-testid*="TurnStatus" i]'));
  let tsh = ts; for (let k = 0; tsh && k < 3 && !(tsh.textContent || '').trim() && tsh.parentElement && tsh.parentElement !== lastRep; k++) tsh = tsh.parentElement;     // the mark is empty: its row holds the words
  if (tsh && !ts.contains(tsh)) { const tw = document.createTreeWalker(tsh, NodeFilter.SHOW_TEXT); let tt = '', nd; while ((nd = tw.nextNode())) { const pe = nd.parentElement; if (pe && !pe.closest('button, .sr-only')) tt += nd.textContent; } act = tt.replace(/\s+/g, ' ').trim(); }
  else if (ts) { const tw = document.createTreeWalker(ts, NodeFilter.SHOW_TEXT); let tt = '', nd; while ((nd = tw.nextNode())) { const pe = nd.parentElement; if (pe && !pe.closest('button, .sr-only')) tt += nd.textContent; } act = tt.replace(/\s+/g, ' ').trim(); }
  if (!act && lastRep) { const rows = Array.from(lastRep.querySelectorAll('[role="button"], [aria-expanded], summary')).filter(vis); const r0 = rows[rows.length - 1]; if (r0) act = (r0.innerText || '').split('\n').map(x => x.trim()).filter(Boolean).pop() || ''; }
  // buttons the page wants you to press (permission prompts, continue...): dialogs + around the last reply
  const PR = /^(allow|always allow|allow once|allow for this chat|autoriser|toujours autoriser|autoriser une fois|deny|don.t allow|refuser|ne pas autoriser|decline|approve|approuver|reject|rejeter|continue|continuer|yes|oui|no|non|accept|accepter|cancel|annuler|send now|envoyer maintenant)\b/i;
  const zones = qa('[role="dialog"], [role="alertdialog"], [data-testid*="permission" i], [data-testid*="approval" i]'); if (lastRep) { zones.push(lastRep); if (lastRep.parentElement) zones.push(lastRep.parentElement.parentElement || lastRep.parentElement); }
  if (composer) { let cz = composer; for (let i = 0; i < 7 && cz.parentElement; i++) cz = cz.parentElement; zones.push(cz); }     // queued message: 'Send now' sits by the message box
  const pb = []; for (const z of zones) for (const b of z.querySelectorAll('button')) { const tx = (b.innerText || b.getAttribute('aria-label') || '').trim().split('\n')[0]; if (tx.length < 40 && PR.test(tx) && vis(b) && !b.disabled && !b.closest('[data-testid="user-message"]') && !pb.includes(b)) pb.push(b); }
  window.__ctPrompts = pb;
  // a question with choices (Claude Code's multiple-choice prompt), found by structure: radios / checkboxes / options near the message box or the last reply
  let qn = null; window.__ctQ = null;
  // claude.ai's own card (seen 2026-10): [data-testid=hub-ask-user-question-card] in the composer dock > [data-cds=AskUserQuestion] (role=group):
  //   label span (aria-labelledby) · nav: prev / "N sur M" / next buttons · options = button[aria-pressed] (bdi[0] label, bdi[1] description) · form input "Other" + skip button
  const qcard = document.querySelector('[data-testid="hub-ask-user-question-card"]') || (document.querySelector('[data-cds="AskUserQuestion"]') || {}).parentElement;
  if (qcard && vis(qcard)) {
    const g = qcard.querySelector('[data-cds="AskUserQuestion"]') || qcard, lid = g.getAttribute('aria-labelledby'), le = (lid && document.getElementById(lid)) || g.querySelector('span[id$="-label"]');
    const og = g.querySelector('[role="group"][data-orientation="vertical"]') || g.querySelector('[role="group"]:not([data-cds="AskUserQuestion"])');     // step 1 (single) used button[aria-pressed]; a several-answers step may use checkboxes
    let ob = Array.from(g.querySelectorAll('button[aria-pressed], [role="checkbox"], [role="menuitemcheckbox"], [role="radio"], input[type="checkbox"], input[type="radio"], button[aria-checked]')).filter(e => vis(e.matches('input') ? (e.closest('label') || e.parentElement) : e) && !e.closest('form'));
    if (!ob.length && og) ob = Array.from(og.querySelectorAll('button, [role="button"], label')).filter(vis);
    ob = ob.filter(e => !ob.some(o => o !== e && o.contains(e)) && !(e.matches('input') && e.parentElement && e.parentElement.querySelector('[role="checkbox"], [role="radio"]')));     // one per choice: the button / the span[role=checkbox], not the hidden input next to it
    const stp = Array.from(g.querySelectorAll('span')).map(s => (s.children.length ? '' : (s.textContent || '').trim())).find(x => /^\d+\s*\D{1,6}\s*\d+$/.test(x)) || '';
    const sm = stp.match(/(\d+)\D+(\d+)/), stN = sm ? +sm[1] : 1, stM = sm ? +sm[2] : 1;
    let nx = null, pv = null; const stEl = Array.from(g.querySelectorAll('span')).find(s => !s.children.length && (s.textContent || '').trim() === stp && stp); if (stEl && stEl.parentElement) { const bs = Array.from(stEl.parentElement.querySelectorAll('button')); pv = bs[0] || null; nx = bs[bs.length - 1] || null; }
    const fi = g.querySelector('form input[type="text"], form textarea'); let skip = fi ? (fi.closest('label') || fi.parentElement).querySelector('button') : null;
    // several-answers step: a footer with span[role=status] (how many picked), a text button (skip) and an icon button (send, disabled until you pick)
    const stS = g.querySelector('span[role="status"]'), fb = stS && stS.parentElement ? Array.from(stS.parentElement.querySelectorAll('button')).filter(vis) : [];
    const fSub = fb.filter(b => (b.innerText || '').trim().length <= 1).pop() || null; if (!skip) skip = fb.find(b => (b.innerText || '').trim().length > 1) || null;     // icon buttons hold one glyph
    const SBR = /^(submit|send|envoyer|soumettre|valider|confirm|confirmer|terminer|done|finish|répondre|reply)/i;
    const sb0 = fSub || Array.from(g.querySelectorAll('button')).find(b => vis(b) && !b.disabled && !ob.includes(b) && b !== nx && b !== pv && b !== skip && SBR.test(((b.innerText || '') + ' ' + (b.getAttribute('aria-label') || '')).trim())) || null;
    window.__ctQ = { o: ob, next: nx && !nx.disabled && nx !== pv ? nx : null, prev: pv && !pv.disabled && pv !== nx ? pv : null, skip: skip, sub: sb0, card: true };
    const multi0 = ob.some(e => /checkbox/.test((e.getAttribute('role') || '') + (e.type || '')) || e.hasAttribute('aria-checked'));
    qn = { t: ((le && le.innerText) || '').trim().slice(0, 220), step: stN, steps: stM, next: !!window.__ctQ.next, prev: !!window.__ctQ.prev, skip: skip ? (skip.innerText || '').trim().slice(0, 20) : '', multi: multi0, sub: sb0 ? (((sb0.innerText || sb0.getAttribute('aria-label') || '').trim().split('\n')[0].slice(0, 24)) || 'Send answers') : '', subOk: !!(sb0 && !sb0.disabled), card: true,
      o: ob.slice(0, 8).map(b => { const bd = Array.from(b.querySelectorAll('bdi')).map(x => (x.innerText || '').trim()); const ls = bd.length ? bd : (b.innerText || '').split('\n').map(x => x.trim()).filter(x => x && !/^\d+$/.test(x)); return { l: (ls[0] || (b.innerText || '').trim()).slice(0, 60), d: (ls[1] || '').slice(0, 160), s: b.getAttribute('aria-pressed') === 'true' || b.getAttribute('aria-checked') === 'true' || !!b.checked || /^(checked|on)$/.test(b.getAttribute('data-state') || '') }; }) };
  }
  if (!qn) { const qz = qa('[role="dialog"], [role="alertdialog"]'); if (composer) { let cz = composer; for (let i = 0; i < 8 && cz.parentElement; i++) cz = cz.parentElement; qz.push(cz); } if (lastRep && lastRep.parentElement) qz.push(lastRep.parentElement);
    const OS = '[role="radio"], [role="checkbox"], [role="option"], [role="menuitemradio"], [role="menuitemcheckbox"], input[type="radio"], input[type="checkbox"]';
    const lab = e => e.matches('input') ? (e.closest('label') || (e.id && document.querySelector('label[for="' + CSS.escape(e.id) + '"]')) || e.parentElement) : e;
    let os = []; for (const z of qz) for (const e of z.querySelectorAll(OS)) if (!os.includes(e) && vis(lab(e)) && !e.closest('[data-testid="user-message"], [cmdk-root], [data-testid="model-selector-dropdown"], nav, aside, header, [role="navigation"]') && (lab(e).innerText || '').trim()) os.push(e);
    const grp = e => e.closest('[role="radiogroup"], [role="listbox"], [role="group"], fieldset') || (e.parentElement && e.parentElement.parentElement) || e.parentElement;
    const by = new Map(); for (const e of os) { const g = grp(e); if (!by.has(g)) by.set(g, []); by.get(g).push(e); }
    let best = null; for (const [g, l] of by) if (l.length >= 2 && l.length <= 12 && (!best || l.length > best[1].length)) best = [g, l];
    if (best) {
      const [g, l] = best; const bad = s => s.matches('[data-testid="assistant-message"], [data-testid="user-message"], nav, aside, header') || !!s.querySelector('[data-testid="assistant-message"], [data-testid="user-message"]') || (composer && s.contains(composer));
      let qt = g.innerText || ''; for (const e of l) { const s0 = lab(e).innerText; if (s0) qt = qt.replace(s0, ''); } if (composer && g.contains(composer)) qt = qt.replace(composer.innerText || '', '');     // the question: text in the group besides the choices, else the closest text before it
      for (const bt of g.querySelectorAll('button')) if (!l.includes(bt)) qt = qt.replace(bt.innerText || '', '');
      for (let n = g, i = 0; n && i < 4 && !qt.trim(); n = n.parentElement, i++) for (let s = n.previousElementSibling; s && !qt.trim(); s = s.previousElementSibling) { if (!bad(s)) qt = s.innerText || ''; }
      const SB = /^(submit|send|envoyer|valider|soumettre|next|suivant|continue|continuer|confirm|confirmer|done|terminé|ok)\b/i; let sb = null; let sx = g; for (let i = 0; i < 5 && sx && !sb; sx = sx.parentElement, i++) sb = Array.from(sx.querySelectorAll('button')).find(b => vis(b) && !b.disabled && SB.test((b.innerText || b.getAttribute('aria-label') || '').trim()) && !l.includes(b)) || null;
      const multi = l.some(e => /checkbox/.test(e.getAttribute('role') || e.type || '')) || g.getAttribute('aria-multiselectable') === 'true';
      window.__ctQ = { o: l, sub: sb };
      qn = { t: qt.split('\n').map(x => x.trim()).filter(x => x && x.length > 3).slice(0, 2).join(' ').slice(0, 220), multi: multi, sub: sb ? (sb.innerText || sb.getAttribute('aria-label') || '').trim().split('\n')[0].slice(0, 20) : '',
        o: l.slice(0, 8).map(e => { const ls = (lab(e).innerText || '').split('\n').map(x => x.trim()).filter(Boolean); return { l: (ls[0] || '').slice(0, 60), d: ls.slice(1).join(' ').slice(0, 160), s: e.getAttribute('aria-checked') === 'true' || e.getAttribute('aria-selected') === 'true' || !!e.checked || e.getAttribute('data-state') === 'checked' }; }) };
    } }
  // bridge mode: the quest as a ```tray-quest block at the end of Claude's reply (chat can't reach the PC folder)
  let quest = '';
  let qtag = false;
  for (const r of after) for (const c of r.querySelectorAll('pre code, code')) { const tx = (c.textContent || '').trim(); const tagged = /tray-quest/i.test(c.className || '') || /^\s*tray-quest\b/i.test(((c.closest('pre') || c).parentElement || {}).textContent || '') || /^\s*tray-quest\b/i.test((((c.closest('pre') || c).parentElement || {}).parentElement || {}).textContent || '');
    if (/^\{[\s\S]*"steps"\s*:/.test(tx) && /"v"\s*:\s*1/.test(tx) && tx.length < 20000) { quest = tx; qtag = tagged; }     /* untagged blocks only count in chats with /tray on (the tray checks) */ }
  reply = reply.replace(/(tray-quest\s*)?\{\s*"v"\s*:\s*1[\s\S]*?"steps"[\s\S]*$/, '').replace(/\btray-quest\s*$/i, '').trim();     // a quest is for the tray, never a preview
  const ms = document.querySelector('[data-testid="model-selector-dropdown"]');
  return JSON.stringify({ qtag: qtag, t: document.title, vs: document.visibilityState, raf: window.__ctRaf ? Date.now() - window.__ctRaf : -1, foc: document.hasFocus(), ok: !!composer, stop: stop, streaming: !!streamingEl, users: users.length, replies: replies.length,
    lastUser: lastUser ? lastUser.innerText.slice(0, 80) : '', reply: reply.slice(-4000), rl: reply.length, cf: /just a moment|un instant/i.test(document.title),
    act: act.slice(0, 90), prompts: pb.map(b => (b.innerText || b.getAttribute('aria-label') || '').trim().split('\n')[0]).slice(0, 6), q: qn,
    model: ms ? (ms.innerText || '').trim().split('\n')[0].slice(0, 40) : '', retry: !!document.querySelector('[data-testid="action-bar-retry"]'), quest: quest });
})()
'@
    # new chat from the tray: projects list, then create (claude.ai internal endpoints, with the page's own session)
    $catJs = @'
(async () => {
  const j = async u => { const r = await fetch(u, { credentials: 'include' }); if (!r.ok) throw new Error(u.replace(/[0-9a-f-]{36}/g, '<id>') + ' ' + r.status); return r.json(); };
  const orgs = await j('/api/organizations');
  const ck = decodeURIComponent((document.cookie.match(/lastActiveOrg=([^;]+)/) || [])[1] || '');
  const org = orgs.find(o => o.uuid === ck) || orgs.find(o => (o.capabilities || []).includes('chat')) || orgs[0];
  let projects = [], perr = '';
  try { const p = await j('/api/organizations/' + org.uuid + '/projects'); projects = (Array.isArray(p) ? p : (p.data || p.projects || [])).filter(x => !x.archived_at && !x.is_archived).map(x => ({ id: x.uuid, name: x.name })); } catch (e) { perr = String(e.message || e); }
  let recent = []; try { const rc = await j('/api/organizations/' + org.uuid + '/chat_conversations?limit=300'); recent = (Array.isArray(rc) ? rc : (rc.data || [])).map(x => ({ id: x.uuid, name: x.name || '', p: x.project_uuid || (x.project && x.project.uuid) || '', at: x.updated_at || '' })); } catch (e) { }
  return JSON.stringify({ org: org.uuid, projects: projects, perr: perr, orgs: orgs.length, recent: recent });
})()
'@
    $catProjJs = @'
(async (org, pid) => {
  const j = async u => { const r = await fetch(u, { credentials: 'include' }); if (!r.ok) throw new Error(String(r.status)); return r.json(); };
  let rows = null, err = '';
  for (const u of ['/api/organizations/' + org + '/projects/' + pid + '/conversations', '/api/organizations/' + org + '/chat_conversations?limit=200&project_uuid=' + pid]) {
    try { const d = await j(u); const a = Array.isArray(d) ? d : (d.data || d.conversations || []); rows = a.filter(x => !x.project_uuid || x.project_uuid === pid).map(x => ({ id: x.uuid, name: x.name || '', p: pid, at: x.updated_at || '' })); break; } catch (e) { err = String(e.message || e); }
  }
  return JSON.stringify({ pid: pid, rows: rows || [], err: rows ? '' : err });
})
'@
    # model / effort of an open chat: read the page's model menu, or pick in it (labels only - UI text, no chat content)
    $modelJs = @'
(async (mode, kind, name) => {
  const sleep = ms => new Promise(r => setTimeout(r, ms)), vis = e => !!(e && e.offsetParent !== null);
  const lines = e => (e && e.innerText || '').split('\n').map(s => s.trim()).filter(Boolean);
  const btn = document.querySelector('[data-testid="model-selector-dropdown"]') || Array.from(document.querySelectorAll('button[aria-haspopup]')).find(b => /opus|sonnet|haiku|fable|mythos|claude/i.test(b.innerText || ''));
  if (!btn) return JSON.stringify({ err: 'no-selector' });
  const IT = '[role="menuitem"], [role="menuitemradio"], [role="menuitemcheckbox"], [role="option"]';
  const items = () => Array.from(document.querySelectorAll(IT)).filter(vis);
  const esc = async () => { for (const tg of [document.activeElement, document.body]) if (tg) tg.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', code: 'Escape', bubbles: true })); await sleep(220); };
  const MR = /^(claude\s+)?(opus|sonnet|haiku|fable|mythos)\b/i;
  if (mode === 'sub') { const base = window.__ctMMbase || []; const se = items().filter(i => !base.includes(i)); window.__ctMMsub = se; return JSON.stringify({ efforts: se.map(i => lines(i)[0]).filter(Boolean) }); }
  if (mode === 'subpick') { const it = (window.__ctMMsub || []).find(i => lines(i)[0] === name); if (!it) { await esc(); await esc(); return JSON.stringify({ err: 'no-effort' }); } it.click(); await sleep(350); await esc(); return JSON.stringify({ ok: true, cur: lines(btn)[0] || '' }); }
  if (mode === 'close') { await esc(); await esc(); return JSON.stringify({ ok: true, cur: lines(btn)[0] || '' }); }
  if (!items().length) { btn.click(); await sleep(450); }
  const its = items(); window.__ctMMbase = its;
  const models = its.filter(i => MR.test(lines(i)[0] || '')).map(i => lines(i)[0]);
  const sub = its.find(i => !MR.test(lines(i)[0] || '') && (i.getAttribute('aria-haspopup') === 'menu' || i.getAttribute('aria-haspopup') === 'true' || i.hasAttribute('aria-expanded')) && !/more models|plus de mod/i.test(lines(i)[0] || ''));
  const struct = its.map(i => (i.getAttribute('role') || '') + (i.getAttribute('aria-haspopup') ? '^' : '') + (i.getAttribute('aria-checked') === 'true' ? '*' : '') + ':' + (lines(i)[0] || '').slice(0, 30)).join(' | ');
  let rect = null; if (sub) { const r0 = sub.getBoundingClientRect(); rect = { x: Math.round(r0.left + r0.width / 2), y: Math.round(r0.top + r0.height / 2) }; }
  if (mode === 'read' || kind === 'effort') return JSON.stringify({ cur: lines(btn)[0] || '', models: models, sub: sub ? lines(sub)[0] : '', rect: rect, struct: struct.slice(0, 900) });     // the menu stays open: 'sub' / 'close' next
  const it = its.find(i => lines(i)[0] === name); if (!it) { await esc(); return JSON.stringify({ err: 'no-item' }); }
  it.click(); await sleep(350); await esc(); return JSON.stringify({ ok: true, cur: lines(btn)[0] || '' });
})(__MODE__, __KIND__, __NAME__)
'@
    $pickJs = @'
(async (want, think) => {
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const esc = () => document.activeElement && document.activeElement.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
  const btn = document.querySelector('[data-testid="model-selector-dropdown"]') || Array.from(document.querySelectorAll('button[aria-haspopup]')).find(b => /opus|sonnet|haiku|fable|claude/i.test(b.innerText || ''));
  if (!btn) return 'no-selector';
  let r = 'model:' + (btn.innerText || '').trim().split('\n')[0];
  if (want && !(btn.innerText || '').toLowerCase().includes(want.toLowerCase())) {
    btn.click(); await sleep(450);
    const items = Array.from(document.querySelectorAll('[role="menuitem"], [role="option"], [role="menuitemradio"]'));
    const it = items.find(i => (i.innerText || '').toLowerCase().includes(want.toLowerCase()));
    if (it) { it.click(); await sleep(350); r += ' -> ' + (it.innerText || '').trim().split('\n')[0]; } else { esc(); await sleep(150); r += ' -> no-item(' + items.length + ')'; }
  }
  if (think) {
    btn.click(); await sleep(450);
    const t = Array.from(document.querySelectorAll('[role="menuitemcheckbox"], [role="switch"], [role="menuitem"], button')).find(x => /extended thinking|réflexion étendue|thinking|réflexion/i.test((x.innerText || '') + ' ' + (x.getAttribute('aria-label') || '')));
    if (t) { const on = t.getAttribute('aria-checked') === 'true' || t.getAttribute('data-state') === 'checked' || !!t.querySelector('[aria-checked="true"], [data-state="checked"]'); if ((think === 'on') !== on) { t.click(); await sleep(250); } r += ' think:' + (on ? 'was-on' : 'was-off') + '->' + think; } else r += ' think:not-found';
    esc(); await sleep(200);
  }
  return r;
})(__WANT__, __THINK__)
'@
    # files Claude attached to a message (cards / download links). Shared by $msgJs (names) and the 'dl' command (fetch / click).
    $fileJs = @'
(root) => {
  const sel = 'a[download], a[href*="/files/"], a[href*="/download"], a[href^="blob:"], [data-testid*="file" i], [data-testid*="attachment" i], [data-testid*="artifact" i], [data-testid*="download" i]';
  const out = [];
  for (const el of root.querySelectorAll(sel)) {
    if (out.some(o => o.el.contains(el) || el.contains(o.el))) continue;
    const t = ((el.getAttribute('download') || el.getAttribute('aria-label') || el.innerText || el.getAttribute('title') || '') + '').split('\n').map(x => x.trim()).filter(Boolean)[0] || '';
    if (!t || t.length > 120) continue;
    out.push({ el: el, name: t.replace(/^(download|télécharger)\s*/i, '') });
  }
  // file cards without test-ids: a clickable element whose text is a file name ('tray-test.csv')
  const FN = /^[^\\/:*?"<>|\n]{1,80}\.(csv|tsv|txt|md|json|xml|yaml|yml|log|png|jpe?g|gif|webp|svg|pdf|zip|7z|rar|ps1|psm1|bat|cmd|py|js|ts|html?|css|xlsx?|docx?|pptx?|mp3|mp4|wav|blend|fbx|obj)$/i;
  for (const el of root.querySelectorAll('button, a, [role="button"]')) {
    if (out.some(o => o.el.contains(el) || el.contains(o.el))) continue;
    const bits = [el.getAttribute('aria-label') || '', el.getAttribute('title') || ''].concat(Array.from(el.querySelectorAll('*')).filter(x => !x.firstElementChild).map(x => x.textContent || ''), (el.innerText || '').split('\n'));
    const t = bits.map(x => x.trim()).find(x => FN.test(x));
    if (t) out.push({ el: el, name: t });
  }
  return out;
}
'@
    # messages for an open chat view: user text + Claude's reply as whitelisted HTML (tags only, no attributes, no links/images)
    $mdiagJs = @'
(() => {     // STRUCTURE ONLY (privacy): how the page holds the messages (attribute names, numbers) and where tool rows sit (tags, classes, text length) - no text
  const els = Array.from(document.querySelectorAll('[data-testid="user-message"], [data-testid="assistant-message"], .font-claude-response')).filter((e, i, a) => !a.some(o => o !== e && o.contains(e)));
  const sig = e => { const o = []; for (let p = e, k = 0; p && p !== document.body && k < 6; p = p.parentElement, k++) { const at = [...p.attributes].filter(a => /^data-|^aria-(posinset|setsize)$/.test(a.name) && a.name !== 'data-testid').map(a => a.name + (/^\d+$/.test(a.value) ? '=' + a.value : '')); if (at.length) o.push(p.tagName.toLowerCase() + '[' + at.join(',') + ']'); } return o.join('<'); };
  const rk = e => { const ki = e.closest('[data-index]'); return ki ? ki.getAttribute('data-index') + '/' + els.filter(o => ki.contains(o)).length : '-'; };
  const msgs = els.slice(-24).map(e => (e.matches('[data-testid="user-message"]') ? 'U' : 'A') + rk(e));
  const RE = /^(lu|read|enregistr|exécut|ran|running|saving|écrit|wrote|modifi|edited|recherch|searched|créé|created|consult|viewed)/i;
  const path = n => { const o = []; for (let p = n, k = 0; p && k < 9 && !(p.matches && p.matches('[data-testid="assistant-message"], .font-claude-response')); p = p.parentElement, k++) o.push(p.tagName.toLowerCase() + (p.getAttribute('data-testid') ? '#' + p.getAttribute('data-testid') : '') + (p.getAttribute('role') ? '[' + p.getAttribute('role') + ']' : '') + (p.hasAttribute('aria-expanded') ? '{ae}' : '') + '.' + String(p.getAttribute('class') || '').split(/\s+/).filter(Boolean).slice(0, 5).join('.')); return o.join(' < '); };
  const rows = []; for (const e of els.slice(-4)) for (const n of e.querySelectorAll('*')) { const t = (n.textContent || '').trim(); if (t.length < 200 && RE.test(t) && ![...n.children].some(c => RE.test((c.textContent || '').trim()))) rows.push('len' + t.length + ' ' + path(n)); }
  return 'MDIAG msgs ' + els.length + ' :: ' + msgs.join(' | ') + ' || ROWS ' + rows.slice(-6).join(' | ');
})()
'@
    $msgJs = @'
((n) => {
  const KEEP = new Set(['P','BR','UL','OL','LI','PRE','CODE','STRONG','B','EM','I','H1','H2','H3','H4','H5','H6','TABLE','THEAD','TBODY','TR','TH','TD','BLOCKQUOTE','HR','DEL','S']);
  const DROP = new Set(['BUTTON','SVG','IMG','INPUT','TEXTAREA','SELECT','STYLE','SCRIPT','NOSCRIPT','TIME','IFRAME','VIDEO','AUDIO','CANVAS','FORM','LABEL','PICTURE','OBJECT']);
  const junk = /^(il y a .*|à l.instant|just now|.* ago|\d+\s*(s|sec|min|h|j|d)\b.*|modifié|edited|copié|copied|copy|copier|claude réfléchit.*|claude is thinking.*|thinking…?|réflexion…?|en cours d.exécution…?|exécution en cours…?|exécutant (une|des|la) commandes?…?|running( a| the)? commands?…?|running…?|compétence chargée|skill loaded|commande exécutée.*|command (ran|executed).*|ran a command.*|(utilisé|used) (computer|l.ordinateur).*|fichier (lu|modifié|créé).*|(read|edited|created) a file.*|tray-quest)$/i;
  const escT = t => t.replace(/[&<>]/g, x => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[x]));
  const SPIN = /^[\p{L}'’-]{3,24}(…|\.\.\.)$/u;     // Claude Code's spinner word ('Déchiffrage…', 'Pondering…'): status, not text
  const STEPS = /^(utilisé|used|lu|read|exécuté|ran|run|modifié|edited|recherché|searched|créé|created|écrit|wrote|consulté|viewed|fetched|récupéré)(?=[\s,:])[^.!?]*?(?:^|[\s,])(\d+|un|une|a|an)\s+(étapes?|steps?|commandes?|commands?|fichiers?|files?|recherches?|searches?|outils?|tools?)\b[^.!?]*$/i;
  const ser = el => {
    let o = '';
    for (const c of el.childNodes) {
      if (c.nodeType === 3) { o += escT(c.textContent); continue; }
      if (c.nodeType !== 1) continue;
      const t = c.tagName.toUpperCase();
      if (DROP.has(t) || c.hidden || c.getAttribute('aria-hidden') === 'true' || /\bsr-only\b/.test(c.getAttribute('class') || '') || c.getAttribute('role') === 'button' || c.hasAttribute('aria-expanded') || t === 'SUMMARY') continue;
      if (!c.firstElementChild && junk.test((c.textContent || '').trim()) && (c.textContent || '').length < 40) continue;
      if (t === 'PRE' && /"v"\s*:\s*1/.test(c.textContent || '') && /"steps"\s*:/.test(c.textContent || '')) continue;      // bridge-mode quest block: the tray turns it into steps
      if (!c.firstElementChild && /^tray-quest$/i.test((c.textContent || '').trim())) continue;
      if (/(^|\s)group\/status(\s|$)/.test(c.getAttribute('class') || '')) continue;      // claude.ai turn heading ('Designing ...'): shown as the activity line instead
      if (c.querySelector('[data-testid*="TurnStatus" i]') && (c.textContent || '').trim().length < 120) continue;     // the turn status row around its animated mark
      if (!c.firstElementChild && SPIN.test((c.textContent || '').trim())) continue;
      if (/TurnStatus/i.test(c.getAttribute('data-testid') || '') || (STEPS.test((c.textContent || '').trim()) && (c.textContent || '').length < 200)) continue;    // Claude Code: turn heading / 'ran 8 commands, 3 more steps'
      const inner = ser(c);
      if (t === 'A' && /^https?:\/\//i.test(c.getAttribute('href') || '')) { o += '<a data-href="' + escT(c.href).replace(/"/g, '&quot;') + '">' + inner + '</a>'; continue; }
      if (t === 'BR' || t === 'HR') o += '<' + t.toLowerCase() + '>';
      else if (KEEP.has(t)) o += '<' + t.toLowerCase() + '>' + inner + '</' + t.toLowerCase() + '>';
      else if (getComputedStyle(c).display === 'block' && inner.trim() && !/^\s*<(p|ul|ol|pre|table|h\d|blockquote|div)/.test(inner)) o += '<div>' + inner + '</div>';
      else o += inner;
    }
    return o;
  };
  const clean = t => (t || '').replace(/^\s*(Claude a répondu|Claude replied|Vous avez dit|You said)\s*:\s*/i, '').split('\n').filter(l => { const x = l.trim(); return !junk.test(x) && !STEPS.test(x) && !SPIN.test(x) && !(x.length <= 2 && !/[\p{L}\p{N}]/u.test(x)); }).join('\n').replace(/\n{3,}/g, '\n\n').trim();
  const els = Array.from(document.querySelectorAll('[data-testid="user-message"], [data-testid="assistant-message"], .font-claude-response')).filter((e, i, a) => !a.some(o => o !== e && o.contains(e)));
  const base = Math.max(0, els.length - n);
  const out = els.slice(-n).map((e, j) => {
    const u = e.matches('[data-testid="user-message"]');
    const m = { r: u ? 'u' : 'a', t: clean(e.innerText).slice(0, 12000), x: base + j };
    { const ki = e.closest('[data-index]'); if (ki && /^\d+$/.test(ki.getAttribute('data-index')) && els.filter(o => ki.contains(o)).length === 1) m.k = +ki.getAttribute('data-index'); }     // claude.ai's row number (only if that row holds just this message): the list keeps only some rows, this says where each one sits
    { let tm = e.querySelector('time[datetime]'); for (let p = e.parentElement, k = 0; !tm && p && k < 4; p = p.parentElement, k++) { const all = p.querySelectorAll('time[datetime]'); const own = [...all].filter(t => !t.closest('[data-testid="user-message"], [data-testid="assistant-message"]') || t.closest('[data-testid="user-message"], [data-testid="assistant-message"]') === e); if (own.length === 1 && p.querySelectorAll('[data-testid="user-message"], [data-testid="assistant-message"], .font-claude-response').length <= 1) tm = own[0]; }
      const at = tm ? Date.parse(tm.getAttribute('datetime')) : NaN; if (at) m.at = at; }
    const fl = __FILES__(e); if (fl.length) m.f = fl.map(f => f.name);
    if (!u) { try { m.h = ser(e).replace(/(<div>\s*<\/div>)+/g, '').slice(0, 60000); const d = new DOMParser().parseFromString(m.h.replace(/<\/(p|li|h\d|pre|div|tr|blockquote)>|<br>/g, '\n$&'), 'text/html'); const tx = clean(d.body.textContent || ''); if (tx) m.t = tx.slice(0, 12000); else if (e.querySelector('[class~="group/status"], [data-testid*="TurnStatus" i]')) m.t = ''; else m.t = m.t.replace(/(tray-quest\s*)?\{\s*"v"\s*:\s*1[\s\S]*$/, '').trim(); } catch (x) { } }
    return m;
  });
  if (out.some(m => m.k != null)) { for (let i = 0; i < out.length; i++) if (out[i].k == null) { const p = out[i - 1], nx = out.slice(i + 1).find(m => m.k != null); if (p && p.k != null && (!nx || nx.k > p.k + 1)) out[i].k = p.k + 1; else if (nx && (!p || p.k == null)) out[i].k = nx.k - (out.slice(i + 1).indexOf(nx) + 1); } }     // a row without its number (user messages sit deeper): from its neighbours
  // size budget (PS 5.1 parses the reply with ConvertFrom-Json, ~2 MB max): newest messages keep their HTML, older ones fall back to text
  let budget = 700000;
  for (let i = out.length - 1; i >= 0; i--) { const m = out[i]; const sz = (m.t || '').length + (m.h || '').length; if (sz > budget && m.h) { delete m.h; } if ((m.t || '').length > budget) m.t = m.t.slice(0, Math.max(200, budget)); budget = Math.max(0, budget - (m.t || '').length - (m.h || '').length); }
  return JSON.stringify(out);
})(__N__)
'@
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $edgeUa = ''
    if ($edge) { try { $ev = (Get-Item $edge).VersionInfo.ProductVersion; $edgeUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$($ev.Split('.')[0]).0.0.0 Safari/537.36 Edg/$ev" } catch { } }
    $flags = @("--remote-debugging-port=$port", '--remote-debugging-address=127.0.0.1', "--user-data-dir=`"$($Web.Profile)`"", '--no-first-run', '--no-default-browser-check',
               '--disable-background-timer-throttling', '--disable-renderer-backgrounding', '--disable-backgrounding-occluded-windows', '--window-size=1100,900')
    $headless = [bool]$Web.Headless
    $tabOf = @{}                                            # chat id -> targetId (claude.ai rewrites the URL after load: never match on the full URL)
    $lastLaunch = [datetime]::MinValue
    function Get-BrowserWs { $v = Invoke-RestMethod "$base/json/version" -TimeoutSec 2; $b = New-Object System.Net.WebSockets.ClientWebSocket; [void]$b.ConnectAsync([Uri]$v.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000); return @{ Ws = $b; Ver = $v } }
    while (-not $Web.Stop) {
        $t0 = [Diagnostics.Stopwatch]::StartNew(); $Web.PassAt = Get-Date
        try {
            $list = $null; try { $list = Invoke-RestMethod "$base/json" -TimeoutSec 2 } catch { }
            if ($null -eq $list) {
                $Web.Ok = $false
                if (((Get-Date) - $lastLaunch).TotalSeconds -gt 60 -and (@($Web.Want).Count -or $Web.Cmds.Count)) {
                    if ($edge) {
                        $mode = if ($headless) { @('--headless=new', "--user-agent=`"$edgeUa`"") } else { @('--window-position=-2600,-2600', '--start-minimized') }
                        Start-Process -FilePath $edge -ArgumentList ($flags + $mode + @("https://claude.ai/$(if (@($Web.Want).Count) { @($Web.Want)[0] } else { 'new' })")) -WindowStyle Hidden; $lastLaunch = Get-Date; $tabOf = @{}; $Web.LaunchedHeadless = $headless; $Web.Checked = $true
                        WL ("edge launched ({0}, port {1})" -f $(if ($headless) { 'headless' } else { 'off-screen, minimized' }), $port)
                    } else { $Web.Err = 'Edge not found' }
                }
                Start-Sleep -Milliseconds 1500; continue
            }
            if (-not $Web.Checked) {                        # first contact: a visible browser left over (spike / old build) -> close it, relaunch headless
                $Web.Checked = $true
                try {
                    $bw = Get-BrowserWs; $isHeadless = ([string]$bw.Ver.Browser -match 'Headless') -or ([string]$bw.Ver.'User-Agent' -match 'Headless')
                    if (-not $isHeadless) {
                        # new-headless Edge reports a normal version string: look at the command line of the Edge on our port
                        $own = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match "remote-debugging-port=$port" -and $_.CommandLine -match '--headless' })
                        if ($own.Count) { $isHeadless = $true; $Web.LaunchedHeadless = $true }
                    }
                    WL ("browser: {0}, headless={1}" -f $bw.Ver.Browser, $isHeadless)
                    if ($headless -and -not $isHeadless -and -not $Web.LaunchedHeadless) { WL 'visible browser on the debug port -> closing it to relaunch headless'; try { [void](Cdp $bw.Ws 'Browser.close' @{}) } catch { }; $bw.Ws.Dispose(); $Web.Checked = $false; $lastLaunch = [datetime]::MinValue; Start-Sleep -Milliseconds 2000; continue }
                    $bw.Ws.Dispose()
                } catch { WL "version check: $($_.Exception.Message)" }
            }
            $pages = @($list | Where-Object { $_.type -eq 'page' })
            # commands not tied to a tracked chat: projects list, new chat, rename
            foreach ($cmd in @($Web.Cmds.ToArray() | Where-Object { $_.Id -eq '__new__' })) {
                $Web.Cmds.Remove($cmd); $res = 'error'; $nws = $null
                try {
                    $anyPg = @($pages | Where-Object { $_.url -like '*claude.ai*' })[0]
                    if ($cmd.Kind -eq 'newchat') {
                        $nu = if ($cmd.Project) { "https://claude.ai/project/$($cmd.Project)" } else { 'https://claude.ai/new' }
                        $nt = $null; try { $nt = Invoke-RestMethod -Method Put "$base/json/new?$nu" -TimeoutSec 5 } catch { $nt = Invoke-RestMethod "$base/json/new?$nu" -TimeoutSec 5 }
                        $Web.NewAt = Get-Date
                        $nws = New-Object System.Net.WebSockets.ClientWebSocket; if (-not $nws.ConnectAsync([Uri]$nt.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000)) { throw 'connect timeout (new tab)' }
                        $t0n = Get-Date; $okc = $false
                        do { Start-Sleep -Milliseconds 400; try { $okc = [bool](Cdp $nws 'Runtime.evaluate' @{ expression = "!!document.querySelector('div.ProseMirror[contenteditable=""true""]')"; returnByValue = $true }).result.result.value } catch { } } while (-not $okc -and ((Get-Date) - $t0n).TotalSeconds -lt 25)
                        if (-not $okc) { throw 'the new-chat page never showed its message box' }
                        Start-Sleep -Milliseconds 500
                        $pk = ''; if ($cmd.Model -or $cmd.Think) { $pj = $pickJs.Replace('__WANT__', (ConvertTo-Json ([string]$cmd.Model))).Replace('__THINK__', (ConvertTo-Json ([string]$cmd.Think))); $pk = [string](Cdp $nws 'Runtime.evaluate' @{ expression = $pj; returnByValue = $true; awaitPromise = $true }).result.result.value; WL "new chat: $pk" }
                        [void](Cdp $nws 'Runtime.evaluate' @{ expression = "document.querySelector('div.ProseMirror[contenteditable=""true""]').focus()"; returnByValue = $true })
                        [void](Cdp $nws 'Input.insertText' @{ text = [string]$cmd.Text })
                        Start-Sleep -Milliseconds 250
                        [void](Cdp $nws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 }); [void](Cdp $nws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 })      # close a slash-command popup ("/tray")
                        Start-Sleep -Milliseconds 150
                        [void](Cdp $nws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; text = "`r" }); [void](Cdp $nws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 })
                        $t0n = Get-Date; $pth = ''
                        do { Start-Sleep -Milliseconds 400; try { $pth = [string](Cdp $nws 'Runtime.evaluate' @{ expression = 'location.pathname'; returnByValue = $true }).result.result.value } catch { } } while ($pth -notmatch '^/chat/[0-9a-f-]{36}' -and ((Get-Date) - $t0n).TotalSeconds -lt 25)
                        if ($pth -notmatch '^/chat/([0-9a-f-]{36})') { throw "no chat address after sending (page $($pth -replace '[0-9a-f-]{36}', '<id>'), $pk)" }
                        $nid = "chat/$($Matches[1])"; $res = "created:$nid|$pk"
                        if ($cmd.Name -and $cmd.Org) {
                            $rn = [string](Cdp $nws 'Runtime.evaluate' @{ expression = "fetch('/api/organizations/$($cmd.Org)/chat_conversations/$($Matches[1])', { method: 'PUT', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: $(ConvertTo-Json ([string]$cmd.Name)) }) }).then(r => 'rename ' + r.status).catch(e => 'rename ' + e)"; returnByValue = $true; awaitPromise = $true }).result.result.value
                            $res += "|$rn"
                        }
                    } else {
                        if (-not $anyPg) { $nt = $null; try { $nt = Invoke-RestMethod -Method Put "$base/json/new?https://claude.ai/new" -TimeoutSec 5 } catch { $nt = Invoke-RestMethod "$base/json/new?https://claude.ai/new" -TimeoutSec 5 }; $Web.NewAt = Get-Date; Start-Sleep -Milliseconds 3500; $anyPg = $nt }
                        $nws = New-Object System.Net.WebSockets.ClientWebSocket; if (-not $nws.ConnectAsync([Uri]$anyPg.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000)) { throw 'connect timeout' }
                        if ($cmd.Kind -eq 'catalog') { $res = 'catalog:' + [string](Cdp $nws 'Runtime.evaluate' @{ expression = $catJs; returnByValue = $true; awaitPromise = $true }).result.result.value }
                        elseif ($cmd.Kind -eq 'catproj') { $res = 'catproj:' + [string](Cdp $nws 'Runtime.evaluate' @{ expression = "($catProjJs)('$($cmd.Org -replace '[^\w-]', '')', '$($cmd.Pid -replace '[^\w-]', '')')"; returnByValue = $true; awaitPromise = $true }).result.result.value }
                        elseif ($cmd.Kind -eq 'rename') { $res = [string](Cdp $nws 'Runtime.evaluate' @{ expression = "fetch('/api/organizations/$($cmd.Org)/chat_conversations/$($cmd.Uuid)', { method: 'PUT', credentials: 'include', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: $(ConvertTo-Json ([string]$cmd.Name)) }) }).then(r => 'rename ' + r.status).catch(e => 'rename ' + e)"; returnByValue = $true; awaitPromise = $true }).result.result.value }
                        elseif ($cmd.Kind -eq 'usage') { $Web.UsageAt = Get-Date; try { $ur = [string](Cdp $nws 'Runtime.evaluate' @{ expression = "(async () => { const ck = decodeURIComponent((document.cookie.match(/lastActiveOrg=([^;]+)/) || [])[1] || ''); let org = ck; if (!org) { const o = await (await fetch('/api/organizations', { credentials: 'include' })).json(); const x = o.find(y => (y.capabilities || []).includes('chat')) || o[0]; org = x && x.uuid; } if (!org) return JSON.stringify({ code: -1 }); const r = await fetch('/api/organizations/' + org + '/usage', { credentials: 'include' }); return JSON.stringify({ code: r.status, body: r.ok ? await r.text() : '', err: r.ok ? '' : (await r.text()).slice(0, 300), page: location.pathname.replace(/[0-9a-f-]{36}/g, '<id>') }); })()"; returnByValue = $true; awaitPromise = $true }).result.result.value; $uo = $ur | ConvertFrom-Json; $Web.Usage = @{ At = (Get-Date); Code = [int]$uo.code; Body = [string]$uo.body }; if ([int]$uo.code -ne 200) { WL ("usage via claude.ai: HTTP {0} on page {1}: {2}" -f $uo.code, $uo.page, (([string]$uo.err) -replace "[0-9a-f]{8}-[0-9a-f-]{27}", "<id>")) } } catch { WL "usage via claude.ai: $($_.Exception.Message)" }; $res = 'usage' }     # plan usage when no claude.ai chat tab is open (only Desktop local chats in the tray)
                    }
                } catch { $res = "error: $($_.Exception.Message)" }
                if ($nws) { try { $nws.Dispose() } catch { } }
                $Web.Results[$cmd.Key] = @{ Res = $res; At = (Get-Date) }
                WL ("new: {0} -> {1} ({2} ms)" -f $cmd.Kind, $(if ($res -like 'catalog:*') { 'catalog ' + $res.Length + ' chars' } else { $res }), [int]((Get-Date) - $cmd.At).TotalMilliseconds)
            }
            foreach ($id in @($Web.Want)) { if (-not $tabOf[$id]) { $k0 = ($id -split '/')[-1]; $a0 = ([string]$Web.Alias[$id] -split '/')[-1]; $m0 = @($pages | Where-Object { ($_.url -like "*$k0*" -or ($a0 -and $_.url -like "*$a0*")) -and @($tabOf.Values) -notcontains $_.id })[0]; if ($m0) { $tabOf[$id] = $m0.id } } }     # claim tabs already on a wanted chat first
            foreach ($tid in @($tabOf.Keys)) {                 # two chats on one tab: the one the page actually shows keeps it
                if (-not $tabOf.ContainsKey($tid)) { continue }
                $tpg = @($pages | Where-Object { $_.id -eq $tabOf[$tid] })[0]; if (-not $tpg) { continue }
                $same = @($tabOf.Keys | Where-Object { $tabOf[$_] -eq $tabOf[$tid] }); if ($same.Count -lt 2) { continue }
                foreach ($sid in $same) { if ([string]$tpg.url -notlike "*$(($sid -split '/')[-1])*") { $tabOf.Remove($sid); WL "two chats on one tab - $sid lets it go" } }
            }
            foreach ($id in @($Web.Want)) {
                $key = ($id -split '/')[-1]                     # session_... / uuid: survives claude.ai's URL rewrites
                $tg = $null
                if ($tabOf[$id]) { $tg = @($pages | Where-Object { $_.id -eq $tabOf[$id] })[0] }
                if (-not $tg) { $ak0 = ([string]$Web.Alias[$id] -split '/')[-1]; $tg = @($pages | Where-Object { $_.url -like "*$key*" -or ($ak0 -and $_.url -like "*$ak0*") })[0]; if ($tg) { $tabOf[$id] = $tg.id } }
                if (-not $tg) {                                 # reuse an unclaimed claude.ai tab (its URL may have been rewritten) instead of opening one
                    # never one that still shows another wanted chat (after a restart that stole chat B's tab for chat A: both read the same page)
                    $wantKeys = @(@($Web.Want) | ForEach-Object { ($_ -split '/')[-1]; if ($Web.Alias[$_]) { ([string]$Web.Alias[$_] -split '/')[-1] } })
                    $free = @($pages | Where-Object { $pu = [string]$_.url; $pu -like '*claude.ai*' -and @($tabOf.Values) -notcontains $_.id -and -not ($wantKeys | Where-Object { $pu -like "*$_*" }) })[0]
                    if ($free) {
                        $tabOf[$id] = $free.id; $tg = $free
                        try { $tmpWs = New-Object System.Net.WebSockets.ClientWebSocket; [void]$tmpWs.ConnectAsync([Uri]$free.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000); [void](Cdp $tmpWs 'Page.navigate' @{ url = "https://claude.ai/$id" }); $tmpWs.Dispose() } catch { }
                        WL "reused tab $($free.id.Substring(0, 8)) for $id"; continue
                    }
                }
                if (-not $tg -and (-not $Web.OpenedAt.ContainsKey($id) -or ((Get-Date) - $Web.OpenedAt[$id]).TotalSeconds -gt 20)) {
                    $nt = $null; try { $nt = Invoke-RestMethod -Method Put "$base/json/new?https://claude.ai/$id" -TimeoutSec 5 } catch { try { $nt = Invoke-RestMethod "$base/json/new?https://claude.ai/$id" -TimeoutSec 5 } catch { } }
                    $Web.OpenedAt[$id] = Get-Date; if ($nt) { $tabOf[$id] = $nt.id }
                    WL "tab opened for $id"; continue
                }
                if (-not $tg) { continue }
                try {                                           # one broken tab (Cloudflare, crash) must not stall the other chats
                $c0Users = if ($Web.Chats[$id]) { [int]$Web.Chats[$id].Users } else { 0 }
                $ws = $socks[$tg.id]
                if (-not $ws -or $ws.State -ne 'Open') {
                    $ws = New-Object System.Net.WebSockets.ClientWebSocket
                    if (-not $ws.ConnectAsync([Uri]$tg.webSocketDebuggerUrl, [Threading.CancellationToken]::None).Wait(4000)) { throw "connect timeout" }
                    $socks[$tg.id] = $ws; $pth = ([string]$tg.url -replace '^https://claude\.ai', ''); if ($pth.Length -gt 60) { $pth = $pth.Substring(0, 60) }; WL ("connected to tab {0} ({1})" -f $id, $pth)
                    # a background tab can stop rendering the live stream (seen: Claude done, tab still 'working'): ask it to act focused and active
                    try { [void](Cdp $ws 'Emulation.setFocusEmulationEnabled' @{ enabled = $true }) } catch { }
                    try { [void](Cdp $ws 'Page.setWebLifecycleState' @{ state = 'active' }) } catch { }
                }
                # the tab drifted to another page (connection lost, error page, login, /new): bring it back to the chat
                if (-not $Web.NavAt) { $Web.NavAt = @{} }; if (-not $Web.Alias) { $Web.Alias = @{} }
                $curUrl = [string]$tg.url; try { $curUrl = [string](Cdp $ws 'Runtime.evaluate' @{ expression = 'location.href'; returnByValue = $true }).result.result.value } catch { }
                $curPath = ($curUrl -replace '^https://claude\.ai', '' -replace '[?#].*$', '')
                # claude.ai can move a chat to a new address (a session shown as /chat/<uuid>): when OUR navigation to its own link
                # lands there, that address is this chat from now on
                if ($curUrl -notlike "*$key*" -and $Web.NavAt[$id] -and ((Get-Date) - $Web.NavAt[$id]).TotalSeconds -lt 20 -and $curPath -match '^/(chat|code)/[\w-]+$' -and $Web.Alias[$id] -ne $curPath) {
                    $Web.Alias[$id] = $curPath; WL ("{0}: claude.ai opened it at {1} - using that address" -f $id, $curPath)
                }
                $okPath = $curUrl -like "*$key*" -or ($Web.Alias[$id] -and $curPath -eq $Web.Alias[$id])
                if (-not $okPath -and -not ($Web.NavAt[$id] -and ((Get-Date) - $Web.NavAt[$id]).TotalSeconds -lt 20)) {
                    $Web.NavAt[$id] = Get-Date; WL ("{0}: tab shows another page ({1}) - back to the chat" -f $id, $curPath)
                    try { [void](Cdp $ws 'Page.navigate' @{ url = "https://claude.ai/$id" }) } catch { }
                    $cr0 = $Web.Chats[$id]; if ($cr0) { $cr0.ReloadAt = Get-Date; $cr0.At = Get-Date }
                }
                foreach ($cmd in @($Web.Cmds.ToArray() | Where-Object { $_.Id -eq $id })) {
                    $Web.Cmds.Remove($cmd); $res = 'error'
                    try {
                        if ($cmd.Kind -eq 'send') {
                            # same as a person typing in the box and pressing Enter: the app's own queue applies while Claude works
                            # never type into another page (the tab was redirected: /new, login, deleted chat) - Enter there would start a new chat
                            $tail = ([string]$id -split '/')[-1] -replace '[^\w-]', ''
                            if (-not $Web.Alias) { $Web.Alias = @{} }; $alias = ([string]$Web.Alias[$id] -split '/')[-1] -replace '[^\w-]', ''; if (-not $alias) { $alias = $tail }
                            # a box still holding the tray's own earlier text (Enter was lost) is cleared; your own draft never is
                            $pre = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { if (!location.pathname.includes('$tail') && !location.pathname.includes('$alias')) return 'wrong-page'; const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); if (!e) return 'no-composer'; const cur = (e.innerText || '').replace(/\u200b/g,'').trim(); if (cur.length) { if (window.__ctTyped && cur === window.__ctTyped) { e.focus(); document.execCommand('selectAll'); document.execCommand('delete'); if ((e.innerText || '').trim().length) return 'not-empty'; } else return 'not-empty'; } e.focus(); return 'ok'; })()"; returnByValue = $true }).result.result.value
                            if ($pre -eq 'wrong-page') {                # back to the chat, wait for it (max 15 s), check again
                                WL "$($id): send found another page - opening the chat first"
                                try { [void](Cdp $ws 'Page.navigate' @{ url = "https://claude.ai/$id" }) } catch { }
                                $Web.NavAt[$id] = Get-Date; $tw = Get-Date
                                do {
                                    Start-Sleep -Milliseconds 500
                                    $st0 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); return JSON.stringify({ p: location.pathname, c: !!e, t: e ? (e.innerText || '').replace(/\u200b/g,'').trim().length : 0 }); })()"; returnByValue = $true }).result.result.value | ConvertFrom-Json
                                    $hit = ([string]$st0.p).Contains($tail) -or ($alias -and ([string]$st0.p).Contains($alias))
                                    # claude.ai redirected our own link to another address and the page is ready there: that's this chat now
                                    if (-not $hit -and $st0.c -and ([string]$st0.p) -match '^/(chat|code)/[\w-]+$' -and ((Get-Date) - $tw).TotalSeconds -gt 3) { $Web.Alias[$id] = [string]$st0.p; $alias = ([string]$st0.p -split '/')[-1]; $hit = $true; WL ("{0}: claude.ai opened it at {1} - using that address" -f $id, $st0.p) }
                                    $pre = if (-not $hit) { 'wrong-page' } elseif (-not $st0.c) { 'no-composer' } elseif ($st0.t) { 'not-empty' } else { 'ok' }
                                } while ($pre -in 'wrong-page', 'no-composer' -and ((Get-Date) - $tw).TotalSeconds -lt 15)
                                if ($pre -eq 'ok') { [void](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); if (e) e.focus(); })()" }) }
                            }
                            if ($pre -ne 'ok') { $res = $pre }
                            else {
                                if (@($cmd.Files).Count) {           # attachments: the page's own file input (same as picking files), then wait for the upload
                                    $busyJs = "(() => { const f = document.querySelector('div.ProseMirror[contenteditable=""true""]'); let form = f; for (let i = 0; i < 6 && form && !form.querySelector('input[type=""file""]'); i++) form = form.parentElement; if (!form) form = document; const busy = !!form.querySelector('[role=""progressbar""], [aria-busy=""true""], .animate-spin'); const n = form.querySelectorAll('img, [data-testid*=""file"" i], [data-testid*=""attachment"" i], [data-testid*=""thumbnail"" i]').length; return (busy ? 'busy:' : 'idle:') + n; })()"
                                    $b0 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = $busyJs; returnByValue = $true }).result.result.value
                                    $doc = Cdp $ws 'DOM.getDocument' @{ depth = 0 }
                                    $qn = Cdp $ws 'DOM.querySelectorAll' @{ nodeId = $doc.result.root.nodeId; selector = 'input[type="file"]' }
                                    $nodes = @($qn.result.nodeIds)
                                    if (-not $nodes.Count) { throw 'no file input on the page' }
                                    [void](Cdp $ws 'DOM.setFileInputFiles' @{ nodeId = $nodes[0]; files = @($cmd.Files) })
                                    $t1 = Get-Date; $st1 = ''; $n0 = [int]($b0 -replace '^\D+', '')
                                    do { Start-Sleep -Milliseconds 300; $st1 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = $busyJs; returnByValue = $true }).result.result.value } while (((Get-Date) - $t1).TotalSeconds -lt 25 -and ($st1 -like 'busy:*' -or ([int]($st1 -replace '^\D+', '') -le $n0 -and ((Get-Date) - $t1).TotalSeconds -lt 2.5)))
                                    WL ("{0}: {1} file(s) attached via input 1/{2}, composer {3} -> {4} after {5} ms" -f $id, @($cmd.Files).Count, $nodes.Count, $b0, $st1, [int]((Get-Date) - $t1).TotalMilliseconds)
                                    Start-Sleep -Milliseconds 400
                                }
                                if ([string]$cmd.Text) { [void](Cdp $ws 'Input.insertText' @{ text = [string]$cmd.Text }); try { [void](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); window.__ctTyped = e ? (e.innerText || '').replace(/\u200b/g,'').trim() : ''; })()" }) } catch { } }
                                Start-Sleep -Milliseconds 120
                                if (([string]$cmd.Text).StartsWith('/')) { Start-Sleep -Milliseconds 250; [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 }); [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 }); Start-Sleep -Milliseconds 120 }
                                [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; text = "`r" })
                                [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 })
                                $res = 'sent'
                            }
                        } elseif ($cmd.Kind -eq 'more') {
                            # scroll the transcript to the top so claude.ai loads older messages
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const l = document.querySelector('[data-testid=""transcript-list""]') || document.querySelector('[data-testid=""user-message""]'); let n = l; while (n && !(n.scrollHeight > n.clientHeight + 10 && /auto|scroll/.test(getComputedStyle(n).overflowY))) n = n.parentElement; if (!n) return 'no-scroller'; n.scrollTop = Math.max(0, n.scrollTop - n.clientHeight * 1.5); return 'scrolled'; })()"; returnByValue = $true }).result.result.value
                        } elseif ($cmd.Kind -eq 'press') {
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const b = (window.__ctPrompts || [])[$([int]$cmd.I)]; if (!b) return 'gone'; const tx = (b.innerText || b.getAttribute('aria-label') || '').trim().split('\n')[0]; if (tx !== $(ConvertTo-Json ([string]$cmd.Label))) return 'changed:' + tx; b.click(); return 'pressed:' + tx; })()"; returnByValue = $true }).result.result.value
                        } elseif ($cmd.Kind -eq 'model') {
                            # read the model menu (and its effort sub-menu: it opens on hover, so a real mouse move) / pick a model or an effort
                            $mj = { param($mo, $kd, $nm) [string](Cdp $ws 'Runtime.evaluate' @{ expression = $modelJs.Replace('__MODE__', (ConvertTo-Json $mo)).Replace('__KIND__', (ConvertTo-Json $kd)).Replace('__NAME__', (ConvertTo-Json $nm)); returnByValue = $true; awaitPromise = $true }).result.result.value }
                            $mk0 = [string]$cmd.Mode; $o1 = (& $mj $(if ($mk0 -eq 'pick') { 'pick' } else { 'read' }) ([string]$cmd.KindM) ([string]$cmd.Name)) | ConvertFrom-Json
                            if (($mk0 -eq 'read' -or $cmd.KindM -eq 'effort') -and $o1.rect) {
                                [void](Cdp $ws 'Input.dispatchMouseEvent' @{ type = 'mouseMoved'; x = [int]$o1.rect.x; y = [int]$o1.rect.y }); Start-Sleep -Milliseconds 450
                                $o2 = (& $mj 'sub' '' '') | ConvertFrom-Json; $o1 | Add-Member -NotePropertyName efforts -NotePropertyValue @($o2.efforts) -Force
                                if ($mk0 -eq 'pick' -and $cmd.KindM -eq 'effort') { $o3 = (& $mj 'subpick' '' ([string]$cmd.Name)) | ConvertFrom-Json; $o1 | Add-Member -NotePropertyName ok -NotePropertyValue ([bool]$o3.ok) -Force; $o1 | Add-Member -NotePropertyName err -NotePropertyValue ([string]$o3.err) -Force }
                                else { [void](& $mj 'close' '' '') }
                            } elseif ($mk0 -eq 'read') { [void](& $mj 'close' '' '') }
                            $res = 'model:' + ($o1 | ConvertTo-Json -Compress -Depth 4)
                        } elseif ($cmd.Kind -eq 'qother') {
                            # the card's own "Other" box (one more answer, next to the picks): replace its text, Enter only for a one-answer step
                            $f1 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const g = document.querySelector('[data-cds=""AskUserQuestion""]') || document.querySelector('[data-testid=""hub-ask-user-question-card""]'); const i = g && g.querySelector('form input[type=""text""], form textarea'); if (!i) return 'no-input'; i.focus(); if (i.select) i.select(); return 'ok'; })()"; returnByValue = $true }).result.result.value
                            if ($f1 -ne 'ok') { $res = $f1 }
                            else {
                                [void](Cdp $ws 'Input.insertText' @{ text = [string]$cmd.Text }); Start-Sleep -Milliseconds 120
                                if ($cmd.Enter) { [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; text = "`r" }); [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }); $res = 'other sent' } else { $res = 'other set' }
                            }
                        } elseif ($cmd.Kind -in 'qpick', 'qsub', 'qnext', 'qskip', 'qprev') {
                            $lbJs = ConvertTo-Json ([string]$cmd.Label)
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const q = window.__ctQ; if (!q) return 'gone'; if ('$($cmd.Kind)' === 'qsub' && q.sub) { if (q.sub.disabled) return 'send-disabled'; q.sub.click(); return 'submitted'; } if ('$($cmd.Kind)' === 'qsub') { const ci = document.querySelector('[data-testid=""chat-input""], div.ProseMirror[contenteditable=""true""]'); let z = ci; for (let i = 0; i < 6 && z && z.parentElement; i++) z = z.parentElement; const sbt = z ? Array.from(z.querySelectorAll('button')).find(b => !b.disabled && b.offsetParent !== null && /send|envoyer/i.test(b.getAttribute('aria-label') || '') && !b.closest('[data-testid=""hub-ask-user-question-card""]')) : null; if (sbt) { sbt.click(); return 'clicked send'; } return 'enter'; } if ('$($cmd.Kind)' === 'qnext') { if (!q.next) return 'no-next'; q.next.click(); return 'next'; } if ('$($cmd.Kind)' === 'qskip') { if (!q.skip) return 'no-skip'; q.skip.click(); return 'skipped'; } if ('$($cmd.Kind)' === 'qprev') { if (!q.prev) return 'no-prev'; q.prev.click(); return 'prev'; } const e = q.o[$([int]$cmd.I)]; if (!e) return 'gone'; const lb = e.matches('input') ? (e.closest('label') || e.parentElement) : e; const bd = lb.querySelector && lb.querySelector('bdi'); const tx = ((bd && bd.innerText) || lb.innerText || '').trim().split('\n').filter(x => !/^\d+$/.test(x.trim()))[0].trim(); if (tx.slice(0, 60) !== $lbJs) return 'changed'; (e.matches('input') ? e : lb).click(); return 'picked'; })()"; returnByValue = $true }).result.result.value
                            if ($res -eq 'enter') {                    # claude.ai's card: "send your message to answer" - Enter in the (empty) message box sends the picks
                                $f0 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); if (!e) return 'no-composer'; e.focus(); return 'ok'; })()"; returnByValue = $true }).result.result.value
                                if ($f0 -eq 'ok') { [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; text = "`r" }); [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13 }); $res = 'sent (Enter)' } else { $res = $f0 }
                            }
                        } elseif ($cmd.Kind -eq 'slash') {
                            $pre2 = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); if (!e) return 'no-composer'; if ((e.innerText || '').replace(/\u200b/g,'').trim().length) return 'busy'; e.focus(); return 'ok'; })()"; returnByValue = $true }).result.result.value
                            if ($pre2 -ne 'ok') { $res = "slash:{`"err`":`"$pre2`"}" }
                            else {
                                [void](Cdp $ws 'Input.insertText' @{ text = '/' }); Start-Sleep -Milliseconds 800
                                $lst = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const vis = x => x.offsetParent !== null; const it = Array.from(document.querySelectorAll('[role=""option""], [role=""menuitem""], [cmdk-item]')).filter(vis).slice(0, 120); return JSON.stringify({ items: it.map(x => { const ls = (x.innerText || '').split('\n').map(s => s.trim()).filter(Boolean); return { n: (ls[0] || '').slice(0, 60), d: ls.slice(1).join(' ').slice(0, 140) }; }).filter(o => o.n) }); })()"; returnByValue = $true }).result.result.value
                                [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 }); [void](Cdp $ws 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Escape'; code = 'Escape'; windowsVirtualKeyCode = 27; nativeVirtualKeyCode = 27 })
                                [void](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const e = document.querySelector('div.ProseMirror[contenteditable=""true""]'); if (e && (e.innerText || '').trim() === '/') { e.focus(); document.execCommand('selectAll'); document.execCommand('delete'); } })()" })
                                $res = 'slash:' + $lst
                            }
                        } elseif ($cmd.Kind -eq 'retry') {
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const b = Array.from(document.querySelectorAll('[data-testid=""action-bar-retry""]')).pop(); if (!b) return 'no-retry'; b.click(); return 'retried'; })()"; returnByValue = $true }).result.result.value
                        } elseif ($cmd.Kind -eq 'dl') {
                            # a file Claude attached: fetch it with the page's own session (link) or click its download button
                            New-Item -ItemType Directory -Path $cmd.Dir -Force | Out-Null
                            [void](Cdp $ws 'Page.setDownloadBehavior' @{ behavior = 'allow'; downloadPath = [string]$cmd.Dir })
                            $dj = "(async (x, k) => { const els = Array.from(document.querySelectorAll('[data-testid=""user-message""], [data-testid=""assistant-message""], .font-claude-response')).filter((e, i, a) => !a.some(o => o !== e && o.contains(e))); const e = els[x]; if (!e) return 'no-message'; const fl = ($fileJs)(e); const f = fl[k]; if (!f) return 'no-file'; const a = f.el.closest('a[href]') || f.el.querySelector('a[href]'); if (a) { try { const r = await fetch(a.href, { credentials: 'include' }); if (r.ok) { const b = await r.blob(); const s = await new Promise(ok => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(',')[1] || ''); fr.readAsDataURL(b); }); window.__ctdl = s; return 'fetched:' + s.length + ':' + (a.getAttribute('download') || f.name); } } catch (z) { } } const btn = Array.from(f.el.querySelectorAll('button, a')).find(b => /download|télécharg/i.test((b.getAttribute('aria-label') || '') + ' ' + (b.innerText || ''))) || f.el; btn.click(); await new Promise(ok => setTimeout(ok, 900)); const dg = Array.from(document.querySelectorAll('[role=""dialog""]')).pop(); if (dg) { const b2 = Array.from(dg.querySelectorAll('a[href], button')).find(x => /download|télécharg/i.test((x.getAttribute('aria-label') || '') + ' ' + (x.innerText || '') + ' ' + (x.getAttribute('download') != null ? 'download' : ''))); if (b2 && b2.href && !/^javascript:/i.test(b2.href)) { try { const r2 = await fetch(b2.href, { credentials: 'include' }); if (r2.ok) { const bl = await r2.blob(); const s2 = await new Promise(ok => { const fr = new FileReader(); fr.onload = () => ok(String(fr.result).split(',')[1] || ''); fr.readAsDataURL(bl); }); window.__ctdl = s2; document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'fetched:' + s2.length + ':' + f.name; } } catch (z) { } } if (b2) { b2.click(); await new Promise(ok => setTimeout(ok, 300)); } document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true })); return 'clicked:' + f.name + (b2 ? ' (preview download)' : ' (preview, no download button)'); } return 'clicked:' + f.name; })($([int]$cmd.X), $([int]$cmd.K))"
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = $dj; returnByValue = $true; awaitPromise = $true }).result.result.value
                            if ($res -match '^fetched:(\d+):(.*)$') {
                                $len = [int]$Matches[1]; $fnm = ($Matches[2] -replace '[\/:*?"<>|]', '_').Trim(); if (-not $fnm) { $fnm = 'file' }
                                $sb = New-Object Text.StringBuilder
                                for ($ofs = 0; $ofs -lt $len; $ofs += 400000) { [void]$sb.Append([string](Cdp $ws 'Runtime.evaluate' @{ expression = "window.__ctdl.substr($ofs, 400000)"; returnByValue = $true }).result.result.value) }
                                [void](Cdp $ws 'Runtime.evaluate' @{ expression = 'delete window.__ctdl'; returnByValue = $true })
                                $fpart = Join-Path $cmd.Dir ($fnm + '.part'); [IO.File]::WriteAllBytes($fpart, [Convert]::FromBase64String($sb.ToString())); Move-Item $fpart (Join-Path $cmd.Dir $fnm) -Force; $res = "saved:$fnm"
                            }
                        } elseif ($cmd.Kind -eq 'diag' -and $Web.Chats[$id] -and $Web.Chats[$id].DiagAt -and ((Get-Date) - $Web.Chats[$id].DiagAt).TotalSeconds -lt 30 -and [string]$cmd.Key -notlike 'diagq-*') {
                            $res = 'skip'                     # one structure dump per chat per 30 s (expanding / folding chats queued one each time)
                        } elseif ($cmd.Kind -eq 'mdiag') {
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = $mdiagJs; returnByValue = $true }).result.result.value
                        } elseif ($cmd.Kind -eq 'diag') {
                            if ($Web.Chats[$id]) { $Web.Chats[$id].DiagAt = Get-Date }
                            # STRUCTURE ONLY (privacy): tags, data-testids, link/download flags of the last messages - no text
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const els = Array.from(document.querySelectorAll('[data-testid=""user-message""], [data-testid=""assistant-message""], .font-claude-response')).filter((e, i, a) => !a.some(o => o !== e && o.contains(e))); const L = /download|télécharg|copy|copier|open|ouvrir|file|fichier|attach|pièce|preview|aperçu/i; const tree = (n, d) => d > 4 ? '' : Array.from(n.children).slice(0, 8).map(c => c.tagName.toLowerCase() + ((c.getAttribute('class') || '').split(/\s+/).filter(Boolean).slice(0, 2).map(x => '.' + x.slice(0, 18)).join('')) + (c.dataset.testid ? '#' + c.dataset.testid : '') + ':' + (c.textContent || '').length + (c.children.length ? '(' + tree(c, d + 1) + ')' : '')).join(' '); const lastA = els.filter(e => !e.matches('[data-testid=""user-message""]')).pop(); const cmp0 = document.querySelector('div.ProseMirror[contenteditable=""true""]'); let cz0 = cmp0; for (let i = 0; i < 6 && cz0 && cz0.parentElement; i++) cz0 = cz0.parentElement; const tz = (n, d) => d > 6 ? '' : Array.from(n.children).slice(0, 10).map(c => c.tagName.toLowerCase() + (c.getAttribute('role') ? '[' + c.getAttribute('role') + ']' : '') + (c.getAttribute('type') ? '{' + c.getAttribute('type') + '}' : '') + (c.getAttribute('aria-checked') ? '~c' + c.getAttribute('aria-checked') : '') + (c.dataset.testid ? '#' + c.dataset.testid : '') + ':' + (c.textContent || '').length + (c.children.length ? '(' + tz(c, d + 1) + ')' : '')).join(' '); window.__ctZ = cz0 ? 'ZONE ' + tz(cz0, 0) : 'ZONE none'; const qc0 = document.querySelector('[data-testid=""hub-ask-user-question-card""]'); const tq = (n, d) => d > 12 ? '' : Array.from(n.children).slice(0, 12).map(c => c.tagName.toLowerCase() + (c.getAttribute('role') ? '[' + c.getAttribute('role') + ']' : '') + (c.getAttribute('type') ? '{' + c.getAttribute('type') + '}' : '') + ['aria-pressed', 'aria-checked', 'aria-selected', 'data-state', 'data-cds', 'data-orientation', 'disabled'].filter(a => c.hasAttribute(a)).map(a => '~' + a.replace(/^(aria|data)-/, '') + '=' + c.getAttribute(a)).join('') + ':' + (c.textContent || '').length + (c.children.length ? '(' + tq(c, d + 1) + ')' : '')).join(' '); return (qc0 ? 'QCARD ' + tq(qc0, 0).slice(0, 3500) + ' || ' : '') + window.__ctZ.slice(0, 1500) + ' || TREE ' + (lastA ? tree(lastA, 0).slice(0, 1500) : '-') + ' || ' + els.slice(-3).map((e, j) => (e.matches('[data-testid=""user-message""]') ? 'U' : 'A') + '[' + Array.from(e.querySelectorAll('[data-testid], a, button, img, [download]')).slice(0, 40).map(x => x.tagName.toLowerCase() + (x.dataset.testid ? '#' + x.dataset.testid : '') + (x.getAttribute('href') ? '(href:' + (x.getAttribute('href').match(/^[a-z]+:|^\/[a-z_-]+/i) || ['?'])[0] + ')' : '') + (x.hasAttribute('download') ? '(dl)' : '') + (L.test(x.getAttribute('aria-label') || '') ? '{' + (x.getAttribute('aria-label').match(L) || [''])[0] + '}' : '')).join(' ') + ']').join(' | '); })()"; returnByValue = $true }).result.result.value
                        } elseif ($cmd.Kind -eq 'reload') {
                            $cr = $Web.Chats[$id]; if ($cr) { $cr.ReloadAt = Get-Date; $cr.ChangeAt = Get-Date }
                            [void](Cdp $ws 'Page.reload' @{ ignoreCache = $false }); $res = 'reloaded'
                        } elseif ($cmd.Kind -eq 'stop') {
                            $res = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(() => { const b = Array.from(document.querySelectorAll('button')).find(x => /^(stop|arr[eê]t)/i.test((x.getAttribute('aria-label') || '').trim())); if (!b) return 'no-stop-button'; b.click(); return 'stopped'; })()"; returnByValue = $true }).result.result.value
                        }
                    } catch { $res = "error: $($_.Exception.Message)" }
                    $Web.Results[$cmd.Key] = @{ Res = $res; At = (Get-Date); Users = $c0Users }
                    if ($res -ne 'skip') { WL ("{0}: {1} -> {2} ({3} ms after queued)" -f $id, $cmd.Kind, $res, [int]((Get-Date) - $cmd.At).TotalMilliseconds) }
                }
                if (-not $Web.UsageAt -or ((Get-Date) - $Web.UsageAt).TotalSeconds -gt 170) {          # plan usage from claude.ai itself (the page's own session)
                    $Web.UsageAt = Get-Date
                    try { $ur = [string](Cdp $ws 'Runtime.evaluate' @{ expression = "(async () => { const ck = decodeURIComponent((document.cookie.match(/lastActiveOrg=([^;]+)/) || [])[1] || ''); let org = ck; if (!org) { const o = await (await fetch('/api/organizations', { credentials: 'include' })).json(); const x = o.find(y => (y.capabilities || []).includes('chat')) || o[0]; org = x && x.uuid; } if (!org) return JSON.stringify({ code: -1 }); const r = await fetch('/api/organizations/' + org + '/usage', { credentials: 'include' }); return JSON.stringify({ code: r.status, body: r.ok ? await r.text() : '' }); })()"; returnByValue = $true; awaitPromise = $true }).result.result.value
                          $uo = $ur | ConvertFrom-Json; $Web.Usage = @{ At = (Get-Date); Code = [int]$uo.code; Body = [string]$uo.body }; if ([int]$uo.code -ne 200) { WL "usage via claude.ai: HTTP $($uo.code)" } } catch { WL "usage via claude.ai: $($_.Exception.Message)" }
                }
                $r = Cdp $ws 'Runtime.evaluate' @{ expression = $js; returnByValue = $true }
                $o = [string]$r.result.result.value | ConvertFrom-Json
                if ($Web.ConvFor -eq $id -or @($Web.MsgFor) -contains $id) {     # chat view open for this chat: last N messages, both sides
                    $cj = $msgJs.Replace('__FILES__', "($fileJs)").Replace('__N__', [string]$(if ($Web.MsgN.ContainsKey($id)) { [int]$Web.MsgN[$id] } else { 20 }))
                    try {
                        $mr = Cdp $ws 'Runtime.evaluate' @{ expression = $cj; returnByValue = $true }; $cc0 = $Web.Chats[$id]
                        if ($cc0) {
                            $arr = [string]$mr.result.result.value | ConvertFrom-Json; $nw = @($arr | ForEach-Object { $_ })
                            # claude.ai unloads older messages (after a send): keep the ones we already had in front of the overlap
                            $old = @($cc0.Msgs); $mg = $nw; if (-not $nw.Count -and $old.Count) { $mg = $old }     # page reloading / empty for a moment: keep what we had
                            $nk = @($nw | Where-Object { $null -ne $_.k }); $byK = $null
                            if ($nw.Count -and $nk.Count -eq $nw.Count) {
                                # claude.ai keeps only some rows of a long chat on the page (the newest ones + where it is scrolled): keep each row by its number,
                                # show the unbroken run that ends at the newest one (a gap = rows we never saw: never show older rows after it)
                                $byK = $cc0.ByK; $mxN = ($nk | Measure-Object -Property k -Maximum).Maximum
                                if (-not $byK -or $mxN -lt [int]$cc0.ByKMax) { $byK = @{} }     # first read, or another / reloaded page: start over
                                foreach ($mm in $nk) { $byK[[int]$mm.k] = $mm }
                                $cc0.ByK = $byK; $cc0.ByKMax = [int]$mxN
                                $run = New-Object System.Collections.ArrayList; $miss = 0
                                $here = @{}; foreach ($mm in $nk) { $here[[int]$mm.k] = $true }
                                for ($kk = [int]$mxN; $kk -ge 0 -and $run.Count -lt 200; $kk--) { if ($byK.ContainsKey($kk)) { $e0 = $byK[$kk]; if (-not $here[$kk]) { $e0 = $e0.PSObject.Copy(); $e0.x = -1 }; [void]$run.Insert(0, $e0); $miss = 0 } else { $miss++; if ($miss -gt 2) { break } } }     # x = -1: not on the page now (its files can't be fetched from here)
                                $mg = @($run)
                            }
                            elseif ($nw.Count -and $old.Count) {
                                # overlap = the first point where the rest of the old list equals the start of the new one (repeated 'check's included)
                                $j = -1; for ($oi = 0; $oi -lt $old.Count; $oi++) { $okm = $true; for ($pp = 0; $oi + $pp -lt $old.Count -and $pp -lt $nw.Count; $pp++) { if ($old[$oi + $pp].r -ne $nw[$pp].r -or [string]$old[$oi + $pp].t -ne [string]$nw[$pp].t) { $okm = $false; break } }; if ($okm) { $j = $oi; break } }
                                if ($j -gt 0) { $pre = @($old[0..($j - 1)] | ForEach-Object { $cp = $_.PSObject.Copy(); $cp.x = -1; $cp }); $mg = @($pre + $nw); if ($mg.Count -gt 200) { $mg = @($mg[($mg.Count - 200)..($mg.Count - 1)]) } }
                            }
                            $cc0.Msgs = $mg
                        }
                    } catch { WL "conv read: $($_.Exception.Message)" }
                }
                $c = $Web.Chats[$id]; if (-not $c) { $c = [hashtable]::Synchronized(@{ Working = $false; Reply = ''; ReplyAt = [datetime]::MinValue; At = [datetime]::MinValue; Ok = $false; Users = 0; EndAt = [datetime]::MinValue; StartAt = [datetime]::MinValue; FirstAt = (Get-Date) }); $Web.Chats[$id] = $c }
                $work = [bool]($o.stop -or $o.streaming)
                if ($c.ReloadAt -and ((Get-Date) - $c.ReloadAt).TotalSeconds -lt 15 -and -not $o.ok) { $c.At = Get-Date; continue }     # reloaded page still coming back: keep the last state
                $rsig = "$($o.replies)|$($o.rl)|$($o.users)|$($o.act)"
                if ($rsig -ne [string]$c.RSig) { $c.RSig = $rsig; $c.ChangeAt = Get-Date }
                $stall = if ($id -like 'code/*' -and [string]$o.act) { 240 } else { 60 }     # a Claude Code step running a long command shows its name: give it time
                if ($work -and $c.ChangeAt -and ((Get-Date) - $c.ChangeAt).TotalSeconds -gt $stall -and -not ($c.ReloadAt -and ((Get-Date) - $c.ReloadAt).TotalSeconds -lt $stall)) {
                    # the hidden tab's stream can stall while the answer is already done on the server (seen with claude.ai chats): a reload shows the real state
                    $c.ReloadAt = Get-Date; $c.ChangeAt = Get-Date; WL ("{0}: 'working' with nothing new for {1} s - reloading the hidden tab (page {2}, focus {3}, last frame {4} ms ago)" -f $id, $stall, $o.vs, $o.foc, $o.raf)
                    try { [void](Cdp $ws 'Page.reload' @{ ignoreCache = $false }) } catch { }
                }
                if ($work -ne $c.Working) { WL ("{0}: {1} (stop={2} streaming={3}, reply {4} chars, page {5})" -f $id, $(if ($work) { 'idle -> working' } else { 'working -> idle' }), $o.stop, $o.streaming, ([string]$o.reply).Length, $o.vs); if (-not $work) { $c.EndAt = Get-Date } else { $c.StartAt = Get-Date } }
                if ($o.reply -ne $c.Reply) { $c.Reply = [string]$o.reply; $c.ReplyAt = Get-Date }
                if ([int]$o.users -ne [int]$c.Users -and $c.Ok) { WL ("{0}: user messages {1} -> {2}" -f $id, $c.Users, $o.users) }
                if ($work) { $c.SawWork = $true }
                if ([string]$o.quest) { $c.Quest = [string]$o.quest; $c.QuestTag = [bool]$o.qtag }
                $c.Act = [string]$o.act; $c.Prompts = @($o.prompts | ForEach-Object { [string]$_ }); $c.Model = [string]$o.model; $c.Retry = [bool]$o.retry
                $pks = ($c.Prompts -join '|'); if ($pks -ne [string]$c.PromptSig) { $c.PromptSig = $pks; if ($pks) { WL ("{0}: page asks: {1}" -f $id, $pks) } }
                $c.Q = $o.q; $qsg = $(if ($o.q) { '{0}|{1}|{2}|{3}/{4}|{5}|{6}|{7}' -f @($o.q.o).Count, [bool]$o.q.multi, [string]$o.q.sub, [int]$o.q.step, [int]$o.q.steps, [bool]$o.q.card, @($o.q.o | Where-Object { $_.s }).Count, [bool]$o.q.subOk } else { '' })
                if ($qsg -ne [string]$c.QSig) { $qWas = [string]$c.QSig; $c.QSig = $qsg; if ($qsg) { WL ("{0}: question with {1} choices (card={2}, step {3}/{4}, picked {5})" -f $id, @($o.q.o).Count, [bool]$o.q.card, [int]$o.q.step, [int]$o.q.steps, @($o.q.o | Where-Object { $_.s }).Count); if (-not $qWas -or ($qsg.Split('|')[3] -ne $qWas.Split('|')[3] -and -not @($o.q.o).Count)) { [void]$Web.Cmds.Add(@{ Id = $id; Kind = 'diag'; Key = 'diagq-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } } else { WL ("{0}: question gone" -f $id) } }
                $c.Working = $work; $c.Users = [int]$o.users; $c.LastUser = [string]$o.lastUser; $c.Ok = [bool]$o.ok; $c.Cf = [bool]$o.cf; $c.At = Get-Date
                if ($o.ok -and -not $c.WasOk) { $c.WasOk = $true; WL ("{0}: page ready ({1} replies)" -f $id, $o.replies) }
                if (-not $o.ok -and -not $c.WarnedOk -and ((Get-Date) - $c.FirstAt).TotalSeconds -gt 10) { $c.WarnedOk = $true; WL ("{0}: no composer (cloudflare={1}, login page={2}) - signed in?" -f $id, $o.cf, ([string]$o.t -match '(?i)log ?in|connexion|sign')) }
                } catch { WL ("{0}: {1} - this chat's tab reconnects next pass" -f $id, $_.Exception.Message); try { if ($socks[$tg.id]) { $socks[$tg.id].Dispose() } } catch { }; $socks.Remove($tg.id) }
            }
            $keep = @($tabOf.Values)
            if (@($Web.Want).Count -and -not ($Web.NewAt -and ((Get-Date) - $Web.NewAt).TotalSeconds -lt 20)) { foreach ($pg in $pages) { if ($pg.url -like '*claude.ai*' -and $keep -notcontains $pg.id -and @($pages | Where-Object { $_.url -like '*claude.ai*' }).Count -gt @($Web.Want).Count) { try { Invoke-RestMethod "$base/json/close/$($pg.id)" -TimeoutSec 3 | Out-Null; WL "closed extra tab $($pg.id.Substring(0,8))" } catch { } } } }      # only once the chat list is known (else it closed its own tab at start)
            # headless rejected? (no composer after 30 s) -> fall back to an off-screen window
            if ($headless) { foreach ($cc in @($Web.Chats.Values)) { if (-not $cc.Ok -and $cc.FirstAt -and ((Get-Date) - $cc.FirstAt).TotalSeconds -gt 30) { WL 'headless page never showed the composer -> falling back to an off-screen window'; $headless = $false; $Web.Headless = $false; try { $bw = Get-BrowserWs; [void](Cdp $bw.Ws 'Browser.close' @{}) } catch { }; $lastLaunch = [datetime]::MinValue; $Web.Chats.Clear(); break } } }
            $Web.Ok = $true; $Web.Err = ''
        } catch { $Web.Err = $_.Exception.Message; WL "error: $($_.Exception.Message)"; foreach ($sk in @($socks.Keys)) { try { $socks[$sk].Dispose() } catch { } }; $socks = @{}; Start-Sleep -Milliseconds 800 }
        $Web.Ms = $t0.ElapsedMilliseconds
        if (-not $Web.Cmds.Count) { Start-Sleep -Milliseconds $(if ($Web.Idle) { 2000 } else { 500 }) } else { Start-Sleep -Milliseconds 50 }     # idle = panel hidden and nobody working
    }
}
# the browser profile holds a claude.ai login: keep it in %LOCALAPPDATA%, not next to the script (repo folders get zipped/shared)
$webProfile = if ($Cfg.webProfile) { [Environment]::ExpandEnvironmentVariables([string]$Cfg.webProfile) } else { Join-Path $env:LOCALAPPDATA 'ClaudeTray\browser-profile' }
$oldProfile = Join-Path $Root 'browser-profile'
if ((Test-Path $oldProfile) -and -not (Test-Path $webProfile)) {
    try {
        foreach ($pr in @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$oldProfile*" })) { Stop-Process -Id $pr.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 1500
        New-Item -ItemType Directory -Path (Split-Path $webProfile -Parent) -Force | Out-Null
        Move-Item $oldProfile $webProfile -Force; Log "browser profile moved out of the script folder to $webProfile"
    } catch { Log "browser profile move failed ($($_.Exception.Message)) - using the old place" 'WARN'; $webProfile = $oldProfile }
}
$Web.Profile = $webProfile
$webEnabled = ([string]$Cfg.engine -ne 'app') -and (Test-Path $webProfile)
if ($webEnabled) {
    $webRs = [runspacefactory]::CreateRunspace(); $webRs.ApartmentState = 'MTA'; $webRs.Open()
    $webPs = [powershell]::Create(); $webPs.Runspace = $webRs; [void]$webPs.AddScript($webScript).AddArgument($Web)
    $webHandle = $webPs.BeginInvoke()
}
function Get-WebChat($q) {                       # live tab data: fresh (< 4 s), or the browser loop is busy on a long step (upload, new chat): trust it up to 90 s
    if (-not $webEnabled) { return $null }; $c = $Web.Chats[[string]$q.id]; if (-not ($c -and $c.Ok)) { return $null }
    $age = ((Get-Date) - $c.At).TotalSeconds; if ($age -lt 4) { return $c }
    if ($Web.PassAt -and ((Get-Date) - $Web.PassAt).TotalSeconds -gt 3 -and $age -lt 90) { return $c }
    return $null
}
function Get-PageLabel([string]$pg) {         # page title for the log: tracked chats by name, anything else anonymised
    if (-not $pg) { return '' }
    foreach ($q in $QS.List) { if ($q.title -and $pg.StartsWith([string]$q.title)) { return $pg } }
    return '<other chat>'
}
function Get-ProbeQuest { if (-not $Probe.Page) { return $null }; foreach ($q in $QS.List) { if ($q.title -and $Probe.Page.StartsWith([string]$q.title)) { return $q } }; return $null }
function Get-LocalTitle($q) {     # a local chat's title as Claude Desktop shows it (the quest title may be stale after a rename)
    $sid = ([string]$q.id) -replace '^local/', ''
    $e = @(@(try { Get-DesktopLocal } catch { }) | Where-Object { [string]$_.id -eq $sid })[0]
    if ($e -and ([string]$e.name).Trim()) { return ([string]$e.name).Trim() }
    if ($QS.Titles[[string]$q.id]) { return [string]$QS.Titles[[string]$q.id] }
    return [string]$q.title
}
function Test-PageIsChat([string]$page, $q) { $tx = $(if (([string]$q.id).StartsWith('local/')) { Get-LocalTitle $q } else { [string]$q.title }).Trim(); if (-not $tx -or -not $page) { return $false }; return ($page -ceq "$tx - Claude" -or $page -ceq $tx) }     # exact page name (no prefix match: 'Foo' must not match 'Foo bar')
function Test-LocalSafe($q) {     # automation on a local chat only when its title is unique among the Desktop local sessions (Desktop is driven by title)
    $tx = (Get-LocalTitle $q).Trim(); if (-not $tx) { return $false }
    $n = @(@(Get-DesktopLocal) | Where-Object { ([string]$_.name).Trim() -ceq $tx }).Count
    if ($n -gt 1) { Log "local[$($q.id)]: $n Desktop sessions share this title - automation disabled for it" 'WARN'; try { $tray.ShowBalloonTip(4000, 'Do it in Claude Desktop', 'Several Desktop chats have this title: rename one so the tray can tell them apart.', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }; return $false }
    return $true
}
function Get-LocalState($q) {      # state of a Desktop local (Cowork) chat from its transcript on disk (works with Desktop minimized). Read-only; content never logged.
    # <org>\<session folder>\.claude\projects\*\<cliSessionId>.jsonl (Claude Code format). Only the tail is read; fields used: type, isSidechain, message.role/stop_reason/content (text, tool_use id/name, AskUserQuestion questions/labels).
    $id = [string]$q.id; if (-not $id.StartsWith('local/')) { return $null }
    if ($null -eq $script:LocalSt) { $script:LocalSt = @{}; $script:LocalJf = @{}; $script:LocalJfAt = @{}; $script:LocalJfWarn = @{} }
    $c = $script:LocalSt[$id]; if ($c -and ((Get-Date) - $c.At).TotalSeconds -lt 2) { return $c }
    try {
        $sid = $id.Substring(6); $jf = $script:LocalJf[$sid]
        if (-not $script:LocalJfAt.ContainsKey($sid) -or ((Get-Date) - $script:LocalJfAt[$sid]).TotalSeconds -gt 60 -or ($jf -and -not (Test-Path -LiteralPath $jf))) {     # also a negative cache: no rescan on every call
            $null = Get-DesktopLocal; $od = $(if ($script:DeskLocalDir) { $script:DeskLocalDir[$sid] } else { $null }); $cli = $(if ($script:DeskLocalCli) { [string]$script:DeskLocalCli[$sid] } else { '' }); $jf = $null
            if ($od) {
                $short = ($sid -replace '^local_', ''); if ($short.Length -gt 8) { $short = $short.Substring(0, 8) }
                $cands = @()
                if ($cli) { $cands = @(Get-ChildItem (Join-Path $od "$short\.claude\projects\*\$cli.jsonl") -File -Force -ErrorAction SilentlyContinue); if (-not $cands.Count) { $cands = @(Get-ChildItem (Join-Path $od "*\.claude\projects\*\$cli.jsonl") -File -Force -ErrorAction SilentlyContinue) } }
                if (-not $cands.Count) { $cands = @(Get-ChildItem (Join-Path $od "$short\.claude\projects\*\*.jsonl") -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'agent-*' }) }
                $jx = @($cands | Sort-Object LastWriteTime -Descending)[0]; if ($jx) { $jf = $jx.FullName }
            }
            $script:LocalJf[$sid] = $jf; $script:LocalJfAt[$sid] = Get-Date
        }
        if (-not $jf) { if (-not $script:LocalJfWarn[$id]) { $script:LocalJfWarn[$id] = $true; Log ("local[{0}]: transcript not found (org folder known: {1})" -f $id, [bool]$(if ($script:DeskLocalDir) { $script:DeskLocalDir[$sid] })) 'WARN' }; return $null }
        $fi = Get-Item -LiteralPath $jf -Force
        if ($c -and $c.Len -eq $fi.Length -and $c.Mt -eq $fi.LastWriteTimeUtc) {
            $c.At = Get-Date; $age0 = ((Get-Date).ToUniversalTime() - $c.Mt).TotalSeconds
            if ($c.St -eq 'working' -and $c.TextOnly -and $age0 -gt 8) { $c.St = 'done' }       # streamed reply without stop_reason: quiet = finished
            if ($c.St -eq 'working' -and $age0 -gt 900) { $c.St = 'idle' }                       # app closed / interrupted without a trace
            return $c
        }
        $ents = New-Object System.Collections.ArrayList
        foreach ($win in 393216, 4194304) {     # a single huge line (image, big tool input) can fill the first window: retry larger once
            $fs = [IO.File]::Open($jf, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
            try { $n = [int][Math]::Min($fs.Length, $win); [void]$fs.Seek(-$n, [IO.SeekOrigin]::End); $buf = New-Object byte[] $n; $rd = 0; while ($rd -lt $n) { $kx = $fs.Read($buf, $rd, $n - $rd); if ($kx -le 0) { break }; $rd += $kx } } finally { $fs.Dispose() }
            $lines = @(([Text.Encoding]::UTF8.GetString($buf, 0, $rd)) -split "`n"); if ($n -lt $fi.Length -and $lines.Count) { $lines = @($lines | Select-Object -Skip 1) }
            $ents.Clear()
            foreach ($ln in $lines) { if (($ln.StartsWith('{"parentUuid"') -or $ln.StartsWith('{"type":"user"') -or $ln.StartsWith('{"type":"assistant"')) -and -not $ln.Contains('"isSidechain":true')) { try { $o = $ln | ConvertFrom-Json; if ($o.type -eq 'user' -or $o.type -eq 'assistant') { [void]$ents.Add($o) } } catch { } } }
            if ($ents.Count -or $n -ge $fi.Length) { break }
        }
        $st = 'idle'; $ask = $null; $pend = $null; $textOnly = $false; $msgs = New-Object System.Collections.ArrayList
        if ($ents.Count) {
            $last = $ents[$ents.Count - 1]; $m = $last.message; $bl = @(if ($m.content -is [string]) { } else { $m.content })
            if ($last.type -eq 'assistant') {
                $tus = @($bl | Where-Object { $_.type -eq 'tool_use' })
                $aq = @($tus | Where-Object { $_.name -eq 'AskUserQuestion' })[0]
                if ([string]$m.stop_reason -eq 'end_turn') { $st = 'done' }
                elseif ($aq -and $aq.input -and @($aq.input.questions).Count) { $q0 = @($aq.input.questions)[0]; $st = 'ask'; $pend = @{ Id = [string]$aq.id; Name = 'AskUserQuestion' }; $ask = @{ T = [string]$q0.question; O = @(@($q0.options) | ForEach-Object { [string]$_.label }); Multi = [bool]$q0.multiSelect; N = @($aq.input.questions).Count; Skip = ''; Page = ''; File = $true } }
                elseif ($tus.Count) { $st = 'working'; $pend = @{ Id = [string]$tus[-1].id; Name = [string]$tus[-1].name } }
                else { $textOnly = $true; $st = $(if (((Get-Date).ToUniversalTime() - $fi.LastWriteTimeUtc).TotalSeconds -gt 8) { 'done' } else { 'working' }) }
            } else {
                $ut = if ($m.content -is [string]) { [string]$m.content } else { (@($bl | ForEach-Object { if ($_.type -eq 'text') { [string]$_.text } elseif ($_.type -eq 'tool_result') { if ($_.content -is [string]) { [string]$_.content } else { (@($_.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join ' ' } } }) -join ' ') }
                $st = if ($ut -match '(?i)\[Request interrupted|interrupted by user|doesn.t want to (proceed|take this action)|tool use was rejected') { 'done' } else { 'working' }     # cancelled / rejected = the turn is over
            }
            if ($st -eq 'working' -and ((Get-Date).ToUniversalTime() - $fi.LastWriteTimeUtc).TotalSeconds -gt 900) { $st = 'idle' }
            $xi = 0
            foreach ($e in $ents) {
                $em = $e.message; $tx = ''
                if ($em.content -is [string]) { $tx = [string]$em.content } else { $tx = (@(@($em.content) | Where-Object { $_.type -eq 'text' } | ForEach-Object { [string]$_.text }) -join "`n") }
                if ($tx -match '<command-name>\s*(/[^<\s]+)\s*</command-name>') { $cn = $Matches[1]; $ca = $(if ($tx -match '(?s)<command-args>(.*?)</command-args>') { $Matches[1].Trim() } else { '' }); $tx = ($cn + ' ' + $ca).Trim() }     # a slash command (skill) the user ran
                $tx = ($tx -replace '(?s)<(system-reminder|command-[a-z-]+|local-command-[a-z-]+)>.*?</\1>', '').Trim()
                if (-not $tx) { continue }
                $xi++; [void]$msgs.Add([pscustomobject]@{ r = $(if ($e.type -eq 'user') { 'u' } else { 'a' }); t = $tx; x = $xi })
            }
        }
        $lae = @($ents | Where-Object { $_.type -eq 'assistant' })[-1]; $mdl = $(if ($lae) { [string]$(if ($lae.requestedModel) { $lae.requestedModel } else { $lae.message.model }) } else { '' }); $eff = $(if ($lae) { [string]$(if ($lae.perTurnEffort) { $lae.perTurnEffort } else { $lae.effort }) } else { '' })     # model + effort in use
        $c2 = @{ Model = $mdl; Effort = $eff; St = $st; Ask = $ask; TextOnly = $textOnly; PendId = $(if ($pend) { $pend.Id } else { '' }); PendName = $(if ($pend) { $pend.Name } else { '' }); Msgs = @($msgs | Select-Object -Last 12); Len = $fi.Length; Mt = $fi.LastWriteTimeUtc; At = (Get-Date) }
        if (-not $c -or $c.St -ne $st -or $c.PendId -ne $c2.PendId) { Log ("local[{0}]: state {1}{2} (transcript {3} B, {4} entries)" -f $id, $st, $(if ($c) { " (was $($c.St))" } else { '' }), $fi.Length, $ents.Count) }     # sizes/states only, never content
        $script:LocalSt[$id] = $c2; return $c2
    } catch { Log "local[$id]: transcript read: $($_.Exception.Message)" 'WARN'; return $null }
}
function Invoke-LocalWake($q, $ls) {      # a tool call waiting with no transcript write may be a request card that a minimized Desktop doesn't draw: restore it behind (no focus) so the tray can read it; minimize again once resolved. Per chat. Config localWake=false disables.
    try {
        if ($null -eq $script:Woke) { $script:Woke = @{} }
        $id = [string]$q.id; $wk = $script:Woke[$id]
        if ($ls.St -eq 'ask' -or ($ls.St -eq 'working' -and $ls.PendId)) { $Probe.CardsUntil = (Get-Date).AddSeconds(6) }     # the watcher looks for request cards only while something waits
        if ($wk -and $wk.Pid -ne $ls.PendId) {
            $script:Woke.Remove($id)
            $others = @($script:Woke.Keys | Where-Object { $script:Woke[$_].Hwnd -eq $wk.Hwnd }).Count
            if ($wk.Hwnd -ne [IntPtr]::Zero -and -not $others -and [ClaudeTray.Native]::GetForegroundWindow() -ne $wk.Hwnd) { [void][ClaudeTray.Native]::ShowWindow($wk.Hwnd, 7); Log "local[$id]: request resolved - Claude Desktop minimized again" }
            $wk = $null
        }
        if ($Cfg.localWake -eq $false) { return }
        if ($ls.St -eq 'working' -and $ls.PendId -and -not $wk) {
            $age = ((Get-Date).ToUniversalTime() - $ls.Mt).TotalSeconds
            $susp = [string]$ls.PendName -match '(?i)allow|request|permission|approv|connect|install|delete|chrome|computer|browser|navigate'
            $quiet = [string]$ls.PendName -match '^(mcp__workspace__bash|mcp__workspace__web_fetch|Agent|Task\w*|WebSearch|WebFetch|Read|Write|Edit|Grep|Glob|ToolSearch|Skill)$'
            if (($susp -and $age -ge 3) -or (-not $quiet -and $age -ge 12) -or $age -ge 45) {
                $h = [IntPtr]::Zero; $w = Get-ClaudeWindow
                if ($w -and [ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) {
                    [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 4); [void][ClaudeTray.Native]::SetWindowPos($w.MainWindowHandle, [IntPtr]1, 0, 0, 0, 0, 0x0013); $h = $w.MainWindowHandle
                    $Probe.FastUntil = (Get-Date).AddSeconds(20)
                    Log ("local[{0}]: tool call waiting {1:0}s - Claude Desktop restored behind (no focus) to read a possible request" -f $id, $age)
                }
                $script:Woke[$id] = @{ Pid = [string]$ls.PendId; Hwnd = $h }
            }
        }
    } catch { }
}
function Test-LocalIdleSeen($q, $ls) {     # the transcript looks unfinished but Claude Desktop shows no running turn (cancelled in the app, crash...): idle until the transcript changes
    $id = [string]$q.id; if ($null -eq $script:LocalIdle) { $script:LocalIdle = @{} }
    if ($script:LocalIdle.ContainsKey($id)) { if ([long]$script:LocalIdle[$id] -eq [long]$ls.Len) { return $true }; $script:LocalIdle.Remove($id) }
    $age = ((Get-Date).ToUniversalTime() - $ls.Mt).TotalSeconds
    if ($age -ge 8 -and $Probe.Page -and (Test-PageIsChat ([string]$Probe.Page) $q) -and ((Get-Date) - $Probe.At).TotalSeconds -lt 5 -and -not $Probe.Working -and -not $Probe.Ask) { $script:LocalIdle[$id] = [long]$ls.Len; Log "local[$id]: transcript unfinished but Desktop shows no running turn - idle"; return $true }
    return $false
}
function Get-LocalAsk($q) {      # the question / request this Desktop local chat shows now (watcher card on the exact page, else the transcript's pending question)
    if (-not ([string]$q.id).StartsWith('local/')) { return $null }
    $id = [string]$q.id; $ls = Get-LocalState $q; $a = $Probe.Ask
    $mu = $(if ($script:AskMute) { $script:AskMute[$id] } else { $null }); $muted = [bool]($mu -and (Get-Date) -lt $mu.Until)
    if ($a -and -not $muted -and ((Get-Date) - $Probe.At).TotalSeconds -lt 5 -and (Test-PageIsChat ([string]$a.Page) $q)) {
        if (-not $a.Gen) { return $a }
        if ($ls -and $ls.St -eq 'working' -and $ls.PendId) { return $a }                     # a request card counts only while a tool call waits (no false cards)
    }
    if ($ls -and $ls.St -eq 'ask' -and -not ($muted -and $mu.Pid -eq $ls.PendId)) { return $ls.Ask }
    return $null
}
function Get-LocalQ($q) {      # the card for the panel (multi-choice / several questions: shown, answered in Desktop)
    $la = Get-LocalAsk $q; if (-not $la) { return $null }
    $ls = Get-LocalState $q
    if ($ls -and $ls.St -eq 'ask' -and $ls.Ask -and ($ls.Ask.Multi -or [int]$ls.Ask.N -gt 1)) { return [ordered]@{ t = 'Answer in Claude Desktop (multi-choice or several questions): ' + [string]$la.T; o = @(); skip = ''; card = $true; gen = $true } }
    return [ordered]@{ t = [string]$la.T; o = @($la.O | ForEach-Object { @{ l = [string]$_ } }); skip = [string]$la.Skip; card = $true; gen = [bool]$la.Gen }
}
function Test-ChatWorking($q) { if (([string]$q.id).StartsWith('local/')) { $ls = Get-LocalState $q; if ($ls) { Invoke-LocalWake $q $ls; if (Get-LocalAsk $q) { return $false }; if ($ls.St -eq 'working' -and (Test-LocalIdleSeen $q $ls)) { return $false }; return ($ls.St -eq 'working') } }; if (Get-LocalAsk $q) { return $false }; $wc = Get-WebChat $q; if ($wc) { return ([bool]$wc.Working -or ($wc.Expect -and ((Get-Date) - $wc.Expect).TotalSeconds -lt 8 -and -not $wc.SawWork)) }; return ($Probe.Working -and $Probe.Page -and $q.title -and $Probe.Page.StartsWith([string]$q.title) -and ((Get-Date) - $Probe.At).TotalSeconds -lt 5) }
function Get-ClaudeWindow { return @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^claude' -and $_.MainWindowHandle -ne 0 })[0] }
function Get-ChatPageName {               # name of the web document inside the app window ("<chat title> - Claude"); needs the a11y wake + a short settle
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $w = Get-ClaudeWindow; if (-not $w) { return '' }
        $r = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.MainWindowHandle)
        $docC = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Document)
        for ($i = 0; $i -lt 6; $i++) {                  # the web tree wakes up lazily: retry up to ~1 s
            $null = $r.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            foreach ($d in @($r.FindAll([System.Windows.Automation.TreeScope]::Descendants, $docC))) { $nm = [string]$d.Current.Name; if ($nm -and $nm -ne 'Claude') { return $nm } }
            Start-Sleep -Milliseconds 170
        }
        Log 'page name: no named document in the app tree' 'DEBUG'; return ''
    } catch { Log "page name: $($_.Exception.Message)" 'DEBUG'; return '' }
}
function Test-ChatInFront($q) {
    $want = [string]$q.title; if (-not $want) { return $false }
    $w = Get-ClaudeWindow; if (-not $w) { return $false }
    if (([string]$q.id).StartsWith('local/')) { if (Test-PageIsChat ([string]$w.MainWindowTitle) $q) { return $true }; $pn = Get-ChatPageName; $UI.LastPage = $pn; return (Test-PageIsChat $pn $q) }     # exact title for local chats
    if (([string]$w.MainWindowTitle).StartsWith($want)) { return $true }      # plain prefix: titles like [X] are not wildcards
    $pn = Get-ChatPageName; $UI.LastPage = $pn
    return ($pn -and $pn.StartsWith($want))
}
function Update-DesktopPark {     # setting 'parkDesktop', experimental: a minimized Claude Desktop is kept restored but parked off-screen (no focus), so the tray can work in it without anything showing; when you bring it up (taskbar, Alt+Tab, tray 'open') it comes back where it was
    try {
        $w = Get-ClaudeWindow; if (-not $w) { $script:Park = $null; return }; $h = $w.MainWindowHandle
        $psig = "{0}|{1}|{2}" -f [ClaudeTray.Native]::IsIconic($h), [bool]$script:Park, ([ClaudeTray.Native]::GetForegroundWindow() -eq $h); if ($psig -ne $script:ParkSig) { $script:ParkSig = $psig; Log "park: state minimized|parked|foreground = $psig" }     # diag
        if (-not ('ClaudeTray.Place' -as [type])) { Set-DesktopGhost $h $false }     # loads the placement API
        if ($script:Park -and $script:Park.H -ne $h) { $script:Park = $null }
        if (-not ($Cfg.parkDesktop -and $Caps.Park)) { if ($script:Park) { Undo-DesktopPark $false }; return }
        if ($script:Park) {
            if ($script:ParkHold -and (Get-Date) -lt $script:ParkHold) { return }     # the tray itself is giving it focus for a moment (Enter for a rename / typed answer)
            $fg = [ClaudeTray.Native]::GetForegroundWindow() -eq $h
            if ($fg -or [ClaudeTray.Native]::IsIconic($h)) { Undo-DesktopPark $fg }     # you brought it up (or something minimized it): back on screen / minimized
            return
        }
        if (-not [ClaudeTray.Native]::IsIconic($h)) { return }
        $wp = New-Object ClaudeTray.Place+WP; $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp); if (-not [ClaudeTray.Place]::GetWindowPlacement($h, [ref]$wp)) { return }
        $g = New-Object ClaudeTray.Place+WP; $g.length = $wp.length; [void][ClaudeTray.Place]::GetWindowPlacement($h, [ref]$g)
        $rc = $g.rc; $wdt = $rc.R - $rc.L; $hgt = $rc.B - $rc.T; $rc.L = -32000; $rc.T = -32000; $rc.R = -32000 + $wdt; $rc.B = -32000 + $hgt; $g.rc = $rc; $g.flags = $g.flags -band (-bnot 2); $g.showCmd = 4     # SW_SHOWNOACTIVATE, off-screen
        $script:Park = @{ H = $h; Wp = $wp }
        [void][ClaudeTray.Place]::SetWindowPlacement($h, [ref]$g)
        Log 'park: Claude Desktop parked off-screen (you minimized it)'
    } catch { Log "park: $($_.Exception.Message)" 'WARN'; $script:Park = $null }
}
function Undo-DesktopPark([bool]$show) {     # back where it was (shown if you brought it up, else minimized)
    try {
        $p = $script:Park; if (-not $p) { return }; $script:Park = $null
        $wp = $p.Wp; $wp.showCmd = $(if ($show) { if (($wp.flags -band 2) -ne 0) { 3 } else { 1 } } else { 2 })
        [void][ClaudeTray.Place]::SetWindowPlacement($p.H, [ref]$wp)
        if ($show) { [void][ClaudeTray.Native]::SetForegroundWindow($p.H) }
        Log ("park: Claude Desktop back {0}" -f $(if ($show) { 'on screen' } else { 'minimized' }))
    } catch { Log "park: $($_.Exception.Message)" 'WARN' }
}
function Open-ClaudeApp {                           # bring the Claude app forward, or start it
    if ($script:Park) { Undo-DesktopPark $true }
    $w = Get-ClaudeWindow
    if ($w) { if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 9) }; [void][ClaudeTray.Native]::SetForegroundWindow($w.MainWindowHandle); Log 'open app: brought to front'; return }
    $exe = @("$env:LOCALAPPDATA\AnthropicClaude\claude.exe", "$env:LOCALAPPDATA\Programs\Claude\Claude.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    try { if ($exe) { Start-Process $exe } else { Start-Process 'claude://' }; Log 'open app: started' } catch { Log "open app: $($_.Exception.Message)" 'WARN' }
}
function Set-DesktopGhost($hwnd, [bool]$on) {     # experimental, setting 'ghostDesktop': while the tray works in a minimized Claude Desktop, its restore position is moved off-screen, so the window is restored where nobody sees it (transparency does not work on Chromium windows); placement put back afterwards (and by a 20 s safety net)
    try {
        if ($hwnd -eq $null -or $hwnd -eq [IntPtr]::Zero) { return }
        if (-not ('ClaudeTray.Place' -as [type])) {
            Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
namespace ClaudeTray { public static class Place {
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct WP { public int length, flags, showCmd; public POINT ptMin, ptMax; public RECT rc; }
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WP p);
  [DllImport("user32.dll")] public static extern bool SetWindowPlacement(IntPtr h, ref WP p);
} }
"@
        }
        if ($on) {
            if (-not ($Cfg.ghostDesktop -and $Caps.Ghost) -or $script:Ghost -or -not [ClaudeTray.Native]::IsIconic($hwnd)) { return }
            $wp = New-Object ClaudeTray.Place+WP; $wp.length = [System.Runtime.InteropServices.Marshal]::SizeOf($wp)
            if (-not [ClaudeTray.Place]::GetWindowPlacement($hwnd, [ref]$wp)) { return }
            $script:Ghost = @{ H = $hwnd; Wp = $wp; At = (Get-Date) }
            $g = New-Object ClaudeTray.Place+WP; $g.length = $wp.length; [void][ClaudeTray.Place]::GetWindowPlacement($hwnd, [ref]$g)     # a separate copy (PS struct pitfalls: nested fields must be set through a copy)
            $rc = $g.rc; $wdt = $rc.R - $rc.L; $hgt = $rc.B - $rc.T; $rc.L = -32000; $rc.T = -32000; $rc.R = -32000 + $wdt; $rc.B = -32000 + $hgt; $g.rc = $rc; $g.flags = $g.flags -band (-bnot 2)     # no 'restore to maximized'
            [void][ClaudeTray.Place]::SetWindowPlacement($hwnd, [ref]$g)
        } elseif ($script:Ghost -and $script:Ghost.H -eq $hwnd) {
            $wp = $script:Ghost.Wp; $script:Ghost = $null
            if (-not [ClaudeTray.Native]::IsIconic($hwnd)) { $wp.showCmd = $(if (($wp.flags -band 2) -ne 0) { 3 } else { 4 }) }     # left open (handed to you / safety net): back on screen, as it was
            [void][ClaudeTray.Place]::SetWindowPlacement($hwnd, [ref]$wp)
        }
    } catch { Log "ghost: $($_.Exception.Message)" 'WARN'; $script:Ghost = $null }
}
function Find-SidebarEntry($uiRoot, [string]$ttl) {     # the Desktop sidebar entry of a chat. Chats in a Local project: ListItem named exactly the title (its button is clickable); top-level chats: button '<status> <title>' (status prefix varies: unread / read / idle / waiting..., any language). Unique match only.
    $AE = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
    $btnC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $sb = $uiRoot.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'dframe-sidebar font-normal font-control'))); $scope = $(if ($sb) { $sb } else { $uiRoot })
    $c = @()
    foreach ($li in @($scope.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::ListItem))))) {
        if (([string]$li.Current.Name).Trim() -ceq $ttl) { $b0 = @(@($li.FindAll($TS::Descendants, $btnC)) | Where-Object { [string]$_.Current.ClassName -like 'w-full shrink-0*' })[0]; if ($b0) { $c += $b0 } }
    }
    if (-not $c.Count) {
        foreach ($bt in @($scope.FindAll($TS::Descendants, $btnC))) {
            if (-not ([string]$bt.Current.ClassName -like 'w-full shrink-0*')) { continue }
            $nm = ([string]$bt.Current.Name).Trim()
            if ($nm -ceq $ttl -or ($nm.EndsWith(' ' + $ttl) -and ($nm.Length - $ttl.Length) -le 40)) { $c += $bt }
        }
    }
    if ($c.Count -eq 1) { return $c[0] }
    if ($c.Count -gt 1) { Log "sidebar: $($c.Count) entries match this title - not choosing" 'WARN' }
    return $null
}
function Enter-LocalChat($q) {     # make this local chat the one open in Claude Desktop (no focus). Returns @{ Ok; Prev = title of the chat that was open; Hwnd; WasMin; Moved; SbBtn }
    $r = @{ Ok = $false; Prev = ''; Hwnd = [IntPtr]::Zero; WasMin = $false; Moved = $false; SbBtn = $null }
    try {
        $w = Get-ClaudeWindow; if (-not $w) { return $r }; $r.Hwnd = $w.MainWindowHandle
        if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) { $r.WasMin = $true; Set-DesktopGhost $w.MainWindowHandle $true; [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 4); [void][ClaudeTray.Native]::SetWindowPos($w.MainWindowHandle, [IntPtr]1, 0, 0, 0, 0, 0x0013); Start-Sleep -Milliseconds 400 }
        if (Test-ChatInFront $q) { $r.Ok = $true; return $r }
        if (-not (Test-LocalSafe $q)) { return $r }
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $AE = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
        $uiRoot = $AE::FromHandle([IntPtr]$w.MainWindowHandle); $ttl = (Get-LocalTitle $q).Trim()
        $pn0 = Get-ChatPageName; if ($pn0) { $r.Prev = ($pn0 -replace ' - Claude$', '') }
        $hit = $null; for ($i = 0; $i -lt 4 -and -not $hit; $i++) { $hit = Find-SidebarEntry $uiRoot $ttl; if (-not $hit) { Start-Sleep -Milliseconds 200 } }
        if (-not $hit) {     # sidebar hidden: show it (a toggle control), search again; hidden again on exit
            $sbg = $uiRoot.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'dframe-sidebar font-normal font-control')))
            $btnC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            $vis = [bool]($sbg -and @($sbg.FindAll($TS::Descendants, $btnC)).Count)
            if (-not $vis) {
                $tg = @(@($uiRoot.FindAll($TS::Descendants, $btnC)) | Where-Object { [string]$_.Current.Name -match '(?i)sidebar|barre lat|seitenleiste|barra lateral|zijbalk|boczny' -and -not ([string]$_.Current.Name -match '(?i)redimension|resize') })[0]
                if ($tg -and (Invoke-UiaAny $tg)) { $r.SbBtn = $tg; Start-Sleep -Milliseconds 300; for ($i = 0; $i -lt 6 -and -not $hit; $i++) { $hit = Find-SidebarEntry $uiRoot $ttl; if (-not $hit) { Start-Sleep -Milliseconds 200 } } }
            }
        }
        if (-not $hit) {     # inside a collapsed Local project: expand it (toggle whose name ends with the project name)
            $sid0 = ([string]$q.id) -replace '^local/', ''; $de = @(@(try { Get-DesktopLocal } catch { }) | Where-Object { [string]$_.id -eq $sid0 })[0]; $pj = $(if ($de) { ([string]$de.pn).Trim() } else { '' })
            if ($pj) {
                $btnC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
                $ex = @(@($uiRoot.FindAll($TS::Descendants, $btnC)) | Where-Object { $nm = ([string]$_.Current.Name).Trim(); $nm -cne $pj -and $nm.EndsWith(' ' + $pj) -and $_.Current.ClassName -like 'hide-focus-ring*' })[0]
                if ($ex -and (Invoke-UiaAny $ex)) { Start-Sleep -Milliseconds 300; for ($i = 0; $i -lt 6 -and -not $hit; $i++) { $hit = Find-SidebarEntry $uiRoot $ttl; if (-not $hit) { Start-Sleep -Milliseconds 200 } } }
            }
        }
        if (-not $hit) { Log "nav[$($q.id)]: chat not found in the Desktop sidebar" 'WARN'; return $r }
        if (-not (Invoke-UiaAny $hit)) { Log "nav[$($q.id)]: sidebar entry not clickable" 'WARN'; return $r }
        $r.Moved = $true
        for ($i = 0; $i -lt 15 -and -not $r.Ok; $i++) { Start-Sleep -Milliseconds 200; $r.Ok = Test-ChatInFront $q }
        Log ("nav[{0}]: switched Claude Desktop to this chat - {1}" -f $q.id, $(if ($r.Ok) { 'ok' } else { 'NOT confirmed by the page title' })) $(if ($r.Ok) { 'INFO' } else { 'WARN' })
    } catch { Log "nav[$($q.id)]: $($_.Exception.Message)" 'WARN' }
    return $r
}
function Exit-LocalChat($nav, [bool]$back = $true) {     # after acting in the background: back to the chat that was open, sidebar as it was, minimized again if it was
    try {
        if (-not $nav -or $nav.Hwnd -eq [IntPtr]::Zero) { return }
        $uiRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$nav.Hwnd)
        if ($back -and $nav.Moved -and $nav.Prev) { Start-Sleep -Milliseconds 300; $pv = Find-SidebarEntry $uiRoot ([string]$nav.Prev); if ($pv) { [void](Invoke-UiaAny $pv); Log 'nav: back to the chat that was open' } }
        if ($nav.SbBtn) { Start-Sleep -Milliseconds 200; try { [void](Invoke-UiaAny $nav.SbBtn) } catch { } }
        if ($nav.WasMin -and [ClaudeTray.Native]::GetForegroundWindow() -ne $nav.Hwnd) { Start-Sleep -Milliseconds 250; [void][ClaudeTray.Native]::ShowWindow($nav.Hwnd, 7) }
    } catch { }
    finally { if ($nav -and $nav.Hwnd) { Start-Sleep -Milliseconds 150; Set-DesktopGhost $nav.Hwnd $false } }
}
function Rename-LocalChat($q, [string]$name) {     # rename a Desktop local chat through its title button (UIA); brief focus on Desktop to confirm with Enter
    try {
        if (-not (Test-LocalSafe $q)) { return $false }
        $nav = Enter-LocalChat $q     # switch Desktop to it first (any open chat)
        if (-not $nav.Ok) { Log "rename[$($q.id)]: could not open it in Claude Desktop" 'WARN'; return $false }
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $AE = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
        $w = Get-ClaudeWindow; $uiRoot = $AE::FromHandle([IntPtr]$w.MainWindowHandle)
        $slot = $uiRoot.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::AutomationIdProperty, 'cowork-title-slot')))
        if (-not $slot) { Log "rename[$($q.id)]: title area not found" 'WARN'; return $false }
        $tb = $slot.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))
        if (-not $tb) { Log "rename[$($q.id)]: title button not found" 'WARN'; return $false }
        $ctx = @{ PrevFg = [ClaudeTray.Native]::GetForegroundWindow(); WasMin = $false; WasFront = $false; Hwnd = $w.MainWindowHandle }
        if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 9) }
        [void][ClaudeTray.Native]::SetForegroundWindow($w.MainWindowHandle)
        $tb.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $edx = $null; $edC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
        for ($i = 0; $i -lt 10 -and -not $edx; $i++) { Start-Sleep -Milliseconds 150; $edx = $slot.FindFirst($TS::Descendants, $edC); if (-not $edx) { try { $fe = $AE::FocusedElement; if ($fe -and $fe.Current.ControlType -eq [System.Windows.Automation.ControlType]::Edit -and -not ([string]$fe.Current.ClassName -like 'tiptap*')) { $edx = $fe } } catch { } } }
        if (-not $edx) { Restore-Focus $ctx; Log "rename[$($q.id)]: no name field after clicking the title" 'WARN'; return $false }
        $edx.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue($name); $edx.SetFocus(); Start-Sleep -Milliseconds 150
        $ok = $false; try { $ok = ([ClaudeTray.Native]::GetForegroundWindow() -eq $w.MainWindowHandle) -and [System.Windows.Automation.Automation]::Compare($AE::FocusedElement, $edx) } catch { }
        if (-not $ok) { Restore-Focus $ctx; Log "rename[$($q.id)]: name field not focused - Enter not sent" 'WARN'; return $false }     # SAFETY: never press Enter elsewhere
        $script:ParkHold = (Get-Date).AddSeconds(4); Set-DesktopGhost $w.MainWindowHandle $false; [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Milliseconds 600; Restore-Focus $ctx
        $script:DeskLocalAt = [datetime]::MinValue
        $done = $false; for ($i = 0; $i -lt 10 -and -not $done; $i++) { $pn = Get-ChatPageName; if ($pn -ceq "$name - Claude" -or $pn -ceq $name) { $done = $true } else { Start-Sleep -Milliseconds 300 } }
        Log ("rename[{0}]: {1}" -f $q.id, $(if ($done) { 'renamed in Claude Desktop' } else { 'sent, not confirmed by the page title' })) $(if ($done) { 'INFO' } else { 'WARN' })
        Exit-LocalChat $nav     # back to the chat that was open, minimized again if it was
        return $done
    } catch { Log "rename[$($q.id)]: $($_.Exception.Message)" 'WARN'; return $false }
}
function Add-LocalFolder($q) {     # pick files (several) or a folder (Open with nothing selected = the folder you are in); the Cowork session is asked to request access (approval card in the tray) and use them. Paths not logged.
    $dlg = New-Object System.Windows.Forms.OpenFileDialog; $dlg.Title = 'Files for Claude - or open a folder and click Open with nothing selected to give the whole folder'
    $dlg.Multiselect = $true; $dlg.CheckFileExists = $false; $dlg.ValidateNames = $false; $dlg.FileName = 'Select this folder'; $dlg.Filter = 'All files (*.*)|*.*'
    $own = New-Object System.Windows.Forms.Form; $own.TopMost = $true; $own.ShowInTaskbar = $false; $own.StartPosition = 'Manual'; $own.Location = New-Object System.Drawing.Point -32000, -32000; $own.Size = New-Object System.Drawing.Size 1, 1
    try { $own.Show(); $r = $dlg.ShowDialog($own) } finally { $own.Close(); $own.Dispose() }
    if ($r -ne [System.Windows.Forms.DialogResult]::OK) { return }
    $picked = @($dlg.FileNames | Where-Object { $_ })
    $files = @($picked | Where-Object { (Split-Path $_ -Leaf) -ne 'Select this folder' -and (Test-Path -LiteralPath $_ -PathType Leaf) })
    $dirs0 = @($picked | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
    if (-not $files.Count -and -not $dirs0.Count) { $dirs0 = @(Split-Path $picked[0] -Parent) }     # 'Select this folder' (nothing chosen) = the folder shown in the dialog
    if ($files.Count) {
        $dirs = @($files | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)
        $msg = "Please request access to $(if ($dirs.Count -gt 1) { 'these folders' } else { 'this folder' }) for this session (use your folder-access tool): $($dirs -join '; ') - then use these files: $($files -join '; ')"
    } else { $msg = "Please request access to this folder for this session (use your folder-access tool): $($dirs0[0])" }
    if (Send-ToChat $q $msg 'addfolder') { Log ("addfolder[{0}]: asked the session for {1} (paths not logged)" -f $q.id, $(if ($files.Count) { "$($files.Count) file(s)" } else { 'a folder' })) }
}
function Invoke-UiaAny($el) {     # press a control whatever pattern it exposes (Invoke, Toggle, ExpandCollapse)
    foreach ($pt in [System.Windows.Automation.InvokePattern]::Pattern, [System.Windows.Automation.TogglePattern]::Pattern, [System.Windows.Automation.ExpandCollapsePattern]::Pattern) {
        $o = $null; if ($el.TryGetCurrentPattern($pt, [ref]$o) -and $o) {
            if ($o -is [System.Windows.Automation.InvokePattern]) { $o.Invoke() } elseif ($o -is [System.Windows.Automation.TogglePattern]) { $o.Toggle() } else { if ($o.Current.ExpandCollapseState -eq [System.Windows.Automation.ExpandCollapseState]::Expanded) { $o.Collapse() } else { $o.Expand() } }
            return $true
        }
    }
    return $false
}
function Open-Chat($q, [bool]$inBrowser) {
    if (([string]$q.id).StartsWith('local/')) {     # no deep link for Desktop local chats: bring Desktop forward and switch to the chat through its sidebar
        Open-ClaudeApp
        $nav = Enter-LocalChat $q
        if (-not $nav.Ok) { try { $tray.ShowBalloonTip(4000, 'Open it in Claude Desktop', "Couldn't switch Claude Desktop to this chat.", [System.Windows.Forms.ToolTipIcon]::None) } catch { } }
        return
    }
    if (-not $inBrowser -and (Test-ChatInFront $q)) {          # already on it: just bring the app forward, no deep link round trip
        $w = Get-ClaudeWindow; if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 9) }; [void][ClaudeTray.Native]::SetForegroundWindow($w.MainWindowHandle); Log "open app: already on $($q.id), brought to front"; return
    }
    $u = if ($inBrowser) { "https://claude.ai/$($q.id)" } else { "claude://claude.ai/$($q.id)" }
    try { Start-Process $u; Log "open $u" } catch { Log "open $u : $($_.Exception.Message)" 'ERR' }
}
function Restore-Focus($ctx) {                 # put the user's world back after a send/stop
    try {
        if ($ctx.WasFront) { return }
        if ($ctx.WasMin -and $ctx.Hwnd) { [void][ClaudeTray.Native]::ShowWindow($ctx.Hwnd, 7) }          # SW_SHOWMINNOACTIVE
        if ($ctx.PrevFg -eq $hPop -or -not $ctx.PrevFg -or $ctx.PrevFg -eq [IntPtr]::Zero) { if ($UI.Shown) { $pop.Activate() } }
        else { [void][ClaudeTray.Native]::SetForegroundWindow($ctx.PrevFg) }
    } catch { Log "restore focus: $($_.Exception.Message)" 'WARN' }
}
function Send-ToChat($q, [string]$text, [string]$via = 'field', [bool]$Force = $false, [string[]]$Files = @()) {
    # SAFE ORDER: make sure the right chat is the open page -> paste -> Enter -> restore focus -> verify (async, watcher)
    if (-not $text -and -not @($Files).Count) { return $false }
    if ($UI.LastSend -and ((Get-Date) - $UI.LastSend.At).TotalSeconds -lt 5 -and $UI.LastSend.Text -eq $text -and $UI.LastSend.Id -eq [string]$q.id -and -not @($Files).Count) { Log "send: ignored duplicate within 5 s ($via)" 'DEBUG'; return $true }
    $UI.LastSend = @{ At = (Get-Date); Text = $text; Id = [string]$q.id }
    if (([string]$q.id).StartsWith('local/')) {          # a Desktop local chat can't be typed into from here: clipboard + bring Claude Desktop forward, the user pastes
        if (@($Files).Count -or -not $text) { Log "send[$($q.id)]: local chat - attachments not supported" 'WARN'; try { $tray.ShowBalloonTip(4000, 'Not sent', 'Files can''t be sent to a Claude Desktop local chat from the tray.', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }; return $false }
        $nav = Enter-LocalChat $q     # switch Desktop to this chat (background), send, back to the open one. Never pastes elsewhere, never sends twice.
        if (-not $nav.Ok) { Exit-LocalChat $nav $false; Log "send[$($q.id)]: could not switch Claude Desktop to this chat - not sent" 'WARN'; try { $tray.ShowBalloonTip(5000, 'Not sent', "Couldn't open this chat in Claude Desktop. Your text is kept in the tray.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }; return $false }
        $rs = Send-LocalNoFocus $q $text
        Exit-LocalChat $nav
        if ($rs -eq 'sent') { $r = Get-Results $q; $r.sent = @(@(@($r.sent) + [pscustomobject][ordered]@{ at = (Get-Iso (Get-Date)); text = (Get-SentText $text) }) | Select-Object -Last 2); Save-Results $q $r; $Probe.ExpectAt = Get-Date; $Probe.ExpectPage = $Probe.Page; $Probe.SawStop = $false; return $true }
        $why = switch ($rs) { 'busy' { 'This chat has unsent text in Claude Desktop (send or clear it there).' } 'refused' { 'Claude Desktop did not take the message (a command it does not know?).' } default { 'Claude Desktop could not be typed into.' } }
        try { $tray.ShowBalloonTip(5000, 'Not sent - your text is kept', $why, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
        return $false
    }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $ph = [ordered]@{}
    $ctx = @{ PrevFg = [ClaudeTray.Native]::GetForegroundWindow(); WasMin = $false; WasFront = $false; Hwnd = [IntPtr]::Zero }
    $short = if ($text.Length -gt 60) { $text.Substring(0, 60) + '...' } else { $text }
    Log ("send[{0}] start via={1} working={2}: {3}" -f $q.id, $via, (Test-ChatWorking $q), (Mask $text))
    $wc = Get-WebChat $q
    if ($wc -and [string]$Cfg.sendVia -ne 'app') {      # through the hidden browser tab: the desktop app is never touched
        $key = [guid]::NewGuid().ToString('N')
        [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'send'; Text = $text; Files = @($Files); Key = $key; At = (Get-Date) })
        $k0 = (($text -replace '\s+', ' ').Trim()); if ($k0.Length -gt 40) { $k0 = $k0.Substring(0, 40) }
        $UI.WebSends[$key] = @{ Q = $q; Text = $text; At = (Get-Date); Users = [int]$wc.Users; Files = @($Files).Count; Key0 = $k0 }
        $Probe.ExpectPage = ''; $wc.SawWork = $false; $wc.Expect = Get-Date
        $sentRec = [ordered]@{ at = (Get-Iso (Get-Date)); text = (Get-SentText $text) }; if (@($Files).Count) { $sentRec.files = @($Files | ForEach-Object { Split-Path $_ -Leaf }) }
        $r = Get-Results $q; $r.sent = @(@(@($r.sent) + [pscustomobject]$sentRec) | Select-Object -Last 2); Save-Results $q $r
        $UI.Sending[[string]$q.id] = @{ Text = $(if ($text) { $text } else { '(' + (@($Files | ForEach-Object { Split-Path $_ -Leaf }) -join ', ') + ')' }); At = (Get-Date) }
        Log ("send[{0}] queued to the browser tab (users {1})" -f $q.id, $wc.Users)
        return $true
    }
    if (@($Files).Count) { Log "send[$($q.id)]: attachments need the hidden browser (not ready) - not sent" 'WARN'; try { $tray.ShowBalloonTip(4000, 'Not sent', 'Files can''t be sent to this chat yet. Try again in a few seconds.', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }; return $false }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $w0 = Get-ClaudeWindow
        if (-not $w0) { throw 'Claude desktop app is not running' }
        $ctx.Hwnd = $w0.MainWindowHandle; $ctx.WasMin = [ClaudeTray.Native]::IsIconic($ctx.Hwnd); $ctx.WasFront = ($ctx.PrevFg -eq $ctx.Hwnd)
        if ($Cfg.holdWhileWorking -and -not $Force -and (Test-ChatWorking $q)) {
            $UI.Queue[[string]$q.id] = $text; $UI.QueuedAt[[string]$q.id] = Get-Date
            Log "send[$($q.id)] held: Claude is working (sending now would interrupt). Will send when idle, or 'send now'."; return $true
        }
        $onIt = Test-ChatInFront $q; $ph.detect = $sw.ElapsedMilliseconds
        if (-not $onIt -and ([string]$q.id).StartsWith('local/')) { Restore-Focus $ctx; try { [System.Windows.Forms.Clipboard]::SetText($text) } catch { }; Log "send[$($q.id)]: local chat no longer in front - text copied, nothing pasted" 'WARN'; try { $tray.ShowBalloonTip(4000, 'Copied - paste it in Claude Desktop', 'The chat was no longer the one open in Claude Desktop.', [System.Windows.Forms.ToolTipIcon]::None) } catch { }; return $false }     # no deep link for local chats
        if (-not $onIt) {
            Start-Process "claude://claude.ai/$($q.id)"
            $deadline = (Get-Date).AddSeconds(6)
            do { Start-Sleep -Milliseconds 100 } while ((Get-Date) -lt $deadline -and -not (Test-ChatInFront $q))
            $ph.deeplink = $sw.ElapsedMilliseconds
            if (-not (Test-ChatInFront $q)) {                 # SAFETY: never paste into whatever chat happens to be open
                Restore-Focus $ctx
                Log ("send[{0}] ABORTED: page is '{1}', not this chat, after deep link ({2} ms) - nothing pasted" -f $q.id, (Get-PageLabel $UI.LastPage), $sw.ElapsedMilliseconds) 'ERR'
                try { $tray.ShowBalloonTip(4000, 'Not sent', "Couldn't open '$($q.title)' in the app - your text is kept.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
                return $false
            }
            Start-Sleep -Milliseconds 250                   # let the composer mount
        }
        if ($Cfg.holdWhileWorking -and -not $Force -and (Test-ChatWorking $q)) {
            $UI.Queue[[string]$q.id] = $text; $UI.QueuedAt[[string]$q.id] = Get-Date; Restore-Focus $ctx
            Log "send[$($q.id)] held: Claude is working (sending now would interrupt). Will send when idle, or 'send now'."; return $true
        }
        $w = Get-ClaudeWindow; $ctx.Hwnd = $w.MainWindowHandle
        # only un-minimize (SW_RESTORE on a maximized window would un-maximize it); never move or resize
        if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 9) }
        $fgOk = [ClaudeTray.Native]::SetForegroundWindow($w.MainWindowHandle); $ph.front = $sw.ElapsedMilliseconds
        $rootEl = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.MainWindowHandle)
        $null = $rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
        $edit = $null
        foreach ($cls in 'tiptap ProseMirror', 'tiptap ProseMirror ProseMirror-focused') { if (-not $edit) { $edit = $rootEl.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, $cls))) } }
        if (-not $edit) { Restore-Focus $ctx; throw 'composer not found in the app (nothing pasted)' }
        $edit.SetFocus(); Start-Sleep -Milliseconds 120; $ph.composer = $sw.ElapsedMilliseconds
        $fe = $null; try { $fe = [System.Windows.Automation.AutomationElement]::FocusedElement.Current.ClassName } catch { }
        if ($fe -notlike 'tiptap*') { Restore-Focus $ctx; throw "focus is on '$fe', not the composer (nothing pasted)" }
        # SAFETY: if the user has unsent text in the app's box, pasting would merge it into one message
        $draft = ''; $how = ''
        try { $tp = $edit.GetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern); $draft = $tp.DocumentRange.GetText(2000); $how = 'text' } catch { }
        if (-not $how) { try { $vp = $edit.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern); $draft = $vp.Current.Value; $how = 'value' } catch { } }
        if (-not $how) { $kids = @($edit.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)))); $draft = ($kids | ForEach-Object { $_.Current.Name }) -join ' '; $how = "children($($kids.Count))" }
        $draft = ([string]$draft).Trim([char]0x200B, ' ', "`r", "`n", "`t")
        $ph.box = $sw.ElapsedMilliseconds
        Log ("send[{0}] app box read via {1}: {2} chars" -f $q.id, $how, $draft.Length) 'DEBUG'
        if ($draft.Length -gt 0) {
            Restore-Focus $ctx
            Log ("send[{0}] ABORTED: the app's message box already has text ({1} chars) - not merging" -f $q.id, $draft.Length) 'WARN'
            try { $tray.ShowBalloonTip(5000, 'Not sent', "The Claude app's message box has unsent text. Send or clear it there first - your tray text is kept.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
            return $false
        }
        # baseline for verification: how many messages already contain this text (e.g. earlier 'check's)
        $snip = (($text -replace '\s+', ' ').Trim()); if ($snip.Length -gt 24) { $snip = $snip.Substring(0, 24) }
        $base = 0; try { foreach ($bb in @($rootEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))))) { if (([string]$bb.Current.Name -replace '\s+', ' ').Contains($snip)) { $base++ } } } catch { }
        $old = $null; try { $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }
        Set-Clipboard -Value $text
        [System.Windows.Forms.SendKeys]::SendWait('^v'); Start-Sleep -Milliseconds 250
        [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Milliseconds 150; $ph.paste = $sw.ElapsedMilliseconds
        if ($null -ne $old) { try { Set-Clipboard -Value $old } catch { Log 'send: clipboard restore failed' 'WARN' } }
        Restore-Focus $ctx; $ph.restore = $sw.ElapsedMilliseconds
        $r = Get-Results $q; $r.sent = @(@(@($r.sent) + [pscustomobject]@{ at = (Get-Iso (Get-Date)); text = (Get-SentText $text) }) | Select-Object -Last 2); Save-Results $q $r
        # verification runs in the watcher thread: it looks for our text in the chat
        $Probe.ExpectPage = $Probe.Page; $Probe.SawStop = $false; $Probe.ExpectAt = Get-Date      # 'working' from the moment of the paste
        $UI.VerifySnip = $snip; $Probe.VerifyHadQueue = [bool]$Probe.AppQueued; $Probe.VerifyPrev = [string]$Probe.LastUser; $Probe.VerifyBase = $base; $Probe.VerifySnip = $snip; $Probe.VerifyUntil = (Get-Date).AddSeconds(6); $Probe.VerifyResult = ''; $UI.VerifyQ = $q; $UI.VerifyText = $text
        Log ("send[{0}] pasted in {1} ms | phases {2} | onIt={3} wasMin={4} wasFront={5} fg={6}" -f $q.id, $sw.ElapsedMilliseconds, (($ph.Keys | ForEach-Object { "$_=$($ph[$_])" }) -join ' '), $onIt, $ctx.WasMin, $ctx.WasFront, $fgOk)
        return $true
    } catch {
        Log ("send[{0}] FAILED after {1} ms: {2} | phases {3}" -f $q.id, $sw.ElapsedMilliseconds, $_.Exception.Message, (($ph.Keys | ForEach-Object { "$_=$($ph[$_])" }) -join ' ')) 'ERR'
        $nsMsg = $_.Exception.Message; if (([string]$q.id).StartsWith('local/')) { try { [System.Windows.Forms.Clipboard]::SetText($text); $nsMsg += ' - text copied, paste it in Claude Desktop' } catch { } }
        try { $tray.ShowBalloonTip(4000, 'Not sent', $nsMsg, [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
        return $false
    }
}
function Send-LocalNoFocus($q, [string]$text) {      # set the composer's value + invoke ITS send button by UI Automation, no window focus. $false = nothing typed, use the paste path. Never falls back once Send was pressed (no double send).
    $w = $null; $wasMin = $false
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $AE = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
        $w = Get-ClaudeWindow; if (-not $w) { return 'fail' }
        $wasMin = [ClaudeTray.Native]::IsIconic($w.MainWindowHandle)
        if ($wasMin) { Set-DesktopGhost $w.MainWindowHandle $true; [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 4); [void][ClaudeTray.Native]::SetWindowPos($w.MainWindowHandle, [IntPtr]1, 0, 0, 0, 0, 0x0013); Start-Sleep -Milliseconds 350 }     # a minimized Desktop doesn't update its UI tree: restore it BEHIND your windows (no focus), minimized again below
        $uiRoot = $AE::FromHandle([IntPtr]$w.MainWindowHandle)
        $edx = $uiRoot.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'tiptap ProseMirror')))
        if (-not $edx) { Log "send[$($q.id)] nofocus: composer not found" 'INFO'; return 'fail' }
        $tw = [System.Windows.Automation.TreeWalker]::ControlViewWalker; $box = $tw.GetParent($edx)     # the composer container: its own send button only
        for ($kx = 0; $kx -lt 8 -and $box -and -not ([string]$box.Current.ClassName -match 'rounded-composer'); $kx++) { $box = $tw.GetParent($box) }
        if (-not $box) { Log "send[$($q.id)] nofocus: composer container not found" 'INFO'; return 'fail' }
        $vp = $edx.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern)
        if (([string]$vp.Current.Value).Trim([char]0x200B, ' ', "`r", "`n", "`t").Length) { Log "send[$($q.id)] nofocus: the app's box has unsent text - not merging" 'WARN'; return 'busy' }
        $vp.SetValue($text); Start-Sleep -Milliseconds 250
        $k0 = (($text -replace '\s+', ' ').Trim()); if ($k0.Length -gt 20) { $k0 = $k0.Substring(0, 20) }
        if (-not ((([string]$vp.Current.Value) -replace '\s+', ' ').Contains($k0))) { try { $vp.SetValue('') } catch { }; Log "send[$($q.id)] nofocus: value not taken by the composer" 'INFO'; return 'fail' }
        $send = $null; foreach ($bt in @($box.FindAll($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button))))) { $bn = [string]$bt.Current.Name; if ($bn -match '(?i)^(envoyer|send|enviar|senden|invia|verzenden|wy.lij)' -and $bn -notmatch '(?i)maintenant|now|ahora|jetzt|ora' -and $bt.Current.IsEnabled) { $send = $bt } }
        if (-not $send) { try { $vp.SetValue('') } catch { }; Log "send[$($q.id)] nofocus: no enabled send button in the composer" 'INFO'; return 'fail' }
        $ls0 = Get-LocalState $q; $len0 = $(if ($ls0) { [long]$ls0.Len } else { -1 })
        $send.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        $got = $false; $left = ''     # taken = the transcript grew; still in the box after 3 s = refused (box cleared, nothing resent)
        for ($vi = 0; $vi -lt 12 -and -not $got; $vi++) { Start-Sleep -Milliseconds 250; if ($script:LocalSt -and $script:LocalSt[[string]$q.id]) { $script:LocalSt[[string]$q.id].At = [datetime]::MinValue }; $lsv = Get-LocalState $q; if ($lsv -and $len0 -ge 0 -and [long]$lsv.Len -gt $len0) { $got = $true } }
        try { $left = ([string]$vp.Current.Value).Trim([char]0x200B, ' ', "`r", "`n", "`t") } catch { }
        if (-not $got -and $left.Length) { try { $vp.SetValue('') } catch { }; Log "send[$($q.id)] nofocus: Claude Desktop kept the text in the box (refused) - cleared, not resent" 'WARN'; return 'refused' }
        Log "send[$($q.id)] nofocus: sent (no focus change$(if ($wasMin) { ', Desktop kept minimized' }))$(if (-not $got) { ', not yet in the transcript' })"
        return 'sent'
    } catch { Log "send[$($q.id)] nofocus: $($_.Exception.Message)" 'INFO'; return 'fail' }
    finally { if ($wasMin -and $w) { [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 7); Start-Sleep -Milliseconds 150; Set-DesktopGhost $w.MainWindowHandle $false } }     # SW_SHOWMINNOACTIVE: back to minimized, focus untouched
}
function Set-AskResult($q, [string]$label, [bool]$ok, [string]$pid0) {     # what the tray did with your answer, shown in the card; hides the (stale) watcher card for 15 s when taken
    if ($null -eq $script:AskRes) { $script:AskRes = @{}; $script:AskMute = @{} }
    $script:AskRes[[string]$q.id] = @{ l = $label; ok = $ok; k = [guid]::NewGuid().ToString('N'); At = (Get-Date) }
    if ($ok) { $script:AskMute[[string]$q.id] = @{ Pid = $pid0; Until = (Get-Date).AddSeconds(15) } }
    try { Push-WebState } catch { }
}
function Wait-LocalTaken($q, [string]$pid0) {     # the waiting tool call got its result in the transcript (4 s max; re-parses only when the file changed)
    for ($vi = 0; $vi -lt 16; $vi++) { Start-Sleep -Milliseconds 250; if ($script:LocalSt -and $script:LocalSt[[string]$q.id]) { $script:LocalSt[[string]$q.id].At = [datetime]::MinValue }; $lsv = Get-LocalState $q; if ($lsv -and [string]$lsv.PendId -ne $pid0) { return $true } }
    return $false
}
function Invoke-LocalAsk($q, [string]$mt, $m) {      # answer a Desktop local chat's question card or request card by UI Automation (no focus, except Enter for a typed answer)
    $reMin = [IntPtr]::Zero; $keepFront = $false; $nav = $null
    $nope = { param($why) Log "ask[$($q.id)]: $why - nothing done" 'WARN'; Set-AskResult $q ([string]$(if ($m.label) { $m.label } elseif ($mt -eq 'qskip') { 'Skip' } else { 'Answer' })) $false ''; try { $tray.ShowBalloonTip(4000, 'Not answered', "$why. Answer it in Claude Desktop.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } }
    try {
        $la0 = Get-LocalAsk $q
        if (-not $la0) { & $nope 'no question or request for this chat now'; return }
        if (-not (Test-LocalSafe $q)) { return }
        $ls0 = Get-LocalState $q; $pid0 = $(if ($ls0) { [string]$ls0.PendId } else { '' })
        if ($ls0 -and $ls0.St -eq 'ask' -and $ls0.Ask -and ($ls0.Ask.Multi -or [int]$ls0.Ask.N -gt 1)) { & $nope 'multi-choice / several questions'; return }
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $AE = [System.Windows.Automation.AutomationElement]; $TS = [System.Windows.Automation.TreeScope]
        $btnC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        $w = Get-ClaudeWindow; if (-not $w) { & $nope 'Claude Desktop is not running'; return }
        if ([ClaudeTray.Native]::IsIconic($w.MainWindowHandle)) {     # a minimized Desktop doesn't draw the card: restore it behind your windows, without focus (minimized again at the end)
            Set-DesktopGhost $w.MainWindowHandle $true; [void][ClaudeTray.Native]::ShowWindow($w.MainWindowHandle, 4); [void][ClaudeTray.Native]::SetWindowPos($w.MainWindowHandle, [IntPtr]1, 0, 0, 0, 0, 0x0013); $reMin = $w.MainWindowHandle
            Log "ask[$($q.id)]: Claude Desktop was minimized - restored behind, no focus"
        }
        $uiRoot = $AE::FromHandle([IntPtr]$w.MainWindowHandle)
        $nav = Enter-LocalChat $q; $front = [bool]$nav.Ok     # switch Desktop to this chat if another one is open
        if (-not $front) { & $nope 'Claude Desktop shows another chat'; return }
        $lbl = ([string]$m.label).Trim()
        if ($la0.Inline) {      # inline request card: its buttons are direct children of the conversation scroller (or of a 'contents' wrapper); the LAST match is the live card
            if ($mt -ne 'qpick') { & $nope 'this request only has buttons'; return }
            $tw3 = [System.Windows.Automation.TreeWalker]::ControlViewWalker; $hit = $null
            foreach ($bx in @($uiRoot.FindAll($TS::Descendants, $btnC))) {
                if (([string]$bx.Current.Name).Trim() -cne $lbl -or -not $bx.Current.IsEnabled) { continue }
                $pa = $tw3.GetParent($bx); if ($pa -and [string]$pa.Current.ClassName -eq 'contents') { $pa = $tw3.GetParent($pa) }
                if ($pa -and ([string]$pa.Current.ClassName).StartsWith('overflow-y-auto')) { $hit = $bx }
            }
            if (-not $hit) { & $nope "button '$lbl' not found"; return }
            if ($QS.DeskOnly.ContainsKey($lbl)) {     # Desktop ignores this button when pressed from outside (approvals): open Desktop on the chat right away
                $keepFront = $true; Set-DesktopGhost $w.MainWindowHandle $false; try { $w2 = Get-ClaudeWindow; if ([ClaudeTray.Native]::IsIconic($w2.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w2.MainWindowHandle, 9) }; [void][ClaudeTray.Native]::SetForegroundWindow($w2.MainWindowHandle) } catch { }
                Set-AskResult $q $lbl $false $pid0; Log "ask[$($q.id)]: '$lbl' must be pressed in Claude Desktop - brought it to the front"; return
            }
            $hit.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $Probe.FastUntil = (Get-Date).AddSeconds(20)
            $ok = $false     # taken = the transcript moved on OR the button is gone from a fresh scan of the scroller (some requests write their result late)
            for ($vi = 0; $vi -lt 20 -and -not $ok; $vi++) {
                Start-Sleep -Milliseconds 250
                if ($script:LocalSt -and $script:LocalSt[[string]$q.id]) { $script:LocalSt[[string]$q.id].At = [datetime]::MinValue }; $lsv = Get-LocalState $q; if ($lsv -and [string]$lsv.PendId -ne $pid0) { $ok = $true; break }
                $still = $false
                foreach ($bx in @($uiRoot.FindAll($TS::Descendants, $btnC))) { if (([string]$bx.Current.Name).Trim() -cne $lbl) { continue }; $pa = $tw3.GetParent($bx); if ($pa -and [string]$pa.Current.ClassName -eq 'contents') { $pa = $tw3.GetParent($pa) }; if ($pa -and ([string]$pa.Current.ClassName).StartsWith('overflow-y-auto')) { $still = $true; break } }
                if (-not $still) { $ok = $true }
            }
            Set-AskResult $q $lbl $ok $pid0
            Log ("ask[{0}]: pressed '{1}' (inline card) - {2}" -f $q.id, $lbl, $(if ($ok) { 'taken by Desktop' } else { 'NOT CONFIRMED after 5 s (card still there, transcript unchanged)' })) $(if ($ok) { 'INFO' } else { 'WARN' })
            if (-not $ok) { $QS.DeskOnly[$lbl] = $true; Save-State; $keepFront = $true; Set-DesktopGhost $w.MainWindowHandle $false; try { $w2 = Get-ClaudeWindow; if ([ClaudeTray.Native]::IsIconic($w2.MainWindowHandle)) { [void][ClaudeTray.Native]::ShowWindow($w2.MainWindowHandle, 9) }; [void][ClaudeTray.Native]::SetForegroundWindow($w2.MainWindowHandle) } catch { }; try { $tray.ShowBalloonTip(6000, 'Approve it in Claude Desktop', 'Claude Desktop did not take this answer from the tray (some approvals must be given in Desktop itself). It is open on this chat now.', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } }     # no workaround - bring Desktop forward on this chat
            return
        }
        $grpC = New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Group); $card = $null
        for ($tr = 0; $tr -lt 12 -and -not $card; $tr++) {
            $gs = @($uiRoot.FindAll($TS::Descendants, $grpC))
            foreach ($e in $gs) { if ([string]$e.Current.ClassName -match 'rounded-composer.*cds-question') { $card = $e; break } }
            if (-not $card -and $la0.Gen) { foreach ($e in $gs) { if ([string]$e.Current.ClassName -match 'rounded-composer' -and -not $e.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ClassNameProperty, 'tiptap ProseMirror')))) { $card = $e; break } } }
            if (-not $card) { Start-Sleep -Milliseconds 250 }
        }
        if (-not $card) { & $nope 'the card is not shown in Claude Desktop'; return }
        $btns = @($card.FindAll($TS::Descendants, $btnC))
        $rows = @($btns | Where-Object { [string]$_.Current.ClassName -like 'group/row *' }); $other = @($btns | Where-Object { -not ([string]$_.Current.ClassName -like 'group/row *') })
        switch ($mt) {
            'qpick' {
                if (-not $rows.Count) {      # request card above the composer: the button with exactly that name
                    $gbt = @($btns | Where-Object { ([string]$_.Current.Name).Trim() -ceq $lbl -and $_.Current.IsEnabled })
                    if ($gbt.Count -ne 1) { & $nope "button '$lbl' not found once on the card"; return }
                    $gbt[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $Probe.FastUntil = (Get-Date).AddSeconds(20)
                    $ok = Wait-LocalTaken $q $pid0; Set-AskResult $q $lbl $ok $pid0; Log ("ask[{0}]: pressed '{1}' (card) - {2}" -f $q.id, $lbl, $(if ($ok) { 'taken' } else { 'NOT TAKEN' })); return
                }
                $match = @($rows | Where-Object { $nm = ([string]$_.Current.Name).Trim(); $nm -ceq $lbl -or $nm.StartsWith($lbl + ' ') })     # transcript labels vs UIA 'label description'
                if ($match.Count -ne 1) { & $nope "choice '$lbl' not found once on the card"; return }     # SAFETY: never click another choice
                $tp = $null; try { $tp = $match[0].GetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern) } catch { }
                if ($tp) { $tp.Toggle() } else { $match[0].GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke() }
                $ok = Wait-LocalTaken $q $pid0; Set-AskResult $q $lbl $ok $pid0; Log ("ask[{0}]: picked a choice - {1}" -f $q.id, $(if ($ok) { 'taken' } else { 'NOT TAKEN' }))
            }
            'qskip' {
                $sk = $(if ($other.Count -ge 2) { $other[-1] } else { $null }); $skn = $(if ($sk) { ([string]$sk.Current.Name).Trim() } else { '' })
                $want = $(if ($Probe.Ask -and -not $Probe.Ask.Gen) { ([string]$Probe.Ask.Skip).Trim() } else { '' })
                if (-not $sk -or -not (($want -and $skn -ceq $want) -or (-not $want -and $skn -match '(?i)^(skip|passer|ignorer|omitir|saltar|.berspringen|salta)$'))) { & $nope 'skip button not identified'; return }
                $sk.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                $ok = Wait-LocalTaken $q $pid0; Set-AskResult $q 'Skip' $ok $pid0; Log ("ask[{0}]: skipped - {1}" -f $q.id, $(if ($ok) { 'taken' } else { 'NOT TAKEN' }))
            }
            'qother' {
                $edx = $card.FindFirst($TS::Descendants, (New-Object System.Windows.Automation.PropertyCondition($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)))
                if (-not $edx) { & $nope "no 'other' field"; return }
                $edx.GetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern).SetValue([string]$m.text)
                if ($m.enter) {           # submitting a typed answer needs Enter in that field: brief focus on Claude Desktop, checked, then back
                    $script:ParkHold = (Get-Date).AddSeconds(4); $ctx = @{ PrevFg = [ClaudeTray.Native]::GetForegroundWindow(); WasMin = $false; WasFront = $false; Hwnd = $w.MainWindowHandle }
                    [void][ClaudeTray.Native]::SetForegroundWindow($w.MainWindowHandle); $edx.SetFocus(); Start-Sleep -Milliseconds 150
                    $focusOk = $false; try { $focusOk = ([ClaudeTray.Native]::GetForegroundWindow() -eq $w.MainWindowHandle) -and [System.Windows.Automation.Automation]::Compare([System.Windows.Automation.AutomationElement]::FocusedElement, $edx) } catch { }
                    if (-not $focusOk) { Restore-Focus $ctx; & $nope 'could not focus the answer field (text is typed there)'; return }     # SAFETY: never press Enter in another app
                    [System.Windows.Forms.SendKeys]::SendWait('{ENTER}'); Start-Sleep -Milliseconds 150; Restore-Focus $ctx
                    $ok = Wait-LocalTaken $q $pid0; Set-AskResult $q 'Other' $ok $pid0
                }
                Log ("ask[{0}]: other answer set ({1} chars), enter={2}" -f $q.id, ([string]$m.text).Length, [bool]$m.enter)
            }
        }
        $Probe.FastUntil = (Get-Date).AddSeconds(20)
    } catch { Log "ask[$($q.id)]: $($_.Exception.Message)" 'WARN' }
    finally { if ($nav) { Exit-LocalChat $nav (-not $keepFront) }; if ($reMin -ne [IntPtr]::Zero -and -not $keepFront) { Start-Sleep -Milliseconds 300; if ([ClaudeTray.Native]::GetForegroundWindow() -ne $reMin) { [void][ClaudeTray.Native]::ShowWindow($reMin, 7) } }; if ($reMin -ne [IntPtr]::Zero) { Start-Sleep -Milliseconds 150; Set-DesktopGhost $reMin $false } }     # minimized again, focus untouched; visible again
}
function Stop-Chat($q) {                           # press the stop button for this chat: browser tab first, else the app's (no focus change needed)
    $wc = Get-WebChat $q
    if ($wc) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'stop'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log "stop[$($q.id)]: queued to the browser tab"; return }
    try {
        if (([string]$q.id).StartsWith('local/')) {     # switch Desktop to this chat (background), press its stop button, back
            $nav = Enter-LocalChat $q; if (-not $nav.Ok) { Exit-LocalChat $nav $false; Log "stop[$($q.id)]: could not switch Claude Desktop to it" 'WARN'; return }
            try { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes; $rt = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$nav.Hwnd); Start-Sleep -Milliseconds 300
                $sbx = @(@($rt.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)))) | Where-Object { $nm = [string]$_.Current.Name; ($Probe.StopName -and $nm -ceq [string]$Probe.StopName) -or $nm -match '(?i)^(stop|arr.t|interromp|annuler la r)|stop (response|generating)' })[0]
                if ($sbx -and (Invoke-UiaAny $sbx)) { Log "stop[$($q.id)]: pressed its stop button" } else { Log "stop[$($q.id)]: no stop button on that chat - marked idle" 'WARN'; $lsx0 = Get-LocalState $q; if ($lsx0) { if ($null -eq $script:LocalIdle) { $script:LocalIdle = @{} }; $script:LocalIdle[[string]$q.id] = [long]$lsx0.Len; Push-WebState $true } } } catch { Log "stop[$($q.id)]: $($_.Exception.Message)" 'WARN' }
            Exit-LocalChat $nav; return
        }\r
        if (-not (Test-ChatWorking $q)) { Log "stop[$($q.id)]: not working (page '$(Get-PageLabel $Probe.Page)')" 'DEBUG'; return }
        $name = [string]$Probe.StopName; if (-not $name) { Log "stop[$($q.id)]: watcher has no stop-button name" 'WARN'; return }
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $w = Get-ClaudeWindow; $appRoot = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.MainWindowHandle)
        $btn = $appRoot.FindFirst([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.AndCondition((New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)), (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $name)))))
        if (-not $btn) { Log "stop[$($q.id)]: button '$name' not found" 'WARN'; return }
        $btn.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
        Log "stop[$($q.id)]: invoked '$name'"
    } catch { Log "stop[$($q.id)]: $($_.Exception.Message) (button probably already gone)" 'DEBUG' }
}
$OemEnc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
function Write-CmdFile([string]$path, [string]$text) {   # cmd.exe reads batch files in the OEM code page (accents in paths: Vidéos)
    $back = $OemEnc.GetString($OemEnc.GetBytes($text))
    if ($back -eq $text) { [IO.File]::WriteAllText($path, $text, $OemEnc) }
    else { [IO.File]::WriteAllText($path, "@chcp 65001>nul`r`n" + $text, (New-Object Text.UTF8Encoding $false)) }
}
function Read-OutText([string]$path) {           # step output: BOM if any (PowerShell *> = UTF-16), else UTF-8 if valid, else OEM (cmd / console tools)
    $b = [IO.File]::ReadAllBytes($path);
    if ($b.Length -ge 2 -and (($b[0] -eq 0xFF -and $b[1] -eq 0xFE) -or ($b[0] -eq 0xFE -and $b[1] -eq 0xFF) -or ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))) {
        $sr = New-Object IO.StreamReader((New-Object IO.MemoryStream (, $b)), $true); try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    try { return (New-Object Text.UTF8Encoding $false, $true).GetString($b) } catch { return $OemEnc.GetString($b) }
}
function Start-Step($q, $st) {
    $key = "$($q.id)#$($st.n)"
    if ($QS.Running.ContainsKey($key)) { return }
    $kind = [string]$st.kind
    try {
        switch ($kind) {
            { $_ -in 'dir', 'file', 'url' } {
                $target = if ($kind -eq 'url') { [string]$st.url } else { [string]$st.path }
                # 'open' steps only open: web links for url, folders for dir, documents for file - never a program or another protocol
                $why = $null
                if ($kind -eq 'url' -and $target -notmatch '^https?://[^\s"<>]+$') { $why = 'only http(s) links open' }
                elseif ($kind -eq 'dir' -and -not (Test-Path -LiteralPath $target -PathType Container)) { $why = 'folder not found' }
                elseif ($kind -eq 'file' -and [IO.Path]::GetExtension($target) -match '^\.(exe|com|bat|cmd|ps1|psm1|vbs|vbe|js|jse|wsf|wsh|msi|msp|scr|pif|lnk|hta|cpl|reg|jar|appref-ms|url|scf)$') { $why = 'programs and scripts run as ps/cmd/exe steps, not file steps' }
                if ($why) { Set-StepResult $q ([int]$st.n) @{ status = 'failed'; ended = (Get-Iso (Get-Date)); out = "not opened: $why" }; Log "step $key refused: $why" 'WARN'; return }
                Start-Process $target; Set-StepResult $q ([int]$st.n) @{ status = 'done'; ended = (Get-Iso (Get-Date)) }; Log "step $key opened ($kind)"; return
            }
            'manual' { Set-StepResult $q ([int]$st.n) @{ status = 'done'; ended = (Get-Iso (Get-Date)) }; return }
            'observe' { return }
            default {
                $tmp = Join-Path $env:TEMP ('claudetray_' + [guid]::NewGuid().ToString('N'))
                $outF = "$tmp.out.txt"
                if ($kind -eq 'exe') {
                    $target = [string]$st.path
                    $proc = Start-Process -FilePath $target -WorkingDirectory (Split-Path $target -Parent) -PassThru
                    $outF = $null
                } elseif ([bool]$st.interactive) {
                    if ($kind -eq 'cmd') { Write-CmdFile "$tmp.cmd" ([string]$st.cmd); $proc = Start-Process cmd.exe -ArgumentList "/c `"$tmp.cmd`" & pause" -PassThru }
                    else { Set-Content "$tmp.ps1" ([string]$st.cmd) -Encoding UTF8; $proc = Start-Process $PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"& '$tmp.ps1'; Read-Host 'Done - press Enter to close'`"" -PassThru }
                    $outF = $null
                } elseif ([bool]$st.admin) {
                    if ($kind -eq 'cmd') { Write-CmdFile "$tmp.cmd" ([string]$st.cmd); $inner = "cmd /c `"$tmp.cmd`" *> '$outF'; exit `$LASTEXITCODE" }
                    else { Set-Content "$tmp.ps1" ([string]$st.cmd) -Encoding UTF8; $inner = "& '$tmp.ps1' *> '$outF'; exit `$LASTEXITCODE" }
                    $proc = Start-Process $PsExe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$inner`"" -PassThru
                } else {
                    if ($kind -eq 'cmd') { Write-CmdFile "$tmp.cmd" ([string]$st.cmd); $proc = Start-Process cmd.exe -ArgumentList "/c `"$tmp.cmd`"" -WindowStyle Hidden -RedirectStandardOutput $outF -RedirectStandardError "$tmp.err.txt" -PassThru }
                    else { Set-Content "$tmp.ps1" ([string]$st.cmd + "`r`nif (`$LASTEXITCODE) { exit `$LASTEXITCODE }") -Encoding UTF8; $proc = Start-Process $PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tmp.ps1`"" -WindowStyle Hidden -RedirectStandardOutput $outF -RedirectStandardError "$tmp.err.txt" -PassThru }
                }
                try { $null = $proc.Handle } catch { }           # PS 5.1: without this ExitCode comes back null
                $QS.Running[$key] = @{ Proc = $proc; Out = $outF; Err = "$tmp.err.txt"; Tmp = $tmp; Q = $q; N = [int]$st.n; Started = (Get-Date) }
                Set-StepResult $q ([int]$st.n) @{ status = 'running'; started = (Get-Iso (Get-Date)) }
                Log "step $key started pid=$($proc.Id) kind=$kind admin=$([bool]$st.admin) interactive=$([bool]$st.interactive)"
            }
        }
    } catch { Log "step $key : $($_.Exception.Message)" 'ERR'; Set-StepResult $q ([int]$st.n) @{ status = 'failed'; out = $_.Exception.Message } }
}
function Poll-Running {
    $done = @()
    foreach ($key in @($QS.Running.Keys)) {
        $rn = $QS.Running[$key]
        if (-not $rn.Proc.HasExited) { continue }
        $tail = ''
        foreach ($f in @($rn.Out, $rn.Err)) { if ($f -and (Test-Path $f)) { try { $tail += ((@((Read-OutText $f) -split "`r?`n") | Select-Object -Last 40) -join "`n") } catch { } } }
        $tail = $tail -replace '\x1b\[[0-9;]*[A-Za-z]', ''
        if ($tail.Length -gt [int]$Cfg.resultChars) { $tail = '...' + $tail.Substring($tail.Length - [int]$Cfg.resultChars) }   # Claude reads this file: keep it small
        $code = $rn.Proc.ExitCode
        # exit 0 but a command in it failed (only the last one sets the exit code): an error line in the output fails the step
        if (($code -eq 0 -or $null -eq $code) -and $tail -match '(?im)^\s*(fatal|error)\b[^\r\n]{0,200}|could not resolve host|is not recognized as (the name of )?a cmdlet|cannot find path') { $code = 1; $tail = "$tail`n[tray] marked failed: an error line in the output (exit was 0)" }
        Set-StepResult $rn.Q ([int]$rn.N) @{ status = $(if ($code -eq 0 -or $null -eq $code) { 'done' } else { 'failed' }); exit = $code; ended = (Get-Iso (Get-Date)); out = $tail.Trim() }
        Log "step $key exit=$code out=$($tail.Length)ch"
        foreach ($f in @($rn.Out, $rn.Err, "$($rn.Tmp).ps1", "$($rn.Tmp).cmd")) { if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue } }
        $done += $key
    }
    foreach ($dk in $done) { $QS.Running.Remove($dk) }
    return ($done.Count -gt 0)
}

# ---------------------------------------------------------------- flyout window
$pop = New-Object System.Windows.Forms.Form
$pop.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$pop.ShowInTaskbar = $false
$pop.MaximizeBox = $false; $pop.MinimizeBox = $false     # the top band is a native drag region: a double-click must not maximize the panel
$pop.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$pop.BackColor = $T.Bg; $pop.ForeColor = $T.Tx; $pop.Font = $FUi
$pop.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None     # sizes are already in px (DPI-scaled by px); font-autoscale would grow the form again
$pop.Width = px 340; $pop.Height = px 200
$pop.Padding = New-Object System.Windows.Forms.Padding 1, 0, 1, 1     # no top border strip, so the page's top resize zone starts at the window's real top edge
$null = $pop.Handle
$hPop = $pop.Handle
[void][ClaudeTray.Native]::SetWindowLong($hPop, -20, ([ClaudeTray.Native]::GetWindowLong($hPop, -20) -bor 0x08000088))   # NOACTIVATE | TOOLWINDOW | TOPMOST
try { $corner = 2; [void][ClaudeTray.Native]::DwmSetWindowAttribute($hPop, 33, [ref]$corner, 4) } catch { }
$pop.add_Paint({ param($sender, $e) $pen = New-Object System.Drawing.Pen $T.Ln; $e.Graphics.DrawRectangle($pen, 0, 0, $pop.Width - 1, $pop.Height - 1); $pen.Dispose() })
$pop.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($pop, $true, $null)

$content = New-Object System.Windows.Forms.FlowLayoutPanel
$content.FlowDirection = 'TopDown'; $content.WrapContents = $false; $content.AutoScroll = $true
$content.Dock = 'Fill'; $content.BackColor = $T.Bg; $content.Padding = New-Object System.Windows.Forms.Padding (px 6), (px 8), (px 6), (px 6)
$pop.Controls.Add($content)
$UI.PopReady = $true
[System.Windows.Forms.Application]::AddMessageFilter((New-Object ClaudeTray.WheelToHover))
$content.add_Layout({ try { [void][ClaudeTray.Scroll]::ShowScrollBar($content.Handle, 1, $false) } catch { } })

# drag to park: the top band of the panel (header row + edge padding) moves it; a moved panel is docked (always on top, remembered)
$dragH = @{
    MouseDown = { param($sender, $e)
        if ($e.Button -ne 'Left') { return }
        $inForm = $pop.PointToClient([System.Windows.Forms.Cursor]::Position)
        if (($sender -eq $pop -or $sender -eq $content) -and $inForm.Y -gt (px 36)) { return }
        $UI.Drag = @{ Start = [System.Windows.Forms.Cursor]::Position; Origin = $pop.Location }; $UI.DragMoved = $false }
    MouseMove = { param($sender, $e) if ($UI.Drag -and [System.Windows.Forms.Control]::MouseButtons -eq 'Left') { $c = [System.Windows.Forms.Cursor]::Position; if ((Dist $c $UI.Drag.Start) -gt 3) { $UI.DragMoved = $true; $pop.Location = New-Object System.Drawing.Point ($UI.Drag.Origin.X + $c.X - $UI.Drag.Start.X), ($UI.Drag.Origin.Y + $c.Y - $UI.Drag.Start.Y) } } }
    MouseUp   = { param($sender, $e) if ($UI.Drag) { $UI.Drag = $null; if ($UI.DragMoved) { if (-not $UI.Docked) { $UI.Docked = $true; Pin-Pop; Request-Build }; Set-DockMemo; Save-State; Log ("panel dragged to {0},{1} (docked)" -f $pop.Left, $pop.Top) 'DEBUG' } } }
}
foreach ($hn in 'MouseDown', 'MouseMove', 'MouseUp') { $pop."add_$hn"($dragH[$hn]); $content."add_$hn"($dragH[$hn]) }
# side panel: full text of a box, shown next to the flyout while hovering it; pin keeps it
$side = New-Object System.Windows.Forms.Form
$side.FormBorderStyle = 'None'; $side.ShowInTaskbar = $false; $side.StartPosition = 'Manual'; $side.BackColor = $T.Card; $side.Width = px 300; $side.Height = px 120; $side.AutoScaleMode = 'None'
$null = $side.Handle; $hSide = $side.Handle
[void][ClaudeTray.Native]::SetWindowLong($hSide, -20, ([ClaudeTray.Native]::GetWindowLong($hSide, -20) -bor 0x08000088))
try { $corner = 2; [void][ClaudeTray.Native]::DwmSetWindowAttribute($hSide, 33, [ref]$corner, 4) } catch { }
$side.add_Paint({ param($sender, $e) $pen = New-Object System.Drawing.Pen $T.Ln; $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1); $pen.Dispose() })
# body: a read-only RichTextBox (bold names for the conversation), wheel-scrolled, thin indicator on the right
$sideBox = New-Object System.Windows.Forms.RichTextBox; $sideBox.ReadOnly = $true; $sideBox.BorderStyle = 'None'; $sideBox.Font = $FUi; $sideBox.BackColor = $T.Card; $sideBox.ForeColor = $T.Tx
$sideBox.ScrollBars = 'None'; $sideBox.DetectUrls = $false; $sideBox.TabStop = $false; $sideBox.Cursor = [System.Windows.Forms.Cursors]::Default
$sideBar = New-Object System.Windows.Forms.Panel; $sideBar.Width = [Math]::Max(2, (px 2)); $sideBar.BackColor = $T.Mu; $sideBar.Visible = $false
$sideTitle = New-Object System.Windows.Forms.Label; $sideTitle.AutoSize = $false; $sideTitle.Height = px 18; $sideTitle.Font = $FSmall; $sideTitle.ForeColor = $T.Mu; $sideTitle.TextAlign = 'MiddleLeft'; $sideTitle.AutoEllipsis = $true
$sideMore = New-Object System.Windows.Forms.Label; $sideMore.AutoSize = $true; $sideMore.Font = $FSmall; $sideMore.ForeColor = $T.Acc; $sideMore.Text = 'load earlier'; $sideMore.Cursor = [System.Windows.Forms.Cursors]::Hand; $sideMore.Visible = $false
$sideMore.add_Click({ if ($UI.ConvQ) { $Web.ConvN = [int]$Web.ConvN + 10; [void]$Web.Cmds.Add(@{ Id = [string]$UI.ConvQ.id; Kind = 'more'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); $UI.ConvKeepTop = $true; Log "conv: load earlier ($($Web.ConvN))" 'DEBUG' } })
$sidePin = New-Object System.Windows.Forms.Label; $sidePin.AutoSize = $false; $sidePin.Width = px 18; $sidePin.Height = px 18; $sidePin.ImageAlign = 'MiddleCenter'; $sidePin.Cursor = [System.Windows.Forms.Cursors]::Hand
$sidePin.add_Click({ $UI.SidePinned = -not $UI.SidePinned; $sidePin.Image = Get-IconBmp $(if ($UI.SidePinned) { 'unpin' } else { 'pin' }) $(if ($UI.SidePinned) { $T.Acc } else { $T.Mu }) (px 12) })
$sideX = New-Object System.Windows.Forms.Label; $sideX.AutoSize = $false; $sideX.Width = px 18; $sideX.Height = px 18; $sideX.ImageAlign = 'MiddleCenter'; $sideX.Cursor = [System.Windows.Forms.Cursors]::Hand
$sideX.add_Click({ $UI.SidePinned = $false; $UI.ConvQ = $null; $Web.ConvFor = ''; Hide-Side })
$side.Controls.AddRange([System.Windows.Forms.Control[]]@($sideBox, $sideBar, $sideTitle, $sideMore, $sidePin, $sideX)); $sideBar.BringToFront()
$UI.SidePinned = $false; $UI.SideFor = $null; $UI.SideHoverAt = $null; $UI.ConvQ = $null; $UI.ConvSig = ''
$Web.ConvFor = ''; $Web.ConvN = 16; $Web.MsgFor = @(); $Web.MsgN = [hashtable]::Synchronized(@{})
function Update-SideBar {
    try {
        $total = [int][ClaudeTray.Native]::SendMessage($sideBox.Handle, 0x00BA, [IntPtr]0, [IntPtr]0); $first = [int][ClaudeTray.Native]::SendMessage($sideBox.Handle, 0x00CE, [IntPtr]0, [IntPtr]0)
        $vis = [Math]::Max(1, [int][Math]::Floor($sideBox.Height / [Math]::Max(1, $FUi.Height)))
        if ($total -le $vis) { $sideBar.Visible = $false; return }
        $th = [Math]::Max((px 10), [int]($sideBox.Height * $vis / $total)); $sideBar.Height = $th
        $sideBar.Top = $sideBox.Top + [int](($sideBox.Height - $th) * $first / [Math]::Max(1, $total - $vis)); $sideBar.Left = $side.Width - (px 4); $sideBar.Visible = $true
    } catch { }
}
$sideBox.add_VScroll({ Update-SideBar }); $sideBox.add_MouseWheel({ Update-SideBar })
function Place-Side([int]$w, [int]$h, [string]$title, [bool]$conv) {
    $sideTitle.Text = $title; $sideMore.Visible = $conv
    $sideTitle.Location = New-Object System.Drawing.Point (px 10), (px 4); $sideTitle.Width = $w - (px 10) - (px 44) - $(if ($conv) { $sideMore.Width + (px 8) } else { 0 })
    $sideMore.Location = New-Object System.Drawing.Point ($w - (px 44) - $sideMore.Width - (px 4)), (px 6)
    $sidePin.Location = New-Object System.Drawing.Point ($w - (px 42)), (px 4); $sideX.Location = New-Object System.Drawing.Point ($w - (px 22)), (px 4)
    $sidePin.Image = Get-IconBmp $(if ($UI.SidePinned) { 'unpin' } else { 'pin' }) $(if ($UI.SidePinned) { $T.Acc } else { $T.Mu }) (px 12); $sideX.Image = Get-IconBmp 'x' $T.Mu (px 12)
    foreach ($c in @($side, $sideBox, $sideTitle, $sideMore, $sidePin, $sideX)) { $c.BackColor = $T.Card }; $sideBox.ForeColor = $T.Tx; $sideTitle.ForeColor = $T.Mu
    $sideBox.Location = New-Object System.Drawing.Point (px 10), (px 26); $sideBox.Width = $w - (px 20); $sideBox.Height = $h - (px 34)
    $scr = [System.Windows.Forms.Screen]::FromControl($pop).WorkingArea
    $x = $pop.Right + (px 6); if ($x + $w -gt $scr.Right) { $x = $pop.Left - $w - (px 6) }
    $y = [Math]::Min([Math]::Max($scr.Top, $pop.Bottom - $h), $scr.Bottom - $h)
    if (-not $side.Visible) { $side.Show() }
    [void][ClaudeTray.Native]::SetWindowPos($hSide, [IntPtr](-1), $x, $y, $w, $h, 0x0010 -bor 0x0040)
}
function Show-Side([string]$text, $owner, [string]$title = 'Full answer') {      # hover: full text next to the panel
    if (-not $text -or $UI.ConvQ) { return }
    $UI.SideFor = $owner
    $w = px 380; $tw = $w - (px 24)
    $h = [System.Windows.Forms.TextRenderer]::MeasureText($text, $FUi, (New-Object System.Drawing.Size $tw, 8000), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height + (px 44)
    $h = [Math]::Max((px 60), [Math]::Min($h, [Math]::Max((px 200), $pop.Height)))
    $sideBox.Text = ($text -replace "(?<!`r)`n", "`r`n"); $sideBox.SelectionStart = 0
    Place-Side $w $h $title $false; Update-SideBar
}
function Get-AnswerFull($q) {                       # Claude's whole latest reply when the browser has it, else the quest text
    $wc = Get-WebChat $q
    if ($wc -and $wc.Reply) { return [string]$wc.Reply }
    if ($q.answer) { return [string]$q.answer }; return [string]$q.summary
}
function Show-Conv($q) {                            # conversation of a chat (you + Claude), live, pinned until closed
    $UI.ConvQ = $q; $UI.SidePinned = $true; $Web.ConvFor = [string]$q.id; $UI.ConvSig = ''
    Log "conv: open for $($q.id)" 'DEBUG'
    Render-Conv
}
function Render-Conv {
    $q = $UI.ConvQ; if (-not $q) { return }
    $wc = Get-WebChat $q
    $msgs = if ($wc -and $wc.Msgs) { @($wc.Msgs) } else { @() }
    $sig = "{0}|{1}" -f $msgs.Count, $(if ($msgs.Count) { "$($msgs[-1].r)$(([string]$msgs[-1].t).Length)" } else { '' })
    if ($sig -eq $UI.ConvSig -and $side.Visible) { return }
    $UI.ConvSig = $sig
    $atBottom = $true
    try { $total = [int][ClaudeTray.Native]::SendMessage($sideBox.Handle, 0x00BA, [IntPtr]0, [IntPtr]0); $first = [int][ClaudeTray.Native]::SendMessage($sideBox.Handle, 0x00CE, [IntPtr]0, [IntPtr]0); $vis = [int][Math]::Floor($sideBox.Height / [Math]::Max(1, $FUi.Height)); $atBottom = ($first + $vis + 1 -ge $total) } catch { }
    $sideBox.SuspendLayout(); $sideBox.Clear()
    if (-not $msgs.Count) { $sideBox.SelectionColor = $T.Mu; $sideBox.AppendText($(if ($wc) { 'Loading the conversation...' } else { 'Conversation not available yet.' })) }
    foreach ($m in $msgs) {
        $you = ($m.r -eq 'u')
        $sideBox.SelectionFont = $FBold; $sideBox.SelectionColor = $(if ($you) { $T.Act } else { $T.Acc }); $sideBox.AppendText($(if ($you) { "You`n" } else { "Claude`n" }))
        $sideBox.SelectionFont = $FUi; $sideBox.SelectionColor = $(if ($you) { $T.Tx } else { $T.Tx }); $sideBox.AppendText(([string]$m.t).Trim() + "`n`n")
    }
    $sideBox.ResumeLayout()
    $w = px 400; $h = [Math]::Max((px 320), $pop.Height)
    Place-Side $w $h ("Conversation - {0}" -f $q.title) $true
    if ($UI.ConvKeepTop) { $UI.ConvKeepTop = $false; $sideBox.SelectionStart = 0; $sideBox.ScrollToCaret() }
    elseif ($atBottom) { $sideBox.SelectionStart = $sideBox.TextLength; $sideBox.ScrollToCaret() }
    Update-SideBar
}
function Hide-Side { if ($UI.SidePinned) { return }; if ($side.Visible) { $side.Hide() }; $UI.SideFor = $null; $UI.SideMsg = $null }
function Hook-Side($tb) {                                   # hover a box for 250 ms -> side panel with its full text
    $tb.add_MouseEnter({ param($sender, $e) $UI.SideHoverAt = Get-Date; $UI.SideWant = $sender })
    $tb.add_MouseLeave({ param($sender, $e) if ($UI.SideWant -eq $sender) { $UI.SideWant = $null } })
}
function Set-Activatable([bool]$on) {
    $ex = [ClaudeTray.Native]::GetWindowLong($hPop, -20)
    $ex = if ($on) { $ex -band (-bnot 0x08000000) } else { $ex -bor 0x08000000 }
    [void][ClaudeTray.Native]::SetWindowLong($hPop, -20, $ex)
}
function Set-DockMemo { $UI.DockPos = $pop.Location; $QS.Dock = @($pop.Left, $pop.Top); $QS.DockB = $pop.Bottom }   # remember the pinned spot (top-left for old state.json + its bottom edge = the anchor)
function Pin-Pop { if (-not $UI.Pinned) { $UI.Pinned = $true; Set-Activatable $true; try { $pop.Activate() } catch { } } }
function Hook-Click($ctl) {
    $ctl.add_MouseDown({ Pin-Pop })
    foreach ($c in $ctl.Controls) { Hook-Click $c }
}

function New-Glyph([string]$ch, [string]$tip, [System.Drawing.Color]$color, $tag, [scriptblock]$onClick, [bool]$small = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = ''; $l.Image = Get-IconBmp $ch $color (px $(if ($small) { 12 } else { 14 })); $l.ImageAlign = 'MiddleCenter'; $l.ForeColor = $color; $l.AutoSize = $false
    $l.Width = px 20; $l.Height = px 20; $l.TextAlign = 'MiddleCenter'; $l.Margin = New-Object System.Windows.Forms.Padding 0
    $l.Cursor = [System.Windows.Forms.Cursors]::Hand; $l.Tag = $tag
    if ($tip) { $TT.SetToolTip($l, $tip) }
    $l.AccessibleName = $(if ($tip) { $tip } else { $ch })
    if ($onClick) { $l.add_Click({ $tg = $this.Tag; $who = if ($tg -is [hashtable] -and $tg.q) { "$($tg.q.id)#$($tg.st.n)" } elseif ($tg -and $tg.id) { [string]$tg.id } else { [string]$tg }; Log ("click '{0}' {1}" -f $this.AccessibleName, $who) 'DEBUG' }); $l.add_Click($onClick) }
    $l.add_MouseEnter({ $this.BackColor = $T.Ln }); $l.add_MouseLeave({ $this.BackColor = [System.Drawing.Color]::Transparent })
    return $l
}
function New-Lbl([string]$text, $font, [System.Drawing.Color]$color, [int]$w) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Font = $font; $l.ForeColor = $color
    $l.AutoSize = $false; $l.Width = $w; $l.Height = px 20; $l.TextAlign = 'MiddleLeft'; $l.AutoEllipsis = $true; $l.Margin = New-Object System.Windows.Forms.Padding 0
    return $l
}
function Draw-Dots($g, [single]$cx, [single]$cy, [single]$size, [int]$phase, [System.Drawing.Color]$col) {   # 2x2 dots, one lit, going round TL > TR > BR > BL
    $r = [single]($size * 0.17); $o = [single]($size * 0.26)
    $pos = @(@(-1, -1), @(1, -1), @(1, 1), @(-1, 1)); $lit = $phase % 4
    for ($i = 0; $i -lt 4; $i++) {
        $a = if ($i -eq $lit) { 255 } elseif ($i -eq (($lit + 3) % 4)) { 140 } else { 70 }
        $b = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($a, $col.R, $col.G, $col.B))
        $g.FillEllipse($b, [single]($cx + $pos[$i][0] * $o - $r), [single]($cy + $pos[$i][1] * $o - $r), [single](2 * $r), [single](2 * $r)); $b.Dispose()
    }
}
function New-Marker([string]$st) {
    $m = New-Object System.Windows.Forms.Panel; $m.Width = px 20; $m.Height = px 22; $m.Margin = New-Object System.Windows.Forms.Padding 0; $m.Tag = $st
    $m.add_Paint({
        param($sender, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $d = [single](px 6.5); $ox = [single](($sender.Width - $d) / 2); $oy = [single](($sender.Height - $d) / 2)
        switch ($sender.Tag) {
            'act' { $b = New-Object System.Drawing.SolidBrush $T.Act; $g.FillEllipse($b, $ox, $oy, $d, $d); $b.Dispose() }
            'done' { $b = New-Object System.Drawing.SolidBrush $T.Pur; $g.FillEllipse($b, $ox, $oy, $d, $d); $b.Dispose() }
            default { Draw-Dots $g ([single]($sender.Width / 2)) ([single]($sender.Height / 2)) ([single](px 9)) ([int]$UI.Phase) $T.Acc }
        }
    })
    return $m
}
function New-Row([int]$h) { $r = New-Object System.Windows.Forms.FlowLayoutPanel; $r.FlowDirection = 'LeftToRight'; $r.WrapContents = $false; $r.AutoSize = $false; $r.Height = $h; $r.Margin = New-Object System.Windows.Forms.Padding 0; $r.Padding = New-Object System.Windows.Forms.Padding 0; return $r }

function Build-Rows {
    if ($UI.WebReady) { $UI.ViewSig = Get-ViewSig; $UI.Built = $true; Push-WebState; return }
    $swb = [Diagnostics.Stopwatch]::StartNew()
    # WM_SETREDRAW only while visible: WM_SETREDRAW(TRUE) on a hidden window makes it visible (blank grey panel - happened)
    $vis0 = $pop.Visible
    if ($vis0) { [void][ClaudeTray.Native]::SendMessage($hPop, 0x000B, [IntPtr]0, [IntPtr]0) }
    try { Build-RowsCore } catch { Log ("build: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR' }
    finally { if ($vis0) { [void][ClaudeTray.Native]::SendMessage($hPop, 0x000B, [IntPtr]1, [IntPtr]0); $pop.Refresh() } }
    if (-not $UI.Shown -and $pop.Visible) { Log 'build: flyout became visible while hidden - hiding it' 'WARN'; $pop.Hide() }
    Log ("build {0} ms [{9}]: {1} rows, {2}x{3}, quests={4} visible={5} expanded={6} pinned={7} docked={8}" -f $swb.ElapsedMilliseconds, $content.Controls.Count, $pop.Width, $pop.Height, @($QS.List).Count, @($QS.List | Where-Object { $_.Visible }).Count, (@($UI.Expanded.Keys | Where-Object { $UI.Expanded[$_] }).Count), $UI.Pinned, $UI.Docked, $UI.BuildPhases) 'DEBUG'
}
function New-Field([int]$w, [int]$h, $font, $tag) {           # rounded bordered box holding a multi-line TextBox (Enter = submit, Ctrl+Enter = newline, wheel scrolls)
    $pn = New-Object System.Windows.Forms.Panel; $pn.Width = $w; $pn.Height = $h; $pn.BackColor = $T.Card; $pn.Margin = New-Object System.Windows.Forms.Padding 0
    $pn.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($pn, $true, $null)
    $pn.add_Paint({ param($sender, $e)       # square panel in the card colour, rounded field drawn inside (no square corners poking out)
        $e.Graphics.SmoothingMode = 'AntiAlias'; $pth = New-RoundPath 0.5 0.5 ($sender.Width - 1) ($sender.Height - 1) (px 6)
        $fb2 = New-Object System.Drawing.SolidBrush $sender.Tag.Fill; $e.Graphics.FillPath($fb2, $pth); $fb2.Dispose()
        $pen = New-Object System.Drawing.Pen $(if ($sender.Tag.Box.Focused) { Blend $T.Ln $T.Mu 0.5 } else { $T.Ln }); $e.Graphics.DrawPath($pen, $pth); $pen.Dispose(); $pth.Dispose() })
    $tb = New-Object System.Windows.Forms.TextBox; $tb.Multiline = $true; $tb.BorderStyle = 'None'; $tb.Font = $font; $tb.BackColor = $T.Field; $tb.ForeColor = $T.Tx
    $tb.Location = New-Object System.Drawing.Point (px 8), (px 5); $tb.Width = $w - (px 16); $tb.Height = $h - (px 9); $tb.Tag = $tag; $tb.AcceptsReturn = $false
    $tb.add_KeyDown({ param($sender, $e)
        if ($e.Control -and $e.KeyCode -eq 'A') { $sender.SelectAll(); $e.SuppressKeyPress = $true }
        elseif ($e.Control -and $e.KeyCode -in 'Back', 'Delete' -and -not $sender.ReadOnly) {
            $e.SuppressKeyPress = $true
            if ($sender.SelectionLength -gt 0) { $sender.SelectedText = '' }
            else {
                $i0 = $sender.SelectionStart; $tx = $sender.Text
                if ($e.KeyCode -eq 'Back') { $m = [regex]::Match($tx.Substring(0, $i0), '(\w+|[^\w\s]+)?\s*$'); $n0 = $m.Length; if ($n0 -gt 0) { $sender.Text = $tx.Remove($i0 - $n0, $n0); $sender.SelectionStart = $i0 - $n0 } }
                else { $m = [regex]::Match($tx.Substring($i0), '^\s*(\w+|[^\w\s]+)?'); $n0 = $m.Length; if ($n0 -gt 0) { $sender.Text = $tx.Remove($i0, $n0); $sender.SelectionStart = $i0 } }
            }
        }
        elseif ($e.KeyCode -eq 'Escape') { $e.SuppressKeyPress = $true; if (-not $UI.Docked) { Hide-Pop 'esc' } } })
    $tb.add_GotFocus({ param($sender, $e) if (-not $UI.FocusByUser) { $sender.SelectionStart = $sender.Text.Length; $sender.SelectionLength = 0 } })
    $tb.add_MouseDown({ $UI.FocusByUser = $true }); $tb.add_MouseUp({ $UI.FocusByUser = $false })
    # thin scroll indicator on the right edge, follows the text
    $sb = New-Object System.Windows.Forms.Panel; $sb.Width = [Math]::Max(2, (px 2)); $sb.BackColor = $T.Mu; $sb.Visible = $false; $sb.Left = $w - (px 4); $sb.Top = px 3; $sb.Height = px 8
    $pn.Controls.Add($sb); $sb.BringToFront()
    $pn.Tag = @{ Bar = $sb; Box = $tb; Max = 1; Fill = $T.Field }
    $tb.add_GotFocus({ param($sender, $e) $sender.Parent.Invalidate() }); $tb.add_LostFocus({ param($sender, $e) $sender.Parent.Invalidate() })
    $pn.Controls.Add($tb)
    $UI.Fields += $pn
    return @{ Panel = $pn; Box = $tb }
}
function Update-FieldBar($pn) {              # EM_GETLINECOUNT / EM_GETFIRSTVISIBLELINE -> thumb size/position
    try {
        $d = $pn.Tag; $tb = $d.Box; if (-not $tb.IsHandleCreated) { return }
        $total = [int][ClaudeTray.Native]::SendMessage($tb.Handle, 0x00BA, [IntPtr]0, [IntPtr]0)
        $first = [int][ClaudeTray.Native]::SendMessage($tb.Handle, 0x00CE, [IntPtr]0, [IntPtr]0)
        $vis = [Math]::Max(1, [int][Math]::Floor($tb.Height / [Math]::Max(1, $tb.Font.Height)))
        if ($total -le $vis) { if ($d.Bar.Visible) { $d.Bar.Visible = $false }; return }
        $trackH = $pn.Height - (px 6)
        $th = [Math]::Max((px 8), [int]($trackH * $vis / $total)); $ty = (px 3) + [int](($trackH - $th) * $first / [Math]::Max(1, $total - $vis))
        $d.Bar.Height = $th; $d.Bar.Top = $ty; $d.Bar.Left = $pn.Width - (px 4); if (-not $d.Bar.Visible) { $d.Bar.Visible = $true }
    } catch { }
}
function Grow-Field($pn, [int]$maxLines) {    # field height follows its line count up to maxLines; then it scrolls (caret kept in view)
    $d = $pn.Tag; $tb = $d.Box
    $lines = [int][ClaudeTray.Native]::SendMessage($tb.Handle, 0x00BA, [IntPtr]0, [IntPtr]0)
    $h = (px 10) + [Math]::Min($maxLines, [Math]::Max(1, $lines)) * $tb.Font.Height
    if ($h -ne $pn.Height) {
        $dh = $h - $pn.Height
        $pn.Height = $h; $tb.Height = $h - (px 8)
        $row = $pn.Parent; if ($row) { $row.Height = $row.Height + $dh; foreach ($c in $row.Controls) { if ($c -ne $pn -and $c.Height -eq ($h - $dh) -and $c -is [System.Windows.Forms.Label] -and -not $c.Text) { $c.Height = $h } } }
        Fit-Pop
    }
    $tb.ScrollToCaret(); Update-FieldBar $pn
}
function Fit-Pop {                            # size the flyout to its content; the bottom edge stays fixed (attached or pinned), only the top moves
    $wa = [System.Windows.Forms.Screen]::FromControl($pop).WorkingArea
    $need = (px 14); foreach ($c in $content.Controls) { $need += $c.Height + $c.Margin.Vertical }
    $nh = [Math]::Min([Math]::Max((px 60), $need), [int]($wa.Height * 0.85))
    if ($nh -eq $pop.Height -and $pop.Bottom -le $wa.Bottom -and $pop.Top -ge $wa.Top) { return }
    if ($UI.Docked -and $null -eq $QS.DockB) { $QS.DockB = $pop.Bottom }                           # old state.json had no bottom
    $bot = if ($UI.Docked) { [int]$QS.DockB } else { $pop.Bottom }                                # pinned: the remembered bottom, so a clamp below never drifts it
    $top = $bot - $nh                                                                            # grow/shrink upwards only
    if ($top + $nh -gt $wa.Bottom) { $top = $wa.Bottom - $nh }                                   # would leave the screen: move up instead
    if ($top -lt $wa.Top) { $top = $wa.Top; $nh = [Math]::Min($nh, $wa.Height) }
    if ($pop.Visible) { $pop.SetBounds($pop.Left, $top, $pop.Width, $nh) } else { $pop.Height = $nh; $pop.Top = $top }
    if ($UI.Docked) { $UI.DockPos = $pop.Location; $QS.Dock = @($pop.Left, $pop.Top) }           # in memory; DockB kept as the anchor
    try { [void][ClaudeTray.Scroll]::ShowScrollBar($content.Handle, 1, $false) } catch { }
}
function New-ChatBox([int]$w, [int]$h) {        # the card's conversation: rounded panel + read-only RichTextBox + thin scroll indicator
    $pn = New-Object System.Windows.Forms.Panel; $pn.Width = $w; $pn.Height = $h; $pn.BackColor = $T.Card; $pn.Margin = New-Object System.Windows.Forms.Padding 0
    $pn.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($pn, $true, $null)
    $rb = New-Object System.Windows.Forms.RichTextBox; $rb.ReadOnly = $true; $rb.BorderStyle = 'None'; $rb.ScrollBars = 'None'; $rb.DetectUrls = $false; $rb.TabStop = $false
    $rb.BackColor = $T.Bg; $rb.ForeColor = $T.Tx; $rb.Font = $FUi; $rb.Cursor = [System.Windows.Forms.Cursors]::Default
    $rb.Location = New-Object System.Drawing.Point (px 8), (px 5); $rb.Width = $w - (px 16); $rb.Height = $h - (px 10)
    $sb = New-Object System.Windows.Forms.Panel; $sb.Width = [Math]::Max(2, (px 2)); $sb.BackColor = $T.Mu; $sb.Visible = $false; $sb.Left = $w - (px 4); $sb.Top = px 3; $sb.Height = px 8
    $pn.Tag = @{ Bar = $sb; Box = $rb; Max = 1; Fill = $T.Bg }
    $pn.add_Paint({ param($sender, $e) $e.Graphics.SmoothingMode = 'AntiAlias'; $pth = New-RoundPath 0.5 0.5 ($sender.Width - 1) ($sender.Height - 1) (px 6); $fb2 = New-Object System.Drawing.SolidBrush $sender.Tag.Fill; $e.Graphics.FillPath($fb2, $pth); $fb2.Dispose(); $pen = New-Object System.Drawing.Pen $T.Ln; $e.Graphics.DrawPath($pen, $pth); $pen.Dispose(); $pth.Dispose() })
    $rb.add_VScroll({ param($sender, $e) Update-FieldBar $sender.Parent })
    $pn.Controls.Add($sb); $sb.BringToFront(); $pn.Controls.Add($rb)
    $UI.Fields += $pn
    return @{ Panel = $pn; Box = $rb }
}
function Render-Chat([string]$id) {               # last messages of the chat (from the hidden tab) + what you just sent, Claude-app style
    $ch = $UI.Chats[$id]; if (-not $ch -or $ch.Box.IsDisposed) { return }
    $q = $ch.Q; $wc = Get-WebChat $q; $rb = $ch.Box
    $msgs = if ($wc -and $wc.Msgs) { @($wc.Msgs) } else { @() }
    $pend = $UI.Sending[$id]
    if ($pend) {                                  # delivered once the chat shows it (or after 20 s)
        $lastU = @($msgs | Where-Object { $_.r -eq 'u' })[-1]
        $pk = (($pend.Text -replace '\s+', ' ').Trim()); if ($pk.Length -gt 20) { $pk = $pk.Substring(0, 20) }
        if (($lastU -and (([string]$lastU.t -replace '\s+', ' ').Trim().StartsWith($pk))) -or ((Get-Date) - $pend.At).TotalSeconds -gt 20) { $UI.Sending.Remove($id); $pend = $null }
    }
    $working = [bool](Test-ChatWorking $q)
    $sig = "{0}|{1}|{2}|{3}" -f $msgs.Count, $(if ($msgs.Count) { "$($msgs[-1].r)$(([string]$msgs[-1].t).Length)" } else { '' }), $(if ($pend) { $pend.Text.Length } else { 0 }), $working
    if ($sig -eq $ch.Sig) { return }
    $ch.Sig = $sig
    $atBottom = $true
    try { $total = [int][ClaudeTray.Native]::SendMessage($rb.Handle, 0x00BA, [IntPtr]0, [IntPtr]0); $first = [int][ClaudeTray.Native]::SendMessage($rb.Handle, 0x00CE, [IntPtr]0, [IntPtr]0); $vis = [int][Math]::Floor($rb.Height / [Math]::Max(1, $FUi.Height)); $atBottom = ($total -le $vis) -or ($first + $vis + 2 -ge $total) } catch { }
    $firstBefore = 0; try { $firstBefore = [int][ClaudeTray.Native]::SendMessage($rb.Handle, 0x00CE, [IntPtr]0, [IntPtr]0) } catch { }
    $ranges = New-Object System.Collections.ArrayList
    $rb.SuspendLayout(); $rb.Clear()
    $add = { param($who, $text, $color, $muted)
        $st0 = $rb.TextLength
        $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $FBold; $rb.SelectionColor = $color; $rb.AppendText("$who`n")
        $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $FUi; $rb.SelectionColor = $(if ($muted) { $T.Mu } else { $T.Tx }); $rb.AppendText(([string]$text).Trim() + "`n`n")
        [void]$ranges.Add(@{ S = $st0; E = $rb.TextLength; Who = $who; T = [string]$text })
    }
    if (-not $msgs.Count -and -not $pend) {
        $fallback = if ($q.answer) { [string]$q.answer } elseif ($q.summary) { [string]$q.summary } else { '' }
        if ($fallback) { & $add 'Claude' $fallback $T.Acc $false } else { $rb.SelectionColor = $T.Mu; $rb.AppendText('Loading the conversation...') }
    }
    $iLast = $msgs.Count - 1
    for ($mx = 0; $mx -le $iLast; $mx++) {
        $m = $msgs[$mx]
        if ($m.r -eq 'u') { & $add 'You' $m.t $T.Act $false }
        elseif ([string]$m.t) { & $add 'Claude' $m.t $T.Acc $false }
        elseif ($mx -eq $iLast -and $working) { & $add 'Claude' 'writing...' $T.Acc $true }
    }
    if ($pend) { & $add 'You · sending...' $pend.Text $T.Mu $true }
    $lastRole = if ($pend) { 'u' } elseif ($msgs.Count) { [string]$msgs[-1].r } else { '' }
    if ($lastRole -eq 'a' -and $msgs.Count -and -not [string]$msgs[-1].t) { $lastRole = 'x' }
    if ($working -and $lastRole -eq 'u') { $rb.SelectionStart = $rb.TextLength; $rb.SelectionFont = $FSmall; $rb.SelectionColor = $T.Mu; $rb.AppendText('Claude is writing...') }
    $rb.ResumeLayout()
    $ch.Ranges = $ranges
    if ($ch.KeepTop) {                              # after loading earlier messages: stay near the top, not at the end
        $ch.KeepTop = $false; $added = [Math]::Max(0, $msgs.Count - $ch.CountBefore)
        $rb.SelectionStart = 0; $rb.ScrollToCaret()
        if ($added -gt 0 -and $ranges.Count -gt $added) { $rb.SelectionStart = [int]$ranges[$added].S; $rb.ScrollToCaret() }
    }
    elseif ($atBottom -or $pend) { $rb.SelectionStart = $rb.TextLength; $rb.ScrollToCaret() }
    else { try { $cur = [int][ClaudeTray.Native]::SendMessage($rb.Handle, 0x00CE, [IntPtr]0, [IntPtr]0); [void][ClaudeTray.Native]::SendMessage($rb.Handle, 0x00B6, [IntPtr]0, [IntPtr]($firstBefore - $cur)) } catch { } }
    $rb.SelectionLength = 0
    Update-FieldBar $rb.Parent
}
function Request-Earlier([string]$id) {           # Discord-like: wheel up at the top of a chat loads older messages
    $ch = $UI.Chats[$id]; if (-not $ch) { return }
    if ($ch.MoreAt -and ((Get-Date) - $ch.MoreAt).TotalSeconds -lt 2.5) { return }
    $ch.MoreAt = Get-Date; $ch.KeepTop = $true; $ch.CountBefore = @((Get-WebChat $ch.Q).Msgs).Count; $ch.Sig = ''
    $Web.MsgN[$id] = [int]$(if ($Web.MsgN.ContainsKey($id)) { $Web.MsgN[$id] } else { 12 }) + 10
    [void]$Web.Cmds.Add(@{ Id = $id; Kind = 'more'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) })
    Log ("chat[{0}]: load earlier (now {1} messages)" -f $id, $Web.MsgN[$id]) 'DEBUG'
}
function Test-Submit($e, $tb) {                                   # true when Enter means "submit"; Ctrl+Enter inserts a line break
    if ($e.KeyCode -ne 'Return') { return $false }
    $e.SuppressKeyPress = $true
    if ($e.Control -or $e.Shift) { $tb.SelectedText = "`r`n"; return $false }
    return $true
}
function New-TextBtn([string]$text, [string]$tip, $tag, [scriptblock]$onClick) {
    $l = New-Object System.Windows.Forms.Label; $l.Text = $text; $l.Font = $FSmall; $l.ForeColor = $T.Tx; $l.BackColor = $T.Ln; $l.AutoSize = $false
    $l.Width = px 34; $l.Height = px 20; $l.TextAlign = 'MiddleCenter'; $l.Margin = New-Object System.Windows.Forms.Padding (px 4), 0, 0, 0; $l.Cursor = [System.Windows.Forms.Cursors]::Hand; $l.Tag = $tag
    $pth = New-RoundPath 0 0 $l.Width $l.Height (px 6); $l.Region = New-Object System.Drawing.Region $pth; $pth.Dispose()
    if ($tip) { $TT.SetToolTip($l, $tip) }
    if ($onClick) { $l.add_Click($onClick) }
    return $l
}
function Format-Until($dt) {                    # compact time left before a reset: 42m / 3h12 / Thu 18h
    if (-not $dt) { return '' }
    $sp = ([datetime]$dt) - (Get-Date)
    if ($sp.TotalMinutes -lt 1) { return 'now' }
    if ($sp.TotalHours -lt 1) { return ('{0}m' -f [int][Math]::Floor($sp.TotalMinutes)) }
    if ($sp.TotalHours -lt 24) { return ('{0}h{1:00}' -f [int][Math]::Floor($sp.TotalHours), $sp.Minutes) }
    return ([datetime]$dt).ToString('ddd HH', $EN) + 'h'
}
function Format-Left($dt) {                     # time left: 42m / 3h20 / 6d 17h
    if (-not $dt) { return '' }
    $sp = ([datetime]$dt) - (Get-Date)
    if ($sp.TotalMinutes -lt 1) { return 'now' }
    if ($sp.TotalHours -lt 1) { return ('{0}m' -f [int][Math]::Floor($sp.TotalMinutes)) }
    if ($sp.TotalHours -lt 24) { return ('{0}h{1:00}' -f [int][Math]::Floor($sp.TotalHours), $sp.Minutes) }
    return ('{0}d {1}h' -f $sp.Days, $sp.Hours)
}
function Format-ResetAt($dt) {                  # absolute reset time: 03:39 today/tomorrow, else Mon 18:00
    if (-not $dt) { return '' }
    $d0 = [datetime]$dt
    if (($d0 - (Get-Date)).TotalHours -lt 20) { return $d0.ToString('HH:mm') }
    return $d0.ToString('ddd HH:mm', $EN)
}
function New-UsageBar([string]$label, [double]$used, [string]$detail, [int]$w) {
    # Session  18%                         resets 03:39 · in 3h20
    # ================------------------------------------------   (thin bar underneath)
    $pn = New-Object System.Windows.Forms.Panel; $pn.Width = $w; $pn.Height = px 21; $pn.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, (px 2); $pn.BackColor = $T.Bg
    $pn.Tag = @{ L = $label; U = $used; D = $detail; R = $null }
    $pn.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($pn, $true, $null)
    $pn.add_Paint({
        param($sender, $e)
        $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
        $d = $sender.Tag; $W0 = $sender.Width; $th = px 15
        $col = if ($d.U -ge 90) { $T.Acc } elseif ($d.U -ge 75) { Blend $T.Acc $T.Mu 0.5 } else { $T.Mu }
        $fl = [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        $lt = '{0}  ' -f $d.L; $lsz = [System.Windows.Forms.TextRenderer]::MeasureText($g, $lt, $FSmall, (New-Object System.Drawing.Size 999, $th), $fl)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $lt, $FSmall, (New-Object System.Drawing.Rectangle 0, 0, $lsz.Width, $th), $T.Mu, $fl)
        [System.Windows.Forms.TextRenderer]::DrawText($g, ('{0}%' -f [Math]::Round($d.U)), $FBold, (New-Object System.Drawing.Rectangle $lsz.Width, 0, (px 60), $th), $(if ($d.U -ge 75) { $col } else { $T.Tx }), $fl)
        $rt = if ($d.R) { 'resets {0} · in {1}' -f (Format-ResetAt $d.R), (Format-Left $d.R) } else { '' }
        [System.Windows.Forms.TextRenderer]::DrawText($g, $rt, $FSmall, (New-Object System.Drawing.Rectangle 0, 0, $W0, $th), $T.Mu, ($fl -bor [System.Windows.Forms.TextFormatFlags]::Right))
        $by = $th + (px 2); $bh = [single][Math]::Max(2, (px 2.5))
        Fill-Round $g $T.Ln 0 $by $W0 $bh ($bh / 2)
        if ($d.U -gt 0) { Fill-Round $g $col 0 $by ([Math]::Max($bh, $W0 * [Math]::Min(1.0, $d.U / 100.0))) $bh ($bh / 2) }
    })
    return $pn
}
function Toggle-Manual($d) {
    $cur = @($d.q.Res.steps) | Where-Object { [int]$_.n -eq [int]$d.st.n } | Select-Object -First 1
    $isDone = $cur -and $cur.status -eq 'done'
    Set-StepResult $d.q ([int]$d.st.n) $(if ($isDone) { @{ status = 'pending'; ended = $null } } else { @{ status = 'done'; ended = (Get-Iso (Get-Date)) } })
    Log ("manual step {0}#{1} -> {2}" -f $d.q.id, $d.st.n, $(if ($isDone) { 'pending' } else { 'done' })) 'DEBUG'
    Refresh-Quests $true
}
function Build-RowsCore {
    $UI.ViewSig = Get-ViewSig; $UI.Built = $true; $UI.ShotAt = (Get-Date).AddMilliseconds(600); $UI.ShotWhy = 'build'
    # keep what the user is typing across rebuilds
    $focusedId = $null
    foreach ($inp in @($UI.Inputs)) { try { if ($inp.Box.Focused -and $inp.N -eq 100000) { $focusedId = [string]$inp.Box.Tag.id } } catch { } }
    $content.SuspendLayout()
    $TT.RemoveAll()
    foreach ($c in @($content.Controls)) { $content.Controls.Remove($c); $c.Dispose() }
    $UI.Live = @{}
    $UI.Inputs = @(); $UI.Markers = @(); $UI.Fields = @(); $UI.Bars = @(); $UI.Chats = @{}; $UI.RenderAfterBuild = @()
    $W = $pop.ClientSize.Width - (px 12) - (px 2)       # inner width (native scrollbar hidden; wheel scrolls)
    # header: thin drag band + pin
    $hdr = New-Row (px 16); $hdr.Width = $W; $hdr.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    foreach ($hn in 'MouseDown', 'MouseMove', 'MouseUp') { $hdr."add_$hn"($dragH[$hn]) }
    $grip = New-Lbl '' $FSmall $T.Mu ($W - (px 20)); $grip.Cursor = [System.Windows.Forms.Cursors]::SizeAll
    foreach ($hn in 'MouseDown', 'MouseMove', 'MouseUp') { $grip."add_$hn"($dragH[$hn]) }
    $grip.add_Paint({ param($sender, $e) $b = New-Object System.Drawing.SolidBrush $T.Ln; $cx = [int]($sender.Width / 2); $e.Graphics.FillRectangle($b, $cx - (px 14), [int](($sender.Height - (px 3)) / 2), (px 28), (px 3)); $b.Dispose() })
    $pinG = New-Glyph $(if ($UI.Docked) { $Gly.unpin } else { $Gly.pin }) $(if ($UI.Docked) { 'Unpin (closes on click outside)' } else { 'Pin here (stays on top)' }) $(if ($UI.Docked) { $T.Acc } else { $T.Mu }) $null { if ($UI.Docked) { $UI.Docked = $false } else { $UI.Docked = $true; Pin-Pop; Set-DockMemo; Save-State }; Request-Build }
    $pinG.Height = px 16
    $gearG = New-Glyph $Gly.gear 'Settings (same as right-click on the tray icon)' $T.Mu $null { $UI.MenuFromPanel = $true; $menu.Show($this, (New-Object System.Drawing.Point 0, $this.Height)) }
    $gearG.Height = px 16; $grip.Width = $grip.Width - (px 20)
    $hdr.Controls.AddRange([System.Windows.Forms.Control[]]@($grip, $gearG, $pinG)); $content.Controls.Add($hdr)
    $bsw = [Diagnostics.Stopwatch]::StartNew(); $bt = [ordered]@{}
    $vis = @($QS.List | Where-Object { $_.Visible })
    if (-not $vis) {
        $r0 = New-Row (px 22); $r0.Width = $W; $r0.Margin = New-Object System.Windows.Forms.Padding 0, (px 4), 0, 0
        $r0.Controls.Add((New-Lbl $(if (@($QS.List).Count) { 'All chats hidden - they come back when Claude writes to them' } else { 'No chat has written a quest yet (type /tray in a chat)' }) $FSmall $T.Mu $W)); $content.Controls.Add($r0)
    }
    foreach ($q in $vis) {
        $id = [string]$q.id
        if (-not $UI.Expanded.ContainsKey($id)) { $UI.Expanded[$id] = ($q.St -eq 'act') }
        $card = New-Object System.Windows.Forms.FlowLayoutPanel; $card.FlowDirection = 'TopDown'; $card.WrapContents = $false; $card.AutoSize = $true; $card.AutoSizeMode = 'GrowAndShrink'
        $card.Width = $W; $card.BackColor = $T.Card; $card.Margin = New-Object System.Windows.Forms.Padding 0, (px 4), 0, 0; $card.Padding = New-Object System.Windows.Forms.Padding (px 6), (px 3), (px 6), (px 4)
        $card.add_Resize({ param($sender, $e) try { $pth = New-RoundPath 0 0 $sender.Width $sender.Height (px 8); $old = $sender.Region; $sender.Region = New-Object System.Drawing.Region $pth; $pth.Dispose(); if ($old) { $old.Dispose() } } catch { } })
        $IW = $W - (px 12)
        # title row
        $row = New-Row (px 22); $row.Width = $IW; $row.Cursor = [System.Windows.Forms.Cursors]::Hand; $row.Tag = $id
        $row.add_Click({ $UI.Expanded[[string]$this.Tag] = -not $UI.Expanded[[string]$this.Tag]; Request-Build })
        $ls0 = Get-LiveState $q; $stTxt = $ls0.Txt; $stCol = $ls0.Col           # (was read before being set: first card got a stale marker)
        $mk = New-Marker $ls0.Mk; $UI.Markers += $mk
        $stL = New-Lbl $stTxt $FSmall $stCol (px 60); $stL.AutoSize = $true; $stL.Margin = New-Object System.Windows.Forms.Padding 0, (px 1), 0, 0
        $tl = New-Lbl ([string]$q.title) $FUi $T.Tx ($IW - (px 20) - 4 * (px 20) - (px 8)); $tl.Margin = New-Object System.Windows.Forms.Padding (px 4), 0, 0, 0; $tl.Tag = $id; $tl.Cursor = [System.Windows.Forms.Cursors]::Hand
        $tl.add_Click({ $UI.Expanded[[string]$this.Tag] = -not $UI.Expanded[[string]$this.Tag]; Request-Build })
        $age = New-Lbl ('· ' + (Format-Age $q.Upd)) $FSmall $T.Mu (px 30); $age.AutoSize = $true; $age.Margin = New-Object System.Windows.Forms.Padding (px 4), (px 1), 0, 0
        $bellOn = -not ($QS.Bells.ContainsKey($id) -and -not $QS.Bells[$id])
        $gA = New-Glyph $Gly.app 'Open in the Claude app' $T.Mu $q { Open-Chat $this.Tag $false }
        $gW = New-Glyph $Gly.web 'Open on claude.ai' $T.Mu $q { Open-Chat $this.Tag $true }
        $gB = New-Glyph $(if ($bellOn) { $Gly.bell } else { $Gly.belloff }) $(if ($bellOn) { 'Notifications on' } else { 'Notifications off' }) $(if ($bellOn) { $T.Mu } else { $T.Ln }) $id { $kb = [string]$this.Tag; $QS.Bells[$kb] = ($QS.Bells.ContainsKey($kb) -and -not $QS.Bells[$kb]); Save-State; Request-Build }
        $gC = New-Glyph $Gly.chat 'Conversation (what you sent + Claude''s replies)' $T.Mu $q { if ($UI.ConvQ -and $UI.ConvQ.id -eq $this.Tag.id) { $UI.SidePinned = $false; $UI.ConvQ = $null; $Web.ConvFor = ''; Hide-Side } else { Show-Conv $this.Tag } }
        $gX = New-Glyph $Gly.x 'Hide until Claude writes again' $T.Mu $q { $QS.Hidden[[string]$this.Tag.id] = [string]$this.Tag.updated; Save-State; Refresh-Quests $true }
        # stop button sits where the age is; Update-Live swaps them when Claude starts/stops generating (no rebuild)
        $gStop = New-Glyph $Gly.stop 'Stop Claude (the app''s stop button)' $T.Acc $q { Stop-Chat $this.Tag }; $gStop.Visible = $ls0.Stop
        $rowCtl = @($mk, $tl, $gA, $gW, $gB, $gX)
        $stL.Tag = $q; $stL.add_Click({ $qq = $this.Tag; $qk = [string]$qq.id; if ($UI.Queue.ContainsKey($qk)) { $txt = $UI.Queue[$qk]; $UI.Queue.Remove($qk); Log "queue[$qk]: send now (user, interrupts)"; if (-not (Send-ToChat $qq $txt 'send-now' $true)) { $UI.Drafts[$qk] = $txt }; Refresh-Quests $true } })
        $UI.Live[$id] = @{ Q = $q; St = $stL; Mk = $mk; Age = $age; Stop = $gStop; Tl = $tl; Ans = $null }
        $row.Controls.AddRange([System.Windows.Forms.Control[]]$rowCtl); $card.Controls.Add($row)
        $TT.SetToolTip($mk, $stTxt); $TT.SetToolTip($tl, ("{0}  ·  {1}" -f $stTxt, (Format-Age $q.Upd)))
        if (-not $UI.Expanded[$id]) { $row.Controls.Add($gStop); $tl.Width = $tl.Width - (px 20) }
        if ($UI.Expanded[$id]) {
            # conversation (browser) - or Claude's quest text when the browser isn't available
            $ansTxt = if ($q.answer) { [string]$q.answer } elseif ($q.summary) { [string]$q.summary } else { '' }
            if (Get-WebChat $q) {
                $ar = New-Row (px 180); $ar.Width = $IW; $ar.Margin = New-Object System.Windows.Forms.Padding 0, (px 2), 0, (px 3)
                $pad = New-Lbl '' $FSmall $T.Mu (px 24); $pad.Height = px 180
                $cb = New-ChatBox ($IW - (px 24) - (px 20)) (px 180)
                $cb.Box.Tag = @{ Q = $q; Chat = $id }; Hook-Side $cb.Box
                $UI.Chats[$id] = @{ Box = $cb.Box; Q = $q; Sig = ''; Ranges = @(); KeepTop = $false; CountBefore = 0; MoreAt = $null }
                $tg = New-Glyph $Gly.full 'Read Claude''s last reply on the side' $T.Mu $q { $UI.SideFor = $null; Show-Side (Get-AnswerFull $this.Tag) $this ("Claude's answer - {0}" -f $this.Tag.title); $UI.SidePinned = $true }
                $ar.Controls.AddRange([System.Windows.Forms.Control[]]@($pad, $cb.Panel, $tg)); $card.Controls.Add($ar)
                $UI.RenderAfterBuild += $id
            }
            elseif ($ansTxt) {
                if (-not $UI.AnsOpen.ContainsKey($id)) { $UI.AnsOpen[$id] = $false }
                $open = $UI.AnsOpen[$id]
                $ar = New-Row (px 40); $ar.Width = $IW; $ar.Margin = New-Object System.Windows.Forms.Padding 0, (px 2), 0, (px 2)
                $aw = $IW - (px 24) - (px 20)
                $need = [System.Windows.Forms.TextRenderer]::MeasureText($ansTxt, $FSmall, (New-Object System.Drawing.Size ($aw - (px 12)), 2000), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height + (px 10)
                $ah = [Math]::Min($need, (px 150))                 # full text up to a cap; beyond that: expand or hover for the side panel
                $ar.Height = $ah
                $pad = New-Lbl '' $FSmall $T.Mu (px 24); $pad.Height = $ah
                $af = New-Field $aw $ah $FSmall $null; $af.Box.ReadOnly = $true; $af.Box.Text = ($ansTxt -replace "(?<!`r)`n", "`r`n"); $af.Panel.Tag.Fill = $T.Card; $af.Box.BackColor = $T.Card
                $af.Box.TabStop = $false; $af.Box.Cursor = [System.Windows.Forms.Cursors]::Default
                $UI.Live[$id].Ans = $af.Box; $UI.Live[$id].AnsOrig = $af.Box.Text
                $af.Box.Tag = @{ Q = $q }; Hook-Side $af.Box
                $tg = New-Glyph $Gly.full 'Read the full answer on the side' $T.Mu $q { $UI.SideFor = $null; Show-Side (Get-AnswerFull $this.Tag) $this ("Claude's answer - {0}" -f $this.Tag.title); $UI.SidePinned = $true }
                $tg.Visible = $true
                $ar.Controls.AddRange([System.Windows.Forms.Control[]]@($pad, $af.Panel, $tg)); $card.Controls.Add($ar)
            }
            foreach ($st in @($q.steps)) {
                $rec = @($q.Res.steps) | Where-Object { [int]$_.n -eq [int]$st.n } | Select-Object -First 1
                $status = if ($rec) { [string]$rec.status } else { 'pending' }
                $isRun = $QS.Running.ContainsKey("$id#$($st.n)")
                $sr = New-Row (px 20); $sr.Width = $IW
                $kg = switch ([string]$st.kind) { 'cmd' { $Gly.cmd } 'ps' { $Gly.cmd } 'exe' { $Gly.run } 'dir' { $Gly.dir } 'file' { $Gly.file } 'url' { $Gly.url } 'observe' { $Gly.eye } default { $Gly.hand } }
                $kcol = $T.Mu
                if ($status -eq 'done') { $kg = $Gly.boxok; $kcol = $T.Ok } elseif ($status -eq 'skipped') { $kg = $Gly.skip; $kcol = Blend $T.Mu $T.Card 0.4 } elseif ($status -eq 'failed') { $kcol = $T.Acc }
                $kl = New-Glyph $kg $(switch ($status) { 'done' { 'done' } 'skipped' { 'skipped (right-click to restore)' } 'failed' { 'failed' } default { [string]$st.kind } }) $kcol $null $null $true; $kl.Cursor = [System.Windows.Forms.Cursors]::Default; $kl.Margin = New-Object System.Windows.Forms.Padding 0
                $txt = [string]$st.label; $hint = if ($st.cmd) { ([string]$st.cmd -split "`n")[0] } elseif ($st.path) { [string]$st.path } elseif ($st.url) { [string]$st.url } else { '' }
                $actW = px 64; $exW = px 46
                $isObs = ([string]$st.kind -eq 'observe')
                $kindW = switch ([string]$st.kind) { 'observe' { 0 } 'manual' { 0 } { $_ -in 'dir', 'file', 'url' } { px 20 } 'exe' { (px 40) + $exW } default { $actW + $exW } }
                $lw = $IW - (px 24) - (px 6) - $kindW - $(if ([bool]$st.admin) { px 20 } else { 0 })
                $ll = New-Lbl $txt $FUi $(if ($status -eq 'done') { $T.Mu } else { $T.Tx }) $lw; $ll.Margin = New-Object System.Windows.Forms.Padding (px 4), 0, 0, 0
                $lh = [System.Windows.Forms.TextRenderer]::MeasureText($txt, $FUi, (New-Object System.Drawing.Size $lw, 2000), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
                if ($lh -gt $FUi.Height + 2) { $lh = [Math]::Min($lh, 3 * $FUi.Height) + (px 4); $ll.AutoEllipsis = $false; $ll.TextAlign = 'MiddleLeft'; $ll.Height = $lh; $sr.Height = $lh }   # wrap instead of cutting
                if ($status -eq 'skipped') { $ll.Font = $FStrike; $ll.ForeColor = Blend $T.Mu $T.Card 0.5 }
                elseif ($status -eq 'done') { $ll.ForeColor = $T.Mu }
                $TT.SetToolTip($ll, $(if ($hint) { "$hint`r`n(right-click: skip / unskip)" } else { 'right-click: skip / unskip' }))
                $ll.Tag = @{ q = $q; st = $st; status = $status }
                $ll.add_MouseUp({ param($sender, $e) if ($e.Button -eq 'Right') { $d = $sender.Tag; Log ("step {0}#{1} right-click (was {2})" -f $d.q.id, $d.st.n, $d.status) 'DEBUG'; if ($d.status -eq 'skipped') { Set-StepResult $d.q ([int]$d.st.n) @{ status = 'pending'; ended = $null } } else { Set-StepResult $d.q ([int]$d.st.n) @{ status = 'skipped'; ended = (Get-Iso (Get-Date)) } }; Refresh-Quests $true } })
                $adm = if ([bool]$st.admin) { New-Glyph $Gly.key 'Needs admin (UAC prompt)' $T.Mu $null $null $true } else { $null }
                $ex = New-Lbl $(if ($isRun) { 'running' } elseif ($status -eq 'skipped') { 'skipped' } elseif ($rec -and $null -ne $rec.exit) { "exit $($rec.exit)" } elseif ($status -eq 'failed') { 'failed' } else { '' }) $FMono $(if ($status -eq 'failed' -or ($rec -and $rec.exit -and $rec.exit -ne 0)) { $T.Acc } else { $T.Ok }) $exW; $ex.TextAlign = 'MiddleRight'
                $tag = @{ q = $q; st = $st }
                $acts = @()
                switch ([string]$st.kind) {
                    'observe' { $ex = $null }
                    'manual' {
                        $acts = @()
                        $kl.Tag = $tag; $kl.Cursor = [System.Windows.Forms.Cursors]::Hand; $kl.add_Click({ Toggle-Manual $this.Tag })
                        $ll.Cursor = [System.Windows.Forms.Cursors]::Hand
                        $ll.add_MouseUp({ param($sender, $e) if ($e.Button -eq 'Left') { Toggle-Manual $sender.Tag } })
                    }
                    { $_ -in 'dir', 'file', 'url' } { $acts = @((New-Glyph $Gly.dir 'Open' $(if ($status -in 'done', 'skipped') { $T.Mu } else { $T.Acc }) $tag { $d = $this.Tag; Start-Step $d.q $d.st; Refresh-Quests $true })) }
                    'exe' { $acts = @((New-Glyph $Gly.run 'Run' $(if ($status -in 'done', 'skipped') { $T.Mu } else { $T.Acc }) $tag { $d = $this.Tag; Start-Step $d.q $d.st; Refresh-Quests $true }), (New-Glyph $Gly.dir 'Open its folder' $T.Mu $tag { $d = $this.Tag; Start-Process (Split-Path ([string]$d.st.path) -Parent) })) }
                    default {
                        $acts = @((New-Glyph $(if ($isRun) { $Gly.spin } else { $Gly.run }) $(if ($isRun) { 'Running...' } elseif ($status -eq 'done') { 'Run again' } else { 'Run (hidden, output captured)' }) $(if ($isRun -or $status -in 'done', 'skipped') { $T.Mu } else { $T.Acc }) $tag { $d = $this.Tag; Start-Step $d.q $d.st; Refresh-Quests $true }),
                                  (New-Glyph $Gly.copy 'Copy the command' $T.Mu $tag { $d = $this.Tag; Set-Clipboard -Value ([string]$d.st.cmd) }),
                                  (New-Glyph $Gly.bot 'Ask Claude to do this step itself' $T.Mu $tag { $d = $this.Tag; if (Send-ToChat $d.q ("do step {0} yourself: {1}" -f $d.st.n, $d.st.label) 'step-auto') { Refresh-Quests $true } }))
                    }
                }
                $ctrls = @($kl, $ll); if ($adm) { $ctrls += $adm }; if ($ex) { $ctrls += $ex }; $ctrls += $acts
                $sr.Controls.AddRange([System.Windows.Forms.Control[]]$ctrls); $card.Controls.Add($sr)
                if ($isObs) {                                   # answer box on its own row under the question: 1 line, grows to 3 with content
                    $otxt = if ($rec -and $rec.answer) { [string]$rec.answer } else { '' }
                    $olines = if ($otxt) { [Math]::Ceiling([System.Windows.Forms.TextRenderer]::MeasureText($otxt, $FUi, (New-Object System.Drawing.Size ($IW - (px 36)), 2000), [System.Windows.Forms.TextFormatFlags]::WordBreak).Height / [Math]::Max(1, $FUi.Height)) } else { 1 }
                    $obH = (px 10) + [Math]::Min(3, [Math]::Max(1, $olines)) * $FUi.Height
                    $orow = New-Row $obH; $orow.Width = $IW; $orow.Margin = New-Object System.Windows.Forms.Padding 0, 0, 0, (px 2)
                    $opad = New-Lbl '' $FSmall $T.Mu (px 24); $opad.Height = $obH
                    $of = New-Field ($IW - (px 24)) $obH $FUi $tag
                    if ($rec -and $rec.answer) { $of.Box.Text = [string]$rec.answer; $of.Box.ForeColor = $T.Mu; $of.Box.Tag.Saved = [string]$rec.answer }
                    $of.Panel.Tag.Max = 3
                    $of.Box.add_TextChanged({ param($sender, $e) Grow-Field $sender.Parent 3; $sender.ForeColor = $(if ($sender.Tag.Saved -and $sender.Text -eq $sender.Tag.Saved) { $T.Mu } else { $T.Tx }) })
                    $of.Box.add_KeyDown({ param($sender, $e) if (Test-Submit $e $sender) { $d = $sender.Tag; Set-StepResult $d.q ([int]$d.st.n) @{ status = 'done'; answer = $sender.Text; ended = (Get-Iso (Get-Date)) }; $UI.FocusAfter = [int]$d.st.n; Refresh-Quests $true } })
                    $UI.Inputs += @{ N = [int]$st.n; Box = $of.Box }
                    $orow.Controls.AddRange([System.Windows.Forms.Control[]]@($opad, $of.Panel)); $card.Controls.Add($orow)
                }
            }
            # reply field + send + auto
            $fr = New-Row (px 30); $fr.Width = $IW; $fr.Margin = New-Object System.Windows.Forms.Padding 0, (px 3), 0, 0
            $ff = New-Field ($IW - (px 20) - (px 34) - (px 10)) (px 30) $FUi $q; $fb = $ff.Box
            $allDone = (@($q.steps).Count -gt 0) -and -not (@($q.steps) | Where-Object { $n = [int]$_.n; -not (@($q.Res.steps) | Where-Object { [int]$_.n -eq $n -and $_.status -in 'done', 'skipped' }) })
            if ($UI.Drafts.ContainsKey($id)) { $fb.Text = [string]$UI.Drafts[$id] }
            elseif ($q.St -eq 'act' -and $allDone) { $fb.Text = $(if ($q.reply) { [string]$q.reply } else { 'check' }) }
            $ff.Panel.Tag.Max = 5
            $fb.add_TextChanged({ param($sender, $e) $UI.Drafts[[string]$sender.Tag.id] = $sender.Text; Grow-Field $sender.Parent 5 })
            $fb.add_KeyUp({ param($sender, $e) Update-FieldBar $sender.Parent }); $fb.add_MouseWheel({ param($sender, $e) Update-FieldBar $sender.Parent }); $fb.add_Click({ param($sender, $e) Update-FieldBar $sender.Parent })
            if ($focusedId -eq $id) { $UI.FocusReply = $fb }
            $fb.add_KeyDown({ param($sender, $e) if (Test-Submit $e $sender) { $qq = $sender.Tag; $txt = $sender.Text; if (Send-ToChat $qq $txt 'enter') { $UI.Drafts.Remove([string]$qq.id); $sender.Text = ''; Refresh-Quests $true } } })
            $UI.Inputs += @{ N = 100000; Box = $fb }
            $gS = New-Glyph $Gly.send 'Send to this chat (Enter)' $T.Acc @{ q = $q; tb = $fb } { $d = $this.Tag; if (Send-ToChat $d.q $d.tb.Text 'button') { $UI.Drafts.Remove([string]$d.q.id); $d.tb.Text = ''; Refresh-Quests $true } }; $gS.Margin = New-Object System.Windows.Forms.Padding (px 4), (px 5), 0, 0
            $gR = New-TextBtn 'auto' 'Ask Claude to do these steps itself' $q { if (Send-ToChat $this.Tag 'do it yourself' 'auto') { Refresh-Quests $true } }; $gR.Margin = New-Object System.Windows.Forms.Padding (px 2), (px 5), 0, 0
            $gStop.Margin = New-Object System.Windows.Forms.Padding (px 2), (px 5), 0, 0
            $ff.Panel.Width = $ff.Panel.Width - (px 20); $fb.Width = $fb.Width - (px 20)
            $fr.Controls.AddRange([System.Windows.Forms.Control[]]@($ff.Panel, $gS, $gStop, $gR)); $card.Controls.Add($fr)
        }
        $content.Controls.Add($card); $bt["card$($bt.Count)"] = $bsw.ElapsedMilliseconds
    }
    # footer: usage bars (thin), click for reset times
    $ft = New-Object System.Windows.Forms.FlowLayoutPanel; $ft.FlowDirection = 'TopDown'; $ft.WrapContents = $false; $ft.AutoSize = $true; $ft.AutoSizeMode = 'GrowAndShrink'; $ft.Width = $W; $ft.Margin = New-Object System.Windows.Forms.Padding 0, (px 6), 0, 0; $ft.Padding = New-Object System.Windows.Forms.Padding 0
    if (@($S.Limits).Count) {
        foreach ($l in @($S.Limits)) {
            $n = if ($l.Key -and $ShortNames.ContainsKey([string]$l.Key)) { $ShortNames[[string]$l.Key] } else { $l.Label }
            $nn = (Get-Culture).TextInfo.ToTitleCase([string]$n)
            $ub = New-UsageBar $nn ([double]$l.Used) (Format-Until $l.Reset) $W; $ub.Tag.R = $l.Reset; $UI.Bars += $ub; $ft.Controls.Add($ub)
            $TT.SetToolTip($ub, ("{0}: {1}% used - resets {2} (in {3})" -f $l.Label, [Math]::Round([double]$l.Used), $(if ($l.Reset) { ([datetime]$l.Reset).ToString('dddd HH:mm', $EN) } else { '?' }), (Format-Until $l.Reset)))
        }
    } else { $ft.Controls.Add((New-Lbl $(if ($S.Error) { $S.Error } else { 'usage: no data yet' }) $FSmall $T.Mu $W)) }
    if ($UI.UsageOpen -and $S.Error -and @($S.Limits).Count) { $ft.Controls.Add((New-Lbl $S.Error $FSmall $T.Acc $W)) }
    $content.Controls.Add($ft); $bt.footer = $bsw.ElapsedMilliseconds
    Hook-Click $content
    $content.ResumeLayout(); $bt.layout = $bsw.ElapsedMilliseconds
    # size to content, capped
    Fit-Pop; $bt.fit = $bsw.ElapsedMilliseconds
    $pop.Invalidate()
    $UI.BuildPhases = (($bt.Keys | ForEach-Object { "$_=$($bt[$_])" }) -join ' ')
    foreach ($f in @($UI.Fields)) { if ($f.Tag.Max -gt 1 -and $f.Tag.Box.Text) { Grow-Field $f $f.Tag.Max } else { Update-FieldBar $f } }
    foreach ($rid in @($UI.RenderAfterBuild)) { Render-Chat $rid }
    if ($UI.FocusReply) { $fr0 = $UI.FocusReply; $UI.FocusReply = $null; try { $fr0.Focus(); $fr0.SelectionStart = $fr0.Text.Length; $fr0.ScrollToCaret(); Grow-Field $fr0.Parent 5 } catch { } }
    elseif ($null -eq $UI.FocusAfter) { try { $pop.ActiveControl = $null } catch { } }
    if ($null -ne $UI.FocusAfter) {                       # Enter in a box: jump to the next box
        $nx = @($UI.Inputs | Where-Object { $_.N -gt $UI.FocusAfter } | Sort-Object { $_.N })[0]
        $UI.FocusAfter = $null
        if ($nx) { Pin-Pop; $UI.FocusTarget = $nx.Box; $UI.FocusTries = 0; try { $pop.ActiveControl = $nx.Box } catch { } }
        else { Log "focus: no box after $($UI.FocusAfter)" 'DEBUG' }
    }
}
function Request-Build { $UI.NeedBuild = $true }
function Get-LiveState($q) {                       # what the title row should show right now
    $id = [string]$q.id
    if ($UI.Queue.ContainsKey($id)) { return @{ Txt = 'queued · send now'; Col = $T.Acc; Mk = 'working'; Stop = $true } }
    if (Test-ChatWorking $q) { return @{ Txt = 'working'; Col = $T.Mu; Mk = 'working'; Stop = $true } }
    switch ([string]$q.St) { 'act' { return @{ Txt = 'to do'; Col = $T.Act; Mk = 'act'; Stop = $false } } 'done' { return @{ Txt = 'your turn'; Col = $T.Pur; Mk = 'done'; Stop = $false } } default { return @{ Txt = 'sent'; Col = $T.Mu; Mk = 'working'; Stop = $false } } }
}
function Update-Live {                              # cheap in-place refresh of status words, markers, stop buttons
    if ($UI.WebReady) { Push-WebState; return }
    foreach ($id in @($UI.Live.Keys)) {
        $c = $UI.Live[$id]; $ls = Get-LiveState $c.Q
        try {
            if ($c.LastTxt -ne $ls.Txt) { $c.LastTxt = $ls.Txt; $TT.SetToolTip($c.Mk, $ls.Txt); $TT.SetToolTip($c.Tl, ("{0}  ·  {1}" -f $ls.Txt, (Format-Age $c.Q.Upd))) }
            if ($c.Mk.Tag -ne $ls.Mk) { $c.Mk.Tag = $ls.Mk; $c.Mk.Invalidate() }
            if ($c.Ans) {                               # live preview of Claude's answer while it writes in this chat
                $wc = Get-WebChat $c.Q
                # browser text: live while Claude writes, then until Claude updates the quest (max 90 s)
                if ($wc) { $liveOn = [bool]$wc.Reply -and ($wc.Working -or ($wc.EndAt -gt $c.Q.Upd -and ((Get-Date) - $wc.EndAt).TotalSeconds -lt 90)); $want = if ($liveOn) { [string]$wc.Reply } else { [string]$c.AnsOrig } }
                else {
                $liveOn = $Probe.LiveText -and $Probe.LivePage -and $c.Q.title -and $Probe.LivePage.StartsWith([string]$c.Q.title) -and ((Get-Date) - $Probe.LiveAt).TotalSeconds -lt 8 -and $Probe.LiveAt -gt $c.Q.Upd
                $want = if ($liveOn) { [string]$Probe.LiveText } else { [string]$c.AnsOrig }
                }
                if ($c.Ans.Text -ne $want) { $c.Ans.Text = $want; $c.Ans.ForeColor = $(if ($liveOn) { $T.Mu } else { $T.Tx }); $c.Ans.SelectionStart = $c.Ans.Text.Length; $c.Ans.ScrollToCaret(); Update-FieldBar $c.Ans.Parent }
            }
            if ($c.Stop.Visible -ne $ls.Stop) { $c.Stop.Visible = $ls.Stop; Log ("live[{0}]: {1}" -f $id, $ls.Txt) 'DEBUG' }

        } catch { }
    }
    $UI.Markers = @($UI.Live.Values | ForEach-Object { $_.Mk })
    if ($UI.ConvQ) { Render-Conv }
    foreach ($cid in @($UI.Chats.Keys)) { Render-Chat $cid }
    foreach ($ub in @($UI.Bars)) { try { $nd = Format-Until $ub.Tag.R; if ($nd -ne $ub.Tag.D) { $ub.Tag.D = $nd; $ub.Invalidate() } } catch { } }
}
function Get-ViewSig {                              # everything a full rebuild depends on (live state excluded)
    $parts = @("d$($UI.Docked)", "u$($UI.UsageOpen)", ((@($S.Limits) | ForEach-Object { [Math]::Round([double]$_.Used) }) -join ','), $S.Error)
    foreach ($q in @($QS.List | Where-Object { $_.Visible })) {
        $id = [string]$q.id
        $parts += "$id|$([bool](Get-WebChat $q))|$($q.updated)|$($q.St)|$($UI.Expanded[$id])|$($UI.AnsOpen[$id])|$($QS.Bells[$id])|$($QS.Running.Keys -join ',')|" + ((@($q.Res.steps) | ForEach-Object { "$($_.n):$($_.status):$($_.exit):$($_.answer)" }) -join ';')
    }
    return ($parts -join '#')
}
function Refresh-Quests([bool]$rebuild) {
    $prevStates = @{}; foreach ($q in $QS.List) { $prevStates[[string]$q.id] = $q.St }
    $QS.List = Read-Quests
    foreach ($q in $QS.List) {
        $id = [string]$q.id
        $wasSeen = $prevStates.ContainsKey($id)
        if ($q.Visible -and ($q.St -in 'act', 'done') -and ((-not $wasSeen -and $UI.Booted) -or ($wasSeen -and $prevStates[$id] -ne $q.St)) -and -not ($QS.Bells.ContainsKey($id) -and -not $QS.Bells[$id])) {
            try { $tray.ShowBalloonTip(5000, [string]$q.title, $(if ($q.St -eq 'act') { "Steps for you: $(@($q.steps).Count)" } else { 'Claude is done - your turn' }), [System.Windows.Forms.ToolTipIcon]::None) } catch { }
        }
    }
    foreach ($q in $QS.List) { $id = [string]$q.id; if ($prevStates.ContainsKey($id) -and $prevStates[$id] -ne $q.St) { Log ("quest {0}: {1} -> {2} (updated {3}, visible {4})" -f $id, $prevStates[$id], $q.St, $q.updated, $q.Visible)
        # Claude writes the quest as its last action: if the hidden tab still says 'working', its stream stalled - reload it now
        $wq = $Web.Chats[$id]; if ($webEnabled -and $prevStates[$id] -eq 'working' -and $wq -and $wq.Working) { [void]$Web.Cmds.Add(@{ Id = $id; Kind = 'reload'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log "reload[$id]: new quest while the tab still says working" } } }
    $UI.Booted = $true
    Update-TrayIcon
    Sync-Anim
    if ($UI.Shown) { if ($rebuild -and (Get-ViewSig) -ne $UI.ViewSig) { Request-Build } else { Update-Live } }
    elseif ($rebuild -and (Get-ViewSig) -ne $UI.ViewSig) { $UI.PreBuild = $true }
}

function Get-BindingUsed {
    if (@($S.Limits).Count -eq 0) { return $null }
    return ($S.Limits | ForEach-Object { [double]$_.Used } | Measure-Object -Maximum).Maximum
}
$ShortNames = @{ five_hour = 'session'; seven_day = 'week'; seven_day_opus = 'Opus week'; seven_day_sonnet = 'Sonnet week'; seven_day_oauth_apps = 'apps week'; extra_usage = 'extra' }
function Update-TrayIcon {
    $iconPx = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    $err = [bool]$S.Error -and -not $S.Updated
    if ($S.Updated -and ((Get-Date) - $S.Updated).TotalSeconds -gt 3 * [int]$Cfg.pollSeconds) { $err = $true }
    $fl = Get-IconFlags; $UI.IconFlags = $fl
    # only talk to the shell when the picture changes (frequent tray updates can keep an auto-hide taskbar up)
    $ikey = "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f $iconPx, [Math]::Round([double](Get-BindingUsed)), $err, $LightTaskbar, $fl.Needs, $fl.Working, ('{0}{1}' -f $fl.Unread, $fl.Ask), $(if ($fl.Working) { [int]$UI.Phase % 4 } else { 0 })
    if ($ikey -ne $UI.IconKey) {
        $UI.IconKey = $ikey
        $bmp = New-TrayIcon $iconPx (Get-BindingUsed) $err $LightTaskbar '' ([int]$UI.Phase) $fl
        $h = $bmp.GetHicon(); $bmp.Dispose()
        $tray.Icon = [System.Drawing.Icon]::FromHandle($h)
        if ($UI.IconHandle -ne [IntPtr]::Zero) { [void][ClaudeTray.Native]::DestroyIcon($UI.IconHandle) }
        $UI.IconHandle = $h
    }
    $txt = if ($err -and $S.Error) { 'Tray for Claude - ' + $S.Error }
    elseif (@($S.Limits).Count) {
        $parts = foreach ($l in @($S.Limits)) { $n = $l.Label; if ($l.Key -and $ShortNames.ContainsKey([string]$l.Key)) { $n = $ShortNames[[string]$l.Key] }; '{0} {1}%' -f $n, [Math]::Round([double]$l.Used) }
        'Tray for Claude - ' + ($parts -join ', ')
    } else { 'Tray for Claude' }
    $vis0 = @($QS.List | Where-Object { $_.Visible })
    $pre = @()
    $nNeed = @($vis0 | Where-Object { $_.St -eq 'act' -or ($Web.Chats[[string]$_.id] -and (@($Web.Chats[[string]$_.id].Prompts).Count -or $Web.Chats[[string]$_.id].Q)) }).Count; if ($nNeed) { $pre += "$nNeed need you" }
    $nWork = @($vis0 | Where-Object { Test-ChatWorking $_ }).Count; if ($nWork) { $pre += "$nWork working" }
    $nNew = @($vis0 | Where-Object { Test-Unread $_ }).Count; if ($nNew) { $pre += "$nNew new" }
    if ($pre.Count) { $txt = ($pre -join ', ') + ' - ' + ($txt -replace '^ClaudeTray - ', '') }
    if ($txt.Length -gt 63) { $txt = $txt.Substring(0, 60) + '...' }
    if ($txt -ne $UI.TipText) { $UI.TipText = $txt; try { $tray.Text = $txt } catch { } }
}

function Show-Pop([string]$why = 'hover') {
    $UI.ShowWhy = $why
    if (-not $UI.Built -or (Get-ViewSig) -ne $UI.ViewSig) { Build-Rows } else { Update-Live; Log "show: reused prebuilt flyout" 'DEBUG' }
    $cur = [System.Windows.Forms.Cursor]::Position
    $scr = [System.Windows.Forms.Screen]::FromPoint($cur)
    $sb = $scr.Bounds
    $w = $pop.Width; $h = $pop.Height; $gap = px 8
    if ($UI.Docked -and $UI.DockPos) {               # pinned: same left, same bottom edge; old state.json: top-left as before
        $dy = $UI.DockPos.Y
        if ($null -ne $QS.DockB) { $dwa = [System.Windows.Forms.Screen]::FromPoint($UI.DockPos).WorkingArea; $dy = [Math]::Max($dwa.Top, [Math]::Min([int]$QS.DockB - $h, $dwa.Bottom - $h)) }
        $pop.Location = New-Object System.Drawing.Point $UI.DockPos.X, $dy
    }
    elseif (-not $UI.Docked -or -not $UI.Shown) {
        # the taskbar itself (WorkingArea is unreliable with auto-hide / some DPI setups)
        $tb = $null; try { $rr = New-Object ClaudeTray.Native+RECT; $hTb = [ClaudeTray.Native]::FindWindow('Shell_TrayWnd', $null); if ($hTb -ne [IntPtr]::Zero -and [ClaudeTray.Native]::GetWindowRect($hTb, [ref]$rr)) { $tb = New-Object System.Drawing.Rectangle $rr.L, $rr.T, ($rr.R - $rr.L), ($rr.B - $rr.T) } } catch { }
        if (-not $tb -or -not $tb.IntersectsWith($sb)) { $tb = New-Object System.Drawing.Rectangle $sb.Left, ($sb.Bottom - (px 40)), $sb.Width, (px 40) }
        # stable x: keep the previous anchor unless the icon clearly moved
        if (-not $UI.AnchorX -or [Math]::Abs($cur.X - $UI.AnchorX) -gt (px 120) -or [Math]::Abs($cur.Y - $UI.AnchorY) -gt (px 120)) { $UI.AnchorX = $cur.X; $UI.AnchorY = $cur.Y }
        $ax = $UI.AnchorX; $ay = $UI.AnchorY
        if ($tb.Height -lt $tb.Width) {                   # horizontal taskbar (bottom or top)
            $x = $ax - [int]($w / 2)
            $y = if ($tb.Top -gt $sb.Top + ($sb.Height / 2)) { $tb.Top - $h - $gap } else { $tb.Bottom + $gap }
        } else {                                          # vertical taskbar (left or right)
            $y = $ay - [int]($h / 2)
            $x = if ($tb.Left -gt $sb.Left + ($sb.Width / 2)) { $tb.Left - $w - $gap } else { $tb.Right + $gap }
        }
        $x = [Math]::Max($sb.Left + $gap, [Math]::Min($x, $sb.Right - $w - $gap))
        $y = [Math]::Max($sb.Top + $gap, [Math]::Min($y, $sb.Bottom - $h - $gap))
        $pop.Location = New-Object System.Drawing.Point $x, $y
    }
    if (-not $pop.Visible) { $pop.Opacity = 1.0; $pop.Show() }   # WinForms Show (creates the child controls); WS_EX_NOACTIVATE keeps focus where it is
    [void][ClaudeTray.Native]::SetWindowPos($hPop, [IntPtr](-1), $pop.Left, $pop.Top, $w, $h, 0x0010 -bor 0x0040)
    $UI.LeftAt = $null; $UI.ShownAt = Get-Date; if (-not $UI.ShotAt) { $UI.ShotAt = (Get-Date).AddMilliseconds(500); $UI.ShotWhy = $why }
    $UI.Shown = $true
    Log ("show ({0}) {1}x{2} at {3},{4} cursor {5},{6}" -f $UI.ShowWhy, $pop.Width, $pop.Height, $pop.Left, $pop.Top, $cur.X, $cur.Y) 'DEBUG'
}
function Save-PopShot([string]$why) {          # logs\flyout-last.png: the panel exactly as on screen, for remote debugging (local only)
    if (-not ($Cfg.screenshots -or $Cfg.debugLog) -or -not $pop.Visible) { return }
    try {
        $rc = $pop.Bounds; if ($UI.Sides) { foreach ($sd in @($UI.Sides.Values)) { if ($sd.Open) { $rc = [System.Drawing.Rectangle]::Union($rc, $sd.Form.Bounds) } } }    # panel + open reading windows
        $bmp = New-Object System.Drawing.Bitmap $rc.Width, $rc.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($rc.Left, $rc.Top, 0, 0, $bmp.Size); $g.Dispose()
        $f = Join-Path $LogDir 'flyout-last.png'; $bmp.Save($f, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        Log ("shot ({0}): flyout {1}x{2} at {3},{4} -> logs\flyout-last.png" -f $why, $pop.Width, $pop.Height, $pop.Left, $pop.Top) 'DEBUG'
    } catch { Log "shot: $($_.Exception.Message)" 'WARN' }
}
function Hide-Pop([string]$why = 'left', [bool]$force = $false) {
    if ($UI.Docked -and -not $force) { return }      # a pinned panel only hides on request (icon click); it comes back at its place
    $c0 = [System.Windows.Forms.Cursor]::Position
    Log ("hide ({0}) after {1}s, cursor {2},{3}, pinned={4}" -f $why, [int]((Get-Date) - $UI.ShownAt).TotalSeconds, $c0.X, $c0.Y, $UI.Pinned) 'DEBUG'
    foreach ($sx0 in 'L', 'R') { Hide-SideWin $sx0 }
    $pop.Hide(); $UI.SidePinned = $false; Hide-Side
    $UI.Shown = $false; $UI.Pinned = $false; $UI.Pending = $false; $UI.LeftAt = $null
    Set-Activatable $false
}
function Get-Bridge {                                 # the strip between the icon and the panel counts as "inside"
    $a = $UI.Anchor; $b = $pop.Bounds; $m = px 16
    $x1 = [Math]::Min($a.X - $m, $b.Left); $x2 = [Math]::Max($a.X + $m, $b.Right)
    $y1 = [Math]::Min($a.Y - $m, $b.Top); $y2 = [Math]::Max($a.Y + $m, $b.Bottom)
    return New-Object System.Drawing.Rectangle $x1, $y1, ($x2 - $x1), ($y2 - $y1)
}
function Dist([System.Drawing.Point]$a, [System.Drawing.Point]$b) { return [Math]::Max([Math]::Abs($a.X - $b.X), [Math]::Abs($a.Y - $b.Y)) }
function Test-UsageAlerts {                     # one notification per limit and threshold until it resets
    foreach ($l in @($S.Limits)) {
        foreach ($th in 95, 80) {
            $k2 = "{0}|{1}|{2}" -f $l.Key, $th, $(if ($l.Reset) { ([datetime]$l.Reset).ToString('yyyyMMddHH') } else { '' })
            if ([double]$l.Used -ge $th -and -not $QS.Alerts.ContainsKey($k2)) {
                $QS.Alerts[$k2] = $true; Save-State
                $nm = if ($ShortNames.ContainsKey([string]$l.Key)) { $ShortNames[[string]$l.Key] } else { $l.Label }
                if ($Cfg.usageAlerts) { try { $tray.ShowBalloonTip(5000, 'Claude usage', ("{0} at {1}% - resets in {2}" -f $nm, [Math]::Round([double]$l.Used), (Format-Until $l.Reset)), [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } }
                Log ("usage alert: {0} {1}% (>= {2})" -f $nm, [Math]::Round([double]$l.Used), $th)
                break
            }
        }
    }
}
function Invoke-Poll {
    Apply-Theme
    Update-Usage
    Test-UsageAlerts
    Refresh-Quests $true
    $pollTimer.Interval = [int]$Cfg.pollSeconds * 1000 * $S.Backoff
}

# ---------------------------------------------------------------- WebView2 panel (ui\panel.html): list of chats + THE conversation
# The page only renders; everything it does comes back here as a message (On-WebMsg) and runs through the same functions
# as the classic panel. Classic WinForms panel = fallback (no WebView2 runtime, 32-bit PowerShell, ui=classic, init failure).
$UI.WebUi = $null; $UI.WebReady = $false; $UI.WebOpen = @(); $UI.WebJson = ''; $UI.WebMsg = @{}
$UI.Sides = @{}; $UI.WebBig = @(); $UI.Dl = @{}; $UI.PromptWas = @{}; $UI.MsgCount = @{}; $UI.MsgJ = @{}; $UI.DiagAt = @{}; $UI.BridgeSig = @{}; $UI.BridgeSent = @{}; $UI.Catalog = $null; $UI.CatProj = @{}; $UI.Answered = @{}; $UI.Slash = $null; $UI.SlashKey = $null; $UI.NewChat = $null; $UI.CatKey = $null; $UI.Org = ''; $SideW = 360; $UI.Zoom = $(if ($Cfg.panelZoom) { [double]$Cfg.panelZoom } else { 0.9 })
$UI.DraftRestore = @{}; $UI.WebNav = $false; $UI.WebNc = $false; $UI.WebH = 0; $UI.WebStart = $null; $UI.WebPushes = 0
$StatusRx = '^(Claude (réfléchit|is thinking|thinks|est en train)|Thinking|Réflexion|Réfléchit)\b|^(il y a .*|à l.instant|just now|.* ago|\d+\s*(s|sec|min|h|j|d)\b.*|commande exécutée.*|compétence chargée|skill loaded|tray-quest)$'      # Claude's status labels: never a preview line
function Get-Hex([System.Drawing.Color]$col) { return ('#{0:x2}{1:x2}{2:x2}' -f $col.R, $col.G, $col.B) }
function Init-WebUi {
    if ([string]$Cfg.ui -eq 'classic') { Log 'webui: off (ui=classic)'; return }
    $wlib = Join-Path $Root 'lib\webview2'; $wpage = Join-Path $Root 'ui\panel.html'
    if (-not [Environment]::Is64BitProcess) { Log 'webui: 32-bit PowerShell - classic panel' 'WARN'; return }
    if (-not (Test-Path (Join-Path $wlib 'Microsoft.Web.WebView2.WinForms.dll')) -or -not (Test-Path $wpage)) { Log 'webui: lib\webview2 or ui\panel.html missing - classic panel' 'WARN'; return }
    try {
        # a ZIP downloaded from GitHub marks every file "from the internet": .NET then refuses the DLLs (no admin needed to clear it)
        try { Get-ChildItem $wlib -Recurse -File | Unblock-File -ErrorAction SilentlyContinue } catch { }
        Add-Type -Path (Join-Path $wlib 'Microsoft.Web.WebView2.Core.dll'); Add-Type -Path (Join-Path $wlib 'Microsoft.Web.WebView2.WinForms.dll')
        $warch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
        try { [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::SetLoaderDllFolderPath((Join-Path $wlib $warch)) } catch { }
        $wver = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
        $UI.WebHtml = [IO.File]::ReadAllText($wpage)
        $wvc = New-Object Microsoft.Web.WebView2.WinForms.WebView2
        $wprops = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
        $wprops.UserDataFolder = Join-Path $env:LOCALAPPDATA 'ClaudeTray\webview2-ui'
        $wvc.CreationProperties = $wprops; $wvc.Dock = 'Fill'; $wvc.DefaultBackgroundColor = $T.Bg; $wvc.Visible = $false; $wvc.ZoomFactor = $UI.Zoom
        $pop.Controls.Add($wvc); $wvc.BringToFront()
        $UI.WebUi = $wvc; $UI.WebStart = Get-Date
        $wvc.add_CoreWebView2InitializationCompleted({ param($sender, $e) On-WebInit $sender $e })
        [void]$wvc.EnsureCoreWebView2Async($null)
        Log "webui: WebView2 runtime $wver, initialising"
    } catch { Log "webui: $($_.Exception.Message) - classic panel" 'WARN'; Disable-WebUi }
}
function On-WebInit($wvc, $e) {
    try {
        if (-not $e.IsSuccess) { throw $e.InitializationException }
        $cw = $wvc.CoreWebView2
        $wset = @{ AreDevToolsEnabled = [bool]$Cfg.webDevTools; IsStatusBarEnabled = $false; IsZoomControlEnabled = $false; AreBrowserAcceleratorKeysEnabled = $false; IsGeneralAutofillEnabled = $false; IsPasswordAutosaveEnabled = $false; IsSwipeNavigationEnabled = $false }
        foreach ($wk in $wset.Keys) { try { $cw.Settings.$wk = $wset[$wk] } catch { } }
        try { $cw.Settings.IsNonClientRegionSupportEnabled = $true; $UI.WebNc = $true } catch { $UI.WebNc = $false }     # CSS app-region:drag = native window drag (smooth)
        $cw.add_NewWindowRequested({ param($sender, $e) $e.Handled = $true })
        $cw.add_NavigationStarting({ param($sender, $e) if ($UI.WebNav) { $e.Cancel = $true; Log 'webui: blocked a navigation away from the panel' 'WARN' } })
        $cw.add_NavigationCompleted({ param($sender, $e) $UI.WebNav = $true })
        $cw.add_WebMessageReceived({ param($sender, $e) try { $raw = $e.WebMessageAsJson; On-WebMsg $(if ($raw.Length -gt 400000) { ConvertFrom-BigJson $raw } else { $raw | ConvertFrom-Json }) } catch { Log ("webui msg: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR' } })
        $cw.add_ProcessFailed({ param($sender, $e) Log "webui: page process failed ($($e.ProcessFailedKind)) - classic panel" 'ERR'; Disable-WebUi })
        $cw.NavigateToString($UI.WebHtml)
        Log ("webui: core ready in {0} ms (native drag {1})" -f [int]((Get-Date) - $UI.WebStart).TotalMilliseconds, $UI.WebNc)
    } catch { Log "webui init failed: $($_.Exception.Message) - classic panel" 'WARN'; Disable-WebUi }
}
function ConvertFrom-BigJson([string]$raw) {         # PS 5.1 ConvertFrom-Json chokes on multi-MB strings (pasted images): plain serializer, no length cap
    Add-Type -AssemblyName System.Web.Extensions
    $ser = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $ser.MaxJsonLength = [int]::MaxValue
    return $ser.DeserializeObject($raw)
}
function Get-DownloadsDir {
    try { $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'; if ($v) { $v = [Environment]::ExpandEnvironmentVariables($v); if (Test-Path $v) { return $v } } } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}
function Clear-OldTemp {                             # uploads, downloads in flight and step outputs older than a day (your files can sit in them)
    $lim = (Get-Date).AddDays(-1)
    foreach ($d0 in @((Join-Path $env:TEMP 'claudetray_up'), (Join-Path $env:LOCALAPPDATA 'ClaudeTray\dl'))) {
        if (Test-Path $d0) { foreach ($it in @(Get-ChildItem $d0 -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $lim })) { try { Remove-Item $it.FullName -Recurse -Force -ErrorAction Stop } catch { } } }
    }
    foreach ($it in @(Get-ChildItem $env:TEMP -Filter 'claudetray_*' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $lim })) { try { Remove-Item $it.FullName -Force -ErrorAction Stop } catch { } }
}
function Save-Upload($f) {                            # a file pasted / dropped / picked in the panel -> temp file for the browser's file input
    $nm = ([string]$f.name -replace '[\\/:*?"<>|]', '_').Trim(); if (-not $nm) { $nm = 'file' }
    $dir = Join-Path $env:TEMP ('claudetray_up\' + [guid]::NewGuid().ToString('N').Substring(0, 8)); New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $fp = Join-Path $dir $nm; [IO.File]::WriteAllBytes($fp, [Convert]::FromBase64String([string]$f.b64)); return $fp
}
function Open-Downloaded([string]$path) {             # one click on a file Claude made: open it with its app - never run a program or script (those are shown in their folder)
    $ext = [IO.Path]::GetExtension($path).ToLowerInvariant()
    $risky = '.exe', '.com', '.bat', '.cmd', '.msi', '.msp', '.ps1', '.psm1', '.vbs', '.vbe', '.js', '.jse', '.wsf', '.wsh', '.hta', '.lnk', '.scr', '.pif', '.reg', '.cpl', '.jar', '.msc', '.appx', '.msix', '.appinstaller', '.application', '.inf', '.url', '.scf', '.dll', '.sys', '.iso', '.vhd', '.vhdx'
    if ($risky -contains $ext) { Start-Process explorer.exe "/select,`"$path`""; Log ("dl: {0} file shown in its folder, not run" -f $ext); return }
    try { Start-Process -FilePath $path } catch { Start-Process explorer.exe "/select,`"$path`"" }
}
function Finish-Download($key, [string]$srcFile) {        # file is in our temp folder -> Downloads (no overwrite) -> clipboard if asked
    $dl = $UI.Dl[$key]; if (-not $dl) { return }
    try {
        $dst = Join-Path (Get-DownloadsDir) (Split-Path $srcFile -Leaf); $bn = [IO.Path]::GetFileNameWithoutExtension($dst); $ex = [IO.Path]::GetExtension($dst); $ix = 1
        while (Test-Path $dst) { $dst = Join-Path (Split-Path $dst -Parent) ("{0} ({1}){2}" -f $bn, $ix, $ex); $ix++ }
        Move-Item $srcFile $dst -Force; $dl.Path = $dst; $dl.St = 'saved'
        if ($dl.Mode -eq 'copy') { $sc = New-Object System.Collections.Specialized.StringCollection; [void]$sc.Add($dst); [System.Windows.Forms.Clipboard]::SetFileDropList($sc); $dl.St = 'copied' }
        elseif ($dl.Mode -eq 'open') { Open-Downloaded $dst; $dl.St = 'opened' }
        Log ("dl[{0}]: {1} -> {2} ({3} KB)" -f $key, $dl.St, (Split-Path $dst -Leaf), [int]((Get-Item $dst).Length / 1KB))
        if ($dl.St -ne 'opened') { try { $tray.ShowBalloonTip(3000, $(if ($dl.St -eq 'copied') { 'File copied' } else { 'File saved' }), $(if ($dl.St -eq 'copied') { "$(Split-Path $dst -Leaf) - paste it anywhere (also in Downloads)" } else { "Downloads\$(Split-Path $dst -Leaf)" }), [System.Windows.Forms.ToolTipIcon]::None) } catch { } }
    } catch { $dl.St = 'failed'; Log "dl[$key]: $($_.Exception.Message)" 'WARN' }
    Push-WebState
}
function Poll-ModelMenu {                             # the model menu read / pick from a chat's tab -> the panel's menu, or a balloon
    $mw = $UI.MMWait; if (-not $mw) { return }
    $wr = $Web.Results[$mw.Key]
    if (-not $wr) { if (((Get-Date) - $mw.At).TotalSeconds -gt 20) { $UI.MMWait = $null; Log "model[$($mw.Id)]: no answer from the tab" 'WARN' }; return }
    $Web.Results.Remove($mw.Key); $UI.MMWait = $null
    $o = $null; try { $o = ([string]$wr.Res -replace '^model:', '') | ConvertFrom-Json } catch { }
    Log ("model[{0}] {1}: {2}" -f $mw.Id, $mw.Mode, ([string]$wr.Res).Substring(0, [Math]::Min(1200, ([string]$wr.Res).Length))) 'DEBUG'     # menu labels (UI text): to fix the selectors when claude.ai changes
    if ($mw.Mode -eq 'read') { $UI.ModelMenu = @{ id = [string]$mw.Id; k = [guid]::NewGuid().ToString('N'); models = @($(if ($o) { $o.models })); efforts = @($(if ($o) { $o.efforts })); ok = [bool]($o -and @($o.models).Count) }; if (-not ($o -and @($o.models).Count)) { try { $tray.ShowBalloonTip(4000, 'Model menu not found', 'Change it in the chat itself (Open in Claude).', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } } }
    elseif (-not ($o -and $o.ok)) { try { $tray.ShowBalloonTip(4000, 'Model not changed', 'Change it in the chat itself (Open in Claude).', [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } }
    Push-WebState $true
}
function Poll-Downloads {                             # called by the quest timer: command results + files appearing in the temp folders
    foreach ($key in @($UI.Dl.Keys)) {
        $dl = $UI.Dl[$key]; if ($dl.St -ne 'working') { continue }
        $wr = $Web.Results[$dl.Cmd]
        if ($wr -and -not $dl.Res) { $dl.Res = [string]$wr.Res; $Web.Results.Remove($dl.Cmd); Log ("dl[{0}]: {1}" -f $key, $dl.Res) 'DEBUG'; if ($dl.Res -notmatch '^(saved|clicked):') { $dl.St = 'failed'; Push-WebState; [void]$Web.Cmds.Add(@{ Id = $dl.Id; Kind = 'diag'; Key = 'diag-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); continue } }
        $done = @(Get-ChildItem $dl.Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -notin '.crdownload', '.tmp', '.part' -and $_.Length -gt 0 })
        if ($done.Count) { Finish-Download $key $done[0].FullName }
        elseif (((Get-Date) - $dl.At).TotalSeconds -gt 40) { $dl.St = 'failed'; Log "dl[$key]: nothing arrived after 40 s ($($dl.Res))" 'WARN'; [void]$Web.Cmds.Add(@{ Id = $dl.Id; Kind = 'diag'; Key = 'diag-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Push-WebState }
    }
    foreach ($dk in @($Web.Results.Keys | Where-Object { $_ -like 'diag-*' -or $_ -like 'diagq-*' })) { if ([string]$Web.Results[$dk].Res -ne 'skip') { Log ("web diag (structure only): {0}" -f $Web.Results[$dk].Res) 'DEBUG' }; $Web.Results.Remove($dk) }
}
function Write-Placeholder([string]$nid, [string]$ttl, [string]$sentText) {     # makes a chat visible in the tray before (or without) Claude writing a quest
    $qroot = $QuestRoots[0]; $qd = Join-Path $qroot 'quests'; if (-not (Test-Path $qd)) { New-Item -ItemType Directory -Path $qd -Force | Out-Null }
    $qf = Join-Path $qd ((Get-FileId $nid) + '.json'); if (Test-Path $qf) { return }
    $qph = [ordered]@{ v = 1; id = $nid; title = $ttl; state = 'done'; tracked = $true; summary = $(if ($sentText) { 'New chat - waiting for Claude' } else { 'Tracked from the tray' }); updated = (Get-Iso (Get-Date)); steps = @() }
    [IO.File]::WriteAllText($qf, ($qph | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
    if ($sentText) { $qo = [pscustomobject]@{ id = $nid; updated = $qph.updated; Root = $qroot }; $rs = New-Results $qo; $rs.sent = @([pscustomobject]@{ at = (Get-Iso (Get-Date).AddSeconds(2)); text = $sentText }); Save-Results $qo $rs }
}
function Poll-Bridge {                                  # quests that arrived inside a reply -> quest files (same as if Claude had written them)
    foreach ($bid in @($Web.Chats.Keys)) {
        $bc = $Web.Chats[$bid]; $qt = [string]$bc.Quest; if (-not $qt) { continue }
        if (-not $bc.QuestTag) {                           # an untagged quest-shaped block runs only in a chat where /tray is on (text quoted from elsewhere can't plant steps)
            $bq0 = @($QS.List | Where-Object { [string]$_.id -eq $bid })[0]; $bmsgs = @($bc.Msgs)
            if (-not ($bq0 -and (Test-TraySkill $bq0 $bmsgs)) -and -not @($bmsgs | Where-Object { $_.r -eq 'u' -and ([string]$_.t).TrimStart().StartsWith('/tray') }).Count) { if ($UI.BridgeSig[$bid] -ne "skip|$($qt.Length)") { $UI.BridgeSig[$bid] = "skip|$($qt.Length)"; Log "bridge[$bid]: untagged quest block ignored (no /tray in this chat)" 'WARN' }; continue }
        }
        $hsig = "$($qt.Length)|$($qt.GetHashCode())"; if ($UI.BridgeSig[$bid] -eq $hsig) { continue }
        $UI.BridgeSig[$bid] = $hsig
        try {
            $bq = $qt | ConvertFrom-Json
            if (-not $bq.steps -and [string]$bq.state -ne 'done') { throw 'no steps' }
            $obj = [ordered]@{ v = 1; id = $bid; title = $(if ($bq.title) { [string]$bq.title } else { $tq = @($QS.List | Where-Object { [string]$_.id -eq $bid })[0]; if ($tq) { [string]$tq.title } else { $bid } }); state = $(if ($bq.state) { [string]$bq.state } else { 'act' }); bridge = $true; updated = (Get-Iso (Get-Date)) }
            foreach ($fk in 'answer', 'summary', 'reply') { if ($bq.$fk) { $obj[$fk] = [string]$bq.$fk } }
            $obj.steps = @(@($bq.steps) | Where-Object { $_.kind -in 'cmd', 'ps', 'exe', 'dir', 'file', 'url', 'observe', 'manual' })
            $qroot = $QuestRoots[0]; $qd = Join-Path $qroot 'quests'; if (-not (Test-Path $qd)) { New-Item -ItemType Directory -Path $qd -Force | Out-Null }
            $qf = Join-Path $qd ((Get-FileId $bid) + '.json')
            if (Test-Path $qf) {                               # same round already on disk (e.g. after a restart): keep it, or its results would reset
                try { $ex0 = [IO.File]::ReadAllText($qf) | ConvertFrom-Json; if ($ex0.bridge -and [string]$ex0.state -eq [string]$obj.state -and (ConvertTo-Json -InputObject @($ex0.steps) -Depth 4 -Compress) -eq (ConvertTo-Json -InputObject @($obj.steps) -Depth 4 -Compress)) { continue } } catch { }
            }
            [IO.File]::WriteAllText($qf, (ConvertTo-Json -InputObject $obj -Depth 6 -Compress), (New-Object Text.UTF8Encoding $false))
            Log ("bridge[{0}]: quest from the reply, {1} step(s)" -f $bid, @($obj.steps).Count)
            Refresh-Quests $true
        } catch { Log ("bridge[{0}]: quest block not usable ({1})" -f $bid, $_.Exception.Message) 'WARN' }
    }
}
function Get-BridgeLine($q) {                            # '[tray] 1 ✓ exit 0 | 2 ✓ "yes" | 3 ✗ exit 3: Access denied' for chats that can't read the results file
    if (-not $q.bridge) { return '' }
    $parts = foreach ($bs in @($q.steps)) {
        $rr = @($q.Res.steps) | Where-Object { [int]$_.n -eq [int]$bs.n } | Select-Object -First 1
        if (-not $rr -or $rr.status -in 'pending', 'running') { continue }
        $mk = switch ([string]$rr.status) { 'done' { [char]0x2713 } 'skipped' { [char]0x2013 } default { [char]0x2717 } }
        $p0 = "$($bs.n) $mk"
        if ($null -ne $rr.exit -and [string]$rr.exit -ne '') { $p0 += " exit $($rr.exit)" }
        if ($rr.answer) { $p0 += ' "' + ([string]$rr.answer -replace '\s+', ' ').Trim() + '"' }
        if ($rr.out) {     # failed: last 2 lines; done: the last line (Claude sees the result without a copy / paste)
            $bad = $rr.status -eq 'failed' -or ($rr.exit -and [string]$rr.exit -ne '0'); $ot = (([string]$rr.out -split "`n") | Where-Object { $_.Trim() } | Select-Object -Last $(if ($bad) { 2 } else { 1 })) -join ' / '
            $cap = $(if ($bad) { 160 } else { 120 }); if ($ot.Length -gt $cap) { $ot = $ot.Substring($ot.Length - $cap) }; if ($ot) { $p0 += ": $($ot.Trim())" }
        }
        $p0
    }
    if (-not @($parts).Count) { return '' }
    return "`n`n[tray] " + (@($parts) -join ' | ') + $(if ($Cfg.terse) { ' | style terse' } else { ' | style normal' })
}
$script:DeskLocalCache = $null; $script:DeskLocalAt = [datetime]::MinValue
function Get-DesktopLocal {   # (off unless Settings > Claude Desktop local chats) Claude Desktop Local/Cowork sessions, read-only. Roots: MSIX (%LOCALAPPDATA%\Claude-Data\*), classic (%APPDATA%\Claude), or the running Desktop's --user-data-dir. Layout <root>\local-agent-mode-sessions\<account>\<org>\local_*.json; only the signed-in org ($UI.Org) when its folder exists. Regex-extracts whitelisted top-level fields only (never deserializes email/system prompt/telemetry headers). pn = Local project name from the 'instructions for this project ("<name>")' phrase. Returns a plain array: callers wrap with @().
  if (-not $Caps.Local) { return @() }
  if ($null -ne $script:DeskLocalCache -and ((Get-Date) - $script:DeskLocalAt).TotalSeconds -lt 60) { return $script:DeskLocalCache }
  if (-not $script:DeskLocalRoots) {
    $rs = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Claude-Data') -Directory -ErrorAction SilentlyContinue)) { [void]$rs.Add($d.FullName) }
    [void]$rs.Add((Join-Path $env:APPDATA 'Claude'))
    try { foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop)) { if ([string]$p.CommandLine -match '--user-data-dir=(?:"([^"]+)"|(\S+))') { [void]$rs.Add($(if ($Matches[1]) { $Matches[1] } else { $Matches[2] })) } } } catch { }
    $script:DeskLocalRoots = @($rs | ForEach-Object { Join-Path ([string]$_).TrimEnd('\') 'local-agent-mode-sessions' } | Where-Object { Test-Path $_ } | Sort-Object -Unique)
  }
  $org = ''; try { $org = [string]$UI.Org } catch { }
  $out = New-Object System.Collections.ArrayList; $seen = @{}
  $get = { param($kx) $m = [regex]::Match($tx, '"' + $kx + '"\s*:\s*"((?:[^"\\]|\\.)*)"'); if ($m.Success) { try { [string](('"' + $m.Groups[1].Value + '"') | ConvertFrom-Json) } catch { $m.Groups[1].Value } } else { '' } }
  foreach ($rt in @($script:DeskLocalRoots)) {
    $dirs = @(Get-Item (Join-Path $rt '*\*') -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer })
    if ($org) { $mine = @($dirs | Where-Object { $_.Name -eq $org }); if ($mine.Count) { $dirs = $mine } }
    foreach ($dd in $dirs) { foreach ($f in @(Get-ChildItem (Join-Path $dd.FullName 'local_*.json') -File -ErrorAction SilentlyContinue)) {
      try { $tx = [IO.File]::ReadAllText($f.FullName)
        if ($tx -match '"isArchived"\s*:\s*true') { continue }
        $sid = & $get 'sessionId'; if (-not $sid -or $seen.ContainsKey($sid)) { continue }; $seen[$sid] = 1
        if ($null -eq $script:DeskLocalDir) { $script:DeskLocalDir = @{} }; $script:DeskLocalDir[$sid] = $dd.FullName; if ($null -eq $script:DeskLocalCli) { $script:DeskLocalCli = @{} }; $script:DeskLocalCli[$sid] = (& $get 'cliSessionId')     # org folder, for the session transcript
        $ms = [regex]::Match($tx, '"lastActivityAt"\s*:\s*(\d+)'); $at = if ($ms.Success) { [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms.Groups[1].Value).UtcDateTime.ToString('o') } else { '' }
        $mf = [regex]::Match($tx, '"userSelectedFolders"\s*:\s*\[\s*"((?:[^"\\]|\\.)*)"'); $fd = if ($mf.Success) { Split-Path ($mf.Groups[1].Value -replace '\\\\', '\') -Leaf } else { '' }
        $mp = [regex]::Match($tx, 'instructions for this project \(\\"(.{1,120}?)\\"\)'); $pn = if ($mp.Success) { $mp.Groups[1].Value } else { '' }
        [void]$out.Add([ordered]@{ id = $sid; name = (& $get 'title'); at = $at; sp = (& $get 'spaceId'); f = [string]$fd; pn = [string]$pn })
      } catch { }
    } }
  }
  $script:DeskLocalCache = @($out | Sort-Object { $_.at } -Descending | Select-Object -First 500); $script:DeskLocalAt = Get-Date
  return $script:DeskLocalCache
}
function Poll-NewChat {                               # results of catalog / newchat / rename commands
    if ($UI.CatKey -and $Web.Results[$UI.CatKey]) {
        $r0 = [string]$Web.Results[$UI.CatKey].Res; $Web.Results.Remove($UI.CatKey); $UI.CatKey = $null
        if ($r0 -like 'catalog:*') { try { $cj0 = $r0.Substring(8) | ConvertFrom-Json; $UI.Catalog = [ordered]@{ projects = @($cj0.projects | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name } }); recent = @($cj0.recent | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name; p = [string]$_.p; at = [string]$_.at } }); err = [string]$cj0.perr; byProj = [ordered]@{}; at = (Get-Iso (Get-Date)) }
                $pn0 = @{}; foreach ($pj in @($cj0.projects)) { $pn0[[string]$pj.id] = [string]$pj.name }
                foreach ($rc in @($cj0.recent)) { if ($rc.p -and $pn0.ContainsKey([string]$rc.p)) { $QS.Proj["chat/$($rc.id)"] = $pn0[[string]$rc.p] } elseif (-not $rc.p) { $QS.Proj["chat/$($rc.id)"] = '' } }; Save-State; $UI.Org = [string]$cj0.org; Log ("new chat: {0} project(s), {1} recent chat(s){2}" -f @($cj0.projects).Count, @($cj0.recent).Count, $(if ($cj0.perr) { ' - projects: ' + $cj0.perr } else { '' })) } catch { $UI.Catalog = [ordered]@{ projects = @(); err = 'could not read the projects' } } }
        else { $UI.Catalog = [ordered]@{ projects = @(); err = $r0 }; Log "new chat catalog: $r0" 'WARN' }
        Push-WebState
    }
    if ($UI.SlashKey -and $Web.Results[$UI.SlashKey]) {          # the page's / commands and skills, for the panel's slash list
        $sr = [string]$Web.Results[$UI.SlashKey].Res; $Web.Results.Remove($UI.SlashKey); $UI.SlashKey = $null
        try { $sj = $sr.Substring(6) | ConvertFrom-Json; $its = @($sj.items | Where-Object { $_.n } | ForEach-Object { $nm = ([string]$_.n).Trim(); if (-not $nm.StartsWith('/')) { $nm = '/' + ($nm -replace '\s+', '-').ToLower() }; [ordered]@{ n = $nm; d = [string]$_.d } }); $UI.Slash = @{ At = (Get-Date); Items = $its; Err = [string]$sj.err }; Log ("slash: {0} command(s){1}" -f $its.Count, $(if ($sj.err) { ' - ' + $sj.err } else { '' })) } catch { $UI.Slash = @{ At = (Get-Date); Items = @(); Err = 'unreadable' } }
        Push-WebState
    }
    foreach ($pk0 in @($UI.CatProj.Keys)) {                   # a project opened in the Browse section: its conversations
        $rk1 = $UI.CatProj[$pk0]; $rr = $Web.Results[$rk1]; if (-not $rr) { continue }
        $Web.Results.Remove($rk1); $UI.CatProj.Remove($pk0)
        try { $pj1 = ([string]$rr.Res).Substring(8) | ConvertFrom-Json; if ($UI.Catalog -and $UI.Catalog.byProj -ne $null) { $UI.Catalog.byProj[[string]$pk0] = [ordered]@{ rows = @($pj1.rows | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name; at = [string]$_.at } }); err = [string]$pj1.err } }
              $pnm = @($UI.Catalog.projects | Where-Object { $_.id -eq $pk0 })[0]; if ($pnm) { foreach ($rw in @($pj1.rows)) { $QS.Proj["chat/$($rw.id)"] = [string]$pnm.name } }; Save-State
              Log ("browse: project listed, {0} chat(s){1}" -f @($pj1.rows).Count, $(if ($pj1.err) { ' - ' + $pj1.err } else { '' })) } catch { Log "browse: $($_.Exception.Message)" 'WARN' }
        Push-WebState
    }
    if ($UI.NewChat -and $UI.NewChat.St -eq 'working' -and $Web.Results[$UI.NewChat.Key]) {
        $r1 = [string]$Web.Results[$UI.NewChat.Key].Res; $Web.Results.Remove($UI.NewChat.Key)
        Log "new chat: $r1"
        if ($r1 -match '^created:(chat/[0-9a-f-]{36})') {
            $nid = $Matches[1]; $nc = $UI.NewChat
            try {
                $qroot = $QuestRoots[0]; $qd = Join-Path $qroot 'quests'; if (-not (Test-Path $qd)) { New-Item -ItemType Directory -Path $qd -Force | Out-Null }
                $ttl = if ($nc.Name) { $nc.Name } else { $t0 = ($nc.Text -replace '^/tray\s*', '' -replace '\s+', ' ').Trim(); if ($t0.Length -gt 40) { $t0.Substring(0, 40) + '...' } else { $t0 } }
                $qph = [ordered]@{ v = 1; id = $nid; title = $ttl; state = 'done'; tracked = $true; summary = 'New chat - waiting for Claude'; updated = (Get-Iso (Get-Date)); steps = @() }
                [IO.File]::WriteAllText((Join-Path $qd ((Get-FileId $nid) + '.json')), ($qph | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
                $qo = [pscustomobject]@{ id = $nid; updated = $qph.updated; Root = $qroot }
                $rs = New-Results $qo; $rs.sent = @([pscustomobject]@{ at = (Get-Iso (Get-Date).AddSeconds(2)); text = $nc.Text }); Save-Results $qo $rs
                $UI.WebOpen = @(@($UI.WebOpen) + $nid); $UI.NewChat = [ordered]@{ St = 'ok'; Id = $nid; Key = $nc.Key; Msg = '' }
                if ($nc.Name -and $UI.Org) { $UI.RenameLater = @{ At = (Get-Date).AddSeconds(30); Uuid = ($nid -split '/')[1]; Name = $nc.Name } }      # claude.ai may auto-title after the first reply: apply the name again
                Refresh-Quests $true
            } catch { $UI.NewChat = [ordered]@{ St = 'failed'; Msg = "created, but the tray could not track it: $($_.Exception.Message)"; Key = $UI.NewChat.Key } }
        } else { $UI.NewChat = [ordered]@{ St = 'failed'; Msg = ($r1 -replace '^error:\s*', ''); Key = $UI.NewChat.Key } }
        Push-WebState
    }
    if ($UI.RenameLater -and (Get-Date) -gt $UI.RenameLater.At) { $rl = $UI.RenameLater; $UI.RenameLater = $null; [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'rename'; Uuid = $rl.Uuid; Name = $rl.Name; Org = $UI.Org; Key = 'rn-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) }
    foreach ($rk in @($Web.Results.Keys | Where-Object { $_ -like 'rn-*' })) { $Web.Results.Remove($rk) }
}
function Disable-WebUi {
    $UI.WebReady = $false
    if ($UI.WebUi) { try { $UI.WebUi.Visible = $false; $pop.Controls.Remove($UI.WebUi); $UI.WebUi.Dispose() } catch { } }
    $UI.WebUi = $null; $content.Visible = $true; $pop.Width = px 340; $UI.Built = $false; Request-Build
}
function Test-Unread($q) {                            # Claude replied (finished a turn or rewrote the quest) after you last looked at the chat
    $id = [string]$q.id; $rd = $QS.Read[$id]; if (-not $rd -or -not $rd.At) { return $false }
    $last = $q.Upd; $wc = $Web.Chats[$id]; if ($wc -and $wc.EndAt -and $wc.EndAt -gt $last) { $last = $wc.EndAt }
    return ([bool]($last -and $last -gt $rd.At.AddSeconds(2)) -and -not (Test-ChatWorking $q))
}
function Test-StepsLocked($q) { return [bool](Test-ChatWorking $q) }     # Claude is generating in this chat: no running its (stale) steps meanwhile
function Get-WebQuest($wid) { return @($QS.List | Where-Object { [string]$_.id -eq [string]$wid })[0] }
function Get-WebUiChat($q) {
    $id = [string]$q.id; $wc = Get-WebChat $q; $raw = $Web.Chats[$id]
    $msgs = if ($raw -and $raw.Msgs) { @($raw.Msgs) } else { @() }
    $lsx = if (-not $raw -and $id.StartsWith('local/')) { Get-LocalState $q } else { $null }; if ($lsx) { $msgs = @($lsx.Msgs) }     # Desktop local chat messages from its transcript
    $pend = $UI.Sending[$id]
    if ($pend) {                                  # "sending..." until the chat shows the message (or 20 s)
        $lastU = @($msgs | Where-Object { $_.r -eq 'u' })[-1]
        $pk = (($pend.Text -replace '\s+', ' ').Trim()); if ($pk.Length -gt 20) { $pk = $pk.Substring(0, 20) }
        if (($lastU -and (([string]$lastU.t -replace '\s+', ' ').Trim().StartsWith($pk))) -or ((Get-Date) - $pend.At).TotalSeconds -gt 20) { $UI.Sending.Remove($id); $pend = $null }
    }
    $pv = if ($wc -and $wc.Reply) { [string]$wc.Reply } elseif ($q.answer) { [string]$q.answer } else { [string]$q.summary }
    $pv = [string](@($pv -split "`n" | Where-Object { $_.Trim() -match '[\p{L}\p{N}]' -and $_.Trim() -notmatch $StatusRx }) | Select-Object -Last 1); $pv = $pv -replace '[\p{Co}\p{Cn}\u200B-\u200F\uFEFF]', ''; if ($pv.Length -gt 160) { $pv = $pv.Substring(0, 160) }
    $wst = switch ([string]$q.St) { 'act' { 'act' } 'done' { 'done' } default { 'sent' } }
    if ($wst -eq 'sent' -and $lsx -and ($lsx.St -in 'done', 'idle' -or ($lsx.St -eq 'working' -and (Test-LocalIdleSeen $q $lsx))) -and $q.LastSent -and $lsx.Mt -gt $q.LastSent.ToUniversalTime()) { $wst = 'done' }
    if ($wst -eq 'sent' -and $raw -and -not $raw.Working -and $raw.EndAt -and $q.LastSent -and $raw.EndAt -gt $q.LastSent) { $wst = 'done' }     # Claude answered without new steps
    $sbr = if (@($q.steps).Count) { Get-StepsBefore $q $msgs $raw } else { @{ Sb = -1; Ans = $false } }; $sb = [int]$sbr.Sb
    if ($wst -eq 'act' -and $sbr.Ans) { $wst = 'done' }; $UI.Answered[$id] = [bool]$sbr.Ans                       # you already answered (maybe in the app): the steps are history
    $ch = [ordered]@{ id = $id; trayCmd = $(if ($id.StartsWith('local/')) { $(if ($Cfg.localTrayCommand) { [string]$Cfg.localTrayCommand } else { '/tray' }) } else { '/tray' }); title = $(if ($QS.Titles[$id]) { [string]$QS.Titles[$id] } elseif ($id.StartsWith('local/')) { Get-LocalTitle $q } else { [string]$q.title }); st = $wst; working = [bool]((Test-ChatWorking $q) -or $UI.Queue.ContainsKey($id)); bell = -not ($QS.Bells.ContainsKey($id) -and -not $QS.Bells[$id])
                      age = (Format-Age $q.Upd); preview = $pv.Trim(); web = [bool]$wc; sending = $(if ($pend) { [string]$pend.Text } else { $null })
                      unread = (Test-Unread $q); readKey = $(if ($QS.Read[$id]) { [string]$QS.Read[$id].K } else { $null })
                      act = $(if ($wc -and $wc.Working) { [string]$wc.Act } else { '' }); prompts = @($(if ($wc) { $wc.Prompts } else { @() })); q = $(if ($wc -and $wc.Q) { $wc.Q } elseif ($lq = Get-LocalQ $q) { $lq } else { $null }); askRes = $(if ($script:AskRes -and $script:AskRes[$id] -and ((Get-Date) - $script:AskRes[$id].At).TotalSeconds -lt 12) { @{ l = [string]$script:AskRes[$id].l; ok = [bool]$script:AskRes[$id].ok; k = [string]$script:AskRes[$id].k } } else { $null }); model = $(if ($wc) { [string]$wc.Model } elseif ($lsx) { [string]$lsx.Model } else { '' }); effort = $(if ($lsx) { [string]$lsx.Effort } else { '' }); retry = [bool]($wc -and $wc.Retry); pin = [bool]$QS.Pins.Contains($id); bridge = [bool]$q.bridge; skill = (Test-TraySkill $q $msgs); stepsBefore = $sb
                      ts = [long](([DateTimeOffset]$q.Upd).ToUnixTimeMilliseconds()); kind = $(if ($id -like 'code/*') { 'code' } else { 'chat' }); proj = $(if ($id -like 'code/*') { 'Claude Code' } elseif ($QS.Proj.ContainsKey($id)) { [string]$QS.Proj[$id] } else { $null }) }
    if ($UI.Drafts.ContainsKey($id)) { $ov = if ($UI.DraftRestore.ContainsKey($id)) { [int]$UI.DraftRestore[$id].V } else { 0 }; $UI.DraftRestore[$id] = @{ T = [string]$UI.Drafts[$id]; V = $ov + 1 }; $UI.Drafts.Remove($id) }
    if ($UI.DraftRestore.ContainsKey($id)) { $ch.draft = $UI.DraftRestore[$id].T; $ch.draftV = $UI.DraftRestore[$id].V }
    if ($UI.WebOpen -contains $id) {
        $lim = [Math]::Max(20, [int]$(if ($Web.MsgN.ContainsKey($id)) { $Web.MsgN[$id] } else { 20 }) + 5); if ($msgs.Count -gt $lim) { $cut = $msgs.Count - $lim; $msgs = @($msgs[$cut..($msgs.Count - 1)]); if ($ch.stepsBefore -ge 0) { $ch.stepsBefore = $(if ($ch.stepsBefore - $cut -ge 0) { $ch.stepsBefore - $cut } else { -2 }) } }    # only what you loaded (-2: the steps are further up)
        $msig = "$($msgs.Count)|$(if ($msgs.Count) { "$($msgs[0].x)/$($msgs[-1].x)" })|" + (($msgs | ForEach-Object { ([string]$_.t).Length + ([string]$_.h).Length } | Measure-Object -Sum).Sum)
        $mc = $UI.WebMsg[$id]
        if (-not $mc -or $mc.Sig -ne $msig) {
            # one JSON string per message, cached: while Claude streams only the last one is serialised again (PS 5.1 is slow on big strings)
            if ($UI.MsgJ.Count -gt 3000) { $UI.MsgJ.Clear() }
            $parts = foreach ($mm in $msgs) {
                $mk = "{0}|{1}|{2}|{3}|{4}" -f $mm.r, $mm.x, ([string]$mm.t).Length, ([string]$mm.h).Length, ([string]$mm.t).GetHashCode()
                $pj = $UI.MsgJ[$mk]
                if (-not $pj) { $o2 = [ordered]@{ r = [string]$mm.r; t = [string]$mm.t; x = [int]$mm.x; h = $(if ($mm.h) { [string]$mm.h } else { $null }) }; if ($mm.at) { $o2.at = [long]$mm.at }; if ($mm.f) { $o2.f = @($mm.f | ForEach-Object { [string]$_ }) }; $pj = ConvertTo-Json -InputObject $o2 -Compress -Depth 3; $UI.MsgJ[$mk] = $pj }
                $pj
            }
            $mc = @{ Sig = $msig; Json = '[' + (@($parts) -join ',') + ']' }; $UI.WebMsg[$id] = $mc
        }
        $ch.msgs = "__MSGS_$($UI.WebMsgIdx.Count)__"; $UI.WebMsgIdx += $mc.Json
        $ch.answer = if ($q.answer) { [string]$q.answer } else { [string]$q.summary }
        $ch.gist = [string]$q.answer
        $ch.lastSent = [string](@($q.Res.sent) | Select-Object -Last 1).text
        $dls = [ordered]@{}; foreach ($dk in @($UI.Dl.Keys | Where-Object { $_ -like "$id|*" })) { $dls[($dk -split '\|')[1] + '#' + ($dk -split '\|')[2]] = $UI.Dl[$dk].St }; $ch.dl = $dls
        $ch.locked = (Test-StepsLocked $q)
        $ch.steps = @(foreach ($qs0 in @($q.steps)) {
            $rec = @($q.Res.steps) | Where-Object { [int]$_.n -eq [int]$qs0.n } | Select-Object -First 1
            [ordered]@{ n = [int]$qs0.n; options = @(@($qs0.options) | Where-Object { $_ } | Select-Object -First 4 | ForEach-Object { [string]$_ }); kind = [string]$qs0.kind; label = [string]$qs0.label; cmd = [string]$qs0.cmd; path = [string]$qs0.path; url = [string]$qs0.url; admin = [bool]$qs0.admin
                        status = $(if ($rec) { [string]$rec.status } else { 'pending' }); exit = $(if ($rec) { $rec.exit } else { $null }); answer = $(if ($rec) { [string]$rec.answer } else { '' }); running = $QS.Running.ContainsKey("$id#$($qs0.n)") }
        })
    }
    # every step done -> suggest the reply ("check"), also for collapsed cards (the one-line box sends it on Enter)
    if ($q.St -eq 'act' -and @($q.steps).Count) {
        $left = @(foreach ($qs1 in @($q.steps)) { $rec1 = @($q.Res.steps) | Where-Object { [int]$_.n -eq [int]$qs1.n } | Select-Object -First 1; if (-not $rec1 -or [string]$rec1.status -notin 'done', 'skipped') { 1 } }).Count
        if (-not $left) { $ch.suggest = $(if ($q.reply) { [string]$q.reply } else { 'check' }); $ch.suggestKey = [string]$q.updated }
    }
    return $ch
}
function Get-StepsBefore($q, $msgs, $raw) {          # where this round's steps go: index of the first message you sent after them (-1 = none yet: they're current)
    # also returns whether you answered at all, from the tab's last message when the conversation isn't loaded (collapsed chat)
    $id = [string]$q.id; $norm = { param($txt1) $t2 = ([string]$txt1 -replace '\s+', ' ').Trim(); if ($t2.Length -gt 60) { $t2.Substring(0, 60) } else { $t2 } }
    $um = @(for ($i = 0; $i -lt $msgs.Count; $i++) { if ($msgs[$i].r -eq 'u') { $i } })
    $qms = [long](([DateTimeOffset]$q.Upd).ToUnixTimeMilliseconds())
    $lu = if ($raw -and $raw.Ok) { & $norm $raw.LastUser } else { '' }
    $an = $QS.Anchor[$id]
    if ($um.Count -and @($um | Where-Object { $msgs[$_].at }).Count -eq $um.Count) {      # every message has its time: exact...
        if (-not $an -or $an.U -ne [string]$q.updated) { $QS.Anchor[$id] = @{ U = [string]$q.updated; T = (& $norm $msgs[$um[-1]].t); L = $lu }; Save-State; $an = $QS.Anchor[$id] }
        $ai = -1; if ($an.T) { for ($ki = $um.Count - 1; $ki -ge 0; $ki--) { if ((& $norm $msgs[$um[$ki]].t) -eq $an.T) { $ai = $um[$ki]; break } } }
        # ...but never the message you had sent when the steps arrived (a message's time can be read late: it hid fresh steps once)
        foreach ($i in $um) { if ($i -gt $ai -and [long]$msgs[$i].at -gt $qms + 5000) { return @{ Sb = $i; Ans = $true } } }; return @{ Sb = -1; Ans = $false }
    }
    if (-not $an -or $an.U -ne [string]$q.updated) {                 # first sight of this quest version: remember your last message
        if (-not $um.Count -and -not $lu) { return @{ Sb = -1; Ans = $false } }
        $QS.Anchor[$id] = @{ U = [string]$q.updated; T = $(if ($um.Count) { & $norm $msgs[$um[-1]].t } else { '' }); L = $lu }; Save-State; return @{ Sb = -1; Ans = $false }
    }
    if (-not $an.T -and $um.Count) { $an.T = & $norm $msgs[$um[-1]].t; if (-not $an.L) { $an.L = $lu }; Save-State }
    if (-not $an.L -and $lu) { $an.L = $lu; Save-State }
    if ($um.Count -and $an.T) {
        $last = -1; for ($ki = $um.Count - 1; $ki -ge 0; $ki--) { if ((& $norm $msgs[$um[$ki]].t) -eq $an.T) { $last = $ki; break } }
        if ($last -ge 0 -and $last + 1 -lt $um.Count) { for ($ni = $last + 1; $ni -lt $um.Count; $ni++) { $uix = $um[$ni]; if (-not $msgs[$uix].at -or [long]$msgs[$uix].at -gt $qms + 5000) { return @{ Sb = $uix; Ans = $true } } }; return @{ Sb = -1; Ans = $false } }     # a message whose time says it was sent before the steps is never the answer to them
        if ($last -ge 0) { return @{ Sb = -1; Ans = $false } }
    }
    return @{ Sb = -1; Ans = [bool]($lu -and $an.L -and $lu -ne $an.L) }
}
function Test-TraySkill($q, $msgs) {                 # /tray is on in this chat: Claude wrote a quest (not our placeholder) or a message started with /tray
    if ($q.bridge -or -not ($q.tracked -or [string]$q.summary -in 'Tracked from the tray', 'New chat - waiting for Claude')) { return $true }
    foreach ($sx in @($q.Res.sent)) { if ([string]$sx.text -match '^\s*/(?:[\w-]+:)?tray\b') { return $true } }     # also '/<plugin>:tray' (Claude Desktop names skills by plugin)
    foreach ($mx in @($msgs)) { if ($mx.r -eq 'u' -and [string]$mx.t -match '^\s*/(?:[\w-]+:)?tray\b') { return $true } }
    return $false
}
function Get-WebHint {                              # why conversations can't show (shown in an empty conversation)
    if (-not $webEnabled) { return "Live chats are off: settings > Sign in to claude.ai (once)." }
    $bad = @($Web.Chats.Values | Where-Object { -not $_.Ok -and $_.FirstAt -and ((Get-Date) - $_.FirstAt).TotalSeconds -gt 30 })
    if ($bad.Count -and -not @($Web.Chats.Values | Where-Object { $_.Ok }).Count) { return "The tray's browser isn't signed in to claude.ai: settings > Sign in to claude.ai." }
    if ($Web.Err) { return "Live chats: $($Web.Err)" }
    return ''
}
function Push-WebState([bool]$force = $false) {
    if (-not $UI.WebReady -or -not $UI.WebUi) { return }
    try {
        $wa = [System.Windows.Forms.Screen]::FromControl($pop).WorkingArea
        $thm = [ordered]@{}; foreach ($tk in 'Bg', 'Card', 'Tx', 'Mu', 'Ln', 'Acc', 'Act', 'Pur', 'Ok') { $thm[$tk.ToLower()] = Get-Hex $T[$tk] }
        $thm.field = Get-Hex $T.Card; $thm.bub = Get-Hex $(if ($UI.Light) { C 240 238 230 } else { C 26 26 24 })
        $us = @(foreach ($l in @($S.Limits)) {
            $nm = if ($l.Key -and $ShortNames.ContainsKey([string]$l.Key)) { $ShortNames[[string]$l.Key] } else { [string]$l.Label }
            [ordered]@{ label = (Get-Culture).TextInfo.ToTitleCase([string]$nm); used = [Math]::Round([double]$l.Used, 1); at = (Format-ResetAt $l.Reset); left = (Format-Left $l.Reset)
                        tip = ("{0}: {1}% used - resets {2}" -f $l.Label, [Math]::Round([double]$l.Used), $(if ($l.Reset) { ([datetime]$l.Reset).ToString('dddd HH:mm', $EN) } else { '?' })) }
        })
        $werr = if (-not @($S.Limits).Count) { if ($S.Error) { [string]$S.Error } else { 'usage: no data yet' } } elseif ($S.Error) { [string]$S.Error } else { '' }
        $vis = @($QS.List | Where-Object { $_.Visible })
        $UI.WebMsgIdx = @()
        $state = [ordered]@{ type = 'state'; theme = $thm; nc = [bool]$UI.WebNc; docked = [bool]$UI.Docked; maxH = [int]($wa.Height * 0.62 / ($k * $UI.Zoom)); shown = [bool]($UI.Shown -or $UI.Docked); expanded = @($UI.WebOpen); big = @($UI.WebBig)
                             mainW = (Get-PanelW); sides = $(Get-WebSidesState $wa)
                             err = $werr; usage = $us; catalog = $UI.Catalog; desklocal = @(if (($QS.Layout -and $QS.Layout.browse) -or @($QS.List | Where-Object { ([string]$_.id).StartsWith('local/') }).Count) { try { Get-DesktopLocal } catch { } }); deskSeen = [bool](@($script:DeskLocalCache).Count -or @($QS.List | Where-Object { ([string]$_.id).StartsWith('local/') }).Count); deskOnly = @($QS.DeskOnly.Keys); seen = $(try { $sm = @{}; foreach ($sq in @($QS.List)) { $sl = Get-LastActivity $sq; $sr = $(if ($QS.Read[[string]$sq.id]) { $QS.Read[[string]$sq.id].At } else { $null }); $sv = $(if ($sr -is [datetime]) { $sr } elseif ($sq.LastSent -is [datetime]) { $sq.LastSent } else { $sq.Upd }); if ($sv) { $sm[[string]$sq.id] = ([datetime]$sv).ToUniversalTime().ToString('o') } }; $sm } catch { @{} }); newchat = $(if ($UI.NewChat) { [ordered]@{ st = $UI.NewChat.St; id = [string]$UI.NewChat.Id; msg = [string]$UI.NewChat.Msg; key = [string]$UI.NewChat.Key } } else { $null }); hiddenAll = (@($QS.List).Count -gt 0)     # seen = when you last saw each tracked chat (Browse dot)
                             hidden = @(foreach ($qh in @($QS.List | Where-Object { -not $_.Visible -and -not ([string]$_.id).StartsWith('local/') -or (-not $_.Visible -and $Caps.Local) } | Select-Object -First 30)) { [ordered]@{ id = [string]$qh.id; title = [string]$qh.title; age = (Format-Age $qh.Upd); at = ([datetime]$qh.Upd).ToUniversalTime().ToString('o') } })
                             pins = @($QS.Pins.Keys); webHint = (Get-WebHint); layout = $QS.Layout; sideOn = [bool]$Cfg.sideWindows; fixedH = [int]$Cfg.panelHeight
                             modelMenu = $UI.ModelMenu; update = @{ st = [string]$UI.Upd.St; cur = $Version; new = [string]$UI.Upd.New; how = [string]$UI.Upd.How; msg = [string]$UI.Upd.Msg }; caps = [ordered]@{ renameWeb = [bool]($webEnabled -and $UI.Org); renameLocal = $true; park = [bool]$Caps.Park; ghost = [bool]$Caps.Ghost }; settings = [ordered]@{ park = [bool]$Cfg.parkDesktop; ghost = [bool]$Cfg.ghostDesktop; hideAfter = (Get-HideAfterMin); theme = $(if ($Cfg.theme) { [string]$Cfg.theme } else { 'auto' }); terse = [bool]$Cfg.terse; compact = [bool]$Cfg.compact; debug = [bool]$Cfg.debugLog; start = $(if (-not (Test-Path $LnkBoot)) { 'manual' } elseif ([string]$Cfg.startWith -eq 'claude') { 'claude' } else { 'windows' }); sized = [bool]($Cfg.panelWidth -or $Cfg.panelHeight); version = $Version; light = [bool]$UI.Light; signedIn = [bool]($webEnabled -and @($Web.Chats.Values | Where-Object { $_.Ok }).Count) }; slash = $(if ($UI.Slash) { [ordered]@{ items = @($UI.Slash.Items); err = [string]$UI.Slash.Err } } else { $null }); chats = @(foreach ($q in $vis) { Get-WebUiChat $q }) }
        $json = ConvertTo-Json -InputObject $state -Depth 6 -Compress
        for ($mi2 = 0; $mi2 -lt $UI.WebMsgIdx.Count; $mi2++) { $json = $json.Replace("`"__MSGS_$($mi2)__`"", $UI.WebMsgIdx[$mi2]) }
        if ($force -or $json -ne $UI.WebJson) {
            $UI.WebJson = $json; $UI.WebPushes++
            $UI.WebUi.CoreWebView2.PostWebMessageAsJson($json)
        }
    } catch { Log ("webui push: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR' }
}
function Fit-WebPop {                                # page height (CSS px) -> panel height; bottom edge fixed (attached or pinned), only the top moves, never off-screen
    if (-not $UI.WebH) { return }
    $wa = [System.Windows.Forms.Screen]::FromControl($pop).WorkingArea
    if ($UI.Rsz -or $UI.Drag -or $UI.MoveFrom) { return }      # you're resizing or moving it (re-fitted on release)
    $nh = if ([int]$Cfg.panelHeight -gt 0 -and (@($UI.WebOpen).Count -or -not $UI.FoldAll)) {     # the height you set stays when you close a chat; only 'collapse all' shrinks the panel
        [Math]::Min((px ([int]$Cfg.panelHeight * $UI.Zoom)), [int]($wa.Height * 0.95)) } else { [Math]::Min([Math]::Max((px 60), [int]([double]$UI.WebH * $k * $UI.Zoom) + 2), [int]($wa.Height * 0.7)) }
    if ($nh -eq $pop.Height -and $pop.Bottom -le $wa.Bottom -and $pop.Top -ge $wa.Top) { return }
    if ($UI.Docked -and $null -eq $QS.DockB) { $QS.DockB = $pop.Bottom }      # old state.json had no bottom
    $bot = if ($UI.Docked) { [int]$QS.DockB } else { $pop.Bottom }           # pinned: the remembered bottom, so a clamp below never drifts it
    $top = $bot - $nh
    if ($top + $nh -gt $wa.Bottom) { $top = $wa.Bottom - $nh }
    if ($top -lt $wa.Top) { $top = $wa.Top }
    if ($pop.Visible) { $pop.SetBounds($pop.Left, $top, $pop.Width, $nh) } else { $pop.Height = $nh; $pop.Top = $top }
    if ($UI.Docked) { $UI.DockPos = $pop.Location; $QS.Dock = @($pop.Left, $pop.Top) }      # in memory; DockB kept as the anchor
}
# reading columns: separate small windows next to the panel (the panel never resizes -> no jump)
function New-SideWin([string]$X) {
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'; $f.BackColor = $T.Bg; $f.AutoScaleMode = 'None'
    $f.Padding = New-Object System.Windows.Forms.Padding 1; $f.Width = px $SideW; $f.Height = px 300
    $null = $f.Handle; $hf = $f.Handle
    [void][ClaudeTray.Native]::SetWindowLong($hf, -20, ([ClaudeTray.Native]::GetWindowLong($hf, -20) -bor 0x08000088))
    try { $scorner = 2; [void][ClaudeTray.Native]::DwmSetWindowAttribute($hf, 33, [ref]$scorner, 4) } catch { }
    $f.add_Paint({ param($sender, $e) $pen = New-Object System.Drawing.Pen $T.Ln; $e.Graphics.DrawRectangle($pen, 0, 0, $sender.Width - 1, $sender.Height - 1); $pen.Dispose() })
    $wvs = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $sprops = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties; $sprops.UserDataFolder = Join-Path $env:LOCALAPPDATA 'ClaudeTray\webview2-ui'
    $wvs.CreationProperties = $sprops; $wvs.Dock = 'Fill'; $wvs.DefaultBackgroundColor = $T.Bg; $wvs.Tag = $X; $wvs.ZoomFactor = $UI.Zoom
    $f.Controls.Add($wvs)
    $UI.Sides[$X] = @{ X = $X; Form = $f; Hwnd = $hf; Wv = $wvs; Ready = $false; Open = $false; Nav = $false; Pend = $null }
    $wvs.add_CoreWebView2InitializationCompleted({ param($sender, $e) On-SideInit $sender $e })
    [void]$wvs.EnsureCoreWebView2Async($null)
}
function On-SideInit($wvs, $e) {
    $X = [string]$wvs.Tag
    try {
        if (-not $e.IsSuccess) { throw $e.InitializationException }
        $cw = $wvs.CoreWebView2
        foreach ($wk in 'IsStatusBarEnabled', 'IsZoomControlEnabled', 'AreBrowserAcceleratorKeysEnabled', 'IsGeneralAutofillEnabled', 'IsPasswordAutosaveEnabled', 'IsSwipeNavigationEnabled') { try { $cw.Settings.$wk = $false } catch { } }
        try { $cw.Settings.AreDevToolsEnabled = [bool]$Cfg.webDevTools } catch { }
        $cw.add_NewWindowRequested({ param($sender, $e) $e.Handled = $true })
        $cw.add_NavigationStarting({ param($sender, $e) $sd0 = $UI.Sides[[string](Get-SideX $sender)]; if ($sd0 -and $sd0.Nav) { $e.Cancel = $true } })
        $cw.add_NavigationCompleted({ param($sender, $e) $sd0 = $UI.Sides[[string](Get-SideX $sender)]; if ($sd0) { $sd0.Nav = $true } })
        $cw.add_WebMessageReceived({ param($sender, $e) try { On-SideMsg ([string](Get-SideX $sender)) ($e.WebMessageAsJson | ConvertFrom-Json) } catch { Log ("side msg: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR' } })
        $cw.NavigateToString([IO.File]::ReadAllText((Join-Path $Root 'ui\side.html')))
    } catch { Log "side $X init failed: $($_.Exception.Message)" 'WARN'; $UI.Sides.Remove($X) }
}
function Get-SideX($core) { foreach ($sd in @($UI.Sides.Values)) { try { if ([object]::ReferenceEquals($sd.Wv.CoreWebView2, $core) -or $sd.Wv.CoreWebView2 -eq $core) { return $sd.X } } catch { } }; return $null }
function Get-SideTheme { $thm = [ordered]@{}; foreach ($tk in 'Bg', 'Card', 'Tx', 'Mu', 'Ln', 'Acc', 'Act') { $thm[$tk.ToLower()] = Get-Hex $T[$tk] }; return $thm }
function Send-Side($sd, $obj) { try { $sd.Wv.CoreWebView2.PostWebMessageAsJson((ConvertTo-Json -InputObject $obj -Depth 4 -Compress)) } catch { Log "side post: $($_.Exception.Message)" 'WARN' } }
function On-SideMsg([string]$X, $m) {
    $sd = $UI.Sides[$X]; if (-not $sd) { return }
    switch ([string]$m.type) {
        'ready' { $sd.Ready = $true; Send-Side $sd @{ type = 'theme'; theme = (Get-SideTheme) }; if ($sd.Pend) { Send-Side $sd $sd.Pend }; Log "webui: side window $X ready" 'DEBUG' }
        'hover' { Send-WebEv $X 'hover' ([bool]$m.on) }
        'pin' { $sd.Pinned = [bool]$m.on; Send-WebEv $X 'pin' ([bool]$m.on) }
        'close' { Hide-SideWin $X; Send-WebEv $X 'close' $false }
        'copy' { if ($m.text) { Set-Clipboard -Value ([string]$m.text) } }
        'openurl' { $u1 = [string]$m.url; if ($u1 -match '^https?://[^\s"<>]+$') { Start-Process $u1; Log 'open link (side window)' } }
        'zoom' { Set-WebZoom ([int]$m.d) }
        'focus' { try { [void][ClaudeTray.Native]::SetWindowLong($sd.Hwnd, -20, ([ClaudeTray.Native]::GetWindowLong($sd.Hwnd, -20) -band (-bnot 0x08000000))); [void][ClaudeTray.Native]::SetForegroundWindow($sd.Hwnd); $sd.Form.Activate(); $sd.Wv.Focus() } catch { } }    # clicked: take the keyboard (select + Ctrl+C)
        'shown' { Log ("webui: side window {0} shows {1} chars of text" -f $X, [int]$m.len) 'DEBUG'; $UI.SideShotAt = (Get-Date).AddMilliseconds(400); $UI.SideShotX = $X }
    }
}
function Save-SideShot([string]$X) {                  # logs\flyout-side.png: the reading window as on screen (debug, local only)
    $sd = $UI.Sides[$X]; if (-not $Cfg.screenshots -or -not $sd -or -not $sd.Open) { return }
    try { $rc = $sd.Form.Bounds; $bmp = New-Object System.Drawing.Bitmap $rc.Width, $rc.Height; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($rc.Left, $rc.Top, 0, 0, $bmp.Size); $g.Dispose(); $bmp.Save((Join-Path $LogDir 'flyout-side.png'), [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose() } catch { }
}
function Send-WebEv([string]$X, [string]$ev, [bool]$on) { try { $UI.WebUi.CoreWebView2.PostWebMessageAsJson((ConvertTo-Json -InputObject ([ordered]@{ type = 'colev'; x = $X; ev = $ev; on = $on }) -Compress)) } catch { } }
function Get-SideRect([string]$X) {
    $w = px ($SideW * $UI.Zoom); $gap = px 4
    $x0 = if ($X -eq 'L') { $pop.Left - $w - $gap } else { $pop.Right + $gap }
    return New-Object System.Drawing.Rectangle $x0, $pop.Top, $w, $pop.Height
}
function Get-WebSidesState($wa) {
    $rl = Get-SideRect 'L'; $rr = Get-SideRect 'R'
    return [ordered]@{ l = [bool]($UI.Sides['L'] -and $UI.Sides['L'].Open); r = [bool]($UI.Sides['R'] -and $UI.Sides['R'].Open); roomL = ($rl.Left -ge $wa.Left); roomR = ($rr.Right -le $wa.Right) }
}
function Place-SideWins {
    foreach ($X in 'L', 'R') { $sd = $UI.Sides[$X]; if ($sd -and $sd.Open) { $r0 = Get-SideRect $X; [void][ClaudeTray.Native]::SetWindowPos($sd.Hwnd, [IntPtr](-1), $r0.Left, $r0.Top, $r0.Width, $r0.Height, 0x0010 -bor 0x0040) } }
}
function Show-SideWin([string]$X, $m) {
    if (-not $UI.Sides[$X]) { New-SideWin $X }
    $sd = $UI.Sides[$X]; if (-not $sd) { return }
    $sd.Pend = [ordered]@{ type = 'show'; key = [string]$m.key; title = [string]$m.title; html = [string]$m.html; pinned = [bool]$sd.Pinned }
    if ($sd.Ready) { Send-Side $sd $sd.Pend }
    if (-not $sd.Open) {
        $sd.Open = $true; $r0 = Get-SideRect $X
        $sd.Form.Bounds = $r0
        if (-not $sd.Form.Visible) { $sd.Form.Show() }
        [void][ClaudeTray.Native]::SetWindowPos($sd.Hwnd, [IntPtr](-1), $r0.Left, $r0.Top, $r0.Width, $r0.Height, 0x0010 -bor 0x0040)
        Log "webui: side window $X open" 'DEBUG'; $UI.ShotAt = (Get-Date).AddMilliseconds(600); $UI.ShotWhy = 'web-side'
    }
}
function Hide-SideWin([string]$X) { $sd = $UI.Sides[$X]; if ($sd -and $sd.Open) { $sd.Open = $false; $sd.Pinned = $false; try { $sd.Form.Hide(); [void][ClaudeTray.Native]::SetWindowLong($sd.Hwnd, -20, ([ClaudeTray.Native]::GetWindowLong($sd.Hwnd, -20) -bor 0x08000000)) } catch { }; Log "webui: side window $X closed" 'DEBUG' } }
function Test-InSideWins($pt) { foreach ($sd in @($UI.Sides.Values)) { if ($sd.Open -and $sd.Form.Bounds.Contains($pt)) { return $true } }; return $false }
function Set-WebZoom([int]$d) {                       # Ctrl+wheel over the panel: whole UI bigger/smaller, remembered
    $z = [Math]::Round([Math]::Min(1.4, [Math]::Max(0.6, $UI.Zoom + 0.05 * $d)), 2); if ($z -eq $UI.Zoom) { return }
    $UI.Zoom = $z; Save-CfgKey 'panelZoom' $z
    try { $UI.WebUi.ZoomFactor = $z } catch { }; foreach ($sd in @($UI.Sides.Values)) { try { $sd.Wv.ZoomFactor = $z } catch { } }
    $nw = px ((Get-PanelW) * $z); $pop.SetBounds($pop.Right - $nw, $pop.Top, $nw, $pop.Height); Fit-WebPop     # the height follows the zoom too
    $UI.WebJson = ''; Push-WebState; Place-SideWins
    Log ("webui: zoom {0:P0}" -f $z) 'DEBUG'
}
function Get-PanelW { if ($Cfg.panelWidth) { return [int]$Cfg.panelWidth } else { return 340 } }
function Set-DockHere {
    if (-not $UI.Docked) { $UI.Docked = $true; Pin-Pop }
    Set-DockMemo; Save-State
    Log ("panel dragged to {0},{1} (docked)" -f $pop.Left, $pop.Top) 'DEBUG'; Push-WebState
}
function On-WebMsg($m) {
    $mt = [string]$m.type
    if ($mt -notin 'focus', 'size', 'drag', 'log', 'copy', 'rsz') { Log ("webui: {0}{1}{2}" -f $mt, $(if ($m.id) { " $($m.id)" } else { '' }), $(if ($null -ne $m.n) { "#$($m.n)" } else { '' })) 'DEBUG' }
    $q = if ($m.id) { Get-WebQuest $m.id } else { $null }
    $wstep = if ($q -and $null -ne $m.n) { @($q.steps | Where-Object { [int]$_.n -eq [int]$m.n })[0] } else { $null }
    if ($m.id -and ([string]$m.id).StartsWith('local/') -and $mt -in 'qpick', 'qother', 'qskip') { if ($q) { Invoke-LocalAsk $q $mt $m }; return }     # answer the Desktop question card through UI Automation
    if ($m.id -and ([string]$m.id).StartsWith('local/') -and $mt -in 'more', 'qpick', 'qnext', 'qother', 'qprev', 'qskip', 'qsub', 'press', 'reload', 'retry', 'dl') { Log "webui: $mt ignored for a Desktop local chat (no claude.ai tab)" 'DEBUG'; return }     # would sit in Web.Cmds forever (never consumed) and keep the browser loop busy
    switch ($mt) {
        'ready' {
            $first = -not $UI.WebReady
            $UI.WebReady = $true; $content.Visible = $false; $UI.WebUi.Visible = $true; $UI.WebUi.BringToFront()
            $pop.Width = px ((Get-PanelW) * $UI.Zoom); try { $UI.WebUi.ZoomFactor = $UI.Zoom } catch { }
            Log ("webui: panel ready ({0}, {1} ms after start)" -f $(if ($first) { 'first load' } else { 'reloaded' }), [int]((Get-Date) - $UI.WebStart).TotalMilliseconds)
            $UI.WebJson = ''; Push-WebState $true
            if ($UI.RestoreDock -and $UI.DockPos -and -not (@([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.WorkingArea.Contains($UI.DockPos) }).Count)) { $UI.RestoreDock = $false; Log 'pinned spot is off every screen now - not restoring' 'WARN' }
            if ($UI.RestoreDock -and $UI.DockPos) {          # it was pinned before the restart: put it back, without taking the focus
                $UI.RestoreDock = $false; $UI.Docked = $true; Show-Pop 'restore pinned'; $UI.Pinned = $true; Set-Activatable $true; Save-State; Log ("panel restored pinned at {0},{1}" -f $UI.DockPos.X, $UI.DockPos.Y)
            }
            foreach ($sx0 in 'L', 'R') { if (-not $UI.Sides[$sx0]) { New-SideWin $sx0 } }      # warm the reading columns: instant on first hover
        }
        'size' { $UI.WebH = [double]$m.h; Fit-WebPop; if ($UI.Shown) { $UI.ShotAt = (Get-Date).AddMilliseconds(700); $UI.ShotWhy = 'web-size' } }
        'focus' { if (-not $UI.Pinned) { Pin-Pop; try { $UI.WebUi.Focus() } catch { } } }
        'menuact' {                                     # the panel's settings menu
            switch ([string]$m.k) {
                'theme' { Save-CfgKey 'theme' ([string]$m.v); foreach ($o in $miTheme.DropDownItems) { $o.Checked = ($o.Tag -eq [string]$m.v) }; Apply-Theme }
                'compact' { Save-CfgKey 'compact' (-not [bool]$Cfg.compact); Log ("Menu: compact {0}" -f $Cfg.compact) }
                'terse' { Save-CfgKey 'terse' (-not [bool]$Cfg.terse); $miTerse.Checked = [bool]$Cfg.terse; foreach ($qt in @($QS.List)) { Save-Results $qt (Get-Results $qt) } }
                'debug' { Save-CfgKey 'debugLog' (-not [bool]$Cfg.debugLog); Log ("debug logs {0}" -f $(if ($Cfg.debugLog) { 'ON' } else { 'off' })) 'WARN'; if ($Cfg.debugLog) { Write-DebugSnapshot 'debug on' } }
                'start' { Save-CfgKey 'startWith' ([string]$m.v); New-BootLnk; foreach ($o in $miBoot.DropDownItems) { $o.Checked = ($o.Tag -eq [string]$m.v) } }
                'park' { Save-CfgKey 'parkDesktop' (-not [bool]$Cfg.parkDesktop); if (-not $Cfg.parkDesktop) { Undo-DesktopPark $false }; Log ("Menu: park Claude Desktop off-screen when minimized {0}" -f $(if ($Cfg.parkDesktop) { 'ON' } else { 'off' })) }
                'ghost' { Save-CfgKey 'ghostDesktop' (-not [bool]$Cfg.ghostDesktop); Log ("Menu: hide Claude Desktop while the tray works {0}" -f $(if ($Cfg.ghostDesktop) { 'ON' } else { 'off' })) }
                'hideafter' { Save-CfgKey 'hideAfterMin' ([double]$m.v); Log ("Menu: hide idle chats after {0} min" -f $m.v); Refresh-Quests $true }
                'size' { Save-CfgKey 'panelWidth' $null; Save-CfgKey 'panelHeight' $null; $pop.Width = px ((Get-PanelW) * $UI.Zoom); Fit-WebPop }
                'refresh' { Invoke-Poll }
                'weblogin' { Start-Process $PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" -WebLogin" -WorkingDirectory $Root }
                'logs' { Start-Process explorer.exe $LogDir }
                'quests' { $d = $QuestRoots[0]; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path (Join-Path $d 'quests') -Force | Out-Null }; Start-Process explorer.exe $d }
                'restart' { Restart-Tray 'panel menu' }
                'update' { Start-Update $(if ([string]$m.v -eq 'apply') { 'apply' } else { 'check' }) }
                'exit' { Exit-Tray 'panel menu exit' }
            }
            Log "menu: $($m.k) $($m.v)"
        }
        'rsz' { $UI.Rsz = @{ Edge = [string]$m.e; Start = [System.Windows.Forms.Cursor]::Position; B = $pop.Bounds }; $rszTimer.Start() }
        'drag' { $UI.Drag = @{ Start = [System.Windows.Forms.Cursor]::Position; Origin = $pop.Location }; $UI.DragMoved = $false; $dragTimer.Start() }
        'esc' { if (-not $UI.Docked) { Hide-Pop 'esc' } }
        'col' { if ($m.open) { Show-SideWin ([string]$m.x) $m } else { Hide-SideWin ([string]$m.x) } }
        'zoom' { Set-WebZoom ([int]$m.d) }
        'menu' { $UI.MenuFromPanel = $true; $menu.Show([System.Windows.Forms.Cursor]::Position) }
        'pin' { if ($UI.Docked) { $UI.Docked = $false; Save-State } else { $UI.Docked = $true; Pin-Pop; Set-DockMemo; Save-State } }
        'copy' { if ($m.text) { Set-Clipboard -Value ([string]$m.text) } }
        'log' { Log ("webui page: {0}" -f $m.text) 'WARN' }
        'expand' { $wasOpen = @($UI.WebOpen).Count; $faWas = [bool]$UI.FoldAll; $UI.FoldAll = [bool]$m.all; $UI.WebBig = @(@($m.big) | Where-Object { $_ } | ForEach-Object { [string]$_ }); $newIds = @(@($m.ids) | Where-Object { $_ -and $UI.WebOpen -notcontains [string]$_ }); $UI.WebOpen = @(@($m.ids) | Where-Object { $_ } | ForEach-Object { [string]$_ }); if ($webEnabled) { $Web.MsgFor = @($UI.WebOpen); foreach ($ni in @($newIds | Where-Object { -not ([string]$_).StartsWith('local/') })) { [void]$Web.Cmds.Add(@{ Id = [string]$ni; Kind = 'diag'; Key = 'diag-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } }; $UI.ShotAt = (Get-Date).AddMilliseconds(900); $UI.ShotWhy = 'web-expand' ; if (($wasOpen -eq 0) -ne (@($UI.WebOpen).Count -eq 0) -or $faWas -ne $UI.FoldAll) { Fit-WebPop } }
        'more' { if ($q) { $Web.MsgN[[string]$q.id] = [int]$(if ($Web.MsgN.ContainsKey([string]$q.id)) { $Web.MsgN[[string]$q.id] } else { 20 }) + 15; [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'more'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log ("chat[{0}]: load earlier (now {1} messages)" -f $q.id, $Web.MsgN[[string]$q.id]) 'DEBUG' } }
        'open' { if ($q) { Open-Chat $q ([bool]$m.web) } }
        'bell' { if ($q) { $kb = [string]$q.id; $QS.Bells[$kb] = ($QS.Bells.ContainsKey($kb) -and -not $QS.Bells[$kb]); Save-State } }
        'hide' { if ($q) { $QS.Pins.Remove([string]$q.id); $QS.Hidden[[string]$q.id] = [string]$q.updated; Save-State; Refresh-Quests $true; Log "hide $($q.id)" } }
        'rename' { if ($q) { $nn = (([string]$m.name) -replace '[\r\n\t]+', ' ').Trim(); if ($nn.Length -gt 200) { $nn = $nn.Substring(0, 200) }; $rid = [string]$q.id     # claude.ai chats only (Desktop local chats: greyed out in the menu)
                if ($nn -and $rid.StartsWith('local/')) { if (Rename-LocalChat $q $nn) { Push-WebState $true } else { try { $tray.ShowBalloonTip(4000, 'Rename it in Claude Desktop', "The tray couldn't rename this chat in Claude Desktop.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { } } }
                elseif ($nn -and $rid -match '^chat/([0-9a-f-]{36})$' -and $UI.Org -and $webEnabled) { $QS.Titles[$rid] = $nn; [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'rename'; Uuid = $Matches[1]; Name = $nn; Org = $UI.Org; Key = 'rn-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Save-State; Push-WebState $true; Log "rename[$rid]: sent to claude.ai" } } }
        'modelmenu' { if ($q) { if (([string]$q.id).StartsWith('local/') -or -not $webEnabled) { Open-Chat $q $false } else { $mk1 = 'mm-' + [guid]::NewGuid().ToString('N'); $UI.MMWait = @{ Key = $mk1; Id = [string]$q.id; Mode = 'read'; At = (Get-Date) }; [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'model'; Mode = 'read'; KindM = ''; Name = ''; Key = $mk1; At = (Get-Date) }) } } }     # the chip: read the chat's model menu in its tab
        'setmodel' { if ($q -and [string]$m.kind -in 'model', 'effort' -and -not ([string]$q.id).StartsWith('local/')) { $mk1 = 'mm-' + [guid]::NewGuid().ToString('N'); $UI.MMWait = @{ Key = $mk1; Id = [string]$q.id; Mode = 'pick'; At = (Get-Date) }; [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'model'; Mode = 'pick'; KindM = [string]$m.kind; Name = [string]$m.name; Key = $mk1; At = (Get-Date) }); Log ("model[{0}]: pick {1} '{2}'" -f $q.id, $m.kind, $m.name) } }
        'addfolder' { if ($q -and ([string]$q.id).StartsWith('local/')) { Add-LocalFolder $q } }
        'unhide' { $uid = [string]$m.id; if ($QS.Hidden.ContainsKey($uid)) { $QS.Hidden.Remove($uid); Save-State; Refresh-Quests $true; Log "unhide $uid" } }
        'pinc' { if ($q) { $pid0 = [string]$q.id; if ($QS.Pins.Contains($pid0)) { $QS.Pins.Remove($pid0) } else { $QS.Pins[$pid0] = $true }; Save-State; Refresh-Quests $true; Log ("pin {0}: {1}" -f $pid0, $QS.Pins.Contains($pid0)) } }
        'send' {
            if ($q -and ($m.text -or @($m.files).Count)) {
                $UI.DraftRestore.Remove([string]$q.id); $paths = @()
                foreach ($fx in @($m.files)) { try { $paths += Save-Upload $fx } catch { Log "upload: $($_.Exception.Message)" 'WARN' } }
                if ($paths.Count) { Log ("send[{0}]: {1} attachment(s), {2} KB" -f $q.id, $paths.Count, [int](($paths | ForEach-Object { (Get-Item $_).Length } | Measure-Object -Sum).Sum / 1KB)) }
                $txt1 = [string]$m.text; if ($m.tray -and -not $txt1.TrimStart().StartsWith('/tray')) { $txt1 = '/tray ' + $txt1 }     # the panel's /tray chip: turns the skill on with this message
                if (([string]$q.id).StartsWith('local/') -and $txt1 -match '^\s*/(?:[\w-]+:)?tray\b' -and $QuestRoots.Count) { $txt1 += "`n`n[tray-id] $([string]$q.id) root=$($QuestRoots[0])"; Log "send[$($q.id)]: /tray message - added its quest id and folder for the session" }     # a Desktop local session can't learn its quest id / folder otherwise (no bridge mode there)
                $bl = Get-BridgeLine $q; if ($bl -and $UI.BridgeSent[[string]$q.id] -ne $bl) { $txt1 += $bl; $UI.BridgeSent[[string]$q.id] = $bl; Log ("bridge[{0}]: results appended ({1} chars)" -f $q.id, $bl.Length) }     # whenever the results changed since the last send
                if (-not (Send-ToChat $q $txt1 'panel' $false $paths)) { if ($m.text) { $UI.Drafts[[string]$q.id] = [string]$m.text }; $UI.BridgeSent.Remove([string]$q.id) }
            }
        }
        'read' { if ($q) { $QS.Read[[string]$q.id] = @{ K = [string]$m.key; At = (Get-Date) }; Save-State; Update-TrayIcon; Sync-Anim } }
        'qpick' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qpick'; I = [int]$m.i; Label = [string]$m.label; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'diag'; Key = 'diagq-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log ("qpick[{0}]: choice {1}" -f $q.id, [int]$m.i) } }
        'qnext' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qnext'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'diag'; Key = 'diagq-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } }
        'qother' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qother'; Text = [string]$m.text; Enter = [bool]$m.enter; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log ("qother[{0}]: {1} chars, enter={2}" -f $q.id, ([string]$m.text).Length, [bool]$m.enter) } }
        'qprev' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qprev'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } }
        'qskip' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qskip'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } }
        'qsub' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'qsub'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'diag'; Key = 'diagq-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log ("qsub[{0}]" -f $q.id) } }
        'press' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'press'; I = [int]$m.i; Label = [string]$m.label; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log ("press[{0}]: '{1}'" -f $q.id, $m.label) } }
        'reload' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'reload'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log "reload[$($q.id)] (from the panel)" } }
        'restart' { Restart-Tray 'panel' }
        'slash' { if ($q -and $webEnabled -and -not $UI.SlashKey -and -not ($UI.Slash -and ((Get-Date) - $UI.Slash.At).TotalMinutes -lt 10 -and @($UI.Slash.Items).Count)) { $UI.SlashKey = 'sl-' + [guid]::NewGuid().ToString('N'); [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'slash'; Key = $UI.SlashKey; At = (Get-Date) }) } }
        'retry' { if ($q) { [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'retry'; Key = [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log "retry[$($q.id)]" } }
        'openurl' { $u0 = [string]$m.url; if ($u0 -match '^https?://[^\s"<>]+$') { Start-Process $u0; Log ("open link {0}" -f ($u0 -replace '\?.*$', '?...')) } else { Log 'open link: refused (not http/https)' 'WARN' } }
        'track' { $tid = [string]$m.id; if (@($QS.List | Where-Object { [string]$_.id -eq $tid }).Count) { if ($null -eq $script:CoolTouch) { $script:CoolTouch = @{} }; $script:CoolTouch[$tid] = Get-Date; $QS.Hidden.Remove($tid); Save-State; Refresh-Quests $true; Log "track: $tid already known - shown again" } elseif ($tid -match '^chat/[0-9a-f-]{36}$' -or ($Caps.Local -and $tid -match '^local/[A-Za-z0-9_-]{6,80}$')) { try { Write-Placeholder $tid ([string]$m.title) ''; $QS.Read[$tid] = @{ K = ''; At = (Get-Date) }; $UI.WebOpen = @(@($UI.WebOpen) + $tid); Log "track: $tid"; Refresh-Quests $true } catch { Log "track: $($_.Exception.Message)" 'WARN' } } }
        'catproj' { $cp0 = [string]$m.pid; if ($webEnabled -and $UI.Org -and $cp0 -match '^[0-9a-f-]{36}$' -and -not $UI.CatProj.ContainsKey($cp0)) { $UI.CatProj[$cp0] = 'cp-' + [guid]::NewGuid().ToString('N'); [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'catproj'; Org = $UI.Org; Pid = $cp0; Key = $UI.CatProj[$cp0]; At = (Get-Date) }) } }
        'layout' { $QS.Layout = $m.layout; $UI.LayoutDirty = Get-Date }
        'catalog' { if (-not $webEnabled) { $UI.Catalog = [ordered]@{ projects = @(); err = 'not available (engine off)' } } elseif (-not $UI.CatKey -and -not ($UI.Catalog -and $UI.Catalog.at -and -not $m.force -and ((Get-Date) - (Parse-Iso $UI.Catalog.at)).TotalMinutes -lt 3)) { $UI.CatKey = 'cat-' + [guid]::NewGuid().ToString('N'); if ($UI.Catalog -and $UI.Catalog.recent) { $UI.Catalog.loading = $true } else { $UI.Catalog = [ordered]@{ loading = $true; projects = @() } }; [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'catalog'; Key = $UI.CatKey; At = (Get-Date) }) } }
        'newchat' {
            if (-not $webEnabled) { $UI.NewChat = [ordered]@{ St = 'failed'; Msg = 'not available (engine off)'; Key = 'new-' + [guid]::NewGuid().ToString('N') } }
            elseif (-not ($UI.NewChat -and $UI.NewChat.St -eq 'working')) {
                $txt0 = ([string]$m.text).Trim(); $txt0 = if ($txt0 -match '(^|\s)/tray\b') { $txt0 } else { ('/tray ' + $txt0).Trim() }
                $nk = 'new-' + [guid]::NewGuid().ToString('N')
                $UI.NewChat = [ordered]@{ St = 'working'; Key = $nk; Name = ([string]$m.name).Trim(); Text = $txt0; Msg = '' }
                [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'newchat'; Project = [string]$m.project; Name = ([string]$m.name).Trim(); Model = [string]$m.model; Think = [string]$m.think; Text = $txt0; Org = $UI.Org; Key = $nk; At = (Get-Date) })
                Log ("new chat: project={0} model={1} think={2} name={3}" -f $(if ($m.project) { 'yes' } else { 'none' }), $m.model, $m.think, $(if ($m.name) { 'set' } else { 'auto' }))
            }
        }
        'dl' {
            if ($q) {
                $key = "{0}|{1}|{2}" -f $q.id, [int]$m.x, [int]$m.k; $dl = $UI.Dl[$key]
                if ($dl -and $dl.Path -and (Test-Path $dl.Path)) {     # already here: open its folder / copy again
                    if ([string]$m.mode -eq 'copy') { $sc = New-Object System.Collections.Specialized.StringCollection; [void]$sc.Add($dl.Path); [System.Windows.Forms.Clipboard]::SetFileDropList($sc); $dl.St = 'copied' } elseif ([string]$m.mode -eq 'open') { Open-Downloaded $dl.Path; $dl.St = 'opened'; Push-WebState } else { Start-Process explorer.exe "/select,`"$($dl.Path)`"" }
                } elseif (-not $dl -or $dl.St -ne 'working') {
                    $ck = [guid]::NewGuid().ToString('N'); $dir = Join-Path $env:LOCALAPPDATA ('ClaudeTray\dl\' + $ck.Substring(0, 8))
                    $UI.Dl[$key] = @{ Id = [string]$q.id; St = 'working'; Mode = [string]$m.mode; Dir = $dir; Cmd = $ck; At = (Get-Date); Res = $null; Path = $null }
                    [void]$Web.Cmds.Add(@{ Id = [string]$q.id; Kind = 'dl'; X = [int]$m.x; K = [int]$m.k; Dir = $dir; Key = $ck; At = (Get-Date) })
                }
            }
        }
        'stop' { if ($q) { Stop-Chat $q } }
        'auto' { if ($q) { [void](Send-ToChat $q 'do it yourself' 'auto') } }
        'autostep' { if ($wstep) { [void](Send-ToChat $q ("do step {0} yourself: {1}" -f $wstep.n, $wstep.label) 'step-auto') } }
        'run' { if ($wstep -and (Test-StepsLocked $q)) { Log "run[$($q.id)#$($wstep.n)]: refused - Claude is working / the round was sent" 'DEBUG' } elseif ($wstep) { Start-Step $q $wstep; Refresh-Quests $true } }
        'tick' { if ($wstep -and -not (Test-StepsLocked $q)) { Toggle-Manual @{ q = $q; st = $wstep } } }
        'skip' { if ($wstep) { $rec = @($q.Res.steps) | Where-Object { [int]$_.n -eq [int]$wstep.n } | Select-Object -First 1; if ($rec -and $rec.status -eq 'skipped') { Set-StepResult $q ([int]$wstep.n) @{ status = 'pending'; ended = $null } } else { Set-StepResult $q ([int]$wstep.n) @{ status = 'skipped'; ended = (Get-Iso (Get-Date)) } }; Refresh-Quests $true } }
        'answer' { if ($wstep -and -not (Test-StepsLocked $q)) { Set-StepResult $q ([int]$wstep.n) @{ status = 'done'; answer = [string]$m.text; ended = (Get-Iso (Get-Date)) }; Refresh-Quests $true } }
    }
    if ($mt -notin 'size', 'focus', 'drag', 'log', 'copy') { Push-WebState }
}
# manual drag (when the runtime has no CSS app-region support): follow the cursor at ~60 fps until the button is released
# resize from the panel's edges (the page posts 'rsz' with the edge); a panel you resize gets pinned where it is
$rszTimer = New-Object System.Windows.Forms.Timer; $rszTimer.Interval = 15
$rszTimer.add_Tick({
    try {
        $rz = $UI.Rsz; if (-not $rz) { $rszTimer.Stop(); return }
        $cp = [System.Windows.Forms.Cursor]::Position; $dx = $cp.X - $rz.Start.X; $dy = $cp.Y - $rz.Start.Y; $b = $rz.B
        $wa = [System.Windows.Forms.Screen]::FromControl($pop).WorkingArea; $minW = px 260; $minH = px 140
        $l = $b.Left; $t0 = $b.Top; $r = $b.Right; $bt = $b.Bottom; $rzEdge = $rz.Edge
        if ($rzEdge -match 'l') { $l = [Math]::Min($r - $minW, [Math]::Max($wa.Left, $b.Left + $dx)) }
        if ($rzEdge -match 'r') { $r = [Math]::Max($l + $minW, [Math]::Min($wa.Right, $b.Right + $dx)) }
        if ($rzEdge -match 't') { $t0 = [Math]::Min($bt - $minH, [Math]::Max($wa.Top, $b.Top + $dy)) }
        if ($rzEdge -match 'b') { $bt = [Math]::Max($t0 + $minH, [Math]::Min($wa.Bottom, $b.Bottom + $dy)) }
        if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::Left) {
            $UI.Rsz = $null; $rszTimer.Stop(); $UI.LeftAt = $null
            if ($pop.Bounds -eq $b) { Fit-WebPop; return }     # a click on an edge without moving: nothing to save (and the height stays automatic)
            $zk = $k * $UI.Zoom; Save-CfgKey 'panelWidth' ([int][Math]::Round($pop.Width / $zk)); if ($rzEdge -match '[tb]') { Save-CfgKey 'panelHeight' ([int][Math]::Round($pop.Height / $zk)) }
            if ($UI.Docked) { Set-DockMemo; Save-State }; Log ("panel resized to {0}x{1} ({2}), docked {3}" -f $pop.Width, $pop.Height, $rzEdge, $UI.Docked) 'DEBUG'; Push-WebState $true; return
        }
        if ($l -ne $pop.Left -or $t0 -ne $pop.Top -or ($r - $l) -ne $pop.Width -or ($bt - $t0) -ne $pop.Height) { $pop.SetBounds($l, $t0, $r - $l, $bt - $t0) }     # only when the cursor moved
    } catch { $UI.Rsz = $null; $rszTimer.Stop() }
})
# a double-click on the drag band can maximize a borderless window (it did): always back to normal
$pop.add_Resize({ try { if ($pop.WindowState -ne [System.Windows.Forms.FormWindowState]::Normal) { $pop.WindowState = [System.Windows.Forms.FormWindowState]::Normal; $pop.Width = px ((Get-PanelW) * $UI.Zoom); Fit-WebPop; Log 'panel was maximized - restored' 'WARN' } } catch { } })
$dragTimer = New-Object System.Windows.Forms.Timer; $dragTimer.Interval = 15
$dragTimer.add_Tick({
    try {
        if (-not $UI.Drag) { $dragTimer.Stop(); return }
        if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::Left) { $UI.Drag = $null; $dragTimer.Stop(); if ($UI.DragMoved) { Set-DockHere }; Fit-WebPop; return }
        $cp = [System.Windows.Forms.Cursor]::Position
        if ($UI.DragMoved -or (Dist $cp $UI.Drag.Start) -gt 3) { $UI.DragMoved = $true; $pop.Location = New-Object System.Drawing.Point ($UI.Drag.Origin.X + $cp.X - $UI.Drag.Start.X), ($UI.Drag.Origin.Y + $cp.Y - $UI.Drag.Start.Y) }
    } catch { $UI.Drag = $null; $dragTimer.Stop() }
})
# native drag (CSS app-region): Windows runs the move loop -> ResizeBegin/ResizeEnd
$pop.add_ResizeBegin({ $UI.MoveFrom = $pop.Location })
$pop.add_LocationChanged({ if ($UI.Sides.Count) { Place-SideWins } }); $pop.add_SizeChanged({ if ($UI.Sides.Count) { Place-SideWins } })
$pop.add_ResizeEnd({ $mf = $UI.MoveFrom; $UI.MoveFrom = $null; if ($mf -and $pop.Location -ne $mf) { Set-DockHere }; Fit-WebPop })

# context menu
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miRefresh = $menu.Items.Add('Refresh now')
$miOpen    = $menu.Items.Add('Open claude.ai usage page')
$miQuests  = $menu.Items.Add('Open quest folder')
$miLogs    = $menu.Items.Add('Open log folder')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miTheme   = New-Object System.Windows.Forms.ToolStripMenuItem 'Theme'
foreach ($tn in 'auto', 'light', 'dark') {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($tn -eq 'auto') { 'Follow Windows' } else { (Get-Culture).TextInfo.ToTitleCase($tn) })
    $mi.Tag = $tn; $mi.Checked = ([string]$Cfg.theme -eq $tn)
    $mi.add_Click({ try { Save-CfgKey 'theme' ([string]$this.Tag); foreach ($o in $miTheme.DropDownItems) { $o.Checked = ($o.Tag -eq $this.Tag) }; Apply-Theme } catch { Log "theme: $($_.Exception.Message)" 'ERR' } })
    [void]$miTheme.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($miTheme)
$miTerse   = New-Object System.Windows.Forms.ToolStripMenuItem 'Short replies from Claude'
$miTerse.Checked = [bool]$Cfg.terse; $miTerse.ToolTipText = 'Asks Claude (through the results file it reads on "check") to answer in the shortest form, typos and shortcuts allowed'
[void]$menu.Items.Add($miTerse)
$miTerse.add_Click({ try { Save-CfgKey 'terse' (-not [bool]$Cfg.terse); $miTerse.Checked = [bool]$Cfg.terse; foreach ($qt in @($QS.List)) { Save-Results $qt (Get-Results $qt) }; Log ("Menu: short replies {0}" -f $Cfg.terse) } catch { Log "terse: $($_.Exception.Message)" 'ERR' } })
$miBoot    = New-Object System.Windows.Forms.ToolStripMenuItem 'Start automatically'
$curStart = if (-not (Test-Path $LnkBoot)) { 'manual' } elseif ([string]$Cfg.startWith -eq 'claude') { 'claude' } else { 'windows' }
foreach ($sm in @(@('windows', 'With Windows'), @('claude', 'When the Claude app opens (also at startup)'), @('manual', 'Only when I start it'))) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $sm[1]; $mi.Tag = $sm[0]; $mi.Checked = ($sm[0] -eq $curStart)
    $mi.add_Click({ try { Save-CfgKey 'startWith' ([string]$this.Tag); New-BootLnk; foreach ($o in $miBoot.DropDownItems) { $o.Checked = ($o.Tag -eq $this.Tag) }; Log "Menu: start mode $($this.Tag)" } catch { Log "start mode: $($_.Exception.Message)" 'ERR' } })
    [void]$miBoot.DropDownItems.Add($mi)
}
[void]$menu.Items.Add($miBoot)
$miWebIn   = $menu.Items.Add('Sign in to claude.ai...')
$miWebIn.ToolTipText = "Signs the tray's own browser in to claude.ai (once): conversations, send, stop and files in the panel"
$miSignOut = $menu.Items.Add('Log out')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miRestart = $menu.Items.Add('Restart')
$miExit    = $menu.Items.Add('Exit')
$tray.ContextMenuStrip = $menu
$miRefresh.add_Click({ try { Log 'Menu: refresh'; Invoke-Poll } catch { Log "refresh: $($_.Exception.Message)" 'ERR' } })
$miOpen.add_Click({ try { Start-Process $UsageUrl } catch { Log "open: $($_.Exception.Message)" 'ERR' } })
$miQuests.add_Click({ try { $d = $QuestRoots[0]; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path (Join-Path $d 'quests') -Force | Out-Null }; Start-Process explorer.exe $d } catch { } })
$miLogs.add_Click({ try { Start-Process explorer.exe $LogDir } catch { } })
$miSignOut.add_Click({ try { foreach ($f in @($OAuthFile, "$OAuthFile.claudetray.bak")) { if (Test-Path $f) { Remove-Item $f -Force } }; Exit-Tray 'menu log out' } catch { Log "logout: $($_.Exception.Message)" 'ERR' } })
$miExit.add_Click({ Exit-Tray 'menu exit' })
$miWebIn.add_Click({ try { Log 'Menu: web login'; Start-Process $PsExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" -WebLogin" -WorkingDirectory $Root } catch { Log "web login: $($_.Exception.Message)" 'ERR' } })
$miRestart.add_Click({ Restart-Tray 'menu' })
$menu.add_Opening({ try { if ($UI.MenuFromPanel) { $UI.MenuFromPanel = $false; Pin-Pop } elseif ($UI.Shown -and -not $UI.Docked) { Hide-Pop 'menu' } } catch { } })

# hover / click
$tray.add_MouseMove({ try { $UI.Anchor = [System.Windows.Forms.Cursor]::Position; if ($UI.Docked -and $UI.ClickHid) { return }; if (-not $UI.Shown -and -not $UI.Pending) { $UI.Pending = $true; $UI.PendSince = Get-Date } } catch { Log "mousemove: $($_.Exception.Message)" 'ERR' } })
$tray.add_MouseClick({
    param($sender, $e)
    try {
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        # one click = show / hide (pinned or not). A panel the hover just opened stays open (it counts as hidden before).
        $UI.ClickWas = if ($UI.Shown -and ($UI.Pinned -or $UI.Docked)) { 'open' } else { 'closed' }
        if ($UI.ClickWas -eq 'open') { Hide-Pop 'icon click' $true; $UI.ClickHid = [bool]$UI.Docked; return }     # a pinned panel hidden by a click stays hidden until the next click (no hover re-show)
        $UI.ClickHid = $false
        $UI.Anchor = [System.Windows.Forms.Cursor]::Position
        if (((Get-Date) - $UI.LastPollAt).TotalSeconds -gt 20) { $UI.LastPollAt = Get-Date; Update-Usage }
        Refresh-Quests $false; Show-Pop 'click'; Pin-Pop
    } catch { Log "click: $($_.Exception.Message)" 'ERR' }
})
$tray.add_MouseDoubleClick({ try { if ($UI.Docked) { return }; if ($UI.ClickWas -eq 'closed' -and $UI.Shown) { Hide-Pop 'double click' $true } elseif ($UI.ClickWas -eq 'open' -and -not $UI.Shown) { Show-Pop 'double click'; Pin-Pop }; Open-ClaudeApp } catch { Log "double click: $($_.Exception.Message)" 'WARN' } })     # undo the first click's show/hide, then open the app
$tray.add_BalloonTipClicked({ try { Refresh-Quests $false; Show-Pop 'balloon'; Pin-Pop } catch { } })

$uiTimer = New-Object System.Windows.Forms.Timer
$uiTimer.Interval = 50
$uiTimer.add_Tick({
    try {
        if ($QuitEvent.WaitOne(0)) { Exit-Tray 'quit signal (restart/uninstall)'; return }
        $UI.Tick = ([int]$UI.Tick + 1) % 1000
        if ($UI.WebReady -and ($UI.Tick % $(if ($UI.Shown -or $UI.Docked -or $UI.Pending) { 5 } else { 80 }) -eq 0)) { Push-WebState }      # page = live mirror (only posts when something changed)
        elseif ($UI.WebUi -and -not $UI.WebReady -and $UI.WebStart -and ((Get-Date) - $UI.WebStart).TotalSeconds -gt 20) { Log 'webui: panel not ready after 20 s - classic panel' 'WARN'; Disable-WebUi }
        if ($UI.Shown -and ($UI.Tick % 3 -eq 0)) { foreach ($f in @($UI.Fields)) { Update-FieldBar $f } }
        if ($UI.Shown -and (($UI.Tick % 200 -eq 0) -or (($Probe.Working -or $UI.AnyWorking) -and $UI.Tick % 12 -eq 0))) { Update-Live }   # countdowns every ~10 s, live answer every ~0.6 s while Claude writes   # scroll indicators follow wheel/keys
        $th0 = [ClaudeTray.WheelToHover]::TopHit
        if ($th0 -ne [IntPtr]::Zero) { [ClaudeTray.WheelToHover]::TopHit = [IntPtr]::Zero; foreach ($cid in @($UI.Chats.Keys)) { try { if ($UI.Chats[$cid].Box.Handle -eq $th0) { Request-Earlier $cid } } catch { } } }
        if ($UI.SideShotAt -and (Get-Date) -gt $UI.SideShotAt) { $UI.SideShotAt = $null; Save-SideShot $UI.SideShotX }
        if ($UI.ShotAt -and (Get-Date) -gt $UI.ShotAt) { $UI.ShotAt = $null; if ($UI.Shown) { Save-PopShot $UI.ShotWhy } }
        if ($UI.FocusTarget) {                         # focus hop: retry a few ticks until Windows lets the panel take focus
            $ft = $UI.FocusTarget; $UI.FocusTries++
            try { if (-not $ft.IsDisposed) { Set-Activatable $true; [void][ClaudeTray.Native]::SetForegroundWindow($hPop); $pop.Activate(); [void]$ft.Focus(); $ft.SelectionStart = $ft.Text.Length; $ft.SelectionLength = 0 } } catch { }
            if ($ft.IsDisposed -or $ft.Focused -or $UI.FocusTries -ge 6) { Log ("focus hop: {0} after {1} tries" -f $(if ($ft.Focused) { 'ok' } else { 'FAILED' }), $UI.FocusTries) 'DEBUG'; $UI.FocusTarget = $null }
        }
        if ($UI.CloseAfter) { $UI.CloseAfter = $false; $UI.NeedBuild = $false; Hide-Pop 'unpin' }
        if ($UI.NeedBuild) { $UI.NeedBuild = $false; if ($UI.Shown) { Build-Rows } }
        elseif ($UI.PreBuild -and -not $UI.Shown -and -not $UI.Pending) { $UI.PreBuild = $false; Build-Rows }   # warm the flyout while hidden -> hover shows it instantly
        $cur = [System.Windows.Forms.Cursor]::Position
        if ($UI.SideWant -and $UI.SideWant.Tag -is [hashtable] -and $UI.SideWant.Tag.Chat -and ((Get-Date) - $UI.SideHoverAt).TotalMilliseconds -ge 450) {
            try {
                $rb0 = $UI.SideWant; $ch0 = $UI.Chats[[string]$rb0.Tag.Chat]
                $ix = $rb0.GetCharIndexFromPosition($rb0.PointToClient([System.Windows.Forms.Cursor]::Position))
                $hit = @($ch0.Ranges | Where-Object { $ix -ge $_.S -and $ix -lt $_.E })[0]
                if ($hit -and $UI.SideMsg -ne "$($rb0.Tag.Chat)#$($hit.S)") { $UI.SideMsg = "$($rb0.Tag.Chat)#$($hit.S)"; $UI.SideFor = $null; Show-Side $hit.T $rb0 ("{0} - {1}" -f $hit.Who, $ch0.Q.title) }
            } catch { }
        }
        elseif ($UI.SideWant -and $UI.SideWant -ne $UI.SideFor -and ((Get-Date) - $UI.SideHoverAt).TotalMilliseconds -ge 300) { try { $sw0 = $UI.SideWant; $full = if ($sw0.Tag -is [hashtable] -and $sw0.Tag.Q) { Get-AnswerFull $sw0.Tag.Q } else { $sw0.Text }; if ($full) { Show-Side $full $sw0 ("Claude's answer - {0}" -f $(if ($sw0.Tag.Q) { $sw0.Tag.Q.title } else { '' })) } } catch { } }
        if ($side.Visible -and -not $UI.SidePinned) {
            $overSide = $side.Bounds.Contains($cur); $overBox = $false
            if ($UI.SideFor) { try { $overBox = $UI.SideFor.RectangleToScreen($UI.SideFor.ClientRectangle).Contains($cur) } catch { } }
            if ($overSide -or $overBox) { $UI.SideLeft = $null } elseif (-not $UI.SideLeft) { $UI.SideLeft = Get-Date } elseif (((Get-Date) - $UI.SideLeft).TotalMilliseconds -ge 400) { $UI.SideLeft = $null; Hide-Side }
        }
        if (-not $UI.Shown -and $side.Visible -and -not $UI.SidePinned) { Hide-Side }
        $near = (Dist $cur $UI.Anchor) -le $tol
        if ($UI.Pending) {
            if (-not $near) { $UI.Pending = $false }
            elseif (((Get-Date) - $UI.PendSince).TotalMilliseconds -ge 150) { $UI.Pending = $false; Refresh-Quests $false; Show-Pop 'hover' }
        }
        elseif ($UI.Shown -and -not $UI.Docked -and -not $UI.Rsz -and -not $UI.Drag) {     # never while you resize / move it (the cursor is outside then)
            $inside = $near -or $pop.Bounds.Contains($cur) -or (Get-Bridge).Contains($cur) -or $menu.Visible -or ($side.Visible -and $side.Bounds.Contains($cur)) -or (Test-InSideWins $cur)
            if ($UI.Pinned) {
                if ([System.Windows.Forms.Control]::MouseButtons -ne [System.Windows.Forms.MouseButtons]::None -and -not $inside) { Hide-Pop 'click outside' }
            } elseif ($inside) { $UI.LeftAt = $null }
            elseif (-not $UI.LeftAt) { $UI.LeftAt = Get-Date }
            elseif (((Get-Date) - $UI.LeftAt).TotalMilliseconds -ge 450) { Hide-Pop 'mouse left' }
        }
    } catch { Log "ui tick: $($_.Exception.Message)" 'ERR' }
})
$questTimer = New-Object System.Windows.Forms.Timer
$questTimer.Interval = 700
$questTimer.add_Tick({
    try {
        $UI.CoolN = [int]$UI.CoolN + 1
        if ($script:Park -or ($Cfg.parkDesktop -and $Caps.Park)) { Update-DesktopPark }     # off unless the capability is on
        if ($script:Ghost -and ((Get-Date) - $script:Ghost.At).TotalSeconds -gt 20) { Log 'ghost: safety net - Claude Desktop made visible again' 'WARN'; Set-DesktopGhost $script:Ghost.H $false }
        if ($webEnabled -and $Web.Usage -and [int]$Web.Usage.Code -eq 200 -and $Web.Usage.At -ne $UI.UsageSeen) { $UI.UsageSeen = $Web.Usage.At; try { Update-Usage; Update-TrayIcon; Push-WebState } catch { } }     # show a fresh claude.ai usage at once (not at the next 3-min poll)
        if ($webEnabled -and $UI.CoolN -eq 7 -and -not @(@($Web.Want) | Where-Object { ([string]$_) -match '^(chat|code)/' }).Count -and (-not $Web.Usage -or ((Get-Date) - $Web.Usage.At).TotalSeconds -gt 170) -and -not @($Web.Cmds.ToArray() | Where-Object { $_.Kind -eq 'usage' }).Count) { [void]$Web.Cmds.Add(@{ Id = '__new__'; Kind = 'usage'; Key = 'us-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }); Log 'usage: queued a claude.ai usage read (no chat tab open)' }
        if ($UI.CoolN -ge 14) { $UI.CoolN = 0; foreach ($cq in @($QS.List)) { if ([bool](Get-QVisible $cq) -ne [bool]$cq.Visible) { Log ("cooldown: {0} -> {1}" -f $cq.id, $(if ($cq.Visible) { 'browse only' } else { 'back in the tray' })); Refresh-Quests $true; break } } }     # , ~10 s
        $changed = Poll-Running
        # live state from the app watcher
        if ([bool]$Probe.Working -ne [bool]$UI.LastWorking -and (Get-PageLabel $Probe.Page) -ne '<other chat>') {
            $now = Get-Date; $lagScan = [int]($now - $Probe.At).TotalMilliseconds
            if ($Probe.Working) {
                $UI.WorkSince = $Probe.At
                $fromSend = if ($UI.LastSend) { '{0} ms after the send' -f [int]($Probe.At - $UI.LastSend.At).TotalMilliseconds } else { 'no tray send' }
                Log ("timing: idle -> working at {0:HH:mm:ss.fff} ({1}{2}), UI {3} ms after the scan" -f $Probe.At, $fromSend, $(if ($Probe.Starting) { ', before the stop button showed' } else { '' }), $lagScan)
            } else {
                $dur = if ($UI.WorkSince) { [int]($Probe.At - $UI.WorkSince).TotalSeconds } else { -1 }
                Log ("timing: working -> idle at {0:HH:mm:ss.fff} after {1} s, UI {2} ms after the scan" -f $Probe.At, $dur, $lagScan)
            }
            $UI.LastWorking = [bool]$Probe.Working
        }
        $pk = "{0}|{1}" -f $Probe.Page, $Probe.Working
        if ($pk -ne $UI.ProbeKey) { $UI.ProbeKey = $pk; Log ("app: page '{0}' working={1}{6} stop='{2}' buttons=[{3}] scan={4}ms{5}" -f (Get-PageLabel $Probe.Page), $Probe.Working, $Probe.StopName, $Probe.Buttons, $Probe.Ms, $(if ($Probe.Err) { ' err=' + $Probe.Err } else { '' }), $(if ($Probe.Starting) { '(starting)' } else { '' })) 'DEBUG'; $changed = $true }
        foreach ($sk in @($UI.WebSends.Keys)) {
            $ws0 = $UI.WebSends[$sk]; $wres = $Web.Results[$sk]; $wcc = $Web.Chats[[string]$ws0.Q.id]
            $age = ((Get-Date) - $ws0.At).TotalSeconds
            if ($wres -and $wres.Res -ne 'sent') {
                $UI.WebSends.Remove($sk); $Web.Results.Remove($sk); $UI.Drafts[[string]$ws0.Q.id] = $ws0.Text; $UI.Sending.Remove([string]$ws0.Q.id); $changed = $true
                $why = switch ($wres.Res) { 'not-empty' { "the chat's message box already has text you typed there" } 'no-composer' { 'the chat page is not ready (signed in?)' } 'wrong-page' { "the chat's page moved - reload it" } default { $wres.Res } }
                Log ("send[{0}] browser: NOT sent - {1}; text back in the box" -f $ws0.Q.id, $why) 'WARN'
                try { $tray.ShowBalloonTip(5000, 'Not sent', "Not sent: $why. Your text is back in the box.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
            } elseif ($wres -and $wcc -and ($wcc.Users -gt $ws0.Users -or $wcc.Working -or ($ws0.Key0 -and (([string]$wcc.LastUser -replace '\s+', ' ').Trim()).StartsWith($ws0.Key0)))) {     # count, working, or your text as the last message (the count moves when claude.ai unloads old messages)
                Log ("send[{0}] browser: delivered in {1} ms (user messages {2} -> {3}, working={4})" -f $ws0.Q.id, [int]((Get-Date) - $ws0.At).TotalMilliseconds, $ws0.Users, $wcc.Users, $wcc.Working)
                $UI.WebSends.Remove($sk); $Web.Results.Remove($sk)
            } elseif ($age -gt $(if ($ws0.Files) { 40 } else { 10 })) {          # uploads take longer (the browser waits up to 25 s)
                $UI.WebSends.Remove($sk); $Web.Results.Remove($sk)
                Log ("send[{0}] browser: NOT VERIFIED after 10 s (result '{1}', users {2} -> {3}) - text back in the box" -f $ws0.Q.id, $(if ($wres) { $wres.Res } else { 'none' }), $ws0.Users, $(if ($wcc) { $wcc.Users } else { '?' })) 'WARN'
                $UI.Drafts[[string]$ws0.Q.id] = $ws0.Text; $UI.Sending.Remove([string]$ws0.Q.id); $changed = $true
                try { $tray.ShowBalloonTip(4000, 'Check the chat', "Couldn't confirm your message arrived in '$($ws0.Q.title)'. Your text is back in the box.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
            }
        }
        if ($UI.UpdPs) { Poll-Update }
        if ($webEnabled -and $UI.WebReady) { Poll-Downloads; Poll-NewChat; Poll-ModelMenu }
        if ($webEnabled -and $Web.Usage -and $Web.Usage.At -ne $UI.UsageSeen) { $UI.UsageSeen = $Web.Usage.At; Update-Usage; Test-UsageAlerts; Update-TrayIcon }     # fresh usage from claude.ai: show it now
        if ($Cfg.debugLog -and (-not $UI.SnapAt -or ((Get-Date) - $UI.SnapAt).TotalSeconds -gt 60)) { $UI.SnapAt = Get-Date; Write-DebugSnapshot }
        if ($UI.LayoutDirty -and ((Get-Date) - $UI.LayoutDirty).TotalSeconds -gt 1) { $UI.LayoutDirty = $null; Save-State }     # sections / order / sort from the panel
        if ($webEnabled) { Poll-Bridge }
        if ($webEnabled -and ($UI.Tick % 40 -eq 0)) { foreach ($rk0 in @($Web.Results.Keys)) { $rv0 = $Web.Results[$rk0]; if ($rv0 -and $rv0.At -and ((Get-Date) - $rv0.At).TotalSeconds -gt 60) { $Web.Results.Remove($rk0) } } }   # press / retry / stop / more results nobody reads
        if ($webEnabled -and $UI.WebReady) { foreach ($oid in @($UI.WebOpen)) { $wc1 = $Web.Chats[$oid]; if ($wc1 -and $wc1.Msgs) { $mn1 = @($wc1.Msgs).Count; if ($UI.MsgCount[$oid] -and $mn1 -gt $UI.MsgCount[$oid] -and -not ($UI.DiagAt[$oid] -and ((Get-Date) - $UI.DiagAt[$oid]).TotalSeconds -lt 60)) { $UI.DiagAt[$oid] = Get-Date; [void]$Web.Cmds.Add(@{ Id = $oid; Kind = 'diag'; Key = 'diag-' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) }; $UI.MsgCount[$oid] = $mn1 } } }   # new message in an open chat: log its structure (no text) - file cards, prompts
        if ($webEnabled) {
            $Web.Want = @($QS.List | Where-Object { $_.Visible -and -not ([string]$_.id).StartsWith('local/') } | ForEach-Object { [string]$_.id })     # Desktop local chats have no claude.ai page
            $Web.MsgFor = if ($UI.WebReady) { if ($UI.Shown -or $UI.Docked -or $UI.Pending) { @($UI.WebBig) } else { @() } } elseif ($UI.Shown -or $UI.Docked) { @($UI.Chats.Keys) } else { @() }
            $msig = (@($UI.Chats.Keys | ForEach-Object { $cc1 = $Web.Chats[$_]; if ($cc1 -and $cc1.Msgs) { "$_=$(@($cc1.Msgs).Count)/$(([string]@($cc1.Msgs)[-1].t).Length)" } }) -join ';')
            if ($msig -ne $UI.MsgSig) { $UI.MsgSig = $msig; foreach ($cid in @($UI.Chats.Keys)) { Render-Chat $cid } }
            while ($Web.Log.Count) { $wl = $Web.Log[0]; $Web.Log.RemoveAt(0); Log "web: $wl" $(if ([string]$wl -match 'new: usage|usage via|launch|edge|profile|sign') { 'INFO' } else { 'DEBUG' }) }     # usage / browser lines visible without debug
            $wsig = (@($Web.Chats.Keys | ForEach-Object { $cc = $Web.Chats[$_]; "$_=$($cc.Working)/$(if (-not $UI.WebReady) { $cc.Reply.Length })" }) -join ';')     # the web panel reads replies on its own push: streaming text needn't re-read every quest file
            if ($wsig -ne $UI.WebSig) { $UI.WebSig = $wsig; $changed = $true }
            $UI.AnyWorking = [bool](@($Web.Chats.Values | Where-Object { $_.Working }).Count)
            $Web.Idle = -not ($UI.AnyWorking -or $UI.Shown -or $UI.Docked -or $UI.Pending -or $UI.WebSends.Count -or $Web.Cmds.Count)
            foreach ($qq in @($QS.List | Where-Object { $_.Visible })) {
                $cc = $Web.Chats[[string]$qq.id]; if (-not $cc) { continue }
                $psg = (@($cc.Prompts) -join '|') + $(if ($cc.Q) { '|?' + [string]$cc.Q.t } else { '' }); $ppv = [string]$UI.PromptWas[[string]$qq.id]; $UI.PromptWas[[string]$qq.id] = $psg
                if ($psg -and $psg -ne $ppv -and -not ($QS.Bells.ContainsKey([string]$qq.id) -and -not $QS.Bells[[string]$qq.id])) { try { $tray.ShowBalloonTip(5000, [string]$qq.title, $(if ($cc.Q -and -not @($cc.Prompts).Count) { "Claude asks: {0}" -f [string]$cc.Q.t } else { "Claude asks: {0}" -f (@($cc.Prompts) -join ' / ') }), [System.Windows.Forms.ToolTipIcon]::None) } catch { }; Log "notify: page asks in $($qq.id)"; Sync-Anim }
                $prevW = $UI.WebWas[[string]$qq.id]; $UI.WebWas[[string]$qq.id] = [bool]$cc.Working
                if ($prevW -and -not $cc.Working -and -not $UI.Shown -and -not ($QS.Bells.ContainsKey([string]$qq.id) -and -not $QS.Bells[[string]$qq.id])) {
                    try { $tray.ShowBalloonTip(4000, [string]$qq.title, 'Claude finished - your turn', [System.Windows.Forms.ToolTipIcon]::None) } catch { }
                    Log "notify: Claude finished in $($qq.id)"
                }
            }
        }
        while ($Probe.DiagLog.Count) { $dl = $Probe.DiagLog[0]; $Probe.DiagLog.RemoveAt(0); Log "app-diag: $dl" 'DEBUG' }
        if ($Probe.VerifyResult) {
            $vr = $Probe.VerifyResult; $Probe.VerifyResult = ''
            if (-not ($vr -like 'landed*' -or $vr -like 'queued*')) { $Probe.ExpectAt = [datetime]::MinValue }     # not delivered: no 'working' expectation
            if ($vr -like 'queued*') { Log ("send[{0}] verified: {1}" -f $UI.VerifyQ.id, $vr) }
            elseif ($vr -like 'landed*') { Log ("send[{0}] verified: {1} (last user message {2})" -f $UI.VerifyQ.id, $vr, (Mask ([string]$Probe.LastUser))) }
            else {
                Log ("send[{0}] NOT VERIFIED: no new message within 6 s (snip {1}, last user msg {2}, page '{3}') - draft restored" -f $UI.VerifyQ.id, (Mask $UI.VerifySnip), (Mask ([string]$Probe.LastUser)), (Get-PageLabel $Probe.Page)) 'WARN'
                $UI.Drafts[[string]$UI.VerifyQ.id] = $UI.VerifyText; $changed = $true
                try { $tray.ShowBalloonTip(4000, 'Check the chat', "Couldn't confirm your message arrived in '$($UI.VerifyQ.title)'. Your text is back in the box.", [System.Windows.Forms.ToolTipIcon]::Warning) } catch { }
            }
        }
        foreach ($qid in @($UI.Queue.Keys)) {
            $qq = @($QS.List | Where-Object { [string]$_.id -eq $qid })[0]
            if (-not $qq) { $UI.Queue.Remove($qid); continue }
            if (-not (Test-ChatWorking $qq) -and ((Get-Date) - $UI.QueuedAt[$qid]).TotalSeconds -gt 2) { $txt = $UI.Queue[$qid]; $UI.Queue.Remove($qid); Log "queue: Claude idle on $qid, sending now" 'DEBUG'; if (-not (Send-ToChat $qq $txt 'queue')) { $UI.Drafts[$qid] = $txt; Log "queue[$qid]: send failed, text back in the box" 'WARN' }; $changed = $true }
        }
        $Probe.Fast = [bool]($UI.Shown -or $UI.Queue.Count); $Probe.NoLive = [bool]$UI.WebReady
        $pausePrev = [bool]$Probe.Pause; $Probe.Pause = [bool]($webEnabled -and $Web.Ok -and @($QS.List | Where-Object { $_.Visible -and -not (Get-WebChat $_) }).Count -eq 0)
        if ($pausePrev -ne $Probe.Pause) { Log ("app watcher {0} (browser engine {1})" -f $(if ($Probe.Pause) { 'paused' } else { 'resumed' }), $(if ($Web.Ok) { 'covers every tracked chat' } else { 'not ready' })) 'DEBUG' }
        $sig = (Get-ChildItem ($QuestRoots | ForEach-Object { Join-Path $_ 'quests' }) -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
        if ($changed -or $sig -ne $UI.QuestSig) { $UI.QuestSig = $sig; Refresh-Quests $true }
    } catch { Log "quest tick: $($_.Exception.Message)" 'ERR' }
})
$animTimer = New-Object System.Windows.Forms.Timer                # icon pulse / spinner, only runs while a badge is shown
$animTimer.Interval = 260
$animTimer.add_Tick({
    try {
        $UI.Phase = ([int]$UI.Phase + 1) % 720
        $fl0 = Get-IconFlags
        if (-not $fl0.Working) { $animTimer.Stop(); Update-TrayIcon; return }
        Update-TrayIcon
        if ($UI.Shown) { foreach ($mk in @($UI.Markers)) { if ($mk.Tag -eq 'working') { try { $mk.Invalidate() } catch { } } } }
    } catch { Log "anim: $($_.Exception.Message)" 'ERR' }
})
function Write-DebugSnapshot([string]$why = 'snapshot') {
    try {
        if ($webEnabled) { foreach ($oid in @($UI.WebOpen | Where-Object { -not ([string]$_).StartsWith('local/') })) { [void]$Web.Cmds.Add(@{ Id = [string]$oid; Kind = 'mdiag'; Key = 'diag-m' + [guid]::NewGuid().ToString('N'); At = (Get-Date) }) } }     # debug: how the page holds this chat's messages (structure only)
        $chs = @(foreach ($q in @($QS.List)) { $wc0 = $Web.Chats[[string]$q.id]
            '{0}[{1}{2}{3}{4}{5}]' -f $q.id, $q.St, $(if (-not $q.Visible) { ',hidden' }), $(if ($wc0) { ',' + $(if ($wc0.Ok) { 'ok' } else { 'noPage' }) + $(if ($wc0.Working) { ',working' }) + ',' + [int]((Get-Date) - $wc0.At).TotalSeconds + 's' } else { ',noTab' }), $(if ($UI.WebOpen -contains [string]$q.id) { ',open' }), $(if (Test-Unread $q) { ',unread' }) })
        $secs = if ($QS.Layout -and $QS.Layout.sec) { (@($QS.Layout.sec) | ForEach-Object { "$($_.id):$($_.sort)$(if ($_.col) { '(col)' })" }) -join ' ' } else { '-' }
        Log ("debug {0}: panel shown={1} pinned={2} docked={3} {4}x{5} at {6},{7} zoom {8}; web ok={9} err='{10}' pass {11} ms; pushes {12}; sections {13}; chats {14}" -f $why, $UI.Shown, $UI.Pinned, $UI.Docked, $pop.Width, $pop.Height, $pop.Left, $pop.Top, $UI.Zoom, $Web.Ok, $Web.Err, $Web.Ms, $UI.WebPushes, $secs, ($chs -join ' ')) 'DEBUG'
        foreach ($q in @($QS.List | Where-Object { @($_.steps).Count -and $UI.WebOpen -contains [string]$_.id })) {     # where each open chat's steps sit (times only, no text)
            $rw = $Web.Chats[[string]$q.id]; $ms0 = if ($rw -and $rw.Msgs) { @($rw.Msgs) } else { @() }; $sb0 = Get-StepsBefore $q $ms0 $rw
            $ut = @($ms0 | Where-Object { $_.r -eq 'u' } | Select-Object -Last 3 | ForEach-Object { if ($_.at) { ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.at)).LocalDateTime.ToString('HH:mm:ss') } else { '-' } })
            Log ("debug steps {0}: quest file {1:HH:mm:ss}, sb={2}, last user msgs at {3}, msgs {4}" -f $q.id, $q.Upd, $sb0.Sb, ($ut -join ' '), $ms0.Count)
        }
    } catch { Log "debug snapshot: $($_.Exception.Message)" 'WARN' }
}
function Write-Heartbeat([string]$why = 'heartbeat') {
    try {
        $me = [Diagnostics.Process]::GetCurrentProcess(); $me.Refresh()
        $gdi = [ClaudeTray.Native]::GetGuiResources($me.Handle, 0); $usr = [ClaudeTray.Native]::GetGuiResources($me.Handle, 1)
        Log ("{0}: mem {1} MB, GDI {2}, USER {3}, handles {4}, quests {5} (visible {6}), running steps {7}, shown {8}, docked {9}, watcher scan {10} ms, page '{11}', anim {12} badge '{13}' phase {14}, web {15} ({16} chats, {17} ms{18})" -f $why, [int]($me.WorkingSet64 / 1MB), $gdi, $usr, $me.HandleCount, @($QS.List).Count, @($QS.List | Where-Object { $_.Visible }).Count, $QS.Running.Count, $UI.Shown, $UI.Docked, $Probe.Ms, (Get-PageLabel $Probe.Page), $animTimer.Enabled, (Get-Badge), $UI.Phase, $(if ($webEnabled) { $Web.Ok } else { 'off' }), $Web.Chats.Count, $Web.Ms, $(if ($Web.Err) { ', ' + $Web.Err } else { '' }))
        if ($gdi -gt 4000 -or $usr -gt 4000) { Log "heartbeat: GDI/USER objects high - leak?" 'WARN' }
    } catch { Log "heartbeat: $($_.Exception.Message)" 'WARN' }
}
function Sync-Anim { $fl1 = Get-IconFlags; if ($fl1.Working -and -not $animTimer.Enabled) { $animTimer.Start() } elseif (-not $fl1.Working) { Update-TrayIcon } }
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = [int]$Cfg.pollSeconds * 1000
$pollTimer.add_Tick({ try { $UI.LastPollAt = Get-Date; Invoke-Poll; $UI.Polls = [int]$UI.Polls + 1; if ($UI.Polls % 4 -eq 1) { Write-Heartbeat } } catch { Log "poll: $($_.Exception.Message)" 'ERR' } })

try {
    foreach ($qr in $QuestRoots) { foreach ($sub in 'quests', 'results') { $d = Join-Path $qr $sub; if (-not (Test-Path $d)) { try { New-Item -ItemType Directory -Path $d -Force | Out-Null } catch { } } } }
    Log ("Quest roots: {0}" -f ($QuestRoots -join ' | '))
    foreach ($qx in Read-Quests) { foreach ($rs in @($qx.Res.steps)) { if ($rs.status -eq 'running') { Set-StepResult $qx ([int]$rs.n) @{ status = 'done'; ended = (Get-Iso (Get-Date)); out = 'tray restarted while this step ran - no output captured' }; Log "step $($qx.id)#$($rs.n) was running at restart; marked done" 'WARN' } } }
    $UI.Booted = $false
    Refresh-Quests $false
    $tray.Visible = $true
    Update-Usage
    Refresh-Quests $false
    try { Clear-OldTemp } catch { }
    Log ("Quests: {0} ({1})" -f @($QS.List).Count, (($QS.List | ForEach-Object { "$($_.id)=$($_.St)" }) -join ', '))
    Init-WebUi
    $uiTimer.Start(); $pollTimer.Start(); $questTimer.Start()
    Write-Heartbeat 'start'
    Log ("Tray running (poll {0}s, icon {1}px, apps light {2})" -f $Cfg.pollSeconds, [System.Windows.Forms.SystemInformation]::SmallIconSize.Width, $AppsLight)
    [System.Windows.Forms.Application]::Run()
} catch {
    Log ("FATAL tray: {0} @ line {1}" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) 'ERR'
} finally {
    try { $tray.Visible = $false; $tray.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    Log 'Tray stopped'
    try { $Probe.Stop = $true; $Web.Stop = $true } catch { }
    [Environment]::Exit(0)                             # don't wait for the watcher thread
}
