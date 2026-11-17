<#
  Glyphix - движок (Windows PowerShell 5.1, без модулей).
  Подключается точкой: . .\Engine.ps1
  Данные: %LOCALAPPDATA%\Glyphix  (app\, packs\<id>\, backup\, start11\, state.json, log.txt)
  Данные прежней версии (%LOCALAPPDATA%\ShadowIcons) один раз переносятся функцией Invoke-LegacyMigration.
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
$script:SI_BaseUrl = 'https://raw.githubusercontent.com/F1KS-FK/glyphix/main/'
# Под администратором переменную GLYPHIX_HOME игнорируем: повышенный процесс не должен писать куда указал окружением кто-то другой.
$script:SI_Home = if ($env:GLYPHIX_HOME -and -not (Test-Admin)) { $env:GLYPHIX_HOME } else { Join-Path $env:LOCALAPPDATA 'Glyphix' }
$script:SI_OldHome = Join-Path $env:LOCALAPPDATA 'ShadowIcons'                       # папка данных прежней версии (Shadow Icons)
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
    if (-not ('GlyphixNative.Shell' -as [type])) {
        Add-Type -Namespace GlyphixNative -Name Shell -MemberDefinition @'
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
        return 'Не удалось определить, чей рабочий стол открыт (владелец проводника). Запустите Glyphix обычным образом, без прав администратора, и отметьте «Также общие ярлыки».'
    }
    if ($me -ne $own) {
        return 'Glyphix запущен от другой учётной записи администратора: изменения затронули бы не ваш рабочий стол. Закройте окно и запустите программу от своего пользователя; права администратора запрашиваются галочкой «Также общие ярлыки».'
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
    $req.UserAgent = 'Glyphix/' + (Get-AppVersion)
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

# Список файлов пака из pack.json: иконки (.ico/.png) и плитки Start11 (обычная и без подписи); у каждого файла свой sha256.
# Небезопасный путь - исключение (такой pack.json не принимается и не сохраняется).
function Get-PackFileList {
    param([string]$PackDir, [string]$PackUrl, $Manifest)
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ic in @($Manifest.icons)) {
        $icId = [string]$ic.id
        if ($icId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск иконки с неверным id '$icId'"; continue }
        foreach ($pair in @(@('ico', '.ico'), @('png', '.png'))) {
            $rel = [string]$ic.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel @($pair[1]))) { throw "недопустимый путь файла '$rel'" }
            $list.Add([pscustomobject]@{ Rel = $rel; Url = ($PackUrl + $rel); Dest = (Join-Rel $PackDir $rel); Sha = [string]$ic.($pair[0] + '_sha256'); Ext = $pair[1] })
        }
    }
    foreach ($tl in @($Manifest.tiles)) {
        if (-not $tl) { continue }
        $tId = [string]$tl.id
        if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск плитки с неверным id '$tId'"; continue }
        foreach ($pair in @(@('file', 'sha256'), @('file_noname', 'sha256_noname'))) {
            $rel = [string]$tl.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel @('.png'))) { throw "недопустимый путь файла '$rel'" }
            $list.Add([pscustomobject]@{ Rel = $rel; Url = ($PackUrl + $rel); Dest = (Join-Rel $PackDir $rel); Sha = [string]$tl.($pair[1]); Ext = '.png' })
        }
    }
    return $list.ToArray()
}

# Скачать недостающие/изменённые файлы списка (каждый проверяется по sha256). Прогресс - строки журнала «Скачиваю <пак>: i/n»
# (GUI показывает их в строке состояния). Возвращает число скачанных файлов.
function Sync-PackFiles {
    param($Files, [string]$Label, [switch]$Force)
    $todo = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in @($Files)) {
        $sha = ([string]$f.Sha).ToLowerInvariant()
        if ($sha -notmatch '^[0-9a-f]{64}$') { throw "нет корректного sha256 для $($f.Dest)" }
        $have = $false
        if (-not $Force -and (Test-Path -LiteralPath $f.Dest -PathType Leaf)) { try { $have = ((Get-FileSha256 $f.Dest) -eq $sha) } catch { } }
        if (-not $have) { $todo.Add($f) }
    }
    $n = $todo.Count; $i = 0
    if ($n -gt 0) { Write-Log "Скачиваю ${Label}: файлов $n" }
    $step = [Math]::Max(1, [int][Math]::Floor($n / 20))
    foreach ($f in $todo) {
        [void](Sync-File $f.Url $f.Dest ([string]$f.Sha) $f.Ext -Force)
        $i++
        if ($i -eq $n -or ($i % $step) -eq 0) { Write-Log "Скачиваю ${Label}: $i/$n" }
    }
    return $n
}

# pack.json и превью пака (иконки и плитки здесь НЕ качаем - см. Install-Pack); возвращает число скачанных файлов
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
    [void](Get-PackFileList $packDir $packUrl $man)          # пути файлов проверяем до сохранения pack.json

    $prevRel = [string]$man.preview
    if ($prevRel -and $Entry.preview_sha256) {
        if (-not (Test-SafeRel $prevRel @('.png'))) { throw "недопустимый preview '$prevRel'" }
        $downloaded += (Sync-File ($packUrl + $prevRel) (Join-Rel $packDir $prevRel) ([string]$Entry.preview_sha256) '.png' -Force:$Force)
    }
    # pack.json пишем последним: если что-то оборвалось, следующая проверка догрузит остальное
    if ($needManifest) { Save-FileAtomic $manLocal $manBytes; $downloaded++ }
    return $downloaded
}

# Файлы пака на диске: 'ready' - всё на месте и проверено по текущему pack.json (метка .synced);
# 'stale' - файлы на месте, но не проверены (pack.json обновился / кэш перенесён из прежней версии); 'none' - чего-то не хватает
function Get-PackState {
    param([string]$PackDir, [string[]]$Files)
    foreach ($f in @($Files)) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return 'none' } }
    try {
        $mk = Join-Path $PackDir '.synced'
        if (Test-Path -LiteralPath $mk -PathType Leaf) {
            if (([IO.File]::ReadAllText($mk)).Trim() -eq (Get-FileSha256 (Join-Path $PackDir 'pack.json'))) { return 'ready' }
        }
    } catch { }
    return 'stale'
}

# Скачать иконки и плитки ОДНОГО пака (по требованию: при «Применить» или «Скачать»). Сначала сверяем pack.json с index.json
# (пак мог обновиться), потом качаем только недостающие/изменённые файлы; каждый - с проверкой sha256. Ошибка сети/sha - исключение.
function Install-Pack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$BaseUrl = $script:SI_BaseUrl, [switch]$Force)
    if ($Id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { throw "недопустимый id пака '$Id'" }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }
    if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
    $idx = ConvertFrom-JsonBytes (Get-WebBytes ($BaseUrl + 'index.json') 1048576)
    $entry = @($idx.packs) | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
    if (-not $entry) { throw "пака '$Id' нет в index.json" }
    $d0 = Update-OnePack $BaseUrl $entry ([bool]$Force)
    $packDir = Join-Path $script:SI_PacksDir $Id
    $man = Read-JsonFile (Join-Path $packDir 'pack.json')
    $files = @(Get-PackFileList $packDir ($BaseUrl + ([string]$entry.path).Trim('/') + '/') $man)
    $label = if ($man.name) { [string]$man.name } else { $Id }
    $n = Sync-PackFiles $files $label -Force:$Force
    [IO.File]::WriteAllText((Join-Path $packDir '.synced'), (Get-FileSha256 (Join-Path $packDir 'pack.json')), (New-Object System.Text.UTF8Encoding($false)))
    Write-Log $(if ($n -gt 0) { "Пак ${label}: скачано файлов $n" } else { "Пак ${label}: все файлы на месте" })
    return [pscustomobject]@{ Id = $Id; Downloaded = ($n + $d0); Files = $files.Count }
}

