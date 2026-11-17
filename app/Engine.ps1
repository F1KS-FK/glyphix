<#
  Shadow Icons - движок (Windows PowerShell 5.1, без модулей).
  Подключается точкой: . .\Engine.ps1
  Данные: %LOCALAPPDATA%\ShadowIcons  (app\, packs\<id>\, backup\, state.json, log.txt)
  Ничего не запускается в фоне: нет автозапуска, нет задач планировщика.
#>

$ErrorActionPreference = 'Stop'

# ---------- Права ----------
$script:SI_IsAdmin = $null

function Test-Admin {
    if ($null -eq $script:SI_IsAdmin) {
        try {
            $script:SI_IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch { $script:SI_IsAdmin = $false }
    }
    return [bool]$script:SI_IsAdmin
}

# ---------- Пути и настройки ----------
$script:SI_BaseUrl = 'https://raw.githubusercontent.com/F1KS-FK/shadow-icons/main/'
# Под администратором переменную SHADOWICONS_HOME игнорируем: повышенный процесс не должен писать куда указал окружением кто-то другой.
$script:SI_Home = if ($env:SHADOWICONS_HOME -and -not (Test-Admin)) { $env:SHADOWICONS_HOME } else { Join-Path $env:LOCALAPPDATA 'ShadowIcons' }
$script:SI_AppDir = Join-Path $script:SI_Home 'app'
$script:SI_PacksDir = Join-Path $script:SI_Home 'packs'
$script:SI_BackupDir = Join-Path $script:SI_Home 'backup'
$script:SI_BackupFile = Join-Path $script:SI_BackupDir 'index.json'
$script:SI_StateFile = Join-Path $script:SI_Home 'state.json'
$script:SI_LogFile = Join-Path $script:SI_Home 'log.txt'
$script:SI_S11Root = 'Software\Stardock\Start8\Start8.ini'                      # HKCU: настройки Start11 (дерево)
$script:SI_S11Tiles = $script:SI_S11Root + '\Start8\CustomTiles'                  # имя = id плитки, данные = путь к PNG
$script:SI_S11BackupFile = Join-Path $script:SI_BackupDir 'start11.json'
$script:SI_S11Dir = Join-Path $script:SI_Home 'start11'                            # наши PNG плиток (стабильный путь)
$script:SI_S11Hint = 'Перезапусти Start11 или выйди из системы и зайди снова'
$script:SI_CodeDir = if ($PSScriptRoot) { $PSScriptRoot } else { $script:SI_AppDir }
$script:SI_OnLog = $null
$script:SI_NoLogFile = $false
$script:SI_ShellApp = $null
$script:SI_Wsh = $null
$script:SI_Seps = [char[]]@([char]92, [char]47)     # \ и /

try {
    if (-not ('ShadowIconsNative.Shell' -as [type])) {
        Add-Type -Namespace ShadowIconsNative -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)]
public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);
'@
    }
} catch { }

# ---------- Журнал ----------
function Set-EngineLogHandler {
    param([scriptblock]$Handler)
    $script:SI_OnLog = $Handler
}

