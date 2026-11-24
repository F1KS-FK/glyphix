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
    # powershell processes whose command line runs Glyphix.ps1 or the old name ShadowIcons.ps1 (the GUI or an elevated CLI run), not counting ours
    function Test-GlyphixCommandLine {
        param([string]$CommandLine)
        if (-not $CommandLine) { return $false }
        return [bool]($CommandLine -match '(?i)(^|[\\/"''\s])(Glyphix|ShadowIcons)\.ps1(["''\s]|$)')
    }
    function Select-GlyphixProcs {
        param($Procs, [int]$SelfPid)
        return @($Procs | Where-Object { $_ -and ([int]$_.ProcessId -ne $SelfPid) -and (Test-GlyphixCommandLine ([string]$_.CommandLine)) })
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
    # Close the running Glyphix: ask politely (CloseMainWindow), wait up to $GraceSec, then Stop-Process what is left (it is our own app).
    # Returns what was done: Closed / Killed / Failed (lists of PIDs), MutexOnly ($true: the mutex is still held but no process of ours is found).
    function Stop-GlyphixRunning {
        param(
            [int]$GraceSec = 8, [int]$KillWaitSec = 3, [int]$SleepMs = 300,
            [scriptblock]$GetProcs = { Get-GlyphixProcs },
            [scriptblock]$IsMutexHeld = { Test-GlyphixMutex },
            [scriptblock]$Close = { param($procs) foreach ($p in $procs) { try { $pr = [Diagnostics.Process]::GetProcessById([int]$p.ProcessId); [void]$pr.CloseMainWindow(); $pr.Dispose() } catch { } } },
            [scriptblock]$Kill = { param($p) Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop }
        )
        $res = [pscustomobject]@{ Closed = @(); Killed = @(); Failed = @(); MutexOnly = $false }
        $first = @(& $GetProcs)
        if ($first.Count -eq 0 -and -not [bool](& $IsMutexHeld)) { return $res }
        Write-Host '  Glyphix is running - asking it to close...' -ForegroundColor Yellow
        if ($first.Count -gt 0) { try { & $Close $first } catch { } }
        $left = $first
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $left = @(& $GetProcs)
            if ($left.Count -eq 0 -and -not [bool](& $IsMutexHeld)) { break }
            if ($sw.Elapsed.TotalSeconds -ge $GraceSec) { break }
            Start-Sleep -Milliseconds $SleepMs
        }
        $leftIds = @($left | ForEach-Object { [int]$_.ProcessId })
        $res.Closed = @($first | ForEach-Object { [int]$_.ProcessId } | Where-Object { $leftIds -notcontains $_ })
        foreach ($id in $res.Closed) { Write-Host ("  closed Glyphix (PID $id)") -ForegroundColor DarkGray }
        if ($left.Count -gt 0) {
            $killed = New-Object 'System.Collections.Generic.List[int]'
            foreach ($p in $left) {
                try { & $Kill $p; $killed.Add([int]$p.ProcessId); Write-Host ("  did not close in $GraceSec s - stopped Glyphix (PID $([int]$p.ProcessId))") -ForegroundColor Yellow } catch { }
            }
            $sw.Restart()
            while ($true) {
                $left = @(& $GetProcs)
                if ($left.Count -eq 0 -and -not [bool](& $IsMutexHeld)) { break }
                if ($sw.Elapsed.TotalSeconds -ge $KillWaitSec) { break }
                Start-Sleep -Milliseconds $SleepMs
            }
            $leftIds = @($left | ForEach-Object { [int]$_.ProcessId })
            $res.Killed = @($killed.ToArray() | Where-Object { $leftIds -notcontains $_ })
            $res.Failed = @($leftIds)
        }
        $res.MutexOnly = ($res.Failed.Count -eq 0 -and $left.Count -eq 0 -and [bool](& $IsMutexHeld))
        return $res
    }
    function Get-FileShaHex {
        param([string]$Path)
        $s = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($s.ComputeHash([IO.File]::ReadAllBytes($Path)))).Replace('-', '').ToLowerInvariant() } finally { $s.Dispose() }
    }
    # Could the folder swap failure ($Ex) be worked around by replacing the files inside app\ one by one?
    # Only a busy folder (IOException / UnauthorizedAccessException) while app\ is still in place and app.new is ready: 'filewise'; everything else: 'abort'.
    function Get-SwapFallbackDecision {
        param($Ex, [bool]$CurExists, [bool]$NewExists)
        if (-not $Ex) { return 'abort' }
        if (-not $CurExists -or -not $NewExists) { return 'abort' }      # app\ missing (rollback failed) or nothing prepared: never improvise
        if (-not (Test-TransientIoError $Ex)) { return 'abort' }
        return 'filewise'
    }
    # one file, atomically: $Src -> $Dest (File.Replace when $Dest exists, else Move); a busy file is retried for up to $TimeoutMs
    function Invoke-FileReplace {
        param(
            [string]$Src, [string]$Dest, [int]$TimeoutMs = 3000,
            [scriptblock]$Replacer = { param($s, $d) if (Test-Path -LiteralPath $d -PathType Leaf) { [IO.File]::Replace($s, $d, [NullString]::Value) } else { [IO.File]::Move($s, $d) } }
        )
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            try { & $Replacer $Src $Dest; return }
            catch {
                if (-not (Test-TransientIoError $_.Exception) -or $sw.ElapsedMilliseconds -ge $TimeoutMs) { throw }
                Start-Sleep -Milliseconds 100
            }
        }
    }
    # copy $From\$rel over $To\$rel for every $Rel (through a temp file next to the target + Invoke-FileReplace)
    function Copy-FilesInto {
        param([string]$From, [string]$To, [string[]]$Rels, [int]$TimeoutMs = 3000, [scriptblock]$Replacer)
        foreach ($rel in $Rels) {
            $src = Join-Path $From $rel
            $dest = Join-Path $To $rel
            $dir = Split-Path -Parent $dest
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $tmp = [string]::Format('{0}.{1}.tmp', $dest, [guid]::NewGuid().ToString('N').Substring(0, 8))
            try {
                Copy-Item -LiteralPath $src -Destination $tmp -Force
                if ($Replacer) { Invoke-FileReplace -Src $tmp -Dest $dest -TimeoutMs $TimeoutMs -Replacer $Replacer } else { Invoke-FileReplace -Src $tmp -Dest $dest -TimeoutMs $TimeoutMs }
            } finally { if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } } }
        }
    }
    function Get-RelFiles {
        param([string]$Dir)
        $d = (Get-NormPath $Dir).TrimEnd([char]92, [char]47) + [IO.Path]::DirectorySeparatorChar
        return @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($d.Length) })
    }
    # Fallback for a locked app\ folder: the previous version is copied to $Old first (the copy needs no rename), then every file of $New is
    # put into $Cur atomically, one by one. $Expected = relative path (with / or \) -> sha256 of the new file. Every file is verified afterwards;
    # if anything is wrong the previous version is restored from $Old and the function throws. app\ is never left half-empty: files are only replaced, not deleted first.
    function Invoke-FileWiseSwap {
        param([string]$Cur, [string]$New, [string]$Old, $Expected, [int]$TimeoutMs = 3000, [scriptblock]$Replacer)
        $root = Split-Path -Parent (Get-NormPath $Cur)
        foreach ($d in @($New, $Old)) {
            if (-not (Test-InsidePath $d $root) -or ((Split-Path -Parent (Get-NormPath $d)) -ine $root)) { throw "refusing to replace files: $d is not next to $Cur" }
        }
        if (-not (Test-Path -LiteralPath $Cur -PathType Container)) { throw "installed folder is missing: $Cur" }
        if (-not (Test-Path -LiteralPath $New -PathType Container)) { throw "prepared folder is missing: $New" }
        $want = @{}
        foreach ($k in $Expected.Keys) { $want[([string]$k).Replace([char]47, [IO.Path]::DirectorySeparatorChar).Replace([char]92, [IO.Path]::DirectorySeparatorChar)] = [string]$Expected[$k] }
        $rels = @($want.Keys)
        foreach ($r in $rels) { if (-not (Test-Path -LiteralPath (Join-Path $New $r) -PathType Leaf)) { throw "prepared file is missing: $r" } }
        # 1) backup of the previous version (a plain copy: works even when the folder itself is locked)
        if (Test-Path -LiteralPath $Old) { Remove-Item -LiteralPath $Old -Recurse -Force }
        $oldRels = @(Get-RelFiles $Cur)
        New-Item -ItemType Directory -Path $Old -Force | Out-Null
        Copy-FilesInto -From $Cur -To $Old -Rels $oldRels -TimeoutMs $TimeoutMs
        # 2) new files over the old ones, 3) verification of every file
        $bad = New-Object 'System.Collections.Generic.List[string]'
        try {
            Copy-FilesInto -From $New -To $Cur -Rels $rels -TimeoutMs $TimeoutMs -Replacer $Replacer
            foreach ($r in $rels) {
                $f = Join-Path $Cur $r
                if (-not (Test-Path -LiteralPath $f -PathType Leaf) -or ((Get-FileShaHex $f) -ne $want[$r])) { $bad.Add($r) }
            }
        } catch {
            $bad.Add('(error: ' + $_.Exception.Message + ')')
        }
        if ($bad.Count -gt 0) {
            $rb = 'previous version restored'
            try {
                Copy-FilesInto -From $Old -To $Cur -Rels $oldRels -TimeoutMs $TimeoutMs
                foreach ($r in $rels) { if ($oldRels -notcontains $r) { $f = Join-Path $Cur $r; if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force } } }
            } catch { $rb = 'ROLLBACK FAILED (' + $_.Exception.Message + '): the previous version is in ' + $Old }
            throw ('replacing files failed for: ' + ($bad -join ', ') + ' - ' + $rb)
        }
        # 4) files of the previous version that the new one does not have, then the temporary folders (not fatal)
        foreach ($r in $oldRels) { if (-not $want.ContainsKey($r)) { try { Remove-Item -LiteralPath (Join-Path $Cur $r) -Force } catch { } } }
        try { Remove-Item -LiteralPath $New -Recurse -Force } catch { }
        try { Remove-Item -LiteralPath $Old -Recurse -Force } catch { }
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
        'app/Engine.ps1' = 'dd031cfcdf6b3a4a3f67025033bd210d25b7500dfbc5a8e76e74fbdcd7fdc5e4'
        'app/Glyphix.ps1' = 'bf1e5fec8e1b563a96e5abfa9306bda0e3934a0b69cf2e9605241fd111033465'
        'app/ShadowIcons.ps1' = '70de09bdba26fb2d51e710f8a3753a476fbdbf38faa873ce8d92957351d335a3'
        'app/MainWindow.xaml' = 'c0f9bf9a06f2680cac2c178ee3a0d44810cf3ddf52a0e2f4196c6311ed1a377e'
        'app/launch.vbs' = 'f07159a4489eb71c47d2b9bfa2c4e9939f83c0aaadf364eecbadc9da7685e337'
        'app/version.txt' = 'f0ea2fc99f3b79d332baa91b88d4e4e469cb6b9f2c96669b3b4ec8f0d6f5b863'
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

        # 2) the running app must not hold the files (a GUI of any version, also the old one without a mutex): ask it to close, wait up to 8 s, stop the rest
        $siStop = Stop-GlyphixRunning -GraceSec 8
        if ($siStop.Failed.Count -gt 0) {
            throw ('Glyphix is still running (PID ' + ($siStop.Failed -join ', ') + ') and cannot be stopped. Close it (Task Manager - powershell.exe) and run the installer again. Nothing was changed.')
        }
        if ($siStop.MutexOnly) { Write-Host '  note: a Glyphix window of another session may still be open - continuing.' -ForegroundColor Yellow }

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
            try { Invoke-DirSwap -Cur $siApp -New $siNew -Old $siOld }
            catch {
                $siSwapErr = $_
                $siDecision = Get-SwapFallbackDecision -Ex $siSwapErr.Exception -CurExists (Test-Path -LiteralPath $siApp -PathType Container) -NewExists (Test-Path -LiteralPath $siNew -PathType Container)
                if ($siDecision -ne 'filewise') { throw $siSwapErr }
                Write-Host ('  the app folder is busy (' + $siSwapErr.Exception.Message + ') - replacing files one by one...') -ForegroundColor Yellow
                $siExp = @{}
                foreach ($rel in $siFiles.Keys) { $siExp[([string]$rel).Substring(4)] = [string]$siFiles[$rel] }      # the table keys start with app/
                Invoke-FileWiseSwap -Cur $siApp -New $siNew -Old $siOld -Expected $siExp
                Write-Host '  files replaced and verified.' -ForegroundColor DarkGray
            }
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
            Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + (Join-Path $siApp 'launch.vbs') + '"') -WorkingDirectory $siHome      # not app\: a process must not hold the app folder
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
