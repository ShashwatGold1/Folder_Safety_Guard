# guard-badges.ps1 - the badges Explorer shows on protected folders and files, bottom left:
#   green lock = protected, orange lock with the left leg open = editing, red ! = partly locked
#   (a file guard couldn't lock yet, or a folder that holds one).
# guard writes what to show into badges.txt (next to config.json) whenever that changes. A small
# helper inside Explorer (badges\guard-badges-<tag>.dll, built and registered by the installer)
# reads it. Dot-sourced by guard-core.ps1. A badge must never stop guard: every failure here is
# ignored. Keep this file pure ASCII.

$script:BadgeKey  = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\ShellIconOverlayIdentifiers'
# two leading spaces: Explorer uses only the first 15 overlays, sorted by name (Google Drive does the same)
$script:BadgeIds  = [ordered]@{
    protected = @('  guard protected', '{EA217AC8-DBCE-4840-A3D5-2B523734FE42}')
    editing   = @('  guard editing',   '{63881172-D367-4037-A670-EDA74C5CDCA4}')
    partly    = @('  guard partly',    '{6E58515F-415E-47BD-91E2-68E340A81040}')
}
$script:BadgeLook = 'lock-1'   # change it when the pictures change: new file names, so Explorer drops its cached ones
$script:DotNet    = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'

