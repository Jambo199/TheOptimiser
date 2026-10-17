<#
    ThE OptImiseR  -  a single-file Windows optimiser / debloater.

    The tweak data in catalog.json was built from the open-source tools the author
    reverse-engineered and deduplicated (winutil, Win11Debloat, Bloatynosy, PC-Tuning,
    and others). Three things found in those tools were deliberately left out:
      * a system-wide proxy pointing at a Russian anti-censorship server (SophiApp),
      * a swap of a Windows system DLL with an old 2019 copy (awesome-windows11),
      * trusting a "Microsoft Testing Root" certificate (Revision Tool).

    Nothing is changed on your PC until you select items and confirm. Every change is
    recorded so it can be undone from the Undo menu.
#>
[CmdletBinding()]
param(
    [switch]$Launch,        # internal: skip intro/questions (used after elevation relaunch)
    [string]$WinBuild,      # internal: carried across an elevation relaunch
    [switch]$NoAnimation,   # skip the summoning animation
    [switch]$SelfTest,      # validate catalog + dry-run a reg apply/undo, then exit
    [switch]$AsLibrary,     # define functions only (for testing); don't run the UI
    [switch]$NoGui,         # use the classic text menu instead of the GUI
    [string]$GuiPreview,    # render the GUI to this PNG path (no window), then exit
    [switch]$DemoBanner     # force-show the "update available" banner once, to preview it
)

$ErrorActionPreference = 'Stop'
$script:Root      =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { try { Split-Path -Parent ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch { (Get-Location).Path } }
$script:CatalogPath = Join-Path $Root 'catalog.json'
$script:UndoDir     = Join-Path $env:LOCALAPPDATA 'TheOptimiser'
$script:JournalDir  = Join-Path $UndoDir 'journals'
$script:BackupDir   = Join-Path $UndoDir 'backups'
$script:UpdateConfig = Join-Path $UndoDir 'update.json'
$script:CurrentJournal = $null
$script:Version = '2.1.0'

# ---------------------------------------------------------------- helpers ----
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Get-Catalog {
    if (-not (Test-Path $CatalogPath)) { throw "catalog.json not found next to the script ($CatalogPath)." }
    Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Ensure-RegDrives {
    if (-not (Get-PSDrive HKCR -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKCR -PSProvider Registry -Root HKEY_CLASSES_ROOT -Scope Script | Out-Null }
    if (-not (Get-PSDrive HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -Scope Script | Out-Null }
}

# ---- per-operation journals (transactional apply / revert) ----
# One Apply = one operation = one journal file. Changes are recorded as they happen;
# if the operation aborts, the recorded items are rolled back and the journal discarded;
# on success the journal is written atomically and can be reverted later as a unit.
function New-Journal($title) {
    $script:CurrentJournal = [ordered]@{
        op      = [guid]::NewGuid().ToString('N').Substring(0,12)
        title   = "$title"
        started = (Get-Date).ToString('o')
        items   = New-Object System.Collections.Generic.List[object]
    }
    return $script:CurrentJournal
}

# Record one reversible before-state. Feeds the open operation, or stands alone if none is open.
function Add-UndoEntry($obj) {
    if ($script:CurrentJournal) { [void]$script:CurrentJournal.items.Add($obj); return }
    New-Journal 'ad-hoc change' | Out-Null
    [void]$script:CurrentJournal.items.Add($obj)
    Complete-Journal | Out-Null
}

# Write the open operation to disk atomically (temp + move) and close it. Returns the file path.
function Complete-Journal {
    $j = $script:CurrentJournal; $script:CurrentJournal = $null
    if (-not $j -or $j.items.Count -eq 0) { return $null }
    if (-not (Test-Path $JournalDir)) { New-Item -ItemType Directory -Path $JournalDir -Force | Out-Null }
    $j.completed = (Get-Date).ToString('o')
    $file = Join-Path $JournalDir ('op_{0:yyyyMMdd_HHmmss}_{1}.json' -f (Get-Date), $j.op)
    $tmp  = "$file.tmp"
    ($j | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $file -Force
    return $file
}

# Reverse one list of recorded before-states (newest first). Returns how many reverted.
function Undo-JournalItems($items) {
    $arr = @($items | ForEach-Object { $_ })   # normalize List/array/scalar -> object[]
    $n = 0
    for ($i = $arr.Count - 1; $i -ge 0; $i--) {
        $e = $arr[$i]
        try {
            switch ($e.kind) {
                'registry'       { Undo-RegValue $e; $n++ }
                'service'        { Set-Service -Name $e.name -StartupType $e.prev -ErrorAction SilentlyContinue; $n++ }
                'file-move'      { if (Test-Path -LiteralPath $e.backup) {
                                       $dir = Split-Path -Parent $e.path
                                       if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue | Out-Null }
                                       Move-Item -LiteralPath $e.backup -Destination $e.path -Force; $n++ } }
                'regkey-export'  { if (Test-Path -LiteralPath $e.backup) { & reg import "$($e.backup)" *>$null; $n++ } }
                'appx'           { }   # reinstall from Store; cannot auto-restore
            }
        } catch {}
    }
    return $n
}

# Run a reversible operation transactionally: on any failure, roll back and discard.
function Invoke-Op {
    param([string]$Title, [scriptblock]$Body)
    New-Journal $Title | Out-Null
    try {
        & $Body
        Complete-Journal | Out-Null
        return $true
    } catch {
        if ($script:CurrentJournal) { [void](Undo-JournalItems $script:CurrentJournal.items); $script:CurrentJournal = $null }
        throw
    }
}

# Enumerate saved operations (new journals + any legacy session logs), newest first.
function Get-Journals {
    $list = @()
    if (Test-Path $JournalDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $JournalDir -Filter 'op_*.json' -ErrorAction SilentlyContinue)) {
            try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                  $list += [pscustomobject]@{ Path=$f.FullName; Title=$j.title; Count=@($j.items).Count; When=$j.started; Legacy=$false } } catch {}
        }
    }
    foreach ($f in (Get-ChildItem -LiteralPath $UndoDir -Filter 'session_*.json' -ErrorAction SilentlyContinue)) {
        $c = @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
        $list += [pscustomobject]@{ Path=$f.FullName; Title=$f.Name; Count=$c; When=$f.LastWriteTime.ToString('o'); Legacy=$true }
    }
    $list | Sort-Object When -Descending
}

# Revert one saved operation (either format) and delete its file. Returns how many reverted.
function Invoke-JournalRevert($path) {
    if ($path -match 'session_.*\.json$') {
        $lines = Get-Content -LiteralPath $path -Encoding UTF8
        $items = @(); foreach ($ln in $lines) { if ($ln.Trim()) { try { $items += ($ln | ConvertFrom-Json) } catch {} } }
    } else {
        $items = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).items
    }
    $n = Undo-JournalItems $items
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    return $n
}

# Apply one registry value, capturing the prior state for undo. Returns $true on success.
function Set-RegValue($hive, $path, $name, $type, $value, [switch]$DryRun) {
    Ensure-RegDrives
    $full = "${hive}:\$path"
    $pname = if ($name -in '(Default)','(default)','') { '(default)' } else { $name }   # key's unnamed value
    $before = @{ kind='registry'; hive=$hive; path=$path; name=$name; existedKey=$false; existed=$false; prev=$null; prevType=$null }
    if (Test-Path -LiteralPath $full) {
        $before.existedKey = $true
        $item = Get-ItemProperty -LiteralPath $full -Name $pname -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $before.existed  = $true
            $before.prev     = $item.$pname
        }
    }
    if ($DryRun) { return $before }
    if (-not $before.existedKey) { New-Item -Path $full -Force | Out-Null }
    # Coerce value to the declared type
    $v = switch ($type) {
        'DWord'        { [int64]$value }
        'QWord'        { [int64]$value }
        'Binary'       { [byte[]]($value -split '[,\s]+' | Where-Object { $_ } | ForEach-Object { [convert]::ToByte($_,16) }) }
        default        { [string]$value }
    }
    New-ItemProperty -LiteralPath $full -Name $pname -PropertyType $type -Value $v -Force | Out-Null
    Add-UndoEntry $before
    return $before
}

function Undo-RegValue($e) {
    Ensure-RegDrives
    $full = "$($e.hive):\$($e.path)"
    $pname = if ($e.name -in '(Default)','(default)','') { '(default)' } else { $e.name }
    if (-not $e.existed) {
        # value did not exist before -> remove it
        if (Test-Path -LiteralPath $full) {
            Remove-ItemProperty -LiteralPath $full -Name $pname -ErrorAction SilentlyContinue }
    } else {
        if (-not (Test-Path -LiteralPath $full)) { New-Item -Path $full -Force | Out-Null }
        Set-ItemProperty -LiteralPath $full -Name $pname -Value $e.prev -ErrorAction Stop
    }
}

