<# : PC-Diagnostics - batch launcher (keep this first line exactly as it is)
@echo off
setlocal
set "DIAG_BAT=%~f0"
set "DIAG_ARGS=%*"
title PC Diagnostics
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PSEXE=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PSEXE%" -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "&([ScriptBlock]::Create([IO.File]::ReadAllText($env:DIAG_BAT, [Text.Encoding]::UTF8)))"
if errorlevel 1 if "%~1"=="" pause
exit /b
#>
<#
  PC-Diagnostics.bat - Windows PC diagnostics with Italian and English reports.
  Supported: Windows 7 SP1, 8, 8.1, 10, 11 (Windows PowerShell 2.0 to 5.1).

  Usage: right-click the file > "Run as administrator", confirm the operating system,
  choose the analysis with the arrow keys and press Enter.
  Everything is READ-ONLY: no settings, drivers, registry keys or system files are changed.

  Output (on the Desktop of the signed-in user; fallback C:\PC-Diagnosis):
    PC-Diagnosis_<PC>_<date>\REPORT_IT.html / REPORT_EN.html   (double-click: opens in the browser)
    PC-Diagnosis_<PC>_<date>\REPORT_IT.md   / REPORT_EN.md
    PC-Diagnosis_<PC>_<date>\data\...                           (raw data, event logs, dumps)
    PC-Diagnosis_<PC>_<date>\PC-Diagnosis_<PC>_<date>.zip       (everything, to send to support)

  Unattended use (no menus):  PC-Diagnostics.bat normal|stress|deepscan  [win7|win8|win10|win11]  [quick]
    quick = short run for testing (15 s sampling, no energy report)
  Optional environment variables: DIAG_OUT (output folder), DIAG_SAMPLE (sampling seconds), DIAG_SKIPENERGY=1

  Rules for maintainers:
  - The code must parse and run on Windows PowerShell 2.0 / .NET 3.5: no -in/-notin, -shr/-shl, [ordered],
    [pscustomobject], ::new(), "Where-Object Name" short syntax, -File/-Directory/-Raw, or .NET 4 APIs.
    Newer cmdlets are only used after checking that they exist (function Has).
  - The code runs inside a script block: do not use $script: variables, and do not reuse the names of
    variables read by helper functions ($raw, $out, $log, $R, $Verdicts, $Actions) inside the steps.
  - File format: UTF-8 WITHOUT BOM and CRLF line endings, otherwise the batch header stops working.
  - "-ExecutionPolicy Bypass" only affects this process: with the default "Restricted" policy some inbox
    commands implemented as script modules (e.g. Compress-Archive) would not load. A Group Policy setting still wins.
#>

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'PC Diagnostics' } catch { }
$interactive = ($Host.Name -eq 'ConsoleHost')

function Clear-KeyBuffer { try { $Host.UI.RawUI.FlushInputBuffer() } catch { try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } } catch { } } }
function Wait-Key { if ($interactive) { Clear-KeyBuffer; try { [void][Console]::ReadKey($true) } catch { } } }

# ============================== ARGUMENTS ==============================
$argTokens = @("$env:DIAG_ARGS".ToLower() -split '[\s"]+' | Where-Object { $_ })
$mode = @($argTokens | Where-Object { @('normal', 'stress', 'deepscan') -contains $_ })[0]
$osArg = @($argTokens | Where-Object { @('win7', 'win8', 'win10', 'win11') -contains $_ })[0]
$quick = $argTokens -contains 'quick'
$unattended = [bool]$mode

# ============================== ADMIN CHECK ==============================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host ''
    Write-Host '  Run me as administrator!' -ForegroundColor Red
    Write-Host '  Right-click PC-Diagnostics.bat and choose "Run as administrator".' -ForegroundColor Gray
    Write-Host ''
    if (-not $unattended) { Write-Host '  Press any key to exit...' -ForegroundColor DarkGray; Wait-Key }
    return
}

# ============================== NATIVE HELPERS (keep awake, console input) ==============================
$Native = $false
try {
    Add-Type -Namespace Diag -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint esFlags);
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
    $Native = $true
} catch { }
[uint32]$ConsoleModeOld = 0
$ConsoleIn = [IntPtr]::Zero
function Set-QuickEdit([bool]$enable) {
    # in the classic console a click in the window (QuickEdit selection) pauses the program: disable it while running
    if (-not $Native) { return }
    try {
        if (-not $enable) {
            $ConsoleIn = [Diag.Native]::GetStdHandle(-10)
            [uint32]$m = 0
            if ([Diag.Native]::GetConsoleMode($ConsoleIn, [ref]$m)) {
                Set-Variable -Name ConsoleModeOld -Value $m -Scope 1
                Set-Variable -Name ConsoleIn -Value $ConsoleIn -Scope 1
                [void][Diag.Native]::SetConsoleMode($ConsoleIn, [uint32](($m -band (-bnot 0x40)) -bor 0x80))
            }
        } elseif ($ConsoleModeOld -ne 0) { [void][Diag.Native]::SetConsoleMode($ConsoleIn, $ConsoleModeOld) }
    } catch { }
}
function Set-KeepAwake([bool]$on) {
    # prevents sleep and screen-off during the analysis (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
    if (-not $Native) { return }
    try { if ($on) { [void][Diag.Native]::SetThreadExecutionState([uint32]2147483651) } else { [void][Diag.Native]::SetThreadExecutionState([uint32]2147483648) } } catch { }
}

# ============================== COMPATIBILITY HELPERS ==============================
$PSV = $PSVersionTable.PSVersion.Major
$PSVText = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)"
# version and build from WMI; [Environment]::OSVersion is only a fallback (it can be altered by compatibility mode)
$OsWmi = $null
try { $OsWmi = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop | Select-Object -First 1 } catch { }
$WinVer = [Environment]::OSVersion.Version
if ($OsWmi -and $OsWmi.Version) { try { $WinVer = New-Object Version ([string]$OsWmi.Version) } catch { } }
$WinBuild = $WinVer.Build
$IsWin7 = ($WinVer.Major -eq 6 -and $WinVer.Minor -le 1)
$IsWin8Plus = ($WinVer.Major -ge 10 -or ($WinVer.Major -eq 6 -and $WinVer.Minor -ge 2))
$Legacy = $false
$UseCim = $false

function Get-DetectedOs {
    if ($IsWin7) { return 'win7' }
    if ($WinVer.Major -eq 6) { return 'win8' }
    if ($WinBuild -ge 22000) { return 'win11' }
    return 'win10'
}
$OsNames = @{ win7 = 'Windows 7'; win8 = 'Windows 8 / 8.1'; win10 = 'Windows 10'; win11 = 'Windows 11' }

function Has([string]$cmd) {
    # a modern cmdlet is used only if it exists and the "Windows 7" profile (legacy methods) is not selected
    if ($Legacy) { return $false }
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Wmi([string]$Class, [string]$Namespace = 'root\cimv2', [string]$Filter = '') {
    # Get-CimInstance on PowerShell 3+, WMI searcher on PowerShell 2 or when legacy methods are selected.
    # Both stop after 2 minutes, so one stuck WMI provider cannot block the whole analysis.
    try {
        if ($UseCim) {
            if ($Filter) { Get-CimInstance -ClassName $Class -Namespace $Namespace -Filter $Filter -OperationTimeoutSec 120 -ErrorAction Stop }
            else { Get-CimInstance -ClassName $Class -Namespace $Namespace -OperationTimeoutSec 120 -ErrorAction Stop }
        } else {
            $q = "SELECT * FROM $Class"; if ($Filter) { $q += " WHERE $Filter" }
            $srch = New-Object Management.ManagementObjectSearcher($Namespace, $q)
            $srch.Options.Timeout = [TimeSpan]::FromSeconds(120)
            $res = @($srch.Get())
            $res
        }
    } catch { }
}

function ToDate($v) {
    # CIM returns DateTime, WMI returns DMTF strings (20260909185925.000000+120)
    if ($v -is [datetime]) { return $v }
    if ($v) {
        try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$v) } catch { }
        $dt = [datetime]::MinValue
        if ([datetime]::TryParse([string]$v, [ref]$dt)) { return $dt }
    }
    return $null
}

function NewObj([object[]]$pairs) {
    # ordered object compatible with PowerShell 2.0 (no [pscustomobject])
    $o = New-Object PSObject
    for ($i = 0; $i -lt $pairs.Count; $i += 2) { Add-Member -InputObject $o -MemberType NoteProperty -Name $pairs[$i] -Value $pairs[$i + 1] }
    return $o
}

function ReadText([string]$path) { try { return [IO.File]::ReadAllText($path) } catch { return '' } }
function Pl($n, [string]$one, [string]$many) { if ($n -eq 1) { return $one } else { return $many } }
$CultIt = [Globalization.CultureInfo]::GetCultureInfo('it-IT')
$CultEn = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Num($v, [string]$lng, [string]$fmt = '0.#') {
    if ($v -eq $null -or "$v" -eq '' -or "$v" -eq '-') { return "$v" }
    $c = $CultEn; if ($lng -eq 'it') { $c = $CultIt }
    try { return ([double]$v).ToString($fmt, $c) } catch { return "$v" }
}

function Test-Tcp([string]$target, [int]$port, [int]$timeoutMs = 3000) {
    # TCP connection test (works where ICMP ping is blocked); .NET 2.0 compatible
    $c = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $c.BeginConnect($target, $port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($timeoutMs, $false) -and $c.Connected) { $c.EndConnect($ar); return $true }
        return $false
    } catch { return $false } finally { try { $c.Close() } catch { } }
}

function Get-EventData($e) {
    $vals = @()
    try { ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { if ($_.'#text') { $vals += $_.'#text' } else { $vals += "$_" } } } catch { }
    return ,$vals
}

function Get-LastAlive($ev6008, $lo, $hi) {
    # event 6008 stores time and date of the unexpected shutdown as two localized strings, which can contain AM/PM
    # and invisible direction marks. Several cultures are tried; only a time inside the crashed session is accepted.
    $d = Get-EventData $ev6008
    if ($d.Count -lt 2) { return $null }
    $t = ([regex]::Replace("$($d[0])", '\p{Cf}', '')).Trim()
    $dd = ([regex]::Replace("$($d[1])", '\p{Cf}', '')).Trim()
    foreach ($cu in @([Globalization.CultureInfo]::CurrentCulture, [Globalization.CultureInfo]::InstalledUICulture, [Globalization.CultureInfo]::InvariantCulture)) {
        $dt = [datetime]::MinValue
        try {
            if ([datetime]::TryParse("$dd $t", $cu, [Globalization.DateTimeStyles]::None, [ref]$dt)) {
                if ((-not $hi -or $dt -le $hi) -and (-not $lo -or $dt -ge $lo)) { return $dt }
            }
        } catch { }
    }
    return $null
}

# ============================== MENUS ==============================
function Write-At([int]$row, [string]$text, [string]$fg = 'Gray') {
    $w = 79
    try { $w = [Math]::Max(20, [Console]::WindowWidth - 1) } catch { }
    if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
    [Console]::SetCursorPosition(0, $row)
    Write-Host $text.PadRight($w) -ForegroundColor $fg -NoNewline
}

function Split-Words([string]$text, [int]$width) {
    $lines = @(); $cur = ''
    foreach ($word in ($text -split ' ')) {
        if (($cur + ' ' + $word).Trim().Length -gt $width) { $lines += $cur; $cur = $word } else { $cur = ($cur + ' ' + $word).Trim() }
    }
    if ($cur) { $lines += $cur }
    return ,$lines
}

function Show-Header([int]$W) {
    Clear-Host
    Write-Host ''
    Write-Host ('  ' + ('=' * $W)) -ForegroundColor Cyan
    Write-Host ('  ' + (' ' * [Math]::Max(0, [int](($W - 14) / 2))) + 'PC DIAGNOSTICS') -ForegroundColor White
    Write-Host ('  ' + (' ' * [Math]::Max(0, [int](($W - 50) / 2))) + 'Read-only checks - reports in Italian and English') -ForegroundColor DarkGray
    Write-Host ('  ' + ('=' * $W)) -ForegroundColor Cyan
    Write-Host ''
}

function Show-Menu([string]$title, [object[]]$items, [int]$start = 0) {
    # vertical menu: arrows or number keys move, Enter confirms, Esc returns 'exit'
    $ww = 80
    try { $ww = [Console]::WindowWidth } catch { }
    $W = [Math]::Min(66, [Math]::Max(50, $ww - 6))
    $sep = '  ' + ('-' * $W)
    Show-Header $W
    Write-Host ('  ' + $title) -ForegroundColor White
    Write-Host ''
    $top = [Console]::CursorTop
    $panel = $top + $items.Count + 1
    $help = $panel + 7
    for ($r = $top; $r -le $help + 1; $r++) { Write-Host '' }
    $top = [Console]::CursorTop - ($help + 2 - $top); $panel = $top + $items.Count + 1; $help = $panel + 7
    $sel = $start
    $maxKey = [Math]::Min(9, $items.Count)
    try { [Console]::CursorVisible = $false } catch { }
    Clear-KeyBuffer
    try {
        while ($true) {
            for ($i = 0; $i -lt $items.Count; $i++) {
                $label = '{0})  {1}' -f ($i + 1), $items[$i].Label
                if ($i -eq $sel) {
                    Write-At ($top + $i) ''
                    [Console]::SetCursorPosition(3, $top + $i)
                    Write-Host (' > ' + $label.PadRight(24)) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
                } else { Write-At ($top + $i) ('      ' + $label) 'Gray' }
            }
            $it = $items[$sel]
            Write-At $panel $sep 'DarkCyan'
            $desc = Split-Words $it.Desc ($W - 2)
            $color = 'White'; if ($it.Warn) { $color = 'Yellow' }
            for ($j = 0; $j -lt 3; $j++) { $t = ''; if ($j -lt $desc.Count) { $t = '   ' + $desc[$j] }; Write-At ($panel + 1 + $j) $t $color }
            $t = ''; if ($it.Info) { $t = '   ' + $it.Info }; Write-At ($panel + 4) $t 'DarkGray'
            Write-At ($panel + 5) $sep 'DarkCyan'
            Write-At $help ("   Up/Down: move     Enter: confirm     1-$($maxKey): select     Esc: exit") 'DarkGray'
            $k = [Console]::ReadKey($true)
            $key = $k.Key.ToString()
            if ($key -eq 'UpArrow') { $sel = ($sel - 1 + $items.Count) % $items.Count }
            elseif ($key -eq 'DownArrow') { $sel = ($sel + 1) % $items.Count }
            elseif ($key -match '^(D|NumPad)([1-9])$') { $n = [int]$matches[2] - 1; if ($n -lt $items.Count) { $sel = $n } }
            elseif ($key -eq 'Enter') { [Console]::SetCursorPosition(0, $help + 2); return $items[$sel].Key }
            elseif ($key -eq 'Escape') { [Console]::SetCursorPosition(0, $help + 2); return 'exit' }
        }
    } finally { try { [Console]::CursorVisible = $true } catch { } }
}

# ============================== CHOICES ==============================
$detected = Get-DetectedOs
$osCaption = ''
if ($OsWmi) { $osCaption = "$($OsWmi.Caption)" }
if (-not $osCaption) { $osCaption = $OsNames[$detected] }
$osCaption = ($osCaption -replace '^Microsoft\s+', '').Trim()

if ($unattended) { $os = $detected; if ($osArg) { $os = $osArg } }
else {
    if (-not $interactive) { Write-Host 'Interactive console required (or pass: normal | stress | deepscan).'; return }
    $keys = @('win7', 'win8', 'win10', 'win11')
    $osItems = @()
    foreach ($k in $keys) {
        $det = ''; if ($k -eq $detected) { $det = '  (detected)' }
        $d = 'All checks, including disk health counters, Defender status and file system scan.'
        if ($k -eq 'win7') { $d = 'Compatible methods only (WMI, registry, classic commands). Works with PowerShell 2.0. Can also be used to force compatibility mode.' }
        if ($k -eq 'win8') { $d = 'Compatible methods plus the newer Windows 8 commands when they are available.' }
        $osItems += @{ Key = $k; Label = $OsNames[$k] + $det; Info = ''; Desc = $d }
    }
    $di = [array]::IndexOf($keys, $detected)
    $osItems[$di].Info = "Detected: $osCaption, build $WinBuild - PowerShell $PSVText"
    $os = 'exit'
    try { $os = Show-Menu 'Confirm the operating system (Enter) or choose another one:' $osItems $di }
    catch { Write-Host ''; Write-Host "  Menu error: $($_.Exception.Message)" -ForegroundColor Red; Write-Host '  Tip: enlarge the window, or run: PC-Diagnostics.bat normal' -ForegroundColor Gray; $os = 'exit' }
    if ($keys -notcontains $os) { Write-Host '  Nothing was run. Press any key to exit...'; Wait-Key; return }
    $modeItems = @(
        @{ Key = 'normal';   Label = 'Normal';   Info = 'Duration: about 5 minutes'
           Desc = 'Standard checks: system, disk, memory, crashes, power and battery, temperatures, network, security and updates.' }
        @{ Key = 'stress';   Label = 'Stress';   Info = 'Duration: about 12 minutes - keep the charger connected'; Warn = $true
           Desc = 'Standard checks plus the processor at 100% for 10 minutes, to test cooling and power supply. Save any open work first!' }
        @{ Key = 'deepscan'; Label = 'DeepScan'; Info = 'Duration: up to 20 minutes'
           Desc = 'Standard checks plus a read-only check of Windows system files (sfc) and of the disk file system (chkdsk).' }
        @{ Key = 'exit';     Label = 'Exit';     Info = ''
           Desc = 'Close the program without running anything.' }
    )
    $mode = 'exit'
    try { $mode = Show-Menu ("System: $($OsNames[$os]). Choose the analysis:") $modeItems 0 }
    catch { Write-Host ''; Write-Host "  Menu error: $($_.Exception.Message)" -ForegroundColor Red; $mode = 'exit' }
    if (@('normal', 'stress', 'deepscan') -notcontains $mode) { Write-Host '  Nothing was run. Press any key to exit...'; Wait-Key; return }
    if ($mode -eq 'stress') {
        Write-Host '  The CPU will run at 100% for 10 minutes. Save any open work and keep the charger connected.' -ForegroundColor Yellow
        Write-Host '  Continue? (Y/N) ' -NoNewline
        Clear-KeyBuffer
        $ans = ''
        try { $ans = [Console]::ReadKey($true).KeyChar } catch { }
        Write-Host $ans
        if ("$ans" -notmatch '^[yYsS]$') { Write-Host '  Cancelled. Nothing was run. Press any key to exit...'; Wait-Key; return }
    }
}

$Legacy = ($os -eq 'win7') -or ($PSV -lt 3)
$UseCim = (-not $Legacy) -and [bool](Get-Command Get-CimInstance -ErrorAction SilentlyContinue)

# ============================== SETTINGS AND OUTPUT FOLDER ==============================
$Days = 60
$SampleSeconds = 120
$Stress = $mode -eq 'stress'
$DeepScan = $mode -eq 'deepscan'
$SkipEnergy = $env:DIAG_SKIPENERGY -eq '1'
$SkipNetwork = $false
if ($Stress) { $SampleSeconds = 600 }
if ("$env:DIAG_SAMPLE" -match '^\d+$') { $SampleSeconds = [int]$env:DIAG_SAMPLE }
if ($quick) { $SampleSeconds = 15; $SkipEnergy = $true }
$NotAvailable = New-Object 'System.Collections.Generic.List[object]'
$EvErrors = New-Object 'System.Collections.Generic.List[string]'

function Get-InteractiveSid {
    # SID of the user signed in to this console session (owner of explorer.exe)
    try {
        $mySession = (Get-Process -Id $PID).SessionId
        $exp = @(Wmi 'Win32_Process' -Filter "Name='explorer.exe'") | Where-Object { $_.SessionId -eq $mySession } | Select-Object -First 1
        if ($exp) { if ($UseCim) { return (Invoke-CimMethod -InputObject $exp -MethodName GetOwnerSid -ErrorAction Stop).Sid } else { return $exp.GetOwnerSid().Sid } }
    } catch { }
    return $null
}

function Get-InteractiveDesktop {
    # Desktop of the signed-in user, even when elevation used a different administrator account
    try {
        if ($UserSid) {
            $sid = $UserSid
            $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            if ($sid -and $sid -ne $me) {
                $profilePath = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid" -ErrorAction Stop).ProfileImagePath
                $key = Get-Item "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction Stop
                $rawDesk = $key.GetValue('Desktop', $null, 'DoNotExpandEnvironmentNames')
                if ($rawDesk) {
                    $dsk = [Environment]::ExpandEnvironmentVariables(($rawDesk -replace '%USERPROFILE%', $profilePath))
                    if (Test-Path -LiteralPath $dsk) { return $dsk }
                }
                $dsk = Join-Path $profilePath 'Desktop'
                if (Test-Path -LiteralPath $dsk) { return $dsk }
            }
        }
    } catch { }
    return [Environment]::GetFolderPath('Desktop')
}

$UserSid = Get-InteractiveSid
$stamp = (Get-Date).ToString('yyyyMMdd_HHmmss', $Inv)
$runName = "PC-Diagnosis_$($env:COMPUTERNAME)_$stamp"
$out = $null
$roots = @()
if ($env:DIAG_OUT) { $roots += $env:DIAG_OUT }
$roots += (Get-InteractiveDesktop)
$roots += (Join-Path $env:SystemDrive 'PC-Diagnosis')
foreach ($root0 in $roots) {
    if (-not $root0 -or $root0 -match '[\[\]]') { continue }      # [ ] are wildcards for PowerShell: log, CSV and zip would fail
    try {
        $cand = Join-Path $root0 $runName
        New-Item -ItemType Directory -Path $cand -Force -ErrorAction Stop | Out-Null
        [IO.File]::WriteAllText((Join-Path $cand 'run_log.txt'), '')
        $out = $cand
        break
    } catch { }
}
if (-not $out) { Write-Host '  ERROR: no writable folder for the results (Desktop or C:\PC-Diagnosis).' -ForegroundColor Red; Wait-Key; return }
$since = (Get-Date).AddDays(-$Days)
$raw = Join-Path $out 'data'
New-Item -ItemType Directory $raw -Force | Out-Null
$log = Join-Path $out 'run_log.txt'