# Перед применением: файлы пака не скачаны / не проверены - скачиваем (только этот пак). Всё на месте, но сети нет - работаем из кэша.
function Confirm-PackFiles {
    param($Pack)
    if (-not $Pack -or -not $Pack.PSObject.Properties['Dir'] -or -not $Pack.PSObject.Properties['Files']) { return }
    $state = Get-PackState ([string]$Pack.Dir) @($Pack.Files)
    if ($state -eq 'ready') { return }
    try {
        [void](Install-Pack -Id ([string]$Pack.Id))
    } catch {
        if ($state -eq 'stale') { Write-Log ('Не удалось проверить файлы пака (' + $_.Exception.Message + ') - использую сохранённые'); return }
        throw
    }
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
    $idxBytes = $null
    try {
        $idxBytes = Get-WebBytes ($BaseUrl + 'index.json') 1048576
        $idx = ConvertFrom-JsonBytes $idxBytes
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
    try { Save-FileAtomic (Join-Path $script:SI_PacksDir 'index.json') $idxBytes } catch { Write-Log ('index.json не сохранён: ' + $_.Exception.Message) }   # порядок паков в галерее
    # на каждом запуске - только index.json, pack.json и превью всех паков; иконки и плитки - по требованию (Install-Pack)
    $entries = @($idx.packs)
    $i = 0
    foreach ($entry in $entries) {
        $i++
        $pid2 = [string]$entry.id
        Write-Log "Проверяю паки: $i/$($entries.Count) ($pid2)"
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
    $msg = if ($errors.Count -gt 0) { "Обновление завершено с ошибками: $($errors.Count)" } elseif ($total -gt 0) { "Паки обновлены (файлов: $total)" } else { 'Все паки актуальны' }
    Write-Log $msg
    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Downloaded = $total; Updated = $updated.ToArray(); Errors = $errors.ToArray(); Message = $msg }
}

# ---------- Локальные паки ----------
# Паки читаются из pack.json (он есть у всех паков после Update-Packs); сами файлы иконок могут быть ещё не скачаны.
# Поэтому пути IcoPath/PngPath/TilePath - «где файл должен лежать», State - 'ready' | 'stale' | 'none' (см. Get-PackState).
function Get-Packs {
    $res = New-Object 'System.Collections.Generic.List[object]'
    if (-not (Test-Path -LiteralPath $script:SI_PacksDir)) { return @() }
    $order = @{}
    try {
        $ixf = Join-Path $script:SI_PacksDir 'index.json'
        if (Test-Path -LiteralPath $ixf) { $k = 0; foreach ($e in @((Read-JsonFile $ixf).packs)) { $order[[string]$e.id] = $k; $k++ } }
    } catch { }
    foreach ($d in (Get-ChildItem -LiteralPath $script:SI_PacksDir -Directory -ErrorAction SilentlyContinue)) {
        $mf = Join-Path $d.FullName 'pack.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $j = Read-JsonFile $mf
            $id = [string]$j.id
            if ($id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { continue }
            $files = New-Object 'System.Collections.Generic.List[string]'
            $tileMap = @{}
            foreach ($tl in @($j.tiles)) {
                if (-not $tl) { continue }
                $tId = [string]$tl.id
                if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { continue }
                $tp = $null; $tn = $null
                if ($tl.file -and (Test-SafeRel ([string]$tl.file) @('.png'))) { $tp = Join-Rel $d.FullName ([string]$tl.file); $files.Add($tp) }
                if ($tl.file_noname -and (Test-SafeRel ([string]$tl.file_noname) @('.png'))) { $tn = Join-Rel $d.FullName ([string]$tl.file_noname); $files.Add($tn) }
                if ($tp -or $tn) { $tileMap[$tId] = @{ Tile = $tp; NoName = $tn } }
            }
            $icons = New-Object 'System.Collections.Generic.List[object]'
            foreach ($ic in @($j.icons)) {
                if (-not $ic.ico -or -not (Test-SafeRel ([string]$ic.ico) @('.ico'))) { continue }
                $ico = Join-Rel $d.FullName ([string]$ic.ico)
                $files.Add($ico)
                $png = $null
                if ($ic.png -and (Test-SafeRel ([string]$ic.png) @('.png'))) { $png = Join-Rel $d.FullName ([string]$ic.png); $files.Add($png) }
                $mn = @(); $mx = @()
                if ($ic.match) { $mn = @($ic.match.names | ForEach-Object { [string]$_ }); $mx = @($ic.match.exes | ForEach-Object { [string]$_ }) }
                $tilePath = $null; $tileNoName = $null
                if ($tileMap.ContainsKey([string]$ic.id)) { $tilePath = $tileMap[[string]$ic.id].Tile; $tileNoName = $tileMap[[string]$ic.id].NoName }
                $icons.Add([pscustomobject]@{ Id = [string]$ic.id; Name = [string]$ic.name; Group = (Get-GroupKey $ic.group); IcoPath = $ico; PngPath = $png; Names = $mn; Exes = $mx; TilePath = $tilePath; TileNoNamePath = $tileNoName })
            }
            $prev = $null
            if ($j.preview -and (Test-SafeRel ([string]$j.preview) @('.png'))) {
                $pv = Join-Rel $d.FullName ([string]$j.preview)
                if (Test-Path -LiteralPath $pv) { $prev = $pv }
            }
            $fileArr = $files.ToArray()
            $state = Get-PackState $d.FullName $fileArr
            $res.Add([pscustomobject]@{
                Id = $id; Name = [string]$j.name; Version = [string]$j.version; Author = [string]$j.author
                License = [string]$j.license; Description = [string]$j.description
                IconCount = $icons.Count; Dir = $d.FullName; Preview = $prev; Icons = $icons.ToArray()
                Files = $fileArr; State = $state; Ready = ($state -eq 'ready')
            })
        } catch { Write-Log "пак $($d.Name) не прочитан: $($_.Exception.Message)" }
    }
    return @($res | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Id)) { [int]$order[$_.Id] } else { 1000 } } }, @{ Expression = { $_.Name } })
}

# ---------- Группы иконок (pack.json: icons[].group = apps | games | system | work | creative; необязательно) ----------
$script:SI_GroupOrder = @('apps', 'games', 'system', 'work', 'creative')

function Get-GroupKey {
    param($Group)
    $s = ([string]$Group).Trim().ToLowerInvariant()
    if ($s -notmatch '^[a-z0-9_\-]{1,32}$') { return '' }
    return $s
}

function Get-GroupRank {
    param([string]$Group)
    if (-not $Group) { return 99 }                                     # без группы - в конец
    $i = [Array]::IndexOf($script:SI_GroupOrder, $Group)
    if ($i -lt 0) { return 50 }                                        # незнакомая группа - после известных
    return $i
}