function New-RestorePointSafe {
    try {
        Write-Host "  Creating a system restore point (this can take a minute)..." -ForegroundColor DarkCyan
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction SilentlyContinue
        Checkpoint-Computer -Description "ThE OptImiseR" -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Host "  Restore point created." -ForegroundColor Green
    } catch {
        Write-Host "  Could not create a restore point: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "  (System Protection may be off, or one was made in the last 24h.)" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------- signed updates (minisign) -
# Pure-PowerShell Ed25519 verification (Windows PowerShell 5.1 / .NET Framework has
# no Ed25519 primitive) so update manifests can be verified offline, exactly as
# eclean does with minisign. RFC 8032, edwards25519, extended homogeneous coords.
$script:Ed = $null
function EdMod($a) { $p = $script:Ed.p; $r = $a % $p; if ($r -lt 0) { $r + $p } else { $r } }
function EdInv($a) { [bigint]::ModPow((EdMod $a), $script:Ed.p - 2, $script:Ed.p) }
function EdRecoverX($y, $sign) {    # point decompression: recover x from y + sign bit
    $p = $script:Ed.p; $d = $script:Ed.d
    $y2 = EdMod ($y*$y); $u = EdMod ($y2 - 1); $v = EdMod ($d*$y2 + 1)
    $x2 = EdMod ($u * (EdInv $v))
    if ($x2 -eq 0) { if ($sign -eq 1) { return $null } else { return [bigint]0 } }
    $x = [bigint]::ModPow($x2, ($p+3)/8, $p)                 # p = 5 (mod 8): candidate root a^((p+3)/8)
    if ((EdMod ($x*$x - $x2)) -ne 0) { $x = EdMod ($x * [bigint]::ModPow([bigint]2, ($p-1)/4, $p)) }  # * sqrt(-1)
    if ((EdMod ($x*$x - $x2)) -ne 0) { return $null }
    if (($x % 2) -ne $sign) { $x = EdMod (-$x) }
    return $x
}
function Get-Ed {
    if ($script:Ed) { return $script:Ed }
    $p = [bigint]::Pow(2,255) - 19
    $L = [bigint]::Pow(2,252) + [bigint]::Parse('27742317777372353535851937790883648493')
    $script:Ed = @{ p=$p; L=$L }
    $script:Ed.d = EdMod ([bigint]-121665 * (EdInv ([bigint]121666)))
    $By = EdMod ([bigint]4 * (EdInv ([bigint]5)))
    $Bx = EdRecoverX $By ([bigint]0)
    $script:Ed.B = @($Bx, $By, [bigint]1, (EdMod ($Bx*$By)))
    return $script:Ed
}
function Add-EdPoints($P, $Q) {    # extended coords, twisted Edwards a=-1
    $d = $script:Ed.d
    $A = EdMod (($P[1]-$P[0]) * ($Q[1]-$Q[0]))
    $B = EdMod (($P[1]+$P[0]) * ($Q[1]+$Q[0]))
    $C = EdMod ($P[3] * 2 * $d * $Q[3])
    $D = EdMod ($P[2] * 2 * $Q[2])
    $E1 = $B - $A; $F = $D - $C; $G = $D + $C; $H = $B + $A
    @((EdMod ($E1*$F)), (EdMod ($G*$H)), (EdMod ($F*$G)), (EdMod ($E1*$H)))
}
function Mul-EdPoint($s, $P) {     # scalar * point, double-and-add (MSB first)
    $R = @([bigint]0, [bigint]1, [bigint]1, [bigint]0)   # identity
    $k = $s; $bits = @(); while ($k -gt 0) { $bits += [int]($k % 2); $k = [bigint]($k / 2) }
    [array]::Reverse($bits)
    foreach ($b in $bits) { $R = Add-EdPoints $R $R; if ($b) { $R = Add-EdPoints $R $P } }
    return $R
}
function EdLE($bytes) { $acc=[bigint]0; for ($i=$bytes.Length-1; $i -ge 0; $i--) { $acc = $acc*256 + $bytes[$i] }; $acc }
function Test-Ed25519($pub, $msg, $sig) {   # pub:32 bytes, sig:64 bytes, msg:byte[]
    try {
        $E = Get-Ed; $L = $E.L; $mask = [bigint]::Pow(2,255) - 1
        if ($pub.Length -ne 32 -or $sig.Length -ne 64) { return $false }
        $ay = (EdLE $pub) -band $mask; $asign = [bigint](($pub[31] -shr 7) -band 1)
        $ax = EdRecoverX $ay $asign; if ($null -eq $ax) { return $false }
        $A = @($ax, $ay, [bigint]1, (EdMod ($ax*$ay)))
        $ry = (EdLE $sig[0..31]) -band $mask; $rsign = [bigint](($sig[31] -shr 7) -band 1)
        $rx = EdRecoverX $ry $rsign; if ($null -eq $rx) { return $false }
        $R = @($rx, $ry, [bigint]1, (EdMod ($rx*$ry)))
        $S = EdLE $sig[32..63]; if ($S -ge $L) { return $false }
        $sha = [Security.Cryptography.SHA512]::Create()
        $buf = New-Object byte[] (64 + $msg.Length)
        [Array]::Copy($sig,0,$buf,0,32); [Array]::Copy($pub,0,$buf,32,32); if ($msg.Length) { [Array]::Copy($msg,0,$buf,64,$msg.Length) }
        $k = (EdLE ($sha.ComputeHash($buf))) % $L
        $lhs = Mul-EdPoint $S $E.B
        $rhs = Add-EdPoints $R (Mul-EdPoint $k $A)
        ((EdMod ($lhs[0]*$rhs[2])) -eq (EdMod ($rhs[0]*$lhs[2]))) -and
        ((EdMod ($lhs[1]*$rhs[2])) -eq (EdMod ($rhs[1]*$lhs[2])))
    } catch { $false }
}

# Verify a minisign signature over message bytes. pubB64 = the key line of a .pub file;
# sigB64 = the base64 (2nd) line of a .minisig file. Legacy 'Ed' (non-prehashed) only.
# shortcut: prehashed 'ED' (BLAKE2b) unsupported; sign manifests with minisign's legacy mode.
function Test-MinisignSignature {
    param([string]$PubB64, [string]$SigB64, [byte[]]$Message)
    try {
        $pk = [Convert]::FromBase64String($PubB64.Trim())
        $sg = [Convert]::FromBase64String($SigB64.Trim())
        if ($pk.Length -ne 42 -or $sg.Length -ne 74) { return @{ ok=$false; why='bad key/sig length' } }
        $palg = [Text.Encoding]::ASCII.GetString($pk[0..1]); $salg = [Text.Encoding]::ASCII.GetString($sg[0..1])
        if ($salg -ne 'Ed') { return @{ ok=$false; why="unsupported sig algorithm '$salg' (need legacy Ed)" } }
        $pkid = $pk[2..9]; $sgid = $sg[2..9]
        for ($i=0; $i -lt 8; $i++) { if ($pkid[$i] -ne $sgid[$i]) { return @{ ok=$false; why='key id mismatch' } } }
        $ok = Test-Ed25519 ([byte[]]$pk[10..41]) $Message ([byte[]]$sg[10..73])
        @{ ok=[bool]$ok; why=$(if($ok){'verified'}else{'signature does not match'}); keyid=([BitConverter]::ToString([byte[]]$pkid) -replace '-') }
    } catch { @{ ok=$false; why=$_.Exception.Message } }
}

function Get-UpdateConfig {
    if (Test-Path $UpdateConfig) { try { return Get-Content -LiteralPath $UpdateConfig -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
    return $null
}

# Check a signed update manifest: download manifest + .minisig, verify, report. Never auto-installs.
function Invoke-UpdateCheck {
    $cfg = Get-UpdateConfig
    if (-not $cfg -or -not $cfg.url -or -not $cfg.pubkey) {
        return @{ status='unconfigured'; message="No signed-update source set. Drop an update.json ({url, pubkey}) at $UpdateConfig to enable." }
    }
    try {
        $man = (Invoke-WebRequest -Uri $cfg.url -UseBasicParsing -TimeoutSec 20).Content
        $sig = (Invoke-WebRequest -Uri ($cfg.url + '.minisig') -UseBasicParsing -TimeoutSec 20).Content
        $sigLine = (@($sig -split "`n") | Where-Object { $_ -notmatch '^(untrusted|trusted) comment:' -and $_.Trim() })[0]
        $bytes = [Text.Encoding]::UTF8.GetBytes($man)
        $v = Test-MinisignSignature -PubB64 $cfg.pubkey -SigB64 $sigLine -Message $bytes
        if (-not $v.ok) { return @{ status='bad-signature'; message="Update manifest signature INVALID ($($v.why)). Ignored." } }
        $info = try { $man | ConvertFrom-Json } catch { $null }
        $ver = if ($info -and $info.version) { $info.version } else { '(signed, see manifest)' }
        $newer = Test-NewerVersion $ver $script:Version
        $msg = if ($newer) { "Update available: v$ver (you have v$script:Version). Signature verified (key $($v.keyid)). Use the banner to get it." }
               else { "You're on the latest version (v$script:Version). Signature verified." }
        return @{ status='verified'; version=$ver; newer=$newer; message=$msg; info=$info }
    } catch {
        return @{ status='error'; message="Update check failed: $($_.Exception.Message)" }
    }
}

# -------------------------------------------------------------- cleaner -------
# A disk/privacy cleaner: winapp2-style junk rules + a Revo/CCleaner-style MRU-trace
# list. File junk is deleted (freed space is not restorable - same as any cleaner);
# registry MRU keys are backed up first and are undoable from the Undo view.
function Expand-Env($s) { [Environment]::ExpandEnvironmentVariables($s) }

function Get-CleanTargets {
    $t = @(
        @{ id='temp-user';    cat='Junk files';   name='Temporary files (user)';     kind='files'; undo=$false; paths=@('%TEMP%'); desc='Your per-user temp folder. Safe to empty; apps recreate what they need.' }
        @{ id='temp-win';     cat='Junk files';   name='Temporary files (Windows)';  kind='files'; undo=$false; admin=$true; paths=@('%SystemRoot%\Temp'); desc='The system temp folder. Needs admin.' }
        @{ id='prefetch';     cat='Junk files';   name='Prefetch';                   kind='files'; undo=$false; admin=$true; paths=@('%SystemRoot%\Prefetch\*.pf'); desc='Boot/app prefetch traces. Windows rebuilds them.' }
        @{ id='crashdumps';   cat='Junk files';   name='Crash dumps';                kind='files'; undo=$false; paths=@('%LOCALAPPDATA%\CrashDumps','%SystemRoot%\Minidump'); desc='Memory dumps left by crashes.' }
        @{ id='thumbs';       cat='Junk files';   name='Thumbnail cache';            kind='files'; undo=$false; paths=@('%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db'); desc='Explorer thumbnail cache; rebuilt on demand.' }
        @{ id='wu-cache';     cat='Junk files';   name='Windows Update cache';       kind='files'; undo=$false; admin=$true; paths=@('%SystemRoot%\SoftwareDistribution\Download'); desc='Downloaded update payloads. Needs admin.' }
        @{ id='chrome-cache'; cat='Browser cache';name='Chrome cache';               kind='files'; undo=$false; paths=@('%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache','%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache'); desc='Cached web files for Chrome.' }
        @{ id='edge-cache';   cat='Browser cache';name='Edge cache';                 kind='files'; undo=$false; paths=@('%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache','%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache'); desc='Cached web files for Edge.' }
        @{ id='firefox-cache';cat='Browser cache';name='Firefox cache';              kind='files'; undo=$false; paths=@('%LOCALAPPDATA%\Mozilla\Firefox\Profiles\*\cache2'); desc='Cached web files for Firefox.' }
        @{ id='recyclebin';   cat='Junk files';   name='Recycle Bin';                kind='recyclebin'; undo=$false; desc='Permanently empties the Recycle Bin.' }
        @{ id='mru-run';      cat='Recent-items traces'; name='Run dialog history';  kind='regmru'; undo=$true; reg=@('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU'); desc='Commands you typed into Win+R.' }
        @{ id='mru-recentdocs';cat='Recent-items traces';name='Recent documents';    kind='regmru'; undo=$true; reg=@('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RecentDocs'); desc='The list of files you opened recently.' }
        @{ id='mru-typedpaths';cat='Recent-items traces';name='Explorer typed paths'; kind='regmru'; undo=$true; reg=@('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\TypedPaths'); desc='Paths typed into the Explorer address bar.' }
        @{ id='mru-opensave'; cat='Recent-items traces'; name='Open/Save dialog history'; kind='regmru'; undo=$true; reg=@('HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\OpenSavePidlMRU','HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\ComDlg32\LastVisitedPidlMRU'); desc='Recent folders in file Open/Save dialogs.' }
        @{ id='mru-muicache'; cat='Recent-items traces'; name='Program run trace (MuiCache)'; kind='regmru'; undo=$true; reg=@('HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\MuiCache'); desc='A trace of programs you have launched.' }
    )
    # optional: merge winapp2.ini FileKey/RegKey entries if the user drops one next to the script
    $w2 = Join-Path $script:Root 'winapp2.ini'
    if (Test-Path $w2) { $t += @(Import-Winapp2 $w2) }
    $t | ForEach-Object { [pscustomobject]$_ }
}

# Minimal winapp2.ini reader: each [Entry] -> one files/regmru target (FileKey#/RegKey#).
# shortcut: Detect/DetectFile/ExcludeKey/Warning are ignored; FileKey flags beyond RECURSE dropped.
function Import-Winapp2($path) {
    $out = @(); $name=$null; $files=@(); $regs=@()
    $flush = { if ($name) { if ($files.Count) { $out += @{ id="w2-$name"; cat='winapp2.ini'; name=$name; kind='files'; undo=$false; paths=$files; desc='From winapp2.ini.' } }
                            if ($regs.Count)  { $out += @{ id="w2r-$name"; cat='winapp2.ini'; name="$name (registry)"; kind='regmru'; undo=$true; reg=$regs; desc='From winapp2.ini.' } } } }
    foreach ($ln in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $ln = $ln.Trim()
        if ($ln -match '^\[(.+)\]$') { & $flush; $name=$matches[1]; $files=@(); $regs=@(); continue }
        if ($ln -match '^FileKey\d+=(.+)$') { $parts = $matches[1] -split '\|'; $dir = Expand-Env $parts[0]
            if ($parts.Count -ge 2) { foreach ($pat in ($parts[1] -split ';')) { $files += (Join-Path $dir $pat) } } else { $files += $dir } ; continue }
        if ($ln -match '^RegKey\d+=(.+)$') { $regs += (($matches[1] -split '\|')[0]); continue }
    }
    & $flush
    $out
}

function Measure-CleanTarget($t) {
    $bytes = [int64]0; $count = 0
    try {
        switch ($t.kind) {
            'files' {
                foreach ($p in $t.paths) {
                    $ep = Expand-Env $p
                    foreach ($item in (Get-ChildItem -Path $ep -Recurse -Force -File -ErrorAction SilentlyContinue)) { $bytes += $item.Length; $count++ }
                }
            }
            'recyclebin' {
                try { $sh = New-Object -ComObject Shell.Application; $bin = $sh.NameSpace(0x0a)
                      foreach ($it in $bin.Items()) { $count++; try { $bytes += [int64]$it.Size } catch {} } } catch {}
            }
            'regmru' {
                foreach ($r in $t.reg) { $full = ($r -replace '^HKCU\\','HKCU:\' -replace '^HKLM\\','HKLM:\')
                    if (Test-Path -LiteralPath $full) { $count++ } }
            }
        }
    } catch {}
    @{ bytes=$bytes; count=$count }
}

function Invoke-CleanTarget($t) {
    switch ($t.kind) {
        'files' {
            foreach ($p in $t.paths) {
                $ep = Expand-Env $p
                Get-ChildItem -Path $ep -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }
        'recyclebin' { try { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } catch {} }
        'regmru' {
            if (-not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
            foreach ($r in $t.reg) {
                $full = ($r -replace '^HKCU\\','HKCU:\' -replace '^HKLM\\','HKLM:\')
                if (-not (Test-Path -LiteralPath $full)) { continue }
                $bk = Join-Path $BackupDir ('mru_{0}_{1:yyyyMMddHHmmss}.reg' -f ($t.id -replace '[^\w]','_'), (Get-Date))
                & reg export "$r" "$bk" /y *>$null
                if (Test-Path -LiteralPath $bk) { Add-UndoEntry @{ kind='regkey-export'; key=$r; backup=$bk } }
                & reg delete "$r" /f *>$null
            }
        }
    }
}

# ---------------------------------------------------------- uninstaller -------
# Enumerate installed programs (Win32 from the three Uninstall roots + UWP), run their
# uninstaller, then hunt leftovers across the registry/filesystem roots Revo Uninstaller
# scans, scored by confidence (High/Medium/Low = Revo's Safe/Moderate/Advanced tiers).
function Get-InstalledPrograms {
    $seen = @{}; $list = @()
    $roots = @(
        @{ hive='HKLM'; path='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
        @{ hive='HKLM'; path='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' }
        @{ hive='HKCU'; path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' }
    )
    foreach ($r in $roots) {
        foreach ($k in (Get-ChildItem -LiteralPath $r.path -ErrorAction SilentlyContinue)) {
            $pp = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if (-not $pp -or -not $pp.DisplayName) { continue }
            if ($pp.SystemComponent -eq 1) { continue }
            if ($pp.ParentKeyName -or $pp.ParentDisplayName) { continue }   # updates/patches
            $key = "$($pp.DisplayName)|$($pp.DisplayVersion)"
            if ($seen[$key]) { continue }; $seen[$key] = $true
            $list += [pscustomobject]@{
                type='Win32'; name=$pp.DisplayName; version="$($pp.DisplayVersion)"; publisher="$($pp.Publisher)"
                location="$($pp.InstallLocation)"; uninstall="$($pp.UninstallString)"; quiet="$($pp.QuietUninstallString)"
                regkey=$k.PSPath; id="$($pp.DisplayName)"
            }
        }
    }
    try {
        foreach ($a in (Get-AppxPackage -ErrorAction SilentlyContinue)) {
            if ($a.IsFramework -or $a.SignatureKind -eq 'System') { continue }
            $nm = ($a.Name -replace '^.*\.','')
            $list += [pscustomobject]@{
                type='UWP'; name=$nm; version="$($a.Version)"; publisher=(("$($a.Publisher)" -replace '^CN=','' -split ',')[0])
                location="$($a.InstallLocation)"; uninstall=''; quiet=''; regkey=''; id=$a.PackageFullName
            }
        }
    } catch {}
    $list | Sort-Object name
}

function Invoke-ProgramUninstall($app, [switch]$Quiet) {
    if ($app.type -eq 'UWP') {
        Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { $_.PackageFullName -eq $app.id } | Remove-AppxPackage -ErrorAction SilentlyContinue
        return
    }
    $cmd = if ($Quiet -and $app.quiet) { $app.quiet } else { $app.uninstall }
    if (-not $cmd) { return }
    # Split an executable + args out of the uninstall string, then wait for it to finish.
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') { $exe=$matches[1]; $argline=$matches[2] }
    elseif ($cmd -match '^\s*(\S+\.exe)\s*(.*)$') { $exe=$matches[1]; $argline=$matches[2] }
    else { $exe=$cmd; $argline='' }
    try {
        if ($argline.Trim()) { Start-Process -FilePath $exe -ArgumentList $argline -Wait -ErrorAction Stop }
        else { Start-Process -FilePath $exe -Wait -ErrorAction Stop }
    } catch { Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Wait -ErrorAction SilentlyContinue }
}

# Tokens that identify an app, used to match leftovers. Drops generic words.
function Get-AppTokens($app) {
    $stop = 'the','inc','ltd','llc','corp','corporation','company','co','software','technologies','technology',
            'group','app','application','windows','microsoft','program','version','x64','x86','64','32','bit'
    $raw = @()
    foreach ($s in @($app.name, $app.publisher)) {
        if ($s) { $raw += ($s -split '[^A-Za-z0-9]+' | Where-Object { $_.Length -ge 3 }) }
    }
    $raw | Where-Object { $stop -notcontains $_.ToLower() } | Sort-Object -Unique
}

# Generic software words that are real tokens (so they help a 2+-token High match on names
# like "AMDInstallManager") but must NOT alone promote a candidate - otherwise "Micro" would
# flag "Microsoft", "Install" would flag "EpicInstaller", etc.
$script:GenericWords = @('install','installer','uninstall','manager','update','updater','setup','launcher',
    'service','services','runtime','framework','sdk','tools','toolkit','common','shared','studio','suite',
    'client','server','helper','assistant','driver','drivers','package','packages','plugin','extension',
    'advanced','micro','devices','corporation','systems','solutions','global','online','cloud','desktop')

# Score a candidate leftover name/path against the app: High / Medium / Low confidence.
function Get-LeftoverScore($text, $tokens, $app) {
    $t = "$text".ToLower()
    if ($app.name -and $t.Contains($app.name.ToLower())) { return 'High' }     # whole product name present
    $hit = @($tokens | Where-Object { $t.Contains($_.ToLower()) })
    if ($hit.Count -ge 2) { return 'High' }                                    # two distinct tokens = strong
    if ($hit.Count -eq 1) {
        $tok = $hit[0].ToLower()
        if ($tok.Length -ge 5 -and ($script:GenericWords -notcontains $tok)) { return 'Medium' }   # one distinctive word
        return 'Low'                                                            # one short or generic word
    }
    return $null
}

function Find-Leftovers($app) {
    $tokens = @(Get-AppTokens $app)
    $found = New-Object System.Collections.Generic.List[object]   # List so the $add scriptblock mutates it in place
    $add = { param($kind,$path,$score,$detail) if ($score) { [void]$found.Add([pscustomobject]@{ kind=$kind; path=$path; score=$score; detail=$detail; _sel=($score -eq 'High') }) } }
    # ---- registry: scan the roots Revo uses, match key/leaf names ----
    $regRoots = @(
        'HKCU:\SOFTWARE','HKLM:\SOFTWARE','HKLM:\SOFTWARE\WOW6432Node',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths'
    )
    foreach ($root in $regRoots) {
        foreach ($k in (Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $leaf = $k.PSChildName
            $score = Get-LeftoverScore $leaf $tokens $app
            # vendor subkeys directly under SOFTWARE are a strong, safe signal
            if ($score -and $root -match 'SOFTWARE$') { & $add 'registry' $k.PSPath $score "key: $leaf" }
            elseif ($score) { & $add 'registry' $k.PSPath $score "key: $leaf" }
        }
    }
    # ---- filesystem: InstallLocation + the standard app folders, matched by vendor/name ----
    $fsRoots = @($app.location) + @(
        (Expand-Env '%ProgramFiles%'), (Expand-Env '%ProgramFiles(x86)%'), (Expand-Env '%ProgramData%'),
        (Expand-Env '%LOCALAPPDATA%'), (Expand-Env '%APPDATA%'),
        (Join-Path (Expand-Env '%APPDATA%') 'Microsoft\Windows\Start Menu\Programs')
    )
    foreach ($root in ($fsRoots | Where-Object { $_ -and (Test-Path -LiteralPath $_ -ErrorAction SilentlyContinue) } | Sort-Object -Unique)) {
        if ($app.location -and ($root -eq $app.location)) { & $add 'folder' $root 'High' 'the program''s own install folder'; continue }
        foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
            $score = Get-LeftoverScore $d.Name $tokens $app
            if ($score) { & $add 'folder' $d.FullName $score "folder: $($d.Name)" }
        }
    }
    $seen = @{}; $result = @()
    foreach ($grp in 'High','Medium','Low') {
        foreach ($it in @($found | Where-Object { $_.score -eq $grp } | Sort-Object { "$($_.path)" })) {
            $kp = "$($it.kind)|$($it.path)".ToLower()
            if (-not $seen[$kp]) { $seen[$kp] = $true; $result += $it }   # keep highest-tier instance of each path
        }
    }
    $result
}

function Remove-Leftovers($items, [switch]$Backup) {
    if ($Backup -and -not (Test-Path $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    foreach ($it in $items) {
        try {
            if ($it.kind -eq 'registry') {
                $reg = ($it.path -replace '^Microsoft\.PowerShell\.Core\\Registry::','' -replace '^HKEY_LOCAL_MACHINE','HKLM' -replace '^HKEY_CURRENT_USER','HKCU')
                if ($Backup) { $bk = Join-Path $BackupDir ('left_{0:yyyyMMddHHmmss}_{1}.reg' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0,6)))
                               & reg export "$reg" "$bk" /y *>$null
                               if (Test-Path -LiteralPath $bk) { Add-UndoEntry @{ kind='regkey-export'; key=$reg; backup=$bk } } }
                & reg delete "$reg" /f *>$null
            } else {
                # move the folder into the backup store so it is restorable, instead of hard delete
                if ($Backup) {
                    $dest = Join-Path $BackupDir ('left_{0:yyyyMMddHHmmss}_{1}_{2}' -f (Get-Date), ([guid]::NewGuid().ToString('N').Substring(0,6)), (Split-Path $it.path -Leaf))
                    Move-Item -LiteralPath $it.path -Destination $dest -Force -ErrorAction Stop
                    Add-UndoEntry @{ kind='file-move'; path=$it.path; backup=$dest }
                } else {
                    Remove-Item -LiteralPath $it.path -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        } catch {}
    }
}

# ---------------------------------------------------------- version / changelog
function Test-NewerVersion($remote, $local) {
    if (-not $remote) { return $false }
    try { return ([version]$remote) -gt ([version]$local) } catch { return ("$remote" -ne "$local") }
}

# In-app changelog (newest first). Shipped with the build so the exe is self-contained.
function Get-Changelog {
    @(
        [pscustomobject]@{ version='2.1.0'; date='2026-10-16'; changes=@(
            'New: in-app update banner - a floating, rounded prompt at the top of the window when a newer, minisign-verified version is available.',
            'New: Changelog view (this screen).') }
        [pscustomobject]@{ version='2.0.0'; date='2026-10-16'; changes=@(
            'New: Clean - winapp2-style junk rules plus Revo/CCleaner-style recent-item (MRU) trace clears; registry clears are backed up and undoable.',
            'New: Uninstall programs - Win32 + UWP, runs the uninstaller then a leftover scan with High/Med/Low confidence (informed by reverse-engineering Revo Uninstaller Pro). Removals are backed up and undoable.',
            'New: per-operation transactional journals for undo - an operation that fails part-way rolls back atomically; replaces the flat undo log.',
            'New: signed updates - a pure-PowerShell minisign / Ed25519 verifier (RFC 8032), checked against the standard test vectors.') }
        [pscustomobject]@{ version='1.0.0'; date='2026-10-15'; changes=@(
            '478 deduplicated registry tweaks, assembled from 18 reverse-engineered open-source tools.',
            'Debloat (Store apps), Install (winget), Services, Expert menu, restore points and undo.',
            'Compact winutil-style WPF GUI with a scary ASCII PowerShell intro.') }
    )
}

# ----------------------------------------------------------------- visuals ---
function Show-Banner {
    Clear-Host
    # Pure 7-bit ASCII so it renders identically in every console / PowerShell version.
    $art = @'
   _____ _     _____    ___        _   ___           _          ____
  |_   _| |__ | ____|  / _ \ _ __ | |_|_ _|_ __ ___ (_)___  ___|  _ \
    | | | '_ \|  _|   | | | | '_ \| __|| || '_ ` _ \| / __|/ _ \ |_) |
    | | | | | | |___  | |_| | |_) | |_ | || | | | | | \__ \  __/  _ <
    |_| |_| |_|_____|  \___/| .__/ \__|___|_| |_| |_|_|___/\___|_| \_\
                            |_|
'@
    foreach ($line in $art -split "`n") {
        Write-Host $line -ForegroundColor Red
        Start-Sleep -Milliseconds 40
    }
    Write-Host "`n          >>=====  summoned from 18 dissected tools  =====<<`n" -ForegroundColor DarkRed
}

function Show-Animation {
    if ($NoAnimation) { return }
    $skull = @(
        '        .-""""""-.        ',
        '      .''  ___     `.     ',
        '     /   .-   -.     \    ',
        '    |   (  o   o  )    |  ',
        '    |    \   ^   /     |  ',
        '     \    `.___.''     /   ',
        '      `._         _.''     ',
        '         `"""""""`        '
    )
    $msgs = 'binding the registry', 'severing telemetry', 'exorcising bloat', 'the ritual completes'
    for ($i = 0; $i -lt 4; $i++) {
        Clear-Host
        $c = @('DarkRed','Red','DarkYellow','Green')[$i]
        foreach ($s in $skull) { Write-Host ("        " + $s) -ForegroundColor $c }
        Write-Host ""
        $bar = ('#' * (($i+1)*8)).PadRight(32,'.')
        Write-Host ("        [$bar]") -ForegroundColor $c
        Write-Host ("        $($msgs[$i])...") -ForegroundColor Gray
        Start-Sleep -Milliseconds 550
    }
    Start-Sleep -Milliseconds 300
}

# --------------------------------------------------------------- questions ---
function Ask-Questions {
    Write-Host "  Before we begin, a few questions.`n" -ForegroundColor Cyan

    # 1. Administrator
    $admin = Read-Host "  1) Run ThE OptImiseR as administrator? Many tweaks need it. (Y/N)"
    $script:WantAdmin = $admin -match '^(y|yes)$'

    # 2. Windows build
    $detected = try { (Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { '' }
    $cap = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { 'Windows' }
    Write-Host "`n  2) Windows build. Detected: $cap (build $detected)." -ForegroundColor Gray
    $b = Read-Host "     Press Enter to accept, or type your build number"
    $script:Build = if ([string]::IsNullOrWhiteSpace($b)) { $detected } else { $b.Trim() }
    if ($Build -notmatch '^\d{4,6}$') {
        Write-Host "     (Unrecognised build; continuing anyway.)" -ForegroundColor Yellow
    } elseif ([int]$Build -lt 19041) {
        Write-Host "     Note: this is older than Windows 10 20H1; some tweaks may not apply." -ForegroundColor Yellow
    }

    # 3. Terms of service  -- shown LAST, must type I AGREE
    Show-Terms
}

function Show-Terms {
    Write-Host "`n  3) Terms of Service" -ForegroundColor Cyan
    $tos = @'
  --------------------------------------------------------------------------
  ThE OptImiseR - Terms of Service
  --------------------------------------------------------------------------
  1. NO WARRANTY. ThE OptImiseR is provided "as is", without warranty of any
     kind, express or implied. You use it entirely at your own risk.

  2. YOUR RESPONSIBILITY. This tool changes Windows system settings, the
     registry, installed apps and services. You are responsible for your own
     computer and data. Back up anything important first.

  3. RESTORE POINT. The tool offers to create a System Restore point before
     making changes, and records every change so it can be undone from the
     Undo menu. Neither is a guarantee; some changes may need a restart or a
     reinstall to fully reverse.

  4. NO LIABILITY. To the fullest extent permitted by law, the authors of ThE
     OptImiseR are not liable for any damage, data loss, downtime or other
     harm arising from its use.

  5. NOT AFFILIATED. ThE OptImiseR is not affiliated with, endorsed by, or
     sponsored by Microsoft or any other company named in it.

  6. OPEN-SOURCE CREDIT. The tweak catalogue was assembled and deduplicated
     from open-source projects including winutil (ChrisTitusTech), Win11Debloat
     (Raphire), Bloatynosy (builtbybel), PC-Tuning (valleyofdoom), Sophia Script
     (farag2), Winhance (memstechtips) and others. Each remains the property of
     its authors under its own licence; all credit to them.

  7. YOU CHOOSE. Nothing is applied until you select items and confirm.
  --------------------------------------------------------------------------
'@
    Write-Host $tos -ForegroundColor Gray
    $ans = Read-Host "`n  Type  I AGREE  to accept these terms (anything else exits)"
    if ($ans -ne 'I AGREE') {
        Write-Host "`n  Terms not accepted. Exiting.`n" -ForegroundColor Red
        exit 1
    }
    Write-Host "  Accepted.`n" -ForegroundColor Green
}

# ------------------------------------------------------------- menu engine ---
function Pause-Key { Write-Host "`n  Press any key to continue..." -ForegroundColor DarkGray; [void]$Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') }

function Select-FromList($items, $labelFn, $title) {
    # Returns the subset the user ticks. Simple numbered multi-select.
    $sel = New-Object System.Collections.Generic.HashSet[int]
    while ($true) {
        Clear-Host
        Write-Host "  $title`n" -ForegroundColor Cyan
        for ($i = 0; $i -lt $items.Count; $i++) {
            $mark = if ($sel.Contains($i)) { '[x]' } else { '[ ]' }
            Write-Host ("   {0} {1,3}. {2}" -f $mark, ($i+1), (& $labelFn $items[$i]))
        }
        Write-Host "`n  Enter numbers to toggle (e.g. 1,4,7 or 2-9), A=all, N=none, D=apply selected, Q=back" -ForegroundColor DarkGray
        $in = (Read-Host "  >").Trim()
        switch -regex ($in) {
            '^(q|Q)$' { return @() }
            '^(d|D)$' { return @($sel | Sort-Object | ForEach-Object { $items[$_] }) }
            '^(a|A)$' { 0..($items.Count-1) | ForEach-Object { [void]$sel.Add($_) }; continue }
            '^(n|N)$' { $sel.Clear(); continue }
            default {
                foreach ($tok in ($in -split ',')) {
                    if ($tok -match '^\s*(\d+)\s*-\s*(\d+)\s*$') {
                        [int]$a=$matches[1]; [int]$b=$matches[2]
                        for ($k=$a; $k -le $b; $k++) { if ($k -ge 1 -and $k -le $items.Count) { [void]$sel.Add($k-1) } }
                    } elseif ($tok -match '^\s*(\d+)\s*$') {
                        $k=[int]$matches[1]; if ($k -ge 1 -and $k -le $items.Count) {
                            if ($sel.Contains($k-1)) { [void]$sel.Remove($k-1) } else { [void]$sel.Add($k-1) } }
                    }
                }
            }
        }
    }
}

function Do-RegistryCategory($cat, $entries) {
    $chosen = Select-FromList $entries { param($e) "$($e.description)  [$($e.hive)\...\$($e.name) = $($e.value)]  ($($e.sources -join ','))" } "Tweaks - $cat"
    if (-not $chosen) { return }
    Write-Host "`n  About to apply $($chosen.Count) tweak(s)." -ForegroundColor Yellow
    if ((Read-Host "  Create a restore point first? (Y/N)") -match '^(y|yes)$') { New-RestorePointSafe }
    if ((Read-Host "  Apply now? (Y/N)") -notmatch '^(y|yes)$') { return }
    try {
        Invoke-Op "Tweaks - $cat ($($chosen.Count))" {
            foreach ($e in $chosen) { Set-RegValue $e.hive $e.path $e.name $e.type $e.value | Out-Null; Write-Host "   + $($e.description)" -ForegroundColor Green }
        } | Out-Null
        Write-Host "`n  Done. $($chosen.Count) tweak(s) applied as one undoable operation." -ForegroundColor Cyan
    } catch { Write-Host "`n  ! Apply failed ($($_.Exception.Message)); rolled back - nothing changed. (HKLM tweaks need administrator.)" -ForegroundColor Red }
    Pause-Key
}

function Do-Debloat($apps) {
    $chosen = Select-FromList $apps { param($a) "$($a.name)  [$($a.safety)]  $($a.id)" } "Debloat - remove Appx packages (safe shown first)"
    if (-not $chosen) { return }
    if ((Read-Host "`n  Remove $($chosen.Count) app(s) for all users? (Y/N)") -notmatch '^(y|yes)$') { return }
    New-Journal "Debloat ($($chosen.Count))" | Out-Null   # appx removal can't auto-undo; grouped for the record
    foreach ($a in $chosen) {
        try {
            Get-AppxPackage -AllUsers -Name $a.id -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq $a.id } |
                ForEach-Object { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction SilentlyContinue } | Out-Null
            Add-UndoEntry @{ kind='appx'; id=$a.id; note='reinstall from Microsoft Store to undo' }
            Write-Host "   - removed $($a.name)" -ForegroundColor Green
        } catch { Write-Host "   ! $($a.name): $($_.Exception.Message)" -ForegroundColor Red }
    }
    Complete-Journal | Out-Null
    Write-Host "`n  Appx removal cannot be auto-undone; reinstall from the Store if needed." -ForegroundColor Yellow
    Pause-Key
}

function Do-Install($apps) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "`n  winget is not available on this system." -ForegroundColor Red; Pause-Key; return }
    $chosen = Select-FromList $apps { param($a) "$($a.name)  [$($a.category)]  $($a.id)" } "Install apps with winget"
    if (-not $chosen) { return }
    foreach ($a in $chosen) {
        Write-Host "   > winget install $($a.id)" -ForegroundColor Cyan
        winget install --id $a.id --accept-source-agreements --accept-package-agreements -e
    }
    Pause-Key
}

function Do-Services($svcs) {
    $chosen = Select-FromList $svcs { param($s) "$($s.name)  -> $($s.startup)  (was $($s.original))" } "Services - change startup type"
    if (-not $chosen) { return }
    if ((Read-Host "`n  Apply to $($chosen.Count) service(s)? (Y/N)") -notmatch '^(y|yes)$') { return }
    try {
        Invoke-Op "Services ($($chosen.Count))" {
            foreach ($s in $chosen) {
                $cur = (Get-Service -Name $s.name -ErrorAction Stop).StartType
                Set-Service -Name $s.name -StartupType $s.startup -ErrorAction Stop
                Add-UndoEntry @{ kind='service'; name=$s.name; prev="$cur" }
                Write-Host "   + $($s.name) -> $($s.startup)" -ForegroundColor Green
            }
        } | Out-Null
    } catch { Write-Host "   ! Service change failed ($($_.Exception.Message)); rolled back." -ForegroundColor Red }
    Pause-Key
}

function Do-Advanced($adv) {
    Clear-Host
    Write-Host "  EXPERT MENU - security-weakening changes" -ForegroundColor Red
    Write-Host @"

  These reduce your protection. They are included because you asked for them,
  but they are OFF by default and gated behind a typed confirmation.

    1) Disable Windows Defender real-time protection & services ($($adv.defender.Count) keys)
         -> leaves the PC with no built-in antivirus. (source: PC-Tuning)
    2) Block Windows Update COMPLETELY ($($adv.updates_block_all.Count) keys)
         -> no security updates either. Not recommended. (source: PC-Tuning)
    3) Block DRIVER updates only, KEEP system/security updates ($($adv.updates_drivers_only.Count) keys)
         -> the safer option: Windows still patches, just stops pushing drivers. (source: PC-Tuning)
    Q) Back

  Excluded entirely (not available anywhere in this tool):
    - Russian anti-censorship proxy (SophiApp)
    - Windows system-DLL swap (awesome-windows11)
    - "Microsoft Testing Root" certificate trust (Revision Tool)

"@ -ForegroundColor Gray
    $pick = (Read-Host "  Choose").Trim()
    $set = switch ($pick) {
        '1' { ,@($adv.defender)            ; $need='DISABLE DEFENDER' }
        '2' { ,@($adv.updates_block_all)   ; $need='BLOCK UPDATES' }
        '3' { ,@($adv.updates_drivers_only); $need='BLOCK DRIVERS' }
        default { return }
    }
    $entries = $set[0]
    Write-Host "`n  This writes $($entries.Count) registry values and WEAKENS your system." -ForegroundColor Red
    if ((Read-Host "  Type exactly  $need  to proceed") -ne $need) { Write-Host "  Cancelled." -ForegroundColor Yellow; Pause-Key; return }
    if ((Read-Host "  Create a restore point first? (Y/N)") -match '^(y|yes)$') { New-RestorePointSafe }
    try {
        Invoke-Op "Expert - $need ($($entries.Count))" {
            foreach ($e in $entries) { Set-RegValue $e.hive $e.path $e.name $e.type $e.value | Out-Null }
        } | Out-Null
        Write-Host "  Applied $($entries.Count) value(s) as one undoable operation. Reboot for full effect." -ForegroundColor Cyan
    } catch { Write-Host "   ! Failed ($($_.Exception.Message)); rolled back - nothing changed." -ForegroundColor Red }
    Pause-Key
}

function Do-Undo {
    $ops = @(Get-Journals)
    if (-not $ops) { Write-Host "`n  No operations to undo." -ForegroundColor Yellow; Pause-Key; return }
    Clear-Host; Write-Host "  Undo an operation`n" -ForegroundColor Cyan
    for ($i=0; $i -lt $ops.Count; $i++) { Write-Host ("   {0}. {1}  ({2} change(s))" -f ($i+1), $ops[$i].Title, $ops[$i].Count) }
    $p = (Read-Host "`n  Which number to revert (Q to cancel)").Trim()
    if ($p -notmatch '^\d+$') { return }
    $idx=[int]$p-1; if ($idx -lt 0 -or $idx -ge $ops.Count) { return }
    $n = Invoke-JournalRevert $ops[$idx].Path
    Write-Host "`n  Reverted $n change(s)." -ForegroundColor Green
    Pause-Key
}

function Do-Clean {
    $targets = @(Get-CleanTargets)
    $chosen = Select-FromList $targets { param($t) "$($t.name)  [$($t.cat)]  $(if($t.undo){'(undoable)'}elseif($t.kind -eq 'recyclebin'){'(permanent)'}else{'(frees space)'})" } "Clean - junk files and recent-item traces"
    if (-not $chosen) { return }
    if ((Read-Host "`n  Clean $($chosen.Count) location(s)? (Y/N)") -notmatch '^(y|yes)$') { return }
    $freed=[int64]0
    New-Journal "Clean ($($chosen.Count))" | Out-Null
    foreach ($t in $chosen) { try { $m=Measure-CleanTarget $t; Invoke-CleanTarget $t; $freed+=$m.bytes; Write-Host "   + $($t.name)" -ForegroundColor Green } catch { Write-Host "   ! $($t.name)" -ForegroundColor Red } }
    Complete-Journal | Out-Null
    Write-Host ("`n  Freed {0:N1} MB. Registry traces are undoable." -f ($freed/1MB)) -ForegroundColor Cyan
    Pause-Key
}

function Do-Programs {
    $apps = @(Get-InstalledPrograms)
    $chosen = Select-FromList $apps { param($a) "$($a.name)  [$($a.type)]  $($a.publisher)" } "Uninstall programs - pick, then review leftovers"
    if (-not $chosen) { return }
    foreach ($app in $chosen) {
        Write-Host "`n  Uninstalling $($app.name)..." -ForegroundColor Cyan
        try { Invoke-ProgramUninstall $app } catch {}
        Write-Host "  Scanning for leftovers..." -ForegroundColor DarkCyan
        $lf = @(Find-Leftovers $app)
        if (-not $lf) { Write-Host "  No leftovers found." -ForegroundColor Green; continue }
        $pick = Select-FromList $lf { param($i) "[$($i.score)] $($i.kind)  $($i.path)" } "Leftovers for $($app.name) - tick to remove (backed up, undoable)"
        if (-not $pick) { continue }
        New-Journal "Leftovers - $($app.name) ($($pick.Count))" | Out-Null
        Remove-Leftovers $pick -Backup
        Complete-Journal | Out-Null
        Write-Host "  Removed $($pick.Count) item(s), backed up." -ForegroundColor Green
    }
    Pause-Key
}

function Do-Updates { $r = Invoke-UpdateCheck; Write-Host "`n  $($r.message)" -ForegroundColor Cyan; Pause-Key }

function Main-Menu {
    $cat = Get-Catalog
    $byCat = $cat.registry | Group-Object category | Sort-Object Name
    while ($true) {
        Clear-Host
        $adminTag = if (Test-Admin) { 'ADMIN' } else { 'standard user (HKLM tweaks will fail)' }
        Write-Host "  ThE OptImiseR   -   build $($script:Build)   -   $adminTag" -ForegroundColor Red
        Write-Host ("  {0} tweaks | {1} apps to debloat | {2} to install | {3} services`n" -f `
            $cat.registry.Count, $cat.debloat.Count, $cat.install.Count, $cat.services.Count) -ForegroundColor DarkGray
        Write-Host "   TWEAKS BY CATEGORY" -ForegroundColor Cyan
        for ($i=0; $i -lt $byCat.Count; $i++) {
            Write-Host ("    {0,2}. {1,-32} {2,3} tweaks" -f ($i+1), $byCat[$i].Name, $byCat[$i].Count) }
        Write-Host "`n   D. Debloat (Store apps)      P. Uninstall programs      I. Install apps" -ForegroundColor Cyan
        Write-Host "   C. Clean junk & traces        S. Services" -ForegroundColor Cyan
        Write-Host "   R. Create restore point       U. Undo       G. Check for updates (signed)" -ForegroundColor Cyan
        Write-Host "   X. Expert / advanced (security-weakening)" -ForegroundColor Red
        Write-Host "   Q. Quit`n" -ForegroundColor Cyan
        $in = (Read-Host "  Choose").Trim()
        switch -regex ($in) {
            '^(q|Q)$' { return }
            '^(d|D)$' { Do-Debloat  $cat.debloat }
            '^(p|P)$' { Do-Programs }
            '^(i|I)$' { Do-Install  $cat.install }
            '^(c|C)$' { Do-Clean }
            '^(s|S)$' { Do-Services $cat.services }
            '^(r|R)$' { New-RestorePointSafe; Pause-Key }
            '^(u|U)$' { Do-Undo }
            '^(g|G)$' { Do-Updates }
            '^(x|X)$' { Do-Advanced $cat.advanced }
            '^\d+$'   { $k=[int]$in-1; if ($k -ge 0 -and $k -lt $byCat.Count) { Do-RegistryCategory $byCat[$k].Name $byCat[$k].Group } }
        }
    }
}

# ------------------------------------------------------------ modern GUI -----
function Get-OptimiserXaml {
@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ThE OptImiseR" Width="1280" Height="840" MinWidth="1040" MinHeight="680"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        Background="#FF13151A" FontFamily="Segoe UI" TextOptions.TextFormattingMode="Ideal">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="46" ResizeBorderThickness="6" CornerRadius="0" GlassFrameThickness="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="Panel"   Color="#FF23262F"/>
    <SolidColorBrush x:Key="Panel2"  Color="#FF121419"/>
    <SolidColorBrush x:Key="Stroke"  Color="#FF2C313C"/>
    <SolidColorBrush x:Key="Accent"  Color="#FF6366F1"/>
    <SolidColorBrush x:Key="Accent2" Color="#FF22D3EE"/>
    <SolidColorBrush x:Key="Text"    Color="#FFF2F5F9"/>
    <SolidColorBrush x:Key="Muted"   Color="#FF8A94A2"/>
    <SolidColorBrush x:Key="Danger"  Color="#FFFF6B6B"/>
    <SolidColorBrush x:Key="Ok"      Color="#FF34D399"/>
    <LinearGradientBrush x:Key="AccentGrad" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#FF6366F1" Offset="0"/><GradientStop Color="#FF22D3EE" Offset="1"/>
    </LinearGradientBrush>

    <Style x:Key="Nav" TargetType="ToggleButton">
      <Setter Property="Height" Value="38"/><Setter Property="Foreground" Value="{StaticResource Muted}"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="b" Background="Transparent" CornerRadius="3" Padding="14,0" Margin="10,1">
            <Grid><Border x:Name="bar" Width="3" HorizontalAlignment="Left" CornerRadius="2" Background="{StaticResource AccentGrad}" Opacity="0"/>
              <ContentPresenter VerticalAlignment="Center" Margin="11,0,0,0"/></Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#FF18222F"/><Setter Property="Foreground" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#FF16222F"/><Setter TargetName="bar" Property="Opacity" Value="1"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="FontWeight" Value="SemiBold"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Height" Value="36"/><Setter Property="Foreground" Value="#FFF2F4F6"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="3" Background="{StaticResource AccentGrad}" Padding="20,0">
            
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.9"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Height" Value="36"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="3" Background="#FF1C1F27" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="16,0"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/><Setter TargetName="b" Property="Background" Value="#FF1B2634"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Cap" TargetType="Button">
      <Setter Property="Width" Value="46"/><Setter Property="Height" Value="34"/><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" CornerRadius="3" Background="Transparent"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#FF1D2836"/><Setter Property="Foreground" Value="{StaticResource Text}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Chip" TargetType="ToggleButton">
      <Setter Property="Height" Value="28"/><Setter Property="Margin" Value="0,0,7,7"/><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="b" CornerRadius="3" Background="#FF1C1F27" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="14,0"><ContentPresenter VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#FF08303A"/><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Seg" TargetType="ToggleButton">
      <Setter Property="Height" Value="30"/><Setter Property="Width" Value="70"/><Setter Property="Foreground" Value="{StaticResource Muted}"/><Setter Property="FontSize" Value="12"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ToggleButton">
          <Border x:Name="b" Background="Transparent" CornerRadius="8"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter Property="Foreground" Value="{StaticResource Text}"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#FF08303A"/><Setter Property="Foreground" Value="{StaticResource Accent}"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Row" TargetType="Border">
      <Setter Property="Background" Value="#00000000"/><Setter Property="CornerRadius" Value="3"/>
      <Style.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FF34383D"/></Trigger></Style.Triggers>
    </Style>

    <Style x:Key="CheckSm" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Border x:Name="t" Width="34" Height="18" CornerRadius="9" Background="#FF3A404B">
            <Ellipse x:Name="k" Width="13" Height="13" Fill="#FFCbd3dd" HorizontalAlignment="Left" Margin="3,0,0,0"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Background" Value="{StaticResource AccentGrad}"/><Setter TargetName="k" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="k" Property="Margin" Value="0,0,3,0"/><Setter TargetName="k" Property="Fill" Value="White"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Check" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Border x:Name="t" Width="40" Height="22" CornerRadius="11" Background="#FF3A404B">
            <Ellipse x:Name="k" Width="16" Height="16" Fill="#FFCbd3dd" HorizontalAlignment="Left" Margin="3,0,0,0"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="t" Property="Background" Value="{StaticResource AccentGrad}"/><Setter TargetName="k" Property="HorizontalAlignment" Value="Right"/><Setter TargetName="k" Property="Margin" Value="0,0,3,0"/><Setter TargetName="k" Property="Fill" Value="White"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style x:Key="Input" TargetType="TextBox">
      <Setter Property="Height" Value="36"/><Setter Property="Foreground" Value="{StaticResource Text}"/><Setter Property="CaretBrush" Value="{StaticResource Accent}"/><Setter Property="FontSize" Value="13"/><Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="TextBox">
          <Border x:Name="b" CornerRadius="4" Background="#FF1B1E22" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="12,0"><ScrollViewer x:Name="PART_ContentHost"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsFocused" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="{StaticResource Accent}"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="9"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar"><Grid Background="Transparent"><Track x:Name="PART_Track" IsDirectionReversed="True"><Track.Thumb>
          <Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border CornerRadius="4" Background="#FF2B3A4D" Margin="2,0"/></ControlTemplate></Thumb.Template></Thumb>
        </Track.Thumb></Track></Grid></ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root">
    <Grid.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="0.45,1"><GradientStop Color="#FF13151A" Offset="0"/><GradientStop Color="#FF1A1D24" Offset="1"/></LinearGradientBrush>
    </Grid.Background>
    <DockPanel>
      <!-- title bar -->
      <Grid DockPanel.Dock="Top" Height="46">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center" Margin="22,0,0,0">
          <Viewbox Width="30" Height="30" Margin="0,0,12,0">
            <Grid Width="256" Height="256">
              <Grid.Resources><LinearGradientBrush x:Key="lg" StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#FF22F0FF" Offset="0"/><GradientStop Color="#FF7C4DFF" Offset="1"/></LinearGradientBrush></Grid.Resources>
              <Ellipse Width="150" Height="150" StrokeThickness="7" Opacity="0.30" Stroke="{StaticResource lg}" Margin="0,6,0,0"/>
              <Path Stroke="{StaticResource lg}" StrokeThickness="23" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Data="M 84 154 L 128 106 L 172 154"/>
              <Path Stroke="{StaticResource lg}" StrokeThickness="19" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Opacity="0.85" Data="M 95 192 L 128 156 L 161 192"/>
              <Ellipse Width="21" Height="21" Fill="#FFEAFBFF" Margin="0,0,0,116"/>
            </Grid>
          </Viewbox>
          <TextBlock Text="ThE OptImiseR" Foreground="{StaticResource Text}" FontSize="14.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock Text="  //  system optimiser" Foreground="{StaticResource Muted}" FontSize="12" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0">
          <Button x:Name="BtnMin" Style="{StaticResource Cap}"><Path Data="M 0 5 L 11 5" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3"/></Button>
          <Button x:Name="BtnMax" Style="{StaticResource Cap}"><Path x:Name="MaxIcon" Data="M 0 0 L 10 0 L 10 10 L 0 10 Z" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3" Fill="Transparent"/></Button>
          <Button x:Name="BtnClose" Style="{StaticResource Cap}"><Path Data="M 0 0 L 11 11 M 11 0 L 0 11" Stroke="{Binding Foreground, RelativeSource={RelativeSource AncestorType=Button}}" StrokeThickness="1.3"/></Button>
        </StackPanel>
      </Grid>
      <!-- body -->
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="238"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <!-- sidebar -->
        <Border Grid.Column="0" Background="{StaticResource Panel2}">
          <DockPanel Margin="0,8,0,18">
            <StackPanel DockPanel.Dock="Bottom" Margin="24,12,24,0">
              <Border Height="1" Background="{StaticResource Stroke}" Margin="0,0,0,14"/>
              <Border CornerRadius="4" Background="#FF1C1F27" Padding="14,10">
                <StackPanel Orientation="Horizontal">
                  <Ellipse x:Name="AdminDot" Width="9" Height="9" Fill="{StaticResource Danger}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                  <TextBlock x:Name="AdminText" Text="standard user" Foreground="{StaticResource Muted}" FontSize="11.5" VerticalAlignment="Center"/>
                </StackPanel>
              </Border>
              <TextBlock x:Name="BuildText" Text="build ----" Foreground="#FF566474" FontSize="10.5" Margin="3,10,0,0"/>
            </StackPanel>
            <StackPanel>
              <TextBlock Text="NAVIGATE" Foreground="#FF566474" FontSize="10.5" FontWeight="SemiBold" Margin="28,8,0,6"/>
              <ToggleButton x:Name="NavTweaks"  Style="{StaticResource Nav}" Content="Tweaks" IsChecked="True"/>
              <ToggleButton x:Name="NavDebloat" Style="{StaticResource Nav}" Content="Debloat (Store apps)"/>
              <ToggleButton x:Name="NavPrograms" Style="{StaticResource Nav}" Content="Uninstall programs"/>
              <ToggleButton x:Name="NavInstall" Style="{StaticResource Nav}" Content="Install apps"/>
              <ToggleButton x:Name="NavClean"   Style="{StaticResource Nav}" Content="Clean"/>
              <ToggleButton x:Name="NavServices" Style="{StaticResource Nav}" Content="Services"/>
              <TextBlock Text="SYSTEM" Foreground="#FF566474" FontSize="10.5" FontWeight="SemiBold" Margin="28,14,0,6"/>
              <ToggleButton x:Name="NavRestore" Style="{StaticResource Nav}" Content="Restore point"/>
              <ToggleButton x:Name="NavUndo"    Style="{StaticResource Nav}" Content="Undo"/>
              <ToggleButton x:Name="NavUpdates" Style="{StaticResource Nav}" Content="Updates (signed)"/>
              <ToggleButton x:Name="NavChangelog" Style="{StaticResource Nav}" Content="Changelog"/>
              <ToggleButton x:Name="NavExpert"  Style="{StaticResource Nav}" Content="Expert / advanced" Foreground="{StaticResource Danger}"/>
            </StackPanel>
          </DockPanel>
        </Border>
        <!-- main -->
        <Grid Grid.Column="1" Margin="26,10,20,16">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
          <Grid Grid.Row="0" Margin="0,0,0,12">
            <StackPanel VerticalAlignment="Center">
              <TextBlock x:Name="SectionTitle" Text="Tweaks" Foreground="{StaticResource Text}" FontSize="21" FontWeight="SemiBold"/>
              <TextBlock x:Name="SectionSub" Text="pick what you want, then apply" Foreground="{StaticResource Muted}" FontSize="12.5" Margin="0,3,0,0"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
              <Border x:Name="ViewToggle" CornerRadius="3" Background="#FF1C1F27" BorderBrush="{StaticResource Stroke}" BorderThickness="1" Padding="3" Margin="0,0,12,0" Visibility="Collapsed">
                <StackPanel Orientation="Horizontal">
                  <ToggleButton x:Name="ViewList" Style="{StaticResource Seg}" Content="Compact" IsChecked="True"/>
                  <ToggleButton x:Name="ViewGrid" Style="{StaticResource Seg}" Content="Cards"/>
                </StackPanel>
              </Border>
              <TextBox x:Name="SearchBox" Style="{StaticResource Input}" Width="196" Margin="0,0,12,0"/>
              <Border CornerRadius="3" Background="#FF1C1F27" Padding="13,0" Height="36" Margin="0,0,12,0"><TextBlock x:Name="SelCount" Text="0 selected" Foreground="{StaticResource Accent}" FontSize="12.5" VerticalAlignment="Center"/></Border>
              <Button x:Name="BtnApply" Style="{StaticResource Primary}" Content="Apply"/>
            </StackPanel>
          </Grid>
          <Border Grid.Row="1" Margin="0,0,0,10"><WrapPanel x:Name="ChipPanel"/></Border>
          <Border Grid.Row="2" Background="{StaticResource Panel}" CornerRadius="5" BorderBrush="{StaticResource Stroke}" BorderThickness="1">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="12,9" CanContentScroll="False"><StackPanel x:Name="ListPanel"/></ScrollViewer>
          </Border>
          <Border x:Name="ExpertBar" Grid.Row="3" Margin="0,14,0,0" CornerRadius="4" Background="#FF2A1D1F" BorderBrush="{StaticResource Danger}" BorderThickness="1" Padding="16,12" Visibility="Collapsed">
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="ExpertHint" Text="Select one above, then type the phrase to confirm:" Foreground="{StaticResource Danger}" VerticalAlignment="Center" FontSize="12.5" Margin="0,0,14,0"/>
              <TextBox x:Name="ExpertPhrase" Style="{StaticResource Input}" Width="240" Margin="0,0,14,0"/>
              <Button x:Name="BtnExpertGo" Style="{StaticResource Ghost}" Content="Execute" IsEnabled="False"/>
            </StackPanel>
          </Border>
          <Grid Grid.Row="4" Margin="3,14,3,0">
            <TextBlock x:Name="StatusText" Text="Ready." Foreground="{StaticResource Muted}" FontSize="12.5" VerticalAlignment="Center"/>
            <ProgressBar x:Name="Progress" Height="4" Width="200" HorizontalAlignment="Right" Minimum="0" Maximum="100" Value="0" Background="#FF1C1F27" BorderThickness="0" Foreground="#FF6366F1"/>
          </Grid>
        </Grid>
      </Grid>
    </DockPanel>
    <!-- floating update banner (curved, shadowed, top-centre) -->
    <Border x:Name="UpdateBanner" Visibility="Collapsed" VerticalAlignment="Top" HorizontalAlignment="Center"
            Margin="0,62,0,0" CornerRadius="22" Padding="20,11" Background="#D9141518" BorderBrush="#552E77FF" BorderThickness="1" Panel.ZIndex="5">
      <Border.Effect><DropShadowEffect BlurRadius="28" ShadowDepth="5" Direction="270" Opacity="0.55" Color="#FF05070A"/></Border.Effect>
      <StackPanel Orientation="Horizontal">
        <Ellipse Width="9" Height="9" Fill="{StaticResource Accent2}" VerticalAlignment="Center" Margin="2,0,13,0"/>
        <TextBlock x:Name="UpdateText" Text="A new version is available - update to the latest version." Foreground="{StaticResource Text}" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <Button x:Name="BtnUpdateGet" Style="{StaticResource Primary}" Content="Update" Height="30" Margin="18,0,0,0"/>
        <Button x:Name="BtnUpdateDismiss" Style="{StaticResource Ghost}" Content="Later" Height="30" Width="74" Margin="9,0,0,0"/>
      </StackPanel>
    </Border>
    <!-- confirm overlay -->
    <Grid x:Name="ConfirmOverlay" Background="#D0161A1E" Visibility="Collapsed">
      <Border Width="460" CornerRadius="6" Background="{StaticResource Panel}" BorderBrush="{StaticResource Accent}" BorderThickness="1" Padding="30" VerticalAlignment="Center" HorizontalAlignment="Center">
        
        <StackPanel>
          <TextBlock Text="Confirm" Foreground="{StaticResource Accent}" FontSize="12.5" FontWeight="SemiBold"/>
          <TextBlock x:Name="ConfirmText" Text="" Foreground="{StaticResource Text}" FontSize="15.5" TextWrapping="Wrap" Margin="0,10,0,18"/>
          <CheckBox x:Name="ConfirmRestore" Style="{StaticResource Check}" Margin="0,0,0,20"><TextBlock Text="  Create a system restore point first" Foreground="{StaticResource Muted}" FontSize="12.5" VerticalAlignment="Center"/></CheckBox>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="BtnConfirmNo" Style="{StaticResource Ghost}" Content="Cancel" Width="110" Margin="0,0,12,0"/>
            <Button x:Name="BtnConfirmYes" Style="{StaticResource Primary}" Content="Apply" Width="130"/>
          </StackPanel>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
</Window>
'@
}

function Build-OptimiserWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
    $win = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new([xml](Get-OptimiserXaml)))
    $global:gui = @{}
    $G = $global:gui
    $G.win = $win
    $G.ui = @{}
    'Root','BtnMin','BtnMax','MaxIcon','BtnClose','NavTweaks','NavDebloat','NavPrograms','NavInstall','NavClean','NavServices','NavRestore','NavUndo','NavUpdates','NavChangelog','NavExpert',
    'AdminDot','AdminText','BuildText','SectionTitle','SectionSub','SearchBox','SelCount','BtnApply','ChipPanel','ListPanel',
    'ViewToggle','ViewList','ViewGrid','ExpertBar','ExpertHint','ExpertPhrase','BtnExpertGo','StatusText','Progress','ConfirmOverlay','ConfirmText','ConfirmRestore',
    'BtnConfirmNo','BtnConfirmYes','UpdateBanner','UpdateText','BtnUpdateGet','BtnUpdateDismiss' | ForEach-Object { $G.ui[$_] = $win.FindName($_) }

    $cat = Get-Catalog
    $G.st = [pscustomobject]@{ Section='Tweaks'; Category='All'; View='Compact'; Catalog=$cat; Pending=$null; ExpertEntries=$null; ExpertPhrase=$null;
                               CleanTargets=$null; Programs=$null; LeftoverApp=$null; Leftovers=$null; UpdateUrl=$null }
    foreach ($grp in @($cat.registry, $cat.debloat, $cat.install, $cat.services)) {
        foreach ($e in $grp) { $e | Add-Member -NotePropertyName _sel -NotePropertyValue $false -Force }
    }
    foreach ($e in @($cat.debloat) + @($cat.install)) { $e | Add-Member -NotePropertyName _installed -NotePropertyValue $null -Force }

    # background scan: which apps are already installed (AppX + winget), then highlight
    $G.scanInstalled = {
        $global:gui.ui.StatusText.Text = 'Scanning installed apps...'
        $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript({
            $appx = @{}
            try { Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | ForEach-Object { $appx[$_.Name] = $true } } catch {}
            $wg = ''
            try { $wg = (winget list --accept-source-agreements 2>$null | Out-String) } catch {}
            [pscustomobject]@{ appx = $appx; winget = $wg }
        })
        $h = $ps.BeginInvoke()
        $timer = New-Object Windows.Threading.DispatcherTimer; $timer.Interval = [TimeSpan]::FromMilliseconds(600)
        $timer.Add_Tick({
            if (-not $h.IsCompleted) { return }
            $timer.Stop()
            $res = $null; try { $res = $ps.EndInvoke($h)[0] } catch {}
            try { $ps.Dispose(); $rs.Dispose() } catch {}
            if ($res) {
                $appx = $res.appx; $wg = "$($res.winget)"
                foreach ($e in $global:gui.st.Catalog.debloat) { $e._installed = [bool]$appx[$e.id] }
                foreach ($e in $global:gui.st.Catalog.install)  { $e._installed = ($wg.Length -gt 0 -and $wg.Contains($e.id)) }
                $nAppx = @($global:gui.st.Catalog.debloat | Where-Object { $_._installed }).Count
                $global:gui.ui.StatusText.Text = "Scan complete - $nAppx built-in apps present. Green dot = installed."
                if ($global:gui.st.Section -in @('Debloat','Install')) { & $global:gui.populate }
            } else { $global:gui.ui.StatusText.Text = 'Could not scan installed apps.' }
        }.GetNewClosure())
        $timer.Start()
    }
    $mk = { param($hex) New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
    $G.res = @{
        accent = $win.FindResource('Accent'); accent2 = $win.FindResource('Accent2'); muted = $win.FindResource('Muted'); text = $win.FindResource('Text')
        stroke = $win.FindResource('Stroke'); grad = $win.FindResource('AccentGrad'); danger = $win.FindResource('Danger')
        ok = $win.FindResource('Ok'); check = $win.FindResource('Check'); ghost = $win.FindResource('Ghost')
        checkSm = $win.FindResource('CheckSm'); row = $win.FindResource('Row')
        cardBg = (& $mk '#FF23262F'); metaFg = (& $mk '#FF808A94'); tipBg = (& $mk '#FF2F373D'); bodyFg = (& $mk '#FFC8D0D8')
        cardSel = (& $mk '#FF2A3550'); iconBg = (& $mk '#FF2A3550')
    }

    # a clean, readable hover card: title + simplified explanation + context footer
    $G.makeTip = {
        param($title, $body, $foot)
        $R = $global:gui.res
        $tt = New-Object Windows.Controls.ToolTip
        $tt.Background = 'Transparent'; $tt.BorderThickness = '0'; $tt.Padding = '0'; $tt.HasDropShadow = $false
        $bd = New-Object Windows.Controls.Border
        $bd.Background = $R.tipBg; $bd.BorderBrush = $R.stroke; $bd.BorderThickness = '1'; $bd.CornerRadius = '11'; $bd.Padding = '15,13'; $bd.MaxWidth = 400
        $sp = New-Object Windows.Controls.StackPanel
        if ($title) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text = $title; $tb.Foreground = $R.text; $tb.FontSize = 13.5; $tb.FontWeight = 'SemiBold'; $tb.TextWrapping = 'Wrap'; [void]$sp.Children.Add($tb) }
        if ($body)  { $bb = New-Object Windows.Controls.TextBlock; $bb.Text = $body; $bb.Foreground = $R.bodyFg; $bb.FontSize = 12.5; $bb.TextWrapping = 'Wrap'; $bb.Margin = '0,7,0,0'; $bb.LineHeight = 18; [void]$sp.Children.Add($bb) }
        if ($foot)  {
            $sep = New-Object Windows.Controls.Border; $sep.Height = 1; $sep.Background = $R.stroke; $sep.Margin = '0,11,0,9'; [void]$sp.Children.Add($sep)
            $ff = New-Object Windows.Controls.TextBlock; $ff.Text = $foot; $ff.Foreground = $R.metaFg; $ff.FontSize = 11; $ff.TextWrapping = 'Wrap'; [void]$sp.Children.Add($ff)
        }
        $bd.Child = $sp; $tt.Content = $bd
        $tt
    }

    $G.updateCount = {
        $st = $global:gui.st
        $n = switch ($st.Section) {
            'Clean'     { @($st.CleanTargets | Where-Object { $_._sel }).Count }
            'Leftovers' { @($st.Leftovers    | Where-Object { $_._sel }).Count }
            default     { $c=$st.Catalog; @($c.registry + $c.debloat + $c.install + $c.services | Where-Object { $_._sel }).Count }
        }
        $global:gui.ui.SelCount.Text = "$n selected"
    }

    $G.newCard = {
        param($title, $desc, $meta, $selectable, $entry, $actionText, $actionCb)
        $R = $global:gui.res
        $card = New-Object Windows.Controls.Border
        $card.CornerRadius = '4'; $card.Padding = '13,9'; $card.Margin = '2,0,8,6'
        $card.Background = $R.cardBg; $card.BorderBrush = $R.stroke; $card.BorderThickness = '1'
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto','*','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        if ($selectable) {
            $cb = New-Object Windows.Controls.CheckBox
            $cb.Style = $R.check; $cb.VerticalAlignment = 'Center'; $cb.Margin = '2,0,14,0'; $cb.IsChecked = [bool]$entry._sel
            $cb.Add_Checked({ $entry._sel = $true; & $global:gui.updateCount }.GetNewClosure())
            $cb.Add_Unchecked({ $entry._sel = $false; & $global:gui.updateCount }.GetNewClosure())
            [Windows.Controls.Grid]::SetColumn($cb, 0); [void]$g.Children.Add($cb)
        }
        $sp = New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($sp, 1)
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $title; $t.Foreground = $R.text; $t.FontSize = 13.5; $t.FontWeight = 'SemiBold'; $t.TextTrimming = 'CharacterEllipsis'
        $d = New-Object Windows.Controls.TextBlock; $d.Text = $desc; $d.Foreground = $R.muted; $d.FontSize = 11.5; $d.TextWrapping = 'Wrap'; $d.Margin = '0,3,10,0'
        [void]$sp.Children.Add($t); [void]$sp.Children.Add($d)
        if ($meta) {
            $m = New-Object Windows.Controls.TextBlock; $m.Text = $meta; $m.FontSize = 10.5; $m.Margin = '0,5,0,0'; $m.Foreground = $R.metaFg; $m.TextTrimming = 'CharacterEllipsis'
            [void]$sp.Children.Add($m)
        }
        [void]$g.Children.Add($sp)
        if ($actionText) {
            $btn = New-Object Windows.Controls.Button; $btn.Style = $R.ghost; $btn.Content = $actionText; $btn.Height = 32; $btn.VerticalAlignment = 'Center'
            $btn.Add_Click($actionCb)
            [Windows.Controls.Grid]::SetColumn($btn, 2); [void]$g.Children.Add($btn)
        }
        $card.Child = $g
        $card
    }

    $G.newRow = {
        param($label, $tip, $entry)
        $R = $global:gui.res
        $b = New-Object Windows.Controls.Border; $b.Style = $R.row; $b.Width = 316; $b.Height = 30; $b.Padding = '9,0'; $b.Margin = '0,0,6,2'
        $b.ToolTip = (& $global:gui.makeTip $tip.T $tip.B $tip.F)
        [Windows.Controls.ToolTipService]::SetInitialShowDelay($b, 320)
        [Windows.Controls.ToolTipService]::SetShowDuration($b, 40000)
        $g = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto','*','Auto') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$g.ColumnDefinitions.Add($cd) }
        $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $R.checkSm; $cb.VerticalAlignment = 'Center'; $cb.Margin = '0,0,11,0'; $cb.IsChecked = [bool]$entry._sel
        $cb.Add_Checked({ $entry._sel = $true; & $global:gui.updateCount }.GetNewClosure())
        $cb.Add_Unchecked({ $entry._sel = $false; & $global:gui.updateCount }.GetNewClosure())
        [Windows.Controls.Grid]::SetColumn($cb, 0); [void]$g.Children.Add($cb)
        $t = New-Object Windows.Controls.TextBlock; $t.Text = $label; $t.Foreground = $R.text; $t.FontSize = 12.5; $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'
        [Windows.Controls.Grid]::SetColumn($t, 1); [void]$g.Children.Add($t)
        # installed indicator (apps only): green dot when present, dimmed when not
        $inst = $entry.PSObject.Properties['_installed']
        if ($inst -and $null -ne $inst.Value) {
            if ($inst.Value) {
                $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 7; $dot.Height = 7; $dot.Fill = $R.ok; $dot.VerticalAlignment = 'Center'; $dot.Margin = '6,0,0,0'
                $dot.ToolTip = 'Installed'
                [Windows.Controls.Grid]::SetColumn($dot, 2); [void]$g.Children.Add($dot)
            } else {
                $t.Foreground = $R.metaFg   # not installed -> dimmed
            }
        }
        $b.Child = $g
        $b
    }

    $G.newTile = {
        param($title, $sub, $tag, $entry)
        $R = $global:gui.res
        $card = New-Object Windows.Controls.Border
        $card.Width = 230; $card.CornerRadius = '4'; $card.Padding = '13,11'; $card.Margin = '0,0,10,10'
        $card.Background = $R.cardBg; $card.BorderBrush = $R.stroke; $card.BorderThickness = '1'
        $card.ToolTip = (& $global:gui.makeTip $title $sub $tag); [Windows.Controls.ToolTipService]::SetInitialShowDelay($card, 320); [Windows.Controls.ToolTipService]::SetShowDuration($card, 40000)
        $sp = New-Object Windows.Controls.StackPanel
        $top = New-Object Windows.Controls.StackPanel; $top.Orientation = 'Horizontal'
        $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $R.check; $cb.VerticalAlignment = 'Top'; $cb.Margin = '0,2,12,0'; $cb.IsChecked = [bool]$entry._sel
        $cb.Add_Checked({ $entry._sel = $true; & $global:gui.updateCount }.GetNewClosure())
        $cb.Add_Unchecked({ $entry._sel = $false; & $global:gui.updateCount }.GetNewClosure())
        $nm = New-Object Windows.Controls.TextBlock; $nm.Text = $title; $nm.Foreground = $R.text; $nm.FontSize = 13.5; $nm.FontWeight = 'SemiBold'; $nm.TextWrapping = 'Wrap'; $nm.Width = 168
        [void]$top.Children.Add($cb); [void]$top.Children.Add($nm); [void]$sp.Children.Add($top)
        $s = New-Object Windows.Controls.TextBlock; $s.Text = $sub; $s.Foreground = $R.muted; $s.FontSize = 11; $s.TextWrapping = 'Wrap'; $s.Height = 48; $s.TextTrimming = 'CharacterEllipsis'; $s.Margin = '0,10,0,0'
        [void]$sp.Children.Add($s)
        $tg = New-Object Windows.Controls.TextBlock; $tg.Text = $tag; $tg.Foreground = $R.metaFg; $tg.FontSize = 10; $tg.Margin = '0,8,0,0'; $tg.TextTrimming = 'CharacterEllipsis'
        [void]$sp.Children.Add($tg)
        $card.Child = $sp
        $card
    }

    # shared toggle handlers (via Tag) so cards don't each need a GetNewClosure - big build-speed win
    $G.onTogChk   = { param($s,$ev) $s.Tag.e._sel = $true;  $s.Tag.card.BorderBrush = $global:gui.res.accent; & $global:gui.updateCount }
    $G.onTogUnchk = { param($s,$ev) $s.Tag.e._sel = $false; $s.Tag.card.BorderBrush = $global:gui.res.stroke; & $global:gui.updateCount }

    # eclean-style card: icon chip + toggle, title + description. No tooltip (desc is on the card)
    # and no drop-shadow, so hundreds render fast.
    $G.newBCard = {
        param($title, $desc, $meta, $iconText, $iconColor, $entry)
        $R = $global:gui.res
        $card = New-Object Windows.Controls.Border
        $card.Width = 226; $card.MinHeight = 94; $card.CornerRadius = '10'; $card.Padding = '14,12'; $card.Margin = '0,0,13,13'
        $card.Background = $R.cardBg; $card.BorderThickness = '1.3'
        $card.BorderBrush = if ([bool]$entry._sel) { $R.accent } else { $R.stroke }
        $g = New-Object Windows.Controls.Grid
        $rd0 = New-Object Windows.Controls.RowDefinition; $rd0.Height = 'Auto'; $rd1 = New-Object Windows.Controls.RowDefinition; $rd1.Height = '*'
        [void]$g.RowDefinitions.Add($rd0); [void]$g.RowDefinitions.Add($rd1)
        # top: icon chip + toggle
        $top = New-Object Windows.Controls.Grid
        foreach ($w in 'Auto','*') { $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; [void]$top.ColumnDefinitions.Add($cd) }
        $icon = New-Object Windows.Controls.Border; $icon.Width = 30; $icon.Height = 30; $icon.CornerRadius = '8'
        $icon.Background = (New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($iconColor)))
        $itx = New-Object Windows.Controls.TextBlock; $itx.Text = $iconText; $itx.Foreground = $R.text; $itx.FontSize = 13; $itx.FontWeight = 'SemiBold'; $itx.HorizontalAlignment = 'Center'; $itx.VerticalAlignment = 'Center'
        $icon.Child = $itx; [void]$top.Children.Add($icon)
        $cb = New-Object Windows.Controls.CheckBox; $cb.Style = $R.check; $cb.HorizontalAlignment = 'Right'; $cb.VerticalAlignment = 'Center'; $cb.IsChecked = [bool]$entry._sel
        $cb.Tag = @{ e = $entry; card = $card }
        $cb.Add_Checked($global:gui.onTogChk); $cb.Add_Unchecked($global:gui.onTogUnchk)
        [Windows.Controls.Grid]::SetColumn($cb, 1); [void]$top.Children.Add($cb)
        [void]$g.Children.Add($top)
        # bottom: title + desc
        $sp = New-Object Windows.Controls.StackPanel; $sp.VerticalAlignment = 'Bottom'; $sp.Margin = '0,11,0,0'; [Windows.Controls.Grid]::SetRow($sp, 1)
        $nm = New-Object Windows.Controls.TextBlock; $nm.Text = $title; $nm.Foreground = $R.text; $nm.FontSize = 13; $nm.FontWeight = 'SemiBold'; $nm.TextTrimming = 'CharacterEllipsis'
        $ds = New-Object Windows.Controls.TextBlock; $ds.Text = $desc; $ds.Foreground = $R.muted; $ds.FontSize = 11; $ds.TextWrapping = 'Wrap'; $ds.MaxHeight = 30; $ds.TextTrimming = 'CharacterEllipsis'; $ds.Margin = '0,3,0,0'
        [void]$sp.Children.Add($nm); [void]$sp.Children.Add($ds)
        [void]$g.Children.Add($sp)
        # installed indicator (apps): green dot when present, dimmed when not
        $inst = $entry.PSObject.Properties['_installed']
        if ($inst -and $null -ne $inst.Value) {
            if ($inst.Value) { $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 8; $dot.Height = 8; $dot.Fill = $R.ok; $dot.HorizontalAlignment = 'Left'; $dot.VerticalAlignment = 'Top'; $dot.Margin = '24,-2,0,0'; $dot.ToolTip = 'Installed'; [void]$top.Children.Add($dot) }
            else { $card.Opacity = 0.62 }
        }
        $card.Child = $g
        $card
    }

    $G.revert = {
        param($path)
        $n = Invoke-JournalRevert $path
        $global:gui.ui.StatusText.Text = "Reverted $n change(s)."; & $global:gui.populate
    }

    $G.populate = {
        $G = $global:gui; $ui = $G.ui; $st = $G.st; $nc = $G.newCard; $nt = $G.newTile; $nr = $G.newRow
        $ui.ListPanel.Children.Clear()
        $q = ($ui.SearchBox.Text).Trim()

        if ($st.Section -eq 'Expert') {
            $adv = $st.Catalog.advanced
            $groups = @(
                @{ t='Disable Windows Defender'; d="Turns off real-time protection and Defender services ($($adv.defender.Count) keys). Leaves no built-in antivirus."; k='defender'; phrase='DISABLE DEFENDER' },
                @{ t='Block ALL Windows Updates'; d="Stops every update, including security ($($adv.updates_block_all.Count) keys). Not recommended."; k='updates_block_all'; phrase='BLOCK UPDATES' },
                @{ t='Block driver updates only (keep security patches)'; d="The safer option: Windows keeps patching, only driver pushes stop ($($adv.updates_drivers_only.Count) keys)."; k='updates_drivers_only'; phrase='BLOCK DRIVERS' }
            )
            foreach ($grp in $groups) {
                [void]$ui.ListPanel.Children.Add((& $nc $grp.t $grp.d 'source: PC-Tuning' $false $null 'Select' ({
                    $st = $global:gui.st; $ui = $global:gui.ui
                    $st.ExpertEntries = $st.Catalog.advanced.($grp.k); $st.ExpertPhrase = $grp.phrase
                    $ui.ExpertHint.Text = "Type   $($grp.phrase)   then Execute:"; $ui.ExpertPhrase.Text=''; $ui.BtnExpertGo.IsEnabled = $false
                    $ui.StatusText.Text = "Selected: $($grp.t)"
                }.GetNewClosure())))
            }
            & $G.updateCount; return
        }
        if ($st.Section -eq 'Undo') {
            $ops = @(Get-Journals)
            if (-not $ops) { $tb = New-Object Windows.Controls.TextBlock; $tb.Text='No operations to undo yet.'; $tb.Foreground=$G.res.muted; $tb.Margin='6'; [void]$ui.ListPanel.Children.Add($tb) }
            foreach ($op in $ops) {
                $when = try { ([datetime]$op.When).ToString('yyyy-MM-dd HH:mm') } catch { '' }
                [void]$ui.ListPanel.Children.Add((& $nc $op.Title "$($op.Count) change(s) recorded     $when" '' $false $null 'Revert' ({ & $global:gui.revert $op.Path }.GetNewClosure())))
            }
            & $G.updateCount; return
        }

        if ($st.Section -eq 'Clean')     { & $G.populateClean;     & $G.updateCount; return }
        if ($st.Section -eq 'Programs')  { & $G.populatePrograms;  & $G.updateCount; return }
        if ($st.Section -eq 'Leftovers') { & $G.populateLeftovers; & $G.updateCount; return }
        if ($st.Section -eq 'Updates')   { & $G.populateUpdates;   & $G.updateCount; return }
        if ($st.Section -eq 'Changelog') { & $G.populateChangelog; & $G.updateCount; return }

        # ---- browse sections (Tweaks / Debloat / Install / Services) as eclean-style cards ----
        $short = { param($d) $s = (($d -split '[.!]')[0]).Trim(); if ($s.Length -gt 64) { $s.Substring(0, 62).Trim() + '...' } else { $s } }
        $palette = @('#FF2A3550','#FF2E4A3B','#FF46304A','#FF3A3A58','#FF2F4A52','#FF4A422F','#FF472F44','#FF2F3A4E','#FF3F4A2F')
        $colorFor = { param($key) $h=0; foreach($ch in [char[]]"$key"){ $h = ($h*31 + [int]$ch) }; $palette[[Math]::Abs($h) % $palette.Count] }
        $mk = $null; $groups = @()
        switch ($st.Section) {
            'Tweaks' {
                $items = $st.Catalog.registry
                if ($st.Category -ne 'All') { $items = $items | Where-Object { $_.category -eq $st.Category } }
                if ($q) { $items = $items | Where-Object { $_.description -match [regex]::Escape($q) -or $_.name -match [regex]::Escape($q) } }
                $mk = { param($e) @{ title=(& $short $e.description); desc=$e.description; key=$e.category } }
                if ($st.Category -ne 'All') { $groups = @(,@{ n=$null; it=@($items) }) }
                else { $by=[ordered]@{}; foreach($e in $items){ if(-not $by.Contains($e.category)){$by[$e.category]=[System.Collections.Generic.List[object]]::new()}; [void]$by[$e.category].Add($e) }; foreach($k in ($by.Keys|Sort-Object)){ $groups += ,@{ n=$k; it=$by[$k] } } }
            }
            'Debloat' {
                $items = $st.Catalog.debloat
                if ($q) { $items = $items | Where-Object { $_.name -match [regex]::Escape($q) -or $_.id -match [regex]::Escape($q) } }
                $mk = { param($e) @{ title=$e.name; desc=$e.description; key=$e.name } }
                $nm2=@{ safe='Safe to remove'; optional='Optional'; unsafe='Caution - part of Windows' }
                foreach($k in 'safe','optional','unsafe'){ $it=@($items|Where-Object{$_.safety -eq $k}); if($it.Count){ $groups += ,@{ n=$nm2[$k]; it=$it } } }
            }
            'Install' {
                $items = $st.Catalog.install
                if ($q) { $items = $items | Where-Object { $_.name -match [regex]::Escape($q) -or $_.id -match [regex]::Escape($q) } }
                $mk = { param($e) @{ title=$e.name; desc=$e.description; key=$e.category } }
                $by=[ordered]@{}; foreach($e in $items){ if(-not $by.Contains($e.category)){$by[$e.category]=[System.Collections.Generic.List[object]]::new()}; [void]$by[$e.category].Add($e) }; foreach($k in ($by.Keys|Sort-Object)){ $groups += ,@{ n=$k; it=$by[$k] } }
            }
            'Services' {
                $items = $st.Catalog.services
                $mk = { param($e) @{ title=$e.name; desc="Start as '$($e.startup)' instead of '$($e.original)'. Fewer always-on services can free memory and speed boot."; key='Services' } }
                $groups = @(,@{ n=$null; it=@($items) })
            }
        }
        foreach ($grp in $groups) {
            if ($grp.n) {
                $hd = New-Object Windows.Controls.TextBlock; $hd.Text = ($grp.n.ToUpper() + "    " + @($grp.it).Count); $hd.Foreground = $G.res.accent2; $hd.FontSize = 11.5; $hd.FontWeight = 'SemiBold'; $hd.Margin = '3,8,0,11'
                [void]$ui.ListPanel.Children.Add($hd)
            }
            $wp = New-Object Windows.Controls.WrapPanel
            foreach ($e in $grp.it) {
                $c = & $mk $e
                $k = "$($c.key)"; $ic = if ($k.Length -ge 1) { $k.Substring(0,1).ToUpper() } else { '#' }
                [void]$wp.Children.Add((& $G.newBCard $c.title $c.desc '' $ic (& $colorFor $k) $e))
            }
            [void]$ui.ListPanel.Children.Add($wp)
        }
        & $G.updateCount
    }

    $G.populateClean = {
        $G=$global:gui; $ui=$G.ui; $st=$G.st; $nc=$G.newCard
        if (-not $st.CleanTargets) {
            $st.CleanTargets = @(Get-CleanTargets)
            foreach ($t in $st.CleanTargets) { $t | Add-Member -NotePropertyName _sel -NotePropertyValue $false -Force }
        }
        $ui.ListPanel.Children.Clear()
        $q = ($ui.SearchBox.Text).Trim()
        $items = $st.CleanTargets
        if ($q) { $items = $items | Where-Object { $_.name -match [regex]::Escape($q) -or $_.cat -match [regex]::Escape($q) } }
        $by=[ordered]@{}
        foreach ($t in $items) { if (-not $by.Contains($t.cat)) { $by[$t.cat]=[System.Collections.Generic.List[object]]::new() }; [void]$by[$t.cat].Add($t) }
        foreach ($catName in $by.Keys) {
            $hdr = New-Object Windows.Controls.TextBlock; $hdr.Text=$catName.ToUpper(); $hdr.Foreground=$G.res.accent2; $hdr.FontSize=11.5; $hdr.FontWeight='SemiBold'; $hdr.Margin='4,8,0,6'
            [void]$ui.ListPanel.Children.Add($hdr)
            foreach ($t in $by[$catName]) {
                $meta = if ($t.undo) { 'backed up - undoable' } elseif ($t.kind -eq 'recyclebin') { 'permanent' } else { 'frees space - not undoable' }
                if ($t.admin) { $meta += '   (needs admin)' }
                [void]$ui.ListPanel.Children.Add((& $nc $t.name $t.desc $meta $true $t $null $null))
            }
        }
    }

    $G.populatePrograms = {
        $G=$global:gui; $ui=$G.ui; $st=$G.st; $nc=$G.newCard
        if (-not $st.Programs) { $ui.StatusText.Text='Reading installed programs...'; $st.Programs=@(Get-InstalledPrograms); $ui.StatusText.Text="$($st.Programs.Count) installed program(s)." }
        $ui.ListPanel.Children.Clear()
        $q=($ui.SearchBox.Text).Trim()
        $items=$st.Programs
        if ($q) { $items = $items | Where-Object { $_.name -match [regex]::Escape($q) -or $_.publisher -match [regex]::Escape($q) } }
        foreach ($app in $items) {
            $meta = "$($app.type)     $($app.publisher)     $($app.version)"
            [void]$ui.ListPanel.Children.Add((& $nc $app.name ($app.location) $meta $false $null 'Uninstall' ({ & $global:gui.startUninstall $app }.GetNewClosure())))
        }
    }

    # run a program's uninstaller, then show its leftovers for review
    $G.startUninstall = {
        param($app)
        $G=$global:gui
        & $G.showConfirm "Uninstall '$($app.name)'? I'll run its uninstaller, then scan for leftovers. Nothing extra is removed without your OK." ({
            $G=$global:gui; $ui=$G.ui
            $ui.StatusText.Text="Uninstalling $($app.name)..."
            try { Invoke-ProgramUninstall $app } catch {}
            $ui.StatusText.Text="Scanning for leftovers..."
            $G.st.LeftoverApp = $app
            $G.st.Leftovers = @(Find-Leftovers $app)
            & $G.setSection 'Leftovers' "Leftovers - $($app.name)" "ticked items are removed and backed up (undoable); grey = low confidence, left unticked"
        }.GetNewClosure())
    }

    $G.populateLeftovers = {
        $G=$global:gui; $ui=$G.ui; $st=$G.st; $R=$G.res
        $ui.ListPanel.Children.Clear()
        $lf = @($st.Leftovers)
        if (-not $lf) {
            $tb=New-Object Windows.Controls.TextBlock; $tb.Text='No leftovers found - this program removed itself cleanly.'; $tb.Foreground=$R.muted; $tb.Margin='6'; [void]$ui.ListPanel.Children.Add($tb); return
        }
        $badge=@{ High=$R.ok; Medium=$R.accent2; Low=$R.metaFg }
        foreach ($grp in 'High','Medium','Low') {
            $rows=@($lf | Where-Object { $_.score -eq $grp })
            if (-not $rows) { continue }
            $hdr=New-Object Windows.Controls.TextBlock; $hdr.Text=("$grp confidence  ($($rows.Count))").ToUpper(); $hdr.Foreground=$badge[$grp]; $hdr.FontSize=11.5; $hdr.FontWeight='SemiBold'; $hdr.Margin='4,10,0,6'
            [void]$ui.ListPanel.Children.Add($hdr)
            foreach ($it in $rows) {
                $b=New-Object Windows.Controls.Border; $b.Style=$R.row; $b.Padding='9,5'; $b.Margin='0,0,6,3'
                $g=New-Object Windows.Controls.Grid
                foreach ($w in 'Auto','Auto','*') { $cd=New-Object Windows.Controls.ColumnDefinition; $cd.Width=$w; [void]$g.ColumnDefinitions.Add($cd) }
                $cb=New-Object Windows.Controls.CheckBox; $cb.Style=$R.checkSm; $cb.VerticalAlignment='Center'; $cb.Margin='0,0,11,0'; $cb.IsChecked=[bool]$it._sel
                $cb.Add_Checked({ $it._sel=$true; & $global:gui.updateCount }.GetNewClosure())
                $cb.Add_Unchecked({ $it._sel=$false; & $global:gui.updateCount }.GetNewClosure())
                [Windows.Controls.Grid]::SetColumn($cb,0); [void]$g.Children.Add($cb)
                $k=New-Object Windows.Controls.TextBlock; $k.Text=$it.kind; $k.Foreground=$R.metaFg; $k.FontSize=10.5; $k.VerticalAlignment='Center'; $k.Width=62
                [Windows.Controls.Grid]::SetColumn($k,1); [void]$g.Children.Add($k)
                $p=New-Object Windows.Controls.TextBlock; $p.Text=$it.path; $p.Foreground=$R.text; $p.FontSize=12; $p.VerticalAlignment='Center'; $p.TextTrimming='CharacterEllipsis'; $p.ToolTip=$it.path
                [Windows.Controls.Grid]::SetColumn($p,2); [void]$g.Children.Add($p)
                $b.Child=$g; [void]$ui.ListPanel.Children.Add($b)
            }
        }
    }

    $G.populateUpdates = {
        $G=$global:gui; $ui=$G.ui; $nc=$G.newCard; $R=$G.res
        $ui.ListPanel.Children.Clear()
        $cfg = Get-UpdateConfig
        $src = if ($cfg -and $cfg.url) { $cfg.url } else { '(none configured)' }
        $key = if ($cfg -and $cfg.pubkey) { $cfg.pubkey.Substring(0,[Math]::Min(24,$cfg.pubkey.Length))+'...' } else { '(no public key)' }
        [void]$ui.ListPanel.Children.Add((& $nc 'Signed updates (minisign / Ed25519)' "Update manifests are verified with a minisign Ed25519 signature before anything is trusted - the scheme eclean uses. Source: $src     Key: $key" "config: $UpdateConfig" $false $null 'Check now' ({
            $G=$global:gui; $G.ui.StatusText.Text='Checking for a signed update...'
            $r = Invoke-UpdateCheck; $G.ui.StatusText.Text = $r.message
        }.GetNewClosure())))
        $tb=New-Object Windows.Controls.TextBlock
        $tb.Text='To enable updates, drop an update.json ({"url":"...","pubkey":"<minisign public key>"}) at the config path above. The manifest at that URL is signed with minisign (legacy Ed mode) and its .minisig sits beside it. Verification is fully offline; a bad or missing signature is ignored. The installer is never downloaded or run for you.'
        $tb.Foreground=$R.muted; $tb.FontSize=12; $tb.TextWrapping='Wrap'; $tb.Margin='6,14,20,0'; $tb.LineHeight=18
        [void]$ui.ListPanel.Children.Add($tb)
    }

    $G.populateChangelog = {
        $G=$global:gui; $ui=$G.ui; $R=$G.res
        $ui.ListPanel.Children.Clear()
        foreach ($e in (Get-Changelog)) {
            $card=New-Object Windows.Controls.Border; $card.CornerRadius='4'; $card.Padding='15,12'; $card.Margin='2,0,8,10'; $card.Background=$R.cardBg; $card.BorderBrush=$R.stroke; $card.BorderThickness='1'
            $sp=New-Object Windows.Controls.StackPanel
            $hdr=New-Object Windows.Controls.StackPanel; $hdr.Orientation='Horizontal'
            $ver=New-Object Windows.Controls.TextBlock; $ver.Text="v$($e.version)"; $ver.Foreground=$R.accent2; $ver.FontSize=15; $ver.FontWeight='SemiBold'
            [void]$hdr.Children.Add($ver)
            $meta = "   $($e.date)"; if ($e.version -eq $script:Version) { $meta += "   -   current" }
            $dt=New-Object Windows.Controls.TextBlock; $dt.Text=$meta; $dt.Foreground=$R.metaFg; $dt.FontSize=11.5; $dt.VerticalAlignment='Bottom'; $dt.Margin='8,0,0,2'
            [void]$hdr.Children.Add($dt); [void]$sp.Children.Add($hdr)
            foreach ($c in $e.changes) {
                $row=New-Object Windows.Controls.TextBlock; $row.Text=" -  $c"; $row.Foreground=$R.bodyFg; $row.FontSize=12.5; $row.TextWrapping='Wrap'; $row.Margin='2,7,10,0'; $row.LineHeight=18
                [void]$sp.Children.Add($row)
            }
            $card.Child=$sp; [void]$ui.ListPanel.Children.Add($card)
        }
    }

    $G.showUpdateBanner = {
        param($version, $url)
        $G=$global:gui
        $G.st.UpdateUrl = $url
        $G.ui.UpdateText.Text = "Version $version is available - update to the latest version."
        $G.ui.UpdateBanner.Visibility = 'Visible'
    }

    # background update check: download manifest + .minisig off-thread, verify + compare on the UI thread
    $G.checkUpdates = {
        $cfg = Get-UpdateConfig
        if (-not $cfg -or -not $cfg.url -or -not $cfg.pubkey) { return }
        $curVer = $script:Version   # capture into a local so the closure tick can see it
        $rs=[runspacefactory]::CreateRunspace(); $rs.ApartmentState='MTA'; $rs.Open()
        $ps=[powershell]::Create(); $ps.Runspace=$rs
        [void]$ps.AddScript({ param($u)
            try { $m=(Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15).Content
                  $s=(Invoke-WebRequest -Uri ($u+'.minisig') -UseBasicParsing -TimeoutSec 15).Content
                  [pscustomobject]@{ man=$m; sig=$s } } catch { $null }
        }).AddArgument($cfg.url)
        $h=$ps.BeginInvoke()
        $timer=New-Object Windows.Threading.DispatcherTimer; $timer.Interval=[TimeSpan]::FromMilliseconds(700)
        $timer.Add_Tick({
            if (-not $h.IsCompleted) { return }
            $timer.Stop()
            $res=$null; try { $res=$ps.EndInvoke($h)[0] } catch {}
            try { $ps.Dispose(); $rs.Dispose() } catch {}
            if (-not $res) { return }
            try {
                $c = Get-UpdateConfig
                $sigLine=(@($res.sig -split "`n") | Where-Object { $_ -notmatch '^(untrusted|trusted) comment:' -and $_.Trim() })[0]
                $v = Test-MinisignSignature -PubB64 $c.pubkey -SigB64 $sigLine -Message ([Text.Encoding]::UTF8.GetBytes($res.man))
                if (-not $v.ok) { return }
                $info = $res.man | ConvertFrom-Json
                if ($info.version -and (Test-NewerVersion $info.version $curVer)) { & $global:gui.showUpdateBanner $info.version $info.url }
            } catch {}
        }.GetNewClosure())
        $timer.Start()
    }

    $G.setSection = {
        param($name, $title, $sub)
        $ui = $global:gui.ui; $global:gui.st.Section = $name
        $ui.SectionTitle.Text = $title; $ui.SectionSub.Text = $sub
        $ui.ChipPanel.Visibility = $(if ($name -eq 'Tweaks') { 'Visible' } else { 'Collapsed' })
        $ui.ViewToggle.Visibility = 'Collapsed'   # single eclean-style card view now
        $ui.ExpertBar.Visibility = $(if ($name -eq 'Expert') { 'Visible' } else { 'Collapsed' })
        $ui.BtnApply.Visibility  = $(if ($name -in @('Tweaks','Debloat','Install','Services','Clean','Leftovers')) { 'Visible' } else { 'Collapsed' })
        $ui.BtnApply.Content = switch ($name) { 'Clean' { 'Clean' } 'Leftovers' { 'Remove selected' } default { 'Apply' } }
        & $global:gui.populate
    }

    $G.showConfirm = {
        param($msg, $action)
        $ui = $global:gui.ui
        $ui.ConfirmText.Text = $msg; $ui.ConfirmRestore.IsChecked = $false; $global:gui.st.Pending = $action; $ui.ConfirmOverlay.Visibility = 'Visible'
    }

    $G.apply = {
        param($kind)
        $st = $global:gui.st; $ui = $global:gui.ui
        switch ($kind) {
            'Tweaks' {
                $sel = @($st.Catalog.registry | Where-Object { $_._sel }); foreach ($e in $sel) { $e._sel=$false }
                if (-not $sel) { $ui.StatusText.Text='Nothing selected.'; break }
                try { Invoke-Op "Tweaks ($($sel.Count))" { foreach ($e in $sel) { Set-RegValue $e.hive $e.path $e.name $e.type $e.value | Out-Null } } | Out-Null
                      $ui.StatusText.Text = "Applied $($sel.Count) tweak(s) as one undoable operation." }
                catch { $ui.StatusText.Text = "Apply failed - rolled back, nothing changed. (HKLM tweaks need administrator.)" }
            }
            'Services' {
                $sel = @($st.Catalog.services | Where-Object { $_._sel }); foreach ($s in $sel) { $s._sel=$false }
                if (-not $sel) { $ui.StatusText.Text='Nothing selected.'; break }
                try { Invoke-Op "Services ($($sel.Count))" { foreach ($s in $sel) { $cur=(Get-Service $s.name -EA Stop).StartType; Set-Service $s.name -StartupType $s.startup -EA Stop; Add-UndoEntry @{kind='service';name=$s.name;prev="$cur"} } } | Out-Null
                      $ui.StatusText.Text = "Changed $($sel.Count) service(s) as one undoable operation." }
                catch { $ui.StatusText.Text = "Service change failed - rolled back, nothing changed." }
            }
            'Debloat' {
                $sel = @($st.Catalog.debloat | Where-Object { $_._sel }); $ok=0
                New-Journal "Debloat ($($sel.Count))" | Out-Null   # appx removal can't auto-undo
                foreach ($a in $sel) { try { Get-AppxPackage -AllUsers -Name $a.id -EA SilentlyContinue | Remove-AppxPackage -AllUsers -EA SilentlyContinue; Add-UndoEntry @{kind='appx';id=$a.id}; $ok++ } catch {}; $a._sel=$false }
                Complete-Journal | Out-Null
                $ui.StatusText.Text = "Removed $ok app(s). (Appx removal can't auto-undo.)"
            }
            'Install' {
                $sel = @($st.Catalog.install | Where-Object { $_._sel })
                if (-not (Get-Command winget -EA SilentlyContinue)) { $ui.StatusText.Text='winget not available.'; return }
                foreach ($a in $sel) { Start-Process winget -ArgumentList "install --id $($a.id) --accept-source-agreements --accept-package-agreements -e" -WindowStyle Minimized; $a._sel=$false }
                $ui.StatusText.Text = "Started winget installs for $($sel.Count) app(s)."
            }
            'Expert' {
                $ent = $st.ExpertEntries
                try { Invoke-Op "Expert ($($ent.Count))" { foreach ($e in $ent) { Set-RegValue $e.hive $e.path $e.name $e.type $e.value | Out-Null } } | Out-Null
                      $ui.StatusText.Text = "Applied $($ent.Count) advanced value(s) as one undoable operation. Reboot for full effect." }
                catch { $ui.StatusText.Text = "Failed - rolled back, nothing changed." }
                $ui.ExpertPhrase.Text=''
            }
            'Clean' {
                $sel = @($st.CleanTargets | Where-Object { $_._sel }); if (-not $sel) { $ui.StatusText.Text='Nothing selected.'; break }
                $freed=[int64]0; $done=0
                New-Journal "Clean ($($sel.Count))" | Out-Null
                foreach ($t in $sel) { try { $m=Measure-CleanTarget $t; Invoke-CleanTarget $t; $freed+=$m.bytes; $done++ } catch {}; $t._sel=$false }
                Complete-Journal | Out-Null
                $ui.StatusText.Text = ("Cleaned {0} location(s), freed {1:N1} MB. Registry traces are undoable." -f $done, ($freed/1MB))
            }
            'Leftovers' {
                $sel = @($st.Leftovers | Where-Object { $_._sel }); if (-not $sel) { $ui.StatusText.Text='Nothing ticked.'; break }
                New-Journal "Leftovers - $($st.LeftoverApp.name) ($($sel.Count))" | Out-Null
                Remove-Leftovers $sel -Backup
                Complete-Journal | Out-Null
                $st.Programs = $null   # force the installed-programs list to re-read
                $ui.StatusText.Text = "Removed $($sel.Count) leftover item(s) - backed up, undoable from Undo."
                & $global:gui.setSection 'Programs' 'Uninstall programs' 'remove a desktop program, then clean its leftovers'
            }
        }
    }

    # ---- nav wiring ----
    $G.navs = @{ NavTweaks='Tweaks'; NavDebloat='Debloat'; NavPrograms='Programs'; NavInstall='Install'; NavClean='Clean'; NavServices='Services'; NavUndo='Undo'; NavUpdates='Updates'; NavChangelog='Changelog'; NavExpert='Expert' }
    $G.navMeta = @{
        Tweaks=@('Tweaks','pick what you want, then apply'); Debloat=@('Debloat (Store apps)','remove built-in Store/Appx apps (safe shown first)')
        Programs=@('Uninstall programs','remove a desktop program, then clean its leftovers'); Install=@('Install apps','install software with winget')
        Clean=@('Clean','clear junk files and recent-item traces'); Services=@('Services','change service startup types')
        Undo=@('Undo','roll back a previous operation'); Updates=@('Updates (signed)','minisign-verified update check')
        Changelog=@('Changelog',"what's new in each version"); Expert=@('Expert / advanced','security-weakening - off by default, gated')
    }
    foreach ($navName in @($G.navs.Keys)) {
        $G.ui[$navName].Add_Checked({
            param($s,$e)
            $G = $global:gui
            foreach ($o in @($G.navs.Keys)) { if ($G.ui[$o] -ne $s) { $G.ui[$o].IsChecked = $false } }
            $m = $G.navMeta[$G.navs[$s.Name]]; & $G.setSection $G.navs[$s.Name] $m[0] $m[1]
        })
    }
    $G.ui.NavRestore.Add_Checked({ param($s,$e); $s.IsChecked=$false; $global:gui.ui.StatusText.Text='Creating restore point (see console)...'; New-RestorePointSafe; $global:gui.ui.StatusText.Text='Restore point step finished.' })

    # ---- chips ----
    foreach ($c in (@('All') + ($cat.registry.category | Sort-Object -Unique))) {
        $chip = New-Object Windows.Controls.Primitives.ToggleButton
        $chip.Style = $win.FindResource('Chip'); $chip.Content = $c; if ($c -eq 'All') { $chip.IsChecked = $true }
        $chip.Add_Checked({ param($s,$e)
            $G = $global:gui
            foreach ($o in $G.ui.ChipPanel.Children) { if ($o -ne $s) { $o.IsChecked = $false } }
            $G.st.Category = $s.Content; & $G.populate
        })
        [void]$G.ui.ChipPanel.Children.Add($chip)
    }

    # ---- search / confirm / apply / expert / chrome ----
    $G.ui.SearchBox.Add_TextChanged({ & $global:gui.populate })
    $G.ui.BtnConfirmNo.Add_Click({ $global:gui.ui.ConfirmOverlay.Visibility = 'Collapsed'; $global:gui.st.Pending = $null })
    $G.ui.BtnConfirmYes.Add_Click({
        $G = $global:gui; $G.ui.ConfirmOverlay.Visibility = 'Collapsed'
        if ($G.ui.ConfirmRestore.IsChecked) { $G.ui.StatusText.Text='Creating restore point...'; New-RestorePointSafe }
        if ($G.st.Pending) { & $G.st.Pending }; $G.st.Pending = $null; & $G.populate
    })
    $G.ui.BtnApply.Add_Click({
        $G = $global:gui; $st = $G.st
        $n = switch ($st.Section) {
            'Clean'     { @($st.CleanTargets | Where-Object { $_._sel }).Count }
            'Leftovers' { @($st.Leftovers    | Where-Object { $_._sel }).Count }
            default     { $map=@{Tweaks='registry';Services='services';Debloat='debloat';Install='install'}; @($st.Catalog.($map[$st.Section]) | Where-Object { $_._sel }).Count }
        }
        if ($n -lt 1) { $G.ui.StatusText.Text = 'Nothing selected.'; return }
        $msg = switch ($st.Section) {
            'Tweaks'    { "Apply $n registry tweak(s)? This changes Windows settings." }
            'Services'  { "Change startup type on $n service(s)?" }
            'Debloat'   { "Remove $n app(s) for all users? This cannot be auto-undone." }
            'Install'   { "Install $n app(s) via winget?" }
            'Clean'     { "Clean $n location(s)? Junk files are freed (not restorable); registry traces are backed up." }
            'Leftovers' { "Remove $n ticked leftover item(s)? They are backed up and can be undone." }
        }
        $sec = $st.Section
        & $G.showConfirm $msg ({ & $global:gui.apply $sec }.GetNewClosure())
    })
    $G.ui.ExpertPhrase.Add_TextChanged({ $G=$global:gui; $G.ui.BtnExpertGo.IsEnabled = ($G.st.ExpertPhrase -and $G.ui.ExpertPhrase.Text -ceq $G.st.ExpertPhrase) })
    $G.ui.BtnExpertGo.Add_Click({
        $G = $global:gui
        if (-not $G.st.ExpertEntries -or $G.ui.ExpertPhrase.Text -cne $G.st.ExpertPhrase) { return }
        & $G.showConfirm "This WEAKENS your system. Write $($G.st.ExpertEntries.Count) registry value(s)?" ({ & $global:gui.apply 'Expert' }.GetNewClosure())
    })
    $G.ui.BtnUpdateDismiss.Add_Click({ $global:gui.ui.UpdateBanner.Visibility = 'Collapsed' })
    $G.ui.BtnUpdateGet.Add_Click({
        $G = $global:gui
        if ($G.st.UpdateUrl) { try { Start-Process $G.st.UpdateUrl } catch {} ; $G.ui.StatusText.Text = 'Opened the update download page in your browser.' }
        else { $G.ui.NavUpdates.IsChecked = $true; $G.ui.StatusText.Text = 'See the Updates section for the signed download.' }
        $G.ui.UpdateBanner.Visibility = 'Collapsed'
    })
    $G.ui.BtnClose.Add_Click({ $global:gui.win.Close() })
    $G.ui.BtnMin.Add_Click({ $global:gui.win.WindowState = 'Minimized' })
    $G.ui.BtnMax.Add_Click({ $w = $global:gui.win; $w.WindowState = $(if ($w.WindowState -eq 'Maximized') { 'Normal' } else { 'Maximized' }) })
    # maximised WindowChrome windows overflow a few px; pad + swap the icon to a restore glyph
    $win.Add_StateChanged({
        $G = $global:gui
        if ($G.win.WindowState -eq 'Maximized') { $G.ui.Root.Margin = '8'; $G.ui.MaxIcon.Data = 'M 2 2 L 10 2 L 10 10 L 2 10 Z M 0 0 L 8 0 M 0 0 L 0 8' }
        else { $G.ui.Root.Margin = '0'; $G.ui.MaxIcon.Data = 'M 0 0 L 10 0 L 10 10 L 0 10 Z' }
    })

    # view toggle (List / Grid) for Uninstall & Install
    $G.ui.ViewList.Add_Checked({ $G=$global:gui; $G.ui.ViewGrid.IsChecked=$false; $G.st.View='Compact'; & $G.populate })
    $G.ui.ViewGrid.Add_Checked({ $G=$global:gui; $G.ui.ViewList.IsChecked=$false; $G.st.View='Cards'; & $G.populate })
    $G.ui.ViewList.Add_Unchecked({ $G=$global:gui; if (-not $G.ui.ViewGrid.IsChecked) { $G.ui.ViewList.IsChecked=$true } })
    $G.ui.ViewGrid.Add_Unchecked({ $G=$global:gui; if (-not $G.ui.ViewList.IsChecked) { $G.ui.ViewGrid.IsChecked=$true } })

    # window + taskbar icon
    try { $icoPath = Join-Path $script:Root 'assets\TheOptimiser.ico'; if (Test-Path $icoPath) { $win.Icon = New-Object Windows.Media.Imaging.BitmapImage ([Uri]$icoPath) } } catch {}

    if (Test-Admin) { $G.ui.AdminText.Text = 'administrator'; $G.ui.AdminDot.Fill = $win.FindResource('Ok') }
    $G.ui.BuildText.Text = "build $($script:Build)"

    & $G.setSection 'Tweaks' 'Tweaks' 'pick what you want, then apply'
    return @{ Window = $win; UI = $G.ui }
}

function Show-Gui {
    $g = Build-OptimiserWindow
    # keep the GUI alive if a single event handler throws (don't crash out to the text menu)
    $g.Window.Dispatcher.add_UnhandledException({ param($s,$e)
        $e.Handled = $true
        try { $global:gui.ui.StatusText.Text = "A step failed: $($e.Exception.Message)" } catch {}
    })
    $g.Window.Add_Loaded({
        try { & $global:gui.scanInstalled } catch {}
        if ($DemoBanner) { & $global:gui.showUpdateBanner '9.9.9' 'https://github.com/Jambo199/TheOptimiser/releases' }
        else { try { & $global:gui.checkUpdates } catch {} }
    })
    [void]$g.Window.ShowDialog()
}

function Save-GuiPreview {
    param([string]$Path, [int]$W = 1280, [int]$H = 840, [string]$Section, [string]$View, [switch]$ShowUpdate)
    $g = Build-OptimiserWindow
    if ($Section) { $nav = @{ Debloat='NavDebloat'; Programs='NavPrograms'; Install='NavInstall'; Clean='NavClean'; Services='NavServices'; Undo='NavUndo'; Updates='NavUpdates'; Changelog='NavChangelog'; Expert='NavExpert' }[$Section]; if ($nav) { $g.UI[$nav].IsChecked = $true } }
    if ($View -eq 'Grid') { $g.UI.ViewGrid.IsChecked = $true }
    if ($ShowUpdate) { & $global:gui.showUpdateBanner '9.9.9' 'https://github.com/Jambo199/TheOptimiser/releases' }
    $root = $g.UI.Root
    $root.Width = $W; $root.Height = $H
    $root.Measure([Windows.Size]::new($W, $H))
    $root.Arrange([Windows.Rect]::new(0, 0, $W, $H))
    $root.UpdateLayout()
    $rtb = New-Object Windows.Media.Imaging.RenderTargetBitmap ($W, $H, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $rtb.Render($root)
    $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($rtb))
    $fs = [IO.File]::Open($Path, 'Create'); $enc.Save($fs); $fs.Close()
}

# --------------------------------------------------------------- self test ---
function Invoke-SelfTest {
    Write-Host "SELF TEST" -ForegroundColor Cyan
    $cat = Get-Catalog
    $checks = @(
        @{ n='registry non-empty'; ok = $cat.registry.Count -gt 0 },
        @{ n='every reg entry has hive/path/name/type'; ok = -not ($cat.registry | Where-Object { -not ($_.hive -and $_.path -and $_.name -and $_.type) }) },
        @{ n='no excluded russian proxy'; ok = -not ($cat.registry | Where-Object { $_.name -eq 'AutoConfigURL' }) },
        @{ n='debloat non-empty'; ok = $cat.debloat.Count -gt 0 },
        @{ n='advanced drivers-only keeps system updates'; ok = $cat.advanced.updates_drivers_only.Count -gt 0 }
    )
    $pass = $true
    foreach ($c in $checks) { $pass = $pass -and $c.ok; Write-Host ("  [{0}] {1}" -f ($(if($c.ok){'PASS'}else{'FAIL'}), $c.n)) -ForegroundColor ($(if($c.ok){'Green'}else{'Red'})) }

    # Dry-run apply + undo against a throwaway HKCU key (no admin, fully reversible)
    $tHive='HKCU'; $tPath='Software\TheOptimiser\SelfTest'; $tName='probe'
    try {
        $before = Set-RegValue $tHive $tPath $tName 'DWord' 12345
        $got = (Get-ItemProperty -LiteralPath "${tHive}:\$tPath" -Name $tName).$tName
        $applied = ($got -eq 12345)
        Undo-RegValue $before
        $still = Test-Path -LiteralPath "${tHive}:\$tPath"
        $removedKey = -not (Get-ItemProperty -LiteralPath "${tHive}:\$tPath" -Name $tName -ErrorAction SilentlyContinue)
        Remove-Item -LiteralPath "HKCU:\Software\TheOptimiser" -Recurse -ErrorAction SilentlyContinue
        Write-Host ("  [{0}] live apply wrote value" -f $(if($applied){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($applied){'Green'}else{'Red'}))
        Write-Host ("  [{0}] undo removed the new value" -f $(if($removedKey){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($removedKey){'Green'}else{'Red'}))
        # default-value (Atlas-style) apply + undo
        $b2 = Set-RegValue $tHive $tPath '(Default)' 'String' 'classic'
        $gotD = (Get-ItemProperty -LiteralPath "${tHive}:\$tPath").'(default)'
        $appliedD = ($gotD -eq 'classic')
        Undo-RegValue $b2
        Remove-Item -LiteralPath "HKCU:\Software\TheOptimiser" -Recurse -ErrorAction SilentlyContinue
        Write-Host ("  [{0}] default-value apply+undo" -f $(if($appliedD){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($appliedD){'Green'}else{'Red'}))
        $pass = $pass -and $applied -and $removedKey -and $appliedD
    } catch {
        Write-Host "  [FAIL] apply/undo threw: $($_.Exception.Message)" -ForegroundColor Red; $pass=$false
    }
    # ---- new features: signed updates, journals, cleaner, uninstaller ----
    $hx = { param($s) $b=New-Object byte[] ($s.Length/2); for($i=0;$i -lt $b.Length;$i++){$b[$i]=[Convert]::ToByte($s.Substring($i*2,2),16)}; ,$b }
    $p3  = & $hx 'fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025'
    $sg3 = & $hx '6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a'
    $sigOk  = Test-Ed25519 $p3 (& $hx 'af82') $sg3
    $sigBad = Test-Ed25519 $p3 (& $hx 'af83') $sg3
    Write-Host ("  [{0}] Ed25519/minisign verifies a valid signature (RFC 8032)" -f $(if($sigOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($sigOk){'Green'}else{'Red'}))
    Write-Host ("  [{0}] Ed25519/minisign rejects a tampered message" -f $(if(-not $sigBad){'PASS'}else{'FAIL'})) -ForegroundColor ($(if(-not $sigBad){'Green'}else{'Red'}))

    $rolledBack = $false
    try { Invoke-Op 'selftest-rollback' { Set-RegValue 'HKCU' 'Software\TheOptimiser\SelfTest' 'a' 'DWord' 1 | Out-Null; throw 'boom' } | Out-Null }
    catch { $rolledBack = -not (Get-ItemProperty -LiteralPath 'HKCU:\Software\TheOptimiser\SelfTest' -Name 'a' -ErrorAction SilentlyContinue) }
    Remove-Item -LiteralPath 'HKCU:\Software\TheOptimiser' -Recurse -ErrorAction SilentlyContinue
    Write-Host ("  [{0}] transactional op rolls back on mid-apply failure" -f $(if($rolledBack){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($rolledBack){'Green'}else{'Red'}))

    $ctOk = (@(Get-CleanTargets).Count -ge 10)
    $app  = [pscustomobject]@{ name='Revo Uninstaller Pro'; publisher='VS Revo Group'; location='' }
    $tok  = @(Get-AppTokens $app)
    $scoreOk = ((Get-LeftoverScore 'Revo Uninstaller Pro' $tok $app) -eq 'High') -and ($null -eq (Get-LeftoverScore 'Google Chrome' $tok $app))
    $progOk  = (@(Get-InstalledPrograms).Count -gt 0)
    # Find-Leftovers must actually accumulate hits (regression guard for a scriptblock-scope bug)
    $probeKey = 'HKCU:\Software\TheOptimiserLeftoverProbe'
    New-Item -Path $probeKey -Force | Out-Null
    $probeApp = [pscustomobject]@{ name='TheOptimiserLeftoverProbe'; publisher='TheOptimiser'; location='' }
    $lfOk = (@(Find-Leftovers $probeApp | Where-Object { $_.path -like '*TheOptimiserLeftoverProbe*' }).Count -ge 1)
    Remove-Item -Path $probeKey -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host ("  [{0}] cleaner ruleset present (winapp2 + MRU traces)" -f $(if($ctOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($ctOk){'Green'}else{'Red'}))
    Write-Host ("  [{0}] leftover confidence scoring (High/Med/Low)" -f $(if($scoreOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($scoreOk){'Green'}else{'Red'}))
    Write-Host ("  [{0}] leftover scan accumulates matches" -f $(if($lfOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($lfOk){'Green'}else{'Red'}))
    Write-Host ("  [{0}] installed-programs enumeration (Win32 + UWP)" -f $(if($progOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($progOk){'Green'}else{'Red'}))
    $verOk = (Test-NewerVersion '2.2.0' '2.1.0') -and (-not (Test-NewerVersion '2.1.0' '2.1.0')) -and (-not (Test-NewerVersion '2.0.0' '2.1.0'))
    $clOk  = (@(Get-Changelog).Count -ge 1) -and [bool]((Get-Changelog)[0].version) -and (@(Get-Changelog)[0].version -eq $script:Version)
    Write-Host ("  [{0}] update version-compare (newer only)" -f $(if($verOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($verOk){'Green'}else{'Red'}))
    Write-Host ("  [{0}] changelog present + top entry = current version" -f $(if($clOk){'PASS'}else{'FAIL'})) -ForegroundColor ($(if($clOk){'Green'}else{'Red'}))
    $pass = $pass -and $sigOk -and (-not $sigBad) -and $rolledBack -and $ctOk -and $scoreOk -and $lfOk -and $progOk -and $verOk -and $clOk

    Write-Host ("`nSELF TEST {0}" -f $(if($pass){'PASSED'}else{'FAILED'})) -ForegroundColor ($(if($pass){'Green'}else{'Red'}))
    if (-not $pass) { exit 1 }
}

# -------------------------------------------------------------------- flow ---
try { $null = [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

if ($AsLibrary) { return }
if ($SelfTest) { Invoke-SelfTest; return }
if ($GuiPreview) { if (-not $script:Build) { $script:Build = 'preview' }; Save-GuiPreview -Path $GuiPreview -ShowUpdate:$DemoBanner; Write-Host "preview saved: $GuiPreview"; return }

if (-not $Launch) {
    Show-Banner
    Ask-Questions
    if ($WantAdmin -and -not (Test-Admin)) {
        Write-Host "  Relaunching as administrator..." -ForegroundColor Cyan
        $self = try { [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { '' }
        $tail = @('-Launch','-WinBuild',"`"$script:Build`"")
        if ($NoAnimation) { $tail += '-NoAnimation' }
        if ($NoGui)       { $tail += '-NoGui' }
        if ($self -match '(?i)(powershell|pwsh)\.exe$') {
            $target = $self; $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`"") + $tail   # running as .ps1
        } else {
            $target = $self; $argList = $tail                                                                            # running as compiled .exe
        }
        try { Start-Process -FilePath $target -ArgumentList $argList -Verb RunAs; return }
        catch { Write-Host "  Elevation was declined; continuing as standard user." -ForegroundColor Yellow }
    }
} else {
    if ($WinBuild) { $script:Build = $WinBuild }
}

if (-not $script:Build) { $script:Build = try { (Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { 'unknown' } }

Show-Animation
if ($NoGui) {
    Main-Menu
} else {
    try { Show-Gui }
    catch {
        Write-Host "  GUI could not start ($($_.Exception.Message)); falling back to the text menu." -ForegroundColor Yellow
        Main-Menu
    }
}
Write-Host "`n  ThE OptImiseR has released your registry. Farewell.`n" -ForegroundColor DarkRed