$R = @{}
foreach ($k in 'Boots','Resumes','Crash41','Unexpected','DumpFailed','DumpInitFailed','DiskErrors','OtherDiskErrors','UnattributedDiskErrors','NtfsErrors','Whea',
               'WheaCorrected','Thermal','AcpiErrors','Throttle37','SvcErrors','SvcCrashes','Crashes','Power','PowerBeforeCrash','UpdatesOk',
               'UpdatesFailed','UpdatesFailedApps','AppCrashes','AppTop','IoErrors','IoDiag','PnpDisk','Minidump','LiveDump','Wer','Samples',
               'TopRam','NetConfig','NetErrors','Antivirus','Firewall','FailedLogonTypes','Startup','RecentSoftware','StoppedServices',
               'RamModules','MemTest','WheaMem','LowMemory','Disks','DiskHealth','Volumes','BadDevices','UnclearDevices','DisabledDevices',
               'PrevWindows','BiosHp','ThirdPartyFw','Tdr','GpuWatchdog') { $R[$k] = @() }
$Verdicts = New-Object 'System.Collections.Generic.List[object]'
$Actions  = New-Object 'System.Collections.Generic.List[object]'

function Log($t) {
    $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $t; Write-Host $l
    # the file can be briefly locked by antivirus or cloud sync of the Desktop: retry, the log is best effort
    for ($i = 0; $i -lt 5; $i++) { try { Add-Content -LiteralPath $log -Value $l -Encoding UTF8 -ErrorAction Stop; break } catch { Start-Sleep -Milliseconds 200 } }
}
function Step($stepName, [scriptblock]$sb) { Log "-> $stepName"; try { & $sb } catch { Log "   ERROR in '$stepName' (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)" } }
function Csv($data, $file) {
    if ($null -eq $data) { $data = @($input) }
    $p = Join-Path $raw $file; $rows = @($data | Where-Object { $_ })
    try { if ($rows.Count) { $rows | Export-Csv -Path $p -NoTypeInformation -Encoding UTF8 } else { Set-Content -Path $p -Value '(no data)' } } catch { Log "   cannot write $file" }
}
function EvSel { $input | Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, @{n='Message';e={ ($_.Message -replace "`r?`n",' | ') }} }
function Ev($filter, [int]$Max = 0) {
    # when display language and regional format differ, Get-WinEvent can return empty messages:
    # align the regional culture with the display language during the query, then restore it
    $th = [Threading.Thread]::CurrentThread; $cc = $th.CurrentCulture
    try {
        if ($th.CurrentUICulture.Name -and $th.CurrentUICulture.Name -ne $cc.Name) { try { $th.CurrentCulture = [Globalization.CultureInfo]::CreateSpecificCulture($th.CurrentUICulture.Name) } catch { } }
        if ($Max -gt 0) { Get-WinEvent -FilterHashtable $filter -MaxEvents $Max -ErrorAction Stop } else { Get-WinEvent -FilterHashtable $filter -ErrorAction Stop }
    }
    catch { if ("$($_.FullyQualifiedErrorId)" -notmatch 'NoMatching|LogsAndProvidersDontOverlap') { $EvErrors.Add("$($filter.LogName) / $($filter.ProviderName): $($_.Exception.Message)") } }
    finally { try { $th.CurrentCulture = $cc } catch { } }
}
function XD($e) { $d = @{}; try { ([xml]$e.ToXml()).Event.EventData.Data | ForEach-Object { if ($_.Name) { $d[$_.Name] = $_.'#text' } } } catch { }; $d }
function Verdict($areaIt, $areaEn, $state, $detIt, $detEn) { $Verdicts.Add((NewObj @('It', $areaIt, 'En', $areaEn, 'State', $state, 'DetIt', $detIt, 'DetEn', $detEn))) }
function Action($it, $en) { if (-not @($Actions | Where-Object { $_.It -eq $it }).Count) { $Actions.Add((NewObj @('It', $it, 'En', $en))) } }
function NA($it, $en) { $NotAvailable.Add((NewObj @('It', $it, 'En', $en))) }

Set-QuickEdit $false
Set-KeepAwake $true
Log "PC Diagnostics - system: $($OsNames[$os]) (detected: $osCaption build $WinBuild, PowerShell $PSVText, compatible methods: $Legacy) - mode: $mode - output: $out"

# code (decimal) -> name (it|en), Italian meaning, English meaning, category
$BugMap = @{
    0   = @('Spegnimento improvviso|Sudden shutdown', 'Il computer si è spento di colpo, senza schermata blu: mancanza di corrente, batteria scarica, blocco totale o spegnimento forzato.', 'The computer turned off abruptly without a blue screen: power loss, flat battery, complete freeze or forced shutdown.', 'power')
    10  = @('IRQL_NOT_LESS_OR_EQUAL', 'Errore di un driver o della memoria.', 'Driver or memory error.', 'memdrv')
    25  = @('BAD_POOL_HEADER', 'Errore di gestione della memoria, spesso causato da un driver.', 'Memory management error, often caused by a driver.', 'memdrv')
    26  = @('MEMORY_MANAGEMENT', 'Errore grave nella gestione della memoria: spesso RAM difettosa, a volte un driver.', 'Serious memory management error: often faulty RAM, sometimes a driver.', 'memdrv')
    30  = @('KMODE_EXCEPTION_NOT_HANDLED', 'Errore grave del sistema con molte cause possibili.', 'Serious system error with many possible causes.', 'other')
    36  = @('NTFS_FILE_SYSTEM', 'Errore del file system del disco.', 'Disk file system error.', 'disk')
    59  = @('SYSTEM_SERVICE_EXCEPTION', 'Errore in un servizio di sistema o in un driver.', 'Error in a system service or a driver.', 'driver')
    74  = @('IRQL_GT_ZERO_AT_SYSTEM_SERVICE', 'Un driver ha lasciato il sistema in uno stato non valido.', 'A driver left the system in an invalid state.', 'driver')
    80  = @('PAGE_FAULT_IN_NONPAGED_AREA', 'Accesso a memoria non valida: RAM o driver difettoso.', 'Invalid memory access: faulty RAM or driver.', 'memdrv')
    105 = @('IO1_INITIALIZATION_FAILED', "Windows non è riuscito ad avviare la gestione del disco all'accensione.", 'Windows could not start disk input/output at boot.', 'disk')
    119 = @('KERNEL_STACK_INPAGE_ERROR', 'Windows non è riuscito a rileggere dati salvati sul disco (a volte la causa è la RAM).', 'Windows could not read back data stored on the disk (sometimes the cause is RAM).', 'diskmem')
    122 = @('KERNEL_DATA_INPAGE_ERROR', 'Windows non è riuscito a rileggere dati salvati sul disco (a volte la causa è la RAM).', 'Windows could not read back data stored on the disk (sometimes the cause is RAM).', 'diskmem')
    123 = @('INACCESSIBLE_BOOT_DEVICE', 'Windows non trova o non riesce a leggere il disco di avvio.', 'Windows cannot find or read the boot disk.', 'disk')
    126 = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'Errore causato di solito da un driver.', 'Error usually caused by a driver.', 'driver')
    127 = @('UNEXPECTED_KERNEL_MODE_TRAP', 'Errore del processore: spesso hardware (RAM, surriscaldamento) o driver.', 'Processor trap: often hardware (RAM, overheating) or a driver.', 'hw')
    159 = @('DRIVER_POWER_STATE_FAILURE', 'Un dispositivo non ha risposto durante la sospensione o il risveglio.', 'A device did not respond during sleep or wake-up.', 'drvpower')
    194 = @('BAD_POOL_CALLER', 'Errore di gestione della memoria da parte di un driver.', 'Memory management error caused by a driver.', 'memdrv')
    209 = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', "Un driver ha causato l'errore.", 'A driver caused the error.', 'driver')
    239 = @('CRITICAL_PROCESS_DIED', 'Un processo vitale di Windows si è chiuso inaspettatamente (cause possibili: disco, driver, file di sistema).', 'A vital Windows process stopped unexpectedly (possible causes: disk, driver, system files).', 'other')
    244 = @('CRITICAL_OBJECT_TERMINATION', 'Un processo vitale di Windows è terminato, spesso per problemi del disco o del suo driver.', 'A vital Windows process ended, often because of the disk or its driver.', 'other')
    257 = @('CLOCK_WATCHDOG_TIMEOUT', 'Un core del processore ha smesso di rispondere: spesso hardware, BIOS o surriscaldamento.', 'A processor core stopped responding: often hardware, BIOS or overheating.', 'hw')
    278 = @('VIDEO_TDR_FAILURE', 'La scheda video ha smesso di rispondere e non è stato possibile ripristinarla.', 'The graphics card stopped responding and could not be recovered.', 'gpu')
    292 = @('WHEA_UNCORRECTABLE_ERROR', 'Errore hardware grave segnalato dal processore.', 'Serious hardware error reported by the processor.', 'hw')
    307 = @('DPC_WATCHDOG_VIOLATION', 'Un componente non ha risposto in tempo, spesso il disco o un driver.', 'A component did not respond in time, often the disk or a driver.', 'diskdrv')
    313 = @('KERNEL_SECURITY_CHECK_FAILURE', 'Errore di integrità, spesso causato da un driver o dalla memoria.', 'Integrity error, often caused by a driver or memory.', 'memdrv')
    340 = @('UNEXPECTED_STORE_EXCEPTION', 'Errore nel recupero di dati salvati su disco o compressi in memoria.', 'Error retrieving data stored on the disk or compressed in memory.', 'diskmem')
}
$CatNames = @{
    disk = @('disco','disk'); diskmem = @('disco o memoria','disk or memory'); power = @('spegnimento improvviso','abrupt shutdown')
    memdrv = @('memoria o driver','memory or driver'); driver = @('driver','driver'); hw = @('hardware','hardware')
    diskdrv = @('disco o driver','disk or driver'); drvpower = @('driver o alimentazione','driver or power'); gpu = @('scheda video','graphics'); other = @('causa non determinata','undetermined cause')
}

# ============================== DATA COLLECTION ==============================

Step 'System information' {
    $cs = Wmi 'Win32_ComputerSystem' | Select-Object -First 1
    $bios = Wmi 'Win32_BIOS' | Select-Object -First 1
    $os0 = Wmi 'Win32_OperatingSystem' | Select-Object -First 1
    $cpu = Wmi 'Win32_Processor' | Select-Object -First 1
    $R.Cs = $cs; $R.Bios = $bios; $R.Os = $os0; $R.Cpu = $cpu
    $R.BiosDate = ToDate $bios.ReleaseDate; $R.InstallDate = ToDate $os0.InstallDate; $R.LastBoot = ToDate $os0.LastBootUpTime
    $R.Ubr = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).UBR
    $R.SecureBoot = 'unknown'
    if ($IsWin7) { $R.SecureBoot = 'na' }
    elseif (Has 'Confirm-SecureBootUEFI') { try { if (Confirm-SecureBootUEFI -ErrorAction Stop) { $R.SecureBoot = 'on' } else { $R.SecureBoot = 'off' } } catch { } }
    if ($R.SecureBoot -eq 'unknown') {
        $sbv = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
        if ($sbv -eq 1) { $R.SecureBoot = 'on' } elseif ($sbv -eq 0) { $R.SecureBoot = 'off' } else { $R.SecureBoot = 'na' }
    }
    $R.Gpu = (@(Wmi 'Win32_VideoController') | ForEach-Object { $_.Name }) -join ', '
    $R.BiosAge = $null; if ($R.BiosDate) { $R.BiosAge = [int]((Get-Date) - $R.BiosDate).TotalDays }
    Csv (@(Wmi 'Win32_PnPSignedDriver') | Where-Object { $_.DeviceName } | Select-Object DeviceName, DeviceClass, Manufacturer, DriverVersion, @{n='DriverDate';e={ ToDate $_.DriverDate }}) 'drivers.csv'
    Csv (@(Wmi 'Win32_Processor') | Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed, CurrentClockSpeed) 'processor.csv'
    # previous Windows versions (the registry keeps the name "Windows 10" also on Windows 11: fix it by build number)
    $R.PrevWindows = @(Get-ItemProperty 'HKLM:\SYSTEM\Setup\Source OS*' -ErrorAction SilentlyContinue | ForEach-Object {
        $pn = "$($_.ProductName)"; if ([int]"0$($_.CurrentBuild)" -ge 22000) { $pn = $pn -replace 'Windows 10', 'Windows 11' }
        "$pn build $($_.CurrentBuild)" } | Select-Object -Unique)
    $hp = @(Wmi 'HP_BIOSEnumeration' 'root\HP\InstrumentedBIOS' | Select-Object Name, CurrentValue)
    if ($hp.Count) {
        Csv $hp 'bios_hp_settings.csv'
        $R.BiosHp = @($hp | Where-Object { $_.Name -match 'VMD|RAID|SATA|Storage|Secure Boot|Fan|Thermal|Legacy|Boot Mode|Virtualization' })
    }
    # how far back the System event log goes (it can be shorter than the analysed period)
    $R.LogFrom = $null
    try { $R.LogFrom = (Get-WinEvent -LogName System -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { }
}

Step 'Disk, free space and health' {
    $pd = @()
    if (Has 'Get-PhysicalDisk') {
        $pd = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            NewObj @('FriendlyName', $_.FriendlyName, 'Type', ("$($_.BusType) $($_.MediaType)" -replace 'Unspecified', '').Trim(), 'Firmware', $_.FirmwareVersion, 'Health', "$($_.HealthStatus)", 'Status', "$($_.OperationalStatus)", 'SizeGB', [math]::Round($_.Size / 1GB, 1)) })
    }
    if (-not $pd.Count) {
        # Windows 7 / compatible methods: Win32_DiskDrive status plus the SMART failure prediction flag
        $pred = @(Wmi 'MSStorageDriver_FailurePredictStatus' 'root\wmi')
        $pd = @(@(Wmi 'Win32_DiskDrive') | ForEach-Object {
            $dd = $_; $pf = $false
            $hasPred = $false
            foreach ($p in $pred) { if ($p.InstanceName -and $dd.PNPDeviceID -and ($p.InstanceName.ToUpper().StartsWith($dd.PNPDeviceID.ToUpper()))) { $hasPred = $true; if ($p.PredictFailure) { $pf = $true } } }
            # without SMART data the health of the disk is unknown, not "healthy"
            $health = 'Unknown'; if ($pf) { $health = 'Warning' } elseif ($dd.Status -ne 'OK') { $health = "$($dd.Status)" } elseif ($hasPred) { $health = 'Healthy' }
            NewObj @('FriendlyName', $dd.Model, 'Type', "$($dd.InterfaceType)", 'Firmware', $dd.FirmwareRevision, 'Health', $health, 'Status', "$($dd.Status)", 'SizeGB', [math]::Round($dd.Size / 1GB, 1)) })
        if ($pred.Count -eq 0) { NA 'Previsione guasti SMART dei dischi (non esposta dal controller)' 'Disk SMART failure prediction (not exposed by the controller)' }
    }
    Csv $pd 'disk_physical.csv'
    $rc = @()
    if ((Has 'Get-StorageReliabilityCounter') -and (Has 'Get-PhysicalDisk')) {
        $rc = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
            $d = $_; $c = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
            NewObj @('Disk', $d.FriendlyName, 'Temp', $c.Temperature, 'TempMax', $c.TemperatureMax, 'Wear', $c.Wear, 'Hours', $c.PowerOnHours, 'ReadErrors', $c.ReadErrorsUncorrected, 'WriteErrors', $c.WriteErrorsUncorrected) })
    } else { NA 'Temperatura, usura e ore di accensione del disco' 'Disk temperature, wear and power-on hours' }
    Csv $rc 'disk_reliability.csv'
    $R.Disks = $pd; $R.DiskHealth = $rc
    $R.InternalDisks = @(@(Wmi 'Win32_DiskDrive') | Where-Object { "$($_.InterfaceType)" -ne 'USB' -and "$($_.MediaType)" -notmatch 'Removable|rimovibil' }).Count
    $vol = @(@(Wmi 'Win32_LogicalDisk' -Filter 'DriveType=3') | ForEach-Object {
        NewObj @('Drive', $_.DeviceID, 'Label', $_.VolumeName, 'FileSystem', $_.FileSystem, 'SizeGB', [math]::Round($_.Size / 1GB, 1), 'FreeGB', [math]::Round($_.FreeSpace / 1GB, 1)) })
    Csv $vol 'volumes.csv'; $R.Volumes = $vol
    Csv (@(Wmi 'Win32_DiskPartition') | Select-Object DiskIndex, Index, Name, Type, BootPartition, @{n='SizeGB';e={ [math]::Round($_.Size / 1GB, 1) }}) 'partitions.csv'
    $sys = $vol | Where-Object { $_.Drive -eq $env:SystemDrive } | Select-Object -First 1
    $R.FreePct = $null; if ($sys -and $sys.SizeGB) { $R.FreePct = [math]::Round(100 * $sys.FreeGB / $sys.SizeGB) }
    $dq = (fsutil dirty query $env:SystemDrive 2>&1 | Out-String)
    $R.Dirty = 'unknown'; if ($dq -match 'NOT Dirty|non .{0,3}danneggiato') { $R.Dirty = 'no' } elseif ($dq -match 'is Dirty|danneggiato') { $R.Dirty = 'yes' }
    $tq = (fsutil behavior query DisableDeleteNotify 2>&1 | Out-String)
    $R.Trim = 'unknown'; if ($tq -match 'DisableDeleteNotify = 0') { $R.Trim = 'on' } elseif ($tq -match 'DisableDeleteNotify = 1') { $R.Trim = 'off' }
    # index of the disk holding the system drive, to tell its errors apart from USB sticks and memory cards
    $R.SysDiskIndex = $null
    foreach ($a in @(Wmi 'Win32_LogicalDiskToPartition')) {
        $dep = "$($a.Dependent)"; $ant = "$($a.Antecedent)"
        if ($a.Dependent -and $a.Dependent.DeviceID) { $dep = "$($a.Dependent.DeviceID)"; $ant = "$($a.Antecedent.DeviceID)" }
        if ($dep -match [regex]::Escape($env:SystemDrive) -and $ant -match 'Disk #(\d+)') { $R.SysDiskIndex = [int]$matches[1] }
    }
    # devices with problems; code 22 = disabled on purpose, 45 = not connected, 24 = not present or incomplete (uncertain)
    $pnpAll = @(Wmi 'Win32_PnPEntity' -Filter 'ConfigManagerErrorCode <> 0')
    Csv ($pnpAll | Select-Object Name, PNPClass, ConfigManagerErrorCode, DeviceID) 'devices_with_errors.csv'
    $R.BadDevices = @($pnpAll | Where-Object { @(22, 24, 45) -notcontains [int]$_.ConfigManagerErrorCode })
    $R.UnclearDevices = @($pnpAll | Where-Object { [int]$_.ConfigManagerErrorCode -eq 24 })
    $R.DisabledDevices = @($pnpAll | Where-Object { [int]$_.ConfigManagerErrorCode -eq 22 })
    $stor = @(Wmi 'Win32_SCSIController') + @(Wmi 'Win32_IDEController')
    Csv ($stor | Select-Object Name, Status, DeviceID) 'disk_controllers.csv'
    $R.Rst = [bool](@($stor | Where-Object { $_.Name -match 'VMD|RST|Rapid Storage' }).Count)
    # crash dump configuration
    $cc = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -ErrorAction SilentlyContinue
    $R.DumpsEnabled = $null; if ($cc -and $cc.CrashDumpEnabled -ne $null) { $R.DumpsEnabled = ($cc.CrashDumpEnabled -ne 0) }
    $R.MinidumpDir = "$env:SystemRoot\Minidump"
    if ($cc -and $cc.MinidumpDir) { $R.MinidumpDir = [Environment]::ExpandEnvironmentVariables("$($cc.MinidumpDir)") }
}

Step 'Memory (RAM)' {
    $mods = @(@(Wmi 'Win32_PhysicalMemory') | ForEach-Object {
        $mhz = $_.ConfiguredClockSpeed; if (-not $mhz) { $mhz = $_.Speed }
        NewObj @('Slot', $_.DeviceLocator, 'GB', [math]::Round($_.Capacity / 1GB, 1), 'MHz', $mhz, 'Manufacturer', "$($_.Manufacturer)".Trim(), 'PartNumber', "$($_.PartNumber)".Trim()) })
    Csv $mods 'memory_modules.csv'; $R.RamModules = $mods
    $R.MemTest = @(Ev @{LogName='System'; ProviderName='Microsoft-Windows-MemoryDiagnostics-Results'; StartTime=$since})
    $R.WheaMem = @(Ev @{LogName='System'; ProviderName='Microsoft-Windows-WHEA-Logger'; StartTime=$since} | Where-Object { $_.Message -match 'memor|DIMM' })
    $R.LowMemory = @(Ev @{LogName='System'; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; StartTime=$since})
    $o = $R.Os
    $R.RamFreePct = $null; if ($o -and $o.TotalVisibleMemorySize) { $R.RamFreePct = [math]::Round(100 * $o.FreePhysicalMemory / $o.TotalVisibleMemorySize) }
}