# Совпадения (ярлыки и плитки) -> группы в порядке apps, games, system, work, creative, прочие, без группы; внутри - по названию
function Get-MatchGroups {
    param($Matches2, $TileMatches)
    $by = @{}
    foreach ($m in @($Matches2)) {
        if (-not $m) { continue }
        $k = Get-GroupKey $m.Group
        if (-not $by.ContainsKey($k)) { $by[$k] = New-Object 'System.Collections.Generic.List[object]' }
        $by[$k].Add([pscustomobject]@{ Kind = 'link'; Title = [string]$m.Name; Item = $m })
    }
    foreach ($m in @($TileMatches)) {
        if (-not $m) { continue }
        $k = Get-GroupKey $m.Group
        if (-not $by.ContainsKey($k)) { $by[$k] = New-Object 'System.Collections.Generic.List[object]' }
        $by[$k].Add([pscustomobject]@{ Kind = 'tile'; Title = $(if ($m.Name) { [string]$m.Name } else { [string]$m.TileId }); Item = $m })
    }
    $out = foreach ($k in $by.Keys) {
        [pscustomobject]@{ Group = $k; Rank = (Get-GroupRank $k); Count = $by[$k].Count
            Rows = @($by[$k] | Sort-Object @{ Expression = { $_.Title } }, @{ Expression = { $_.Kind } }) }
    }
    return @($out | Sort-Object @{ Expression = { $_.Rank } }, @{ Expression = { $_.Group } })
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
                IconId = $m.Icon.Id; IconName = $m.Icon.Name; Group = [string]$m.Icon.Group; IcoPath = $m.Icon.IcoPath; PngPath = $m.Icon.PngPath
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
        if ($script:SI_OldHome -and (Test-PathUnder $full ([IO.Path]::GetFullPath($script:SI_OldHome)))) { return $false }   # папка прежней версии: иконки уже применённого пака
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
    try { [GlyphixNative.Shell]::SHChangeNotify(0x00002000, 0x0005, $Path, [IntPtr]::Zero) } catch { }   # SHCNE_UPDATEITEM, SHCNF_PATHW
}
function Send-AllNotify {
    try { [GlyphixNative.Shell]::SHChangeNotify(0x08000000, 0x0000, $null, [IntPtr]::Zero) } catch { }    # SHCNE_ASSOCCHANGED
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
    Assert-LegacyMigrationComplete               # бэкап прежней версии ещё не перенесён - не применяем
    Confirm-PackFiles $Pack                      # иконки пака качаем только сейчас (если ещё не скачаны)
    Write-Log "Применяю пак: $($Pack.Name) $($Pack.Version)"
    if ($null -eq $Items) { $Items = @(Get-Matches -Pack $Pack) }
    $backup = Load-Backup
    $changed = 0; $same = 0; $failed = 0
    foreach ($m in @($Items)) {
        try {
            if ($m.Already) { $same++; continue }
            if (-not (Test-Path -LiteralPath $m.IcoPath -PathType Leaf)) { throw "нет файла иконки $($m.IcoPath)" }
            Backup-File $backup $m.Path ([string]$m.Icon)
            $how = Set-LinkIcon $m.Path $m.IcoPath
            $after = [string](Get-WshShell).CreateShortcut($m.Path).IconLocation
            Send-ItemNotify $m.Path
            $changed++
            # приложение может пересоздать ярлык со своей иконкой - подменяем и сам .ico, на который он указывал
            if ($m.Icon -match '^(.+?),\s*(-?\d+)$') {
                $orig = [Environment]::ExpandEnvironmentVariables($Matches[1].Trim().Trim('"'))
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
    if ($failed -eq 0 -and ($changed + $same) -gt 0) { Invoke-LegacyCleanup }     # прежняя папка данных больше не нужна, если на неё не ссылается ни один ярлык
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

# вид значения ('String', 'ExpandString', 'DWord', ...) или $null, если значения нет
function Get-S11Kind {
    param([string]$Sub, [string]$Name)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
    if (-not $k) { return $null }
    try {
        if (@($k.GetValueNames()) -notcontains $Name) { return $null }
        return [string]$k.GetValueKind($Name)
    } finally { $k.Close() }
}

# строковое значение: $Kind = String (по умолчанию) или ExpandString
function Set-S11Value {
    param([string]$Sub, [string]$Name, [string]$Data, [string]$Kind = 'String')
    if ($Kind -ne 'String' -and $Kind -ne 'ExpandString') { $Kind = 'String' }
    $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Sub)
    try { $k.SetValue($Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() }
}

function Remove-S11Value {
    param([string]$Sub, [string]$Name)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $true)
    if (-not $k) { return }
    try { $k.DeleteValue($Name, $false) } finally { $k.Close() }
}

# имена значений одного подключа (без вложенных), без значения по умолчанию
function Get-S11ValueNames {
    param([string]$Sub)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
    if (-not $k) { return @() }
    try { return @($k.GetValueNames() | Where-Object { $_ } | ForEach-Object { [string]$_ }) } finally { $k.Close() }
}

function Test-Start11 {
    return [bool](Test-S11Key $script:SI_S11Root)
}

# --- id плитки и сопоставление ---
# Подключи Start8, где Start11 хранит id плиток (имена значений = id); остальное дерево Start8.ini не читаем
$script:SI_S11TileKeys = @('CustomTiles', 'CustomTilesText', 'CustomTilesIcon', 'CustomTilesPainting', 'CustomText')

# Приложения из Get-StartApps + имена значений из подключей Start8\CustomTiles*, CustomText
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
    foreach ($sk in $script:SI_S11TileKeys) {
        try { $names += @(Get-S11ValueNames ($script:SI_S11Root + '\Start8\' + $sk)) } catch { Write-Log ('чтение реестра Start11 (' + $sk + '): ' + $_.Exception.Message) }
    }
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

# слова, которые в id бывают издателем/общим словом, а не именем приложения (ключи уже без регистра и знаков)
$script:SI_PublisherWords = @('com', 'org', 'net', 'ru', 'io', 'microsoft', 'windows', 'google', 'app', 'apps', 'desktop', 'the')

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
    if ($s.Contains('!')) {                                             # AUMID: Имя.Пакета_хэш!App - берём только имя пакета (до '_' / '!')
        $pfn = $s.Substring(0, $s.IndexOf('!'))
        if ($pfn.Contains('_')) { $pfn = $pfn.Substring(0, $pfn.IndexOf('_')) }
        $tokens = @($pfn.Split([char[]]@('.', ' ')) | Where-Object { $_ })
    } elseif ($pathLike) {                                              # полный путь: смотрим только на имя файла
        $seg = @($s.Split([char[]]@('_', '\', '/')) | Where-Object { $_ })
        if ($seg.Count -gt 0) { $tokens = @(($seg[$seg.Count - 1]) -replace $extRx, '') }
    } else {
        $tokens = @(($s -replace $extRx, '').Split([char[]]@('.', '_', ' ')) | Where-Object { $_ })
    }
    $tokens = @($tokens | ForEach-Object { Get-Key $_ } | Where-Object { $_ })
    if ($tokens.Count -eq 0) { return $info }
    # Для точного сравнения берём только хвост id (последние 2 токена): ведущие токены - издатель (com.google.*, Microsoft.*)
    # и не должны давать совпадений. Порядок: оба токена вместе, последний, предпоследний (если это не слово-издатель).
    $keys = New-Object 'System.Collections.Generic.List[string]'
    $seen = @{}
    $n = $tokens.Count
    $cand = New-Object 'System.Collections.Generic.List[string]'
    if ($n -ge 2) { $cand.Add(($tokens[($n - 2)..($n - 1)]) -join '') }
    $cand.Add($tokens[$n - 1])
    if ($n -ge 2 -and ($script:SI_PublisherWords -notcontains $tokens[$n - 2])) { $cand.Add($tokens[$n - 2]) }
    foreach ($k in $cand) {
        foreach ($v in (@($k) + @(Get-StrippedKeys $k))) {
            if ($v -and -not $seen.ContainsKey($v)) { $seen[$v] = $true; $keys.Add($v) }
        }
    }
    $info.Keys = $keys.ToArray()
    $info.Last = $tokens[$n - 1]
    return $info
}

# доп. имена для сопоставления плиток (только в движке; pack.json не меняем): icon id -> ключи
$script:SI_TileAliases = @{ yandexmusic = @('yandexdesktopmusic', 'desktopmusic') }   # ru.yandex.desktop.music: от id остаются 2 последних токена

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
                IconId = [string]$m.Icon.Id; IconName = [string]$m.Icon.Name; Group = [string]$m.Icon.Group; TilePath = $src
                Rule = $m.Rule; Already = (Test-Start11TileSet ([string]$c.Id) $dest $src)
            })
        } catch { Write-Log "  ошибка сопоставления плитки $($c.Id): $($_.Exception.Message)" }
    }
    return $out.ToArray()
}

# --- бэкап значений CustomTiles: backup\start11.json = массив {Id, Absent, Data, Kind}; Absent = значения не было; Kind = String | ExpandString ---
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
            $kind = 'String'
            if ($e.PSObject.Properties['Kind'] -and [string]$e.Kind -eq 'ExpandString') { $kind = 'ExpandString' }     # старые записи без Kind - String
            $map[[string]$e.Id] = [pscustomobject]@{ Absent = $absent; Data = $(if ($absent) { $null } else { [string]$e.Data }); Kind = $kind }
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
    $arr = foreach ($k in $Map.Keys) { [pscustomobject]@{ Id = $k; Absent = [bool]$Map[$k].Absent; Data = $Map[$k].Data; Kind = $(if ($Map[$k].PSObject.Properties['Kind'] -and $Map[$k].Kind) { [string]$Map[$k].Kind } else { 'String' }) } }
    Save-JsonAtomic $script:SI_S11BackupFile (ConvertTo-Json -InputObject @($arr))
}

# --- перезапуск Start11, чтобы он перечитал плитки ---
# аргументы из командной строки процесса: всё после пути к exe (путь в кавычках или без)
function Get-CommandLineArgs {
    param([string]$CommandLine, [string]$Path)
    if (-not $CommandLine) { return '' }
    $c = $CommandLine.Trim()
    if ($c.StartsWith('"')) {
        $e = $c.IndexOf('"', 1)
        if ($e -lt 0) { return '' }
        return $c.Substring($e + 1).Trim()
    }
    if ($Path -and $c.StartsWith($Path, [StringComparison]::OrdinalIgnoreCase)) { return $c.Substring($Path.Length).Trim() }
    $sp = $c.IndexOf(' ')
    if ($sp -lt 0) { return '' }
    return $c.Substring($sp + 1).Trim()
}

# Id процесса -> командная строка (Win32_Process); без неё перезапускаем без аргументов
function Get-Start11CommandLines {
    $map = @{}
    try {
        foreach ($w in @(Get-CimInstance -ClassName Win32_Process -Filter "Name LIKE 'Start11%'" -ErrorAction Stop)) { $map[[int]$w.ProcessId] = [string]$w.CommandLine }
    } catch { Write-Log ('Start11: командная строка не прочитана: ' + $_.Exception.Message) }
    return $map
}

function Get-Start11Processes {
    $sid = (Get-Process -Id $PID).SessionId
    $cmds = $null
    foreach ($p in @(Get-Process -Name 'Start11*' -ErrorAction SilentlyContinue)) {
        $path = ''
        try {
            if ($p.SessionId -ne $sid) { continue }
            $path = [string]$p.MainModule.FileName
        } catch { continue }
        if (-not (Test-Start11Process ([string]$p.ProcessName) $path)) { continue }
        if ($null -eq $cmds) { $cmds = Get-Start11CommandLines }
        $cl = ''
        if ($cmds.ContainsKey([int]$p.Id)) { $cl = [string]$cmds[[int]$p.Id] }
        [pscustomobject]@{ Id = [int]$p.Id; Name = [string]$p.ProcessName; Path = $path; Args = (Get-CommandLineArgs $cl $path) }
    }
}

# процесс меню Start11, который нужно перезапускать: Start11*.exe в папке ...\Stardock\Start11\, кроме *Config*, *Update*, *Uninst* (и *Srv* - служебный)
function Test-Start11Process {
    param([string]$Name, [string]$Path)
    if (-not $Path -or $Path -notlike '*\Stardock\Start11\*') { return $false }
    $leaf = $Path.Substring($Path.LastIndexOfAny($script:SI_Seps) + 1)
    if ($leaf -notlike 'Start11*.exe') { return $false }
    if ($Name -notlike 'Start11*') { return $false }
    foreach ($bad in @('*Config*', '*Update*', '*Uninst*', '*Srv*')) { if ($Name -like $bad -or $leaf -like $bad) { return $false } }
    return $true
}

# запуск без прав администратора (из повышенного процесса - через runas /trustlevel, как у проводника)
function Start-NonElevated {
    param([string]$Path, [string]$Arguments = '')
    if (Test-Admin) {
        $runas = Join-Path $env:SystemRoot 'System32\runas.exe'
        $cmd = '/trustlevel:0x20000 "' + $Path + '"'
        if ($Arguments) { $cmd = '/trustlevel:0x20000 "\"' + $Path + '\" ' + $Arguments.Replace('"', '\"') + '"' }
        Start-Process -FilePath $runas -ArgumentList $cmd -WindowStyle Hidden
    } elseif ($Arguments) {
        Start-Process -FilePath $Path -ArgumentList $Arguments -WorkingDirectory ([IO.Path]::GetDirectoryName($Path))
    } else {
        Start-Process -FilePath $Path -WorkingDirectory ([IO.Path]::GetDirectoryName($Path))
    }
}

# Закрыть Start11 (до записи в реестр, чтобы он не перезаписал плитки из памяти; Stop-Process = Kill: настройки при этом не пишутся).
# Paths - уникальные пути exe; Launch - то же с аргументами командной строки для повторного запуска.
function Stop-Start11 {
    param($Procs = $null)
    $r = [pscustomobject]@{ Ok = $true; Paths = (New-Object 'System.Collections.Generic.List[string]'); Launch = (New-Object 'System.Collections.Generic.List[object]') }
    try {
        if ($null -eq $Procs) { $Procs = @(Get-Start11Processes) }
        $ids = New-Object 'System.Collections.Generic.List[int]'
        foreach ($p in @($Procs)) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction Stop
                $ids.Add([int]$p.Id)
                if (-not ($r.Paths | Where-Object { $_ -ieq $p.Path })) {
                    $r.Paths.Add([string]$p.Path)
                    $a = ''; if ($p.PSObject.Properties['Args'] -and $p.Args) { $a = [string]$p.Args }
                    $r.Launch.Add([pscustomobject]@{ Path = [string]$p.Path; Args = $a })
                }
            } catch { $r.Ok = $false; Write-Log "  Start11: не удалось завершить $($p.Name): $($_.Exception.Message)" }
        }
        for ($i = 0; $i -lt 25; $i++) {
            if (@($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue }).Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }
    } catch { $r.Ok = $false; Write-Log ('Start11: ' + $_.Exception.Message) }
    return $r
}