function Write-Log {
    param([string]$Message)
    if (-not $script:SI_NoLogFile) {
        try {
            if (-not (Test-Path -LiteralPath $script:SI_Home)) { New-Item -ItemType Directory -Path $script:SI_Home -Force | Out-Null }
            if (Test-Path -LiteralPath $script:SI_LogFile) {
                if ((Get-Item -LiteralPath $script:SI_LogFile).Length -gt 1048576) {
                    Move-Item -LiteralPath $script:SI_LogFile -Destination ($script:SI_LogFile + '.old') -Force
                }
            }
            $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message + "`r`n"
            [IO.File]::AppendAllText($script:SI_LogFile, $line, (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    if ($script:SI_OnLog) { try { & $script:SI_OnLog $Message } catch { } }
}

# ---------- Утилиты ----------
function Get-Key {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name.ToLowerInvariant() -replace '[^\p{L}\p{Nd}]', '')
}

# имя файла без расширения; понимает и \ и / (работает одинаково на любой ОС)
function Get-BaseNameSafe {
    param([string]$Path)
    if (-not $Path) { return '' }
    $p = $Path.Trim().Trim('"')
    $i = [Math]::Max($p.LastIndexOf('\'), $p.LastIndexOf('/'))
    $f = $p.Substring($i + 1)
    $d = $f.LastIndexOf('.')
    if ($d -gt 0) { $f = $f.Substring(0, $d) }
    return $f
}

function Get-CurrentUserSid {
    return [string][Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

# SID владельца процесса explorer.exe текущей сессии (пользователь, чей рабочий стол мы правим)
function Get-ExplorerOwnerSid {
    foreach ($p in @(Get-SessionExplorer)) {
        try {
            $cp = Get-CimInstance -ClassName Win32_Process -Filter ('ProcessId=' + [int]$p.Id)
            $r = Invoke-CimMethod -InputObject $cp -MethodName GetOwnerSid
            if ($r -and $r.ReturnValue -eq 0 -and $r.Sid) { return [string]$r.Sid }
        } catch { }
    }
    return $null
}

# $null = можно работать; строка = причина отказа (только для повышенного процесса)
function Get-ElevationProblem {
    if (-not (Test-Admin)) { return $null }
    $me = $null
    try { $me = Get-CurrentUserSid } catch { }
    $own = Get-ExplorerOwnerSid
    if (-not $me -or -not $own) {
        return 'Не удалось определить, чей рабочий стол открыт (владелец проводника). Запустите Shadow Icons обычным образом, без прав администратора, и отметьте «Также общие ярлыки».'
    }
    if ($me -ne $own) {
        return 'Shadow Icons запущен от другой учётной записи администратора: изменения затронули бы не ваш рабочий стол. Закройте окно и запустите программу от своего пользователя; права администратора запрашиваются галочкой «Также общие ярлыки».'
    }
    return $null
}

function Assert-ElevationSafe {
    $m = Get-ElevationProblem
    if ($m) { throw $m }
}

function Get-AppVersion {
    foreach ($d in @($script:SI_CodeDir, $script:SI_AppDir)) {
        try {
            $f = Join-Path $d 'version.txt'
            if (Test-Path -LiteralPath $f) { return ([IO.File]::ReadAllText($f)).Trim().TrimStart([char]0xFEFF).Trim() }
        } catch { }
    }
    return '0.0.0'
}

function Read-JsonFile {
    param([string]$Path)
    $t = [IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    return ($t | ConvertFrom-Json)
}

function Get-FileSha256 {
    param([string]$Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $fs = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() } finally { $fs.Dispose() }
    } finally { $sha.Dispose() }
}

function Get-BytesSha256 {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() } finally { $sha.Dispose() }
}

# ---------- Состояние ----------
function Read-State {
    $st = @{}
    try {
        if (Test-Path -LiteralPath $script:SI_StateFile) {
            $o = Read-JsonFile $script:SI_StateFile
            foreach ($p in $o.PSObject.Properties) { $st[$p.Name] = $p.Value }
        }
    } catch { }
    return $st
}

function Save-State {
    param([hashtable]$State)
    try {
        if (-not (Test-Path -LiteralPath $script:SI_Home)) { New-Item -ItemType Directory -Path $script:SI_Home -Force | Out-Null }
        $json = ConvertTo-Json -InputObject $State -Depth 5
        [IO.File]::WriteAllText($script:SI_StateFile, $json, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-Log ('не удалось записать state.json: ' + $_.Exception.Message) }
}

# ---------- Сеть и обновление паков ----------
function Test-SafeRel {
    # относительный путь вида dir/file.ext: только [A-Za-z0-9_.-], сегменты не начинаются с точки, нужное расширение
    param([string]$Rel, [string[]]$Ext)
    if (-not $Rel) { return $false }
    $trim = $Rel.TrimEnd('/')
    foreach ($seg in $trim.Split('/')) {
        if ($seg -notmatch '^[A-Za-z0-9_][A-Za-z0-9_.\-]*$') { return $false }
        if ($seg.EndsWith('.')) { return $false }
        if ($seg -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])(\..*)?$') { return $false }   # зарезервированные имена Windows (с любым расширением)
    }
    if ($Ext -and $Ext.Count -gt 0) {
        $e = [IO.Path]::GetExtension($trim).ToLowerInvariant()
        if ($Ext -notcontains $e) { return $false }
    }
    return $true
}

function Get-WebBytes {
    param([string]$Url, [int]$MaxBytes = 8388608, [int]$TimeoutMs = 20000)
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $u = $Url + $sep + 'cb=' + [DateTime]::UtcNow.Ticks          # против кэша
    $req = [Net.HttpWebRequest]::Create($u)
    $req.Method = 'GET'
    $req.UserAgent = 'ShadowIcons/' + (Get-AppVersion)
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $true
    $req.Headers.Add('Cache-Control', 'no-cache')
    try { $req.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::BypassCache) } catch { }
    try {
        $px = [Net.WebRequest]::GetSystemWebProxy()
        $px.Credentials = [Net.CredentialCache]::DefaultCredentials
        $req.Proxy = $px
    } catch { }
    $resp = $req.GetResponse()
    try {
        $st = $resp.GetResponseStream()
        $ms = New-Object System.IO.MemoryStream
        try {
            $buf = New-Object byte[] 65536
            while (($n = $st.Read($buf, 0, $buf.Length)) -gt 0) {
                $ms.Write($buf, 0, $n)
                if ($ms.Length -gt $MaxBytes) { throw "ответ больше $MaxBytes байт: $Url" }
            }
            return , $ms.ToArray()
        } finally { $ms.Dispose(); $st.Dispose() }
    } finally { $resp.Close() }
}

function ConvertFrom-JsonBytes {
    param([byte[]]$Bytes)
    $t = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    return ($t | ConvertFrom-Json)
}

function Save-FileAtomic {
    param([string]$Path, [byte[]]$Bytes)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Join-Rel {
    param([string]$Base, [string]$Rel)
    $p = $Base
    foreach ($seg in $Rel.Split('/')) { if ($seg) { $p = Join-Path $p $seg } }
    return $p
}

# скачать файл, если локальный отсутствует или не совпал по sha256; вернуть 1 если качали
function Sync-File {
    param([string]$Url, [string]$Dest, [string]$Sha, [string]$Ext, [switch]$Force)
    if (-not $Sha -or $Sha -notmatch '^[0-9a-fA-F]{64}$') { throw "нет корректного sha256 для $Dest" }
    $Sha = $Sha.ToLowerInvariant()
    if (-not $Force -and (Test-Path -LiteralPath $Dest)) {
        try { if ((Get-FileSha256 $Dest) -eq $Sha) { return 0 } } catch { }
    }
    $b = Get-WebBytes $Url
    $got = Get-BytesSha256 $b
    if ($got -ne $Sha) { throw "sha256 не совпал у $Url (ожидали $Sha, получили $got)" }
    Save-FileAtomic $Dest $b
    return 1
}

function Update-OnePack {
    param([string]$BaseUrl, $Entry, [bool]$Force)
    $id = [string]$Entry.id
    if ($id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { throw "недопустимый id пака '$id'" }
    $path = ([string]$Entry.path).Trim('/')
    if (-not (Test-SafeRel $path $null)) { throw "недопустимый path '$($Entry.path)'" }
    $manRel = [string]$Entry.manifest
    if (-not (Test-SafeRel $manRel @('.json'))) { throw "недопустимый manifest '$manRel'" }
    $manSha = ([string]$Entry.manifest_sha256).ToLowerInvariant()
    if ($manSha -notmatch '^[0-9a-f]{64}$') { throw 'в index.json нет manifest_sha256' }

    $packDir = Join-Path $script:SI_PacksDir $id
    $manLocal = Join-Path $packDir 'pack.json'
    $packUrl = $BaseUrl + $path + '/'
    $downloaded = 0

    $needManifest = $Force -or -not (Test-Path -LiteralPath $manLocal)
    if (-not $needManifest) { try { $needManifest = ((Get-FileSha256 $manLocal) -ne $manSha) } catch { $needManifest = $true } }

    $manBytes = $null
    if ($needManifest) {
        $manBytes = Get-WebBytes ($BaseUrl + $manRel) 4194304
        if ((Get-BytesSha256 $manBytes) -ne $manSha) { throw 'sha256 pack.json не совпал с index.json' }
        $man = ConvertFrom-JsonBytes $manBytes
    } else {
        $man = Read-JsonFile $manLocal
    }
    if ([string]$man.id -ne $id) { throw "id в pack.json ('$($man.id)') не совпал с index.json" }

    foreach ($ic in @($man.icons)) {
        $icId = [string]$ic.id
        if ($icId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск иконки с неверным id '$icId'"; continue }
        foreach ($pair in @(@('ico', '.ico'), @('png', '.png'))) {
            $rel = [string]$ic.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel @($pair[1]))) { throw "недопустимый путь файла '$rel'" }
            $downloaded += (Sync-File ($packUrl + $rel) (Join-Rel $packDir $rel) ([string]$ic.($pair[0] + '_sha256')) $pair[1] -Force:$Force)
        }
    }
    # плитки Start11 (необязательно): обычная и без подписи; у каждой свой sha256
    foreach ($tl in @($man.tiles)) {
        if (-not $tl) { continue }
        $tId = [string]$tl.id
        if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск плитки с неверным id '$tId'"; continue }
        foreach ($pair in @(@('file', 'sha256'), @('file_noname', 'sha256_noname'))) {
            $rel = [string]$tl.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel @('.png'))) { throw "недопустимый путь файла '$rel'" }
            $downloaded += (Sync-File ($packUrl + $rel) (Join-Rel $packDir $rel) ([string]$tl.($pair[1])) '.png' -Force:$Force)
        }
    }
    $prevRel = [string]$man.preview
    if ($prevRel -and $Entry.preview_sha256) {
        if (-not (Test-SafeRel $prevRel @('.png'))) { throw "недопустимый preview '$prevRel'" }
        $downloaded += (Sync-File ($packUrl + $prevRel) (Join-Rel $packDir $prevRel) ([string]$Entry.preview_sha256) '.png' -Force:$Force)
    }
    # pack.json пишем последним: если что-то оборвалось, следующая проверка догрузит остальное
    if ($needManifest) { Save-FileAtomic $manLocal $manBytes; $downloaded++ }
    return $downloaded
}

function Update-Packs {
    [CmdletBinding()]
    param([string]$BaseUrl = $script:SI_BaseUrl, [switch]$Force)
    $errors = New-Object 'System.Collections.Generic.List[string]'
    $updated = New-Object 'System.Collections.Generic.List[string]'
    $total = 0
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
    Write-Log 'Проверяю обновления паков...'
    try {
        $idx = ConvertFrom-JsonBytes (Get-WebBytes ($BaseUrl + 'index.json') 1048576)
    } catch {
        $m = 'Не удалось получить index.json: ' + $_.Exception.Message
        Write-Log $m
        return [pscustomobject]@{ Ok = $false; Downloaded = 0; Updated = @(); Errors = @($m); Message = $m }
    }
    try {
        if ($idx.app_min_version) {
            if ([version][string]$idx.app_min_version -gt [version](Get-AppVersion)) {
                $m = "Для этих паков нужна версия приложения $($idx.app_min_version) или новее (у вас $(Get-AppVersion)). Переустановите приложение."
                Write-Log $m
                return [pscustomobject]@{ Ok = $false; Downloaded = 0; Updated = @(); Errors = @($m); Message = $m }
            }
        }
    } catch { }
    foreach ($entry in @($idx.packs)) {
        $pid2 = [string]$entry.id
        try {
            $n = Update-OnePack $BaseUrl $entry ([bool]$Force)
            $total += $n
            if ($n -gt 0) { $updated.Add($pid2); Write-Log "  $pid2 : загружено файлов $n" } else { Write-Log "  $pid2 : актуален" }
        } catch {
            $errors.Add("[$pid2] " + $_.Exception.Message)
            Write-Log "  ошибка в паке $pid2 : $($_.Exception.Message)"
        }
    }
    if ($errors.Count -eq 0) {
        $st = Read-State; $st['LastUpdate'] = (Get-Date).ToString('s'); Save-State $st
    }
    $msg = if ($errors.Count -gt 0) { "Обновление завершено с ошибками: $($errors.Count)" } elseif ($total -gt 0) { "Обновлено файлов: $total" } else { 'Все паки актуальны' }
    Write-Log $msg
    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Downloaded = $total; Updated = $updated.ToArray(); Errors = $errors.ToArray(); Message = $msg }
}

# ---------- Локальные паки ----------
function Get-Packs {
    $res = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $script:SI_PacksDir)) { return @() }
    foreach ($d in (Get-ChildItem -LiteralPath $script:SI_PacksDir -Directory -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $d.FullName 'pack.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $j = Read-JsonFile $mf
            $id = [string]$j.id
            if ($id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { continue }
            $tileMap = @{}
            foreach ($tl in @($j.tiles)) {
                if (-not $tl) { continue }
                $tId = [string]$tl.id
                if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { continue }
                $tp = $null; $tn = $null
                if ($tl.file -and (Test-SafeRel ([string]$tl.file) @('.png'))) {
                    $x = Join-Rel $d.FullName ([string]$tl.file); if (Test-Path -LiteralPath $x) { $tp = $x }
                }
                if ($tl.file_noname -and (Test-SafeRel ([string]$tl.file_noname) @('.png'))) {
                    $x = Join-Rel $d.FullName ([string]$tl.file_noname); if (Test-Path -LiteralPath $x) { $tn = $x }
                }
                if ($tp -or $tn) { $tileMap[$tId] = @{ Tile = $tp; NoName = $tn } }
            }
            $icons = New-Object 'System.Collections.Generic.List[object]'
            foreach ($ic in @($j.icons)) {
                if (-not $ic.ico -or -not (Test-SafeRel ([string]$ic.ico) @('.ico'))) { continue }
                $ico = Join-Rel $d.FullName ([string]$ic.ico)
                if (-not (Test-Path -LiteralPath $ico)) { continue }
                $png = $null
                if ($ic.png -and (Test-SafeRel ([string]$ic.png) @('.png'))) {
                    $pp = Join-Rel $d.FullName ([string]$ic.png)
                    if (Test-Path -LiteralPath $pp) { $png = $pp }
                }
                $mn = @(); $mx = @()
                if ($ic.match) { $mn = @($ic.match.names | ForEach-Object { [string]$_ }); $mx = @($ic.match.exes | ForEach-Object { [string]$_ }) }
                $tilePath = $null; $tileNoName = $null
                if ($tileMap.ContainsKey([string]$ic.id)) { $tilePath = $tileMap[[string]$ic.id].Tile; $tileNoName = $tileMap[[string]$ic.id].NoName }
                $icons.Add([pscustomobject]@{ Id = [string]$ic.id; Name = [string]$ic.name; IcoPath = $ico; PngPath = $png; Names = $mn; Exes = $mx; TilePath = $tilePath; TileNoNamePath = $tileNoName })
            }
            $prev = $null
            if ($j.preview -and (Test-SafeRel ([string]$j.preview) @('.png'))) {
                $pv = Join-Rel $d.FullName ([string]$j.preview)
                if (Test-Path -LiteralPath $pv) { $prev = $pv }
            }
            $res.Add([pscustomobject]@{
                Id = $id; Name = [string]$j.name; Version = [string]$j.version; Author = [string]$j.author
                License = [string]$j.license; Description = [string]$j.description
                IconCount = $icons.Count; Dir = $d.FullName; Preview = $prev; Icons = $icons.ToArray()
            })
        } catch { Write-Log "пак $($d.Name) не прочитан: $($_.Exception.Message)" }
    }
    return @($res | Sort-Object { $_.Name })
}

# ---------- Сопоставление ----------
function New-MatchIndex {
    param($Pack)
    $nameMap = @{}; $exeMap = @{}
    foreach ($ic in @($Pack.Icons)) {
        foreach ($n in @($ic.Names)) { $k = Get-Key $n; if ($k -and -not $nameMap.ContainsKey($k)) { $nameMap[$k] = $ic } }
        foreach ($e in @($ic.Exes)) { $k = Get-Key $e; if ($k -and -not $exeMap.ContainsKey($k)) { $exeMap[$k] = $ic } }
    }
    return [pscustomobject]@{ Names = $nameMap; Exes = $exeMap }
}

function Test-UninstallLike {
    param([string]$NameKey, [string]$ExeKey)
    if ($NameKey -match 'uninstall|удалить|удаление|деинсталл') { return $true }
    if ($ExeKey -match '^unins|uninstall') { return $true }
    return $false
}

# имя-ключ -> точное имя; exe-ключ -> точный exe; префикс имени (запись names длиной >= 3, самая длинная)
function Find-IconMatch {
    param($Index, [string]$Name, [string]$Target, [string]$Arguments)
    $k1 = Get-Key $Name
    $matchTarget = $Target
    if ($Arguments -match '--app-id|--app=') { $matchTarget = '' }                                   # PWA: не по chrome.exe
    if ($matchTarget -and ($matchTarget -match '(^|[\\/])explorer\.exe\s*$') -and $Arguments) { $matchTarget = '' }  # explorer.exe shell:::{...}
    $k2 = if ($matchTarget) { Get-Key (Get-BaseNameSafe $matchTarget) } else { '' }
    if ($k2 -eq 'update') { $k2 = '' }                                                                # Squirrel Update.exe

    if ($k1 -and $Index.Names.ContainsKey($k1)) { return [pscustomobject]@{ Icon = $Index.Names[$k1]; Rule = 'name' } }
    if ($k2 -and $Index.Exes.ContainsKey($k2)) { return [pscustomobject]@{ Icon = $Index.Exes[$k2]; Rule = 'exe' } }
    if (Test-UninstallLike $k1 $k2) { return $null }
    $best = Find-PrefixMatch $Index @($k1, $k2)
    if ($best) { return [pscustomobject]@{ Icon = $best; Rule = 'prefix' } }
    return $null
}

# префикс: ключ names длиной >= 3 (самый длинный), с которого начинается любой из $Keys
function Find-PrefixMatch {
    param($Index, [string[]]$Keys)
    $best = $null; $bestLen = 0
    foreach ($key in $Index.Names.Keys) {
        if ($key.Length -lt 3 -or $key.Length -le $bestLen) { continue }
        foreach ($k in @($Keys)) {
            if ($k -and $k.StartsWith($key, [StringComparison]::Ordinal)) { $best = $Index.Names[$key]; $bestLen = $key.Length; break }
        }
    }
    return $best
}

# ---------- Ярлыки ----------
function Get-WshShell {
    if (-not $script:SI_Wsh) { $script:SI_Wsh = New-Object -ComObject WScript.Shell }
    return $script:SI_Wsh
}

function Get-ShortcutRoots {
    param([switch]$Common)   # -Common: добавить общие папки (для всех пользователей)
    $roots = New-Object 'System.Collections.Generic.List[object]'
    $roots.Add(@{ Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); Recurse = $false; Location = 'taskbar' })
    $roots.Add(@{ Path = [Environment]::GetFolderPath('Desktop'); Recurse = $false; Location = 'desktop' })
    $roots.Add(@{ Path = [Environment]::GetFolderPath('Programs'); Recurse = $true; Location = 'start' })
    if ($Common) {      # менять общие ярлыки можно только с правами администратора, но читать - всем
        $roots.Add(@{ Path = [Environment]::GetFolderPath('CommonDesktopDirectory'); Recurse = $false; Location = 'desktop_all' })
        $roots.Add(@{ Path = [Environment]::GetFolderPath('CommonPrograms'); Recurse = $true; Location = 'start_all' })
    }
    return $roots
}

function Get-ShortcutList {
    param([switch]$AllUsers)
    $wsh = Get-WshShell
    $seen = @{}
    foreach ($r in (Get-ShortcutRoots -Common:$AllUsers)) {
        if (-not $r.Path -or -not (Test-Path -LiteralPath $r.Path)) { continue }
        $files = @(Get-ChildItem -LiteralPath $r.Path -Filter *.lnk -File -Recurse:([bool]$r.Recurse) -ErrorAction SilentlyContinue)
        foreach ($f in $files) {
            $lk = $f.FullName.ToLowerInvariant()
            if ($seen.ContainsKey($lk)) { continue }
            $seen[$lk] = $true
            try {
                $sc = $wsh.CreateShortcut($f.FullName)
                [pscustomobject]@{
                    Name = $f.BaseName; Path = $f.FullName; Location = $r.Location
                    Target = [string]$sc.TargetPath; Args = [string]$sc.Arguments; Icon = [string]$sc.IconLocation
                }
            } catch { Write-Log "  не прочитан ярлык $($f.Name): $($_.Exception.Message)" }
        }
    }
}

function Test-IconIsSet {
    param([string]$Current, [string]$Ico)
    if (-not $Current) { return $false }
    if ($Current -match '^(.+?),\s*(-?\d+)$') {
        $p = $Matches[1].Trim().Trim('"')
        return ($p -ieq $Ico -and [int]$Matches[2] -eq 0)
    }
    return ($Current.Trim().Trim('"') -ieq $Ico)
}

function Get-Matches {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Shortcuts, [switch]$AllUsers)
    if ($null -eq $Shortcuts) { $Shortcuts = @(Get-ShortcutList -AllUsers:$AllUsers) }
    $index = New-MatchIndex $Pack
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($s in @($Shortcuts)) {
        try {
            $m = Find-IconMatch $index $s.Name $s.Target $s.Args
            if (-not $m) { continue }
            $out.Add([pscustomobject]@{
                Name = $s.Name; Path = $s.Path; Location = $s.Location; Target = $s.Target; Args = $s.Args; Icon = $s.Icon
                IconId = $m.Icon.Id; IconName = $m.Icon.Name; IcoPath = $m.Icon.IcoPath; PngPath = $m.Icon.PngPath
                Rule = $m.Rule; Already = (Test-IconIsSet $s.Icon $m.Icon.IcoPath)
            })
        } catch { Write-Log "  ошибка сопоставления $($s.Name): $($_.Exception.Message)" }
    }
    return $out.ToArray()
}