Step 'Events: crashes, boots, disk, power, services' {
    $providers = 'Microsoft-Windows-Kernel-Power','EventLog','User32','Microsoft-Windows-Kernel-General','Microsoft-Windows-Kernel-Boot',
                 'Microsoft-Windows-WER-SystemErrorReporting','BugCheck','Microsoft-Windows-WHEA-Logger','Microsoft-Windows-Kernel-Processor-Power',
                 'Microsoft-Windows-ACPI','ACPI','disk','stornvme','storahci','iaStorVD','iaStorAC','iaStorAVC','iaStorA','iaStor','Microsoft-Windows-StorPort',
                 'volmgr','partmgr','Ntfs','Microsoft-Windows-Ntfs','Service Control Manager','Microsoft-Windows-Kernel-PnP','Display',
                 'Microsoft-Windows-Power-Troubleshooter'
    $all = @(foreach ($pv in $providers) { Ev @{LogName='System'; ProviderName=$pv; StartTime=$since} })
    $all = @($all | Where-Object { $_ })
    Csv ($all | Sort-Object TimeCreated -Descending | EvSel) 'events_system_key.csv'
    Csv (Ev @{LogName='System'; Level=1,2; StartTime=$since} | Sort-Object TimeCreated -Descending | EvSel) 'events_system_errors.csv'

    $R.Boots      = @($all | Where-Object { $_.ProviderName -match 'Kernel-General' -and $_.Id -eq 12 } | Sort-Object TimeCreated)
    # wake-up: Kernel-Power 107 (Windows 8+), Power-Troubleshooter 1 (also Windows 7)
    $R.Resumes    = @($all | Where-Object { ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 107) -or ($_.ProviderName -eq 'Microsoft-Windows-Power-Troubleshooter' -and $_.Id -eq 1) } | Sort-Object TimeCreated)
    $R.Crash41    = @($all | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and $_.Id -eq 41 } | Sort-Object TimeCreated -Descending)
    $R.Unexpected = @($all | Where-Object { $_.Id -eq 6008 -and $_.ProviderName -eq 'EventLog' })
    $R.DumpFailed = @($all | Where-Object { $_.ProviderName -eq 'volmgr' -and $_.Id -eq 161 })
    $R.DumpInitFailed = @($all | Where-Object { $_.ProviderName -eq 'volmgr' -and (@(45, 46) -contains $_.Id) })
    # disk errors (warnings 51/129/153 are the typical "disk not responding" events), system disk vs other disks
    $diskEv = @($all | Where-Object { $_.ProviderName -match '^(disk|stornvme|storahci|iaStor\w*|Microsoft-Windows-StorPort)$' -and (($_.Level -ge 1 -and $_.Level -le 2) -or ($_.Level -eq 3 -and @(51, 129, 153) -contains $_.Id)) })
    foreach ($e in $diskEv) {
        $txt = "$($e.Message) $((Get-EventData $e) -join ' ')"
        $hasIdx = $txt -match '(?:Harddisk|\bdisk\s+|\bdisco\s+)(\d+)'
        if ($hasIdx -and $R.SysDiskIndex -ne $null) {
            if ([int]$matches[1] -eq $R.SysDiskIndex) { $R.DiskErrors += $e } else { $R.OtherDiskErrors += $e }
        } elseif (-not $hasIdx -and $R.InternalDisks -eq 1) { $R.DiskErrors += $e }      # only one internal disk: controller errors belong to it
        else { $R.UnattributedDiskErrors += $e }
    }
    # NTFS errors are attributed by drive letter (an error on a USB drive must not count against the system disk);
    # event 137 (transaction resource manager) is not file system damage
    foreach ($ne in @($all | Where-Object { $_.ProviderName -match 'Ntfs' -and $_.Level -ge 1 -and $_.Level -le 2 -and $_.Id -ne 137 })) {
        $nt = "$($ne.Message) $((Get-EventData $ne) -join ' ')"
        if ($nt -match '(?<![\w\\])([A-Za-z]):') { if (($matches[1] + ':') -eq $env:SystemDrive) { $R.NtfsErrors += $ne } else { $R.OtherDiskErrors += $ne } }
        else { $R.UnattributedDiskErrors += $ne }
    }
    $R.Whea       = @($all | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and $_.Level -ge 1 -and $_.Level -le 2 })
    $R.WheaCorrected = @($all | Where-Object { $_.ProviderName -eq 'Microsoft-Windows-WHEA-Logger' -and $_.Level -eq 3 })
    $R.Thermal    = @($all | Where-Object { ($_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' -and @(86, 88) -contains $_.Id) -or
                                            ($_.ProviderName -match 'ACPI|Kernel-Power' -and $_.Level -ge 1 -and $_.Level -le 3 -and $_.Message -match 'therm|termic|temperat') })
    $R.AcpiErrors = @($all | Where-Object { $_.ProviderName -match 'ACPI' -and $_.Level -ge 1 -and $_.Level -le 2 -and $_.Message -notmatch 'therm|termic|temperat' })
    $R.Throttle37 = @($all | Where-Object { $_.ProviderName -match 'Processor-Power' -and $_.Id -eq 37 })
    $R.SvcErrors  = @($all | Where-Object { $_.ProviderName -eq 'Service Control Manager' -and (@(7000,7001,7022,7023,7031,7034) -contains $_.Id) })
    $R.SvcCrashes = @($R.SvcErrors | Where-Object { @(7031,7034) -contains $_.Id })
    $R.Tdr        = @($all | Where-Object { $_.ProviderName -eq 'Display' -and $_.Id -eq 4101 })

    # crash timeline. Event 41 is written at the NEXT boot: the crash happened between the last "sign of life"
    # (event 6008, or the newest event of the crashed session) and that boot. The session started at the previous boot or wake-up.
    $boots = @($R.Boots | ForEach-Object { $_.TimeCreated })
    $powerUps = @(@($R.Boots) + @($R.Resumes) | ForEach-Object { $_.TimeCreated } | Sort-Object)
    $n41 = 0
    $R.Crashes = @(foreach ($c in $R.Crash41) {
        $n41++
        try {
            $d = XD $c
            [int64]$bc = 0; if ($d['BugcheckCode']) { $bc = [int64]$d['BugcheckCode'] }
            $key = $bc; if ($bc -gt 0x10000000 -and $bc -lt 0x20000000) { $key = $bc -band 0x0FFFFFFF }      # *_M variants
            $p1 = "$($d['BugcheckParameter1'])".ToLower()
            $p2 = "$($d['BugcheckParameter2'])".ToLower()
            $btn = $false
            if (($d['PowerButtonTimestamp'] -and $d['PowerButtonTimestamp'] -ne '0') -or "$($d['LongPowerButtonPressDetected'])" -match '^(true|1)$') { $btn = $true }
            # the crash happened while the PC was entering or leaving sleep / hibernation / modern standby
            $inSleep = ("$($d['SleepInProgress'])" -match '^[1-9]|^true$') -or ("$($d['ConnectedStandbyInProgress'])" -match '^(true|1)$')
            $info = $null; if ($key -le [int]::MaxValue) { $info = $BugMap[[int]$key] }
            $hex = '0x{0:X}' -f $bc
            if ($bc -eq 3221225498) { $info = @('STATUS_SYSTEM_PROCESS_TERMINATED', 'Un processo vitale di Windows è terminato (file di sistema, driver o disco).', 'A vital Windows process ended (system files, driver or disk).', 'other') }
            if (-not $info) { $info = @("Codice $hex|Code $hex", 'Errore non classificato: cercare il codice nella documentazione Microsoft.', 'Unclassified error: look up the code in the Microsoft documentation.', 'other') }
            $cat = $info[3]
            # disk I/O status codes (Microsoft bug check reference for 0x7A / 0x77)
            $diskSt = 'c000009c|c000016a|c000009d|c0000185|c000000e'
            # 0x1E: exception code c0000006 (in-page error) or a disk status in parameter 1 - heuristic, not a documented rule
            if ($bc -eq 30 -and $p1 -match ('c0000006|' + $diskSt)) { $cat = 'disk' }
            # 0x7A: parameter 2 is the I/O status. 0x77: parameter 1 = 0/1 means a corrupted stack page (RAM), otherwise it is the status
            if ($bc -eq 122) { if ($p2 -match $diskSt) { $cat = 'disk' } elseif ($p2 -match 'c000009a') { $cat = 'memdrv' } }
            if ($bc -eq 119) {
                if ($p1 -match '^(0x)?0*[01]$') { $cat = 'memdrv' }
                elseif (($p1 + ' ' + $p2) -match $diskSt) { $cat = 'disk' }
                elseif (($p1 + ' ' + $p2) -match 'c000009a') { $cat = 'memdrv' }
            }
            $nm = $info[0] -split '\|'
            $meanIt = $info[1]; $meanEn = $info[2]
            if ($bc -eq 0 -and $btn) { $meanIt = 'Spegnimento forzato tenendo premuto il pulsante di accensione (spesso perché il computer era bloccato).'; $meanEn = 'Forced shutdown by holding the power button (often because the computer had frozen).' }
            $bootNew = @($boots | Where-Object { $_ -le $c.TimeCreated.AddSeconds(30) }) | Select-Object -Last 1
            $sessionStart = $null
            if ($bootNew) { $sessionStart = @($powerUps | Where-Object { $_ -lt $bootNew.AddSeconds(-5) }) | Select-Object -Last 1 }
            $lastAlive = $null; $aliveFromLog = $false
            foreach ($u in $R.Unexpected) { if ([math]::Abs(($u.TimeCreated - $c.TimeCreated).TotalSeconds) -lt 180) { $la = Get-LastAlive $u $sessionStart $c.TimeCreated; if ($la) { $lastAlive = $la } } }
            if (-not $lastAlive -and $bootNew -and $sessionStart -and $n41 -le 40) {
                try { $lastAlive = (Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=$sessionStart; EndTime=$bootNew.AddSeconds(-2)} -MaxEvents 1 -ErrorAction Stop).TimeCreated; $aliveFromLog = $true } catch { }
            }
            # a time taken from the last logged event is only a lower bound (the crash happened then or later):
            # it can prove "during use" (more than 5 minutes) but never "right after startup"
            $min = $null
            if ($lastAlive -and $sessionStart -and $lastAlive -ge $sessionStart) {
                $min = [math]::Round(($lastAlive - $sessionStart).TotalMinutes, 1)
                if ($aliveFromLog -and $min -le 5) { $min = $null }
            }
            # shown date: the exact time from event 6008, otherwise the time of the restart that recorded the crash
            $when = $c.TimeCreated; if ($lastAlive -and -not $aliveFromLog) { $when = $lastAlive }
            NewObj @('Date', $when, 'RebootAt', $c.TimeCreated, 'BootAt', $bootNew, 'Code', $bc, 'Hex', $hex, 'Param1', $p1, 'Param2', $p2, 'PowerButton', $btn, 'NameIt', $nm[0], 'NameEn', $nm[$nm.Count - 1],
                     'It', $meanIt, 'En', $meanEn, 'Cat', $cat, 'LastAlive', $lastAlive, 'AliveFromLog', $aliveFromLog, 'SessionStart', $sessionStart, 'MinAfterPowerUp', $min,
                     'InSleep', $inSleep, 'AtBoot', ($inSleep -or ($min -ne $null -and $min -le 5)))
        } catch { Log "   crash record skipped: $($_.Exception.Message)" }
    })
    Csv ($R.Crashes | Select-Object Date, RebootAt, Hex, Param1, Param2, PowerButton, NameEn, Cat, SessionStart, MinAfterPowerUp, InSleep, AtBoot) 'crashes.csv'

    $pw = @(Ev @{LogName='System'; ProviderName='Microsoft-Windows-Kernel-Power'; Id=105; StartTime=$since})
    $R.Power = @(foreach ($p in $pw) { $d = XD $p; NewObj @('Time', $p.TimeCreated, 'AC', $d['AcOnline'], 'Remaining', $d['RemainingCapacity'], 'Full', $d['FullChargeCapacity']) })
    Csv ($R.Power | Sort-Object Time -Descending) 'power_source_changes.csv'
    # mains power lost in the 10 minutes before the last sign of life (events written after the reboot are not considered)
    $R.PowerBeforeCrash = @(foreach ($c in $R.Crashes) {
        if (-not $c.LastAlive) { continue }
        # with only a lower-bound time, the crash can be anywhere up to the next boot
        $hi = $c.LastAlive.AddSeconds(30); if ($c.AliveFromLog -and $c.BootAt) { $hi = $c.BootAt }
        $n = @($R.Power | Where-Object { $_.Time -le $hi -and $_.Time -ge $c.LastAlive.AddMinutes(-10) -and $_.AC -eq 'false' })
        if ($n.Count) { NewObj @('Crash', $c.Date, 'Times', (($n | ForEach-Object { $_.Time.ToString('HH:mm:ss', $Inv) }) -join ', ')) } })

    # Windows Update: a failed update counts only if no Windows update was installed after it and the KB is not installed
    $wu = @(Ev @{LogName='System'; ProviderName='Microsoft-Windows-WindowsUpdateClient'; StartTime=$since})
    Csv ($wu | EvSel) 'windows_update.csv'
    function IsWinKb([string]$m) { return ($m -match 'KB\d' -and $m -notmatch 'Defender|intelligence|Security Essentials|2267602') }
    $R.UpdatesOk = @($wu | Where-Object { $_.Id -eq 19 -and (IsWinKb $_.Message) } | Sort-Object TimeCreated -Descending)
    # installed updates read from WMI directly: InstalledOn is stored as M/d/yyyy (or hex) whatever the language,
    # while Get-HotFix on PowerShell 2.0 swaps day and month on non-US systems
    $hotfixes = @(@(Wmi 'Win32_QuickFixEngineering') | ForEach-Object {
        # raw WMI text (PowerShell's own InstalledOn conversion is culture-dependent on 2.0)
        $rawOn = $null
        try { $rawOn = $_.psbase.Properties['InstalledOn'].Value } catch { }
        if (-not $rawOn) { try { $rawOn = $_.CimInstanceProperties['InstalledOn'].Value } catch { } }
        $s = "$rawOn".Trim(); $dt = [datetime]::MinValue; $when = $null
        if ([datetime]::TryParseExact($s, [string[]]@('M/d/yyyy', 'MM/dd/yyyy', 'd-M-yyyy', 'dd-MM-yyyy', 'yyyyMMdd'), [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { $when = $dt }
        elseif ($s -match '^[0-9a-fA-F]{15,16}$') { try { $when = [datetime]::FromFileTime([Convert]::ToInt64($s, 16)) } catch { } }
        if ($when -and $when -gt (Get-Date).AddDays(1)) { $when = $null }
        NewObj @('HotFixID', "$($_.HotFixID)", 'Description', "$($_.Description)", 'InstalledOn', $when) })
    Csv $hotfixes 'hotfixes.csv'
    $hfIds = @($hotfixes | ForEach-Object { "$($_.HotFixID)".ToUpper() })
    $failed = @($wu | Where-Object { $_.Id -eq 20 -and (IsWinKb $_.Message) } | Where-Object {
        $f = $_; $kb = ''; if ($f.Message -match '(KB\d+)') { $kb = $matches[1].ToUpper() }
        $fCum = ($f.Message -match 'umulativ|Rollup'); $fNet = ($f.Message -match '\.NET')
        $ok2 = @($R.UpdatesOk | Where-Object { $_.TimeCreated -gt $f.TimeCreated -and (($kb -and $_.Message -match ($kb + '(?!\d)')) -or ($fCum -and $_.Message -match 'umulativ|Rollup' -and (($_.Message -match '\.NET') -eq $fNet))) })
        (-not $ok2.Count) -and ($hfIds -notcontains $kb) })
    $R.UpdatesFailed = @($failed | Group-Object { if ($_.Message -match '(KB\d+)') { $matches[1] } else { '?' } } | ForEach-Object { $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1 })
    $R.UpdatesFailedApps = @($wu | Where-Object { $_.Id -eq 20 -and ($_.Message -notmatch 'KB\d' -or $_.Message -match 'Defender|intelligence|Security Essentials|2267602') })
    # age of the newest Windows update and state of the update service
    $R.LastUpdate = $null
    foreach ($h in $hotfixes) { if ($h.InstalledOn -and ($R.LastUpdate -eq $null -or $h.InstalledOn -gt $R.LastUpdate)) { $R.LastUpdate = $h.InstalledOn } }
    # the monthly malicious software removal tool (KB890830) is not a Windows update
    $okNoMsrt = @($R.UpdatesOk | Where-Object { $_.Message -notmatch 'KB890830' })
    if ($okNoMsrt.Count -and ($R.LastUpdate -eq $null -or $okNoMsrt[0].TimeCreated -gt $R.LastUpdate)) { $R.LastUpdate = $okNoMsrt[0].TimeCreated }
    $wus = Wmi 'Win32_Service' -Filter "Name='wuauserv'" | Select-Object -First 1
    $R.WuDisabled = ($wus -and $wus.StartMode -eq 'Disabled')

    $w = [Management.ManagementDateTimeConverter]::ToDmtfDateTime($since)
    Csv (@(Wmi 'Win32_ReliabilityRecords' -Filter "TimeGenerated > '$w'") | Select-Object @{n='Time';e={ ToDate $_.TimeGenerated }}, SourceName, EventIdentifier, ProductName, @{n='Message';e={ ($_.Message -replace "`r?`n",' | ') }}) 'reliability.csv'
}

Step 'Application errors' {
    $app = @(Ev @{LogName='Application'; Level=1,2; StartTime=$since})
    Csv ($app | Sort-Object TimeCreated -Descending | EvSel) 'events_application_errors.csv'
    $R.AppCrashes = @($app | Where-Object { $_.Id -eq 1000 -or $_.Id -eq 1002 })
    $R.AppTop = @($R.AppCrashes | ForEach-Object { if ($_.Message -match '([\w\-\.]+\.exe)') { $matches[1] } else { '?' } } | Group-Object | Sort-Object Count -Descending | Select-Object -First 5 Count, Name)
    $R.AppFrom = $null
    try { $R.AppFrom = (Get-WinEvent -LogName Application -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { }
}

Step 'Disk communication errors (storage logs)' {
    # these logs exist on Windows 8 and later; on Windows 7 the queries simply return nothing
    $e = @(Ev @{LogName='Microsoft-Windows-Storage-ClassPnP/Operational'; StartTime=$since}) +
         @(Ev @{LogName='Microsoft-Windows-Storage-NvmeDisk/Operational'; StartTime=$since}) +
         @(Ev @{LogName='Microsoft-Windows-StorageVolume/Operational'; StartTime=$since})
    $e = @($e | Where-Object { $_ -and $_.Level -ge 1 -and $_.Level -le 3 })
    Csv ($e | Sort-Object TimeCreated -Descending | EvSel) 'disk_io_errors.csv'
    # attribute each error to its disk (DeviceNumber): errors of USB sticks and card readers must not count against the system disk
    foreach ($ev in @($e | Where-Object { $_.ProviderName -notmatch 'StorageVolume' -and $_.Level -le 2 })) {
        $x = XD $ev; $dn = $x['DeviceNumber']
        if ($ev.ProviderName -match 'StorDiag') {
            # diagnostic log: counted only for the system disk and only for real I/O failures
            # (not "unsupported command" answers, sense key 5, and not a device that was removed)
            $ioSt = "$($x['DownLevelIrpStatus']) $($x['IrpStatus']) $($x['Status'])".ToLower()
            if ("$dn" -match '^\d+$' -and $R.SysDiskIndex -ne $null -and [int]$dn -eq $R.SysDiskIndex -and $ioSt -match 'c000009c|c000016a|c0000185' -and "$($x['SenseKey'])" -ne '5') { $R.IoErrors += $ev }
            continue
        }
        if ("$dn" -match '^\d+$' -and $R.SysDiskIndex -ne $null) { if ([int]$dn -eq $R.SysDiskIndex) { $R.IoErrors += $ev } else { $R.OtherDiskErrors += $ev } }
        elseif ("$dn" -notmatch '^\d+$' -and $R.InternalDisks -eq 1) { $R.IoErrors += $ev }
        else { $R.UnattributedDiskErrors += $ev }
    }
    $R.IoDiag   = @($e | Where-Object { $_.ProviderName -match 'StorDiag' })
    $R.PnpDisk  = @(Ev @{LogName='Microsoft-Windows-Kernel-PnP/Configuration'; StartTime=$since} | Where-Object { $_.Message -match 'NVMe|SCSI\\Disk|stornvme|Disk&' })
}

Step 'Crash dumps and startup repair logs' {
    $dd = Join-Path $raw 'dump'; New-Item -ItemType Directory $dd -Force | Out-Null
    $R.Minidump = @(Get-ChildItem $R.MinidumpDir -Filter *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $since })
    $R.Minidump | Copy-Item -Destination $dd -ErrorAction SilentlyContinue
    $R.LiveDump = @(Get-ChildItem "$env:SystemRoot\LiveKernelReports" -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer -and $_.Extension -eq '.dmp' -and $_.LastWriteTime -ge $since })
    $R.LiveDump | Where-Object { $_.Length -lt 30MB } | Copy-Item -Destination $dd -ErrorAction SilentlyContinue
    # LiveKernelReports\WATCHDOG holds the graphics timeout (TDR) dumps; other folders (e.g. PoW32kWatchdog) are not graphics
    $R.GpuWatchdog = @($R.LiveDump | Where-Object { $_.Directory.Name -eq 'WATCHDOG' })
    $srt = @(Get-ChildItem "$env:SystemRoot\System32\LogFiles\Srt" -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    $srt | Copy-Item -Destination $raw -ErrorAction SilentlyContinue
    $R.SrtTrail = $srt | Where-Object { $_.Name -eq 'SrtTrail.txt' -and $_.LastWriteTime -ge $since } | Select-Object -First 1
    $werRoots = @("$env:ProgramData\Microsoft\Windows\WER\ReportArchive", "$env:ProgramData\Microsoft\Windows\WER\ReportQueue")
    $R.Wer = @(Get-ChildItem $werRoots -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer -and $_.Name -match 'Kernel|BlueScreen|LiveKernel|WHEA' -and $_.LastWriteTime -ge $since })
    $wd = Join-Path $raw 'wer'; New-Item -ItemType Directory $wd -Force | Out-Null
    foreach ($w in $R.Wer) { Get-ChildItem $w.FullName -Filter *.wer -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item $_.FullName (Join-Path $wd "$($w.Name).wer") -ErrorAction SilentlyContinue } }
    bcdedit /enum all 2>&1 | Out-File (Join-Path $raw 'bcdedit.txt') -Encoding UTF8
    reagentc /info 2>&1 | Out-File (Join-Path $raw 'reagentc.txt') -Encoding UTF8
}

Step 'Battery and power' {
    $b = Wmi 'Win32_Battery' | Select-Object -First 1
    $design = (Wmi 'BatteryStaticData' 'root\wmi' | Select-Object -First 1).DesignedCapacity
    $full = (Wmi 'BatteryFullChargedCapacity' 'root\wmi' | Select-Object -First 1).FullChargedCapacity
    if ($b -and $IsWin8Plus) {
        # battery report exists on Windows 8 and later
        $bh = Join-Path $raw 'battery_report.html'
        powercfg /batteryreport /output $bh 2>&1 | Out-Null
        if ((Test-Path -LiteralPath $bh) -and (-not $design -or -not $full)) {
            $txt = ((ReadText $bh) -replace '<[^>]+>', ' ') -replace '\s+', ' '
            if ($txt -match 'DESIGN CAPACITY\s+([\d.,]+)\s*mWh') { $design = [int](($matches[1] -replace '[.,]', '')) }
            if ($txt -match 'FULL CHARGE CAPACITY\s+([\d.,]+)\s*mWh') { $full = [int](($matches[1] -replace '[.,]', '')) }
        }
    }
    $R.BatteryPresent = [bool]$b
    if ($b) { $R.BatteryCharge = $b.EstimatedChargeRemaining; $R.BatteryDesign = $design; $R.BatteryFull = $full }
    $R.BatteryHealth = $null; if ($b -and $design -and $full) { $R.BatteryHealth = [math]::Round(100 * $full / $design) }
    # on mains power? (BatteryStatus 1 = discharging); computers without a battery are always on mains power
    $R.OnAC = $true; if ($b -and $b.BatteryStatus -eq 1) { $R.OnAC = $false }
    powercfg /list 2>&1 | Out-File (Join-Path $raw 'power_plans.txt') -Encoding UTF8
    # maximum processor state of the active power plan (below 100% the CPU is limited on purpose)
    $q = (powercfg /query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 2>&1 | Out-String)
    $hex = @([regex]::Matches($q, '0x([0-9a-fA-F]{8})') | ForEach-Object { $_.Groups[1].Value })
    $R.PlanMaxAC = $null; $R.PlanMaxDC = $null
    if ($hex.Count -ge 2) { $R.PlanMaxAC = [Convert]::ToInt32($hex[$hex.Count - 2], 16); $R.PlanMaxDC = [Convert]::ToInt32($hex[$hex.Count - 1], 16) }
    $R.FastStartup = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
}

Step "Performance and temperature sampling ($SampleSeconds s)" {
    $load = @()
    $startAt = Get-Date
    $deadline = $startAt.AddSeconds($SampleSeconds)
    if ($Stress) {
        Log "   CPU load running on $([Environment]::ProcessorCount) threads until $($deadline.ToString('HH:mm:ss'))"
        $jobEnd = $deadline.AddSeconds(5)
        $load = @(1..([Environment]::ProcessorCount) | ForEach-Object {
            Start-Job -ScriptBlock { param($e) $x = 0.0; while ((Get-Date) -lt $e) { for ($k = 0; $k -lt 200000; $k++) { $x = [math]::Sqrt($x + $k) } } } -ArgumentList $jobEnd })
        Start-Sleep -Seconds 3
        $deadline = (Get-Date).AddSeconds($SampleSeconds)
        if ($deadline -gt $jobEnd) { $deadline = $jobEnd.AddSeconds(-1) }
    }
    try {
        $rows = @(while ((Get-Date) -lt $deadline) {
            $tick = Get-Date
            $el = [int]($tick - $startAt).TotalSeconds
            Write-Progress -Activity 'Sampling performance and temperatures' -Status "$el / $SampleSeconds s" -PercentComplete ([Math]::Min(100, [int](100 * $el / [Math]::Max(1, $SampleSeconds))))
            $t = $tick.ToString('HH:mm:ss')
            $p = Wmi 'Win32_PerfFormattedData_Counters_ProcessorInformation' -Filter "Name='_Total'" | Select-Object -First 1
            if ($p) {
                if ($p.PercentPerformanceLimit -ne $null) { NewObj @('Time', $t, 'Key', 'cpu_limit', 'Value', [double]$p.PercentPerformanceLimit) }
                if ($p.PercentProcessorPerformance -ne $null) { NewObj @('Time', $t, 'Key', 'cpu_perf', 'Value', [double]$p.PercentProcessorPerformance) }
                if ($p.ProcessorFrequency -ne $null) { NewObj @('Time', $t, 'Key', 'cpu_freq', 'Value', [double]$p.ProcessorFrequency) }
                NewObj @('Time', $t, 'Key', 'cpu_use', 'Value', [double]$p.PercentProcessorTime)
            } else {
                $p = Wmi 'Win32_PerfFormattedData_PerfOS_Processor' -Filter "Name='_Total'" | Select-Object -First 1
                if ($p) { NewObj @('Time', $t, 'Key', 'cpu_use', 'Value', [double]$p.PercentProcessorTime) }
            }
            $m = Wmi 'Win32_OperatingSystem' | Select-Object -First 1
            if ($m -and $m.TotalVisibleMemorySize) { NewObj @('Time', $t, 'Key', 'ram_use', 'Value', [math]::Round(100 - (100 * $m.FreePhysicalMemory / $m.TotalVisibleMemorySize), 1)) }
            $dk = Wmi 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk' -Filter "Name='_Total'" | Select-Object -First 1
            if ($dk) { NewObj @('Time', $t, 'Key', 'disk_busy', 'Value', [double]$dk.PercentDiskTime) }
            foreach ($z in @(Wmi 'Win32_PerfFormattedData_Counters_ThermalZoneInformation')) {
                $c = [math]::Round($z.Temperature - 273.15, 1)
                if ($c -gt 0 -and $c -lt 120) {
                    NewObj @('Time', $t, 'Key', "temp:$($z.Name)", 'Value', $c)
                    NewObj @('Time', $t, 'Key', "passive:$($z.Name)", 'Value', [double]$z.PercentPassiveLimit)
                    NewObj @('Time', $t, 'Key', "reasons:$($z.Name)", 'Value', [double]$z.ThrottleReasons)
                }
            }
            $wait = 5000 - [int]((Get-Date) - $tick).TotalMilliseconds
            if ($wait -gt 0 -and (Get-Date).AddMilliseconds($wait) -lt $deadline) { Start-Sleep -Milliseconds $wait } elseif ($wait -gt 0) { break }
        })
    } finally {
        Write-Progress -Activity 'Sampling performance and temperatures' -Completed
        if ($load.Count) { $load | Stop-Job -ErrorAction SilentlyContinue; $load | Remove-Job -Force -ErrorAction SilentlyContinue; Log '   CPU load stopped' }
    }
    Csv $rows 'performance_samples.csv'
    $R.Samples = @($rows | Group-Object Key | ForEach-Object {
        $m = $_.Group | Measure-Object Value -Minimum -Maximum -Average
        NewObj @('Key', $_.Name, 'Min', [math]::Round($m.Minimum, 1), 'Avg', [math]::Round($m.Average, 1), 'Max', [math]::Round($m.Maximum, 1)) })
    if (-not @($R.Samples | Where-Object { $_.Key -eq 'cpu_limit' }).Count) { NA 'Limite del processore imposto dal BIOS (contatore non disponibile)' 'Processor limit set by the BIOS (counter not available)' }
    if (-not @($R.Samples | Where-Object { $_.Key -like 'temp:*' }).Count) { NA 'Temperature interne in tempo reale (sensori non esposti)' 'Live internal temperatures (sensors not exposed)' }
    $R.TopRam = @(Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 Name, @{n='MB';e={ [math]::Round($_.WorkingSet64 / 1MB) }})
    Csv (Get-Process | Select-Object Name, Id, @{n='CPU_s';e={ [math]::Round($_.CPU) }}, @{n='RAM_MB';e={ [math]::Round($_.WorkingSet64 / 1MB) }} | Sort-Object RAM_MB -Descending) 'processes.csv'
    Csv (@(Wmi 'MSAcpi_ThermalZoneTemperature' 'root\wmi') | ForEach-Object { NewObj @('Zone', $_.InstanceName, 'Celsius', [math]::Round($_.CurrentTemperature / 10 - 273.15, 1), 'Critical', [math]::Round($_.CriticalTripPoint / 10 - 273.15, 1)) }) 'acpi_temperatures.csv'
}

Step 'Network' {
    $cfgAll = @(Wmi 'Win32_NetworkAdapterConfiguration' -Filter 'IPEnabled = TRUE')
    $R.NetConfig = @($cfgAll | Where-Object { @($_.IPAddress | Where-Object { $_ -match '^\d+\.' -and $_ -notmatch '^169\.254\.' }).Count } | ForEach-Object {
        NewObj @('Adapter', $_.Description, 'IP', (@($_.IPAddress | Where-Object { $_ -match '^\d+\.' }) -join ', '), 'Gateway', (@($_.DefaultIPGateway | Where-Object { $_ }) -join ', '), 'DNS', (@($_.DNSServerSearchOrder | Where-Object { $_ }) -join ', ')) })
    Csv $R.NetConfig 'network_configuration.csv'
    $R.NetErrors = @(foreach ($pv in 'Microsoft-Windows-WLAN-AutoConfig', 'Tcpip', 'Microsoft-Windows-DNS-Client', 'Microsoft-Windows-Dhcp-Client') { Ev @{LogName='System'; ProviderName=$pv; Level=1,2; StartTime=$since} })
    if (-not $SkipNetwork) {
        $gw = @($R.NetConfig | Where-Object { $_.Gateway } | Select-Object -First 1)
        $R.PingGateway = $null
        if ($gw.Count) { $R.PingGateway = [bool](Test-Connection (($gw[0].Gateway -split ',')[0].Trim()) -Count 2 -Quiet -ErrorAction SilentlyContinue) }
        $R.PingInternet = [bool](Test-Connection 1.1.1.1 -Count 2 -Quiet -ErrorAction SilentlyContinue)
        $R.Dns = $false
        try { $R.Dns = [bool]@([System.Net.Dns]::GetHostAddresses('www.microsoft.com')).Count } catch { }
        # HTTPS connection test: works where ping is blocked by a company firewall
        $R.Tcp = (Test-Tcp 'www.microsoft.com' 443) -or (Test-Tcp '1.1.1.1' 443)
        # proxy of the elevated account, of the signed-in user and of the machine (policy or per-machine settings)
        $R.Proxy = $false
        $pKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings', 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings')
        if ($UserSid) { $pKeys += "Registry::HKEY_USERS\$UserSid\Software\Microsoft\Windows\CurrentVersion\Internet Settings" }
        foreach ($pk in $pKeys) { try { $ps = Get-ItemProperty $pk -ErrorAction Stop; if ($ps.ProxyEnable -eq 1 -or $ps.AutoConfigURL) { $R.Proxy = $true } } catch { } }
    }
}