# Запуск обратно: элементы - строки-пути или {Path, Args}. Если процесс с таким путём уже запущен - не запускаем второй.
function Start-Start11Paths($Paths) {
    $ok = $true
    $running = @()
    try { $running = @(Get-Start11Processes | ForEach-Object { [string]$_.Path }) } catch { }
    if ($null -eq $Paths) { return $true }
    foreach ($item in $Paths) {
        $path = ''; $a = ''
        if ($item -is [string]) { $path = $item } else { $path = [string]$item.Path; $a = [string]$item.Args }
        if (-not $path) { continue }
        if ($running | Where-Object { $_ -ieq $path }) { Write-Log "  Start11 уже запущен, второй не запускаю: $path"; continue }
        try { Start-NonElevated $path $a; Write-Log "  Start11 запущен снова: $path" } catch { $ok = $false; Write-Log "  Start11: не удалось запустить $path : $($_.Exception.Message)" }
    }
    return $ok
}

function Restart-Start11 {
    $res = [pscustomobject]@{ Ok = $false; Found = 0; Message = $script:SI_S11Hint }
    $allOk = $true
    $stop = $null
    try {
        $procs = @(Get-Start11Processes)
        $res.Found = $procs.Count
        if ($procs.Count -eq 0) { Write-Log 'Start11 не запущен или не найден среди процессов.'; return $res }
        $stop = Stop-Start11 -Procs $procs
        if (-not $stop.Ok) { $allOk = $false }
    } catch {
        $allOk = $false
        Write-Log ('Start11: ' + $_.Exception.Message)
    }
    if ($stop) {     # что завершили - обязательно запускаем обратно, даже если что-то пошло не так
        if (-not (Start-Start11Paths $stop.Launch)) { $allOk = $false }
        if ($allOk -and $stop.Paths.Count -gt 0) { $res.Ok = $true; $res.Message = '' }
    }
    return $res
}

function Apply-Start11Tiles {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Items, [switch]$NoName, [switch]$NoReload)
    Assert-ElevationSafe
    Assert-LegacyMigrationComplete               # бэкап прежней версии ещё не перенесён - не применяем
    $none = [pscustomobject]@{ Changed = 0; Same = 0; Failed = 0; Total = 0; Reload = $null; Hint = '' }
    if (-not (Test-Start11)) { Write-Log 'Start11 не найден - плитки пропускаю.'; return $none }
    Confirm-PackFiles $Pack
    Write-Log "Применяю плитки Start11: $($Pack.Name) $($Pack.Version)"
    if ($null -eq $Items) { $Items = @(Get-Start11Matches -Pack $Pack -NoName:$NoName) }
    $backup = Load-S11Backup           # не читается - исключение до любых изменений, исходные значения не потеряем
    $changed = 0; $same = 0; $failed = 0
    # есть что менять -> сначала закрываем Start11, пишем реестр, потом запускаем обратно
    # значения не REG_SZ/REG_EXPAND_SZ не трогаем - ради них Start11 не закрываем
    $needs = @($Items | Where-Object {
        try {
            $kind = Get-S11Kind $script:SI_S11Tiles ([string]$_.TileId)
            if ($kind -and $kind -ne 'String' -and $kind -ne 'ExpandString') { return $false }
            -not (Test-Start11TileSet ([string]$_.TileId) (Get-Start11TileDest ([string]$Pack.Id) ([string]$_.IconId)) ([string]$_.TilePath))
        } catch { $true } })
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
            $curKind = 'String'
            if ($null -ne $cur) { $k0 = Get-S11Kind $script:SI_S11Tiles $id; if ($k0 -eq 'ExpandString') { $curKind = 'ExpandString' } }
            Save-FileAtomic $dest ([IO.File]::ReadAllBytes($src))
            if (-not $backup.ContainsKey($id)) {                           # первый оригинал храним, пока не откатим
                $backup[$id] = [pscustomobject]@{ Absent = ($null -eq $cur); Data = $cur; Kind = $curKind }
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
        if ($stop) { $restarted = (Start-Start11Paths $stop.Launch) }
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

# Откат плиток: возвращаем ровно то, что сохранено (значение того же вида или его отсутствие). Как и при применении:
# сначала закрываем Start11, пишем реестр, в finally запускаем обратно. PNG и start11.json удаляем только когда всё вернулось
# и Start11 либо корректно перезапущен, либо вообще не запущен; при -NoReload и работающем Start11 оставляем их (Kept = $true).
function Undo-Start11Tiles {
    [CmdletBinding()]
    param([switch]$NoReload)
    Assert-ElevationSafe
    $backup = Load-S11Backup
    if ($backup.Count -eq 0) { return [pscustomobject]@{ Restored = 0; Failed = 0; Nothing = $true; Kept = $false; Reload = $null; Hint = '' } }
    $n = 0; $failed = 0
    $stop = $null; $restarted = $true; $running = $false
    if ($NoReload) {
        try { $running = (@(Get-Start11Processes).Count -gt 0) } catch { $running = $true }
    } else {
        $stop = Stop-Start11
    }
    try {
        foreach ($id in @($backup.Keys)) {
            $e = $backup[$id]
            try {
                if ($e.Absent) { Remove-S11Value $script:SI_S11Tiles $id } else { Set-S11Value $script:SI_S11Tiles $id ([string]$e.Data) ([string]$e.Kind) }
                $n++
                Write-Log "  плитка возвращена: $id"
                if ($running) { continue }       # Start11 работает и не закрыт: значения вернули, но бэкап оставляем
                $backup.Remove($id)
            } catch { $failed++; Write-Log "  ошибка с плиткой $id : $($_.Exception.Message)" }
        }
    } finally {
        if ($stop) { $restarted = (Start-Start11Paths $stop.Launch) }
    }
    $safe = if ($NoReload) { -not $running } else { [bool]$stop.Ok }
    $kept = ($n -gt 0 -and -not $safe)
    if ($safe) { Save-S11Backup $backup }
    $reload = $null; $hint = ''
    if ($n -gt 0) {
        if ($NoReload) { $hint = $script:SI_S11Hint }
        else {
            $okAll = ($stop.Ok -and $stop.Paths.Count -gt 0 -and $restarted)
            $reload = [pscustomobject]@{ Ok = [bool]$okAll; Found = $stop.Paths.Count; Message = $(if ($okAll) { '' } else { $script:SI_S11Hint }) }
            if (-not $okAll) { $hint = $script:SI_S11Hint; Write-Log $hint }
        }
    }
    if ($failed -eq 0 -and $safe) { Remove-Start11Files }
    elseif ($failed -eq 0 -and $kept) { Write-Log 'Start11 работает: PNG плиток и start11.json оставлены, повторите откат после перезапуска Start11.' }
    $st = Read-State
    if ($failed -eq 0 -and $safe -and $st.ContainsKey('Tiles')) { $st.Remove('Tiles'); Save-State $st }
    Write-Log "Плитки Start11 возвращены: $n$(if ($failed -gt 0) { ', не удалось: ' + $failed })"
    return [pscustomobject]@{ Restored = $n; Failed = $failed; Nothing = $false; Kept = $kept; Reload = $reload; Hint = $hint }
}

function Remove-Start11Files {
    try { if (Test-Path -LiteralPath $script:SI_S11Dir) { Remove-Item -LiteralPath $script:SI_S11Dir -Recurse -Force } } catch { Write-Log "start11 не удалена: $($_.Exception.Message)" }
}

function Remove-CopyQuiet {
    param([string]$Copy)
    try { if ($Copy -and (Test-Path -LiteralPath $Copy)) { Remove-Item -LiteralPath $Copy -Force } } catch { }
}

# Запись бэкапа лежит в общей папке (рабочий стол всех пользователей / общее меню Пуск)? Для таких нужны права администратора.
function Test-CommonPath {
    param([string]$Path, [string[]]$CommonRoots)
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path) } catch { $full = $Path }
    foreach ($r in @($CommonRoots)) {
        if (-not $r) { continue }
        try { $rp = [IO.Path]::GetFullPath($r) } catch { $rp = $r }
        if (Test-PathUnder $full $rp) { return $true }
    }
    return $false
}