# ---- the list Explorer's helper reads ----------------------------------------------------
#   protected|C:\Shots           a protected folder (everything inside: green)
#   editing|C:\Docs              a folder in edit (everything inside: orange)
#   skip|C:\Shots|*.tmp          never locked there: no badge
#   open|C:\Shots\a.png          not locked yet: red, and red on every folder that holds it
function Get-GuardBadgeListPath {
    if (-not $script:GuardConfigPath) { return $null }
    return Join-Path (Split-Path $script:GuardConfigPath -Parent) 'badges.txt'
}
function Read-GuardBadgeLines([string]$File) {
    if (-not (Test-Path -LiteralPath $File)) { return @() }
    return @([IO.File]::ReadAllLines($File) | Where-Object { $_ })
}
function Test-GuardBadgeUnder([string]$Path, [string[]]$Folders) {
    foreach ($d in $Folders) { if ($Path.StartsWith($d.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
    return $false
}

function Write-GuardBadges {
    # folder + skip lines from the config; 'open' lines stay for protected folders not in edit
    param($Config)
    try {
        $file = Get-GuardBadgeListPath; if (-not $file) { return }
        $old = Read-GuardBadgeLines $file
        $new = New-Object Collections.Generic.List[string]; $locked = @()
        foreach ($f in @($Config.folders)) {
            if (-not $f.path) { continue }
            if ($f.editing) { $new.Add("editing|$($f.path)"); continue }
            $new.Add("protected|$($f.path)"); $locked += $f.path
            $own = @(); if ($f.skip) { $own = @($f.skip) }
            foreach ($p in @($script:BuiltinSkip + $own | Select-Object -Unique)) { $new.Add("skip|$($f.path)|$p") }
        }
        foreach ($l in $old) { if ($l.StartsWith('open|') -and (Test-GuardBadgeUnder $l.Substring(5) $locked)) { $new.Add($l) } }
        Save-GuardBadgeLines $file $old $new
    } catch { }
}

function Set-GuardBadgeOpen {
    # the files under $Folder guard couldn't lock: replaces what the list had for that folder
    param([string]$Folder, [string[]]$Paths = @())
    try {
        $file = Get-GuardBadgeListPath; if (-not $file) { return }
        $old = Read-GuardBadgeLines $file
        $new = New-Object Collections.Generic.List[string]
        foreach ($l in $old) { if (-not ($l.StartsWith('open|') -and (Test-GuardBadgeUnder $l.Substring(5) @($Folder)))) { $new.Add($l) } }
        foreach ($p in $Paths) { if ($p) { $new.Add("open|$p") } }
        Save-GuardBadgeLines $file $old $new
    } catch { }
}

function Set-GuardBadgeFile {
    # one file: locked now (-Locked) or not
    param([string]$Path, [switch]$Locked)
    try {
        $file = Get-GuardBadgeListPath; if (-not $file) { return }
        $old = Read-GuardBadgeLines $file
        $new = New-Object Collections.Generic.List[string]
        foreach ($l in $old) { if ($l -ine "open|$Path") { $new.Add($l) } }
        if (-not $Locked) { $new.Add("open|$Path") }
        Save-GuardBadgeLines $file $old $new
    } catch { }
}

function Save-GuardBadgeLines([string]$File, [string[]]$Old, $New) {
    $New = @($New)
    if (($Old -join "`n") -ceq ($New -join "`n")) { return }
    $dir = Split-Path $File -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # write aside, then swap in: Explorer never reads half a list
    $tmp = "$File.tmp"
    [IO.File]::WriteAllLines($tmp, [string[]]$New)
    Move-Item -LiteralPath $tmp -Destination $File -Force
    Update-GuardBadgeView $Old $New
}

function Update-GuardBadgeView([string[]]$Old, [string[]]$New) {
    # tell Explorer which items to draw again: a folder whose state changed (and everything in
    # it), a file that became locked or not (and the folders above it, up to the protected one)
    if (-not (Test-GuardBadgesOn)) { return }
    $changed = @(@($Old | Where-Object { $New -cnotcontains $_ }) + @($New | Where-Object { $Old -cnotcontains $_ }))
    $roots = @(); $items = @()
    foreach ($l in $changed) {
        $p = $l -split '\|'
        if ($p[0] -eq 'open') { $items += $p[1] } elseif ($p.Count -ge 2) { $roots += $p[1] }
    }
    $all = @(@($Old) + @($New) | Where-Object { $_ -match '^(protected|editing)\|' } | ForEach-Object { ($_ -split '\|')[1] })
    $dirs = @(); $one = @()
    foreach ($r in ($roots | Select-Object -Unique)) {
        $one += $r; $dirs += $r
        $dirs += @(Get-ChildItem -LiteralPath $r -Recurse -Directory -Force -ErrorAction SilentlyContinue | Select-Object -First 2000 | ForEach-Object { $_.FullName })
    }
    foreach ($i in ($items | Select-Object -Unique)) {
        $one += $i
        $root = $all | Where-Object { $i.StartsWith($_.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        $up = Split-Path $i -Parent
        while ($root -and $up -and ($up.Length -ge $root.Length)) { $one += $up; $up = Split-Path $up -Parent }
    }
    if (-not ($one + $dirs)) { return }
    Start-Sleep -Milliseconds 300   # the helper reads the list again at most 4 times a second
    Add-GuardShellNotify
    foreach ($p in ($one | Select-Object -Unique)) { [GuardNative.Shell]::SHChangeNotify(0x2000, 0x5, $p, [IntPtr]::Zero) }   # SHCNE_UPDATEITEM
    foreach ($p in ($dirs | Select-Object -Unique)) { [GuardNative.Shell]::SHChangeNotify(0x1000, 0x5, $p, [IntPtr]::Zero) } # SHCNE_UPDATEDIR
}

function Add-GuardShellNotify {
    if (-not ('GuardNative.Shell' -as [type])) {
        Add-Type -Namespace GuardNative -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int e, uint f, string a, IntPtr b);'
    }
}

# ---- the helper inside Explorer ------------------------------------------------------------
function Test-GuardBadgesOn {
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$script:BadgeKey\$($script:BadgeIds.protected[0])")
    if ($k) { $k.Close(); return $true }
    return $false
}

function Get-GuardBadgeDll([string]$Dir) {
    # the file name carries a short hash of the helper's code + look: a new version gets a new
    # file, because Explorer keeps the old one open until it restarts
    $sha = [Security.Cryptography.SHA256]::Create()
    $h = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:BadgeCode + $script:BadgeLook))
    $tag = -join ($h[0..3] | ForEach-Object { $_.ToString('x2') })
    return (Join-Path $Dir "badges\guard-badges-$tag.dll")
}

function Test-GuardBadgesFor([string]$Dll) {
    # registered, and every badge points at this exact file
    if (-not (Test-Path -LiteralPath $Dll)) { return $false }
    foreach ($b in $script:BadgeIds.Values) {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("$script:BadgeKey\$($b[0])")
        if (-not $k) { return $false }
        try { if ([string]$k.GetValue('') -ne $b[1]) { return $false } } finally { $k.Close() }
        $c = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey("CLSID\$($b[1])\InprocServer32")
        if (-not $c) { return $false }
        try { $cb = [string]$c.GetValue('CodeBase') } finally { $c.Close() }
        try { if (([uri]$cb).LocalPath -ine $Dll) { return $false } } catch { return $false }
    }
    return $true
}

function Install-GuardBadges {
    # Build and register the helper, draw the three badges. Returns 'same' (nothing to do) or
    # 'new' (Explorer must restart to load it). Throws when something fails. Admin only.
    param([string]$Dir)
    $dll = Get-GuardBadgeDll $Dir
    if (Test-GuardBadgesFor $dll) { return 'same' }
    $bdir = Split-Path $dll -Parent
    if (-not (Test-Path -LiteralPath $bdir)) { New-Item -ItemType Directory -Path $bdir -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $dll)) {
        $cs = Join-Path $env:TEMP ('guard-badges-' + [guid]::NewGuid().ToString('N') + '.cs')
        try {
            [IO.File]::WriteAllText($cs, $script:BadgeCode)
            $out = & (Join-Path $script:DotNet 'csc.exe') /nologo /target:library /optimize "/out:$dll" $cs 2>&1
            if ($LASTEXITCODE -ne 0) { throw "couldn't build the badge helper: $out" }
        } finally { Remove-Item -LiteralPath $cs -Force -ErrorAction SilentlyContinue }
    }
    $base = $dll -replace '\.dll$', ''
    Save-GuardBadgeIcon "$base-protected.ico" '#188038' 'closed'
    Save-GuardBadgeIcon "$base-editing.ico"   '#c45a0a' 'open'
    Save-GuardBadgeIcon "$base-partly.ico"    '#c5221f' 'bang'
    $out = & (Join-Path $script:DotNet 'RegAsm.exe') /codebase /nologo /silent $dll 2>&1
    if ($LASTEXITCODE -ne 0) { throw "couldn't register the badge helper: $out" }
    $k = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($script:BadgeKey)
    try { foreach ($b in $script:BadgeIds.Values) { $s = $k.CreateSubKey($b[0]); $s.SetValue('', $b[1]); $s.Close() } } finally { $k.Close() }
    # older helpers: gone now, or (still open in Explorer) when the PC restarts
    foreach ($o in @(Get-ChildItem -LiteralPath $bdir -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith((Split-Path $base -Leaf)) })) {
        Remove-GuardFileLater $o.FullName
    }
    return 'new'
}