Step 'Security and protection' {
    $R.IsServer = ($R.Os -and $R.Os.ProductType -ne $null -and [int]$R.Os.ProductType -ne 1)
    # Security Center lists every registered antivirus/firewall (Windows Vista SP1 and later, client editions)
    $R.ScAvailable = [bool](Wmi '__NAMESPACE' 'root' -Filter "Name='SecurityCenter2'")
    $R.WscRunning = [bool](Wmi 'Win32_Service' -Filter "Name='wscsvc' AND State='Running'")
    $R.Antivirus = @(@(Wmi 'AntiVirusProduct' 'root\SecurityCenter2') | ForEach-Object {
        $st = [int]$_.productState
        NewObj @('Name', $_.displayName, 'On', (($st -band 0x1000) -ne 0), 'UpToDate', (($st -band 0x10) -eq 0)) })
    $R.ThirdPartyFw = @(@(Wmi 'FirewallProduct' 'root\SecurityCenter2') | Where-Object { ([int]$_.productState -band 0x1000) -ne 0 } | ForEach-Object { $_.displayName })
    $R.Defender = $null
    if (Has 'Get-MpComputerStatus') {
        try {
            $s = Get-MpComputerStatus -ErrorAction Stop
            $R.Defender = NewObj @('RealTime', [bool]$s.RealTimeProtectionEnabled, 'Mode', "$($s.AMRunningMode)", 'SigDate', $s.AntivirusSignatureLastUpdated, 'SigAge', $s.AntivirusSignatureAge, 'QuickScan', $s.QuickScanEndTime)
        } catch { }
    }
    # firewall: registry (works on every version), Group Policy settings take precedence
    $R.Firewall = @(foreach ($p in @(@('Domain', 'DomainProfile', 'DomainProfile'), @('Private', 'StandardProfile', 'PrivateProfile'), @('Public', 'PublicProfile', 'PublicProfile'))) {
        $v = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$($p[1])" -ErrorAction SilentlyContinue).EnableFirewall
        $g = (Get-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\$($p[2])" -ErrorAction SilentlyContinue).EnableFirewall
        if ($g -ne $null) { $v = $g }
        NewObj @('Name', $p[0], 'Enabled', ($v -eq 1)) })
    # BitLocker and TPM through WMI (Windows 7 and later, administrator required)
    $bl = @(Wmi 'Win32_EncryptableVolume' 'root\CIMV2\Security\MicrosoftVolumeEncryption')
    $R.BitLocker = $null
    if ($bl.Count) {
        $conv = @{ 0 = 'FullyDecrypted'; 1 = 'FullyEncrypted'; 2 = 'EncryptionInProgress'; 3 = 'DecryptionInProgress'; 4 = 'EncryptionPaused'; 5 = 'DecryptionPaused' }
        $R.BitLocker = @($bl | Where-Object { $_.DriveLetter } | ForEach-Object {
            $cs0 = $null
            try { if ($UseCim) { $cs0 = (Invoke-CimMethod -InputObject $_ -MethodName GetConversionStatus -ErrorAction Stop).ConversionStatus } else { $cs0 = $_.GetConversionStatus().ConversionStatus } } catch { }
            $st = 'unknown'; if ($cs0 -ne $null -and $conv.ContainsKey([int]$cs0)) { $st = $conv[[int]$cs0] }
            NewObj @('MountPoint', $_.DriveLetter, 'VolumeStatus', $st, 'Protection', $_.ProtectionStatus) })
    }
    $tpm = Wmi 'Win32_Tpm' 'root\CIMV2\Security\MicrosoftTpm' | Select-Object -First 1
    $R.Tpm = $null; if ($tpm) { $R.Tpm = NewObj @('Ready', ([bool]$tpm.IsEnabled_InitialValue -and [bool]$tpm.IsActivated_InitialValue), 'Version', "$($tpm.SpecVersion)".Split(',')[0]) }
    $R.RebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
                       (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    # at most the newest 20000 events: a large security log would otherwise take minutes and gigabytes of memory
    $af = @(Ev @{LogName='Security'; Id=4625; StartTime=$since} 20000)
    $R.FailedLogons = $af.Count; $R.FailedLogonsCapped = ($af.Count -ge 20000)
    # LogonType is the 11th data field of event 4625
    $R.FailedLogonTypes = @($af | ForEach-Object { $lt = ''; try { $lt = "$($_.Properties[10].Value)" } catch { }; $lt } | Group-Object | Sort-Object Count -Descending | ForEach-Object { NewObj @('Type', $_.Name, 'Count', $_.Count) })
    $R.FailedRemote = 0
    foreach ($ft in @($R.FailedLogonTypes)) { if (@('3', '8', '10') -contains "$($ft.Type)") { $R.FailedRemote += [int]$ft.Count } }
    $R.SecFrom = $null
    try { $R.SecFrom = (Get-WinEvent -LogName Security -MaxEvents 1 -Oldest -ErrorAction Stop).TimeCreated } catch { }
}

Step 'Startup programs, software, services and scheduled tasks' {
    $R.Startup = @(Wmi 'Win32_StartupCommand' | Select-Object Name, Command, Location, User)
    Csv $R.Startup 'startup_programs.csv'
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    $sw = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName } | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Sort-Object DisplayName, DisplayVersion -Unique | Sort-Object InstallDate -Descending)
    Csv $sw 'installed_software.csv'; $R.RecentSoftware = @($sw | Select-Object -First 8)
    $R.StoppedServices = @(Wmi 'Win32_Service' -Filter "StartMode='Auto' AND State<>'Running'" | Select-Object Name, DisplayName)
    Csv $R.StoppedServices 'stopped_automatic_services.csv'
    $R.FailedTasks = $null
    if ((Has 'Get-ScheduledTask') -and (Has 'Get-ScheduledTaskInfo')) {
        $allTasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
        if ($allTasks.Count) {
            $R.FailedTasks = @($allTasks | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue |
                Where-Object { $_.LastTaskResult -ne 0 -and $_.LastRunTime -ge $since } | Select-Object TaskName, LastRunTime, LastTaskResult)
            Csv $R.FailedTasks 'failed_scheduled_tasks.csv'
        } else { NA 'Attività pianificate non riuscite' 'Failed scheduled tasks' }
    } else { NA 'Attività pianificate non riuscite' 'Failed scheduled tasks' }
}

if (-not $SkipEnergy) {
    Step 'Energy report (60 s)' { powercfg /energy /duration 60 /output (Join-Path $raw 'energy_report.html') 2>&1 | Out-Null }
}

if ($DeepScan) {
    Step 'System file check (sfc /verifyonly, read-only)' {
        # sfc writes UTF-16 text: read it through a temporary file
        $tmp = Join-Path $env:TEMP 'diag_sfc.txt'
        cmd /c "sfc /verifyonly > `"$tmp`" 2>&1"
        $o = ''
        try { $o = [IO.File]::ReadAllText($tmp, [Text.Encoding]::Unicode) } catch { }
        if ($o -notmatch '[a-zA-Z]{4}') { $o = ReadText $tmp }
        $o = $o -replace "`0", ''
        $o | Out-File (Join-Path $raw 'sfc_verifyonly.txt') -Encoding UTF8
        Remove-Item $tmp -ErrorAction SilentlyContinue
        # accent-free patterns; the "component metadata" case is tested first because it can also contain the "no violations" sentence
        $R.Sfc = 'unknown'
        if ($o -match 'metadati del componente|component metadata') { $R.Sfc = 'bad' }
        elseif ($o -match 'did not find any integrity violations|non ha rilevato alcuna violazione|non ha trovato violazioni|nessuna violazione di integrit') { $R.Sfc = 'ok' }
        elseif ($o -match 'found integrity violations|rilevato violazioni|rilevate violazioni|trovato violazioni|file danneggiati|corrupt files') { $R.Sfc = 'bad' }
    }
    Step 'File system check (chkdsk, read-only mode)' {
        # plain chkdsk without parameters only reports, it never repairs
        $o = (chkdsk $env:SystemDrive 2>&1 | Out-String)
        $ec = $LASTEXITCODE
        $o | Out-File (Join-Path $raw 'chkdsk_readonly.txt') -Encoding UTF8
        # exit codes: 0 no errors, 2 cleanup possible (no errors), 3 = errors found OR the disk could not be checked
        $R.Chkdsk = 'unknown'
        if ($ec -eq 0 -or $ec -eq 2) { $R.Chkdsk = 'ok' }
        elseif ($ec -eq 3 -and $o -match 'found problems|errors found|must be fixed offline|chkdsk /spotfix|/F \((fix|correggi)|problemi nel file system|risolti offline') { $R.Chkdsk = 'bad' }
    }
}

Step 'Full event logs (.evtx) for later analysis' {
    $ed = Join-Path $raw 'evtx'; New-Item -ItemType Directory $ed -Force | Out-Null
    foreach ($c in 'System','Application','Microsoft-Windows-Storage-ClassPnP/Operational','Microsoft-Windows-Storage-NvmeDisk/Operational',
                   'Microsoft-Windows-Kernel-Boot/Operational','Microsoft-Windows-Kernel-PnP/Configuration','Microsoft-Windows-Ntfs/Operational',
                   'Microsoft-Windows-Kernel-Power/Thermal-Operational','Microsoft-Windows-Kernel-WHEA/Operational',
                   'Microsoft-Windows-Resource-Exhaustion-Detector/Operational','Microsoft-Windows-StorageVolume/Operational') {
        try { Get-WinEvent -ListLog $c -ErrorAction Stop | Out-Null } catch { continue }
        wevtutil epl "$c" (Join-Path $ed (($c -replace '[\\/ ]', '_') + '.evtx')) 2>&1 | Out-Null
    }
    if ($EvErrors.Count) { Log "   event log queries with errors: $($EvErrors.Count)"; $EvErrors | ForEach-Object { Log "     $_" } }
}