function Get-CommonRootPaths {
    return @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('CommonPrograms') | Where-Object { $_ })
}

# Чистое решение, как откатывать: есть ли в бэкапе записи общих папок и нужно ли для них повышение (процесс не администратор).
# Elevate -> общие записи откатывает повышенный CLI-дочерний процесс (-Cli -Undo -NoTiles -CommonOnly), остальное (ярлыки пользователя и плитки) - текущий.
function Get-UndoRoute {
    param([string[]]$Paths, [bool]$IsAdmin, [string[]]$CommonRoots)
    $common = 0; $user = 0
    foreach ($p in @($Paths)) { if (Test-CommonPath $p $CommonRoots) { $common++ } else { $user++ } }
    return [pscustomobject]@{ Elevate = ((-not $IsAdmin) -and $common -gt 0); CommonCount = $common; UserCount = $user }
}

# Откат: .lnk - возвращаем только иконку (Set-LinkIcon), удалённые ярлыки не воскрешаем; .ico - копируем обратно.
# Каждая запись сначала проходит Test-BackupEntry; отклонённые записи выбрасываются из индекса, файлы по ним не трогаются.
function Undo-All {
    [CmdletBinding()]
    param([switch]$RestartExplorer, [switch]$NoReload,
          [switch]$NoTiles,          # плитки Start11 не трогать
          [switch]$CommonOnly,       # только записи общих папок (для повышенного дочернего процесса); плитки не трогаются
          [switch]$SkipCommon)       # записи общих папок пропустить (остаются в бэкапе; их откатывает повышенный процесс)
    Assert-ElevationSafe
    $backup = Load-Backup
    if ($CommonOnly) { $NoTiles = $true }
    $commonRoots = @(Get-CommonRootPaths)
    $s11 = 0
    if (-not $NoTiles) { try { $s11 = (Load-S11Backup).Count } catch { $s11 = 1; Write-Log ('start11.json не прочитан: ' + $_.Exception.Message) } }
    $todo = @($backup.Keys | Where-Object {
        $isCommon = (Test-CommonPath $_ $commonRoots)
        if ($CommonOnly) { $isCommon } elseif ($SkipCommon) { -not $isCommon } else { $true } })
    $pendingCommon = if ($SkipCommon) { @($backup.Keys).Count - $todo.Count } else { 0 }
    if ($todo.Count -eq 0 -and $s11 -eq 0) {
        if ($pendingCommon -eq 0) { Write-Log 'Бэкапа нет - восстанавливать нечего.' }
        return [pscustomobject]@{ Restored = 0; Failed = 0; Skipped = 0; Nothing = ($pendingCommon -eq 0); CommonPending = $pendingCommon; TilesRestored = 0; Hint = '' }
    }
    $n = 0; $failed = 0; $skipped = 0
    foreach ($path in $todo) {
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
    $tilesRestored = 0; $hint = ''; $tileFailed = 0; $tilesKept = $false
    if ($s11 -gt 0) {       # плитки Start11 возвращаем тоже (значения реестра, потом PNG)
        try {
            $tr = Undo-Start11Tiles -NoReload:$NoReload
            $tilesRestored = [int]$tr.Restored; $tileFailed = [int]$tr.Failed; $hint = [string]$tr.Hint; $tilesKept = [bool]$tr.Kept
        } catch { $tileFailed = 1; Write-Log ('Плитки Start11 не возвращены: ' + $_.Exception.Message) }
    }
    $failed += $tileFailed
    $st = Read-State
    if ($st.ContainsKey('Applied') -and $failed -eq 0 -and $pendingCommon -eq 0 -and -not $CommonOnly) { $st.Remove('Applied'); Save-State $st }
    $tail = if ($failed -gt 0) { ", не удалось: $failed (для общих ярлыков отметьте «Также общие ярлыки» - нужны права администратора)" } else { '' }
    Write-Log "Восстановлено: $n$tail"
    if ($failed -eq 0 -and -not $CommonOnly) { Invoke-LegacyCleanup }
    if ($n -gt 0) { Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true }
    return [pscustomobject]@{ Restored = $n; Failed = $failed; Skipped = $skipped; Nothing = $false; CommonPending = $pendingCommon; TilesKept = $tilesKept; TilesRestored = $tilesRestored; Hint = $hint }
}

# Откат для GUI и удаления: записи общих папок при обычных правах возвращает повышенный CLI (один UAC), ярлыки пользователя
# и плитки Start11 - текущий процесс. Не вернулось что-то общее (UAC отменён, ошибка) - это Failed, чтобы удаление не стартовало.
function Undo-Routed {
    [CmdletBinding()]
    param([switch]$RestartExplorer, [switch]$NoReload)
    Assert-ElevationSafe
    $route = Get-UndoRoute -Paths @((Load-Backup).Keys) -IsAdmin (Test-Admin) -CommonRoots @(Get-CommonRootPaths)
    if (-not $route.Elevate) {
        if ($NoReload) { return (Undo-All -RestartExplorer:$RestartExplorer -NoReload) }
        return (Undo-All -RestartExplorer:$RestartExplorer)
    }
    Write-Log "В бэкапе общих ярлыков: $($route.CommonCount) - откатываю их через повышенный процесс."
    $a = @('-Cli', '-Undo', '-NoTiles', '-CommonOnly')
    if (-not $RestartExplorer -or $route.UserCount -gt 0) { $a += '-NoRestart' }      # проводник перезапустит основной процесс (если ему есть что откатывать)
    $er = Invoke-ElevatedCli -CliArgs $a
    $u = $null
    if ($NoReload) { $u = Undo-All -RestartExplorer:$RestartExplorer -NoReload -SkipCommon } else { $u = Undo-All -RestartExplorer:$RestartExplorer -SkipCommon }
    $left = 0
    try { $left = @((Load-Backup).Keys | Where-Object { Test-CommonPath $_ @(Get-CommonRootPaths) }).Count } catch { $left = 1 }
    if ($left -gt 0) {
        Write-Log "Общие ярлыки не возвращены ($left): повышение отменено или не удалось (код $($er.ExitCode))."
        $u.Failed = [int]$u.Failed + $left
        $u.Nothing = $false
    }
    return $u
}

# Запуск этого же скрипта (CLI) с повышением прав (UAC) на одно действие; ждём завершения.
function Invoke-ElevatedCli {
    param([string[]]$CliArgs)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $script = Join-Path $script:SI_CodeDir 'Glyphix.ps1'
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
    foreach ($vbs in @((Join-Path $script:SI_Home 'run-hidden.vbs'), (Join-Path ([string]$script:SI_OldHome) 'run-hidden.vbs'))) {      # v2 держала его в %LOCALAPPDATA%\ShadowIcons
        try {
            if ($vbs -and (Test-Path -LiteralPath $vbs -PathType Leaf)) { Remove-Item -LiteralPath $vbs -Force; $removed.Add($vbs); Write-Log "Удалён $vbs" }
        } catch { Write-Log "run-hidden.vbs не удалён: $($_.Exception.Message)" }
    }
    return $removed.ToArray()
}

# ---------- Ярлыки приложения и удаление ----------
function Get-AppShortcutPaths {
    return @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Glyphix.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Glyphix.lnk')
    )
}