# ---------- Проверки путей ----------
# $Full внутри каталога $Dir (оба - полные пути)
function Test-PathUnder {
    param([string]$Full, [string]$Dir)
    if (-not $Full -or -not $Dir) { return $false }
    $d = $Dir.TrimEnd($script:SI_Seps) + [IO.Path]::DirectorySeparatorChar
    return $Full.StartsWith($d, [StringComparison]::OrdinalIgnoreCase)
}

# .ico, который можно подменять/восстанавливать: внутри %LOCALAPPDATA%\ (не LocalLow, не наша папка данных),
# ни сам файл, ни его родители до %LOCALAPPDATA% включительно - не точки повторной обработки (junction/symlink)
function Test-IcoSwapPath {
    param([string]$Path)
    if (-not $Path -or -not $env:LOCALAPPDATA) { return $false }
    try {
        $sep = [IO.Path]::DirectorySeparatorChar
        $full = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd($script:SI_Seps) + $sep
        if (-not $full.EndsWith('.ico', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if ($full.IndexOf(':', 2) -ge 0) { return $false }                         # альтернативные потоки данных
        foreach ($seg in $full.Substring($root.Length).Split($script:SI_Seps)) {
            if ($seg -ieq 'LocalLow') { return $false }
        }
        if (Test-PathUnder $full ([IO.Path]::GetFullPath($script:SI_Home))) { return $false }
        $cur = $full
        while ($cur -and (($cur.TrimEnd($script:SI_Seps) + $sep).StartsWith($root, [StringComparison]::OrdinalIgnoreCase))) {
            if (Test-Path -LiteralPath $cur) {
                if (([IO.File]::GetAttributes($cur) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
            $cur = [IO.Path]::GetDirectoryName($cur)
        }
        return $true
    } catch { return $false }
}

# Проверка записи бэкапа до любых действий. $null = можно; строка = причина отказа.
function Test-BackupEntry {
    param([string]$Path, [string]$Copy)
    try {
        if (-not $Path -or -not $Copy) { return 'пустой путь' }
        $fp = [IO.Path]::GetFullPath($Path)
        $fc = [IO.Path]::GetFullPath($Copy)
        if (-not (Test-PathUnder $fc ([IO.Path]::GetFullPath($script:SI_BackupDir)))) { return 'копия вне папки бэкапа' }
        if ([IO.Path]::GetFileName($fc) -ieq 'index.json') { return 'копия указывает на index.json' }
        $ext = [IO.Path]::GetExtension($fp).ToLowerInvariant()
        if ($ext -eq '.lnk') {
            foreach ($r in @(Get-ShortcutRoots -Common)) {
                if (-not $r.Path) { continue }
                $rp = [IO.Path]::GetFullPath($r.Path)
                if ($r.Recurse) {
                    if (Test-PathUnder $fp $rp) { return $null }
                } else {
                    $dir = [IO.Path]::GetDirectoryName($fp)
                    if ($dir -and ($dir.TrimEnd($script:SI_Seps) -ieq $rp.TrimEnd($script:SI_Seps))) { return $null }
                }
            }
            return 'ярлык вне известных папок'
        }
        if ($ext -eq '.ico') {
            if (Test-IcoSwapPath $fp) { return $null }
            return 'файл .ico вне %LOCALAPPDATA% или за ссылкой/junction'
        }
        return 'неподдерживаемый тип файла'
    } catch { return 'неверный путь: ' + $_.Exception.Message }
}

# ---------- Бэкап (backup\index.json = массив {Path, Copy, Icon}; старый формат v2 {Path, Copy} читается) ----------
# Load-Backup: хэш-таблица Path -> @{ Copy; Icon }, Icon = $null у старых записей
function Load-Backup {
    $map = @{}
    if (Test-Path -LiteralPath $script:SI_BackupFile) {
        $data = Read-JsonFile $script:SI_BackupFile
        foreach ($e in @($data)) {
            if (-not $e -or -not $e.Path -or -not $e.Copy) { continue }
            $icon = $null
            if ($e.PSObject.Properties['Icon'] -and $null -ne $e.Icon) { $icon = [string]$e.Icon }
            $map[[string]$e.Path] = [pscustomobject]@{ Copy = [string]$e.Copy; Icon = $icon }
        }
    }
    return $map
}

function Save-Backup {
    param([hashtable]$Map)
    if ($Map.Count -eq 0) {
        if (Test-Path -LiteralPath $script:SI_BackupFile) { Remove-Item -LiteralPath $script:SI_BackupFile -Force }
        return
    }
    if (-not (Test-Path -LiteralPath $script:SI_BackupDir)) { New-Item -ItemType Directory -Path $script:SI_BackupDir -Force | Out-Null }
    $arr = foreach ($k in $Map.Keys) { [pscustomobject]@{ Path = $k; Copy = $Map[$k].Copy; Icon = $Map[$k].Icon } }
    $json = ConvertTo-Json -InputObject @($arr)
    $tmp = $script:SI_BackupFile + '.tmp'          # пишем во временный файл и переименовываем: обрыв не оставит битый index.json
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $script:SI_BackupFile) {
            try { [IO.File]::Replace($tmp, $script:SI_BackupFile, $null) } catch { Move-Item -LiteralPath $tmp -Destination $script:SI_BackupFile -Force }
        } else {
            Move-Item -LiteralPath $tmp -Destination $script:SI_BackupFile -Force
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } }
    }
}

# $Icon - исходный IconLocation ярлыка ("путь,индекс"); для .ico не нужен
function Backup-File {
    param([hashtable]$Map, [string]$Path, $Icon = $null)
    if ($Map.ContainsKey($Path)) { return }
    if (-not (Test-Path -LiteralPath $script:SI_BackupDir)) { New-Item -ItemType Directory -Path $script:SI_BackupDir -Force | Out-Null }
    $name = [IO.Path]::GetFileName($Path)
    $copy = Join-Path $script:SI_BackupDir (([guid]::NewGuid().ToString('N').Substring(0, 8)) + '_' + $name)
    Copy-Item -LiteralPath $Path -Destination $copy -Force
    $Map[$Path] = [pscustomobject]@{ Copy = $copy; Icon = $(if ($null -ne $Icon) { [string]$Icon } else { $null }) }
    Save-Backup $Map
}

# "C:\x.exe,3" -> Path 'C:\x.exe', Index 3 (без индекса - 0)
function Split-IconLocation {
    param([string]$Loc)
    $p = [string]$Loc; $i = 0
    if ($p -match '^(.*),\s*(-?\d+)\s*$') { $p = $Matches[1]; $i = [int]$Matches[2] }
    return [pscustomobject]@{ Path = $p.Trim(); Index = $i }
}

# ---------- Применение иконки ----------
function Set-LinkIcon {
    param([string]$Path, [string]$Ico, [int]$Index = 0)
    # 1) Shell.Application (IShellLink) - работает и с ярлыками без пути (UWP и т.п.)
    try {
        if (-not $script:SI_ShellApp) { $script:SI_ShellApp = New-Object -ComObject Shell.Application }
        $folder = $script:SI_ShellApp.NameSpace([IO.Path]::GetDirectoryName($Path))
        $item = $folder.ParseName([IO.Path]::GetFileName($Path))
        $link = $item.GetLink
        $link.SetIconLocation($Ico, $Index)
        $link.Save()
        return 'shell'
    } catch { }
    # 2) запасной вариант - WScript.Shell (только если у ярлыка есть цель)
    $sc = (Get-WshShell).CreateShortcut($Path)
    if (-not $sc.TargetPath) { throw 'у ярлыка нет пути, WScript не сохранит его без потери данных' }
    $sc.IconLocation = "$Ico,$Index"
    $sc.Save()
    return 'wsh'
}

function Send-ItemNotify {
    param([string]$Path)
    try { [ShadowIconsNative.Shell]::SHChangeNotify(0x00002000, 0x0005, $Path, [IntPtr]::Zero) } catch { }   # SHCNE_UPDATEITEM, SHCNF_PATHW
}
function Send-AllNotify {
    try { [ShadowIconsNative.Shell]::SHChangeNotify(0x08000000, 0x0000, $null, [IntPtr]::Zero) } catch { }    # SHCNE_ASSOCCHANGED
}

function Get-SessionExplorer {
    $sid = (Get-Process -Id $PID).SessionId
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sid }
}

function Restart-Explorer {
    param([bool]$ClearCache = $true)
    Write-Log $(if ($ClearCache) { 'Перезапускаю проводник и сбрасываю кэш иконок...' } else { 'Перезапускаю проводник...' })
    foreach ($p in @(Get-SessionExplorer)) { try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { } }
    if ($ClearCache) {
        Start-Sleep -Milliseconds 300
        $files = New-Object 'System.Collections.Generic.List[string]'
        $files.Add((Join-Path $env:LOCALAPPDATA 'IconCache.db'))
        $exDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
        foreach ($f in @(Get-ChildItem -LiteralPath $exDir -Filter 'iconcache_*.db' -File -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { Remove-Item -LiteralPath $f -Force } catch { Write-Log "  кэш занят, не удалён: $f" }
        }
    }
    for ($i = 0; $i -lt 20; $i++) {      # до 10 секунд ждём автоперезапуск проводника
        Start-Sleep -Milliseconds 500
        if (Get-SessionExplorer) { return }
    }
    # Проводник не вернулся. Из повышенного процесса его НЕЛЬЗЯ запускать напрямую (получится проводник с правами администратора).
    if (Test-Admin) {
        $runas = Join-Path $env:SystemRoot 'System32\runas.exe'
        $exp = Join-Path $env:SystemRoot 'explorer.exe'
        Start-Process -FilePath $runas -ArgumentList ('/trustlevel:0x20000 "' + $exp + '"') -WindowStyle Hidden
    } else {
        Start-Process -FilePath 'explorer.exe'
    }
}

function Update-IconView {
    param([bool]$RestartExplorer = $true, [bool]$ClearCache = $true)
    Send-AllNotify
    $ie4 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\ie4uinit.exe' } else { '' }
    if ($ie4 -and (Test-Path -LiteralPath $ie4)) { try { Start-Process -FilePath $ie4 -ArgumentList '-show' -WindowStyle Hidden -Wait } catch { } }
    if ($RestartExplorer) { Restart-Explorer $ClearCache }
}

function Apply-Pack {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Items, [switch]$RestartExplorer)
    Assert-ElevationSafe
    Write-Log "Применяю пак: $($Pack.Name) $($Pack.Version)"
    if ($null -eq $Items) { $Items = @(Get-Matches -Pack $Pack) }
    $backup = Load-Backup
    $changed = 0; $same = 0; $failed = 0
    foreach ($m in @($Items)) {
        try {
            if ($m.Already) { $same++; continue }
            Backup-File $backup $m.Path ([string]$m.Icon)
            $how = Set-LinkIcon $m.Path $m.IcoPath
            $after = [string](Get-WshShell).CreateShortcut($m.Path).IconLocation
            Send-ItemNotify $m.Path
            $changed++
            # приложение может пересоздать ярлык со своей иконкой - подменяем и сам .ico, на который он указывал
            if ($m.Icon -match '^(.+?),\s*(-?\d+)$') {
                $orig = [Environment]::ExpandEnvironmentStrings($Matches[1].Trim().Trim('"'))
                if ((Test-IcoSwapPath $orig) -and (Test-Path -LiteralPath $orig -PathType Leaf)) {
                    if ((Get-FileSha256 $orig) -ne (Get-FileSha256 $m.IcoPath)) {
                        try {
                            Backup-File $backup $orig
                            Copy-Item -LiteralPath $m.IcoPath -Destination $orig -Force
                            Write-Log "       + подменён файл иконки приложения: $orig"
                        } catch { Write-Log "       не удалось подменить $orig : $($_.Exception.Message)" }
                    }
                }
            }
            $ok = if (Test-IconIsSet $after $m.IcoPath) { 'OK' } else { '??' }
            Write-Log "  $ok $($m.Name)  <-  $($m.IconName)  [$how]"
        } catch {
            $failed++
            Write-Log "  ошибка с $($m.Name): $($_.Exception.Message)"
        }
    }
    $st = Read-State
    if ($changed -gt 0 -or $same -gt 0) {
        $st['Applied'] = @{ PackId = $Pack.Id; Version = $Pack.Version; At = (Get-Date).ToString('s'); Count = ($changed + $same) }
        Save-State $st
    }
    Write-Log "Заменено: $changed, уже стояли: $same, ошибок: $failed"
    $restarted = $false
    if ($changed -gt 0) { Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true; $restarted = [bool]$RestartExplorer }
    return [pscustomobject]@{ Changed = $changed; Same = $same; Failed = $failed; Total = @($Items).Count; Restarted = $restarted }
}

# ---------- Плитки Start11 ----------
# Start11 хранит настройки в реестре: HKCU\Software\Stardock\Start8\Start8.ini (дерево подключей).
# Своя плитка = значение REG_SZ в подключе Start8\CustomTiles: ИМЯ = id плитки, ДАННЫЕ = полный путь к PNG.
# id плитки = AppID из Get-StartApps, где каждый '\' заменён на '_' (AUMID остаются как есть).
# Остальные подключи (CustomTilesText/Icon/Painting, CustomText) не трогаем. HKLM не трогаем никогда.

# --- слой реестра (в тестах подменяется) ---
function Test-S11Key {
    param([string]$Sub)
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
        if ($k) { $k.Close(); return $true }
    } catch { }
    return $false
}

