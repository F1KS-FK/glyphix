# Glyphix installer.  Usage (Windows PowerShell 5.1):
#   irm https://raw.githubusercontent.com/F1KS-FK/glyphix/main/install.ps1 | iex
# ASCII-only on purpose: works with irm | iex (no BOM / encoding problems).
# The whole body runs in its own scope (& { ... }): nothing leaks into the user's global scope under irm | iex.

& {
    $ErrorActionPreference = 'Stop'      # local to this scope: the caller's preference is untouched
    # BEGIN-HELPERS (the swap / process helpers below are loaded by work/build/test_engine.ps1 - keep them self-contained)
    function Get-NormPath {
        param([string]$Path)
        $f = [IO.Path]::GetFullPath($Path)
        $r = [IO.Path]::GetPathRoot($f)
        if ($f.Length -gt $r.Length) { $f = $f.TrimEnd([char]92, [char]47) }
        return $f
    }
    # $Path strictly inside $Dir (full paths, case-insensitive)
    function Test-InsidePath {
        param([string]$Path, [string]$Dir)
        $d = (Get-NormPath $Dir).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
        return (Get-NormPath $Path).StartsWith($d, [StringComparison]::OrdinalIgnoreCase)
    }
    # IOException / UnauthorizedAccessException, also when PowerShell wrapped it (MethodInvocationException)
    function Test-TransientIoError {
        param($Ex)
        for ($e = $Ex; $e; $e = $e.InnerException) {
            if ($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) { return $true }
        }
        return $false
    }
    # move a directory; a busy folder (antivirus, indexer) is retried for up to $TimeoutMs
    function Invoke-MoveRetry {
        param([scriptblock]$Mover, [string]$From, [string]$To, [int]$TimeoutMs = 3000)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try { & $Mover $From $To; return }
            catch {
                if (-not (Test-TransientIoError $_.Exception) -or $sw.ElapsedMilliseconds -ge $TimeoutMs) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    # Replace the folder $Cur with the fully prepared folder $New:  Cur -> Old, New -> Cur, delete Old.
    # The previous version is never deleted before the new one is in place; any failure rolls Old back to Cur.
    function Invoke-DirSwap {
        param(
            [string]$Cur, [string]$New, [string]$Old,
            [scriptblock]$Mover = { param($a, $b) [IO.Directory]::Move($a, $b) },
            [int]$TimeoutMs = 3000
        )
        $root = Split-Path -Parent (Get-NormPath $Cur)
        foreach ($d in @($New, $Old)) {
            if (-not (Test-InsidePath $d $root) -or ((Split-Path -Parent (Get-NormPath $d)) -ine $root)) { throw "refusing to swap: $d is not next to $Cur" }
        }
        if (-not (Test-Path -LiteralPath $New -PathType Container)) { throw "prepared folder is missing: $New" }
        if (Test-Path -LiteralPath $Old) { Remove-Item -LiteralPath $Old -Recurse -Force }      # leftover of an earlier run (Old sits next to Cur, checked above)
        $movedOld = $false
        try {
            if (Test-Path -LiteralPath $Cur) { Invoke-MoveRetry $Mover $Cur $Old $TimeoutMs; $movedOld = $true }
            Invoke-MoveRetry $Mover $New $Cur $TimeoutMs
        } catch {
            $err = $_
            if ($movedOld -and -not (Test-Path -LiteralPath $Cur)) {
                try { & $Mover $Old $Cur }
                catch { throw ('install failed (' + $err.Exception.Message + ') and the rollback failed too: the previous version is in ' + $Old + ' - rename it back to ' + (Split-Path -Leaf $Cur)) }
            }
            throw $err
        }
        try { Remove-Item -LiteralPath $Old -Recurse -Force } catch { }      # not fatal: the next run removes it
    }
    # leftovers of an interrupted run: a swap that stopped between the two renames (app is missing, app.old holds the previous version) is rolled back;
    # unfinished app.new / app.old are deleted; *.tmp files older than $MinAgeMinutes are deleted. Returns a list of what was done.
    function Repair-InstallLeftovers {
        param([string]$Root, [string]$Cur, [string]$New, [string]$Old, [int]$MinAgeMinutes = 10)
        $done = New-Object 'System.Collections.Generic.List[string]'
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $done.ToArray() }
        if (-not (Test-Path -LiteralPath $Cur) -and (Test-Path -LiteralPath $Old -PathType Container)) {
            [IO.Directory]::Move($Old, $Cur); $done.Add('restored ' + $Cur + ' from ' + $Old)
        }
        foreach ($d in @($New, $Old)) {
            if ((Test-Path -LiteralPath $d) -and (Test-InsidePath $d $Root)) { Remove-Item -LiteralPath $d -Recurse -Force; $done.Add('removed ' + $d) }
        }
        $limit = (Get-Date).AddMinutes(-$MinAgeMinutes)
        foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force -Filter '*.tmp' -ErrorAction SilentlyContinue)) {
            try { if ($f.LastWriteTime -lt $limit -and $f.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $f.FullName -Force; $done.Add('removed ' + $f.FullName) } } catch { }
        }
        return $done.ToArray()
    }
    # powershell processes whose command line runs Glyphix.ps1 (the GUI or an elevated CLI run), not counting ours
    function Select-GlyphixProcs {
        param($Procs, [int]$SelfPid)
        return @($Procs | Where-Object { $_ -and ([int]$_.ProcessId -ne $SelfPid) -and $_.CommandLine -and ([string]$_.CommandLine -match '(?i)(^|[\\/"''\s])Glyphix\.ps1(["''\s]|$)') })
    }
    function Get-GlyphixProcs {
        $all = @()
        try { $all = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop) }
        catch { try { $all = @(Get-WmiObject -Class Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction Stop) } catch { } }
        return @(Select-GlyphixProcs $all $PID)
    }
    # is the GUI's single-instance mutex (Local\Glyphix.App) alive? The handle is released at once so the mutex is not kept alive by us.
    function Test-GlyphixMutex {
        $m = $null
        try {
            if ([Threading.Mutex]::TryOpenExisting('Local\Glyphix.App', [ref]$m)) { return $true }
            return $false
        } catch {
            for ($e = $_.Exception; $e; $e = $e.InnerException) { if ($e -is [UnauthorizedAccessException]) { return $true } }      # exists, but we may not open it
            return $false
        }
        finally { if ($m) { try { $m.Dispose() } catch { } } }
    }
    # Wait up to $TimeoutSec for Glyphix to exit; ask it politely to close once (CloseMainWindow, never a kill). $true - nothing runs any more.
    function Wait-GlyphixExit {
        param(
            [int]$TimeoutSec = 15,
            [scriptblock]$GetProcs = { Get-GlyphixProcs },
            [scriptblock]$IsMutexHeld = { Test-GlyphixMutex },
            [scriptblock]$Close = { param($procs) foreach ($p in $procs) { try { $pr = [Diagnostics.Process]::GetProcessById([int]$p.ProcessId); [void]$pr.CloseMainWindow(); $pr.Dispose() } catch { } } },
            [int]$SleepMs = 300
        )
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $asked = $false
        while ($true) {
            $procs = @(& $GetProcs)
            $held = [bool](& $IsMutexHeld)
            if ($procs.Count -eq 0 -and -not $held) { return $true }
            if (-not $asked) {
                $asked = $true
                Write-Host '  Glyphix is running - asking it to close...' -ForegroundColor Yellow
                try { & $Close $procs } catch { }
            }
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { return $false }
            Start-Sleep -Milliseconds $SleepMs
        }
    }
    # END-HELPERS

    try {
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
        $siBase = 'https://raw.githubusercontent.com/F1KS-FK/glyphix/main/'
        $siHome = Join-Path $env:LOCALAPPDATA 'Glyphix'
        $siApp = Join-Path $siHome 'app'
        $siNew = Join-Path $siHome 'app.new'
        $siOld = Join-Path $siHome 'app.old'
        # sha256 of every file as committed to the repo. Generated by work/build/gen_install_hashes.py - do not edit by hand;
        # re-run the generator and commit install.ps1 together with any change to app/.
        $siFiles = [ordered]@{
        # BEGIN-HASHES
        'app/Engine.ps1' = 'a2c82dc89132871b9f2c954ca8e5fa6ae9e45349ee6577969b7ed8917aa480ad'
        'app/Glyphix.ps1' = 'e22bc51ded81afe7158aa3f923fabd231ed02d9f1c5f4dafabd2b6ce0655e9ce'
        'app/ShadowIcons.ps1' = '70de09bdba26fb2d51e710f8a3753a476fbdbf38faa873ce8d92957351d335a3'
        'app/MainWindow.xaml' = '2116b4c6d23a20b18701a71e12e041134f7aef4bcfc5c0b2dd2907ab386c98ab'
        'app/launch.vbs' = 'f07159a4489eb71c47d2b9bfa2c4e9939f83c0aaadf364eecbadc9da7685e337'
        'app/version.txt' = '3ffc83cc5ee682541f1eb36b1b7efbe154b2a982df8eaeeb76c5043f07a35c7d'
        'app/assets/app.ico' = '55780e2d17c72795d8f2390d6445e76df320587e83eb6dcc72517bcd954553c2'
        'app/assets/app.png' = 'a9dd1a82e50876dd88bab7343dbe40ea9597b05993672266a6a49acecfecb5a3'
        'app/assets/logo_tile.png' = '0cc3928dba30432041a4dd4e6d7224fddf7e05b0a612499664f72a33e79201e6'
        # END-HASHES
        }

        Write-Host ''
        Write-Host '  GLYPHIX - install' -ForegroundColor Magenta
        Write-Host "  Target: $siApp" -ForegroundColor DarkGray

        $siSha = {
            param([byte[]]$Bytes)
            $s = [Security.Cryptography.SHA256]::Create()
            try { ([BitConverter]::ToString($s.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $s.Dispose() }
        }

        # 1) download EVERYTHING into memory and verify sha256 (one retry per file: GitHub may serve a half-updated tree during a push)
        $siData = @{}
        foreach ($rel in $siFiles.Keys) {
            $want = [string]$siFiles[$rel]
            $ok = $false
            for ($siTry = 1; ($siTry -le 2) -and (-not $ok); $siTry++) {
                $wc = New-Object System.Net.WebClient
                $wc.Headers.Add('Cache-Control', 'no-cache')
                $wc.Headers.Add('User-Agent', 'Glyphix-Installer')
                $bytes = $null
                try { $bytes = $wc.DownloadData($siBase + $rel + '?cb=' + [DateTime]::UtcNow.Ticks) } finally { $wc.Dispose() }
                if ($bytes -and $bytes.Length -gt 0 -and ((& $siSha $bytes) -eq $want)) {
                    $siData[$rel] = $bytes
                    $ok = $true
                } elseif ($siTry -eq 1) {
                    Write-Host "  hash mismatch: $rel - retrying once..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 3
                }
            }
            if (-not $ok) { throw "SHA-256 mismatch for $rel. Nothing was installed. The repository may be updating right now - try again in a minute." }
            Write-Host "  verified $rel" -ForegroundColor DarkGray
        }

        # 2) the running app must not hold the files: wait (up to 15 s) for Glyphix to exit, asking it to close politely
        if (-not (Wait-GlyphixExit -TimeoutSec 15)) {
            throw 'Glyphix is still running. Close its window (or end its powershell.exe process) and run the installer again. Nothing was changed.'
        }

        # 3) leftovers of an interrupted run (half-done swap, stale *.tmp), then write everything into app.new\ and verify it again from disk
        foreach ($note in (Repair-InstallLeftovers -Root $siHome -Cur $siApp -New $siNew -Old $siOld)) { Write-Host "  cleanup: $note" -ForegroundColor DarkGray }
        New-Item -ItemType Directory -Path $siNew -Force | Out-Null
        try {
            foreach ($rel in $siFiles.Keys) {
                if (-not $rel.StartsWith('app/')) { throw "unexpected path in the file table: $rel" }
                $dest = $siNew
                foreach ($seg in $rel.Substring(4).Split('/')) { $dest = Join-Path $dest $seg }
                $dir = Split-Path -Parent $dest
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [IO.File]::WriteAllBytes($dest, $siData[$rel])
                if ((& $siSha ([IO.File]::ReadAllBytes($dest))) -ne [string]$siFiles[$rel]) { throw "file written incorrectly: $rel" }
                Write-Host "  + $rel" -ForegroundColor DarkGray
            }
            Get-ChildItem -LiteralPath $siNew -Recurse -File | ForEach-Object { try { Unblock-File -LiteralPath $_.FullName } catch { } }

            # 4) swap folders: app -> app.old, app.new -> app, delete app.old (rolled back if anything fails)
            Invoke-DirSwap -Cur $siApp -New $siNew -Old $siOld
        } catch {
            if (Test-Path -LiteralPath $siNew) { try { Remove-Item -LiteralPath $siNew -Recurse -Force } catch { } }
            throw
        }

        # remove the old autostart/scheduled task, migrate data of the previous version (%LOCALAPPDATA%\ShadowIcons -> Glyphix),
        # create Start menu + Desktop shortcuts (functions come from Engine.ps1)
        & {
            . (Join-Path $siApp 'Engine.ps1')
            Set-EngineLogHandler { param($m) Write-Host "  $m" -ForegroundColor DarkGray }
            [void](Remove-Legacy)
            # the migration moves the user's backup: only for a normal session (never from an elevated process of another account)
            $siElev = $null
            try { $siElev = Get-ElevationProblem } catch { $siElev = $_.Exception.Message }
            if ($siElev) { Write-Host '  migration skipped: elevated session of another account (run the installer as your normal user)' -ForegroundColor Yellow }
            else { try { [void](Invoke-LegacyMigration) } catch { Write-Host ("  migration skipped: " + $_.Exception.Message) -ForegroundColor Yellow } }
            Install-AppShortcuts
        }

        # 5) start the app exactly once (not when somebody has already started it meanwhile)
        if ((@(Get-GlyphixProcs).Count -gt 0) -or (Test-GlyphixMutex)) {
            Write-Host '  Done. Glyphix is already running - not starting a second copy.' -ForegroundColor Green
        } else {
            Write-Host '  Done. Starting Glyphix...' -ForegroundColor Green
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $siApp 'launch.vbs') + '"') -WorkingDirectory $siApp
        }
    } catch {
        Write-Host ("  Install failed: " + $_.Exception.Message) -ForegroundColor Red
        if ($PSCommandPath) { try { [void](Read-Host '  Press Enter to close') } catch { } }      # run as a file (self-update): keep the window so the error can be read
    } finally {
        # started by the app's self-update (copy in %TEMP%): remove that copy afterwards
        try {
            if ($PSCommandPath -and ([IO.Path]::GetFileName($PSCommandPath) -like 'glyphix_install_*.ps1') -and ([IO.Path]::GetDirectoryName($PSCommandPath) -eq [IO.Path]::GetTempPath().TrimEnd('\'))) {
                Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}