# ============================== VERDICTS ==============================
Log '-> Evaluating results'
# the System log can be shorter than the analysed period: say so instead of "last 60 days"
# the same applies to the Application and Security logs, which often cover fewer days
function Get-Period($from, [string]$whatIt, [string]$whatEn) {
    if ($from -and $from -gt $since.AddDays(1)) { return @("dal $($from.ToString('dd/MM/yyyy', $Inv)) (inizio del registro$whatIt)", "since $($from.ToString('yyyy-MM-dd', $Inv)) (start of the$whatEn log)") }
    return @("negli ultimi $Days giorni", "in the last $Days days")
}
$pp = Get-Period $R.LogFrom '' ''; $PeriodIt = $pp[0]; $PeriodEn = $pp[1]
$pp = Get-Period $R.AppFrom ' delle applicazioni' ' application'; $AppPerIt = $pp[0]; $AppPerEn = $pp[1]
$pp = Get-Period $R.SecFrom ' di sicurezza' ' security'; $SecPerIt = $pp[0]; $SecPerEn = $pp[1]
# System and Application logs actually readable? (an unreadable log must not produce "OK, no errors")
$SysLogOk = [bool]$R.LogFrom -and (-not @($EvErrors | Where-Object { $_ -like 'System / :*' }).Count)
$AppLogOk = -not @($EvErrors | Where-Object { $_ -like 'Application / :*' }).Count

$nCrash = @($R.Crashes).Count
$crashBsod = @($R.Crashes | Where-Object { $_.Code -ne 0 }).Count
$crashOff  = $nCrash - $crashBsod
$crashBtn  = @($R.Crashes | Where-Object { $_.Code -eq 0 -and $_.PowerButton }).Count
$crashDisk = @($R.Crashes | Where-Object { $_.Cat -eq 'disk' }).Count
$crashDiskDrv = @($R.Crashes | Where-Object { $_.Cat -eq 'diskdrv' }).Count
$crashDiskMaybe = @($R.Crashes | Where-Object { $_.Cat -eq 'diskmem' }).Count
$crashMem  = @($R.Crashes | Where-Object { $_.Cat -eq 'memdrv' }).Count
$crashGpu  = @($R.Crashes | Where-Object { $_.Cat -eq 'gpu' }).Count
$crashBoot = @($R.Crashes | Where-Object { $_.AtBoot }).Count
$crashTimed = @($R.Crashes | Where-Object { $_.MinAfterPowerUp -ne $null -or $_.InSleep }).Count
if ($nCrash -eq 0) { Verdict 'Arresti anomali' 'Crashes' 'OK' "Nessuno $PeriodIt." "None $PeriodEn." }
elseif ($crashBsod -eq 0) {
    $st = 'UNSURE'; if ($crashOff -gt 5) { $st = 'WARN' }
    Verdict 'Arresti anomali' 'Crashes' $st ("$crashOff " + (Pl $crashOff 'spegnimento improvviso' 'spegnimenti improvvisi') + " senza schermata blu $PeriodIt ($crashBtn " + (Pl $crashBtn 'forzato' 'forzati') + ' con il pulsante). La causa non è determinabile dai registri: mancanza di corrente, batteria scarica, blocco del computer o spegnimento forzato.') ("$crashOff abrupt " + (Pl $crashOff 'shutdown' 'shutdowns') + " without a blue screen $PeriodEn ($crashBtn forced with the power button). The cause cannot be determined from the logs: power loss, flat battery, a frozen computer or a forced shutdown.")
} else {
    $st = 'WARN'; if ($crashBsod -ge 3) { $st = 'BAD' }
    $bootIt = ''; $bootEn = ''
    if ($crashTimed -gt 0) { $bootIt = " Per $crashTimed è noto il momento: $crashBoot entro 5 minuti dall'accensione o dal risveglio, oppure durante la sospensione."; $bootEn = " For $crashTimed the time is known: $crashBoot within 5 minutes of startup or wake-up, or while going to sleep." }
    Verdict 'Arresti anomali' 'Crashes' $st ("$crashBsod " + (Pl $crashBsod 'schermata blu' 'schermate blu') + " e $crashOff " + (Pl $crashOff 'spegnimento improvviso' 'spegnimenti improvvisi') + " $PeriodIt (dettaglio per causa nella sezione 6).$bootIt") ("$crashBsod blue " + (Pl $crashBsod 'screen' 'screens') + " and $crashOff abrupt " + (Pl $crashOff 'shutdown' 'shutdowns') + " $PeriodEn (breakdown by cause in section 6).$bootEn")
}
if ($crashBsod -gt 0) { Action '**Eseguire subito una copia di sicurezza dei dati:** un computer che va in schermata blu può smettere di avviarsi senza preavviso.' '**Back up the data now:** a computer that shows blue screens can stop booting without warning.' }
if ($crashDisk -gt 0) { Action '**Far controllare il disco:** alcuni arresti indicano letture non riuscite. Verificare fissaggio e stato del disco e, se il problema persiste, sostituirlo.' '**Have the disk checked:** some crashes point to failed reads. Check the disk seating and condition and replace it if the problem persists.' }
if ($crashMem -gt 0) { Action '**Testare la memoria RAM** con lo strumento di Windows o con il test del produttore.' '**Test the RAM** with the Windows tool or the manufacturer''s diagnostics.' }
if ($crashTimed -ge 2 -and $crashBoot -ge [math]::Ceiling($crashTimed / 2)) { Action "**Segnalare che i blocchi avvengono soprattutto all'accensione o al risveglio:** è un dettaglio importante per la diagnosi." '**Report that the crashes happen mostly at startup or wake-up:** it is an important clue for the diagnosis.' }

$diskBad = @($R.Disks | Where-Object { $_.Health -ne 'Healthy' -and $_.Health -ne 'Unknown' })
$worn = @($R.DiskHealth | Where-Object { "$($_.Wear)" -match '^\d+$' -and [int]$_.Wear -ge 90 })
$smartErr = @($R.DiskHealth | Where-Object { $_.ReadErrors -gt 0 -or $_.WriteErrors -gt 0 })
$sysErrN = @($R.DiskErrors).Count + @($R.IoErrors).Count + @($R.NtfsErrors).Count
$unattrN = @($R.UnattributedDiskErrors).Count
$otherN = @($R.OtherDiskErrors).Count
$otherIt = ''; $otherEn = ''
if ($otherN) { $otherIt = " $otherN " + (Pl $otherN 'errore riguarda' 'errori riguardano') + ' altri dischi (chiavette USB, schede di memoria, dischi esterni).'; $otherEn = " $otherN " + (Pl $otherN 'error concerns' 'errors concern') + ' other disks (USB sticks, memory cards, external drives).' }
if (-not @($R.Disks).Count) { Verdict 'Disco / SSD' 'Disk / SSD' 'NA' 'Informazioni sul disco non disponibili.' 'Disk information not available.' }
elseif ($diskBad.Count) { Verdict 'Disco / SSD' 'Disk / SSD' 'BAD' 'Windows o il disco stesso segnalano un problema di salute.' 'Windows or the disk itself reports a health problem.' }
elseif ($smartErr.Count) { Verdict 'Disco / SSD' 'Disk / SSD' 'BAD' 'Il disco ha registrato errori di lettura o scrittura non corretti.' 'The disk has recorded uncorrected read or write errors.' }
elseif ($crashDisk -gt 0) { Verdict 'Disco / SSD' 'Disk / SSD' 'WARN' ("Il disco non segnala guasti, ma $crashDisk " + (Pl $crashDisk 'arresto è dovuto' 'arresti sono dovuti') + " a letture non riuscite: la comunicazione con il disco è instabile.$otherIt") ("The disk reports no failure, but $crashDisk " + (Pl $crashDisk 'crash is' 'crashes are') + " due to failed reads: communication with the disk is unstable.$otherEn") }
elseif ($sysErrN -gt 0) { Verdict 'Disco / SSD' 'Disk / SSD' 'WARN' ("$sysErrN " + (Pl $sysErrN 'errore' 'errori') + " del disco di sistema o del file system $PeriodIt.$otherIt") ("$sysErrN system disk or file system " + (Pl $sysErrN 'error' 'errors') + " $PeriodEn.$otherEn") }
elseif ($worn.Count) {
    Verdict 'Disco / SSD' 'Disk / SSD' 'WARN' ("Il disco $($worn[0].Disk) dichiara di aver consumato il $($worn[0].Wear)% della durata prevista.$otherIt") ("The disk $($worn[0].Disk) reports $($worn[0].Wear)% of its rated life used.$otherEn")
    Action '**Pianificare la sostituzione del disco:** ha quasi esaurito la durata prevista. Tenere una copia dei dati.' '**Plan a disk replacement:** it has almost reached its rated life. Keep a backup of the data.'
}
elseif ($crashDiskMaybe -gt 0) { Verdict 'Disco / SSD' 'Disk / SSD' 'UNSURE' ("$crashDiskMaybe " + (Pl $crashDiskMaybe 'arresto indica' 'arresti indicano') + " un problema del disco o della memoria, ma i registri del disco non riportano errori.$otherIt") ("$crashDiskMaybe " + (Pl $crashDiskMaybe 'crash points' 'crashes point') + " to a disk or memory problem, but the disk logs show no errors.$otherEn") }
elseif ($crashDiskDrv -gt 0) { Verdict 'Disco / SSD' 'Disk / SSD' 'UNSURE' ("$crashDiskDrv " + (Pl $crashDiskDrv 'arresto indica' 'arresti indicano') + " un componente che non ha risposto in tempo (disco o driver), ma i registri del disco non riportano errori.$otherIt") ("$crashDiskDrv " + (Pl $crashDiskDrv 'crash points' 'crashes point') + " to a component that did not respond in time (disk or driver), but the disk logs show no errors.$otherEn") }
elseif ($unattrN -gt 0) { Verdict 'Disco / SSD' 'Disk / SSD' 'UNSURE' ("$unattrN " + (Pl $unattrN 'errore del controller dei dischi non attribuibile' 'errori del controller dei dischi non attribuibili') + " con certezza al disco di sistema.$otherIt") ("$unattrN disk controller " + (Pl $unattrN 'error' 'errors') + " that cannot be attributed with certainty to the system disk.$otherEn") }
else {
    $unkIt = ''; $unkEn = ''
    if (@($R.Disks | Where-Object { $_.Health -eq 'Unknown' }).Count) { $unkIt = ' Lo stato di salute (SMART) del disco non è leggibile su questo sistema.'; $unkEn = ' The disk health (SMART) status is not readable on this system.' }
    Verdict 'Disco / SSD' 'Disk / SSD' 'OK' ('Nessun errore sul disco di sistema.' + $unkIt + $otherIt) ('No errors on the system disk.' + $unkEn + $otherEn)
}
if ($diskBad.Count -or $smartErr.Count) { Action '**Sostituire il disco:** Windows o il disco stesso segnalano errori. Copiare subito i dati.' '**Replace the disk:** Windows or the disk itself reports errors. Copy the data immediately.' }

$fp = $R.FreePct
if ($fp -eq $null) { Verdict 'Spazio su disco' 'Disk space' 'NA' 'Dati non disponibili.' 'Data not available.' }
else {
    $st = 'BAD'; if ($fp -ge 15) { $st = 'OK' } elseif ($fp -ge 8) { $st = 'WARN' }
    Verdict 'Spazio su disco' 'Disk space' $st "Spazio libero sul disco di sistema: $fp%." "Free space on the system drive: $fp%."
    if ($fp -lt 15) { Action '**Liberare spazio sul disco:** sotto il 15% libero Windows rallenta e possono comparire errori.' '**Free up disk space:** below 15% free, Windows slows down and errors may appear.' }
}

$ramErr = @($R.WheaMem | Where-Object { $_.Level -le 2 }).Count
$ramCorr = @($R.WheaMem | Where-Object { $_.Level -eq 3 }).Count
$nMods = @($R.RamModules).Count
# newest completed Windows Memory Diagnostic: 1101/1201 no errors, 1102/1202 hardware errors (cancelled runs are ignored)
$mt = @($R.MemTest | Where-Object { @(1101, 1102, 1201, 1202) -contains $_.Id } | Sort-Object TimeCreated -Descending)
$memFail = ($mt.Count -gt 0 -and @(1102, 1202) -contains $mt[0].Id)
if ($memFail) {
    Verdict 'Memoria RAM' 'Memory (RAM)' 'BAD' "Il test della memoria di Windows del $($mt[0].TimeCreated.ToString('dd/MM/yyyy', $Inv)) ha rilevato errori hardware." "The Windows Memory Diagnostic run on $($mt[0].TimeCreated.ToString('yyyy-MM-dd', $Inv)) detected hardware errors."
    Action '**Sostituire o far testare la RAM:** il test della memoria di Windows ha trovato errori.' '**Replace or have the RAM tested:** the Windows memory test found errors.'
}
elseif ($ramErr -gt 0) { Verdict 'Memoria RAM' 'Memory (RAM)' 'BAD' ("$ramErr " + (Pl $ramErr 'errore di memoria non corretto segnalato' 'errori di memoria non corretti segnalati') + ' dall''hardware.') ("$ramErr uncorrected memory " + (Pl $ramErr 'error' 'errors') + ' reported by the hardware.') }
elseif ($crashMem -gt 0) { Verdict 'Memoria RAM' 'Memory (RAM)' 'WARN' ("$crashMem " + (Pl $crashMem 'arresto compatibile' 'arresti compatibili') + ' con problemi di memoria o di un driver.') ("$crashMem " + (Pl $crashMem 'crash' 'crashes') + ' consistent with memory or driver problems.') }
elseif ($ramCorr -gt 0 -or @($R.LowMemory).Count -gt 0) { Verdict 'Memoria RAM' 'Memory (RAM)' 'WARN' "Errori di memoria corretti: $ramCorr. Episodi di memoria esaurita: $(@($R.LowMemory).Count)." "Corrected memory errors: $ramCorr. Low-memory events: $(@($R.LowMemory).Count)." }
elseif ($nMods -eq 0) { Verdict 'Memoria RAM' 'Memory (RAM)' 'NA' 'Informazioni sulla memoria non disponibili.' 'Memory information not available.' }
else { Verdict 'Memoria RAM' 'Memory (RAM)' 'OK' ("$nMods " + (Pl $nMods 'modulo installato' 'moduli installati') + ', nessun errore segnalato.') ("$nMods " + (Pl $nMods 'module' 'modules') + ' installed, no errors reported.') }

$limit = $null; $ls = @($R.Samples | Where-Object { $_.Key -eq 'cpu_limit' }); if ($ls.Count) { $limit = $ls[0].Avg }
$planMax = $R.PlanMaxAC; if (-not $R.OnAC) { $planMax = $R.PlanMaxDC }
if ($limit -eq $null) { Verdict 'Prestazioni CPU' 'CPU performance' 'NA' 'Limite del processore non misurabile su questo sistema.' 'The processor limit cannot be measured on this system.' }
elseif ($limit -ge 95) { Verdict 'Prestazioni CPU' 'CPU performance' 'OK' 'Il processore lavora senza limitazioni.' 'The processor runs without limits.' }
elseif (-not $R.OnAC) { Verdict 'Prestazioni CPU' 'CPU performance' 'UNSURE' "Velocità del processore limitata: $([math]::Round($limit))% del massimo, ma il computer funzionava a batteria, dove è spesso normale. Ripetere con l'alimentatore collegato." "Processor speed limited to $([math]::Round($limit))% of the maximum, but the computer was running on battery, where this is often normal. Repeat with the charger connected." }
elseif ($planMax -ne $null -and $planMax -lt 100) { Verdict 'Prestazioni CPU' 'CPU performance' 'UNSURE' "Velocità del processore limitata: $([math]::Round($limit))% del massimo, ma il piano energetico imposta un massimo del $planMax%: il limite può essere voluto." "Processor speed limited to $([math]::Round($limit))% of the maximum, but the power plan sets a maximum of $planMax%: the limit may be intentional." }
else {
    $st = 'WARN'; if ($limit -lt 70) { $st = 'BAD' }
    Verdict 'Prestazioni CPU' 'CPU performance' $st "Con l'alimentatore collegato il BIOS limita la velocità del processore: $([math]::Round($limit))% del massimo. Cause tipiche: alimentatore non riconosciuto, batteria difettosa o raffreddamento insufficiente." "With the charger connected the BIOS limits the processor speed to $([math]::Round($limit))% of the maximum. Typical causes: unrecognized charger, faulty battery or poor cooling."
    Action '**Verificare alimentatore e batteria:** il BIOS sta rallentando il processore. Provare con un alimentatore originale funzionante.' '**Check the charger and battery:** the BIOS is slowing the processor down. Try a known-good original charger.'
}

# temperatures: sensors that never change are often placeholders, so a high static value is only "uncertain"
$tMax = $null; $zt = @($R.Samples | Where-Object { $_.Key -like 'temp:*' }); if ($zt.Count) { $tMax = ($zt | Measure-Object Max -Maximum).Maximum }
$ztLive = @($zt | Where-Object { ($_.Max - $_.Min) -ge 1 })
$tMaxLive = $null; if ($ztLive.Count) { $tMaxLive = ($ztLive | Measure-Object Max -Maximum).Maximum }
# one thermal zone counts once, even when both of its throttling counters show it
$thrN = @($R.Samples | Where-Object { ($_.Key -like 'reasons:*' -and $_.Max -gt 0) -or ($_.Key -like 'passive:*' -and $_.Min -lt 100) } | ForEach-Object { $_.Key -replace '^[a-z]+:', '' } | Select-Object -Unique).Count
$nTh = @($R.Thermal).Count
$loadIt = ''; $loadEn = ''; if (-not $Stress) { $loadIt = ' (PC non sotto sforzo: valore poco indicativo)'; $loadEn = ' (PC not under load: limited significance)' }
$tIt = Num $tMax 'it'; $tEn = Num $tMax 'en'
if ($nTh -gt 0) { Verdict 'Temperature' 'Temperatures' 'BAD' "$nTh $(Pl $nTh 'evento termico registrato' 'eventi termici registrati') da Windows (surriscaldamento o limitazione per temperatura)." "$nTh thermal $(Pl $nTh 'event' 'events') logged by Windows (overheating or temperature throttling)." }
elseif ($tMaxLive -ne $null -and $tMaxLive -ge 95) { Verdict 'Temperature' 'Temperatures' 'BAD' "Temperatura interna fino a $(Num $tMaxLive 'it') °C: molto alta." "Internal temperature up to $(Num $tMaxLive 'en') °C: very high." }
elseif ($tMax -ne $null -and $tMax -ge 85) {
    if ($tMaxLive -ne $null -and $tMaxLive -ge 85) { Verdict 'Temperature' 'Temperatures' 'WARN' "Temperatura interna fino a $(Num $tMaxLive 'it') °C: alta." "Internal temperature up to $(Num $tMaxLive 'en') °C: high." }
    else { Verdict 'Temperature' 'Temperatures' 'UNSURE' "Un sensore indica $tIt °C, ma il valore non cambia mai durante la misurazione: alcuni sensori riportano valori fissi non reali. Confermare con un programma di monitoraggio." "A sensor reports $tEn °C, but the value never changes during the measurement: some sensors report fixed, unrealistic values. Confirm with a monitoring tool." }
}
elseif ($thrN -gt 0) { Verdict 'Temperature' 'Temperatures' 'WARN' "$thrN $(Pl $thrN 'sensore segnala' 'sensori segnalano') un rallentamento per calore durante la misurazione." "$thrN $(Pl $thrN 'sensor reports' 'sensors report') heat throttling during the measurement." }
elseif ($tMax -ne $null -and $Stress -and $ztLive.Count -eq 0) { Verdict 'Temperature' 'Temperatures' 'UNSURE' "I sensori ($tIt °C) non sono cambiati con il processore sotto sforzo: non misurano la temperatura del processore o riportano valori fissi." "The sensors ($tEn °C) did not change with the processor under full load: they do not measure the processor temperature or report fixed values." }
elseif ($tMax -ne $null) { Verdict 'Temperature' 'Temperatures' 'OK' "Temperatura massima rilevata: $tIt °C$loadIt." "Highest temperature measured: $tEn °C$loadEn." }
else { Verdict 'Temperature' 'Temperatures' 'NA' 'Nessun evento termico registrato. Temperature non leggibili su questo modello.' 'No thermal events logged. Temperatures are not readable on this model.' }
if ($nTh -gt 0 -or ($tMaxLive -ne $null -and $tMaxLive -ge 90) -or $thrN -gt 0) { Action '**Far pulire il sistema di raffreddamento** e verificare il funzionamento della ventola.' '**Have the cooling system cleaned** and check that the fan works.' }

$bh = $R.BatteryHealth
if ($bh -ne $null -and $bh -gt 105) { Verdict 'Batteria' 'Battery' 'UNSURE' "La batteria dichiara una capacità superiore a quella di progetto ($bh%): i dati che fornisce non sono affidabili." "The battery reports more capacity than its design value ($bh%): the data it provides is not reliable." }
elseif ($bh -ne $null) {
    $st = 'BAD'; if ($bh -ge 70) { $st = 'OK' } elseif ($bh -ge 50) { $st = 'WARN' }
    Verdict 'Batteria' 'Battery' $st "Capacità residua: $bh% di quella originale." "Remaining capacity: $bh% of the original."
    if ($bh -lt 60) { Action '**Sostituire la batteria:** conserva meno del 60% della capacità originale.' '**Replace the battery:** it retains less than 60% of its original capacity.' }
}
elseif ($R.BatteryPresent) { Verdict 'Batteria' 'Battery' 'NA' 'Batteria presente, capacità non leggibile.' 'Battery present, capacity not readable.' }
else { Verdict 'Batteria' 'Battery' 'NA' 'Nessuna batteria rilevata (probabile PC fisso).' 'No battery detected (probably a desktop PC).' }