# строка значения или $null, если значения нет; не REG_SZ - исключение (такое значение не трогаем)
function Get-S11Value {
    param([string]$Sub, [string]$Name)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
    if (-not $k) { return $null }
    try {
        if (@($k.GetValueNames()) -notcontains $Name) { return $null }
        $kind = [string]$k.GetValueKind($Name)
        if ($kind -ne 'String' -and $kind -ne 'ExpandString') { throw "значение '$Name' в реестре не REG_SZ ($kind)" }
        return [string]$k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    } finally { $k.Close() }
}

function Set-S11Value {
    param([string]$Sub, [string]$Name, [string]$Data)
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Sub)
    try { $k.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]::String) } finally { $k.Close() }
}

function Remove-S11Value {
    param([string]$Sub, [string]$Name)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $true)
    if (-not $k) { return }
    try { $k.DeleteValue($Name, $false) } finally { $k.Close() }
}

# имена всех значений в дереве (рекурсивно), без значений по умолчанию
function Get-S11ValueNames {
    param([string]$Sub, [int]$Depth = 0)
    $out = New-Object 'System.Collections.Generic.List[string]'
    if ($Depth -gt 8) { return @() }
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
    if (-not $k) { return @() }
    try {
        foreach ($n in @($k.GetValueNames())) { if ($n) { $out.Add([string]$n) } }
        foreach ($s in @($k.GetSubKeyNames())) { foreach ($n in @(Get-S11ValueNames ($Sub + '\' + $s) ($Depth + 1))) { $out.Add([string]$n) } }
    } finally { $k.Close() }
    return $out.ToArray()
}

function Test-Start11 {
    return [bool](Test-S11Key $script:SI_S11Root)
}

# --- id плитки и сопоставление ---
# Приложения из Get-StartApps + все имена значений, уже лежащие в дереве Start8.ini
function Get-Start11Candidates {
    $map = @{}
    $list = New-Object 'System.Collections.Generic.List[object]'
    $apps = @()
    try { if (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue) { $apps = @(Get-StartApps) } } catch { Write-Log ('Get-StartApps: ' + $_.Exception.Message) }
    foreach ($a in $apps) {
        if (-not $a) { continue }
        $aid = [string]$a.AppID
        if (-not $aid) { continue }
        $id = $aid -replace '\\', '_'
        if ($map.ContainsKey($id)) { continue }
        $o = [pscustomobject]@{ Id = $id; Name = [string]$a.Name; Source = 'start' }
        $map[$id] = $o; $list.Add($o)
    }
    $names = @()
    try { $names = @(Get-S11ValueNames $script:SI_S11Root) } catch { Write-Log ('чтение реестра Start11: ' + $_.Exception.Message) }
    foreach ($n in $names) {
        if (-not $n) { continue }
        if ($map.ContainsKey($n)) { $map[$n].Source = 'start+reg'; continue }
        $o = [pscustomobject]@{ Id = [string]$n; Name = ''; Source = 'reg' }
        $map[$n] = $o; $list.Add($o)
    }
    return $list.ToArray()
}

# ключ без издательских префиксов: windowscalculator -> calculator (остаток >= 4 символов)
function Get-StrippedKeys {
    param([string]$Key)
    $out = @()
    $k = $Key
    for ($i = 0; $i -lt 3; $i++) {
        $changed = $false
        foreach ($pre in @('microsoft', 'windows')) {
            if ($k.StartsWith($pre, [StringComparison]::Ordinal) -and ($k.Length - $pre.Length) -ge 4) { $k = $k.Substring($pre.Length); $out += $k; $changed = $true; break }
        }
        if (-not $changed) { break }
    }
    return $out
}

# Что можно вытащить из id плитки. Pwa = PWA Chrome/Edge (Chrome._crx_<id>): по id не сопоставляем вообще.
# Keys = упорядоченные ключи для точного сравнения с names (последний токен важнее: com.anilibria.anilibrix -> anilibrix);
# Last = ключ имени файла/последнего токена для exes и префикса.
function Get-TileIdInfo {
    param([string]$Id)
    $info = [pscustomobject]@{ Pwa = $false; Keys = @(); Last = '' }
    if (-not $Id) { return $info }
    $s = $Id.Trim()
    if ($s -match '\._crx_') { $info.Pwa = $true; return $info }
    $extRx = '\.(exe|lnk|bat|cmd|com|msi|url|app)$'
    $tokens = @()
    $pathLike = ($s -match '^[A-Za-z]:[_\\/]') -or ($s -match '^\{[0-9A-Fa-f\-]{36}\}[_\\/]') -or ($s -match '[\\/]')
    if ($s.Contains('!')) {                                             # AUMID: Имя.Пакета_хэш!App
        $pfn = $s.Substring(0, $s.IndexOf('!')) -replace '_[a-z0-9]{13}$', ''
        $tokens = @($pfn.Split([char[]]@('.', '_', ' ')) | Where-Object { $_ })
    } elseif ($pathLike) {                                              # полный путь: смотрим только на имя файла
        $seg = @($s.Split([char[]]@('_', '\', '/')) | Where-Object { $_ })
        if ($seg.Count -gt 0) { $tokens = @(($seg[$seg.Count - 1]) -replace $extRx, '') }
    } else {
        $tokens = @(($s -replace $extRx, '').Split([char[]]@('.', '_', ' ')) | Where-Object { $_ })
    }
    $tokens = @($tokens | ForEach-Object { Get-Key $_ } | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $info }
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $n = $tokens.Count
    for ($end = $n; $end -ge 1; $end--) {
        for ($len = [Math]::Min(3, $end); $len -ge 1; $len--) {
            $k = ($tokens[($end - $len)..($end - 1)]) -join ''
            foreach ($v in (@($k) + @(Get-StrippedKeys $k))) {
                if ($v -and -not $seen.ContainsKey($v)) { $seen[$v] = $true; $keys.Add($v) }
            }
        }
    }
    $info.Keys = $keys.ToArray()
    $info.Last = $tokens[$n - 1]
    return $info
}

# доп. имена для сопоставления плиток (только в движке; pack.json не меняем): icon id -> ключи
$script:SI_TileAliases = @{ yandexmusic = @('yandexdesktopmusic') }

function New-TileIndex {
    param($Pack)
    $ix = New-MatchIndex $Pack
    foreach ($ic in @($Pack.Icons)) {
        if (-not $script:SI_TileAliases.ContainsKey([string]$ic.Id)) { continue }
        foreach ($a in @($script:SI_TileAliases[[string]$ic.Id])) { $k = Get-Key $a; if ($k -and -not $ix.Names.ContainsKey($k)) { $ix.Names[$k] = $ic } }
    }
    return $ix
}

# те же правила, что у ярлыков: имя (точно) -> exe (точно) -> id (точно, по токенам) -> префикс имени/файла
function Find-TileMatch {
    param($Index, [string]$Name, [string]$Id)
    $info = Get-TileIdInfo $Id
    $k1 = Get-Key $Name
    $last = $info.Last
    if ($last -eq 'update') { $last = '' }                                      # Squirrel Update.exe
    if ($k1 -and $Index.Names.ContainsKey($k1)) { return [pscustomobject]@{ Icon = $Index.Names[$k1]; Rule = 'name' } }
    foreach ($lk in (@($last) + @(Get-StrippedKeys $last))) {
        if ($lk -and $Index.Exes.ContainsKey($lk)) { return [pscustomobject]@{ Icon = $Index.Exes[$lk]; Rule = 'exe' } }
    }
    foreach ($k in $info.Keys) {
        if ($Index.Names.ContainsKey($k)) { return [pscustomobject]@{ Icon = $Index.Names[$k]; Rule = 'id' } }
    }
    if (Test-UninstallLike $k1 $last) { return $null }
    $best = Find-PrefixMatch $Index @($k1, $last)
    if ($best) { return [pscustomobject]@{ Icon = $best; Rule = 'prefix' } }
    return $null
}

function Get-Start11TileDest {
    param([string]$PackId, [string]$IconId)
    return (Join-Path (Join-Path $script:SI_S11Dir $PackId) ($IconId + '.png'))
}

function Test-Start11TileSet {
    param([string]$Id, [string]$Dest, [string]$Src)
    try {
        $cur = Get-S11Value $script:SI_S11Tiles $Id
        if ($null -eq $cur -or $cur -ine $Dest) { return $false }
        if (-not (Test-Path -LiteralPath $Dest -PathType Leaf)) { return $false }
        return ((Get-FileSha256 $Dest) -eq (Get-FileSha256 $Src))
    } catch { return $false }
}

function Get-Start11Matches {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Candidates, [switch]$NoName)
    if ($null -eq $Candidates) { $Candidates = @(Get-Start11Candidates) }
    $index = New-TileIndex $Pack
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @($Candidates)) {
        try {
            $m = Find-TileMatch $index $c.Name $c.Id
            if (-not $m) { continue }
            $src = $m.Icon.TilePath
            if ($NoName -and $m.Icon.TileNoNamePath) { $src = $m.Icon.TileNoNamePath }
            if (-not $src) { continue }
            $dest = Get-Start11TileDest ([string]$Pack.Id) ([string]$m.Icon.Id)
            $out.Add([pscustomobject]@{
                TileId = [string]$c.Id; Name = [string]$c.Name; Source = [string]$c.Source
                IconId = [string]$m.Icon.Id; IconName = [string]$m.Icon.Name; TilePath = $src
                Rule = $m.Rule; Already = (Test-Start11TileSet ([string]$c.Id) $dest $src)
            })
        } catch { Write-Log "  ошибка сопоставления плитки $($c.Id): $($_.Exception.Message)" }
    }
    return $out.ToArray()
}

# --- бэкап значений CustomTiles: backup\start11.json = массив {Id, Absent, Data}; Absent = значения не было ---
function Save-JsonAtomic {
    param([string]$Path, [string]$Json)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    try {
        [IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding($true)))
        if (Test-Path -LiteralPath $Path) {
            try { [IO.File]::Replace($tmp, $Path, $null) } catch { Move-Item -LiteralPath $tmp -Destination $Path -Force }
        } else {
            Move-Item -LiteralPath $tmp -Destination $Path -Force
        }
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } }
    }
}

function Load-S11Backup {
    $map = @{}
    if (Test-Path -LiteralPath $script:SI_S11BackupFile) {
        $data = Read-JsonFile $script:SI_S11BackupFile
        foreach ($e in @($data)) {
            if (-not $e -or -not $e.Id) { continue }
            $absent = [bool]$e.Absent
            if (-not $absent -and $null -eq $e.Data) { continue }
            $map[[string]$e.Id] = [pscustomobject]@{ Absent = $absent; Data = $(if ($absent) { $null } else { [string]$e.Data }) }
        }
    }
    return $map
}

function Save-S11Backup {
    param([hashtable]$Map)
    if ($Map.Count -eq 0) {
        if (Test-Path -LiteralPath $script:SI_S11BackupFile) { Remove-Item -LiteralPath $script:SI_S11BackupFile -Force }
        return
    }
    $arr = foreach ($k in $Map.Keys) { [pscustomobject]@{ Id = $k; Absent = [bool]$Map[$k].Absent; Data = $Map[$k].Data } }
    Save-JsonAtomic $script:SI_S11BackupFile (ConvertTo-Json -InputObject @($arr))
}

# --- перезапуск Start11, чтобы он перечитал плитки ---
function Get-Start11Processes {
    $sid = (Get-Process -Id $PID).SessionId
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $path = ''
        try {
            if ($p.SessionId -ne $sid) { continue }
            $path = [string]$p.MainModule.FileName
        } catch { continue }
        if (-not (Test-Start11Process ([string]$p.ProcessName) $path)) { continue }
        [pscustomobject]@{ Id = [int]$p.Id; Name = [string]$p.ProcessName; Path = $path }
    }
}

# процесс Start11, который нужно перезапускать: exe в папке ...\Stardock\Start11\, кроме Start11Config и *Srv*
function Test-Start11Process {
    param([string]$Name, [string]$Path)
    if (-not $Path -or $Path -notlike '*\Stardock\Start11\*') { return $false }
    if ($Name -like 'Start11Config*' -or $Name -like '*Srv*') { return $false }
    return $true
}

# запуск без прав администратора (из повышенного процесса - через runas /trustlevel, как у проводника)
function Start-NonElevated {
    param([string]$Path)
    if (Test-Admin) {
        $runas = Join-Path $env:SystemRoot 'System32\runas.exe'
        Start-Process -FilePath $runas -ArgumentList ('/trustlevel:0x20000 "' + $Path + '"') -WindowStyle Hidden
    } else {
        Start-Process -FilePath $Path -WorkingDirectory ([IO.Path]::GetDirectoryName($Path))
    }
}

# Находим процессы Start11 (кроме Start11Config и *Srv*), запоминаем пути, завершаем (Stop-Process = Kill: настройки
# в реестре он при этом не перезаписывает) и запускаем снова. Не вышло - Ok=$false и Message = что сказать пользователю.
# Закрыть Start11 (до записи в реестр, чтобы он не перезаписал плитки из памяти). Возвращает пути для повторного запуска.
function Stop-Start11 {
    $r = [pscustomobject]@{ Ok = $true; Paths = (New-Object 'System.Collections.Generic.List[string]') }
    try {
        $procs = @(Get-Start11Processes)
        $ids = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                $ids.Add([int]$p.Id)
                if (-not ($r.Paths | Where-Object { $_ -ieq $p.Path })) { $r.Paths.Add([string]$p.Path) }
            } catch { $r.Ok = $false; Write-Log "  Start11: не удалось завершить $($p.Name): $($_.Exception.Message)" }
        }
        for ($i = 0; $i -lt 25; $i++) {
            if (@($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }
    } catch { $r.Ok = $false; Write-Log ('Start11: ' + $_.Exception.Message) }
    return $r
}

function Start-Start11Paths($Paths) {
    $ok = $true
    foreach ($path in @($Paths)) {
        try { Start-NonElevated $path; Write-Log "  Start11 запущен снова: $path" } catch { $ok = $false; Write-Log "  Start11: не удалось запустить $path : $($_.Exception.Message)" }
    }
    return $ok
}

function Restart-Start11 {
    $res = [pscustomobject]@{ Ok = $false; Found = 0; Message = $script:SI_S11Hint }
    $stoppedPaths = New-Object 'System.Collections.Generic.List[string]'
    $allOk = $true
    try {
        $procs = @(Get-Start11Processes)
        $res.Found = $procs.Count
        if ($procs.Count -eq 0) { Write-Log 'Start11 не запущен или не найден среди процессов.'; return $res }
        $stopped = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in $procs) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                $stopped.Add([int]$p.Id)
                if (-not ($stoppedPaths | Where-Object { $_ -ieq $p.Path })) { $stoppedPaths.Add([string]$p.Path) }
            } catch { $allOk = $false; Write-Log "  Start11: не удалось завершить $($p.Name): $($_.Exception.Message)" }
        }
        for ($i = 0; $i -lt 25; $i++) {
            $alive = @($stopped | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
            if ($alive.Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }
    } catch {
        $allOk = $false
        Write-Log ('Start11: ' + $_.Exception.Message)
    }
    foreach ($path in $stoppedPaths) {      # что завершили - обязательно запускаем обратно, даже если что-то пошло не так
        try { Start-NonElevated $path; Write-Log "  Start11 запущен снова: $path" } catch { $allOk = $false; Write-Log "  Start11: не удалось запустить $path : $($_.Exception.Message)" }
    }
    if ($allOk -and $stoppedPaths.Count -gt 0) { $res.Ok = $true; $res.Message = '' }
    return $res
}