function Remove-GuardBadges {
    # Unregister the helper and take the badges off. Explorer keeps the DLL open until it
    # restarts: its files go when the PC restarts. Admin only.
    param([string]$Dir)
    $had = Test-GuardBadgesOn
    $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($script:BadgeKey, $true)
    if ($k) { try { foreach ($b in $script:BadgeIds.Values) { $k.DeleteSubKeyTree($b[0], $false) } } finally { $k.Close() } }
    $bdir = Join-Path $Dir 'badges'
    foreach ($d in @(Get-ChildItem -LiteralPath $bdir -Filter 'guard-badges-*.dll' -ErrorAction SilentlyContinue)) {
        & (Join-Path $script:DotNet 'RegAsm.exe') /unregister /nologo /silent $d.FullName 2>&1 | Out-Null
    }
    foreach ($o in @(Get-ChildItem -LiteralPath $bdir -Force -ErrorAction SilentlyContinue)) { Remove-GuardFileLater $o.FullName }
    if (Test-Path -LiteralPath $bdir) { Remove-GuardFileLater $bdir }
    try { Add-GuardShellNotify; [GuardNative.Shell]::SHChangeNotify(0x08000000, 0, $null, [IntPtr]::Zero) } catch { }   # SHCNE_ASSOCCHANGED: redraw icons
    return $had
}

function Remove-GuardFileLater([string]$Path, [switch]$AtRestart) {
    # delete now; if Windows says it is in use, delete it when the PC restarts (-AtRestart: only then)
    if (-not $AtRestart) { try { Remove-Item -LiteralPath $Path -Force -Recurse -ErrorAction Stop; return } catch { } }
    try {
        if (-not ('GuardNative.Files' -as [type])) {
            Add-Type -Namespace GuardNative -Name Files -MemberDefinition '[DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] public static extern bool MoveFileEx(string a, string b, int f);'
        }
        [GuardNative.Files]::MoveFileEx($Path, $null, 4) | Out-Null   # MOVEFILE_DELAY_UNTIL_REBOOT
    } catch { }
}

function Restart-GuardExplorer {
    # Explorer loads its overlay helpers only when it starts. Windows starts it again by itself.
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 24; $i++) { Start-Sleep -Milliseconds 250; if (Get-Process explorer -ErrorAction SilentlyContinue) { return } }
    Start-Process explorer.exe
}