$netErrN = @($R.NetErrors).Count
$nAd = @($R.NetConfig).Count
if ($SkipNetwork) { Verdict 'Rete' 'Network' 'NA' 'Test di rete non eseguiti.' 'Network tests not run.' }
elseif ($nAd -eq 0 -and -not ($R.Dns -or $R.Tcp -or $R.PingInternet)) {
    Verdict 'Rete' 'Network' 'BAD' 'Nessuna scheda di rete ha un indirizzo valido: il computer non è collegato alla rete.' 'No network adapter has a valid address: the computer is not connected to a network.'
    Action '**Verificare il collegamento di rete** (cavo o Wi-Fi).' '**Check the network connection** (cable or Wi-Fi).'
} elseif ($R.Dns -and ($R.Tcp -or $R.PingInternet)) {
    $st = 'OK'; if ($netErrN -gt 10) { $st = 'WARN' }
    $adIt = "$nAd " + (Pl $nAd 'scheda' 'schede') + ' con indirizzo valido'; $adEn = "$nAd " + (Pl $nAd 'adapter' 'adapters') + ' with a valid address'
    if ($nAd -eq 0) { $adIt = 'Configurazione delle schede non leggibile'; $adEn = 'Adapter configuration not readable' }
    Verdict 'Rete' 'Network' $st ("$adIt, Internet raggiungibile, $netErrN " + (Pl $netErrN 'errore' 'errori') + " di rete $PeriodIt.") ("$adEn, Internet reachable, $netErrN network " + (Pl $netErrN 'error' 'errors') + " $PeriodEn.")
} elseif ($R.Dns) {
    $pIt = ''; $pEn = ''; if ($R.Proxy) { $pIt = ' Sul computer è impostato un proxy.'; $pEn = ' A proxy is configured on this computer.' }
    Verdict 'Rete' 'Network' 'UNSURE' "I nomi dei siti vengono risolti, ma le connessioni dirette verso Internet non riescono. Può essere normale in reti aziendali con proxy o firewall.$pIt" "Site names resolve, but direct connections to the Internet fail. This can be normal on company networks with a proxy or firewall.$pEn"
} elseif ($R.Proxy -or ($R.Cs -and $R.Cs.PartOfDomain -and $R.PingGateway -eq $true)) {
    # company networks often resolve internet names only through a proxy (also one discovered automatically)
    $whyIt = 'il computer è in un dominio aziendale'; $whyEn = 'the computer is in a company domain'
    if ($R.Proxy) { $whyIt = 'è impostato un proxy'; $whyEn = 'a proxy is configured' }
    Verdict 'Rete' 'Network' 'UNSURE' "I nomi dei siti non vengono risolti direttamente, ma $whyIt`: in queste reti la navigazione passa spesso da un proxy. Verificare aprendo un sito nel browser." "Site names do not resolve directly, but $whyEn`: on these networks browsing often goes through a proxy. Check by opening a website in the browser."
} elseif ($R.PingGateway -eq $true -or $R.PingInternet -or $R.Tcp) {
    Verdict 'Rete' 'Network' 'BAD' 'La rete risponde, ma la risoluzione dei nomi (DNS) non funziona: i siti non si aprono.' 'The network responds, but name resolution (DNS) does not work: websites will not open.'
    Action '**Verificare le impostazioni DNS** della scheda di rete o del router.' '**Check the DNS settings** of the network adapter or router.'
} else {
    Verdict 'Rete' 'Network' 'BAD' 'Né il router né Internet rispondono.' 'Neither the router nor the Internet responds.'
    Action '**Verificare la connessione di rete:** il computer non raggiunge né il router né Internet.' '**Check the network connection:** the computer reaches neither the router nor the Internet.'
}

# security: any active antivirus is enough (with a third-party antivirus, Defender being off is normal)
$avOn = @($R.Antivirus | Where-Object { $_.On })
$anyAv = ($avOn.Count -gt 0) -or ($R.Defender -and $R.Defender.RealTime)
# "no antivirus" is stated only when it is certain: products registered in Security Center, a working Security Center
# on a client edition, or Defender running as the main antivirus. Otherwise (service off, server, Defender passive) it is uncertain.
$avKnown = (@($R.Antivirus).Count -gt 0) -or ($R.ScAvailable -and $R.WscRunning -and -not $R.IsServer) -or ($R.Defender -and "$($R.Defender.Mode)" -match '^Normal')
$avOld = ($avOn.Count -gt 0 -and -not @($avOn | Where-Object { $_.UpToDate }).Count) -or ($R.Defender -and $R.Defender.RealTime -and $R.Defender.SigAge -gt 7)
$fwOff = @($R.Firewall | Where-Object { -not $_.Enabled }).Count
$fwKo = $fwOff; if (@($R.ThirdPartyFw).Count) { $fwKo = 0 }
$st = 'OK'
if (($avKnown -and -not $anyAv) -or $fwKo -ge 3) { $st = 'BAD' }
elseif ($fwKo -gt 0 -or $avOld -or $R.RebootPending -or $R.FailedRemote -gt 100) { $st = 'WARN' }
elseif (-not $avKnown) { $st = 'UNSURE' }
$sIt = @(); $sEn = @()
if ($anyAv) { $names = @($avOn | ForEach-Object { $_.Name }); if (-not $names.Count) { $names = @('Windows Defender') }; $sIt += "Antivirus attivo ($($names -join ', '))."; $sEn += "Antivirus active ($($names -join ', '))." }
elseif ($avKnown) { $sIt += 'Nessun antivirus attivo.'; $sEn += 'No active antivirus.' }
else { $sIt += 'Stato antivirus non verificabile su questo sistema.'; $sEn += 'Antivirus status cannot be checked on this system.' }
if (@($R.ThirdPartyFw).Count) { $sIt += "Firewall gestito da $($R.ThirdPartyFw -join ', ')."; $sEn += "Firewall managed by $($R.ThirdPartyFw -join ', ')." }
elseif ($fwKo -gt 0) { $sIt += "$fwKo $(Pl $fwKo 'profilo' 'profili') del firewall di Windows $(Pl $fwKo 'disattivato' 'disattivati')."; $sEn += "$fwKo Windows firewall $(Pl $fwKo 'profile' 'profiles') disabled." }
else { $sIt += 'Firewall attivo su tutti i profili.'; $sEn += 'Firewall on for all profiles.' }
if ($avOld) { $sIt += 'Definizioni antivirus non aggiornate.'; $sEn += 'Antivirus definitions out of date.' }
if ($R.FailedRemote -gt 100) { $sIt += "$($R.FailedRemote) tentativi di accesso falliti dalla rete o dal desktop remoto."; $sEn += "$($R.FailedRemote) failed sign-in attempts from the network or remote desktop." }
if ($R.RebootPending) { $sIt += 'È in sospeso un riavvio per completare gli aggiornamenti.'; $sEn += 'A restart is pending to finish updates.' }
Verdict 'Sicurezza' 'Security' $st ($sIt -join ' ') ($sEn -join ' ')
if ($avKnown -and -not $anyAv) { Action '**Attivare un antivirus:** non ne risulta nessuno attivo.' '**Enable an antivirus:** none appears to be active.' }
if ($fwKo -gt 0) { Action '**Riattivare il firewall di Windows** sui profili disattivati.' '**Turn the Windows firewall back on** for the disabled profiles.' }
if ($avOld) { Action '**Aggiornare le definizioni antivirus.**' '**Update the antivirus definitions.**' }
if ($R.FailedRemote -gt 100) { Action '**Verificare i tentativi di accesso dalla rete:** possono essere un dispositivo con una password vecchia salvata oppure tentativi non autorizzati.' '**Check the network sign-in attempts:** they may come from a device with an old saved password or from unauthorized attempts.' }
if ($R.RebootPending) { Action '**Riavviare il computer:** ci sono aggiornamenti in attesa di essere completati.' '**Restart the computer:** updates are waiting to be completed.' }

# Windows Update
$nUpd = @($R.UpdatesFailed).Count
$updAge = $null; if ($R.LastUpdate) { $updAge = [int]((Get-Date) - $R.LastUpdate).TotalDays }
if ($R.WuDisabled) {
    Verdict 'Aggiornamenti di Windows' 'Windows updates' 'BAD' 'Il servizio Windows Update è disattivato: il sistema non riceve aggiornamenti di sicurezza.' 'The Windows Update service is disabled: the system does not receive security updates.'
    Action '**Riattivare il servizio Windows Update.**' '**Re-enable the Windows Update service.**'
} elseif ($nUpd -gt 0) {
    $kbs = ($R.UpdatesFailed | ForEach-Object { if ($_.Message -match '(KB\d+)') { $matches[1] } }) -join ', '
    Verdict 'Aggiornamenti di Windows' 'Windows updates' 'WARN' "$nUpd $(Pl $nUpd 'aggiornamento non riuscito' 'aggiornamenti non riusciti') e non ancora $(Pl $nUpd 'installato' 'installati'): $kbs." "$nUpd $(Pl $nUpd 'update' 'updates') failed and still missing: $kbs."
    Action '**Installare gli aggiornamenti di Windows non riusciti.**' '**Install the Windows updates that failed.**'
} elseif ($updAge -ne $null -and $updAge -gt 60) {
    Verdict 'Aggiornamenti di Windows' 'Windows updates' 'WARN' "L'ultimo aggiornamento di Windows risale a $updAge giorni fa." "The last Windows update was $updAge days ago."
    Action '**Verificare perché Windows non si aggiorna da oltre due mesi.**' '**Check why Windows has not been updated for more than two months.**'
} elseif ($updAge -ne $null) { Verdict 'Aggiornamenti di Windows' 'Windows updates' 'OK' "Ultimo aggiornamento installato $updAge $(Pl $updAge 'giorno' 'giorni') fa." "Last update installed $updAge $(Pl $updAge 'day' 'days') ago." }
else { Verdict 'Aggiornamenti di Windows' 'Windows updates' 'NA' 'Data dell''ultimo aggiornamento non determinabile.' 'Date of the last update cannot be determined.' }

$nBad = @($R.BadDevices).Count; $nSvc = @($R.SvcCrashes).Count
$st = 'OK'; if ($nBad -gt 0 -or $nSvc -gt 5) { $st = 'WARN' }
$srtIt = ''; $srtEn = ''
if ($R.SrtTrail) { $srtIt = " Presente un log di ripristino dell'avvio del $($R.SrtTrail.LastWriteTime.ToString('dd/MM/yyyy', $Inv))."; $srtEn = " A startup repair log from $($R.SrtTrail.LastWriteTime.ToString('yyyy-MM-dd', $Inv)) is present." }
Verdict 'Driver e servizi' 'Drivers and services' $st ("Dispositivi con errori: $nBad. " + "Servizi chiusi inaspettatamente $PeriodIt`: $nSvc.$srtIt") ("Devices with errors: $nBad. " + "Services that stopped unexpectedly $PeriodEn`: $nSvc.$srtEn")
if ($nBad -gt 0) { Action "**Controllare in Gestione dispositivi** $(Pl $nBad 'il dispositivo che non funziona' "i $nBad dispositivi che non funzionano") correttamente." "**Check Device Manager** for the $nBad $(Pl $nBad 'device that is' 'devices that are') not working properly." }

# the same graphics timeout usually leaves both a Display 4101 event and a WATCHDOG live dump: count the larger of the two
$nTdr = @($R.Tdr).Count; $nGw = @($R.GpuWatchdog).Count; $nGpuEv = [Math]::Max($nTdr, $nGw); $nGpu = $nGpuEv + $crashGpu
if ($crashGpu -gt 0 -or $nGpuEv -gt 2) {
    Verdict 'Scheda video' 'Graphics' 'WARN' "La scheda video ha smesso di rispondere almeno $nGpu $(Pl $nGpu 'volta' 'volte') $PeriodIt." "The graphics card stopped responding at least $nGpu $(Pl $nGpu 'time' 'times') $PeriodEn."
    Action "**Aggiornare il driver della scheda video** e verificare le temperature." '**Update the graphics driver** and check the temperatures.'
}

$nApp = @($R.AppCrashes).Count
$st = 'OK'; if ($nApp -gt 30) { $st = 'WARN' }
Verdict 'Stabilità dei programmi' 'Program stability' $st ("$nApp " + (Pl $nApp 'chiusura inattesa' 'chiusure inattese') + " di programmi $AppPerIt.") ("$nApp unexpected program " + (Pl $nApp 'closure' 'closures') + " $AppPerEn.")

if (@($R.Whea).Count -gt 0) {
    Verdict 'Errori hardware (WHEA)' 'Hardware errors (WHEA)' 'BAD' "$(@($R.Whea).Count) $(Pl @($R.Whea).Count 'errore hardware non corretto' 'errori hardware non corretti') $PeriodIt." "$(@($R.Whea).Count) uncorrected hardware $(Pl @($R.Whea).Count 'error' 'errors') $PeriodEn."
    Action "**Far verificare l'hardware:** il sistema ha segnalato errori hardware gravi (WHEA)." '**Have the hardware checked:** the system reported serious hardware errors (WHEA).'
} elseif (@($R.WheaCorrected).Count -gt 20) {
    Verdict 'Errori hardware (WHEA)' 'Hardware errors (WHEA)' 'WARN' "$(@($R.WheaCorrected).Count) errori hardware corretti automaticamente: da soli non causano problemi, ma se sono molti indicano un componente da tenere d'occhio." "$(@($R.WheaCorrected).Count) hardware errors corrected automatically: they cause no problem by themselves, but many of them point to a component worth watching."
}
if ($R.Sfc) {
    if ($R.Sfc -eq 'ok') { Verdict 'File di sistema' 'System files' 'OK' 'Nessun file di sistema danneggiato.' 'No damaged system files.' }
    elseif ($R.Sfc -eq 'bad') {
        Verdict 'File di sistema' 'System files' 'BAD' 'Rilevati file di sistema danneggiati.' 'Damaged system files found.'
        Action '**Riparare i file di sistema** con `sfc /scannow` e, da Windows 8, `DISM /Online /Cleanup-Image /RestoreHealth`.' '**Repair the system files** with `sfc /scannow` and, from Windows 8, `DISM /Online /Cleanup-Image /RestoreHealth`.'
    } else { Verdict 'File di sistema' 'System files' 'UNSURE' 'Esito del controllo non interpretabile (vedere data\sfc_verifyonly.txt).' 'The check result could not be interpreted (see data\sfc_verifyonly.txt).' }
}
if ($R.Chkdsk) {
    if ($R.Chkdsk -eq 'ok') { Verdict 'File system del disco' 'Disk file system' 'OK' 'Nessun problema nel file system.' 'No file system problems.' }
    elseif ($R.Chkdsk -eq 'bad') {
        # a read-only chkdsk of the volume in use can report errors that are not real (Microsoft chkdsk documentation):
        # the result is a warning only when the dirty bit or NTFS errors in the log confirm it
        if ($R.Dirty -eq 'yes' -or @($R.NtfsErrors).Count -gt 0) {
            Verdict 'File system del disco' 'Disk file system' 'WARN' 'Il controllo in sola lettura ha trovato errori nel file system, confermati dai registri di Windows.' 'The read-only check found file system errors, confirmed by the Windows logs.'
            Action '**Riparare il file system** con `chkdsk /f` pianificato al riavvio, dopo aver fatto il backup.' '**Repair the file system** with `chkdsk /f` scheduled at restart, after a backup.'
        } else {
            Verdict 'File system del disco' 'Disk file system' 'UNSURE' 'Il controllo in sola lettura ha segnalato errori, ma nient''altro li conferma: con il disco in uso questo controllo può dare falsi allarmi.' 'The read-only check reported errors, but nothing else confirms them: with the disk in use this check can give false alarms.'
            Action '**Confermare lo stato del file system** con `chkdsk /f` pianificato al riavvio, dopo aver fatto il backup.' '**Confirm the file system state** with `chkdsk /f` scheduled at restart, after a backup.'
        }
    } else { Verdict 'File system del disco' 'Disk file system' 'UNSURE' 'Esito del controllo non interpretabile (vedere data\chkdsk_readonly.txt).' 'The check result could not be interpreted (see data\chkdsk_readonly.txt).' }
}
if ($R.BiosAge -and $R.BiosAge -gt 730) { Action '**Verificare se esiste un BIOS più recente:** quello installato ha più di due anni.' '**Check whether a newer BIOS exists:** the installed one is more than two years old.' }
if ($IsWin7) { Action '**Valutare l''aggiornamento del sistema operativo:** Windows 7 non riceve più aggiornamenti di sicurezza.' '**Consider upgrading the operating system:** Windows 7 no longer receives security updates.' }
elseif ($WinVer.Major -eq 6) { Action '**Valutare l''aggiornamento del sistema operativo:** Windows 8 / 8.1 non riceve più aggiornamenti di sicurezza.' '**Consider upgrading the operating system:** Windows 8 / 8.1 no longer receives security updates.' }
if ($R.DumpsEnabled -eq $false -and $crashBsod -gt 0) { Action '**Riattivare il salvataggio dei file di crash** (Proprietà del sistema > Avvio e ripristino) per poter analizzare i prossimi blocchi.' '**Turn crash dump saving back on** (System properties > Startup and Recovery) so that future crashes can be analysed.' }
elseif (@($R.DumpInitFailed).Count -and $crashBsod -gt 0) { Action '**Controllare file di paging e salvataggio dei crash** (Proprietà del sistema > Avvio e ripristino): all''avvio Windows non riesce a prepararlo, quindi i prossimi blocchi non lasceranno file da analizzare.' '**Check the paging file and crash dump saving** (System properties > Startup and Recovery): Windows cannot prepare it at startup, so future crashes will leave no file to analyse.' }
if (-not $SysLogOk) { NA 'Registro eventi di sistema (non leggibile: vedere run_log.txt)' 'System event log (not readable: see run_log.txt)' }
foreach ($v in $Verdicts) {
    if ($v.State -ne 'OK') { continue }
    if (-not $SysLogOk -and $v.En -eq 'Crashes') { $v.State = 'UNSURE'; $v.DetIt = 'Registro eventi di sistema non leggibile: arresti non verificabili (vedere run_log.txt).'; $v.DetEn = 'System event log not readable: crashes cannot be checked (see run_log.txt).' }
    elseif ((-not $SysLogOk -and @('Disk / SSD', 'Memory (RAM)', 'Drivers and services') -contains $v.En) -or (-not $AppLogOk -and $v.En -eq 'Program stability')) {
        $v.State = 'UNSURE'; $v.DetIt += ' Registro eventi di Windows non leggibile: dati incompleti.'; $v.DetEn += ' The Windows event log could not be read: data incomplete.'
    }
}
if ($Actions.Count -eq 0) {
    if (@($Verdicts | Where-Object { $_.State -eq 'WARN' -or $_.State -eq 'UNSURE' }).Count) { Action "Nessuna azione urgente. Tenere d'occhio i punti segnalati in giallo o in blu nella tabella." 'No urgent action. Keep an eye on the items marked in yellow or blue in the table.' }
    else { Action 'Nessuna azione urgente: i controlli automatici non hanno rilevato problemi.' 'No urgent action: the automatic checks found no problems.' }
}

# ============================== REPORTS ==============================