function Apply-Start11Tiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Items, [switch]$NoName, [switch]$NoReload)
    Assert-ElevationSafe
    $none = [pscustomobject]@{ Changed = 0; Same = 0; Failed = 0; Total = 0; Reload = $null; Hint = '' }
    if (-not (Test-Start11)) { Write-Log 'Start11 не найден - плитки пропускаю.'; return $none }
    Write-Log "Применяю плитки Start11: $($Pack.Name) $($Pack.Version)"
    if ($null -eq $Items) { $Items = @(Get-Start11Matches -Pack $Pack -NoName:$NoName) }
    $backup = Load-S11Backup           # не читается - исключение до любых изменений, исходные значения не потеряем
    $changed = 0; $same = 0; $failed = 0
    # есть что менять -> сначала закрываем Start11, пишем реестр, потом запускаем обратно
    $needs = @($Items | Where-Object {
        try { -not (Test-Start11TileSet ([string]$_.TileId) (Get-Start11TileDest ([string]$Pack.Id) ([string]$_.IconId)) ([string]$_.TilePath)) } catch { $true } })
    $stop = $null; $restarted = $true
    if ($needs.Count -gt 0 -and -not $NoReload) { $stop = Stop-Start11 }
    try {
    foreach ($m in @($Items)) {
        try {
            $id = [string]$m.TileId; $src = [string]$m.TilePath; $icId = [string]$m.IconId
            if (-not $id -or $icId -notmatch '^[A-Za-z0-9_\-]+$') { throw 'неверные данные плитки' }
            if ($src -notmatch '\.png$' -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "нет файла плитки $src" }
            $dest = Get-Start11TileDest ([string]$Pack.Id) $icId
            if (Test-Start11TileSet $id $dest $src) { $same++; continue }
            $cur = Get-S11Value $script:SI_S11Tiles $id                    # не REG_SZ - исключение, значение не трогаем
            Save-FileAtomic $dest ([IO.File]::ReadAllBytes($src))
            if (-not $backup.ContainsKey($id)) {                           # первый оригинал храним, пока не откатим
                $backup[$id] = [pscustomobject]@{ Absent = ($null -eq $cur); Data = $cur }
                Save-S11Backup $backup
            }
            Set-S11Value $script:SI_S11Tiles $id $dest
            if ((Get-S11Value $script:SI_S11Tiles $id) -ine $dest) { throw 'значение в реестре не записалось' }
            $changed++
            Write-Log "  OK $id  <-  $($m.IconName)"
        } catch {
            $failed++
            Write-Log "  ошибка с плиткой $($m.TileId): $($_.Exception.Message)"
        }
    }
    } finally {
        if ($stop) { $restarted = (Start-Start11Paths $stop.Paths) }
    }
    $st = Read-State
    if ($changed -gt 0 -or $same -gt 0) {
        $st['Tiles'] = @{ PackId = $Pack.Id; Version = $Pack.Version; At = (Get-Date).ToString('s'); Count = ($changed + $same) }
        Save-State $st
    }
    Write-Log "Плитки Start11: заменено $changed, уже стояли $same, ошибок $failed"
    $reload = $null; $hint = ''
    if ($changed -gt 0) {
        if ($NoReload) { $hint = $script:SI_S11Hint }
        else {
            $okAll = ($stop -and $stop.Ok -and $stop.Paths.Count -gt 0 -and $restarted)
            $reload = [pscustomobject]@{ Ok = [bool]$okAll; Found = $(if ($stop) { $stop.Paths.Count } else { 0 }); Message = $(if ($okAll) { '' } else { $script:SI_S11Hint }) }
            if (-not $okAll) { $hint = $script:SI_S11Hint; Write-Log $hint }
        }
    }
    return [pscustomobject]@{ Changed = $changed; Same = $same; Failed = $failed; Total = @($Items).Count; Reload = $reload; Hint = $hint }
}