# ---- the pictures -------------------------------------------------------------------------
function Save-GuardBadgeIcon([string]$Path, [string]$Color, [string]$Kind) {
    # an .ico with a PNG per size: transparent, the badge in the bottom-left corner; Explorer
    # lays it over the item's own icon. $Kind: closed / open (left leg off the body) / bang (!)
    Add-Type -AssemblyName System.Drawing
    $fill = [Drawing.ColorTranslator]::FromHtml($Color)
    $sizes = 256, 64, 48, 32, 16
    $pngs = foreach ($s in $sizes) {
        $bmp = New-Object Drawing.Bitmap $s, $s
        $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
        $d = [Math]::Round($s * 0.42); $x = [Math]::Round($s * 0.02); $y = $s - $d - [Math]::Round($s * 0.02)
        # white ring, coloured disc
        $g.FillEllipse([Drawing.Brushes]::White, $x, $y, $d, $d)
        $r = [Math]::Max(1, $d * 0.09)
        $b = New-Object Drawing.SolidBrush $fill
        $g.FillEllipse($b, $x + $r, $y + $r, $d - 2 * $r, $d - 2 * $r)
        $cx = $x + $d / 2; $cy = $y + $d / 2
        if ($Kind -eq 'bang') {
            $bw = [Math]::Max(1.5, $d * 0.105); $top = $y + $d * 0.24; $len = $d * 0.34
            $pen = New-Object Drawing.Pen ([Drawing.Color]::White), ([float]$bw); $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
            $g.DrawLine($pen, [float]$cx, [float]$top, [float]$cx, [float]($top + $len))
            $dr = $bw * 0.62
            $g.FillEllipse([Drawing.Brushes]::White, [float]($cx - $dr), [float]($y + $d * 0.73 - $dr), [float](2 * $dr), [float](2 * $dr))
        } else {
            # padlock: body + shackle; 'open' = the same lock, only the left leg stops short of the body
            $bw = $d * 0.40; $bh = $d * 0.30; $bx = $cx - $bw / 2; $by = $cy - $bh * 0.15
            $g.FillRectangle([Drawing.Brushes]::White, [float]$bx, [float]$by, [float]$bw, [float]$bh)
            $pen = New-Object Drawing.Pen ([Drawing.Color]::White), ([float][Math]::Max(1, $d * 0.075))
            $sw = $bw * 0.62; $sh = $bh * 1.15; $sx = $cx - $sw / 2; $sy = $by - $sh * 0.62
            $leftEnd = $by + 1; if ($Kind -eq 'open') { $leftEnd = $by - [Math]::Max(1, $d * 0.06) }
            $g.DrawArc($pen, [float]$sx, [float]$sy, [float]$sw, [float]$sh, 180, 180)
            $g.DrawLine($pen, [float]$sx, [float]($sy + $sh / 2), [float]$sx, [float]$leftEnd)
            $g.DrawLine($pen, [float]($sx + $sw), [float]($sy + $sh / 2), [float]($sx + $sw), [float]($by + 1))
        }
        $pen.Dispose(); $b.Dispose(); $g.Dispose()
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); , $ms.ToArray()
    }
    $fs = [IO.File]::Create($Path); $w = New-Object IO.BinaryWriter $fs
    try {
        $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
        $off = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $wb = [byte]($sizes[$i] % 256)   # 256 is written as 0
            $w.Write($wb); $w.Write($wb); $w.Write([byte]0); $w.Write([byte]0)
            $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$off)
            $off += $pngs[$i].Length
        }
        foreach ($p in $pngs) { $w.Write($p) }
    } finally { $w.Close() }
}