function Build-Report([string]$lng) {
    $L = New-Object 'System.Collections.Generic.List[string]'
    function T($it, $en) { if ($lng -eq 'it') { return $it } else { return $en } }
    function M($s = '') { $L.Add([string]$s) }
    function ND { return (T 'n/d' 'n/a') }
    function D($dt, [switch]$Time) {
        $dt = ToDate $dt
        if (-not $dt) { return '' }
        $f = 'yyyy-MM-dd'; if ($lng -eq 'it') { $f = 'dd/MM/yyyy' }
        if ($Time) { $f += ' HH:mm' }
        return $dt.ToString($f, $Inv)
    }
    function N($v, [string]$fmt = '0.#') { return (Num $v $lng $fmt) }
    function Light($s) { switch ($s) { 'OK' { return '🟢 OK' } 'WARN' { return (T '🟡 Da verificare' '🟡 Check') } 'BAD' { return (T '🔴 Problema' '🔴 Problem') } 'UNSURE' { return (T '🔵 Incerto' '🔵 Uncertain') } default { return (T '⚪ Non valutabile' '⚪ Not assessed') } } }
    function YesNo($b) { if ($b -eq $true) { return (T 'sì' 'yes') } elseif ($b -eq $false) { return 'no' } else { return (ND) } }
    function Tr($v) {
        switch ("$v") {
            'Healthy' { return (T 'integro' 'healthy') } 'Warning' { return (T 'ATTENZIONE' 'WARNING') } 'Unhealthy' { return (T 'NON integro' 'UNHEALTHY') } 'Unknown' { return (T 'non rilevabile' 'not readable') }
            'Domain' { return (T 'rete di dominio' 'domain network') } 'Private' { return (T 'rete privata' 'private network') } 'Public' { return (T 'rete pubblica' 'public network') }
            'FullyEncrypted' { return (T 'cifrato' 'encrypted') } 'FullyDecrypted' { return (T 'non cifrato' 'not encrypted') } 'EncryptionInProgress' { return (T 'cifratura in corso' 'encryption in progress') }
            'DecryptionInProgress' { return (T 'decifratura in corso' 'decryption in progress') } 'EncryptionPaused' { return (T 'cifratura in pausa' 'encryption paused') } 'DecryptionPaused' { return (T 'decifratura in pausa' 'decryption paused') }
            'unknown' { return (ND) }
            default { return "$v" }
        }
    }
    function Tab($hdr, $rows) {
        $rows = @($rows)
        if ($rows.Count -gt 0 -and -not ($rows[0] -is [array])) { $rows = ,$rows }      # a single row arrives unrolled
        M ('| ' + ($hdr -join ' | ') + ' |'); M ('|' + ('---|' * $hdr.Count))
        foreach ($r in $rows) { M ('| ' + ((@($r) | ForEach-Object { ("$_" -replace '\|', '/') -replace "`r?`n", ' ' }) -join ' | ') + ' |') }
        M ''
    }
    function Note($it, $en) { M ('> *' + (T 'Come leggerlo' 'How to read it') + ':* ' + (T $it $en)); M '' }
    function CatName($k) { $c = $CatNames[$k]; if (-not $c) { $c = $CatNames['other'] }; return (T $c[0] $c[1]) }
    $o = $R.Os; $cs = $R.Cs; $bios = $R.Bios
    $Per = T $PeriodIt $PeriodEn

    M ('# ' + (T 'Diagnosi del computer' 'Computer diagnosis') + " - $($env:COMPUTERNAME)")
    M ''
    $modeName = 'Normal'; if ($mode -eq 'stress') { $modeName = 'Stress' } elseif ($mode -eq 'deepscan') { $modeName = 'DeepScan' }
    M ('**' + (T 'Data' 'Date') + ':** ' + (D (Get-Date) -Time) + ' · **' + (T 'Analisi' 'Analysis') + ":** $modeName · **" + (T 'Sistema scelto' 'Selected system') + ":** $($OsNames[$os]) · **" + (T 'Periodo analizzato' 'Period analysed') + ":** $Per")
    M ''
    M (T 'Report generato automaticamente in sola lettura. I dati completi sono nella cartella `data`.' 'Automatically generated read-only report. Full data is in the `data` folder.')
    M ''
    M ('## 1. ' + (T 'Risultato in breve' 'Summary'))
    M ''
    Tab @((T 'Area' 'Area'), (T 'Esito' 'Result'), (T 'Dettaglio' 'Details')) @($Verdicts | ForEach-Object { ,@((T $_.It $_.En), (Light $_.State), (T $_.DetIt $_.DetEn)) })
    $bad = @($Verdicts | Where-Object { $_.State -eq 'BAD' }); $warn = @($Verdicts | Where-Object { $_.State -eq 'WARN' }); $uns = @($Verdicts | Where-Object { $_.State -eq 'UNSURE' })
    if ($bad.Count) { M ('> 🔴 **' + (T 'Da risolvere' 'To fix') + ':** ' + (($bad | ForEach-Object { T $_.It $_.En }) -join ', ') + '.'); M '' }
    if ($warn.Count) { M ('> 🟡 **' + (T 'Da tenere d''occhio' 'Keep an eye on') + ':** ' + (($warn | ForEach-Object { T $_.It $_.En }) -join ', ') + '.'); M '' }
    if ($uns.Count) { M ('> 🔵 **' + (T 'Risultato incerto' 'Uncertain result') + ':** ' + (($uns | ForEach-Object { T $_.It $_.En }) -join ', ') + '. ' + (T 'I dati disponibili non bastano per un giudizio sicuro: vedere il dettaglio.' 'The available data is not enough for a reliable judgement: see the details.')); M '' }
    if (-not ($bad.Count + $warn.Count + $uns.Count)) { M ('> 🟢 ' + (T 'Nessun problema rilevato dai controlli automatici.' 'No problems found by the automatic checks.')); M '' }
    M ('## 2. ' + (T 'Cosa fare' 'What to do'))
    M ''
    foreach ($a in $Actions) { M ('- ' + (T $a.It $a.En)) }
    M ''

    M ('## 3. ' + (T 'Il computer' 'The computer'))
    M ''
    $uptime = ''
    if ($R.LastBoot) {
        $hrs = [int]((Get-Date) - $R.LastBoot).TotalHours
        $uptime = T "$hrs $(Pl $hrs 'ora' 'ore') fa" "$hrs $(Pl $hrs 'hour' 'hours') ago"
        # with Fast Startup a shutdown does not reset this value: only a restart does
        if ($R.FastStartup -eq 1) { $uptime += T "; con l'Avvio rapido attivo lo spegnimento non azzera questo valore, solo il riavvio" '; with Fast Startup on, shutting down does not reset this value, only a restart does' }
        $uptime = " ($uptime)"
    }
    $sbText = T 'non determinabile' 'unknown'
    if ($R.SecureBoot -eq 'on') { $sbText = T 'attivo' 'on' } elseif ($R.SecureBoot -eq 'off') { $sbText = T 'disattivato' 'off' } elseif ($R.SecureBoot -eq 'na') { $sbText = T 'non supportato (BIOS tradizionale o Windows 7)' 'not supported (legacy BIOS or Windows 7)' }
    $dom = ''; if ($cs) { $dom = $cs.Workgroup; if ($cs.PartOfDomain) { $dom = $cs.Domain } }
    $ubr = ''; if ($R.Ubr) { $ubr = ".$($R.Ubr)" }
    $ram = ND; if ($cs -and $cs.TotalPhysicalMemory) { $ram = (N ($cs.TotalPhysicalMemory / 1GB) '0.0') + ' GB' }
    $winText = ND; if ($o) { $winText = ("$($o.Caption) $($o.CSDVersion) build $($o.BuildNumber)$ubr" -replace '\s+', ' ').Trim() }
    $comp = ND; if ($cs) { $comp = "$($cs.Manufacturer) $($cs.Model)" }
    $cpuText = ND; if ($R.Cpu) { $nc = $R.Cpu.NumberOfCores; $cpuText = "$($R.Cpu.Name) ($nc " + (T 'core' (Pl $nc 'core' 'cores')) + ')' }
    $psText = $PSVText; if ($Legacy) { $psText += ' ' + (T '(metodi compatibili)' '(compatible methods)') }
    $rows = @(
        ,@((T 'Modello' 'Model'), $comp)
        ,@((T 'Numero di serie' 'Serial number'), "$($bios.SerialNumber)")
        ,@((T 'Processore' 'Processor'), $cpuText)
        ,@((T 'Scheda video' 'Graphics'), $R.Gpu)
        ,@('RAM', $ram)
        ,@('BIOS', "$($bios.SMBIOSBIOSVersion) $(T 'del' 'from') $(D $R.BiosDate)")
        ,@('Windows', $winText)
        ,@('PowerShell', $psText)
        ,@((T 'Windows installato il' 'Windows installed on'), (D $R.InstallDate -Time))
        ,@((T 'Ultimo avvio completo' 'Last full boot'), ((D $R.LastBoot -Time) + $uptime))
        ,@('Secure Boot', $sbText)
        ,@((T 'Dominio / gruppo di lavoro' 'Domain / workgroup'), $dom)
    )
    if (@($R.PrevWindows).Count) { $rows += ,@((T 'Versioni precedenti di Windows' 'Previous Windows versions'), ($R.PrevWindows -join '; ')) }
    if ($R.LogFrom) { $rows += ,@((T 'Registro eventi disponibile dal' 'Event log available since'), (D $R.LogFrom)) }
    Tab @((T 'Voce' 'Item'), (T 'Valore' 'Value')) $rows
    if (@($R.BiosHp).Count) { M (T 'Impostazioni del BIOS leggibili da Windows:' 'BIOS settings readable from Windows:'); M ''; Tab @((T 'Impostazione' 'Setting'), (T 'Valore' 'Value')) @($R.BiosHp | ForEach-Object { ,@($_.Name, $_.CurrentValue) }) }

    M ('## 4. ' + (T 'Disco e spazio' 'Disk and space'))
    M ''
    if (@($R.Disks).Count) {
        Tab @((T 'Disco' 'Disk'), (T 'Tipo' 'Type'), (T 'Stato' 'Status'), (T 'Temperatura' 'Temperature'), (T 'Usura' 'Wear'), (T 'Ore di accensione' 'Power-on hours')) @($R.Disks | ForEach-Object {
            $d = $_; $h = @($R.DiskHealth | Where-Object { $_.Disk -eq $d.FriendlyName }) | Select-Object -First 1
            $tt = ND; $wr = ND; $hr = ND
            if ($h) { if ($h.Temp) { $tt = "$($h.Temp) °C"; if ($h.TempMax) { $tt += ' (' + (T 'limite' 'rated max') + " $($h.TempMax) °C)" } }; if ($h.Wear -ne $null) { $wr = "$($h.Wear)%" }; if ($h.Hours) { $hr = $h.Hours } }
            ,@($d.FriendlyName, $d.Type, (Tr $d.Health), $tt, $wr, $hr) })
    }
    if (@($R.Volumes).Count) { Tab @((T 'Unità' 'Drive'), (T 'Etichetta' 'Label'), 'File system', (T 'Totale GB' 'Total GB'), (T 'Liberi GB' 'Free GB')) @($R.Volumes | ForEach-Object { ,@($_.Drive, $_.Label, $_.FileSystem, (N $_.SizeGB), (N $_.FreeGB)) }) }
    M ((T 'Errori del disco di sistema' 'System disk errors') + ': **' + (@($R.IoErrors).Count + @($R.DiskErrors).Count) + '** · ' + (T 'di altri dischi (USB, schede)' 'other disks (USB, cards)') + ': **' + @($R.OtherDiskErrors).Count + '** · ' + (T 'non attribuibili' 'unattributed') + ': **' + @($R.UnattributedDiskErrors).Count + '** · ' + (T 'Errori del file system (NTFS)' 'File system (NTFS) errors') + ': **' + @($R.NtfsErrors).Count + '**')
    M ''
    $dirtyText = ND; if ($R.Dirty -eq 'no') { $dirtyText = 'no' } elseif ($R.Dirty -eq 'yes') { $dirtyText = T 'SÌ' 'YES' }
    $trimText = ND; if ($R.Trim -eq 'on') { $trimText = T 'attivo' 'on' } elseif ($R.Trim -eq 'off') { $trimText = T 'disattivato' 'off' }
    M ((T 'File system da riparare' 'File system needs repair') + ": **$dirtyText** · TRIM: **$trimText** · " + (T 'Controller Intel RST/VMD' 'Intel RST/VMD controller') + ': **' + (YesNo $R.Rst) + '**')
    M ''
    $nD = @($R.IoDiag).Count; if ($nD) { M ('*' + (T "Sono presenti inoltre $nD $(Pl $nD 'evento' 'eventi') di diagnostica avanzata (StorDiag): contano solo gli errori di lettura o scrittura del disco di sistema, già inclusi sopra." "There $(Pl $nD 'is' 'are') also $nD advanced diagnostic $(Pl $nD 'event' 'events') (StorDiag): only read or write failures of the system disk count, and they are already included above.") + '*'); M '' }
    Note '"usura" indica quanta vita del disco è stata consumata (0% = nuovo). Un disco può risultare integro e avere comunque problemi di collegamento: in quel caso lo mostrano gli arresti anomali.' '"wear" shows how much of the disk''s life has been used (0% = new). A disk can report healthy and still have connection problems: the crashes section would show it.'

    M ('## 5. ' + (T 'Memoria RAM' 'Memory (RAM)'))
    M ''
    if (@($R.RamModules).Count) { Tab @((T 'Slot' 'Slot'), 'GB', 'MHz', (T 'Produttore' 'Manufacturer'), (T 'Codice' 'Part number')) @($R.RamModules | ForEach-Object { ,@($_.Slot, (N $_.GB), $_.MHz, $_.Manufacturer, $_.PartNumber) }) }
    $rf = ND; if ($R.RamFreePct -ne $null) { $rf = "$($R.RamFreePct)%" }
    M ((T 'RAM libera al momento del controllo' 'Free RAM at check time') + ": **$rf** · " + (T 'Errori di memoria segnalati dall''hardware' 'Hardware memory errors') + ': **' + @($R.WheaMem).Count + '** · ' + (T 'Test della memoria di Windows' 'Windows memory tests') + ': **' + $mt.Count + '**' + $(if ($mt.Count) { ' (' + (T 'ultimo esito' 'last result') + ': ' + $(if ($memFail) { T 'ERRORI' 'ERRORS' } else { T 'nessun errore' 'no errors' }) + ')' } else { '' }) + ' · ' + (T 'Episodi di memoria esaurita' 'Low-memory events') + ': **' + @($R.LowMemory).Count + '**')
    M ''

    M ('## 6. ' + (T 'Arresti anomali e riavvii improvvisi' 'Crashes and unexpected restarts'))
    M ''
    if ($nCrash -eq 0) { M ((T "Nessun arresto anomalo $PeriodIt." "No crashes $PeriodEn.") + ' 🟢'); M '' }
    else {
        M (T "Windows ha registrato **$nCrash $(Pl $nCrash 'arresto anomalo' 'arresti anomali')** $PeriodIt." "Windows recorded **$nCrash $(Pl $nCrash 'crash' 'crashes')** $PeriodEn.")
        M ''
        Tab @((T 'Data e ora' 'Date and time'), (T 'Tipo di errore' 'Error type'), (T 'Cosa significa' 'What it means'), (T 'Quando' 'When')) @($R.Crashes | Select-Object -First 20 | ForEach-Object {
            $when = T 'non determinabile' 'cannot be determined'
            if ($_.InSleep) { $when = T 'durante la sospensione o il risveglio' 'while going to sleep or waking up' }
            elseif ($_.MinAfterPowerUp -ne $null) {
                if ($_.AtBoot) { $when = T "subito dopo l'accensione o il risveglio" 'right after startup or wake-up' } else { $when = T "durante l'uso" 'during use' }
                if ($_.AliveFromLog) { $when += ' (' + (T 'almeno' 'at least') + ' ' + (N $_.MinAfterPowerUp) + ' min)' } else { $when += ' (' + (N $_.MinAfterPowerUp) + ' min)' }
            }
            $nameText = T $_.NameIt $_.NameEn; if ($_.Code -ne 0 -and $nameText -notmatch '0x') { $nameText += " ($($_.Hex))" }
            ,@((D $_.Date -Time), $nameText, (T $_.It $_.En), $when) })
        if ($nCrash -gt 20) { M ('*' + (T "Mostrati i 20 più recenti su $nCrash; elenco completo in data\crashes.csv." "Showing the 20 most recent of $nCrash; full list in data\crashes.csv.") + '*'); M '' }
        if (@($R.Crashes | Where-Object { -not $_.LastAlive -or $_.AliveFromLog }).Count) { M ('*' + (T "Quando l'orario esatto dell'arresto non è registrato, viene indicato quello del riavvio successivo." 'When the exact crash time is not recorded, the time of the following restart is shown.') + '*'); M '' }
        M ('**' + (T 'Riepilogo per causa' 'By cause') + ':** ' + (($R.Crashes | Group-Object Cat | Sort-Object Count -Descending | ForEach-Object { "$(CatName $_.Name): $($_.Count)" }) -join ' · '))
        M ''
        if ($crashTimed -gt 0) {
            M (T "Per $crashTimed $(Pl $crashTimed 'arresto' 'arresti') su $nCrash è noto quando è avvenuto rispetto all'ultima accensione o all'ultimo risveglio: **$crashBoot** entro 5 minuti oppure durante la sospensione." "For $crashTimed of $nCrash crashes it is known when they happened relative to the last startup or wake-up: **$crashBoot** within 5 minutes or while going to sleep.")
            if ($crashTimed -ge 2 -and $crashBoot -ge [math]::Ceiling($crashTimed / 2)) { M (T 'Il problema si presenta quindi soprattutto quando i componenti si riaccendono, non sotto sforzo.' 'So the problem mostly appears when components power up, not under load.') }
            M ''
        }
        $dumpText = (T 'File dei crash salvati da Windows' 'Crash files saved by Windows') + ': **' + @($R.Minidump).Count + '** minidump, **' + @($R.LiveDump).Count + '** ' + (T 'report di blocco parziale' 'live kernel reports') + '.'
        if (@($R.Minidump).Count -eq 0 -and $crashBsod -gt 0) {
            if (@($R.DumpFailed).Count) { $dumpText += ' ' + (T "Windows ha registrato $(@($R.DumpFailed).Count) $(Pl @($R.DumpFailed).Count 'tentativo fallito' 'tentativi falliti') di salvare il crash: al momento del blocco il disco probabilmente non rispondeva." "Windows logged $(@($R.DumpFailed).Count) failed $(Pl @($R.DumpFailed).Count 'attempt' 'attempts') to save the crash: the disk was probably not responding at that moment.") }
            elseif (@($R.DumpInitFailed).Count) { $dumpText += ' ' + (T 'All''avvio Windows non è riuscito a preparare il salvataggio dei crash (evento volmgr 45/46): controllare il file di paging e le impostazioni di Avvio e ripristino.' 'At startup Windows could not prepare crash dump saving (volmgr event 45/46): check the paging file and the Startup and Recovery settings.') }
            elseif ($R.DumpsEnabled -eq $false) { $dumpText += ' ' + (T 'Il salvataggio dei crash è disattivato nelle impostazioni di Windows.' 'Saving crash dumps is disabled in the Windows settings.') }
            else { $dumpText += ' ' + (T 'Il motivo per cui mancano i file dei crash non è determinabile.' 'Why the crash files are missing cannot be determined.') }
        }
        M $dumpText
        M ''
    }

    M ('## 7. ' + (T 'Programmi, servizi e dispositivi' 'Programs, services and devices'))
    M ''
    $tasksText = ND; if ($null -ne $R.FailedTasks) { $tasksText = @($R.FailedTasks).Count }
    M ((T 'Chiusure inattese di programmi' 'Unexpected program closures') + ': **' + @($R.AppCrashes).Count + '** · ' + (T 'Errori di servizi' 'Service errors') + ': **' + @($R.SvcErrors).Count + '** (' + (T 'chiusure inattese' 'unexpected stops') + ': **' + @($R.SvcCrashes).Count + '**) · ' + (T 'Servizi automatici fermi' 'Stopped automatic services') + ': **' + @($R.StoppedServices).Count + '** · ' + (T 'Attività pianificate non riuscite' 'Failed scheduled tasks') + ": **$tasksText**")
    M ''
    M ((T 'Dispositivi con errori' 'Devices with errors') + ': **' + @($R.BadDevices).Count + '** · ' + (T 'disattivati volutamente' 'disabled on purpose') + ': **' + @($R.DisabledDevices).Count + '** · ' + (T 'non presenti o senza driver (esito incerto)' 'not present or missing drivers (uncertain)') + ': **' + @($R.UnclearDevices).Count + '** · ' + (T 'Blocchi della scheda video' 'Graphics timeouts') + ': **' + [Math]::Max(@($R.Tdr).Count, @($R.GpuWatchdog).Count) + '**')
    M ''
    if (@($R.AppTop).Count) { M (T 'Programmi che si sono bloccati più spesso:' 'Programs that crashed most often:'); M ''; Tab @((T 'Volte' 'Times'), (T 'Programma' 'Program')) @($R.AppTop | ForEach-Object { ,@($_.Count, $_.Name) }) }
    Note 'alcuni servizi impostati su "automatico" partono solo quando servono, quindi risultare fermi è spesso normale. Gli elenchi completi sono nella cartella `data`.' 'some services set to "automatic" only start when needed, so being stopped is often normal. Full lists are in the `data` folder.'

    M ('## 8. ' + (T 'Alimentazione e batteria' 'Power and battery'))
    M ''
    if ($R.BatteryPresent) {
        $bd = ND; if ($R.BatteryDesign) { $bd = "$($R.BatteryDesign) mWh" }
        $bf = ND; if ($R.BatteryFull) { $bf = "$($R.BatteryFull) mWh" }
        $bhh = ND; if ($R.BatteryHealth -ne $null) { $bhh = "$($R.BatteryHealth)%" }
        $acText = T 'alimentatore collegato' 'charger connected'; if (-not $R.OnAC) { $acText = T 'a batteria' 'on battery' }
        Tab @((T 'Voce' 'Item'), (T 'Valore' 'Value')) @(
            ,@((T 'Carica attuale' 'Current charge'), "$($R.BatteryCharge)% ($acText)")
            ,@((T 'Capacità di progetto' 'Design capacity'), $bd)
            ,@((T 'Capacità attuale' 'Current full capacity'), $bf)
            ,@((T 'Salute' 'Health'), $bhh) )
    } else { M (T 'Nessuna batteria rilevata (probabile PC fisso).' 'No battery detected (probably a desktop PC).'); M '' }
    $fs = ND; if ($R.FastStartup -eq 1) { $fs = T 'attivo' 'on' } elseif ($R.FastStartup -eq 0) { $fs = T 'disattivato' 'off' }
    M ((T 'Passaggi tra corrente e batteria' 'Switches between mains and battery') + ': **' + @($R.Power).Count + '** · ' + (T 'Avvio rapido di Windows' 'Windows Fast Startup') + ": **$fs**")
    M ''
    if (@($R.PowerBeforeCrash).Count) {
        $nP = @($R.PowerBeforeCrash).Count; M ('⚠️ ' + (T "In **$nP** $(Pl $nP 'caso' 'casi') il computer ha perso la corrente nei 10 minuti prima di un arresto anomalo:" "In **$nP** $(Pl $nP 'case' 'cases') the computer lost mains power within 10 minutes before a crash:"))
        M ''
        foreach ($a in $R.PowerBeforeCrash) { M ('- ' + (D $a.Crash -Time) + ': ' + (T 'corrente assente alle' 'no mains power at') + " $($a.Times)") }
        M ''
    } elseif (@($R.Power).Count -and $crashTimed -gt 0) { M (T "Nessuno di questi passaggi precede un arresto anomalo: l'alimentatore non risulta la causa diretta dei blocchi." 'None of these switches precedes a crash: the charger does not appear to be the direct cause.'); M '' }

    M ('## 9. ' + (T 'Prestazioni e temperature' 'Performance and temperatures'))
    M ''
    $sm = T " con il computer nell'uso normale." ' during normal use.'; if ($Stress) { $sm = T ' **con il processore sotto sforzo**.' ' **with the processor under full load**.' }
    M ((T "Misurazione di $SampleSeconds secondi" "$SampleSeconds-second measurement") + $sm)
    M ''
    $lbl = @{ cpu_limit = @('CPU: limite imposto dal BIOS (%)','CPU: limit set by the BIOS (%)'); cpu_perf = @('CPU: prestazioni (%)','CPU: performance (%)'); cpu_freq = @('CPU: frequenza (MHz)','CPU: frequency (MHz)')
              cpu_use = @('CPU: utilizzo (%)','CPU: usage (%)'); ram_use = @('RAM in uso (%)','RAM in use (%)'); disk_busy = @('Disco occupato (%)','Disk busy (%)') }
    $rows = @()
    foreach ($k in 'cpu_limit','cpu_perf','cpu_freq','cpu_use','ram_use','disk_busy') { $s = @($R.Samples | Where-Object { $_.Key -eq $k }); if ($s.Count) { $rows += ,@((T $lbl[$k][0] $lbl[$k][1]), (N $s[0].Min), (N $s[0].Avg), (N $s[0].Max)) } }
    if ($zt.Count) { $rows += ,@((T "Temperature interne ($($zt.Count) $(Pl $zt.Count 'sensore' 'sensori'), °C)" "Internal temperatures ($($zt.Count) $(Pl $zt.Count 'sensor' 'sensors'), °C)"), '-', (N ($zt | Measure-Object Avg -Average).Average), (N $tMax)) }
    if ($rows.Count) { $rows += ,@((T 'Sensori che segnalano rallentamento per calore' 'Sensors reporting heat throttling'), '-', '-', $thrN); Tab @((T 'Misura' 'Measure'), (T 'Minimo' 'Min'), (T 'Media' 'Average'), (T 'Massimo' 'Max')) $rows }
    if (@($R.TopRam).Count) { M (T 'Programmi che usano più memoria in questo momento:' 'Programs using the most memory right now:'); M ''; Tab @((T 'Programma' 'Program'), 'MB') @($R.TopRam | ForEach-Object { ,@($_.Name, $_.MB) }) }
    M ((T 'Segnalazioni di processore rallentato dal BIOS' 'BIOS processor-throttling reports') + ': **' + @($R.Throttle37).Count + '** · ' + (T 'Eventi termici' 'Thermal events') + ': **' + @($R.Thermal).Count + '** · ' + (T 'Errori ACPI del BIOS' 'BIOS ACPI errors') + ': **' + @($R.AcpiErrors).Count + '** · ' + (T 'Errori hardware (WHEA) non corretti / corretti' 'Hardware errors (WHEA) uncorrected / corrected') + ': **' + @($R.Whea).Count + ' / ' + @($R.WheaCorrected).Count + '**')
    M ''
    Note 'il limite imposto dal BIOS al 100% significa che il processore può lavorare alla massima velocità. Valori più bassi indicano che il BIOS lo sta rallentando, di solito per alimentazione o raffreddamento. Gli errori ACPI del BIOS sono spesso innocui, ma se sono molti conviene aggiornare il BIOS.' 'a BIOS limit of 100% means the processor can run at full speed. Lower values mean the BIOS is slowing it down, usually because of power or cooling. BIOS ACPI errors are often harmless, but if there are many, a BIOS update is worth checking.'

    M ('## 10. ' + (T 'Rete' 'Network'))
    M ''
    if (@($R.NetConfig).Count) { Tab @((T 'Scheda' 'Adapter'), 'IP', 'Gateway', 'DNS') @($R.NetConfig | ForEach-Object { ,@($_.Adapter, $_.IP, $_.Gateway, $_.DNS) }) }
    if (-not $SkipNetwork) {
        M ((T 'Router raggiungibile (ping)' 'Router reachable (ping)') + ': **' + (YesNo $R.PingGateway) + '** · ' + (T 'Internet (ping)' 'Internet (ping)') + ': **' + (YesNo $R.PingInternet) + '** · ' + (T 'Internet (connessione HTTPS)' 'Internet (HTTPS connection)') + ': **' + (YesNo $R.Tcp) + '** · ' + (T 'Risoluzione dei nomi (DNS)' 'Name resolution (DNS)') + ': **' + (YesNo $R.Dns) + '** · Proxy: **' + (YesNo $R.Proxy) + '**')
        M ''
        Note 'alcune reti aziendali bloccano il ping: per questo si prova anche una connessione HTTPS. Se solo il ping fallisce, la connessione funziona.' 'some company networks block ping, so an HTTPS connection is tried as well. If only ping fails, the connection works.'
    }
    M ((T 'Errori di rete nei registri (Wi-Fi, TCP/IP, DNS, DHCP)' 'Network errors in the logs (Wi-Fi, TCP/IP, DNS, DHCP)') + ': **' + @($R.NetErrors).Count + '**')
    M ''

    M ('## 11. ' + (T 'Sicurezza' 'Security'))
    M ''
    if (@($R.Antivirus).Count) { Tab @('Antivirus', (T 'Protezione attiva' 'Protection on'), (T 'Definizioni aggiornate' 'Definitions up to date')) @($R.Antivirus | ForEach-Object { ,@($_.Name, (YesNo $_.On), (YesNo $_.UpToDate)) }) }
    if ($R.Defender) {
        $rt = T 'DISATTIVATA' 'OFF'; if ($R.Defender.RealTime) { $rt = T 'attiva' 'on' }
        $srows = @(,@((T 'Microsoft Defender: protezione in tempo reale' 'Microsoft Defender: real-time protection'), $rt))
        if ($R.Defender.SigDate) { $srows += ,@((T 'Definizioni aggiornate il' 'Definitions updated on'), (D $R.Defender.SigDate)) }
        if ($R.Defender.QuickScan) { $srows += ,@((T 'Ultima scansione rapida' 'Last quick scan'), (D $R.Defender.QuickScan)) }
        Tab @((T 'Voce' 'Item'), (T 'Valore' 'Value')) $srows
    }
    $fwOther = ''; if (@($R.ThirdPartyFw).Count) { $fwOther = ' · ' + (T 'altro firewall attivo' 'other active firewall') + ': **' + ($R.ThirdPartyFw -join ', ') + '**' }
    M ((T 'Firewall di Windows' 'Windows firewall') + ': ' + (($R.Firewall | ForEach-Object { $fw = T 'DISATTIVATO' 'OFF'; if ($_.Enabled) { $fw = T 'attivo' 'on' }; "$(Tr $_.Name) = $fw" }) -join ' · ') + $fwOther)
    M ''
    if ($R.BitLocker) { M ('BitLocker: ' + (($R.BitLocker | ForEach-Object { "$($_.MountPoint) $(Tr $_.VolumeStatus)" }) -join ' · ')); M '' }
    $tpmText = T 'non presente o non leggibile' 'not present or not readable'
    if ($R.Tpm) { $tpmText = (T 'presente' 'present') + " ($($R.Tpm.Version)), " + (T 'pronto' 'ready') + ': ' + (YesNo $R.Tpm.Ready) }
    M ("TPM: $tpmText · " + (T 'Riavvio in sospeso per aggiornamenti' 'Restart pending for updates') + ': **' + (YesNo $R.RebootPending) + '**')
    M ''
    if ($R.FailedLogons -gt 0) {
        $flN = "$($R.FailedLogons)"; if ($R.FailedLogonsCapped) { $flN = (T 'almeno ' 'at least ') + $flN }
        M ((T "Tentativi di accesso non riusciti $SecPerIt" "Failed sign-in attempts $SecPerEn") + ": **$flN**")
        M ''
        $types = @{ '2' = @('dalla tastiera (password o PIN errato)','at the keyboard (wrong password or PIN)'); '3' = @('dalla rete (cartelle condivise, altri dispositivi)','from the network (shared folders, other devices)')
                    '4' = @('attività pianificate','scheduled tasks'); '5' = @('servizi','services'); '7' = @('sblocco dello schermo','screen unlock'); '8' = @('rete con password in chiaro','network with clear-text password')
                    '10' = @('desktop remoto','remote desktop'); '11' = @('credenziali salvate','cached credentials') }
        Tab @((T 'Tipo' 'Type'), (T 'Numero' 'Count')) @($R.FailedLogonTypes | ForEach-Object { $nn = $types[[string]$_.Type]; $lab = (T 'tipo' 'type') + " $($_.Type)"; if ($nn) { $lab = T $nn[0] $nn[1] }; ,@($lab, $_.Count) })
        Note 'gli errori "dalla tastiera" o allo "sblocco dello schermo" sono di solito password o PIN digitati male. Quelli dei "servizi" indicano di solito un programma o servizio configurato con una password non più valida. Quelli "dalla rete" o "desktop remoto" vanno verificati se sono molti: possono essere dispositivi con una password vecchia salvata oppure tentativi non autorizzati.' '"keyboard" or "screen unlock" failures are usually mistyped passwords or PINs. "Services" failures usually mean a program or service is set up with a password that is no longer valid. "Network" or "remote desktop" failures should be checked if there are many: they may be devices with an old saved password or unauthorized attempts.'
    } else { M (T 'Nessun tentativo di accesso non riuscito (o registro di sicurezza non leggibile).' 'No failed sign-in attempts (or security log not readable).'); M '' }

    M ('## 12. ' + (T 'Aggiornamenti e software' 'Updates and software'))
    M ''
    if (@($R.UpdatesOk).Count) { Tab @((T 'Data' 'Date'), (T 'Aggiornamento di Windows installato' 'Installed Windows update')) @($R.UpdatesOk | Select-Object -First 10 | ForEach-Object { ,@((D $_.TimeCreated -Time), (((($_.Message -split "`n")[0]) -replace '^.*?(aggiornamento|update):\s*', '').Trim())) }) }
    else { M (T "Nessun aggiornamento di Windows installato $PeriodIt." "No Windows updates installed $PeriodEn."); M '' }
    $nA = @($R.UpdatesFailedApps).Count; $appUpd = ''; if ($nA) { $appUpd = ' ' + (T "Inoltre $nA $(Pl $nA 'aggiornamento di app o di antivirus non è riuscito' 'aggiornamenti di app o di antivirus non sono riusciti'): di solito si risolvono da soli." "Also $nA app or antivirus $(Pl $nA 'update' 'updates') failed: they usually fix themselves.") }
    M ((T 'Aggiornamenti di Windows non riusciti e non ancora installati' 'Windows updates that failed and are still missing') + ': **' + @($R.UpdatesFailed).Count + '**.' + $appUpd)
    M ''
    if (@($R.RecentSoftware).Count) {
        M (T 'Programmi installati di recente:' 'Recently installed programs:'); M ''
        Tab @((T 'Programma' 'Program'), (T 'Versione' 'Version'), (T 'Installato il' 'Installed on')) @($R.RecentSoftware | ForEach-Object {
            $idt = "$($_.InstallDate)"; $dt = [datetime]::MinValue; $shown = $idt
            if ([datetime]::TryParseExact($idt, 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dt)) { $shown = D $dt }
            ,@($_.DisplayName, $_.DisplayVersion, $shown) })
    }
    M ((T 'Programmi che si avviano con Windows' 'Programs that start with Windows') + ': **' + @($R.Startup).Count + '** (' + (T 'elenco in' 'list in') + ' `data\startup_programs.csv`).')
    M ''

    M ('## 13. ' + (T 'Limiti di questa analisi' 'Limits of this analysis'))
    M ''
    M ('- ' + (T 'I controlli sono automatici e si basano sui registri di Windows: indicano dove cercare, non sostituiscono la verifica fisica del computer.' 'The checks are automatic and based on Windows logs: they show where to look but do not replace a physical inspection.'))
    M ('- ' + (T "Ventola, fissaggio dei componenti e test hardware del produttore richiedono l'intervento in presenza." 'Fan, component seating and manufacturer hardware tests require on-site work.'))
    M ('- ' + (T 'Un esito 🔵 **Incerto** indica che i dati raccolti non permettono un giudizio sicuro: il dettaglio spiega perché e cosa verificare. Un esito ⚪ **Non valutabile** indica che il dato non è disponibile su questo computer.' 'A 🔵 **Uncertain** result means the data collected does not allow a reliable judgement: the details explain why and what to check. A ⚪ **Not assessed** result means the data is not available on this computer.'))
    if (-not $Stress) { M ('- ' + (T 'Il computer non è stato messo sotto sforzo: le temperature rilevate sono poco indicative (analisi "Stress" per un test completo).' 'The computer was not put under load: the temperatures measured have limited significance (use the "Stress" analysis for a full test).')) }
    if (-not $DeepScan) { M ('- ' + (T 'Non sono stati eseguiti i controlli approfonditi di file di sistema e file system (analisi "DeepScan").' 'The in-depth system file and file system checks were not run (use the "DeepScan" analysis).')) }
    if ($PeriodIt -notmatch 'ultimi') { M ('- ' + (T "Il registro eventi di Windows copre solo il periodo $PeriodIt`: gli eventi più vecchi non sono disponibili." "The Windows event log only covers the period $PeriodEn`: older events are not available.")) }
    if ($NotAvailable.Count) { M ('- ' + (T 'Controlli non disponibili su questo sistema:' 'Checks not available on this system:') + ' ' + (($NotAvailable | ForEach-Object { T $_.It $_.En }) -join '; ') + '.') }
    M ''
    M '---'
    M ('*' + (T 'Dati completi nella cartella `data`. Log di esecuzione in `run_log.txt`.' 'Full data in the `data` folder. Run log in `run_log.txt`.') + '*')
    return ,$L
}