# Откат плиток: возвращаем ровно то, что сохранено (значение или его отсутствие). PNG удаляем только когда всё вернулось.
function Undo-Start11Tiles {
    [CmdletBinding()]
    param([switch]$NoReload)
    Assert-ElevationSafe
    $backup = Load-S11Backup
    if ($backup.Count -eq 0) { return [pscustomobject]@{ Restored = 0; Failed = 0; Nothing = $true; Reload = $null; Hint = '' } }
    $n = 0; $failed = 0
    foreach ($id in @($backup.Keys)) {
        $e = $backup[$id]
        try {
            if ($e.Absent) { Remove-S11Value $script:SI_S11Tiles $id } else { Set-S11Value $script:SI_S11Tiles $id ([string]$e.Data) }
            $backup.Remove($id); $n++
            Write-Log "  плитка возвращена: $id"
        } catch { $failed++; Write-Log "  ошибка с плиткой $id : $($_.Exception.Message)" }
    }
    Save-S11Backup $backup
    $reload = $null; $hint = ''
    if ($n -gt 0) {
        if ($NoReload) { $hint = $script:SI_S11Hint }
        else {
            $reload = Restart-Start11
            if (-not $reload.Ok) { $hint = $script:SI_S11Hint; Write-Log $hint }
        }
    }
    if ($failed -eq 0) { Remove-Start11Files }
    $st = Read-State
    if ($failed -eq 0 -and $st.ContainsKey('Tiles')) { $st.Remove('Tiles'); Save-State $st }
    Write-Log "Плитки Start11 возвращены: $n$(if ($failed -gt 0) { ', не удалось: ' + $failed })"
    return [pscustomobject]@{ Restored = $n; Failed = $failed; Nothing = $false; Reload = $reload; Hint = $hint }
}