# ярлыки прежней версии (Shadow Icons): удаляются при переносе данных и при удалении приложения
function Get-LegacyShortcutPaths {
    $out = @()
    foreach ($f in @('Programs', 'Desktop')) {
        $d = [Environment]::GetFolderPath($f)
        if ($d) { $out += (Join-Path $d 'Shadow Icons.lnk') }
    }
    if ($env:APPDATA) { $out += (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar\Shadow Icons.lnk') }     # закреплённый на панели задач
    return $out
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
            $sc.Description = 'Glyphix'
            $sc.Save()
            Write-Log "Ярлык: $p"
        } catch { Write-Log "Не удалось создать ярлык $p : $($_.Exception.Message)" }
    }
}

# ---------- Перенос данных из прежней версии (Shadow Icons -> Glyphix) ----------
# Прежняя папка %LOCALAPPDATA%\ShadowIcons: backup\ (index.json, start11.json, копии), state.json, start11\ (PNG плиток), packs\, log.txt.
# Папка packs\ КОПИРУЕТСЯ, а не переносится, и остаётся на месте вместе с icons\: на .ico оттуда ещё ссылаются применённые ярлыки.
# Следующее «Применить» перенацелит их на новую папку, после чего Invoke-LegacyCleanup удалит остатки (когда ссылок не осталось).