function Convert-MdToHtml($lines, [string]$lng) {
    function Inline([string]$t) {
        $t = [System.Security.SecurityElement]::Escape($t)
        $t = [regex]::Replace($t, '\*\*(.+?)\*\*', '<strong>$1</strong>')
        $t = [regex]::Replace($t, '(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', '<em>$1</em>')
        return [regex]::Replace($t, '`(.+?)`', '<code>$1</code>')
    }
    $title = 'PC Diagnosis'; $h1 = @($lines | Where-Object { $_ -like '# *' }); if ($h1.Count) { $title = $h1[0].Substring(2) }
    $H = New-Object 'System.Collections.Generic.List[string]'
    $H.Add("<!DOCTYPE html><html lang=`"$lng`"><head><meta charset=`"utf-8`"><meta name=`"viewport`" content=`"width=device-width, initial-scale=1`">")
    $H.Add('<title>' + [System.Security.SecurityElement]::Escape($title) + '</title><style>')
    $H.Add('body{font-family:"Segoe UI",Arial,sans-serif;max-width:1000px;margin:24px auto;padding:0 16px;color:#1f2933;line-height:1.5;background:#fff}')
    $H.Add('h1{color:#1f4e79;border-bottom:3px solid #1f4e79;padding-bottom:6px}h2{color:#1f4e79;margin-top:32px;border-bottom:1px solid #d0d7de;padding-bottom:4px}')
    $H.Add('table{border-collapse:collapse;width:100%;margin:10px 0 16px;font-size:14px}th{background:#1f4e79;color:#fff;text-align:left}')
    $H.Add('th,td{border:1px solid #d0d7de;padding:6px 8px;vertical-align:top}tr:nth-child(even) td{background:#f6f8fa}')
    $H.Add('.summary td:nth-child(2){white-space:nowrap}.summary td:first-child{font-weight:600;white-space:nowrap}')
    $H.Add('blockquote{margin:12px 0;padding:8px 14px;background:#f0f6fc;border-left:4px solid #1f4e79}code{background:#eef1f4;padding:1px 4px;border-radius:3px}')
    $H.Add('@media print{body{margin:0;max-width:none}h2{page-break-after:avoid}}</style></head><body>')
    $inTable = $false; $inList = $false; $first = $true
    foreach ($line in $lines) {
        $isRow = $line.StartsWith('|'); $isItem = $line.StartsWith('- ')
        if (-not $isRow -and $inTable) { $H.Add('</tbody></table>'); $inTable = $false }
        if (-not $isItem -and $inList) { $H.Add('</ul>'); $inList = $false }
        if ($isRow) {
            if ($line -match '^\|(\s*-+\s*\|)+\s*$') { continue }
            $cells = @($line.Trim().Trim('|') -split '\|' | ForEach-Object { Inline $_.Trim() })
            if (-not $inTable) {
                $cls = ''; if ($first) { $cls = ' class="summary"' }; $first = $false
                $H.Add("<table$cls><thead><tr>" + (($cells | ForEach-Object { "<th>$_</th>" }) -join '') + '</tr></thead><tbody>'); $inTable = $true; continue
            }
            $H.Add('<tr>' + (($cells | ForEach-Object { "<td>$_</td>" }) -join '') + '</tr>'); continue
        }
        if ($isItem) { if (-not $inList) { $H.Add('<ul>'); $inList = $true }; $H.Add('<li>' + (Inline $line.Substring(2)) + '</li>'); continue }
        if ($line -match '^# (.*)')  { $H.Add('<h1>' + (Inline $matches[1]) + '</h1>'); continue }
        if ($line -match '^## (.*)') { $H.Add('<h2>' + (Inline $matches[1]) + '</h2>'); continue }
        if ($line -eq '---') { $H.Add('<hr>'); continue }
        if ($line -match '^> ?(.*)') { $H.Add('<blockquote>' + (Inline $matches[1]) + '</blockquote>'); continue }
        if ($line.Trim()) { $H.Add('<p>' + (Inline $line) + '</p>') }
    }
    if ($inTable) { $H.Add('</tbody></table>') }
    if ($inList) { $H.Add('</ul>') }
    $H.Add('</body></html>')
    return ,$H
}

function New-Zip([string]$src, [string]$zip) {
    # Compress-Archive on PowerShell 5+, Windows Shell zip folder on older systems
    if (Has 'Compress-Archive') {
        try { Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force -ErrorAction Stop; return }
        catch { Log "   Compress-Archive failed ($($_.Exception.Message)), using the Windows zip folder"; Remove-Item $zip -ErrorAction SilentlyContinue }
    }
    [IO.File]::WriteAllBytes($zip, [byte[]](@(80, 75, 5, 6) + (@(0) * 18)))
    $shell = New-Object -ComObject Shell.Application
    $target = $shell.NameSpace($zip)
    $n = 0
    foreach ($it in @(Get-ChildItem $src)) {
        $n++
        $target.CopyHere($it.FullName, 0x14)
        $limit = (Get-Date).AddMinutes(5)
        while ($target.Items().Count -lt $n -and (Get-Date) -lt $limit) { Start-Sleep -Milliseconds 300 }
    }
    # the item count rises before a large folder is fully written: wait until the zip is closed and its size is stable
    $limit = (Get-Date).AddMinutes(10); $last = -1
    while ((Get-Date) -lt $limit) {
        Start-Sleep -Seconds 1
        $free = $false
        try { $fs = [IO.File]::Open($zip, 'Open', 'Read', 'None'); $fs.Close(); $free = $true } catch { }
        $size = (Get-Item -LiteralPath $zip).Length
        if ($free -and $size -eq $last) { break }
        $last = $size
    }
}

Step 'Writing reports (Italian and English)' {
    foreach ($lng in 'it', 'en') {
        $up = $lng.ToUpper()
        try {
            $mdLines = Build-Report $lng
            ($mdLines -join "`r`n") | Out-File -FilePath (Join-Path $out "REPORT_$up.md") -Encoding UTF8
            ((Convert-MdToHtml $mdLines $lng) -join "`r`n") | Out-File -FilePath (Join-Path $out "REPORT_$up.html") -Encoding UTF8
        } catch {
            Log "   ERROR building the $up report (line $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
            # minimal fallback: at least the verdict table
            $fb = @("# PC Diagnosis - $($env:COMPUTERNAME)", '', '| Area | Result | Details |', '|---|---|---|')
            foreach ($v in $Verdicts) { if ($lng -eq 'it') { $fb += "| $($v.It) | $($v.State) | $($v.DetIt) |" } else { $fb += "| $($v.En) | $($v.State) | $($v.DetEn) |" } }
            ($fb -join "`r`n") | Out-File -FilePath (Join-Path $out "REPORT_$up.md") -Encoding UTF8
        }
    }
}

Step 'Creating the ZIP archive' {
    # the archive is built in TEMP and COPIED (not moved), so it inherits the Desktop permissions of the signed-in user
    $tmpZip = Join-Path $env:TEMP "$runName.zip"
    Remove-Item $tmpZip -ErrorAction SilentlyContinue
    New-Zip $out $tmpZip
    Copy-Item $tmpZip (Join-Path $out "$runName.zip") -Force
    Remove-Item $tmpZip -ErrorAction SilentlyContinue
}

# ============================== CONSOLE SUMMARY ==============================
Set-KeepAwake $false
Write-Host ''
Write-Host '  ==================== RESULT ====================' -ForegroundColor Cyan
foreach ($v in $Verdicts) {
    $c = 'Gray'; $s = 'N/A     '
    if ($v.State -eq 'OK') { $c = 'Green'; $s = 'OK      ' } elseif ($v.State -eq 'WARN') { $c = 'Yellow'; $s = 'CHECK   ' } elseif ($v.State -eq 'BAD') { $c = 'Red'; $s = 'PROBLEM ' } elseif ($v.State -eq 'UNSURE') { $c = 'Cyan'; $s = 'UNSURE  ' }
    Write-Host ('  [' + $s + '] ') -ForegroundColor $c -NoNewline
    Write-Host ('{0,-30} {1}' -f $v.En, $v.DetEn)
}
Write-Host ''
Write-Host "  Results folder: $out" -ForegroundColor Green
Write-Host '  Open REPORT_EN.html or REPORT_IT.html (double-click) to read the report.' -ForegroundColor Gray
Log 'Done.'
Set-QuickEdit $true
if (-not $unattended -and $interactive) {
    try { Start-Process explorer.exe -ArgumentList "`"$out`"" } catch { }
    Write-Host ''; Write-Host '  Press any key to exit...' -ForegroundColor DarkGray; Wait-Key
}