function Remove-Start11Files {
    try { if (Test-Path -LiteralPath $script:SI_S11Dir) { Remove-Item -LiteralPath $script:SI_S11Dir -Recurse -Force } } catch { Write-Log "start11 не удалена: $($_.Exception.Message)" }
}

function Remove-CopyQuiet {
    param([string]$Copy)
    try { if ($Copy -and (Test-Path -LiteralPath $Copy)) { Remove-Item -LiteralPath $Copy -Force } } catch { }
}

# Откат: .lnk - возвращаем только иконку (Set-LinkIcon), удалённые ярлыки не воскрешаем; .ico - копируем обратно.
# Каждая запись сначала проходит Test-BackupEntry; отклонённые записи выбрасываются из индекса, файлы по ним не трогаются.
function Undo-All {
    [CmdletBinding()]
    param([switch]$RestartExplorer, [switch]$NoReload)
    Assert-ElevationSafe
    $backup = Load-Backup
    $s11 = 0
    try { $s11 = (Load-S11Backup).Count } catch { $s11 = 1; Write-Log ('start11.json не прочитан: ' + $_.Exception.Message) }
    if ($backup.Count -eq 0 -and $s11 -eq 0) {
        Write-Log 'Бэкапа нет - восстанавливать нечего.'
        return [pscustomobject]@{ Restored = 0; Failed = 0; Skipped = 0; Nothing = $true; TilesRestored = 0; Hint = '' }
    }
    $n = 0; $failed = 0; $skipped = 0
    foreach ($path in @($backup.Keys)) {
        $e = $backup[$path]
        $copy = [string]$e.Copy
        $bad = Test-BackupEntry $path $copy
        if ($bad) { Write-Log "  запись бэкапа отклонена ($bad): $path"; $backup.Remove($path); $skipped++; continue }
        try {
            if ([IO.Path]::GetExtension($path) -ieq '.lnk') {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                    Write-Log "  ярлык удалён, не воскрешаю: $(Get-BaseNameSafe $path)"
                    Remove-CopyQuiet $copy; $backup.Remove($path); $skipped++; continue
                }
                $loc = $e.Icon
                if ($null -eq $loc) {      # старая запись v2: исходную иконку берём из сохранённой копии ярлыка
                    if (-not (Test-Path -LiteralPath $copy)) { Write-Log "  нет копии для $path - пропускаю"; $backup.Remove($path); $skipped++; continue }
                    $loc = [string](Get-WshShell).CreateShortcut($copy).IconLocation
                }
                $sp = Split-IconLocation $loc
                [void](Set-LinkIcon $path $sp.Path $sp.Index)
            } else {
                if (-not (Test-Path -LiteralPath $copy)) { Write-Log "  нет копии для $path - пропускаю"; $backup.Remove($path); $skipped++; continue }
                if (-not (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)))) { Write-Log "  папки больше нет, пропускаю: $path"; Remove-CopyQuiet $copy; $backup.Remove($path); $skipped++; continue }
                Copy-Item -LiteralPath $copy -Destination $path -Force
            }
            Remove-CopyQuiet $copy
            Send-ItemNotify $path
            $backup.Remove($path); $n++
            Write-Log "  возвращён: $(Get-BaseNameSafe $path)"
        } catch { $failed++; Write-Log "  ошибка с $path : $($_.Exception.Message)" }
    }
    Save-Backup $backup
    $tilesRestored = 0; $hint = ''; $tileFailed = 0
    if ($s11 -gt 0) {       # плитки Start11 возвращаем тоже (значения реестра, потом PNG)
        try {
            $tr = Undo-Start11Tiles -NoReload:$NoReload
            $tilesRestored = [int]$tr.Restored; $tileFailed = [int]$tr.Failed; $hint = [string]$tr.Hint
        } catch { $tileFailed = 1; Write-Log ('Плитки Start11 не возвращены: ' + $_.Exception.Message) }
    }
    $failed += $tileFailed
    $st = Read-State
    if ($st.ContainsKey('Applied') -and $failed -eq 0) { $st.Remove('Applied'); Save-State $st }
    $tail = if ($failed -gt 0) { ", не удалось: $failed (для общих ярлыков отметьте «Также общие ярлыки» - нужны права администратора)" } else { '' }
    Write-Log "Восстановлено: $n$tail"
    if ($n -gt 0) { Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true }
    return [pscustomobject]@{ Restored = $n; Failed = $failed; Skipped = $skipped; Nothing = $false; TilesRestored = $tilesRestored; Hint = $hint }
}