# путь внутри $OldDir -> тот же относительный путь внутри $NewDir; иначе $null
function Convert-LegacyPath {
    param([string]$Path, [string]$OldDir, [string]$NewDir)
    if (-not $Path -or -not $OldDir) { return $null }
    $p = $Path.Trim()
    $od = $OldDir.TrimEnd($script:SI_Seps)
    if ($p.Length -le ($od.Length + 1)) { return $null }
    if (-not $p.StartsWith($od, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if ($script:SI_Seps -notcontains $p[$od.Length]) { return $null }
    $out = $NewDir
    foreach ($seg in $p.Substring($od.Length + 1).Split($script:SI_Seps)) { if ($seg) { $out = Join-Path $out $seg } }
    return $out
}

# JSON-массив бэкапа (backup\index.json: поле Copy; backup\start11.json: поле Data); остальные поля и старые форматы не меняются
function Convert-LegacyBackupJson {
    param([string]$File, [string]$Field, [string]$OldDir, [string]$NewDir)
    $data = @(Read-JsonFile $File | Where-Object { $_ })
    $changed = 0
    foreach ($e in $data) {
        if (-not $e.PSObject.Properties[$Field] -or $null -eq $e.$Field) { continue }
        $nv = Convert-LegacyPath ([string]$e.$Field) $OldDir $NewDir
        if ($nv) { $e.$Field = $nv; $changed++ }
    }
    return [pscustomobject]@{ Json = (ConvertTo-Json -InputObject @($data)); Items = @($data); Count = $data.Count; Changed = $changed }
}

# копия дерева с объединением (Copy-Item -Recurse в существующую папку вкладывает её внутрь, поэтому вручную)
function Copy-TreeMerge {
    param([string]$Src, [string]$Dst)
    if (-not (Test-Path -LiteralPath $Dst)) { New-Item -ItemType Directory -Path $Dst -Force | Out-Null }
    foreach ($c in @(Get-ChildItem -LiteralPath $Src -Force)) {
        $t = Join-Path $Dst $c.Name
        if ($c.PSIsContainer) { Copy-TreeMerge $c.FullName $t } else { Copy-Item -LiteralPath $c.FullName -Destination $t -Force }
    }
}

# '' - перенос нужен; иначе причина, по которой он не нужен. Условие: прежняя папка есть и метки migrated.json в папке Glyphix ещё нет.
# Бэкап в папке Glyphix сам по себе не повод пропускать перенос: старый бэкап сливается с новым (см. Merge-LegacyBackup).
function Get-LegacyMigrationSkipReason {
    $old = [string]$script:SI_OldHome
    $new = [string]$script:SI_Home
    if (-not $old -or -not (Test-Path -LiteralPath $old -PathType Container)) { return 'нет прежней папки' }
    if ($old.TrimEnd($script:SI_Seps) -ieq $new.TrimEnd($script:SI_Seps)) { return 'та же папка' }
    if (Test-Path -LiteralPath (Join-Path $new 'migrated.json')) { return 'уже перенесено' }
    return ''
}

# $true - метки нет, а бэкап прежней версии (backup\ или backup.migrating\) ещё лежит в прежней папке: перенос не завершён.
# Пока так, применять пак нельзя: исходные иконки уже заменены, и новый бэкап записал бы в «оригиналы» иконки пака.
function Test-LegacyMigrationIncomplete {
    $old = [string]$script:SI_OldHome
    $new = [string]$script:SI_Home
    if (-not $old -or -not (Test-Path -LiteralPath $old -PathType Container)) { return $false }
    if ($old.TrimEnd($script:SI_Seps) -ieq $new.TrimEnd($script:SI_Seps)) { return $false }
    if (Test-Path -LiteralPath (Join-Path $new 'migrated.json')) { return $false }
    foreach ($n in @('backup', 'backup.migrating')) { if (Test-Path -LiteralPath (Join-Path $old $n)) { return $true } }
    return $false
}

$script:SI_MigrationPendingMsg = 'Перенос данных Shadow Icons не завершён: бэкап исходных иконок ещё лежит в прежней папке. Применять пак сейчас нельзя - иначе иконки пака попадут в бэкап как «оригинальные». Перезапустите Glyphix (перенос повторится сам); если сообщение не пропадает, смотрите журнал.'

function Assert-LegacyMigrationComplete {
    if (Test-LegacyMigrationIncomplete) { Write-Log ('Отказ: ' + $script:SI_MigrationPendingMsg); throw $script:SI_MigrationPendingMsg }
}

# записи $Incoming + записи из файла $ExistingFile (если он есть) без повторов по полю $Key (регистр не важен) -> JSON.
# $IncomingWins: при совпадении ключа остаётся запись из $Incoming (старый бэкап - это первые оригиналы), иначе - уже лежащая в файле.
function Merge-BackupEntries {
    param($Incoming, [string]$ExistingFile, [string]$Key, [bool]$IncomingWins)
    $existing = @()
    if (Test-Path -LiteralPath $ExistingFile -PathType Leaf) { $existing = @(Read-JsonFile $ExistingFile | Where-Object { $_ }) }
    $first = if ($IncomingWins) { @($Incoming) } else { $existing }
    $second = if ($IncomingWins) { $existing } else { @($Incoming) }
    $seen = @{}
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $first) {
        $k = ''; if ($e.PSObject.Properties[$Key] -and $null -ne $e.$Key) { $k = [string]$e.$Key }
        if ($k) { $seen[$k] = $true }
        $out.Add($e)
    }
    foreach ($e in $second) {
        $k = ''; if ($e.PSObject.Properties[$Key] -and $null -ne $e.$Key) { $k = [string]$e.$Key }
        if ($k -and $seen.ContainsKey($k)) { continue }
        if ($k) { $seen[$k] = $true }
        $out.Add($e)
    }
    return (ConvertTo-Json -InputObject @($out.ToArray()))
}

# Слить каталог старого бэкапа $Src (backup.migrating\ или лишний backup\) в бэкап Glyphix: копии файлов, потом start11.json и index.json
# (пути Copy/Data переписаны на новую папку). Записи старого бэкапа главнее ($OldFirst): это самые первые оригиналы.
# Ничего в $Src не удаляет. При ошибке удаляет только файлы, СОЗДАННЫЕ этим вызовом, и только пока $Src на месте; ошибку пробрасывает.
# Возвращает число записей index.json старого бэкапа.
function Merge-LegacyBackup {
    param([string]$Src, [string]$OldBackup, [string]$OldS11, [bool]$OldFirst = $true)
    $created = New-Object 'System.Collections.Generic.List[string]'
    $count = 0
    try {
        if (-not (Test-Path -LiteralPath $script:SI_BackupDir)) { New-Item -ItemType Directory -Path $script:SI_BackupDir -Force | Out-Null }
        foreach ($f in @(Get-ChildItem -LiteralPath $Src -File -Force)) {
            if (@('index.json', 'start11.json') -contains $f.Name -or $f.Name.EndsWith('.tmp')) { continue }
            $dst = Join-Path $script:SI_BackupDir $f.Name
            $existed = Test-Path -LiteralPath $dst
            if ($existed -and -not $OldFirst) { continue }
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
            if (-not $existed) { $created.Add($dst) }
        }
        $specs = @(
            @{ File = 'start11.json'; Dest = $script:SI_S11BackupFile; Field = 'Data'; Key = 'Id'; OldDir = $OldS11; NewDir = $script:SI_S11Dir },
            @{ File = 'index.json'; Dest = $script:SI_BackupFile; Field = 'Copy'; Key = 'Path'; OldDir = $OldBackup; NewDir = $script:SI_BackupDir }
        )
        foreach ($sp in $specs) {
            $sf = Join-Path $Src $sp.File
            if (-not (Test-Path -LiteralPath $sf -PathType Leaf)) { continue }
            $c = Convert-LegacyBackupJson $sf $sp.Field $sp.OldDir $sp.NewDir
            if ($c.Count -eq 0) { continue }
            $existed = Test-Path -LiteralPath $sp.Dest
            Save-JsonAtomic $sp.Dest (Merge-BackupEntries $c.Items $sp.Dest $sp.Key $OldFirst)
            if (-not $existed) { $created.Add($sp.Dest) }
            if ($sp.File -eq 'index.json') { $count = $c.Count }
        }
    } catch {
        $err = $_
        if (Test-Path -LiteralPath $Src -PathType Container) {      # источник цел - можно убрать то, что создали сами; чужое и прежнее не трогаем
            foreach ($cf in $created) { try { if (Test-Path -LiteralPath $cf) { Remove-Item -LiteralPath $cf -Force } } catch { Write-Log ('  не удалён файл неудачного переноса: ' + $cf) } }
        }
        throw $err
    }
    return [int]$count
}

$script:SI_MigrationWaitMs = 30000

# Результат: Migrated, Reason, Backup (записей index.json), Packs, Registry (значения CustomTiles), Failed.
# -NoReload: Start11 не закрываем (значения реестра всё равно перепишем, но PNG из старой папки тогда не удаляем).
# Один перенос за раз: именованный мьютекс Local\Glyphix.Migration (ждём до 30 с, иначе пропускаем с записью в журнал).
function Invoke-LegacyMigration {
    [CmdletBinding()]
    param([switch]$NoReload)
    $res = [pscustomobject]@{ Migrated = $false; Reason = ''; Backup = 0; Packs = 0; Registry = 0; Failed = 0 }
    $skip = Get-LegacyMigrationSkipReason
    if ($skip) { $res.Reason = $skip; return $res }
    $mtx = $null; $got = $false
    try {
        try {
            $mtx = New-Object System.Threading.Mutex($false, 'Local\Glyphix.Migration')
            try { $got = $mtx.WaitOne([int]$script:SI_MigrationWaitMs) }
            catch {
                $ex = $_.Exception
                if ($ex -is [System.Threading.AbandonedMutexException] -or $ex.InnerException -is [System.Threading.AbandonedMutexException]) { $got = $true }     # предыдущий владелец завершился, не отпустив - теперь он наш
                else { throw }
            }
        } catch { Write-Log ('Перенос данных: мьютекс недоступен (' + $_.Exception.Message + ') - пропускаю'); $res.Reason = 'мьютекс переноса недоступен'; return $res }
        if (-not $got) { Write-Log 'Перенос данных уже выполняет другой процесс Glyphix - пропускаю'; $res.Reason = 'перенос выполняется другим процессом'; return $res }
        $skip = Get-LegacyMigrationSkipReason          # пока ждали, другой процесс мог закончить
        if ($skip) { $res.Reason = $skip; return $res }
        return (Invoke-LegacyMigrationLocked -NoReload:$NoReload)
    } finally {
        if ($mtx) {
            if ($got) { try { $mtx.ReleaseMutex() } catch { } }
            $mtx.Dispose()
        }
    }
}

# тело переноса; вызывать только под мьютексом (Invoke-LegacyMigration)
function Invoke-LegacyMigrationLocked {
    [CmdletBinding()]
    param([switch]$NoReload)
    $res = [pscustomobject]@{ Migrated = $false; Reason = ''; Backup = 0; Packs = 0; Registry = 0; Failed = 0 }
    $old = [string]$script:SI_OldHome
    $new = [string]$script:SI_Home
    $marker = Join-Path $new 'migrated.json'

    Write-Log "Переношу данные прежней версии: $old"
    $oldBackup = Join-Path $old 'backup'
    $oldMig = Join-Path $old 'backup.migrating'      # старый backup\ после переименования: замок и метка «перенос идёт» (найден при запуске - продолжаем с него)
    $oldS11 = Join-Path $old 'start11'
    $retry = $false          # true - не перенесён бэкап: метку не ставим, перенос повторится при следующем запуске (идемпотентно)

    # 0) старый backup\ -> backup.migrating\ одним переименованием (атомарно); дальше работаем только с ним
    $sources = New-Object 'System.Collections.Generic.List[object]'
    try {
        $hasMig = Test-Path -LiteralPath $oldMig -PathType Container
        $hasBk = Test-Path -LiteralPath $oldBackup -PathType Container
        if ($hasMig) {
            Write-Log '  найден backup.migrating - продолжаю прерванный перенос бэкапа'
            $sources.Add(@{ Dir = $oldMig; OldFirst = $true })
            if ($hasBk) { $sources.Add(@{ Dir = $oldBackup; OldFirst = $false }) }       # свежий backup\ рядом с незаконченным: прежние записи главнее
        } elseif ($hasBk) {
            [IO.Directory]::Move($oldBackup, $oldMig)
            $sources.Add(@{ Dir = $oldMig; OldFirst = $true })
        }
    } catch { $res.Failed++; $retry = $true; $sources.Clear(); Write-Log ('  старый backup не переименован в backup.migrating: ' + $_.Exception.Message) }

    # 1) state.json (значения из новой папки главнее)
    try {
        $os = Join-Path $old 'state.json'
        if (Test-Path -LiteralPath $os -PathType Leaf) {
            $st = Read-State
            foreach ($p in (Read-JsonFile $os).PSObject.Properties) { if (-not $st.ContainsKey($p.Name)) { $st[$p.Name] = $p.Value } }
            Save-State $st
            Remove-Item -LiteralPath $os -Force
        }
    } catch { $res.Failed++; Write-Log ('  state.json не перенесён: ' + $_.Exception.Message) }

    # 2) кэш паков: копия (оригиналы нужны применённым ярлыкам)
    try {
        $op = Join-Path $old 'packs'
        if (Test-Path -LiteralPath $op -PathType Container) {
            foreach ($d in @(Get-ChildItem -LiteralPath $op -Directory -Force)) {
                $dst = Join-Path $script:SI_PacksDir $d.Name
                if (Test-Path -LiteralPath $dst) { continue }
                Copy-TreeMerge $d.FullName $dst
                $res.Packs++
            }
        }
    } catch { $res.Failed++; Write-Log ('  кэш паков не перенесён: ' + $_.Exception.Message) }

    # 3) плитки Start11: PNG -> новая папка, значения CustomTiles, указывающие в старую папку, -> новые пути
    try {
        $rew = New-Object 'System.Collections.Generic.List[object]'
        if (Test-Start11) {
            foreach ($n in @(Get-S11ValueNames $script:SI_S11Tiles)) {
                $v = $null
                try { $v = Get-S11Value $script:SI_S11Tiles $n } catch { continue }          # не REG_SZ - не трогаем
                if ($null -eq $v) { continue }
                $nv = Convert-LegacyPath $v $oldS11 $script:SI_S11Dir
                if ($nv) { $rew.Add([pscustomobject]@{ Id = [string]$n; Data = $nv; Kind = $(if ((Get-S11Kind $script:SI_S11Tiles $n) -eq 'ExpandString') { 'ExpandString' } else { 'String' }) }) }
            }
        }
        $hasPng = (Test-Path -LiteralPath $oldS11 -PathType Container)
        if ($hasPng) { Copy-TreeMerge $oldS11 $script:SI_S11Dir }       # сначала файлы, потом реестр: плитки ни на секунду не остаются без картинки
        $s11ok = $true; $stop = $null
        if ($rew.Count -gt 0) {
            if (-not $NoReload) { $stop = Stop-Start11 }                 # пока Start11 работает, он может записать плитки из памяти поверх наших
            try {
                foreach ($r in $rew) {
                    try {
                        Set-S11Value $script:SI_S11Tiles $r.Id $r.Data $r.Kind
                        if ((Get-S11Value $script:SI_S11Tiles $r.Id) -ine $r.Data) { throw 'значение в реестре не записалось' }
                        $res.Registry++
                    } catch { $s11ok = $false; $res.Failed++; Write-Log "  плитка $($r.Id) не перенесена: $($_.Exception.Message)" }
                }
            } finally {
                if ($stop) { [void](Start-Start11Paths $stop.Launch) }
            }
        }
        if ($hasPng) {
            $canDelete = ($s11ok -and ($rew.Count -eq 0 -or ($stop -and $stop.Ok)))
            if ($canDelete) { Remove-Item -LiteralPath $oldS11 -Recurse -Force }
            else { Write-Log '  PNG плиток в прежней папке оставлены (Start11 не перезапущен или значения не переписаны)' }
        }
    } catch { $res.Failed++; Write-Log ('  плитки Start11 не перенесены: ' + $_.Exception.Message) }     # старые PNG остаются на месте: значения реестра, которые не переписали, продолжают работать

    # 4) бэкап: слияние с бэкапом Glyphix (старые записи главнее); backup.migrating\ удаляем после успеха - отдельным try, который только пишет в журнал
    foreach ($s in $sources) {
        $merged = $false
        try { $res.Backup += (Merge-LegacyBackup $s.Dir $oldBackup $oldS11 $s.OldFirst); $merged = $true }
        catch { $res.Failed++; $retry = $true; Write-Log ('  бэкап не перенесён: ' + $_.Exception.Message) }      # повтор продолжит с backup.migrating
        if (-not $merged) { break }
        try { Remove-Item -LiteralPath $s.Dir -Recurse -Force }
        catch { Write-Log ('  старый бэкап не удалён (он уже перенесён, остаток можно удалить вручную): ' + $s.Dir + ' - ' + $_.Exception.Message) }
    }

    # 5) журнал: старый - перед новым
    try {
        foreach ($ln in @('log.txt.old', 'log.txt')) {
            $ol = Join-Path $old $ln
            if (-not (Test-Path -LiteralPath $ol -PathType Leaf)) { continue }
            $nl = Join-Path $new $ln
            if ($ln -eq 'log.txt' -and (Test-Path -LiteralPath $nl)) {
                [IO.File]::WriteAllText($nl, ([IO.File]::ReadAllText($ol) + [IO.File]::ReadAllText($nl)), (New-Object System.Text.UTF8Encoding($false)))
                Remove-Item -LiteralPath $ol -Force
            } elseif (-not (Test-Path -LiteralPath $nl)) {
                Move-Item -LiteralPath $ol -Destination $nl -Force
            }
        }
    } catch { Write-Log ('  журнал не перенесён: ' + $_.Exception.Message) }

    # 6) метка переноса, и только после неё (перенос удался полностью, не $retry) - старая папка приложения и ярлыки «Shadow Icons» (запускали бы прежнюю версию)
    if (-not $retry) {
        try { Save-JsonAtomic $marker (ConvertTo-Json -InputObject ([pscustomobject]@{ From = $old; At = (Get-Date).ToString('s') })) }
        catch { $res.Failed++; $retry = $true; Write-Log ('  метка переноса не записана: ' + $_.Exception.Message) }
    }
    if (-not $retry) {
        try {
            $oa = Join-Path $old 'app'
            if (Test-Path -LiteralPath $oa) {
                $cd = ''
                try { $cd = [IO.Path]::GetFullPath([string]$script:SI_CodeDir).TrimEnd($script:SI_Seps) } catch { }
                if ($cd -and (($cd -ieq $oa.TrimEnd($script:SI_Seps)) -or (Test-PathUnder $cd $oa))) { Write-Log '  прежняя папка app используется сейчас - не удаляю' }
                else { Remove-Item -LiteralPath $oa -Recurse -Force; Write-Log '  удалена прежняя папка app' }
            }
        } catch { Write-Log ('  прежняя папка app не удалена: ' + $_.Exception.Message) }
        foreach ($lp in (Get-LegacyShortcutPaths)) {
            try { if ($lp -and (Test-Path -LiteralPath $lp)) { Remove-Item -LiteralPath $lp -Force; Write-Log "  удалён прежний ярлык: $lp" } } catch { Write-Log "  ярлык не удалён: $lp" }
        }
    }
    $res.Migrated = (-not $retry)
    $res.Reason = if ($retry) { 'перенос не завершён, повторится при следующем запуске' } else { 'ok' }
    Write-Log "Перенос данных: бэкап $($res.Backup), паков в кэше $($res.Packs), значений плиток Start11 $($res.Registry), ошибок $($res.Failed)"
    return $res
}

# Есть ли ярлыки, иконка которых лежит в прежней папке данных (уже применённый пак прежней версии)?
function Test-LegacyHomeReferenced {
    $old = [string]$script:SI_OldHome
    if (-not $old) { return $false }
    try {
        foreach ($s in @(Get-ShortcutList -AllUsers)) {
            $loc = Split-IconLocation ([string]$s.Icon)
            $p = [Environment]::ExpandEnvironmentVariables($loc.Path.Trim('"'))
            if ($p -and (Test-PathUnder $p $old)) { return $true }
        }
    } catch { return $true }          # не смогли проверить - считаем, что ссылки есть
    return $false
}

# пустые подпапки внутри $Root (сам $Root не трогаем); в ссылки/junction не заходим
function Remove-EmptyDirs {
    param([string]$Root)
    $dirs = @(Get-ChildItem -LiteralPath $Root -Directory -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($d in $dirs) {
        try { if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $d.FullName -Force } } catch { }
    }
}

# Удалить из прежней папки данных packs\ и icons\ (и остатки v2: Set-TaskbarIcons.ps1, log.txt, run-hidden.vbs, пустые папки), когда на неё больше не ссылается ни один ярлык;
# саму папку - если она опустела. Пока бэкап не перенесён (нет метки, а backup\ на месте) - ничего не трогаем.
function Remove-LegacyHomeIfUnused {
    $old = [string]$script:SI_OldHome
    if (-not $old -or -not (Test-Path -LiteralPath $old -PathType Container)) { return $false }
    if ($old.TrimEnd($script:SI_Seps) -ieq ([string]$script:SI_Home).TrimEnd($script:SI_Seps)) { return $false }
    if (Test-LegacyMigrationIncomplete) { return $false }
    if (Test-LegacyHomeReferenced) { return $false }
    $subs = @('packs', 'icons')
    if (Test-Path -LiteralPath (Join-Path ([string]$script:SI_Home) 'migrated.json')) { $subs += 'backup.migrating' }       # остаток уже перенесённого бэкапа
    foreach ($sub in $subs) {
        $d = Join-Path $old $sub
        try { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force; Write-Log "Удалена прежняя папка: $d" } } catch { Write-Log "Не удалена $d : $($_.Exception.Message)" }
    }
    foreach ($fn in @('Set-TaskbarIcons.ps1', 'log.txt', 'log.txt.old', 'run-hidden.vbs')) {
        $f = Join-Path $old $fn
        try { if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force; Write-Log "Удалён остаток прежней версии: $f" } } catch { Write-Log "Не удалён $f : $($_.Exception.Message)" }
    }
    try { Remove-EmptyDirs $old } catch { }
    try { if (-not (Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $old -Force } } catch { }
    return $true
}