# ---- the helper's code (C# 5, built with the .NET Framework compiler every Windows has) ----
$script:BadgeCode = @'
// guard badges: three Explorer icon overlays - protected, editing, partly.
// Explorer asks each overlay "is this item yours?" for every file and folder it shows. The
// answer comes from %ProgramData%\guard\badges.txt (written by guard), kept in memory and read
// again at most 4 times a second, only when the file changed. Any problem: no badge.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace GuardBadges
{
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0C6C4200-C589-11D0-999A-00C04FD655E1")]
    public interface IShellIconOverlayIdentifier
    {
        [PreserveSig] int IsMemberOf([MarshalAs(UnmanagedType.LPWStr)] string path, uint attributes);
        [PreserveSig] int GetOverlayInfo(IntPtr iconFileBuffer, int iconFileBufferSize, out int iconIndex, out uint flags);
        [PreserveSig] int GetPriority(out int priority);
    }

    class Root { public string Path; public string State; public List<Regex> Skip = new List<Regex>(); }

    static class BadgeList
    {
        static readonly string Dll = typeof(BadgeList).Assembly.Location;
        static readonly string ListFile =Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "guard\\badges.txt");
        static readonly object Gate = new object();
        static List<Root> roots = new List<Root>();
        static HashSet<string> open = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        static DateTime stamp = DateTime.MinValue, checkedAt = DateTime.MinValue;
        const StringComparison NoCase = StringComparison.OrdinalIgnoreCase;

        public static string IconFor(string state)
        {
            return Path.Combine(Path.GetDirectoryName(Dll), Path.GetFileNameWithoutExtension(Dll) + "-" + state + ".ico");
        }

        static Regex Glob(string g)
        {
            return new Regex("^" + Regex.Escape(g).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        }

        static void Reload()
        {
            if ((DateTime.UtcNow - checkedAt).TotalMilliseconds < 250) return;
            checkedAt = DateTime.UtcNow;
            DateTime t = File.Exists(ListFile) ? File.GetLastWriteTimeUtc(ListFile) : DateTime.MinValue;
            if (t == stamp) return;
            string[] lines;
            try { lines = t == DateTime.MinValue ? new string[0] : File.ReadAllLines(ListFile); }
            catch { return; }   // being swapped in right now: next time
            stamp = t;
            var r = new List<Root>();
            var byPath = new Dictionary<string, Root>(StringComparer.OrdinalIgnoreCase);
            var o = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string line in lines)
            {
                string[] p = line.Split('|');
                if (p.Length == 2 && (p[0] == "protected" || p[0] == "editing"))
                {
                    var x = new Root(); x.Path = p[1].TrimEnd('\\'); x.State = p[0];
                    r.Add(x); byPath[x.Path] = x;
                }
                else if (p.Length == 3 && p[0] == "skip")
                {
                    Root x;
                    if (byPath.TryGetValue(p[1].TrimEnd('\\'), out x)) x.Skip.Add(Glob(p[2]));
                }
                else if (p.Length == 2 && p[0] == "open") o.Add(p[1]);
            }
            r.Sort((a, b) => b.Path.Length.CompareTo(a.Path.Length));   // the innermost folder wins
            roots = r; open = o;
        }

        public static string StateOf(string path, bool isDir)
        {
            lock (Gate)
            {
                Reload();
                Root root = null;
                foreach (var x in roots)
                    if (path.Equals(x.Path, NoCase) || path.StartsWith(x.Path + "\\", NoCase)) { root = x; break; }
                if (root == null) return null;
                if (root.State == "editing") return "editing";
                if (isDir)
                {
                    string inside = path.TrimEnd('\\') + "\\";
                    foreach (string f in open) if (f.StartsWith(inside, NoCase)) return "partly";
                    return "protected";
                }
                string name = Path.GetFileName(path);
                foreach (Regex g in root.Skip) if (g.IsMatch(name)) return null;   // never locked
                return open.Contains(path) ? "partly" : "protected";
            }
        }
    }

    public abstract class Badge : IShellIconOverlayIdentifier
    {
        protected abstract string State { get; }
        const int S_OK = 0, S_FALSE = 1, E_FAIL = unchecked((int)0x80004005);

        public int IsMemberOf(string path, uint attributes)
        {
            try
            {
                if (string.IsNullOrEmpty(path)) return S_FALSE;
                return BadgeList.StateOf(path, (attributes & 0x10) != 0) == State ? S_OK : S_FALSE;   // 0x10 = folder
            }
            catch { return S_FALSE; }   // never break Explorer
        }

        public int GetOverlayInfo(IntPtr iconFileBuffer, int iconFileBufferSize, out int iconIndex, out uint flags)
        {
            iconIndex = 0; flags = 0;
            try
            {
                char[] chars = (BadgeList.IconFor(State) + "\0").ToCharArray();
                if (chars.Length > iconFileBufferSize) return E_FAIL;
                Marshal.Copy(chars, 0, iconFileBuffer, chars.Length);
                flags = 0x1 | 0x2;   // ISIOI_ICONFILE | ISIOI_ICONINDEX
                return S_OK;
            }
            catch { return E_FAIL; }
        }

        public int GetPriority(out int priority) { priority = 0; return S_OK; }
    }

    [ComVisible(true), Guid("EA217AC8-DBCE-4840-A3D5-2B523734FE42"), ClassInterface(ClassInterfaceType.None)]
    public class ProtectedBadge : Badge { protected override string State { get { return "protected"; } } }

    [ComVisible(true), Guid("63881172-D367-4037-A670-EDA74C5CDCA4"), ClassInterface(ClassInterfaceType.None)]
    public class EditingBadge : Badge { protected override string State { get { return "editing"; } } }

    [ComVisible(true), Guid("6E58515F-415E-47BD-91E2-68E340A81040"), ClassInterface(ClassInterfaceType.None)]
    public class PartlyBadge : Badge { protected override string State { get { return "partly"; } } }
}
'@