# Запуск этого же скрипта (CLI) с повышением прав (UAC) на одно действие; ждём завершения.
function Invoke-ElevatedCli {
    param([string[]]$CliArgs)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $script:SI_CodeDir 'ShadowIcons.ps1'
    $tmpDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $script)) + @($CliArgs)
    Write-Log ('Запрашиваю права администратора для одного действия: ' + ($CliArgs -join ' '))
    try {
        $p = Start-Process -FilePath $ps -ArgumentList $a -Verb RunAs -WindowStyle Hidden -WorkingDirectory $tmpDir -PassThru
    } catch {
        Write-Log ('Повышение прав не выполнено: ' + $_.Exception.Message)
        return [pscustomobject]@{ Started = $false; Cancelled = $true; ExitCode = -1 }
    }
    $p.WaitForExit()
    return [pscustomobject]@{ Started = $true; Cancelled = $false; ExitCode = [int]$p.ExitCode }
}

# ---------- Старая версия (автозапуск v2) ----------
function Remove-Legacy {
    $removed = New-Object 'System.Collections.Generic.List[string]'
    try {
        $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'TaskbarIcons.lnk'
        if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force; $removed.Add($lnk); Write-Log "Удалён автозапуск: $lnk" }
    } catch { Write-Log "Автозапуск не удалён: $($_.Exception.Message)" }
    try {
        if (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue) {
            $task = Get-ScheduledTask -TaskName 'ShadowIcons' -ErrorAction SilentlyContinue
            if ($task) {
                Unregister-ScheduledTask -TaskName 'ShadowIcons' -Confirm:$false -ErrorAction Stop
                $removed.Add('ScheduledTask:ShadowIcons'); Write-Log 'Удалена задача планировщика ShadowIcons'
            }
        }
    } catch { Write-Log "Задача планировщика не удалена: $($_.Exception.Message)" }
    try {
        $vbs = Join-Path $script:SI_Home 'run-hidden.vbs'
        if (Test-Path -LiteralPath $vbs) { Remove-Item -LiteralPath $vbs -Force; $removed.Add($vbs); Write-Log "Удалён $vbs" }
    } catch { Write-Log "run-hidden.vbs не удалён: $($_.Exception.Message)" }
    return $removed.ToArray()
}

# ---------- Ярлыки приложения и удаление ----------
function Get-AppShortcutPaths {
    return @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Shadow Icons.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Shadow Icons.lnk')
    )
}

function Install-AppShortcuts {
    $wsh = Get-WshShell
    $vbs = Join-Path $script:SI_AppDir 'launch.vbs'
    $ico = Join-Path (Join-Path $script:SI_AppDir 'assets') 'app.ico'
    foreach ($p in (Get-AppShortcutPaths)) {
        try {
            $d = [IO.Path]::GetDirectoryName($p)
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $sc = $wsh.CreateShortcut($p)
            $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $sc.Arguments = '"' + $vbs + '"'
            $sc.WorkingDirectory = $script:SI_AppDir
            $sc.IconLocation = "$ico,0"
            $sc.Description = 'Shadow Icons'
            $sc.Save()
            Write-Log "Ярлык: $p"
        } catch { Write-Log "Не удалось создать ярлык $p : $($_.Exception.Message)" }
    }
}

function Uninstall-App {
    [CmdletBinding()]
    param([switch]$RestartExplorer, [switch]$NoReload)
    Assert-ElevationSafe
    Write-Log 'Удаляю приложение...'
    $u = $null
    try { if ($NoReload) { $u = Undo-All -RestartExplorer:$RestartExplorer -NoReload } else { $u = Undo-All -RestartExplorer:$RestartExplorer } } catch { Write-Log "Откат не выполнен: $($_.Exception.Message)" }
    if (-not $u -or $u.Failed -gt 0) {      # откат не удался (или результата нет) - ничего не удаляем, иначе потеряем бэкап
        $msg = 'Не все иконки удалось вернуть - приложение не удалено, бэкап сохранён. Исправьте причину (см. журнал; для общих ярлыков отметьте «Также общие ярлыки») и повторите.'
        Write-Log $msg
        return [pscustomobject]@{ Ok = $false; KeptBackup = $true; Aborted = $true; Message = $msg }
    }
    Remove-Start11Files       # PNG плиток - только теперь, когда значения реестра уже возвращены (иначе плитки остались бы без картинок)
    # не держим папку приложения/данных текущей: иначе её не удалить
    $tmpDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    try { [Environment]::CurrentDirectory = $tmpDir } catch { }
    try { Set-Location -LiteralPath $tmpDir } catch { }
    [void](Remove-Legacy)
    foreach ($p in (Get-AppShortcutPaths)) {
        try { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Log "Удалён ярлык: $p" } } catch { Write-Log "Ярлык не удалён: $p" }
    }
    try { if (Test-Path -LiteralPath $script:SI_StateFile) { Remove-Item -LiteralPath $script:SI_StateFile -Force } } catch { }
    try { if (Test-Path -LiteralPath $script:SI_PacksDir) { Remove-Item -LiteralPath $script:SI_PacksDir -Recurse -Force } } catch { Write-Log "packs не удалён: $($_.Exception.Message)" }
    $appRemoved = $true
    try {
        if (Test-Path -LiteralPath $script:SI_AppDir) { Remove-Item -LiteralPath $script:SI_AppDir -Recurse -Force }
    } catch {
        $appRemoved = $false
        try {   # файлы заняты (мы из них запущены) - дочищаем после завершения процесса
            $cmd = 'ping -n 4 127.0.0.1 >nul & rmdir /s /q "' + $script:SI_AppDir + '" & rmdir "' + $script:SI_Home + '"'
            Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmd) -WindowStyle Hidden -WorkingDirectory $tmpDir
            $appRemoved = $true
        } catch { Write-Log "Папка приложения не удалена: $($_.Exception.Message)" }
    }
    Write-Log 'Приложение удалено.'
    $script:SI_NoLogFile = $true
    try { if (Test-Path -LiteralPath $script:SI_LogFile) { Remove-Item -LiteralPath $script:SI_LogFile -Force } } catch { }
    try { if (Test-Path -LiteralPath ($script:SI_LogFile + '.old')) { Remove-Item -LiteralPath ($script:SI_LogFile + '.old') -Force } } catch { }
    try { if ((Test-Path -LiteralPath $script:SI_Home) -and -not (Get-ChildItem -LiteralPath $script:SI_Home -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $script:SI_Home -Force } } catch { }
    return [pscustomobject]@{ Ok = $appRemoved; KeptBackup = $false; Aborted = $false; Message = '' }
}