function Invoke-LegacyCleanup {
    try { [void](Remove-LegacyHomeIfUnused) } catch { Write-Log ('Прежняя папка данных: ' + $_.Exception.Message) }
}

function Uninstall-App {
    [CmdletBinding()]
    param([switch]$RestartExplorer, [switch]$NoReload)
    Assert-ElevationSafe
    Write-Log 'Удаляю приложение...'
    $u = $null
    try { if ($NoReload) { $u = Undo-Routed -RestartExplorer:$RestartExplorer -NoReload } else { $u = Undo-Routed -RestartExplorer:$RestartExplorer } } catch { Write-Log "Откат не выполнен: $($_.Exception.Message)" }
    if (-not $u -or $u.Failed -gt 0) {      # откат не удался (или результата нет) - ничего не удаляем, иначе потеряем бэкап
        $msg = 'Не все иконки удалось вернуть - приложение не удалено, бэкап сохранён. Исправьте причину (см. журнал; для общих ярлыков отметьте «Также общие ярлыки») и повторите.'
        Write-Log $msg
        return [pscustomobject]@{ Ok = $false; KeptBackup = $true; Aborted = $true; Message = $msg }
    }
    if ($u.PSObject.Properties['TilesKept'] -and $u.TilesKept) { Write-Log 'Start11 работает и не перезапущен: PNG плиток оставлены.' }
    else { Remove-Start11Files }       # PNG плиток - только теперь, когда значения реестра уже возвращены (иначе плитки остались бы без картинок)
    # не держим папку приложения/данных текущей: иначе её не удалить
    $tmpDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    try { [Environment]::CurrentDirectory = $tmpDir } catch { }
    try { Set-Location -LiteralPath $tmpDir } catch { }
    [void](Remove-Legacy)
    foreach ($p in @(Get-AppShortcutPaths) + @(Get-LegacyShortcutPaths)) {
        try { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force; Write-Log "Удалён ярлык: $p" } } catch { Write-Log "Ярлык не удалён: $p" }
    }
    Invoke-LegacyCleanup                 # откат выполнен: прежняя папка данных (packs\, icons\) больше не нужна
    try { if (Test-Path -LiteralPath $script:SI_StateFile) { Remove-Item -LiteralPath $script:SI_StateFile -Force } } catch { }
    try { $mg = Join-Path $script:SI_Home 'migrated.json'; if (Test-Path -LiteralPath $mg) { Remove-Item -LiteralPath $mg -Force } } catch { }
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
