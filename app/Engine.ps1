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
$script:SI_S11Dir = Join-Path $script:SI_Home 'start11'                            # наши плитки: start11\<пак>\<id>.<sha8>.<png|jpg> (путь зависит от содержимого, см. Get-Start11TileDest)
$script:SI_AppliedDir = Join-Path $script:SI_Home 'applied'                        # применённые иконки: applied\<пак>\<id>.<sha8>.ico (путь зависит от содержимого, см. Get-AppliedIconDest)
$script:SI_TileExts = @('.png', '.jpg', '.jpeg')                                   # допустимые расширения файлов плиток в паках
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

# ---------- Фоновые операции (отдельный runspace, UI не замирает) ----------
# Текст движка передаётся в runspace ЦЕЛИКОМ (строкой) и подключается как scriptblock: фоновая операция не зависит от того, лежит ли
# Engine.ps1 на диске в этот момент (раньше runspace делал `. <путь>`: если файла по этому пути не было - «The term '...Engine.ps1' is not recognized»).
$script:SI_BgPrologue = @'
param($engineText, $codeDir, $queue, $params, $body)
$ErrorActionPreference = 'Stop'
. ([scriptblock]::Create($engineText))
if ($codeDir) { $script:SI_CodeDir = $codeDir }
$q = $queue
Set-EngineLogHandler ({ param($m) $q.Enqueue([string]$m) }.GetNewClosure())
try { & ([scriptblock]::Create($body)) $params }
catch {
    $stack = [string]$_.ScriptStackTrace
    Write-Log ('ОШИБКА: ' + $_.Exception.Message)
    if ($stack) { Write-Log ('  стек: ' + ($stack -replace "`r?`n", ' <- ')) }
    [pscustomobject]@{ Error = $_.Exception.Message; Stack = $stack }
}
'@

# Запустить $Body (текст scriptblock с param($p)) в новом runspace. Возвращает @{ PS; RS; Async; Queue }; строки журнала идут в Queue.
# Исходная сессия по умолчанию (CreateDefault: есть все стандартные команды), политика выполнения Bypass, STA (WPF/COM/Shell в движке).
function Start-EngineJob {
    param([Parameter(Mandatory)][string]$EngineText, [string]$CodeDir, [Parameter(Mandatory)][string]$Body, [hashtable]$Params, [string]$Prologue)
    if (-not $EngineText) { throw 'Текст движка пуст: фоновую операцию запустить нельзя' }
    if (-not $Prologue) { $Prologue = $script:SI_BgPrologue }
    if ($null -eq $Params) { $Params = @{} }
    $q = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { try { $iss.ExecutionPolicy = [Microsoft.PowerShell.ExecutionPolicy]::Bypass } catch { } }      # на других ОС свойство не поддерживается (Open() падает)
    $rs = [runspacefactory]::CreateRunspace($iss)
    try { $rs.ApartmentState = [Threading.ApartmentState]::STA } catch { }
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $ps = $null
    try {
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript($Prologue).AddArgument($EngineText).AddArgument($CodeDir).AddArgument($q).AddArgument($Params).AddArgument($Body)
        $async = $ps.BeginInvoke()
    } catch {
        if ($ps) { try { $ps.Dispose() } catch { } }
        try { $rs.Dispose() } catch { }
        throw
    }
    return @{ PS = $ps; RS = $rs; Async = $async; Queue = $q }
}

# Результат задания: последний выведенный объект; если runspace упал - объект с Error и Stack (стек берётся из потока ошибок runspace).
function Receive-EngineJob {
    param([Parameter(Mandatory)]$Job)
    $res = $null
    try {
        $out = $Job.PS.EndInvoke($Job.Async)
        if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] }
    } catch {
        $stack = ''
        try { $stack = (@($Job.PS.Streams.Error | ForEach-Object { [string]$_.ScriptStackTrace }) + [string]$_.ScriptStackTrace | Where-Object { $_ }) -join "`n" } catch { }
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        Write-Log ('ОШИБКА фоновой операции: ' + $msg)
        if ($stack) { Write-Log ('  стек: ' + ($stack -replace "`r?`n", ' <- ')) }
        $res = [pscustomobject]@{ Error = $msg; Stack = $stack }
    }
    try { $Job.PS.Dispose(); $Job.RS.Close(); $Job.RS.Dispose() } catch { }
    return $res
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

# ---------- Самообновление приложения ----------
# Версия приложения = app/version.txt. Сравнение семантическое (major.minor[.patch[.build]][-pre]); любой сбой сети - тихо $null.
$script:SI_AppId = 'F1KS.Glyphix'                    # AppUserModelID: ярлыки «Glyphix» и окно приложения (Start11, группировка на панели задач)
$script:SI_InstallerMaxBytes = 65536                  # install.ps1 крупнее 64 КБ не принимаем

# строка версии -> @{ Nums = [long[]](4); Pre = '' } или $null, если это не версия
function ConvertTo-VersionParts {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Trim().TrimStart([char]0xFEFF).Trim()
    if ($t.Length -eq 0 -or $t.Length -gt 40) { return $null }
    $m = [regex]::Match($t, '^[vV]?(\d{1,9})(?:\.(\d{1,9}))?(?:\.(\d{1,9}))?(?:\.(\d{1,9}))?(?:-([0-9A-Za-z][0-9A-Za-z.\-]*))?(?:\+[0-9A-Za-z.\-]+)?$')
    if (-not $m.Success) { return $null }
    $nums = New-Object 'long[]' 4
    for ($i = 0; $i -lt 4; $i++) { if ($m.Groups[$i + 1].Success) { $nums[$i] = [long]$m.Groups[$i + 1].Value } }
    return @{ Nums = $nums; Pre = $m.Groups[5].Value }
}

# -1 / 0 / 1 (A меньше / равна / больше B); $null, если одна из строк не версия. Пре-релиз ниже релиза: 2.1.0-beta < 2.1.0
function Compare-AppVersion {
    param([string]$A, [string]$B)
    $pa = ConvertTo-VersionParts $A
    $pb = ConvertTo-VersionParts $B
    if ($null -eq $pa -or $null -eq $pb) { return $null }
    for ($i = 0; $i -lt 4; $i++) {
        if ($pa.Nums[$i] -lt $pb.Nums[$i]) { return -1 }
        if ($pa.Nums[$i] -gt $pb.Nums[$i]) { return 1 }
    }
    if ($pa.Pre -eq $pb.Pre) { return 0 }
    if (-not $pa.Pre) { return 1 }
    if (-not $pb.Pre) { return -1 }
    $c = [string]::CompareOrdinal($pa.Pre, $pb.Pre)
    if ($c -lt 0) { return -1 }
    if ($c -gt 0) { return 1 }
    return 0
}

# решение об обновлении: Available только если версия на сервере корректна и строго новее локальной
function Get-UpdateDecision {
    param([string]$Local, [string]$Remote)
    $c = Compare-AppVersion $Remote $Local
    $reason = 'unknown'
    $ok = $false
    if ($null -eq (ConvertTo-VersionParts $Remote)) { $reason = 'bad-remote' }
    elseif ($null -eq (ConvertTo-VersionParts $Local)) { $reason = 'bad-local' }
    elseif ($c -gt 0) { $reason = 'newer'; $ok = $true }
    elseif ($c -eq 0) { $reason = 'same' }
    else { $reason = 'older' }
    return [pscustomobject]@{ Available = $ok; Local = $Local; Remote = $Remote; Reason = $reason }
}

# версия на сервере (app/version.txt) или $null (нет сети, таймаут, мусор в ответе) - без исключений и без шума
function Get-RemoteAppVersion {
    param([string]$BaseUrl = $script:SI_BaseUrl, [int]$TimeoutMs = 5000)
    try {
        if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
        $b = Get-WebBytes ($BaseUrl + 'app/version.txt') 256 $TimeoutMs
        if (-not $b -or $b.Length -eq 0) { return $null }
        $t = [System.Text.Encoding]::UTF8.GetString($b).Trim().TrimStart([char]0xFEFF).Trim()
        if ($null -eq (ConvertTo-VersionParts $t)) { return $null }
        return $t
    } catch { return $null }
}

# локальная версия + версия на сервере + решение; Remote = $null, если проверить не удалось
function Get-AppUpdateInfo {
    param([string]$BaseUrl = $script:SI_BaseUrl, [int]$TimeoutMs = 5000)
    $local = Get-AppVersion
    $remote = Get-RemoteAppVersion -BaseUrl $BaseUrl -TimeoutMs $TimeoutMs
    return (Get-UpdateDecision -Local $local -Remote $remote)
}

# install.ps1 принимаем, только если это короткий ASCII-текст со своей таблицей хэшей (не HTML-заглушка, не бинарник, не BOM)
function Test-InstallerBytes {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Length -eq 0 -or $Bytes.Length -ge $script:SI_InstallerMaxBytes) { return $false }
    $s = [System.Text.Encoding]::GetEncoding(28591).GetString($Bytes)      # 1 байт = 1 символ
    if (-not [regex]::IsMatch($s, '\A[\x09\x0A\x0D\x20-\x7E]+\z')) { return $false }
    return $s.Contains('BEGIN-HASHES')
}

# скачать install.ps1 в %TEMP%; бросает исключение, если файл не прошёл проверку
function Save-AppInstaller {
    param([string]$BaseUrl = $script:SI_BaseUrl, [string]$TempDir = [IO.Path]::GetTempPath())
    if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
    $b = Get-WebBytes ($BaseUrl + 'install.ps1') $script:SI_InstallerMaxBytes 20000
    if (-not (Test-InstallerBytes $b)) { throw 'Скачанный install.ps1 не прошёл проверку (нужен ASCII-текст меньше 64 КБ). Обновление отменено.' }
    $f = Join-Path $TempDir ('glyphix_install_' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
    Save-FileAtomic $f $b
    return $f
}

# ---------- Самообновление через GlyphixSetup.exe (без окна консоли) ----------
# Приложение скачивает GlyphixSetup.exe в <данные>\GlyphixSetup.exe.new, сверяет размер и sha256 с app/files.json ("setup"), кладёт на место и
# запускает его с `/update /wait-pid <PID приложения>`; установщик сам ждёт выхода приложения, скачивает/проверяет файлы, подменяет app\ и
# запускает Glyphix заново. Источники по порядку: raw.githubusercontent.com -> зеркало jsDelivr -> релиз GitHub (latest/download/<имя файла>;
# вложения релиза плоские: имя = последний сегмент пути). Источник без файла (404, релиза ещё нет) или с файлом не по sha256 пропускается.
# Ни одна ветка не запускает powershell.exe/cmd.exe и не открывает консоль. Путь через install.ps1 остаётся для опытных (Save-AppInstaller).
$script:SI_ReleasesBaseUrl = 'https://github.com/F1KS-FK/glyphix/releases/latest/download/'
$script:SI_SetupFileName = 'GlyphixSetup.exe'
$script:SI_SetupMaxBytes = 33554432                   # установщик больше 32 МБ не принимаем (сейчас ~0,2 МБ)

# Адреса одного файла по источникам: { Url; Name; Flat }. Пустой адрес источника = источника нет.
function Get-SetupSourceUrls {
    param([string]$Rel, [string]$BaseUrl = $script:SI_BaseUrl, [string]$MirrorUrl = $script:SI_MirrorBaseUrl, [string]$ReleasesUrl = $script:SI_ReleasesBaseUrl)
    $r = [System.Collections.Generic.List[object]]::new()
    foreach ($s in @(@($BaseUrl, $false, 'GitHub'), @($MirrorUrl, $false, 'зеркало jsDelivr'), @($ReleasesUrl, $true, 'релиз GitHub'))) {
        $b = [string]$s[0]
        if (-not $b) { continue }
        if (-not $b.EndsWith('/')) { $b += '/' }
        $leaf = if ($s[1]) { $Rel.Substring($Rel.LastIndexOf('/') + 1) } else { $Rel }
        $r.Add([pscustomobject]@{ Url = ($b + $leaf); Name = [string]$s[2]; Flat = [bool]$s[1] })
    }
    return $r.ToArray()
}

# files.json (байты) -> запись "setup" { Path; Sha256; Size; Version } или $null, если её нет / она некорректна (старый манифест на зеркале и т.п.)
function ConvertTo-SetupEntry {
    param([byte[]]$Bytes)
    try {
        $s = (ConvertFrom-JsonBytes $Bytes).setup
        if (-not $s) { return $null }
        $sha = ([string]$s.sha256).ToLowerInvariant(); $size = [long]$s.size
        if ([string]$s.path -ne $script:SI_SetupFileName -or $sha -notmatch '^[0-9a-f]{64}$' -or $size -lt 1 -or $size -gt $script:SI_SetupMaxBytes) { return $null }
        if ($null -eq (ConvertTo-VersionParts ([string]$s.version))) { return $null }
        return [pscustomobject]@{ Path = [string]$s.path; Sha256 = $sha; Size = $size; Version = [string]$s.version }
    } catch { return $null }
}

# Байты файла с первого источника, где $Check ($bytes -> $null/$false = не подходит) принял ответ. До 2 попыток на источник (сетевой сбой);
# 404 и «не прошёл проверку» - сразу следующий источник. Результат: { Bytes; Url; Checked }. Все источники отказали - исключение со сводкой.
function Get-SetupBytes {
    param([object[]]$Sources, [int]$MaxBytes, [scriptblock]$Check, [int]$TimeoutMs = 20000)
    Initialize-NetSecurity
    $why = [System.Collections.Generic.List[string]]::new()
    foreach ($s in @($Sources)) {
        for ($try = 1; $try -le 2; $try++) {
            try {
                $b = Get-WebBytesOnce $s.Url $MaxBytes $TimeoutMs ($try -gt 1) $s.Flat
                $c = & $Check $b
                if ($c) { Write-Log ('  источник: ' + $s.Name); return [pscustomobject]@{ Bytes = $b; Url = $s.Url; Checked = $c } }
                $why.Add($s.Name + ': файл не прошёл проверку'); Write-Log ('  ' + $s.Name + ': ответ не прошёл проверку (sha256/формат) - пропускаю'); break
            } catch {
                $m = $_.Exception.Message
                if (-not (Test-TransientWebError $_)) { $why.Add($s.Name + ': ' + $m); Write-Log ('  ' + $s.Name + ': ' + $m + ' - пропускаю'); break }
                if ($try -eq 2) { $why.Add($s.Name + ': ' + $m) }
                else { Write-Log ('  сеть: ' + $s.Name + ': ' + $m + ' - повтор'); $d = @($script:SI_WebRetryDelaysMs); if ($d.Count -gt 0 -and [int]$d[0] -gt 0) { Start-Sleep -Milliseconds ([int]$d[0]) } }
            }
        }
    }
    throw ('Не удалось получить ' + [IO.Path]::GetFileName([string]@($Sources)[0].Url) + ' ни из одного источника (' + ($why -join '; ') + ').')
}

# Скачать GlyphixSetup.exe в <Dest>.new, проверить размер и sha256 по app/files.json, поставить на место <Dest>. Ошибка - исключение, прежний файл цел.
function Save-SetupInstaller {
    param([string]$Dest = (Join-Path $script:SI_Home $script:SI_SetupFileName), [string]$BaseUrl = $script:SI_BaseUrl, [string]$MirrorUrl = $script:SI_MirrorBaseUrl, [string]$ReleasesUrl = $script:SI_ReleasesBaseUrl)
    $m = Get-SetupBytes -Sources @(Get-SetupSourceUrls 'app/files.json' $BaseUrl $MirrorUrl $ReleasesUrl) -MaxBytes 1048576 -Check { param($b) ConvertTo-SetupEntry $b }
    $e = $m.Checked
    $f = Get-SetupBytes -Sources @(Get-SetupSourceUrls $script:SI_SetupFileName $BaseUrl $MirrorUrl $ReleasesUrl) -MaxBytes ([int]$e.Size) -Check ({ param($b) $b.Length -eq $e.Size -and (Get-BytesSha256 $b) -eq $e.Sha256 }.GetNewClosure())
    $dir = [IO.Path]::GetDirectoryName($Dest)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $new = $Dest + '.new'
    try {
        [IO.File]::WriteAllBytes($new, $f.Bytes)
        if ((Get-FileSha256 $new) -ne $e.Sha256) { throw 'Установщик повредился при записи на диск.' }
        try { Move-IntoPlace $new $Dest 5000 }
        catch { throw ('Не удалось заменить ' + $Dest + ': ' + $_.Exception.Message + ' Закройте окно установщика Glyphix, если оно открыто, и повторите.') }
    } catch {
        Remove-Item -LiteralPath $new -Force -ErrorAction SilentlyContinue
        throw
    }
    return [pscustomobject]@{ Path = $Dest; Version = $e.Version; Url = $f.Url }
}

# Скачать установщик и запустить его в режиме обновления (без консоли, без прав администратора); возвращает путь к GlyphixSetup.exe.
# Вызывающий (окно приложения) после этого закрывается: установщик ждёт его выхода по PID (до ~20 с), потом закрывает сам.
function Start-AppSelfUpdate {
    param([string]$BaseUrl = $script:SI_BaseUrl, [string]$MirrorUrl = $script:SI_MirrorBaseUrl, [string]$ReleasesUrl = $script:SI_ReleasesBaseUrl, [string]$Dest = (Join-Path $script:SI_Home $script:SI_SetupFileName))
    $s = Save-SetupInstaller -Dest $Dest -BaseUrl $BaseUrl -MirrorUrl $MirrorUrl -ReleasesUrl $ReleasesUrl
    Write-Log ('Обновление приложения до ' + $s.Version + ': запускаю ' + $s.Path + ' /update')
    Start-NonElevated -Path $s.Path -Arguments ('/update /wait-pid ' + $PID)
    return $s.Path
}

# Ссылка для ручной загрузки установщика, если автообновление не вышло: файл последнего релиза (если он уже есть), иначе raw из main.
function Get-SetupFallbackUrl {
    param([string]$BaseUrl = $script:SI_BaseUrl, [string]$ReleasesUrl = $script:SI_ReleasesBaseUrl, [int]$TimeoutMs = 4000)
    $raw = ([string]$BaseUrl).TrimEnd('/') + '/' + $script:SI_SetupFileName
    try {
        $rel = ([string]$ReleasesUrl).TrimEnd('/') + '/' + $script:SI_SetupFileName
        $req = [Net.HttpWebRequest]::Create($rel); $req.Timeout = $TimeoutMs; $req.UserAgent = 'Glyphix/' + (Get-AppVersion)
        $resp = $req.GetResponse(); $resp.Close()          # тело не читаем: нужен только код ответа
        return $rel
    } catch { return $raw }
}

# ---------- AppUserModelID ярлыков ----------
# Ярлыки идут через wscript.exe launch.vbs, поэтому без явного AppUserModelID Start11 и панель задач видят «wscript.exe».
# IPropertyStore ярлыка: PKEY_AppUserModel_ID = {9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}, 5. C# 5 (Windows PowerShell 5.1).
$script:SI_AumidCode = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

namespace GlyphixNative
{
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")]
    internal class CShellLinkObject { }

    [StructLayout(LayoutKind.Sequential, Pack = 4)]
    internal struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PropVariant
    {
        public ushort vt;
        public ushort r1;
        public ushort r2;
        public ushort r3;
        public IntPtr p;
        public IntPtr p2;                          // вторая половина 16-байтовой части PROPVARIANT: sizeof = 24 (x64) / 16 (x86)
    }

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IPropertyStore
    {
        void GetCount(out uint cProps);
        void GetAt(uint iProp, out PropertyKey pkey);
        void GetValue(ref PropertyKey key, out PropVariant pv);
        void SetValue(ref PropertyKey key, ref PropVariant pv);
        void Commit();
    }

    public static class ShortcutAppId
    {
        [DllImport("ole32.dll")]
        private static extern int PropVariantClear(ref PropVariant pvar);

        private static PropertyKey AppIdKey()
        {
            PropertyKey k = new PropertyKey();
            k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3");
            k.pid = 5;
            return k;
        }

        public static void Set(string lnkPath, string appId)
        {
            object link = new CShellLinkObject();
            try
            {
                IPersistFile pf = (IPersistFile)link;
                pf.Load(lnkPath, 2);                       // STGM_READWRITE
                IPropertyStore store = (IPropertyStore)link;
                PropertyKey key = AppIdKey();
                // InitPropVariantFromString - inline-функция propvarutil.h, из propsys.dll её не импортировать: VT_LPWSTR собираем вручную
                PropVariant pv = new PropVariant();
                pv.vt = 31;                                // VT_LPWSTR; строку освобождает PropVariantClear (CoTaskMemFree)
                pv.p = Marshal.StringToCoTaskMemUni(appId);
                try
                {
                    store.SetValue(ref key, ref pv);
                    store.Commit();
                }
                finally
                {
                    PropVariantClear(ref pv);
                }
                pf.Save(lnkPath, true);
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }

        public static string Get(string lnkPath)
        {
            object link = new CShellLinkObject();
            try
            {
                IPersistFile pf = (IPersistFile)link;
                pf.Load(lnkPath, 0);                       // STGM_READ
                IPropertyStore store = (IPropertyStore)link;
                PropertyKey key = AppIdKey();
                PropVariant pv;
                store.GetValue(ref key, out pv);
                try
                {
                    if (pv.vt == 31) { return Marshal.PtrToStringUni(pv.p); }    // VT_LPWSTR
                    return null;
                }
                finally
                {
                    PropVariantClear(ref pv);
                }
            }
            finally
            {
                Marshal.ReleaseComObject(link);
            }
        }
    }
}
'@

# AppUserModelID для готового .lnk; $true/$false, исключений не бросает (ярлык без ID всё равно рабочий)
function Set-ShortcutAppId {
    param([string]$Path, [string]$AppId = $script:SI_AppId)
    try {
        if (-not ('GlyphixNative.ShortcutAppId' -as [type])) { Add-Type -TypeDefinition $script:SI_AumidCode -Language CSharp }
        [GlyphixNative.ShortcutAppId]::Set($Path, $AppId)
        return $true
    } catch {
        Write-Log "AppUserModelID для ярлыка не задан ($Path): $($_.Exception.Message)"
        return $false
    }
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
        Save-FileAtomic $script:SI_StateFile ([System.Text.UTF8Encoding]::new($false).GetBytes($json))
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

# ---------- Сеть: TLS, повторы, зеркало (2.6.0) ----------
# raw.githubusercontent.com из России нестабилен («The underlying connection was closed: An unexpected error occurred on a send»): временные ошибки
# повторяем с паузой 0.5 / 1.5 / 3 с (всего 4 попытки), потом берём то же самое с зеркала jsDelivr (файлы пака сверяются по sha256 из pack.json;
# index.json / pack.json с зеркала могут быть чуть старше - принимаем, в журнале пишем, откуда взято). В тестах базовые адреса и паузы переопределяются.
$script:SI_MirrorBaseUrl = 'https://cdn.jsdelivr.net/gh/F1KS-FK/glyphix@main/'
$script:SI_WebRetryDelaysMs = @(500, 1500, 3000)
$script:SI_PrimaryBadUntil = [DateTime]::MinValue         # до этого момента первичный хост считаем неработающим: сначала зеркало
$script:SI_PrimaryBadMinutes = 3
$script:SI_LastNetFail = $false                           # последняя сетевая операция закончилась сетевой ошибкой (а не ответом сервера «нет такого файла»)
$script:SI_NoNetMsg = 'Нет связи с GitHub — проверь интернет/VPN и нажми ещё раз'
$script:SI_TlsSet = $false

# Какие протоколы включить (числа SecurityProtocolType: Tls12 = 3072, Tls13 = 12288). Всегда TLS 1.2; TLS 1.3 - только на Windows 11 (сборка 22000+)
# и если он есть в перечислении: в Windows 10 у schannel нет клиентского TLS 1.3, и включение Tls13 в .NET 4.8 само даёт
# «The underlying connection was closed: An unexpected error occurred on a send». На Windows 10 бит Tls13 снимаем, даже если он уже стоял. Исключений не бросает.
function Get-NetSecurityValue {
    param([int]$Current = 0, [int]$Build = 0, [bool]$HasTls13 = $false)
    $p = $Current -bor 3072
    if ($HasTls13) { if ($Build -ge 22000) { $p = $p -bor 12288 } else { $p = $p -band (-bnot 12288) } }
    return [int]$p
}

# TLS 1.2 (+ 1.3 на Windows 11) один раз за сеанс; SSL3/TLS1.0 не включаем
function Initialize-NetSecurity {
    if ($script:SI_TlsSet) { return }
    $script:SI_TlsSet = $true
    try {
        $has13 = $false; try { $has13 = ([Enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') } catch { }
        $build = 0; try { $build = [int][Environment]::OSVersion.Version.Build } catch { }
        $cur = 0; try { $cur = [int][Net.ServicePointManager]::SecurityProtocol } catch { }
        $v = Get-NetSecurityValue -Current $cur -Build $build -HasTls13 $has13
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]$v }
        catch { try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]3072 } catch { } }
    } catch { }
}

# адрес того же файла на зеркале ('' - зеркала нет или адрес не из нашего репозитория)
function Get-MirrorUrl {
    param([string]$Url)
    $m = [string]$script:SI_MirrorBaseUrl; $b = [string]$script:SI_BaseUrl
    if (-not $m -or -not $b -or -not $Url -or -not $Url.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return ($m + $Url.Substring($b.Length))
}

function Test-PrimaryBad { return ([DateTime]::UtcNow -lt $script:SI_PrimaryBadUntil) }
function Set-PrimaryBad {
    param([bool]$Bad)
    if ($Bad) {
        if (-not (Test-PrimaryBad)) { Write-Log ('  GitHub (raw.githubusercontent.com) не отвечает - ближайшие ' + $script:SI_PrimaryBadMinutes + ' мин сначала пробую зеркало jsDelivr') }
        $script:SI_PrimaryBadUntil = [DateTime]::UtcNow.AddMinutes($script:SI_PrimaryBadMinutes)
    } else { $script:SI_PrimaryBadUntil = [DateTime]::MinValue }
}

# временная ошибка (стоит повторить): сбой отправки/получения/соединения, таймаут, обрыв, DNS, ответы 5xx / 408 / 429. 404 / 403 / «слишком большой» - нет
function Test-TransientWebError {
    param($Err)
    $ex = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception } else { $Err }
    $depth = 0
    while ($ex -and $depth -lt 8) {
        if ($ex -is [Net.WebException]) {
            if ($ex.Status -eq [Net.WebExceptionStatus]::ProtocolError -and $ex.Response) {
                $c = 0; try { $c = [int]$ex.Response.StatusCode } catch { }
                return ($c -ge 500 -or $c -eq 429 -or $c -eq 408)
            }
            return $true
        }
        if ($ex -is [IO.IOException] -or $ex -is [Net.Sockets.SocketException] -or $ex -is [TimeoutException] -or $ex -is [ObjectDisposedException]) { return $true }
        $ex = $ex.InnerException; $depth++
    }
    return $false
}

# одна попытка; $FreshConn - не переиспользовать соединение (после сбоя «старое» соединение часто мёртво)
function Get-WebBytesOnce {
    param([string]$Url, [int]$MaxBytes = 8388608, [int]$TimeoutMs = 20000, [bool]$FreshConn = $false, [bool]$NoCacheBust = $false)
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    $u = if ($NoCacheBust) { $Url } else { $Url + $sep + 'cb=' + [DateTime]::UtcNow.Ticks }          # против кэша (адреса вложений релиза GitHub - без параметра)
    $req = [Net.HttpWebRequest]::Create($u)
    $req.Method = 'GET'
    $req.UserAgent = 'Glyphix/' + (Get-AppVersion)
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $true
    if ($FreshConn) { try { $req.KeepAlive = $false } catch { } }
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

# GET с повторами (4 попытки: паузы 0.5 / 1.5 / 3 с, только на временных ошибках) и запасным путём через зеркало. Без сети - исключение (SI_LastNetFail = $true).
function Get-WebBytes {
    param([string]$Url, [int]$MaxBytes = 8388608, [int]$TimeoutMs = 20000)
    Initialize-NetSecurity
    $delays = @($script:SI_WebRetryDelaysMs)
    $mirror = Get-MirrorUrl $Url
    $plan = [System.Collections.Generic.List[object]]::new()
    $nP = $delays.Count + 1
    if ($mirror -and (Test-PrimaryBad)) {            # первичный хост недавно не отвечал: зеркало первым, потом он же
        $plan.Add(@($mirror, $true)); for ($i = 0; $i -lt [Math]::Min(2, $nP); $i++) { $plan.Add(@($Url, $false)) }; $plan.Add(@($mirror, $true))
    } else {
        for ($i = 0; $i -lt $nP; $i++) { $plan.Add(@($Url, $false)) }
        if ($mirror) { $plan.Add(@($mirror, $true)); $plan.Add(@($mirror, $true)) }
    }
    $script:SI_LastNetFail = $false
    $first = $null; $netErr = $null
    $mirrorGone = $false        # зеркало ответило «нет такого файла» (jsDelivr @main отстаёт от GitHub до 12 ч): больше его не спрашиваем, но GitHub из плана пробуем
    for ($i = 0; $i -lt $plan.Count; $i++) {
        $u = [string]$plan[$i][0]; $isM = [bool]$plan[$i][1]
        if ($isM -and $mirrorGone) { continue }
        try {
            $b = Get-WebBytesOnce $u $MaxBytes $TimeoutMs ($i -gt 0)
            if ($isM) { Write-Log ('  источник: зеркало jsDelivr (' + ($u -replace '^https?://[^/]+/', '') + ')') } else { Set-PrimaryBad $false }
            $script:SI_LastNetFail = $false          # повтор удался: сетевого сбоя больше нет, флаг не должен «прилипнуть» к чужим ошибкам
            return , $b
        } catch {
            if (-not $first) { $first = $_ }
            if (-not (Test-TransientWebError $_)) {
                if (-not $isM) { $script:SI_LastNetFail = $false; throw }      # GitHub: 404 / 403 / слишком большой ответ - повторять и менять источник нечего
                $mirrorGone = $true
                Write-Log ('  зеркало: ' + ($u -replace '\?.*$', '') + ' - ' + $_.Exception.Message)
                continue
            }
            if (-not $netErr) { $netErr = $_ }
            $script:SI_LastNetFail = $true
            if (-not $isM -and $mirror -and $i -ge 1) { Set-PrimaryBad $true }
            $nx = $i + 1
            while ($nx -lt $plan.Count -and $mirrorGone -and [bool]$plan[$nx][1]) { $nx++ }
            if ($nx -lt $plan.Count) {
                $nextM = [bool]$plan[$nx][1]
                Write-Log ('  сеть: ' + ($u -replace '\?.*$', '') + ' - ' + $_.Exception.Message + $(if ($nextM) { ' - пробую зеркало' } else { ' - повтор ' + ($nx + 1) + '/' + $plan.Count }))
                if (-not $nextM -or $isM) { $d = $delays[[Math]::Min($i, [Math]::Max(0, $delays.Count - 1))]; if ($d -gt 0) { Start-Sleep -Milliseconds ([int]$d) } }
            }
        }
    }
    if ($netErr) { $script:SI_LastNetFail = $true; throw $netErr }       # GitHub не ответил (а зеркало не помогло) - это сбой сети, а не «нет файла»
    throw $first
}

function ConvertFrom-JsonBytes {
    param([byte[]]$Bytes)
    $t = [System.Text.Encoding]::UTF8.GetString($Bytes)
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    return ($t | ConvertFrom-Json)
}

# Уникальное имя временного файла рядом с $Path: <файл>.<PID>.<guid>.tmp (два процесса/потока не пишут в один и тот же .tmp)
function Get-TempSibling {
    param([string]$Path)
    return ('{0}.{1}.{2}.tmp' -f $Path, $PID, [guid]::NewGuid().ToString('N'))
}

# IOException / UnauthorizedAccessException (в том числе когда PowerShell обернул её в MethodInvocationException): файл занят - можно повторить
function Test-TransientIoError {
    param($Ex)
    for ($e = $Ex; $e; $e = $e.InnerException) {
        if ($e -is [IO.IOException] -or $e -is [UnauthorizedAccessException]) { return $true }
    }
    return $false
}

# Поставить готовый временный файл на место $Dest, не удаляя $Dest до того, как новый файл готов:
# есть цель - [IO.File]::Replace (атомарно), нет - [IO.File]::Move. Файл занят (антивирус, индексатор, читатель) - короткие повторы до $TimeoutMs.
# Не вышло - исключение; прежний $Dest остаётся нетронутым, временный файл удаляет вызывающий.
function Move-IntoPlace {
    param([string]$Tmp, [string]$Dest, [int]$TimeoutMs = 3000)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        if (-not (Test-Path -LiteralPath $Tmp -PathType Leaf)) { throw (New-Object IO.FileNotFoundException(('временный файл не найден: ' + $Tmp))) }
        try {
            if (Test-Path -LiteralPath $Dest -PathType Leaf) { [IO.File]::Replace($Tmp, $Dest, [NullString]::Value) } else { [IO.File]::Move($Tmp, $Dest) }
            return
        } catch {
            if (-not (Test-TransientIoError $_.Exception) -or $sw.ElapsedMilliseconds -ge $TimeoutMs) { throw }
            Start-Sleep -Milliseconds 60
        }
    }
}

function Save-FileAtomic {
    param([string]$Path, [byte[]]$Bytes, [int]$TimeoutMs = 3000)
    $dir = [IO.Path]::GetDirectoryName($Path)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = Get-TempSibling $Path
    try {
        [IO.File]::WriteAllBytes($tmp, $Bytes)
        Move-IntoPlace -Tmp $tmp -Dest $Path -TimeoutMs $TimeoutMs
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } }
    }
}

# Остатки прерванных записей (*.tmp) в папке данных: прежний формат <файл>.tmp и новый <файл>.<PID>.<guid>.tmp.
# Трогаем только старше $MinAgeMinutes, чтобы не задеть запись другого процесса. Возвращает число удалённых.
function Remove-StaleTempFiles {
    param([string]$Root = $script:SI_Home, [int]$MinAgeMinutes = 10)
    $n = 0
    $script:SI_TempBytes = [long]0         # сколько байт освободил последний вызов (для «Очистить кэш»)
    if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { return 0 }
    $limit = (Get-Date).AddMinutes(-$MinAgeMinutes)
    try {
        # обход вручную: Get-ChildItem -Recurse в Windows PowerShell 5.1 заходит в junction/symlink; ссылки (папки и файлы) не открываем и не удаляем
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($Root)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            foreach ($f in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparse $f) { continue }
                if ($f.PSIsContainer) { $stack.Push($f.FullName); continue }
                try {
                    if ($f.LastWriteTime -lt $limit -and $f.Name.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) { $len = [long]$f.Length; Remove-Item -LiteralPath $f.FullName -Force -Confirm:$false -ErrorAction Stop; $n++; $script:SI_TempBytes += $len }
                } catch { }
            }
        }
    } catch { }
    if ($n -gt 0) { Write-Log "Удалено остатков *.tmp: $n" }
    return $n
}

function Join-Rel {
    param([string]$Base, [string]$Rel)
    $p = $Base
    foreach ($seg in $Rel.Split('/')) { if ($seg) { $p = Join-Path $p $seg } }
    return $p
}

# ---------- Параллельная загрузка файлов пака ----------
# Пак - сотни мелких файлов с одного хоста; по одному (новый HttpWebRequest, 2 соединения на хост, ожидание каждого ответа) это очень долго.
# Здесь: один общий System.Net.Http.HttpClient (keep-alive, соединения переиспользуются), до $script:SI_DownloadConcurrency запросов одновременно,
# без async/await: окно из Task, ожидание Task.WaitAny. Проверка sha256 и запись (Save-FileAtomic) - только в вызывающем потоке.
$script:SI_HttpClient = $null
$script:SI_DownloadConcurrency = 12                  # одновременных запросов
$script:SI_DownloadTries = 4                         # попыток на файл (первая + 3 повтора; 3-я идёт через зеркало jsDelivr, если оно задано)
$script:SI_RetryDelaysMs = @(500, 1500, 3000)        # пауза перед 2-й, 3-й и 4-й попыткой
$script:SI_HttpTimeoutSec = 45                       # таймаут одного запроса (с телом ответа)
$script:SI_ConnectionLimit = 16                      # ServicePoint.ConnectionLimit для хоста
# лимит соединений задаём сразу при загрузке движка: ServicePoint (в т.ч. для системного прокси/VPN) создаётся с лимитом, действующим в момент первого запроса
try { if ([Net.ServicePointManager]::DefaultConnectionLimit -lt $script:SI_ConnectionLimit) { [Net.ServicePointManager]::DefaultConnectionLimit = $script:SI_ConnectionLimit } } catch { }
$script:SI_FileMaxBytes = 16777216                   # один файл пака больше 16 МБ не принимаем

function Get-HttpClient {
    if ($script:SI_HttpClient) { return $script:SI_HttpClient }
    try { Add-Type -AssemblyName System.Net.Http -ErrorAction Stop } catch { }
    Initialize-NetSecurity
    try {
        if ([Net.ServicePointManager]::DefaultConnectionLimit -lt $script:SI_ConnectionLimit) { [Net.ServicePointManager]::DefaultConnectionLimit = $script:SI_ConnectionLimit }
        [Net.ServicePointManager]::Expect100Continue = $false
    } catch { }
    $h = New-Object System.Net.Http.HttpClientHandler
    try { $h.AllowAutoRedirect = $true; $h.AutomaticDecompression = [Net.DecompressionMethods]::GZip -bor [Net.DecompressionMethods]::Deflate } catch { }
    try {
        $px = [Net.WebRequest]::GetSystemWebProxy()
        $px.Credentials = [Net.CredentialCache]::DefaultCredentials
        $h.Proxy = $px
    } catch { }
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds($script:SI_HttpTimeoutSec)
    try { $c.MaxResponseContentBufferSize = [long]$script:SI_FileMaxBytes } catch { }
    try { [void]$c.DefaultRequestHeaders.UserAgent.TryParseAdd('Glyphix/' + (Get-AppVersion)) } catch { }
    $script:SI_HttpClient = $c
    return $c
}

# Запустить GET (тело ответа читается целиком внутри задачи); вернуть Task<HttpResponseMessage>. Тесты подменяют эту функцию.
function Start-HttpFetch {
    param([string]$Url, [Threading.CancellationToken]$Token)
    $c = Get-HttpClient
    $uri = [Uri]$Url
    try {
        $sp = [Net.ServicePointManager]::FindServicePoint($uri)      # ServicePoint хоста мог появиться раньше (Get-WebBytes) с лимитом 2
        if ($sp.ConnectionLimit -lt $script:SI_ConnectionLimit) { $sp.ConnectionLimit = $script:SI_ConnectionLimit }
    } catch { }
    return $c.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseContentRead, $Token)
}

# Завершённая Task -> байты; сбой запроса, таймаут, не-2xx, слишком большой ответ - исключение
function Receive-HttpFetch {
    param($Task, [long]$MaxBytes = $script:SI_FileMaxBytes)
    if ($Task.IsCanceled) { throw 'таймаут запроса' }
    if ($Task.IsFaulted) { throw $Task.Exception.GetBaseException().Message }
    $resp = $Task.Result
    try {
        if (-not $resp.IsSuccessStatusCode) { throw ('HTTP {0} {1}' -f [int]$resp.StatusCode, $resp.ReasonPhrase) }
        $len = $resp.Content.Headers.ContentLength
        if ($len -and [long]$len -gt $MaxBytes) { throw "ответ больше $MaxBytes байт" }
        $b = $resp.Content.ReadAsByteArrayAsync().Result
        if ($b.Length -gt $MaxBytes) { throw "ответ больше $MaxBytes байт" }
        return , $b
    } finally { $resp.Dispose() }
}

function Format-DownloadSize {
    param([long]$Bytes)
    return ([double]($Bytes / 1048576.0)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' МБ'
}

# Скачать $Items (объекты с Url, Dest, Sha) параллельно. Каждый файл: GET -> sha256 -> Save-FileAtomic (в этом потоке); не совпал/сбой -
# до $MaxTries попыток с паузой (повтор идёт с cb=<ticks> в URL, чтобы обойти устаревший кэш CDN); итог по файлу не влияет на остальные.
# Прогресс: $OnProgress (done, total, bytes) и, если задан $Label, строки журнала «Скачиваю <пак>: 230/508 (7.4 МБ)» (не чаще раза в 300 мс).
# Возвращает { Done; Total; Bytes; Failed = [ { Item; Error } ] }. Исключение/остановка - отменяем запросы в полёте, временных файлов не остаётся.
function Invoke-ParallelDownload {
    param($Items, [string]$Label, [scriptblock]$OnProgress, [int]$Concurrency = $script:SI_DownloadConcurrency, [int]$MaxTries = $script:SI_DownloadTries)
    if ($Concurrency -lt 1) { $Concurrency = 1 }
    if ($MaxTries -lt 1) { $MaxTries = 1 }
    $total = @($Items).Count
    $failed = [System.Collections.Generic.List[object]]::new()
    $res = [pscustomobject]@{ Done = 0; Total = $total; Bytes = [long]0; Failed = $failed }
    $script:SI_LastNetFail = $false                  # флаг сетевой ошибки - на одну операцию: ставится только за файл, не скачанный по сетевой причине
    if ($total -eq 0) { return $res }
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $waiting = [System.Collections.Generic.List[object]]::new()
    $active = [System.Collections.Generic.List[object]]::new()
    foreach ($it in @($Items)) { $pending.Enqueue([pscustomobject]@{ Item = $it; Attempt = 0; Task = $null; StartErr = $null; Ready = [long]0; Mirror = $false }) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $lastLog = [long]-1000
    $cts = New-Object System.Threading.CancellationTokenSource
    $mirrorFiles = 0
    try {
        while ($pending.Count -gt 0 -or $waiting.Count -gt 0 -or $active.Count -gt 0) {
            $now = $sw.ElapsedMilliseconds
            for ($k = $waiting.Count - 1; $k -ge 0; $k--) { if ($waiting[$k].Ready -le $now) { $pending.Enqueue($waiting[$k]); $waiting.RemoveAt($k) } }
            while ($active.Count -lt $Concurrency -and $pending.Count -gt 0) {
                $j = $pending.Dequeue()
                $j.Attempt++; $j.Task = $null; $j.StartErr = $null
                $url = [string]$j.Item.Url
                # источник попытки: обычно первичный (GitHub), 3-я попытка - зеркало; если GitHub недавно не отвечал - зеркало первым, потом GitHub
                $j.Mirror = $false
                $mu = Get-MirrorUrl $url
                if ($mu) {
                    $badNow = Test-PrimaryBad
                    if (($badNow -and ($j.Attempt % 2) -eq 1) -or (-not $badNow -and $j.Attempt -eq 3)) { $url = $mu; $j.Mirror = $true }
                }
                if ($j.Attempt -gt 1) { $url += $(if ($url.Contains('?')) { '&' } else { '?' }) + 'cb=' + [DateTime]::UtcNow.Ticks }
                try { $j.Task = Start-HttpFetch $url $cts.Token } catch { $j.StartErr = $_.Exception.Message }
                $active.Add($j)
            }
            $live = @($active | Where-Object { $_.Task -and -not $_.Task.IsCompleted })
            if ($live.Count -gt 0 -and $live.Count -eq $active.Count) {
                $arr = New-Object 'System.Threading.Tasks.Task[]' $live.Count
                for ($k = 0; $k -lt $live.Count; $k++) { $arr[$k] = $live[$k].Task }
                [void][Threading.Tasks.Task]::WaitAny($arr, 100)
            } elseif ($active.Count -eq 0 -and $waiting.Count -gt 0) {
                Start-Sleep -Milliseconds 40
            }
            for ($k = $active.Count - 1; $k -ge 0; $k--) {
                $j = $active[$k]
                if ($j.Task -and -not $j.Task.IsCompleted) { continue }
                $active.RemoveAt($k)
                $err = $j.StartErr; $b = $null
                if (-not $err) {
                    try {
                        $b = Receive-HttpFetch $j.Task
                        $got = Get-BytesSha256 $b
                        $want = ([string]$j.Item.Sha).ToLowerInvariant()
                        if ($want -and $got -ne $want) { $err = "sha256 не совпал (ожидали $want, получили $got)" }
                        elseif (-not $want -and $j.Item.PSObject.Properties['Check'] -and $j.Item.Check -and -not (& $j.Item.Check $b)) { $err = 'содержимое не похоже на ожидаемый файл' }      # файлы без хэша (превью каталога) - только проверка формата
                        elseif (-not $want -and -not ($j.Item.PSObject.Properties['Check'] -and $j.Item.Check)) { $err = 'нет sha256 и проверки формата' }
                        else { Save-FileAtomic ([string]$j.Item.Dest) $b }
                    } catch { $err = $_.Exception.Message }
                }
                $netErr = [bool]($err -and $err -notmatch '^sha256' -and $err -notmatch '^HTTP 4(?!08|29)' -and $err -notmatch '^ответ больше')       # сбой сети, а не «нет такого файла» / «не тот файл»
                if (-not $err) {
                    if ($j.Mirror) { $mirrorFiles++ } else { Set-PrimaryBad $false }
                    $res.Done++; $res.Bytes += $b.Length
                    $ms = $sw.ElapsedMilliseconds
                    if ($Label -and ($res.Done -eq $total -or ($ms - $lastLog) -ge 300)) { $lastLog = $ms; Write-Log ("Скачиваю ${Label}: $($res.Done)/$total ($(Format-DownloadSize $res.Bytes))") }
                    if ($OnProgress) { try { & $OnProgress $res.Done $total $res.Bytes } catch { } }
                } elseif ($j.Attempt -lt $MaxTries) {
                    if ($netErr -and -not $j.Mirror -and $j.Attempt -ge 2 -and (Get-MirrorUrl ([string]$j.Item.Url))) { Set-PrimaryBad $true }
                    $di = [Math]::Min($j.Attempt - 1, @($script:SI_RetryDelaysMs).Count - 1)
                    $j.Ready = $sw.ElapsedMilliseconds + $(if ($di -ge 0) { [long]@($script:SI_RetryDelaysMs)[$di] } else { 0 })
                    $waiting.Add($j)
                    Write-Log ("  повтор $($j.Attempt)/${MaxTries}: $(([string]$j.Item.Url) -replace '^.*/packs/', '') - $err$(if ($j.Mirror) { ' (зеркало)' })")
                } else {
                    $failed.Add([pscustomobject]@{ Item = $j.Item; Error = $err })
                    if ($netErr) { $script:SI_LastNetFail = $true }
                    Write-Log ("  не скачан: $([string]$j.Item.Url) - $err")
                }
            }
        }
        if ($mirrorFiles -gt 0) { Write-Log ('  источник: зеркало jsDelivr - файлов: ' + $mirrorFiles + ' (остальные с GitHub)') }
    } finally {
        try { $cts.Cancel() } catch { }
        $left = @($active | Where-Object { $_.Task })
        if ($left.Count -gt 0) {
            try { $arr = New-Object 'System.Threading.Tasks.Task[]' $left.Count; for ($k = 0; $k -lt $left.Count; $k++) { $arr[$k] = $left[$k].Task }; [void][Threading.Tasks.Task]::WaitAll($arr, 3000) } catch { }
            foreach ($j in $left) { try { if ($j.Task.IsCompleted -and -not $j.Task.IsFaulted -and -not $j.Task.IsCanceled) { $j.Task.Result.Dispose() } } catch { } }
        }
        try { $cts.Dispose() } catch { }
    }
    return $res
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

# Части пака: 'icons' - .ico и .png иконок (нужны всегда); 'tiles' - плитки Start11 с подписью; 'noname' - плитки без подписи.
# Плитка без файла file_noname при «без подписи» берётся обычная (так выбирает Get-Start11Matches), поэтому такой file относится к обеим частям.
$script:SI_AllParts = @('icons', 'tiles', 'noname', 'auto')       # 'auto' - только auto.json пака (параметры автоиконок; он же входит в 'icons')

# Части пака, нужные при текущих настройках: иконки всегда; плитки включены -> 'tiles', или 'noname' при «без подписи» (обычные тогда не нужны)
function Get-PackParts {
    param([bool]$Tiles = $false, [bool]$NoName = $false)
    $p = @('icons')
    if ($Tiles) { if ($NoName) { $p += 'noname' } else { $p += 'tiles' } }
    return $p
}

# Список файлов пака из pack.json: иконки (.ico/.png) и плитки Start11 (обычная и без подписи); у каждого файла свой sha256 и список частей (Parts).
# $Parts - какие части вернуть (по умолчанию все). Небезопасный путь - исключение (такой pack.json не принимается и не сохраняется).
function Get-PackFileList {
    param([string]$PackDir, [string]$PackUrl, $Manifest, [string[]]$Parts = $script:SI_AllParts)
    $list = [System.Collections.Generic.List[object]]::new()
    $want = @{}; foreach ($w in @($Parts)) { $want[[string]$w] = $true }
    $add = {
        param($Rel, $Sha, $Ext, $FileParts)
        foreach ($fp in $FileParts) { if ($want.ContainsKey($fp)) { $list.Add([pscustomobject]@{ Rel = $Rel; Url = ($PackUrl + $Rel); Dest = (Join-Rel $PackDir $Rel); Sha = $Sha; Ext = $Ext; Parts = $FileParts }); return }
        }
    }
    foreach ($ic in @($Manifest.icons)) {
        $icId = [string]$ic.id
        if ($icId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск иконки с неверным id '$icId'"; continue }
        foreach ($pair in @(@('ico', '.ico'), @('png', '.png'))) {
            $rel = [string]$ic.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel @($pair[1]))) { throw "недопустимый путь файла '$rel'" }
            & $add $rel ([string]$ic.($pair[0] + '_sha256')) $pair[1] @('icons')
        }
    }
    $autoEnt = $Manifest.PSObject.Properties['auto']                          # auto.json: параметры автоиконок (нет записи - пак без автоиконок)
    if ($autoEnt -and $autoEnt.Value -and [string]$autoEnt.Value.file) {
        $arel = [string]$autoEnt.Value.file
        if (-not (Test-SafeRel $arel @('.json'))) { throw "недопустимый путь файла '$arel'" }
        & $add $arel ([string]$autoEnt.Value.sha256) '.json' @('icons', 'auto')
    }
    foreach ($tl in @($Manifest.tiles)) {
        if (-not $tl) { continue }
        $tId = [string]$tl.id
        if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { Write-Log "  пропуск плитки с неверным id '$tId'"; continue }
        $hasNoName = [bool][string]$tl.file_noname
        foreach ($pair in @(@('file', 'sha256'), @('file_noname', 'sha256_noname'))) {
            $rel = [string]$tl.($pair[0])
            if (-not $rel) { continue }
            if (-not (Test-SafeRel $rel $script:SI_TileExts)) { throw "недопустимый путь файла '$rel'" }
            $fp = if ($pair[0] -eq 'file_noname') { @('noname') } elseif ($hasNoName) { @('tiles') } else { @('tiles', 'noname') }
            & $add $rel ([string]$tl.($pair[1])) ([IO.Path]::GetExtension($rel).ToLowerInvariant()) $fp
        }
    }
    return $list.ToArray()
}

# Скачать недостающие/изменённые файлы списка (каждый проверяется по sha256; локальный файл с верным sha не качаем). Качает параллельно
# (Invoke-ParallelDownload); прогресс - строки журнала «Скачиваю <пак>: 230/508 (7.4 МБ)» (GUI показывает их в строке состояния).
# Остальные файлы сохраняются, даже если один не скачался; тогда в конце - исключение со списком не скачанных. Возвращает число скачанных файлов.
function Sync-PackFiles {
    param($Files, [string]$Label, [switch]$Force)
    $todo = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($f in @($Files)) {
        $sha = ([string]$f.Sha).ToLowerInvariant()
        if ($sha -notmatch '^[0-9a-f]{64}$') { throw "нет корректного sha256 для $($f.Dest)" }
        if ($seen.ContainsKey([string]$f.Dest)) { continue }
        $seen[[string]$f.Dest] = $true
        $have = $false
        if (-not $Force -and (Test-Path -LiteralPath $f.Dest -PathType Leaf)) { try { $have = ((Get-FileSha256 $f.Dest) -eq $sha) } catch { } }
        if (-not $have) { $todo.Add([pscustomobject]@{ Rel = $f.Rel; Url = $f.Url; Dest = $f.Dest; Sha = $sha }) }
    }
    $n = $todo.Count
    if ($n -gt 0) {
        Write-Log "Скачиваю ${Label}: файлов $n"
        $r = Invoke-ParallelDownload -Items $todo.ToArray() -Label $Label
        if ($r.Failed.Count -gt 0) {
            $names = @($r.Failed | Select-Object -First 3 | ForEach-Object { '{0} ({1})' -f $_.Item.Rel, $_.Error }) -join '; '
            $more = if ($r.Failed.Count -gt 3) { " и ещё $($r.Failed.Count - 3)" } else { '' }
            throw "не скачано файлов пака ${Label}: $($r.Failed.Count) из $n (скачано $($r.Done)): $names$more"
        }
    }
    return $n
}

# pack.json и превью пака (иконки и плитки здесь НЕ качаем - см. Install-Pack); возвращает число скачанных файлов
# Тихое фоновое обновление можно остановить: $Cancel - синхронизированная hashtable с ключом Cancel (ставит GUI, когда начинается Применить / Откат / Удаление).
# Остановленное обновление новых файлов не пишет.
function Test-RefreshCancelled {
    param($Cancel)
    try { return [bool]($Cancel -and $Cancel['Cancel']) } catch { return $false }
}

# версия локального pack.json пака $Id ('' - файла нет, не читается, другой id или версия не разбирается)
function Get-LocalPackVersion {
    param([string]$ManPath, [string]$Id)
    try {
        if (-not (Test-Path -LiteralPath $ManPath -PathType Leaf)) { return '' }
        $j = Read-JsonFile $ManPath
        if ([string]$j.id -ne $Id) { return '' }
        $v = [string]$j.version
        if ($null -eq (ConvertTo-VersionParts $v)) { return '' }
        return $v
    } catch { return '' }
}

# $A строго новее $B (числовое сравнение по частям); версия $B не указана / не разбирается - $false (нечем доказать, что локальная новее)
function Test-VersionNewer {
    param([string]$A, [string]$B)
    $c = Compare-AppVersion $A $B
    return ($null -ne $c -and $c -gt 0)
}

function Update-OnePack {
    param([string]$BaseUrl, $Entry, [bool]$Force, $Cancel = $null)
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

    # никогда не откатываем пак назад: зеркало jsDelivr (@main) отстаёт от GitHub до 12 ч, и его index.json / pack.json могут быть старше локального
    if ($needManifest) {
        $lv = Get-LocalPackVersion $manLocal $id
        if ($lv -and (Test-VersionNewer $lv ([string]$Entry.version))) { Write-Log ("  $id : в index.json версия $($Entry.version), локальная $lv новее - оставляю локальный pack.json"); return 0 }
    }

    if (Test-RefreshCancelled $Cancel) { return 0 }
    $manBytes = $null
    if ($needManifest) {
        $manBytes = Get-WebBytes ($BaseUrl + $manRel) 4194304
        if ((Get-BytesSha256 $manBytes) -ne $manSha) { throw 'sha256 pack.json не совпал с index.json' }
        $man = ConvertFrom-JsonBytes $manBytes
        $lv2 = Get-LocalPackVersion $manLocal $id
        if ($lv2 -and (Test-VersionNewer $lv2 ([string]$man.version))) { Write-Log ("  $id : полученный pack.json (версия $($man.version)) старше локального ($lv2) - оставляю локальный"); return 0 }
    } else {
        $man = Read-JsonFile $manLocal
    }
    if ([string]$man.id -ne $id) { throw "id в pack.json ('$($man.id)') не совпал с index.json" }
    [void](Get-PackFileList $packDir $packUrl $man)          # пути файлов проверяем до сохранения pack.json

    if (Test-RefreshCancelled $Cancel) { return 0 }
    $prevRel = [string]$man.preview
    if ($prevRel -and $Entry.preview_sha256) {
        if (-not (Test-SafeRel $prevRel @('.png'))) { throw "недопустимый preview '$prevRel'" }
        $downloaded += (Sync-File ($packUrl + $prevRel) (Join-Rel $packDir $prevRel) ([string]$Entry.preview_sha256) '.png' -Force:$Force)
    }
    # pack.json пишем последним: если что-то оборвалось, следующая проверка догрузит остальное
    if (Test-RefreshCancelled $Cancel) { return $downloaded }
    if ($needManifest) { Save-FileAtomic $manLocal $manBytes; $downloaded++ }
    return $downloaded
}

# Метка «часть пака проверена по текущему pack.json»: иконки - .synced (как в прежних версиях), плитки - .synced_tiles, плитки без подписи - .synced_noname
function Get-PackMarkerName {
    param([string]$Part = 'icons')
    if ($Part -eq 'icons' -or -not $Part) { return '.synced' }
    return ('.synced_' + $Part)
}

# Файлы части пака на диске: 'ready' - всё на месте и проверено по текущему pack.json (метка);
# 'stale' - файлы на месте, но не проверены (pack.json обновился / кэш перенесён из прежней версии); 'none' - чего-то не хватает.
# Нет файлов в этой части (в паке нет плиток) - 'ready'.
function Get-PackState {
    param([string]$PackDir, [string[]]$Files, [string]$Part = 'icons')
    if (@($Files).Count -eq 0) { return 'ready' }
    foreach ($f in @($Files)) { if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { return 'none' } }
    try {
        $mk = Join-Path $PackDir (Get-PackMarkerName $Part)
        if (Test-Path -LiteralPath $mk -PathType Leaf) {
            if (([IO.File]::ReadAllText($mk)).Trim() -eq (Get-FileSha256 (Join-Path $PackDir 'pack.json'))) { return 'ready' }
        }
    } catch { }
    return 'stale'
}

# Скачать файлы ОДНОГО пака (по требованию: при «Применить» или «Скачать»). Сначала сверяем pack.json с index.json
# (пак мог обновиться), потом качаем только недостающие/изменённые файлы нужных частей ($Parts: icons, tiles, noname; по умолчанию все)
# параллельно; каждый - с проверкой sha256. Ошибка сети/sha - исключение (уже скачанные файлы остаются, метка «готово» не ставится).
function Install-Pack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string]$BaseUrl = $script:SI_BaseUrl, [switch]$Force, [string[]]$Parts = $script:SI_AllParts, [string]$LabelPrefix = '')
    if ($Id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { throw "недопустимый id пака '$Id'" }
    $Parts = @($Parts | Where-Object { $script:SI_AllParts -contains $_ })
    if ($Parts.Count -eq 0) { $Parts = @('icons') }
    Initialize-NetSecurity
    $script:SI_LastNetFail = $false
    if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
    $idx = ConvertFrom-JsonBytes (Get-WebBytes ($BaseUrl + 'index.json') 1048576)
    $entry = @($idx.packs) | Where-Object { [string]$_.id -eq $Id } | Select-Object -First 1
    if (-not $entry) { throw "пака '$Id' нет в index.json" }
    $d0 = Update-OnePack $BaseUrl $entry ([bool]$Force)
    $packDir = Join-Path $script:SI_PacksDir $Id
    $manPath = Join-Path $packDir 'pack.json'
    # pack.json держим в памяти: пока качаются сотни файлов, на диске с ним могло что-то случиться (антивирус, чистильщик, другой процесс)
    $manBytes = [IO.File]::ReadAllBytes($manPath)
    $manSha = Get-BytesSha256 $manBytes
    $man = ConvertFrom-JsonBytes $manBytes
    $files = @(Get-PackFileList $packDir ($BaseUrl + ([string]$entry.path).Trim('/') + '/') $man -Parts $Parts)
    $label = if ($man.name) { [string]$man.name } else { $Id }
    $n = Sync-PackFiles $files ($LabelPrefix + $label) -Force:$Force
    if (-not (Test-Path -LiteralPath $manPath -PathType Leaf)) {
        Write-Log "  pack.json пака $label пропал с диска во время загрузки - записываю заново"
        Save-FileAtomic $manPath $manBytes
    } elseif ((Get-FileSha256 $manPath) -ne $manSha) {
        Write-Log "  pack.json пака $label изменился во время загрузки - записываю проверенную версию"
        Save-FileAtomic $manPath $manBytes
    }
    foreach ($part in $Parts) { Save-FileAtomic (Join-Path $packDir (Get-PackMarkerName $part)) ([System.Text.UTF8Encoding]::new($false).GetBytes($manSha)) }
    Write-Log $(if ($n -gt 0) { "Пак ${label}: скачано файлов $n" } else { "Пак ${label}: все файлы на месте" })
    # остатки прежних версий (старые .png-плитки после перехода на .jpg и т.п.): файлы, которых нет в свежем pack.json (по ВСЕМ частям), если на них ничто не ссылается
    try {
        $expected = @(Get-PackFileList $packDir ($BaseUrl + ([string]$entry.path).Trim('/') + '/') $man | ForEach-Object { [string]$_.Dest })
        if ($man.preview -and (Test-SafeRel ([string]$man.preview) @('.png'))) { $expected += (Join-Rel $packDir ([string]$man.preview)) }
        [void](Clear-PackLeftovers $packDir $expected)
    } catch { Write-Log ('  остатки прежней версии пака не удалены: ' + $_.Exception.Message) }
    return [pscustomobject]@{ Id = $Id; Downloaded = ($n + $d0); Files = $files.Count; Parts = $Parts }
}

# Несколько паков за раз (выбор на карточках, 2.6.0): по очереди Install-Pack (файлы каждого пака качаются параллельно, Invoke-ParallelDownload).
# Уже скачанный свежий пак (все нужные части 'ready' по текущему pack.json) пропускаем. Общий прогресс - в строках журнала: «Скачиваю [2/5] Gold: 230/508 (7.4 МБ)».
# Ошибка одного пака не останавливает остальные. Возвращает { Total; Downloaded (паков); Files; Skipped (id); Failed (@{ Id; Error }); Message }.
function Install-Packs {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Ids, [string]$BaseUrl = $script:SI_BaseUrl, [string[]]$Parts = @('icons'))
    $ids = @($Ids | Where-Object { $_ } | Select-Object -Unique)
    $total = $ids.Count
    $done = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()
    $files = 0; $i = 0
    foreach ($id in $ids) {
        $i++
        $script:SI_LastNetFail = $false          # у каждого пака своя сетевая оценка: сбой одного не делает «Нет связи» чужую ошибку другого
        try {
            if ($id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { throw "недопустимый id пака '$id'" }
            $pk = @(Get-Packs -OnlyId $id) | Select-Object -First 1
            $fresh = $false
            if ($pk) {
                $fresh = $true
                foreach ($part in @($Parts)) {
                    $pf = if ($pk.PartFiles.ContainsKey([string]$part)) { @($pk.PartFiles[[string]$part]) } else { @($pk.Files) }
                    if ((Get-PackState ([string]$pk.Dir) $pf ([string]$part)) -ne 'ready') { $fresh = $false; break }
                }
            }
            if ($fresh) { $skipped.Add($id); Write-Log "Пакет $i из ${total}: $id уже скачан"; continue }
            Write-Log "Скачиваю выбранные: пак $i из ${total} ($id)"
            $r = Install-Pack -Id $id -BaseUrl $BaseUrl -Parts $Parts -LabelPrefix "[$i/$total] "
            $files += [int]$r.Downloaded
            $done.Add($id)
        } catch {
            $em = $_.Exception.Message
            Write-Log "  пак ${id}: ошибка - $em"
            if ($script:SI_LastNetFail -or (Test-NetworkErrorText $em)) { $em = $script:SI_NoNetMsg }
            $failed.Add([pscustomobject]@{ Id = $id; Error = $em })
        }
    }
    $msg = "Скачано паков: $($done.Count) (файлов: $files)"
    if ($skipped.Count -gt 0) { $msg += ", уже скачаны: $($skipped.Count)" }
    if ($failed.Count -gt 0) { $msg += ", ошибок: $($failed.Count)" }
    Write-Log $msg
    return [pscustomobject]@{ Total = $total; Downloaded = $done.Count; Files = $files; Skipped = $skipped.ToArray(); Failed = $failed.ToArray(); Done = $done.ToArray(); Message = $msg }
}

# Перед применением: нужные части пака не скачаны / не проверены - докачиваем (только этот пак, только эти части; по умолчанию - иконки).
# Всё на месте, но сети нет - работаем из кэша.
function Confirm-PackFiles {
    param($Pack, [string[]]$Parts = @('icons'))
    if (-not $Pack -or -not $Pack.PSObject.Properties['Dir'] -or -not $Pack.PSObject.Properties['Files']) { return }
    $pf = if ($Pack.PSObject.Properties['PartFiles'] -and $Pack.PartFiles) { $Pack.PartFiles } else { @{} }
    $need = @(); $worst = 'ready'
    foreach ($part in @($Parts)) {
        $files = if ($pf.ContainsKey([string]$part)) { @($pf[[string]$part]) } else { @($Pack.Files) }
        $s = Get-PackState ([string]$Pack.Dir) $files ([string]$part)
        if ($s -eq 'ready') { continue }
        $need += $part
        if ($s -eq 'none') { $worst = 'none' } elseif ($worst -eq 'ready') { $worst = 'stale' }
    }
    if ($need.Count -eq 0) { return }
    try {
        [void](Install-Pack -Id ([string]$Pack.Id) -Parts $need)
    } catch {
        if ($worst -eq 'stale') { Write-Log ('Не удалось проверить файлы пака (' + $_.Exception.Message + ') - использую сохранённые'); return }
        throw
    }
}

function New-RefreshCancelledResult {
    param([int]$Downloaded = 0, [string[]]$Updated = @())
    return [pscustomobject]@{ Ok = $false; Cancelled = $true; Downloaded = $Downloaded; Updated = @($Updated); Errors = @(); Message = 'Обновление остановлено' }
}

# index.json с сервера старше сохранённого: его поле updated раньше, или у какого-то пака версия ниже (откат не принимаем)
function Test-IndexOlderThanLocal {
    param([string]$LocalPath, $Remote)
    try {
        if (-not (Test-Path -LiteralPath $LocalPath -PathType Leaf)) { return $false }
        $loc = Read-JsonFile $LocalPath
        $a = [DateTime]::MinValue; $b = [DateTime]::MinValue
        $st = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        if ($loc.updated -and $Remote.updated -and [DateTime]::TryParse([string]$loc.updated, [Globalization.CultureInfo]::InvariantCulture, $st, [ref]$a) -and [DateTime]::TryParse([string]$Remote.updated, [Globalization.CultureInfo]::InvariantCulture, $st, [ref]$b)) {
            if ($a -gt $b) { return $true }
        }
        $lv = @{}; foreach ($e in @($loc.packs)) { $lv[[string]$e.id] = [string]$e.version }
        foreach ($e in @($Remote.packs)) { if ($lv.ContainsKey([string]$e.id) -and (Test-VersionNewer $lv[[string]$e.id] ([string]$e.version))) { return $true } }
    } catch { }
    return $false
}

function Update-Packs {
    [CmdletBinding()]
    param([string]$BaseUrl = $script:SI_BaseUrl, [switch]$Force, $Cancel = $null)
    $errors = [System.Collections.Generic.List[string]]::new()
    $updated = [System.Collections.Generic.List[string]]::new()
    $total = 0
    Initialize-NetSecurity
    $script:SI_LastNetFail = $false
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
    if (Test-RefreshCancelled $Cancel) { return (New-RefreshCancelledResult) }
    try {
        $ixLocal = Join-Path $script:SI_PacksDir 'index.json'
        if (Test-IndexOlderThanLocal $ixLocal $idx) { Write-Log 'index.json на сервере (зеркало?) старше локального - локальный оставляю' }
        else { Save-FileAtomic $ixLocal $idxBytes }     # порядок паков в галерее
    } catch { Write-Log ('index.json не сохранён: ' + $_.Exception.Message) }
    # 3.0: каталог вариантов (variants.json + превью) качается вместе с index.json, теми же повторами и зеркалом; его сбой не считается ошибкой паков
    $vres = $null
    try { $vres = Update-VariantCatalog -BaseUrl $BaseUrl -Index $idx -Cancel $Cancel } catch { Write-Log ('Каталог вариантов: ' + $_.Exception.Message) }
    # на каждом запуске - только index.json, pack.json и превью всех паков; иконки и плитки - по требованию (Install-Pack)
    $entries = @($idx.packs)
    $i = 0
    foreach ($entry in $entries) {
        $i++
        if (Test-RefreshCancelled $Cancel) { Write-Log 'Обновление паков остановлено: началась другая операция'; return (New-RefreshCancelledResult -Downloaded $total -Updated $updated.ToArray()) }
        $pid2 = [string]$entry.id
        Write-Log "Проверяю паки: $i/$($entries.Count) ($pid2)"
        try {
            $n = Update-OnePack $BaseUrl $entry ([bool]$Force) $Cancel
            $total += $n
            if ($n -gt 0) { $updated.Add($pid2); Write-Log "  $pid2 : загружено файлов $n" } else { Write-Log "  $pid2 : актуален" }
        } catch {
            $errors.Add("[$pid2] " + $_.Exception.Message)
            Write-Log "  ошибка в паке $pid2 : $($_.Exception.Message)"
        }
    }
    if (Test-RefreshCancelled $Cancel) { return (New-RefreshCancelledResult -Downloaded $total -Updated $updated.ToArray()) }
    if ($errors.Count -eq 0) {
        $st = Read-State; $st['LastUpdate'] = (Get-Date).ToString('s'); Save-State $st
    }
    $msg = if ($errors.Count -gt 0) { "Обновление завершено с ошибками: $($errors.Count)" } elseif ($total -gt 0) { "Паки обновлены (файлов: $total)" } else { 'Все паки актуальны' }
    Write-Log $msg
    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Downloaded = $total; Updated = $updated.ToArray(); Errors = $errors.ToArray(); Message = $msg; Variants = $vres }
}

# ---------- Локальные паки ----------
# Паки читаются из pack.json (он есть у всех паков после Update-Packs); сами файлы иконок могут быть ещё не скачаны.
# Поэтому пути IcoPath/PngPath/TilePath - «где файл должен лежать», State - 'ready' | 'stale' | 'none' по иконкам (см. Get-PackState);
# PartFiles - файлы по частям (icons / tiles / noname), Files - все.
function Get-Packs {
    param([string]$OnlyId = '')          # прочитать с диска только этот пак (папка packs\<id>); имя не $Id: переменная $id ниже - id очередного пака
    $res = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $script:SI_PacksDir)) { return @() }
    $order = @{}
    try {
        $ixf = Join-Path $script:SI_PacksDir 'index.json'
        if (Test-Path -LiteralPath $ixf) { $k = 0; foreach ($e in @((Read-JsonFile $ixf).packs)) { $order[[string]$e.id] = $k; $k++ } }
    } catch { }
    foreach ($d in (Get-ChildItem -LiteralPath $script:SI_PacksDir -Directory -ErrorAction SilentlyContinue)) {
        if ($OnlyId -and $d.Name -ne $OnlyId) { continue }
        $mf = Join-Path $d.FullName 'pack.json'
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $j = Read-JsonFile $mf
            $mSha = ''; try { $mSha = Get-FileSha256 $mf } catch { }
            $id = [string]$j.id
            if ($id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { continue }
            $files = [System.Collections.Generic.List[string]]::new()
            $pAuto = [System.Collections.Generic.List[string]]::new()
            $pIcons = [System.Collections.Generic.List[string]]::new(); $pTiles = [System.Collections.Generic.List[string]]::new(); $pNoName = [System.Collections.Generic.List[string]]::new()
            $tileMap = @{}
            foreach ($tl in @($j.tiles)) {
                if (-not $tl) { continue }
                $tId = [string]$tl.id
                if ($tId -notmatch '^[A-Za-z0-9_\-]+$') { continue }
                $tp = $null; $tn = $null
                if ($tl.file -and (Test-SafeRel ([string]$tl.file) $script:SI_TileExts)) { $tp = Join-Rel $d.FullName ([string]$tl.file); $files.Add($tp); $pTiles.Add($tp) }
                if ($tl.file_noname -and (Test-SafeRel ([string]$tl.file_noname) $script:SI_TileExts)) { $tn = Join-Rel $d.FullName ([string]$tl.file_noname); $files.Add($tn); $pNoName.Add($tn) }
                if ($tp -and -not $tn) { $pNoName.Add($tp) }                  # нет плитки без подписи - при «без подписи» берётся обычная
                if ($tp -or $tn) { $tileMap[$tId] = @{ Tile = $tp; NoName = $tn } }
            }
            $icons = [System.Collections.Generic.List[object]]::new()
            foreach ($ic in @($j.icons)) {
                if (-not $ic.ico -or -not (Test-SafeRel ([string]$ic.ico) @('.ico'))) { continue }
                $ico = Join-Rel $d.FullName ([string]$ic.ico)
                $files.Add($ico); $pIcons.Add($ico)
                $png = $null
                if ($ic.png -and (Test-SafeRel ([string]$ic.png) @('.png'))) { $png = Join-Rel $d.FullName ([string]$ic.png); $files.Add($png); $pIcons.Add($png) }
                $mn = @(); $mx = @()
                if ($ic.match) { $mn = @($ic.match.names | ForEach-Object { [string]$_ }); $mx = @($ic.match.exes | ForEach-Object { [string]$_ }) }
                $tilePath = $null; $tileNoName = $null
                if ($tileMap.ContainsKey([string]$ic.id)) { $tilePath = $tileMap[[string]$ic.id].Tile; $tileNoName = $tileMap[[string]$ic.id].NoName }
                $icons.Add([pscustomobject]@{ Id = [string]$ic.id; Name = [string]$ic.name; Group = (Get-GroupKey $ic.group); IcoPath = $ico; PngPath = $png; Names = $mn; Exes = $mx; TilePath = $tilePath; TileNoNamePath = $tileNoName })
            }
            $autoDecl = $false; $autoPath = $null; $autoSha = ''; $autoP = $null
            $au = $j.PSObject.Properties['auto']                                   # auto.json есть у пака, только если объявлен в pack.json (старые паки - без автоиконок)
            if ($au -and $au.Value -and [string]$au.Value.file -and (Test-SafeRel ([string]$au.Value.file) @('.json'))) {
                $autoDecl = $true; $autoSha = [string]$au.Value.sha256
                $autoPath = Join-Rel $d.FullName ([string]$au.Value.file)
                $files.Add($autoPath); $pIcons.Add($autoPath); $pAuto.Add($autoPath)
                if (Test-Path -LiteralPath $autoPath -PathType Leaf) { $autoP = Read-AutoParams $autoPath $autoSha }
            }
            $prev = $null
            if ($j.preview -and (Test-SafeRel ([string]$j.preview) @('.png'))) {
                $pv = Join-Rel $d.FullName ([string]$j.preview)
                if (Test-Path -LiteralPath $pv) { $prev = $pv }
            }
            $fileArr = $files.ToArray()
            $partFiles = @{ icons = $pIcons.ToArray(); tiles = $pTiles.ToArray(); noname = $pNoName.ToArray(); auto = $pAuto.ToArray() }
            $state = Get-PackState $d.FullName $partFiles['icons'] 'icons'          # «готов» = иконки; плитки докачиваются при применении плиток
            $res.Add([pscustomobject]@{
                Id = $id; Name = [string]$j.name; Version = [string]$j.version; Author = [string]$j.author
                License = [string]$j.license; Description = [string]$j.description
                IconCount = $icons.Count; Dir = $d.FullName; Preview = $prev; Icons = $icons.ToArray()
                Files = $fileArr; PartFiles = $partFiles; State = $state; Ready = ($state -eq 'ready'); ManifestSha = $mSha
                Auto = $autoP; AutoDeclared = $autoDecl; AutoPath = $autoPath; AutoSha = $autoSha
            })
        } catch { Write-Log "пак $($d.Name) не прочитан: $($_.Exception.Message)" }
    }
    return @($res | Sort-Object @{ Expression = { if ($order.ContainsKey($_.Id)) { [int]$order[$_.Id] } else { 1000 } } }, @{ Expression = { $_.Name } })
}

# ---------- Свежий пак перед применением (2.5.0) ----------
# текст ошибки похож на сетевую (.NET: «The underlying connection was closed», таймаут, DNS, отказ в соединении и т.п.)
function Test-NetworkErrorText {
    param([string]$Text)
    return [bool]($Text -match '(?i)underlying connection|unexpected error occurred on a send|unable to connect|could not be resolved|name or service not known|actively refused|connection (was )?(closed|reset|refused)|timed out|timeout|time.?out|the request was aborted|удал[её]нный сервер|базовое соединение|не удаётся соединиться|таймаут|HTTP 5\d\d|HTTP 429|WebException|GetResponse')
}

# Применять можно только пак, прочитанный с диска ПОСЛЕ обновления index.json / pack.json и докачки файлов: объект Get-Packs, снятый раньше,
# мог описывать старую версию (другие файлы, другие расширения плиток) - так в 2.4.2 применялся кэш 2.1.0, а новые файлы качались уже после.
# Sync-PackForApply = Install-Pack (index + pack.json + нужные части) и повторное чтение пака с диска. Нет сети - работаем из кэша, если нужные файлы
# на месте (иначе ошибка). Объект помечен Synced/SyncedParts: Apply-Pack / Apply-Start11Tiles второй раз его не обновляют.
function Sync-PackForApply {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, [string[]]$Parts = @('icons'), [string]$BaseUrl = $script:SI_BaseUrl)
    $err = ''
    $script:SI_LastNetFail = $false
    try { [void](Install-Pack -Id $Id -Parts $Parts -BaseUrl $BaseUrl) } catch { $err = $_.Exception.Message }
    $netFail = [bool]($err -and ($script:SI_LastNetFail -or (Test-NetworkErrorText $err)))
    $pk = @(Get-Packs -OnlyId $Id) | Select-Object -First 1
    if (-not $pk) { if ($err) { Write-Log ('  причина: ' + $err); if ($netFail) { throw $script:SI_NoNetMsg }; throw $err }; throw "пак '$Id' не найден" }
    if ($err) {
        foreach ($part in @($Parts)) {
            $files = if ($pk.PartFiles.ContainsKey([string]$part)) { @($pk.PartFiles[[string]$part]) } else { @($pk.Files) }
            if ((Get-PackState ([string]$pk.Dir) $files ([string]$part)) -eq 'none') { Write-Log ('  причина: ' + $err); if ($netFail) { throw $script:SI_NoNetMsg }; throw $err }
        }
        Write-Log ('Не удалось обновить пак с GitHub — применена сохранённая версия ' + [string]$pk.Version)
        Write-Log ('  причина: ' + $err)
    }
    $pk | Add-Member -NotePropertyName FromCache -NotePropertyValue ([bool]$err) -Force      # пак применяется из кэша: обновить с GitHub не удалось
    $pk | Add-Member -NotePropertyName Synced -NotePropertyValue $true -Force
    $pk | Add-Member -NotePropertyName SyncedParts -NotePropertyValue @($Parts) -Force
    return $pk
}

# Пак для применения: уже свежий (Synced, нужные части) - как есть; иначе Sync-PackForApply. Replaced = pack.json отличается от переданного объекта
# (тогда ярлыки/плитки, найденные по старому паку, надо сопоставить заново).
function Resolve-FreshPack {
    param($Pack, [string[]]$Parts = @('icons'))
    $same = [pscustomobject]@{ Pack = $Pack; Replaced = $false }
    if (-not $Pack) { return $same }
    foreach ($pn in @('Id', 'Dir', 'Files')) { if (-not $Pack.PSObject.Properties[$pn]) { return $same } }
    if ($Pack.PSObject.Properties['Synced'] -and $Pack.Synced) {
        $have = @($Pack.SyncedParts)
        if (@($Parts | Where-Object { $have -notcontains $_ }).Count -eq 0) { return $same }
    }
    $fresh = Sync-PackForApply -Id ([string]$Pack.Id) -Parts $Parts
    $old = if ($Pack.PSObject.Properties['ManifestSha']) { [string]$Pack.ManifestSha } else { '' }
    return [pscustomobject]@{ Pack = $fresh; Replaced = [bool]($old -and $old -ne [string]$fresh.ManifestSha) }
}

# Ярлыки, найденные по старому паку -> те же ярлыки (по пути), сопоставленные заново по свежему
function Convert-ItemsToFreshPack {
    param($Items, $Pack, [bool]$Auto = $false)
    $paths = @{}; $all = $false
    foreach ($m in @($Items)) {
        if (-not $m -or -not $m.PSObject.Properties['Path']) { continue }
        $paths[([string]$m.Path).ToLowerInvariant()] = $true
        if (Test-CommonLocation ([string]$m.Location)) { $all = $true }
    }
    if ($paths.Count -eq 0) { return @() }
    return @(Get-Matches -Pack $Pack -AllUsers:$all -Auto:$Auto | Where-Object { $paths.ContainsKey(([string]$_.Path).ToLowerInvariant()) })
}

function Convert-TileItemsToFreshPack {
    param($Items, $Pack, [bool]$NoName = $false, [bool]$Auto = $false)
    $ids = @{}
    foreach ($m in @($Items)) { if ($m -and $m.PSObject.Properties['TileId']) { $ids[[string]$m.TileId] = $true } }
    if ($ids.Count -eq 0) { return @() }
    return @(Get-Start11Matches -Pack $Pack -NoName:$NoName -Auto:$Auto | Where-Object { $ids.ContainsKey([string]$_.TileId) })
}

# ---------- Применённые иконки: пути зависят от содержимого (2.5.0) ----------
# Ярлык указывает не на файл пака, а на копию applied\<пак>\<id>.<sha8>.ico: изменился рисунок - изменился путь, значит изменилась и иконка ярлыка
# (кэш иконок Windows ключуется путём, на новый путь он ответить прежней картинкой не может). Старые копии того же id, на которые никто
# не ссылается, удаляются. Всё внутри нашей папки данных.
function Get-AppliedIconDest {
    param([string]$PackId, [string]$IconId, [string]$Src)
    if (-not $Src -or $PackId -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$' -or $IconId -notmatch '^[A-Za-z0-9_\-]+$') { return $null }
    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) { return $null }
    try { $sha = Get-FileSha256 $Src } catch { return $null }
    return (Join-Path (Join-Path $script:SI_AppliedDir $PackId) ($IconId + '.' + $sha.Substring(0, 8) + '.ico'))
}

# скопировать .ico пака в applied\ (если такой копии с тем же содержимым ещё нет); возвращает путь копии
function Publish-AppliedIcon {
    param([string]$PackId, [string]$IconId, [string]$Src)
    if ($PackId -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$' -or $IconId -notmatch '^[A-Za-z0-9_\-]+$') { throw "неверный id иконки '$IconId'" }
    $bytes = [IO.File]::ReadAllBytes($Src)
    $sha = Get-BytesSha256 $bytes
    $dest = Join-Path (Join-Path $script:SI_AppliedDir $PackId) ($IconId + '.' + $sha.Substring(0, 8) + '.ico')
    $have = $false
    if (Test-Path -LiteralPath $dest -PathType Leaf) { try { $have = ((Get-FileSha256 $dest) -eq $sha) } catch { } }
    if (-not $have) { Save-FileAtomic $dest $bytes }
    return $dest
}

# Удалить прежние копии (<id>.<другой sha8>.ico) тех же id в applied\<пак>\, если на них не ссылается ни один ярлык (и не перечислены в $ExtraRefs).
# Ссылки читаем со всех ярлыков (в т.ч. общих); не удалось прочитать - ничего не удаляем. Возвращает число удалённых.
function Clear-StaleAppliedIcons {
    param([string]$PackId, [string[]]$Dests, [string[]]$ExtraRefs = @())
    $n = 0
    try {
        if ($PackId -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$' -or @($Dests).Count -eq 0) { return 0 }
        $root = [IO.Path]::GetFullPath($script:SI_AppliedDir)
        $dir = Join-Path $root $PackId
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return 0 }
        if (-not (Test-PathUnder ([IO.Path]::GetFullPath($dir)) $root)) { return 0 }
        if (([IO.File]::GetAttributes($dir) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 0 }
        $keep = @{}; $ids = @{}
        foreach ($d in @($Dests)) {
            if (-not $d) { continue }
            $keep[[IO.Path]::GetFullPath($d).ToLowerInvariant()] = $true
            $ids[[IO.Path]::GetFileName($d).Split('.')[0].ToLowerInvariant()] = $true
        }
        $cand = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '^(?<id>[A-Za-z0-9_\-]+)\.[0-9a-f]{8}\.ico$' -and $ids.ContainsKey($Matches['id'].ToLowerInvariant()) -and -not $keep.ContainsKey($_.FullName.ToLowerInvariant()) -and (([int]$_.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -eq 0) })
        if ($cand.Count -eq 0) { return 0 }
        $refs = @{}
        $script:SI_LnkReadFails = 0
        foreach ($lnk in @(Get-ReferenceLinks)) {
            $pth = (Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$lnk.Icon))).Path.Trim('"')
            if ($pth) { try { $refs[[IO.Path]::GetFullPath($pth).ToLowerInvariant()] = $true } catch { } }
        }
        if ($script:SI_LnkReadFails -gt 0) { Write-Log ('  прежние копии иконок не удалены: не прочитано ярлыков - ' + $script:SI_LnkReadFails); return 0 }      # не знаем, на что ссылается нечитаемый ярлык - не удаляем ничего
        foreach ($x in @($ExtraRefs)) {
            if (-not $x) { continue }
            $pth = (Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$x))).Path.Trim('"')
            if ($pth) { try { $refs[[IO.Path]::GetFullPath($pth).ToLowerInvariant()] = $true } catch { } }
        }
        foreach ($f in $cand) {
            if ($refs.ContainsKey($f.FullName.ToLowerInvariant())) { continue }
            try { Remove-Item -LiteralPath $f.FullName -Force; $n++; Write-Log "  удалена прежняя копия иконки: $($f.Name)" } catch { }
        }
    } catch { Write-Log ('  прежние копии иконок не удалены: ' + $_.Exception.Message) }
    return $n
}

# папка applied\ целиком (только внутри папки данных); после полного отката и при удалении приложения.
# -KeepReferenced (откат): копии, на которые ещё смотрит хоть один ярлык (например, ярлык, закреплённый на панели задач уже после применения:
# он скопировал путь applied\..., а записи в бэкапе у него нет), не удаляем - иначе он останется с пустой иконкой. Ярлыки не прочитать - не удаляем ничего.
function Remove-AppliedFiles {
    param([switch]$KeepReferenced)
    try {
        if (-not (Test-Path -LiteralPath $script:SI_AppliedDir)) { return }
        $root = [IO.Path]::GetFullPath($script:SI_AppliedDir)
        if (-not (Test-PathUnder $root ([IO.Path]::GetFullPath($script:SI_Home)))) { return }
        if (([IO.File]::GetAttributes($script:SI_AppliedDir) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        if ($KeepReferenced) {
            $refs = @{}
            $script:SI_LnkReadFails = 0
            $links = @(Get-ReferenceLinks)
            if ($script:SI_LnkReadFails -gt 0) { Write-Log ('  applied\ не тронута: не прочитано ярлыков - ' + $script:SI_LnkReadFails); return }      # не знаем, на что смотрит нечитаемый ярлык - не удаляем ничего
            foreach ($lnk in $links) {
                $pth = (Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$lnk.Icon))).Path.Trim('"')
                if (-not $pth) { continue }
                try { $full = [IO.Path]::GetFullPath($pth); if (Test-PathUnder $full $root) { $refs[$full.ToLowerInvariant()] = $true } } catch { }
            }
            if ($refs.Count -gt 0) {
                foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                    if (([int]$d.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                    foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -File -Force -ErrorAction SilentlyContinue)) {
                        if ($refs.ContainsKey($f.FullName.ToLowerInvariant())) { continue }
                        if (([int]$f.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        try { Remove-Item -LiteralPath $f.FullName -Force } catch { }
                    }
                }
                Remove-EmptyDirs $root
                Write-Log "  applied\: оставлены копии иконок, на которые ещё ссылаются ярлыки: $($refs.Count)"
                return
            }
        }
        [void](Remove-TreeSafe $script:SI_AppliedDir $script:SI_Home)       # без захода в ссылки (в PowerShell 5.1 Remove-Item -Recurse в них заходит)
    } catch { Write-Log ('applied не удалена: ' + $_.Exception.Message) }
}

# ---------- Очистка диска (2.6.0) ----------
# Место занимают: packs\<id>\ (скачанные иконки и плитки), applied\ (копии иконок для ярлыков), start11\ (копии плиток, на которые смотрит реестр Start11)
# и auto\ (автоиконки). Правила безопасности те же, что у Clear-StaleAppliedIcons (2.5.0): удаляем только внутри нашей папки данных, ссылки
# (junction/symlink) не открываем и не удаляем, файл, на который ещё что-то ссылается (ярлык, значение CustomTiles, бэкап), остаётся,
# а если хоть один ярлык не прочитался - не удаляем ничего (неизвестно, на что он смотрит).

function Test-IsReparse {
    param($Item)
    try { return ((([int]$Item.Attributes) -band ([int][IO.FileAttributes]::ReparsePoint)) -ne 0) } catch { return $true }
}

# размер папки без захода в ссылки
function Get-TreeBytes {
    param([string]$Dir)
    $sum = [long]0
    try {
        foreach ($c in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
            if (Test-IsReparse $c) { continue }
            if ($c.PSIsContainer) { $sum += (Get-TreeBytes $c.FullName) } else { $sum += [long]$c.Length }
        }
    } catch { }
    return $sum
}

function Remove-TreeInner {
    param([string]$Dir, $Res)
    foreach ($c in @(Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue)) {
        if (Test-IsReparse $c) { $Res.Left++; continue }                          # ссылку не открываем и не трогаем (пусть остаётся)
        if ($c.PSIsContainer) { Remove-TreeInner $c.FullName $Res; continue }
        try { $len = [long]$c.Length; Remove-Item -LiteralPath $c.FullName -Force -ErrorAction Stop; $Res.Files++; $Res.Bytes += $len } catch { $Res.Left++ }
    }
    try { if (-not (Get-ChildItem -LiteralPath $Dir -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $Dir -Recurse -Force -Confirm:$false -ErrorAction Stop } else { $Res.Left++ } } catch { $Res.Left++ }
}

# Рекурсивное удаление папки $Path строго внутри $Root (сам $Root не удаляется), не переходя по junction/symlink: в PowerShell 5.1
# Remove-Item -Recurse заходит в ссылки. Возвращает { Files; Bytes; Left }: сколько файлов удалено, сколько байт освобождено, сколько элементов осталось.
function Remove-TreeSafe {
    param([string]$Path, [string]$Root)
    $res = [pscustomobject]@{ Files = 0; Bytes = [long]0; Left = 0 }
    try {
        $full = Get-NormalPath $Path; $rt = Get-NormalPath $Root
        if (-not $full -or -not $rt -or -not (Test-PathUnder $full $rt)) { return $res }
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { return $res }
        if (Test-IsReparse (Get-Item -LiteralPath $full -Force)) { $res.Left = 1; return $res }
        if ((Test-Path -LiteralPath $rt -PathType Container) -and (Test-IsReparse (Get-Item -LiteralPath $rt -Force))) { $res.Left = 1; return $res }
        Remove-TreeInner $full $res
    } catch { $res.Left++; Write-Log ('  папка не удалена: ' + $_.Exception.Message) }
    return $res
}

# Всё, на что сейчас что-то ссылается: иконки ярлыков (пользователя, общих и закреплённых на панели задач / в Пуске), значения CustomTiles Start11,
# исходные значения в бэкапах (backup\index.json: Icon, backup\start11.json: Data), иконка самого приложения (state.json: AppIcon) и $ExtraRefs.
# Ok = $false (Reason - почему), если хоть что-то прочитать не удалось: тогда решать, что не нужно, нельзя. Paths - хэш-таблица полных путей в нижнем регистре.
function Get-ReferencedFiles {
    param([string[]]$ExtraRefs = @())
    $set = @{}
    $res = [pscustomobject]@{ Ok = $true; Reason = ''; Paths = $set }
    $add = {
        param($Loc)
        $p = (Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$Loc))).Path.Trim('"')
        if ($p) { try { $set[[IO.Path]::GetFullPath($p).ToLowerInvariant()] = $true } catch { } }
    }
    try {
        $script:SI_LnkReadFails = 0
        # все папки ярлыков рекурсивно, в т.ч. закреплённые на панели задач / в Пуске (User Pinned\TaskBar, StartMenu, ImplicitAppShortcuts) - см. Get-ReferenceLinks
        foreach ($lnk in @(Get-ReferenceLinks)) { & $add ([string]$lnk.Icon) }
        if ($script:SI_LnkReadFails -gt 0) { $res.Ok = $false; $res.Reason = 'не прочитано ярлыков: ' + $script:SI_LnkReadFails; return $res }
        foreach ($n in @(Get-S11ValueNames $script:SI_S11Tiles)) {
            try { $v = Get-S11Value $script:SI_S11Tiles $n; if ($v) { & $add $v } } catch { }          # не REG_SZ - не наше значение
        }
        foreach ($e in @((Load-S11Backup).Values)) { if (-not $e.Absent -and $e.Data) { & $add ([string]$e.Data) } }
        foreach ($e in @((Load-Backup).Values)) { if ($e.Icon) { & $add ([string]$e.Icon) } }
        $st = Read-State
        if ($st.ContainsKey('AppIcon') -and $st['AppIcon']) { & $add ([string]$st['AppIcon']) }
        foreach ($x in @($ExtraRefs)) { if ($x) { & $add $x } }
    } catch { $res.Ok = $false; $res.Reason = $_.Exception.Message }
    return $res
}

# id применённого пака (state.json), '' - ничего не применено
function Get-AppliedPackId {
    try { $st = Read-State; if ($st.ContainsKey('Applied') -and $st['Applied']) { return [string]$st['Applied'].PackId } } catch { }
    return ''
}

# размер скачанного пака на диске (вся его папка), для карточки
function Get-PackDiskBytes {
    param([string]$PackDir)
    if (-not $PackDir -or -not (Test-Path -LiteralPath $PackDir -PathType Container)) { return [long]0 }
    return (Get-TreeBytes $PackDir)
}

# Файлы внутри папки пака (рекурсивно, без ссылок), кроме $Keep (полные пути) и тех, на что есть ссылки. -Markers: метки .synced* оставить.
# -Ext: трогать только файлы с этими расширениями. Возвращает { Files; Bytes; Kept }.
function Remove-PackDirFiles {
    param([string]$Dir, [string[]]$Keep = @(), $Refs = $null, [switch]$Markers, [string[]]$Ext = $null)
    $res = [pscustomobject]@{ Files = 0; Bytes = [long]0; Kept = 0 }
    $keepSet = @{}                                     # не $keep: имя переменной без учёта регистра совпало бы с параметром $Keep
    foreach ($k in @($Keep)) { if ($k) { $kp = Get-NormalPath $k; if ($kp) { $keepSet[$kp.ToLowerInvariant()] = $true } } }
    $walk = $null
    $walk = {
        param($d)
        foreach ($c in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
            if (Test-IsReparse $c) { $res.Kept++; continue }
            if ($c.PSIsContainer) { & $walk $c.FullName; continue }
            $lk = $c.FullName.ToLowerInvariant()
            if ($keepSet.ContainsKey($lk)) { continue }
            if ($Markers -and $c.Name.StartsWith('.synced', [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($Ext -and ($Ext -notcontains $c.Extension.ToLowerInvariant())) { continue }
            if ($Refs -and $Refs.ContainsKey($lk)) { $res.Kept++; continue }
            try { $len = [long]$c.Length; Remove-Item -LiteralPath $c.FullName -Force -ErrorAction Stop; $res.Files++; $res.Bytes += $len } catch { $res.Kept++ }
        }
    }
    try {
        if (Test-Path -LiteralPath $Dir -PathType Container) {
            if (-not (Test-IsReparse (Get-Item -LiteralPath $Dir -Force))) { & $walk $Dir; Remove-EmptyDirs $Dir }
        }
    } catch { Write-Log ('  файлы пака не удалены: ' + $_.Exception.Message) }
    return $res
}

# Остатки прежних версий в папке пака: файлы, которых нет в свежем pack.json (были .png-плитки, стали .jpg). $Expected - полные пути файлов пака
# (иконки, плитки, auto.json), pack.json и превью, метки .synced* и неизвестные расширения не трогаем; на что есть ссылка - тоже. Возвращает { Files; Bytes }.
function Clear-PackLeftovers {
    param([string]$PackDir, [string[]]$Expected)
    $none = [pscustomobject]@{ Files = 0; Bytes = [long]0 }
    try {
        if (-not $PackDir -or -not (Test-Path -LiteralPath $PackDir -PathType Container)) { return $none }
        $root = Get-NormalPath $script:SI_PacksDir
        if (-not (Test-PathUnder (Get-NormalPath $PackDir) $root)) { return $none }
        $exp = @{}
        foreach ($x in @($Expected)) { if ($x) { $xp = Get-NormalPath $x; if ($xp) { $exp[$xp.ToLowerInvariant()] = $true } } }
        $exp[(Get-NormalPath (Join-Path $PackDir 'pack.json')).ToLowerInvariant()] = $true
        $exts = @('.ico', '.png', '.jpg', '.jpeg', '.json')
        # сначала смотрим, есть ли вообще остатки: ярлыки читаем (это не быстро) только если есть что удалять
        $cand = [System.Collections.Generic.List[string]]::new()
        $stack = [System.Collections.Generic.Stack[string]]::new()
        $stack.Push($PackDir)
        while ($stack.Count -gt 0) {
            $d = $stack.Pop()
            foreach ($c in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparse $c) { continue }
                if ($c.PSIsContainer) { $stack.Push($c.FullName); continue }
                if ($exts -notcontains $c.Extension.ToLowerInvariant()) { continue }
                if ($exp.ContainsKey($c.FullName.ToLowerInvariant())) { continue }
                $cand.Add($c.FullName)
            }
        }
        if ($cand.Count -eq 0) { return $none }
        $refs = Get-ReferencedFiles
        if (-not $refs.Ok) { Write-Log ('  остатки прежней версии пака не удалены (' + $refs.Reason + ')'); return $none }
        $r = Remove-PackDirFiles $PackDir -Keep @($Expected + @(Join-Path $PackDir 'pack.json')) -Refs $refs.Paths -Markers -Ext $exts
        if ($r.Files -gt 0) { Write-Log ('  удалены файлы прежней версии пака ' + [IO.Path]::GetFileName($PackDir.TrimEnd($script:SI_Seps)) + ': ' + $r.Files + ' (' + (Format-DownloadSize $r.Bytes) + ')') }
        return [pscustomobject]@{ Files = $r.Files; Bytes = $r.Bytes }
    } catch { Write-Log ('  остатки прежней версии пака не удалены: ' + $_.Exception.Message); return $none }
}

# Удалить скачанные файлы ОДНОГО пака (иконки, плитки, auto.json, метки); pack.json и превью остаются - карточка пака остаётся в списке, «Скачать» вернёт файлы.
# Применённый пак не удаляется. Что-то ещё ссылается на файл (ярлык от старой версии, бэкап) - файл остаётся; ярлыки не прочитались - не удаляем ничего.
# $Refs - уже посчитанные ссылки (Clear-PackCache считает один раз). Возвращает { Ok; Skipped; Message; Files; Bytes }.
function Remove-PackDownload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id, $Refs = $null)
    $r = [pscustomobject]@{ Ok = $false; Skipped = $true; Message = ''; Files = 0; Bytes = [long]0 }
    if ($Id -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { $r.Message = "недопустимый id пака '$Id'"; return $r }
    if ($Id -eq (Get-AppliedPackId)) { $r.Message = 'пак применён - удалить нельзя'; return $r }
    $dir = Join-Path $script:SI_PacksDir $Id
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $r.Message = 'пака нет на диске'; return $r }
    if (-not (Test-PathUnder (Get-NormalPath $dir) (Get-NormalPath $script:SI_PacksDir))) { $r.Message = 'путь вне папки паков'; return $r }
    if ($null -eq $Refs) { $rf = Get-ReferencedFiles; if (-not $rf.Ok) { $r.Message = 'ярлыки не прочитаны (' + $rf.Reason + ') - ничего не удалено'; Write-Log ('Пак ' + $Id + ': ' + $r.Message); return $r }; $Refs = $rf.Paths }
    $keep = @((Join-Path $dir 'pack.json'))
    try {
        $mf = Join-Path $dir 'pack.json'
        if (Test-Path -LiteralPath $mf -PathType Leaf) {
            $j = Read-JsonFile $mf
            if ($j.preview -and (Test-SafeRel ([string]$j.preview) @('.png'))) { $keep += (Join-Rel $dir ([string]$j.preview)) }
        }
    } catch { }
    $d = Remove-PackDirFiles $dir -Keep $keep -Refs $Refs
    $r.Ok = $true; $r.Skipped = $false; $r.Files = $d.Files; $r.Bytes = $d.Bytes
    $r.Message = 'удалено файлов: ' + $d.Files + ', освобождено ' + (Format-DownloadSize $d.Bytes)
    Write-Log ('Пак ' + $Id + ': ' + $r.Message)
    return $r
}

# Копии, которые больше никому не нужны: applied\<пак>\<id>.<sha8>.ico, start11\<пак>\<id>[.<sha8>].(png|jpg|jpeg), auto\<пак>\<ключ>.(ico|png|jpg)[.key].
# Остаются: всё, на что есть ссылка (ярлык, CustomTiles, бэкап), $KeepRefs (копии, нужные в этом применении) и auto\<применённый пак>\ целиком (кэш,
# плитка Start11 смотрит на копию в start11\, а не на auto\). Не прочитался хоть один ярлык - ничего не удаляется. Чужие файлы в этих папках не трогаем.
# Возвращает { Ok; Reason; Files; Bytes }.
function Clear-UnusedCopies {
    [CmdletBinding()]
    param([string[]]$KeepRefs = @())
    $out = [pscustomobject]@{ Ok = $true; Reason = ''; Files = 0; Bytes = [long]0 }
    try {
        $home2 = Get-NormalPath $script:SI_Home
        $specs = @(
            @{ Dir = $script:SI_AppliedDir; Rx = '^[A-Za-z0-9_\-]+\.[0-9a-f]{8}\.ico$'; Label = 'applied' },
            @{ Dir = $script:SI_S11Dir; Rx = '^[A-Za-z0-9_\-]+(\.[0-9a-f]{8})?\.(png|jpe?g)$'; Label = 'start11' },
            @{ Dir = $script:SI_AutoDir; Rx = '^[a-z0-9_]{1,40}\.(ico|png|jpg)(\.key)?$'; Label = 'auto' })
        $roots = @($specs | Where-Object { $_.Dir -and (Test-Path -LiteralPath $_.Dir -PathType Container) })
        if ($roots.Count -eq 0) { return $out }
        $refs = Get-ReferencedFiles -ExtraRefs $KeepRefs
        if (-not $refs.Ok) { $out.Ok = $false; $out.Reason = $refs.Reason; Write-Log ('  неиспользуемые копии иконок не удалены: ' + $refs.Reason); return $out }
        $applied = Get-AppliedPackId
        $appliedV = Get-AppliedVariantId
        foreach ($s in $roots) {
            $root = Get-NormalPath $s.Dir
            if (-not (Test-PathUnder $root $home2)) { continue }
            if (Test-IsReparse (Get-Item -LiteralPath $s.Dir -Force)) { continue }
            $n = 0; $bytes = [long]0
            foreach ($pd in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparse $pd) { continue }
                if ($pd.Name -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { continue }
                if ($s.Label -eq 'auto' -and ($pd.Name -eq $applied -or $pd.Name -eq $appliedV)) { continue }
                $stems = @{}
                if ($s.Label -eq 'auto') {      # у автоиконки .ico/.png/.jpg/.key одного ключа живут вместе: ссылка на любой из них сохраняет все
                    foreach ($k in @($refs.Paths.Keys)) { if ((Test-PathUnder $k $pd.FullName.ToLowerInvariant())) { $stems[([IO.Path]::GetFileName($k)).Split('.')[0]] = $true } }
                }
                foreach ($f in @(Get-ChildItem -LiteralPath $pd.FullName -File -Force -ErrorAction SilentlyContinue)) {
                    if (Test-IsReparse $f) { continue }
                    if ($f.Name -notmatch $s.Rx) { continue }
                    if ($refs.Paths.ContainsKey($f.FullName.ToLowerInvariant())) { continue }
                    if ($s.Label -eq 'auto' -and $stems.ContainsKey($f.Name.Split('.')[0])) { continue }
                    try { $len = [long]$f.Length; Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++; $bytes += $len } catch { }
                }
                try { if (-not (Get-ChildItem -LiteralPath $pd.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $pd.FullName -Recurse -Force -Confirm:$false } } catch { }
            }
            if ($n -gt 0) { Write-Log ('  ' + $s.Label + '\: удалено ненужных копий: ' + $n + ' (' + (Format-DownloadSize $bytes) + ')') }
            $out.Files += $n; $out.Bytes += $bytes
        }
    } catch { $out.Ok = $false; $out.Reason = $_.Exception.Message; Write-Log ('  неиспользуемые копии иконок не удалены: ' + $_.Exception.Message) }
    return $out
}

# «Очистить кэш»: скачанные паки, кроме применённого (pack.json и превью остаются), остатки прежних версий в применённом, папки без pack.json, *.tmp
# и неиспользуемые копии applied\ start11\ auto\. Возвращает { Ok; Bytes; Files; Packs (id удалённых); Message }.
function Clear-PackCache {
    [CmdletBinding()]
    param()
    $res = [pscustomobject]@{ Ok = $true; Bytes = [long]0; Files = 0; Packs = @(); Message = '' }
    $removed = [System.Collections.Generic.List[string]]::new()
    try {
        $applied = Get-AppliedPackId
        $rf = Get-ReferencedFiles
        if (-not $rf.Ok) { Write-Log ('Очистка кэша: паки не тронуты (' + $rf.Reason + ')') }
        if (Test-Path -LiteralPath $script:SI_PacksDir -PathType Container) {
            $root = Get-NormalPath $script:SI_PacksDir
            foreach ($d in @(Get-ChildItem -LiteralPath $script:SI_PacksDir -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparse $d) { continue }
                if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'pack.json') -PathType Leaf)) {         # папка без pack.json: обрывок загрузки
                    if (-not $rf.Ok) { continue }                                                              # ссылки неизвестны - не трогаем
                    $dl = $d.FullName.TrimEnd($script:SI_Seps).ToLowerInvariant()
                    if (@($rf.Paths.Keys | Where-Object { Test-PathUnder $_ $dl }).Count -gt 0) { Write-Log ('  папка без pack.json оставлена: на файл внутри ссылается ярлык / плитка / бэкап (' + $d.Name + ')'); continue }
                    $t = Remove-TreeSafe $d.FullName $root
                    $res.Bytes += $t.Bytes; $res.Files += $t.Files
                    if ($t.Files -gt 0) { Write-Log ('  удалена папка без pack.json: ' + $d.Name + ' (' + (Format-DownloadSize $t.Bytes) + ')') }
                    continue
                }
                if ($d.Name -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$') { continue }
                if (-not $rf.Ok) { continue }
                if ($d.Name -eq $applied) {
                    $pk = @(Get-Packs -OnlyId $d.Name) | Select-Object -First 1
                    if ($pk) {
                        $exp = @($pk.Files); if ($pk.Preview) { $exp += [string]$pk.Preview }
                        $lo = Clear-PackLeftovers $pk.Dir $exp
                        $res.Bytes += $lo.Bytes; $res.Files += $lo.Files
                    }
                    continue
                }
                $r = Remove-PackDownload -Id $d.Name -Refs $rf.Paths
                if ($r.Ok -and $r.Files -gt 0) { $res.Bytes += $r.Bytes; $res.Files += $r.Files; $removed.Add($d.Name) }
            }
        }
        try { [void](Remove-StaleTempFiles -Root $script:SI_PacksDir -MinAgeMinutes 0); $res.Bytes += [long]$script:SI_TempBytes } catch { }
        $cp = Clear-UnusedCopies
        $res.Bytes += $cp.Bytes; $res.Files += $cp.Files
        # 3.0: отрисованные варианты (variants\): всё, кроме текущего ключа применённого варианта (копии для ярлыков лежат в applied\, а не здесь)
        $keepV = @{}
        try { $av = Get-AppliedVariantId; if ($av) { $vk = Get-AppliedVariantKey $av; if ($vk) { $keepV[$av] = $vk } } } catch { }
        $vc = Clear-VariantCache -KeepKeys $keepV
        $res.Bytes += $vc.Bytes; $res.Files += $vc.Files
    } catch { $res.Ok = $false; $res.Message = $_.Exception.Message; Write-Log ('Очистка кэша: ' + $_.Exception.Message) }
    $res.Packs = $removed.ToArray()
    if (-not $res.Message) { $res.Message = 'освобождено ' + (Format-DownloadSize $res.Bytes) + ', файлов: ' + $res.Files + ', паков удалено: ' + $removed.Count }
    Write-Log ('Очистка кэша: ' + $res.Message)
    return $res
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
    if ($Group -eq 'auto') { return 90 }                               # автоиконки - после всех групп пака
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
        if (-not $by.ContainsKey($k)) { $by[$k] = [System.Collections.Generic.List[object]]::new() }
        $by[$k].Add([pscustomobject]@{ Kind = 'link'; Title = [string]$m.Name; Item = $m })
    }
    foreach ($m in @($TileMatches)) {
        if (-not $m) { continue }
        $k = Get-GroupKey $m.Group
        if (-not $by.ContainsKey($k)) { $by[$k] = [System.Collections.Generic.List[object]]::new() }
        $by[$k].Add([pscustomobject]@{ Kind = 'tile'; Title = (Get-TileTitle $m); Item = $m })
    }
    $out = foreach ($k in $by.Keys) {
        [pscustomobject]@{ Group = $k; Rank = (Get-GroupRank $k); Count = $by[$k].Count
            Rows = @($by[$k] | Sort-Object @{ Expression = { $_.Title } }, @{ Expression = { $_.Kind } }) }
    }
    return @($out | Sort-Object @{ Expression = { $_.Rank } }, @{ Expression = { $_.Group } })
}

# ---------- Сопоставление ----------
# слишком общие слова: не имя и не exe конкретного приложения (в старых паках они ещё есть, поэтому режем и здесь, а не только в каталоге)
$script:SI_GenericNames = @('uninstall', 'launcher', 'install', 'installer', 'setup', 'update', 'code')       # 'code' - только как имя ярлыка/токен id: exe code.exe (VS Code) остаётся
$script:SI_GenericExes = @('uninstall', 'launcher', 'install', 'installer', 'setup', 'update')

function New-MatchIndex {
    param($Pack)
    $nameMap = @{}; $exeMap = @{}
    foreach ($ic in @($Pack.Icons)) {
        foreach ($n in @($ic.Names)) { $k = Get-Key $n; if ($k -and ($script:SI_GenericNames -notcontains $k) -and -not $nameMap.ContainsKey($k)) { $nameMap[$k] = $ic } }
        foreach ($e in @($ic.Exes)) { $k = Get-Key $e; if ($k -and ($script:SI_GenericExes -notcontains $k) -and -not $exeMap.ContainsKey($k)) { $exeMap[$k] = $ic } }
    }
    return [pscustomobject]@{ Names = $nameMap; Exes = $exeMap }
}

function Test-UninstallLike {
    param([string]$NameKey, [string]$ExeKey)
    if ($NameKey -match 'uninstall|удалить|удаление|деинсталл') { return $true }
    if ($ExeKey -match '^unins|uninstall') { return $true }
    return $false
}

# имя-ключ -> точное имя; exe-ключ -> точный exe; префикс имени (запись names длиной >= 5, остаток - известный суффикс, самая длинная)
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

# Префикс допустим, только если после ключа идёт известный суффикс (telegram|desktop, discord|ptb, robloxplayer|beta) или цифры/версия:
# signalrgb НЕ signal, codectweaktool НЕ code. Короткие ключи (<= 4 символов: msi, code, obs, vlc) - только целиком, без префикса.
$script:SI_PrefixSuffixRx = '^(?:desktop|app|launcher|beta|client|player|studio|x64|x86|web|remote|canary|ptb|\d+)+$'

function Test-PrefixRemainder {
    param([string]$Rest)
    if (-not $Rest) { return $true }
    return ($Rest -match $script:SI_PrefixSuffixRx)
}

# префикс: ключ names длиной >= 5 (самый длинный), с которого начинается любой из $Keys, а остаток - известный суффикс
function Find-PrefixMatch {
    param($Index, [string[]]$Keys)
    $best = $null; $bestLen = 0
    foreach ($key in $Index.Names.Keys) {
        if ($key.Length -le 4 -or $key.Length -le $bestLen) { continue }
        foreach ($k in @($Keys)) {
            if ($k -and $k.StartsWith($key, [StringComparison]::Ordinal) -and (Test-PrefixRemainder $k.Substring($key.Length))) { $best = $Index.Names[$key]; $bestLen = $key.Length; break }
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
    $roots = [System.Collections.Generic.List[object]]::new()
    $roots.Add(@{ Path = (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'); Recurse = $false; Location = 'taskbar' })
    $roots.Add(@{ Path = [Environment]::GetFolderPath('Desktop'); Recurse = $false; Location = 'desktop' })
    $roots.Add(@{ Path = [Environment]::GetFolderPath('Programs'); Recurse = $true; Location = 'start' })
    if ($Common) {      # менять общие ярлыки можно только с правами администратора, но читать - всем
        $roots.Add(@{ Path = [Environment]::GetFolderPath('CommonDesktopDirectory'); Recurse = $false; Location = 'desktop_all' })
        $roots.Add(@{ Path = [Environment]::GetFolderPath('CommonPrograms'); Recurse = $true; Location = 'start_all' })
    }
    return $roots
}

$script:SI_LnkReadFails = 0          # сколько ярлыков Get-ShortcutList не смог прочитать (сбрасывает и проверяет вызывающий: см. Clear-StaleAppliedIcons)
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
            } catch { $script:SI_LnkReadFails++; Write-Log "  не прочитан ярлык $($f.Name): $($_.Exception.Message)" }
        }
    }
}

# ---------- Широкий обзор ярлыков для решений «на это ещё ссылаются» (2.6.0) ----------
# Get-ShortcutList смотрит только туда, где ярлыки меняем (рабочий стол без подпапок и т.д.). Но ярлык, который мы когда-то правили, пользователь мог
# перенести в подпапку рабочего стола / меню «Пуск» / закрепить. Поэтому перед удалением любой копии иконки смотрим ШИРЕ: все папки ярлыков
# (рабочий стол и общий рабочий стол, меню «Пуск» обоих видов целиком, Quick Launch\User Pinned: TaskBar, StartMenu, ImplicitAppShortcuts) - рекурсивно,
# до $script:SI_RefScanMaxDepth уровней, не заходя в junction/symlink-папки. Не смогли прочитать ярлык / папку, упёрлись в предел глубины или числа
# записей - увеличиваем SI_LnkReadFails (вызывающий тогда ничего не удаляет: не знаем, на что смотрит непрочитанное).
$script:SI_RefScanMaxDepth = 8
$script:SI_RefScanMaxEntries = 100000

function Get-ReferenceScanRoots {
    $list = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $add = {
        param($Path)
        if (-not $Path) { return }
        $n = Get-NormalPath ([string]$Path)
        if ($n -and -not $seen.ContainsKey($n.ToLowerInvariant())) { $seen[$n.ToLowerInvariant()] = $true; $list.Add($n) }
    }
    foreach ($r in @(Get-ShortcutRoots -Common)) { & $add $r.Path }
    foreach ($sf in @('Desktop', 'DesktopDirectory', 'CommonDesktopDirectory', 'StartMenu', 'CommonStartMenu', 'Programs', 'CommonPrograms')) {
        $fp = ''; try { $fp = [Environment]::GetFolderPath($sf) } catch { }
        & $add $fp
    }
    if ($env:APPDATA) { & $add (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch') }                  # User Pinned\TaskBar, \StartMenu, \ImplicitAppShortcuts
    if ($env:USERPROFILE) { & $add (Join-Path $env:USERPROFILE 'Desktop') }
    if ($env:OneDrive) { & $add (Join-Path $env:OneDrive 'Desktop') }
    if ($env:PUBLIC) { & $add (Join-Path $env:PUBLIC 'Desktop') }
    return $list.ToArray()
}

# Все .lnk в папках Get-ReferenceScanRoots: { Path; Icon }. Не прочитанное - $script:SI_LnkReadFails++ (сбрасывает вызывающий).
function Get-ReferenceLinks {
    $wsh = Get-WshShell
    $seen = @{}
    $count = 0
    foreach ($root in @(Get-ReferenceScanRoots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $stack = [System.Collections.Generic.Stack[object]]::new()
        $stack.Push(@($root, 0))
        while ($stack.Count -gt 0) {
            $e = $stack.Pop(); $dir = [string]$e[0]; $depth = [int]$e[1]
            $items = @()
            $errs = $null
            try { $items = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue -ErrorVariable errs) } catch { $errs = @($_) }
            if ($errs -and @($errs).Count -gt 0) { $script:SI_LnkReadFails++; Write-Log ('  папка ярлыков не прочитана: ' + $dir) }
            foreach ($c in $items) {
                $count++
                if ($count -gt $script:SI_RefScanMaxEntries) { $script:SI_LnkReadFails++; Write-Log '  обзор ярлыков остановлен: слишком много записей'; return }
                if ($c.PSIsContainer) {
                    if (Test-IsReparse $c) { continue }                                          # junction/symlink-папку не открываем
                    if ($depth -ge $script:SI_RefScanMaxDepth) { $script:SI_LnkReadFails++; Write-Log ('  обзор ярлыков: предел глубины, не просмотрена ' + $c.FullName); continue }
                    $stack.Push(@($c.FullName, ($depth + 1)))
                    continue
                }
                if (-not $c.Name.EndsWith('.lnk', [StringComparison]::OrdinalIgnoreCase)) { continue }
                $lk = $c.FullName.ToLowerInvariant()
                if ($seen.ContainsKey($lk)) { continue }
                $seen[$lk] = $true
                try { [pscustomobject]@{ Path = $c.FullName; Icon = [string]$wsh.CreateShortcut($c.FullName).IconLocation } }
                catch { $script:SI_LnkReadFails++; Write-Log "  не прочитан ярлык $($c.Name): $($_.Exception.Message)" }
            }
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
    param([Parameter(Mandatory)]$Pack, $Shortcuts, [switch]$AllUsers, [switch]$Auto, $Overrides)
    if ($null -eq $Shortcuts) { $Shortcuts = @(Get-ShortcutList -AllUsers:$AllUsers) }
    $index = New-MatchIndex $Pack
    $out = [System.Collections.Generic.List[object]]::new()
    $autoP = $null                                   # -Auto: ярлыки без иконки в паке тоже в списке (Auto = $true), если у пака есть auto.json
    if ($Auto) { $autoP = Get-PackAuto $Pack; if ($null -eq $Overrides) { $Overrides = Get-AutoOverrides } }
    foreach ($s in @($Shortcuts)) {
        try {
            $m = Find-IconMatch $index $s.Name $s.Target $s.Args
            if (-not $m) {
                if ($autoP) { $ai = New-AutoLinkItem $s ([string]$Pack.Id) $Overrides; if ($ai) { $out.Add($ai) } }
                continue
            }
            $ap = Get-AppliedIconDest ([string]$Pack.Id) ([string]$m.Icon.Id) ([string]$m.Icon.IcoPath)      # куда ярлык должен указывать после применения (нет файла пака - $null)
            $out.Add([pscustomobject]@{
                Name = $s.Name; Path = $s.Path; Location = $s.Location; Target = $s.Target; Args = $s.Args; Icon = $s.Icon
                IconId = $m.Icon.Id; IconName = $m.Icon.Name; Group = [string]$m.Icon.Group; IcoPath = $m.Icon.IcoPath; PngPath = $m.Icon.PngPath
                AppliedPath = $ap; Rule = $m.Rule; Already = [bool]($ap -and (Test-IconIsSet $s.Icon $ap)); Auto = $false
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

# Полный путь без хвостового разделителя (корень диска оставляем как есть); '' - если путь разобрать нельзя
function Get-NormalPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    try {
        $f = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($f)
        if ($f.Length -gt $root.Length) { $f = $f.TrimEnd($script:SI_Seps) }
        return $f
    } catch { return '' }
}

# Как соотносятся прежняя и новая папки данных (по полным путям, регистр не важен):
# 'separate' - не пересекаются; 'equal' - одна и та же; 'old-in-new' / 'new-in-old' - одна лежит внутри другой; 'unknown' - путь не разобрать.
# Всё, кроме 'separate', - повод отказаться от любого разрушительного шага над прежней папкой.
function Get-HomeRelation {
    param([string]$Old, [string]$New)
    $o = Get-NormalPath $Old
    $n = Get-NormalPath $New
    if (-not $o -or -not $n) { return 'unknown' }
    if ($o -ieq $n) { return 'equal' }
    if (Test-PathUnder $o $n) { return 'old-in-new' }
    if (Test-PathUnder $n $o) { return 'new-in-old' }
    return 'separate'
}

# Можно ли рекурсивно удалять $Path под прежней папкой: папки не пересекаются, путь строго внутри прежней и не внутри (и не равен) новой
function Test-SafeOldHomeDelete {
    param([string]$Path, [string]$OldHome = [string]$script:SI_OldHome, [string]$NewHome = [string]$script:SI_Home)
    if ((Get-HomeRelation $OldHome $NewHome) -ne 'separate') { return $false }
    $p = Get-NormalPath $Path
    $o = Get-NormalPath $OldHome
    $n = Get-NormalPath $NewHome
    if (-not $p -or -not $o -or -not $n) { return $false }
    if (-not (Test-PathUnder $p $o)) { return $false }
    if (($p -ieq $n) -or (Test-PathUnder $p $n)) { return $false }
    return $true
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
            $ak = $null
            if ($e.PSObject.Properties['AppKey'] -and $e.AppKey) { $ak = [string]$e.AppKey }          # 3.0: к какому приложению (AppKey плана) относится запись - для частичного отката
            $map[[string]$e.Path] = [pscustomobject]@{ Copy = [string]$e.Copy; Icon = $icon; AppKey = $ak }
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
    $arr = foreach ($k in $Map.Keys) {
        $o = [ordered]@{ Path = $k; Copy = $Map[$k].Copy; Icon = $Map[$k].Icon }
        if ($Map[$k].PSObject.Properties['AppKey'] -and $Map[$k].AppKey) { $o['AppKey'] = [string]$Map[$k].AppKey }
        [pscustomobject]$o
    }
    $json = ConvertTo-Json -InputObject @($arr)
    $tmp = Get-TempSibling $script:SI_BackupFile          # пишем во временный файл и переименовываем: обрыв не оставит битый index.json
    try {
        [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
        Move-IntoPlace -Tmp $tmp -Dest $script:SI_BackupFile
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } }
    }
}

# $Icon - исходный IconLocation ярлыка ("путь,индекс"); для .ico не нужен
function Backup-File {
    param([hashtable]$Map, [string]$Path, $Icon = $null, [string]$AppKey = '')
    if ($Map.ContainsKey($Path)) { return }
    if (-not (Test-Path -LiteralPath $script:SI_BackupDir)) { New-Item -ItemType Directory -Path $script:SI_BackupDir -Force | Out-Null }
    $name = [IO.Path]::GetFileName($Path)
    $copy = Join-Path $script:SI_BackupDir (([guid]::NewGuid().ToString('N').Substring(0, 8)) + '_' + $name)
    Copy-Item -LiteralPath $Path -Destination $copy -Force
    $Map[$Path] = [pscustomobject]@{ Copy = $copy; Icon = $(if ($null -ne $Icon) { [string]$Icon } else { $null }); AppKey = $(if ($AppKey) { $AppKey } else { $null }) }
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
        $files = [System.Collections.Generic.List[string]]::new()
        $files.Add((Join-Path $env:LOCALAPPDATA 'IconCache.db'))
        $exDir = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
        foreach ($f in @(Get-ChildItem -LiteralPath $exDir -Filter 'iconcache_*.db' -File -ErrorAction SilentlyContinue)) { $files.Add($f.FullName) }
        $locked = 0
        foreach ($f in $files) {
            if (-not (Test-Path -LiteralPath $f)) { continue }
            try { Remove-Item -LiteralPath $f -Force } catch { $locked++ }
        }
        if ($locked -gt 0) {
            # кэш занят: просим Windows обновить значки (ie4uinit -show + SHCNE_ASSOCCHANGED); это не критично - применённые иконки лежат по новым путям (applied\...<sha8>.ico)
            Send-AllNotify
            Invoke-Ie4uinit
            Write-Log "  кэш иконок занят ($locked файл.) - запросил обновление значков через ie4uinit и SHChangeNotify"
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

function Invoke-Ie4uinit {
    $ie4 = if ($env:SystemRoot) { Join-Path $env:SystemRoot 'System32\ie4uinit.exe' } else { '' }
    if ($ie4 -and (Test-Path -LiteralPath $ie4)) { try { Start-Process -FilePath $ie4 -ArgumentList '-show' -WindowStyle Hidden -Wait } catch { } }
}

function Update-IconView {
    param([bool]$RestartExplorer = $true, [bool]$ClearCache = $true)
    Send-AllNotify
    Invoke-Ie4uinit
    if ($RestartExplorer) { Restart-Explorer $ClearCache }
}

# Иконка самого Glyphix из пака: иконка с id 'glyphix' (предпочитаем .ico, иначе .png), файл должен существовать. Нет - $null.
function Get-PackAppIcon {
    param($Pack)
    foreach ($ic in @($Pack.Icons)) {
        if ([string]$ic.Id -ine 'glyphix') { continue }
        foreach ($p in @($ic.IcoPath, $ic.PngPath)) { if ($p -and (Test-Path -LiteralPath ([string]$p) -PathType Leaf)) { return [string]$p } }
    }
    return $null
}

# Запомнить в state.json (AppIcon) иконку приложения из пака; в паке её нет - запись убираем (вернётся assets\app.ico). Возвращает путь или $null.
function Set-AppIconState {
    param($Pack)
    try {
        $path = Get-PackAppIcon $Pack
        $st = Read-State
        if ($path) { $st['AppIcon'] = $path; Save-State $st }
        elseif ($st.ContainsKey('AppIcon')) { $st.Remove('AppIcon'); Save-State $st }
        return $path
    } catch { Write-Log ('иконка приложения: ' + $_.Exception.Message); return $null }
}

function Clear-AppIconState {
    try { $st = Read-State; if ($st.ContainsKey('AppIcon')) { $st.Remove('AppIcon'); Save-State $st } } catch { }
}

# Путь к иконке окна: AppIcon из state.json, если файл есть и лежит в нашей папке packs\ (.ico/.png), иначе $Fallback (assets\app.ico)
function Get-AppIconPath {
    param([string]$Fallback = '')
    try {
        $st = Read-State
        if ($st.ContainsKey('AppIcon') -and $st['AppIcon']) {
            $p = [string]$st['AppIcon']
            $e = [IO.Path]::GetExtension($p).ToLowerInvariant()
            $root = [IO.Path]::GetFullPath($script:SI_PacksDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            $root2 = [IO.Path]::GetFullPath($script:SI_VariantsDir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar          # 3.0: иконка из отрисованного варианта
            $fullP = [IO.Path]::GetFullPath($p)
            if (($e -eq '.ico' -or $e -eq '.png') -and ($fullP.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or $fullP.StartsWith($root2, [StringComparison]::OrdinalIgnoreCase)) -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p }
        }
    } catch { }
    return $Fallback
}

# ---------- Общие (All Users) ярлыки ----------
# Общие ярлыки видят все пользователи Windows, а .ico пака лежат в папке данных одного пользователя - у остальных иконки могут быть пустыми.
# Раньше (2.4.1) иконки копировались в %ProgramData%\Glyphix\icons из повышенного процесса; это небезопасно (папку может заранее создать
# обычный пользователь, в том числе как junction), поэтому с 2.4.2 ничего в ProgramData не пишем и не удаляем.
$script:SI_LegacyCommonNoted = $false
$script:SI_CommonNoteLogged = $false

# ярлык в общей папке (рабочий стол всех пользователей / общее меню Пуск)?
function Test-CommonLocation {
    param([string]$Location)
    return ($Location -eq 'desktop_all' -or $Location -eq 'start_all')
}

# Только чтение: если от 2.4.1 осталась папка %ProgramData%\Glyphix - один раз пишем о ней в журнал, сами её не трогаем
function Write-LegacyCommonIconsNote {
    if ($script:SI_LegacyCommonNoted) { return }
    $script:SI_LegacyCommonNoted = $true
    try {
        $pd = [string]$env:ProgramData
        if (-not $pd) { return }
        $d = Join-Path $pd 'Glyphix'
        if (Test-Path -LiteralPath $d) { Write-Log "Папка $d осталась от версии 2.4.1 - Glyphix её больше не использует и не трогает; при желании удалите её вручную (от имени администратора)." }
    } catch { }
}

# ---------- Запущенные приложения (иконка окна, пока приложение открыто) ----------
$script:SI_HintIgnoreProcs = @('explorer', 'cmd', 'powershell', 'pwsh', 'wscript', 'cscript', 'rundll32', 'control', 'conhost')

# имя процесса по цели ярлыка ('C:\x\Steam.exe' -> 'Steam'); '' - если это не .exe или процесс не имеет смысла проверять
function Get-TargetProcessName {
    param([string]$Target)
    $t = [Environment]::ExpandEnvironmentVariables(([string]$Target).Trim().Trim('"'))
    if (-not $t -or $t -notmatch '(?i)\.exe$') { return '' }
    $n = [IO.Path]::GetFileNameWithoutExtension($t.Replace('\', '/'))
    if (-not $n -or ($script:SI_HintIgnoreProcs -contains $n.ToLowerInvariant())) { return '' }
    return $n
}

function Test-TargetRunning {
    param([string]$Target)
    try {
        $n = Get-TargetProcessName $Target
        if (-not $n) { return $false }
        return [bool](@(Get-Process -Name $n -ErrorAction SilentlyContinue).Count -gt 0)
    } catch { return $false }
}

# Подсказка для строки состояния: до 3 приложений
function Format-RunningHint {
    param([string[]]$Names)
    $n = @($Names | Where-Object { $_ } | Select-Object -Unique)
    if ($n.Count -eq 0) { return '' }
    $shown = @($n | Select-Object -First 3) -join ', '
    if ($n.Count -gt 3) { $shown += ' и ещё ' + ($n.Count - 3) }
    $verb = if ($n.Count -gt 1) { 'запущены' } else { 'запущен' }
    return "$shown $verb — Windows может показывать иконку окна, пока приложение не закрыто"
}

function Apply-Pack {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Pack, $Items, [switch]$RestartExplorer, [switch]$NoAuto)
    Assert-ElevationSafe
    Assert-LegacyMigrationComplete               # бэкап прежней версии ещё не перенесён - не применяем
    # сначала index.json + pack.json этого пака + файлы (Install-Pack), потом пак заново читаем с диска: применяем только свежий пак, а не объект из памяти
    $fr = Resolve-FreshPack $Pack @('icons')
    $Pack = $fr.Pack
    if ($fr.Replaced -and $null -ne $Items) {
        Write-Log 'Пак обновился с момента сканирования - сопоставляю ярлыки заново'
        $Items = @(Convert-ItemsToFreshPack $Items $Pack ((-not $NoAuto) -and (Get-AutoEnabled)))
    }
    Write-Log "Применяю пак: $($Pack.Name) $($Pack.Version)"
    Write-LegacyCommonIconsNote
    if ($null -eq $Items) { $Items = @(Get-Matches -Pack $Pack -Auto:((-not $NoAuto) -and (Get-AutoEnabled))) }
    $backup = Load-Backup
    $changed = 0; $same = 0; $failed = 0; $autoDone = 0; $autoSkipped = 0
    $autoP = $null; $autoTried = $false; $autoReady = $false; $ov = $null
    $running = [System.Collections.Generic.List[string]]::new()
    $dests = [System.Collections.Generic.List[string]]::new()          # копии applied\, нужные в этом применении
    $destsBy = @{}                                                         # то же по пакам-источникам (3.0: у приложения может быть свой вариант - PackId элемента)
    $keepRefs = [System.Collections.Generic.List[string]]::new()       # иконки ярлыков, которые остались как были (не удалять копии, на которые они смотрят)
    foreach ($m in @($Items)) {
        try {
            $regen = $false
            if (Test-AutoItem $m) {
                # автоиконка: режим приложения читаем из state.json в момент применения (его могли поменять после сканирования)
                if (-not $m.PSObject.Properties['ModeSet']) {            # элементы плана (ModeSet) уже прошли через режимы приложений
                    if ($null -eq $ov) { $ov = Get-AutoOverrides }
                    if ((Get-AutoMode ([string]$m.AutoKey) $ov) -ne 'Auto') { $autoSkipped++; continue }
                }
                if (-not $autoTried) {
                    $autoTried = $true
                    $autoP = Get-PackAuto $Pack
                    if ($autoP) { try { $autoReady = Initialize-AutoNative } catch { Write-Log ('Автоиконки недоступны: ' + $_.Exception.Message) } }
                }
                if (-not $autoReady) { $autoSkipped++; continue }
                $regen = ((New-AutoLinkFiles $m $autoP ([string]$Pack.Id) $backup $Pack) -eq 'generated')      # файлы в кэше актуальны или пересозданы (исходная иконка / стиль изменились)
            }
            if (-not (Test-Path -LiteralPath $m.IcoPath -PathType Leaf)) { throw "нет файла иконки $($m.IcoPath)" }
            $ico = [string]$m.IcoPath
            $already = [bool]$m.Already
            if (-not (Test-AutoItem $m)) {
                # ярлык указывает на копию applied\<пак>\<id>.<sha8>.ico: изменился файл иконки - изменился путь - изменилась иконка ярлыка (кэш Windows не отдаст старую)
                $itemPack = if ($m.PSObject.Properties['PackId'] -and [string]$m.PackId) { [string]$m.PackId } else { [string]$Pack.Id }
                $ico = Publish-AppliedIcon $itemPack ([string]$m.IconId) ([string]$m.IcoPath)
                $dests.Add($ico)
                if (-not $destsBy.ContainsKey($itemPack)) { $destsBy[$itemPack] = [System.Collections.Generic.List[string]]::new() }
                $destsBy[$itemPack].Add($ico)
                $already = Test-IconIsSet ([string]$m.Icon) $ico
            }
            if ($already -and -not $regen) { $same++; $keepRefs.Add([string]$m.Icon); continue }
            $how = 'обновлён файл'
            if ((Test-CommonLocation ([string]$m.Location)) -and -not $script:SI_CommonNoteLogged) {
                $script:SI_CommonNoteLogged = $true
                Write-Log '  общие ярлыки указывают на иконку в папке данных текущего пользователя: другие пользователи Windows могут видеть стандартные иконки'
            }
            if (-not $already) {
                Backup-File $backup $m.Path ([string]$m.Icon) (Get-ItemAppKey $m)
                $how = Set-LinkIcon $m.Path $ico
            }
            $after = [string](Get-WshShell).CreateShortcut($m.Path).IconLocation
            Send-ItemNotify $m.Path
            $changed++
            if (Test-AutoItem $m) { $autoDone++ }
            # приложение может пересоздать ярлык со своей иконкой - подменяем и сам .ico, на который он указывал
            # (автоиконки не трогаем: иначе следующий Apply прочитал бы уже стилизованную иконку как исходную)
            if ((-not (Test-AutoItem $m)) -and $m.Icon -match '^(.+?),\s*(-?\d+)$') {
                $orig = [Environment]::ExpandEnvironmentVariables($Matches[1].Trim().Trim('"'))
                if ((Test-IcoSwapPath $orig) -and (Test-Path -LiteralPath $orig -PathType Leaf)) {
                    if ((Get-FileSha256 $orig) -ne (Get-FileSha256 $m.IcoPath)) {
                        try {
                            Backup-File $backup $orig $null (Get-ItemAppKey $m)
                            Copy-Item -LiteralPath $m.IcoPath -Destination $orig -Force
                            Write-Log "       + подменён файл иконки приложения: $orig"
                        } catch { Write-Log "       не удалось подменить $orig : $($_.Exception.Message)" }
                    }
                }
            }
            $ok = if (Test-IconIsSet $after $ico) { 'OK' } else { '??' }
            Write-Log "  $ok $($m.Name)  <-  $($m.IconName)  [$how]"
            if (-not $already -and (Test-TargetRunning ([string]$m.Target)) -and -not ($running -contains [string]$m.Name)) {
                $running.Add([string]$m.Name)
                Write-Log "       $($m.Name) запущен — Windows может показывать иконку окна, пока приложение не закрыто"
            }
        } catch {
            $failed++
            $keepRefs.Add([string]$m.Icon)
            Write-Log "  ошибка с $($m.Name): $($_.Exception.Message)"
        }
    }
    foreach ($dp in @($destsBy.Keys)) { [void](Clear-StaleAppliedIcons ([string]$dp) $destsBy[$dp].ToArray() $keepRefs.ToArray()) }
    [void](Set-AppIconState $Pack)               # иконка самого приложения следует за паком (иконка с id 'glyphix')
    $st = Read-State
    if ($changed -gt 0 -or $same -gt 0) {
        $st['Applied'] = @{ PackId = $(if ($Pack.PSObject.Properties['BaseId'] -and $Pack.BaseId) { [string]$Pack.BaseId } else { [string]$Pack.Id }); VariantId = [string]$Pack.Id; CacheKey = $(if ($Pack.PSObject.Properties['CacheKey']) { [string]$Pack.CacheKey } else { '' }); Version = $Pack.Version; At = (Get-Date).ToString('s'); Count = ($changed + $same) }
        Save-State $st
    }
    Write-Log "Пак $($Pack.Name) $($Pack.Version): заменено $changed, уже стояли $same, ошибок $failed$(if ($autoDone -gt 0 -or $autoSkipped -gt 0) { ', автоиконок: ' + $autoDone + ' (пропущено: ' + $autoSkipped + ')' })"
    if ($failed -eq 0 -and ($changed + $same) -gt 0) { Invoke-LegacyCleanup }     # прежняя папка данных больше не нужна, если на неё не ссылается ни один ярлык
    $restarted = $false
    if ($changed -gt 0) { Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true; $restarted = [bool]$RestartExplorer }
    return [pscustomobject]@{ Changed = $changed; Same = $same; Failed = $failed; Total = @($Items).Count; Restarted = $restarted; Auto = $autoDone; AutoSkipped = $autoSkipped; Running = $running.ToArray()
        PackName = [string]$Pack.Name; PackVersion = [string]$Pack.Version; FromCache = [bool]($Pack.PSObject.Properties['FromCache'] -and $Pack.FromCache) }
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

# Папки, где может лежать установленный Start11 (Program Files и Program Files (x86))
function Get-Start11InstallDirs {
    $dirs = [System.Collections.Generic.List[string]]::new()
    foreach ($b in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramW6432)) {
        if (-not $b) { continue }
        $d = Join-Path (Join-Path $b 'Stardock') 'Start11'
        if (-not ($dirs -contains $d)) { $dirs.Add($d) }
    }
    return $dirs.ToArray()
}

# DisplayName записей удаления программ (HKLM 64/32 и HKCU); в тестах подменяется
function Get-UninstallDisplayNames {
    $names = [System.Collections.Generic.List[string]]::new()
    $roots = @(
        @([Microsoft.Win32.Registry]::LocalMachine, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'),
        @([Microsoft.Win32.Registry]::LocalMachine, 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'),
        @([Microsoft.Win32.Registry]::CurrentUser, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'))
    foreach ($r in $roots) {
        try {
            $k = $r[0].OpenSubKey($r[1], $false)
            if (-not $k) { continue }
            try {
                foreach ($sn in @($k.GetSubKeyNames())) {
                    try {
                        $sk = $k.OpenSubKey($sn, $false)
                        if ($sk) { try { $dn = $sk.GetValue('DisplayName'); if ($dn) { $names.Add([string]$dn) } } finally { $sk.Close() } }
                    } catch { }
                }
            } finally { $k.Close() }
        } catch { }
    }
    return $names.ToArray()
}

# Имена установленных Store (AppX) пакетов Start11; если командлета нет или он не работает - пусто; в тестах подменяется
function Get-Start11AppxNames {
    try {
        if (-not (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) { return @() }
        return @(Get-AppxPackage -Name '*Start11*' -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.Name })
    } catch { return @() }
}

# Start11 установлен: есть Start11*.exe в ...\Stardock\Start11\, запись удаления с DisplayName вида «Start11» либо Store-пакет (AppX) Start11.
# Одного ключа реестра HKCU\...\Start8.ini мало: он остаётся после удаления Start11.
function Test-Start11Installed {
    try {
        foreach ($d in @(Get-Start11InstallDirs)) {
            if ((Test-Path -LiteralPath $d -PathType Container) -and (Get-ChildItem -LiteralPath $d -Filter 'Start11*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1)) { return $true }
        }
    } catch { }
    try { if (@(Get-UninstallDisplayNames | Where-Object { $_ -like '*Start11*' }).Count -gt 0) { return $true } } catch { }
    try { if (@(Get-Start11AppxNames | Where-Object { $_ -like '*Start11*' }).Count -gt 0) { return $true } } catch { }
    return $false
}

# Start11 есть, если есть и его настройки в HKCU, и сама установка; один реестр без установки - остатки, плитки не пишем
function Test-Start11 {
    if (-not (Test-S11Key $script:SI_S11Root)) { return $false }
    return [bool](Test-Start11Installed)
}

# --- id плитки и сопоставление ---
# Подключи Start8, где Start11 хранит id плиток (имена значений = id); остальное дерево Start8.ini не читаем
$script:SI_S11TileKeys = @('CustomTiles', 'CustomTilesText', 'CustomTilesIcon', 'CustomTilesPainting', 'CustomText')

# id плитки - ссылка (http / https / ftp / mailto или любая scheme://): такие плитки пропускаем везде (кандидаты, сопоставление, список, применение)
function Test-UrlTileId {
    param([string]$Id)
    if (-not $Id) { return $false }
    $t = $Id.Trim()
    if ($t -match '^(?i)(https?|ftps?|mailto):') { return $true }
    return [bool](Get-TileIdInfo $t).Url
}

# Заголовок плитки в списке: имя из Get-StartApps (или ярлыка), иначе название иконки пака; сырой id - только в серой строке под заголовком
function Get-TileTitle {
    param($M)
    foreach ($pn in @('Name', 'IconName')) {
        if ($M -and $M.PSObject.Properties[$pn] -and [string]$M.$pn) { return [string]$M.$pn }
    }
    if ($M -and $M.PSObject.Properties['TileId']) { return [string]$M.TileId }
    return ''
}

# Приложения из Get-StartApps + имена значений из подключей Start8\CustomTiles*, CustomText
function Get-Start11Candidates {
    $map = @{}
    $list = [System.Collections.Generic.List[object]]::new()
    $apps = @()
    try { if (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue) { $apps = @(Get-StartApps) } } catch { Write-Log ('Get-StartApps: ' + $_.Exception.Message) }
    foreach ($a in $apps) {
        if (-not $a) { continue }
        $aid = [string]$a.AppID
        if (-not $aid) { continue }
        if (Test-UrlTileId $aid) { continue }                                  # плитка-ссылка (https://...): не приложение, в плитки не берём
        $id = $aid -replace '\\', '_'
        if ($map.ContainsKey($id)) { continue }
        $o = [pscustomobject]@{ Id = $id; Name = [string]$a.Name; Source = 'start'; AppId = $aid }
        $map[$id] = $o; $list.Add($o)
    }
    $names = @()
    foreach ($sk in $script:SI_S11TileKeys) {
        try { $names += @(Get-S11ValueNames ($script:SI_S11Root + '\Start8\' + $sk)) } catch { Write-Log ('чтение реестра Start11 (' + $sk + '): ' + $_.Exception.Message) }
    }
    foreach ($n in $names) {
        if (-not $n) { continue }
        if (Test-UrlTileId ([string]$n)) { continue }
        if ($map.ContainsKey($n)) { $map[$n].Source = 'start+reg'; continue }
        $o = [pscustomobject]@{ Id = [string]$n; Name = ''; Source = 'reg'; AppId = '' }
        $map[$n] = $o; $list.Add($o)
    }
    # 3.0: закреплённые элементы Start11 (GroupContents): их id - основной источник плиток, которых нет в Get-StartApps
    $pinSkipped = [System.Collections.Generic.List[string]]::new()
    try { [void](Add-PinnedCandidates $list $map $pinSkipped) } catch { Write-Log ('закреплённые элементы Start11: ' + $_.Exception.Message) }
    foreach ($ps in $pinSkipped) { Write-Log ('  Диагностика плиток: закреплённый id ' + $ps) }
    # сам Glyphix (2.6.0): ярлык «Glyphix» в меню Пуск идёт через wscript.exe с AppUserModelID F1KS.Glyphix; Get-StartApps может его не вернуть -
    # тогда плитку не на что вешать. Ярлык есть, а кандидата нет - добавляем кандидата F1KS.Glyphix сами (ровно один ключ, без запасных путей: wscript.exe общий).
    try {
        $self = [string]$script:SI_AppId
        $have = $null
        foreach ($c in $list) { if (([string]$c.Id -ceq $self) -or ([string]$c.AppId -ceq $self)) { $have = $c; break } }
        if ($have) {
            if (-not [string]$have.Name) { $have.Name = 'Glyphix' }
            if (-not [string]$have.AppId) { $have.AppId = $self }
        } elseif (-not (@($list | Where-Object { (Get-Key ([string]$_.Name)) -eq 'glyphix' -and [string]$_.Source -ne 'pinned' }).Count -gt 0) -and (Test-AppStartShortcut)) {
            $o = [pscustomobject]@{ Id = $self; Name = 'Glyphix'; Source = 'app'; AppId = $self }
            $list.Add($o)
            Write-Log ("  плитка Glyphix: Get-StartApps не вернул ярлык - добавлен кандидат '" + $self + "'")
        }
    } catch { Write-Log ('  кандидат Glyphix: ' + $_.Exception.Message) }
    return $list.ToArray()
}

# ярлык Glyphix в меню Пуск пользователя существует (его создаёт установщик; в тестах подменяется)
function Test-AppStartShortcut {
    try { $p = @(Get-AppShortcutPaths)[0]; return [bool]($p -and (Test-Path -LiteralPath $p -PathType Leaf)) } catch { return $false }
}

# кандидат - сам Glyphix (AppID F1KS.Glyphix)?
function Test-SelfTileCandidate {
    param($C)
    $self = [string]$script:SI_AppId
    if (-not $C) { return $false }
    if ([string]$C.Id -ceq $self) { return $true }
    if ($C.PSObject.Properties['Aumid'] -and ([string]$C.Aumid -ceq $self)) { return $true }          # закреплённый ярлык Glyphix (.lnk с AUMID F1KS.Glyphix)
    return [bool]($C.PSObject.Properties['AppId'] -and ([string]$C.AppId -ceq $self))
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

# Что можно вытащить из id плитки. Pwa = PWA Chrome/Edge (Chrome._crx_<id>) и Url = id-ссылка (scheme://...): по id не сопоставляем вообще.
# Keys = упорядоченные ключи для точного сравнения с names (последний токен важнее: com.anilibria.anilibrix -> anilibrix);
# Last = ключ имени файла/последнего токена для exes и префикса.
function Get-TileIdInfo {
    param([string]$Id)
    $info = [pscustomobject]@{ Pwa = $false; Url = $false; Keys = @(); Last = '' }
    if (-not $Id) { return $info }
    $s = $Id.Trim()
    if ($s -match '\._crx_') { $info.Pwa = $true; return $info }
    if ($s -match '^[A-Za-z][A-Za-z0-9+.\-]+://') { $info.Url = $true; return $info }      # плитка-ссылка (https://www.geeks3d.com/discord/): путь адреса - не имя приложения
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
    $keys = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    $n = $tokens.Count
    $cand = [System.Collections.Generic.List[string]]::new()
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

# расширение плитки в нашей папке = расширение исходного файла (.png / .jpg / .jpeg); без источника - .png
function Get-Start11TileExt {
    param([string]$Src = '')
    $e = ''
    try { $e = [IO.Path]::GetExtension($Src).ToLowerInvariant() } catch { }
    if ($e -eq '.jpg' -or $e -eq '.jpeg') { return $e }
    return '.png'
}

# start11\<пак>\<id>.<sha8><ext>: путь зависит от содержимого исходной плитки (изменилась картинка - новый путь - Start11 перечитает её, а не отдаст старую из кэша).
# Исходного файла нет - путь без sha8 (<id><ext>).
function Get-Start11TileDest {
    param([string]$PackId, [string]$IconId, [string]$Src = '')
    $name = $IconId
    if ($Src -and (Test-Path -LiteralPath $Src -PathType Leaf)) { try { $name = $IconId + '.' + (Get-FileSha256 $Src).Substring(0, 8) } catch { } }
    return (Join-Path (Join-Path $script:SI_S11Dir $PackId) ($name + (Get-Start11TileExt $Src)))
}

# Удалить прежние файлы плитки того же id в папке пака (<id>.png / .jpg / <id>.<другой sha8>.png|jpg): после смены содержимого или .png <-> .jpg.
# Только внутри нашей папки start11, только обычные файлы, и только если на файл не ссылается ни одно значение CustomTiles
# (другая плитка с тем же рисунком ещё может смотреть на него).
function Remove-StaleTileFiles {
    param([string]$Dest)
    try {
        $dir = [IO.Path]::GetDirectoryName($Dest)
        $id = [IO.Path]::GetFileName($Dest).Split('.')[0]
        $destFull = [IO.Path]::GetFullPath($Dest)
        $root = [IO.Path]::GetFullPath($script:SI_S11Dir).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not ([IO.Path]::GetFullPath($dir) + [IO.Path]::DirectorySeparatorChar).StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return }
        if (-not $id -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        $rx = '^' + [regex]::Escape($id) + '(\.[0-9a-f]{8})?\.(png|jpe?g)$'
        $refs = $null
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notmatch $rx) { continue }
            if ($f.FullName -ieq $destFull) { continue }
            if ($null -eq $refs) {
                $refs = @{}
                foreach ($n in @(Get-S11ValueNames $script:SI_S11Tiles)) { try { $v = Get-S11Value $script:SI_S11Tiles $n; if ($v) { $refs[$v.ToLowerInvariant()] = $true } } catch { } }
            }
            if ($refs.ContainsKey($f.FullName.ToLowerInvariant())) { continue }
            if (([int]$f.Attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
            Remove-Item -LiteralPath $f.FullName -Force
            Write-Log "  удалена прежняя плитка: $($f.FullName)"
        }
    } catch { Write-Log ('  прежняя плитка не удалена: ' + $_.Exception.Message) }
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
    param([Parameter(Mandatory)]$Pack, $Candidates, [switch]$NoName, [switch]$Auto, $Overrides)
    if ($null -eq $Candidates) { $Candidates = @(Get-Start11Candidates) }
    $index = New-TileIndex $Pack
    $out = [System.Collections.Generic.List[object]]::new()
    $autoP = $null                                   # -Auto: плитки без иконки в паке - автоплитки (Auto = $true), если у пака есть auto.json
    if ($Auto) { $autoP = Get-PackAuto $Pack; if ($null -eq $Overrides) { $Overrides = Get-AutoOverrides } }
    foreach ($c in @($Candidates)) {
        try {
            if ((Test-UrlTileId ([string]$c.Id)) -or ($c.PSObject.Properties['AppId'] -and (Test-UrlTileId ([string]$c.AppId)))) { continue }     # плитка-ссылка
            $m = $null
            if (Test-SelfTileCandidate $c) {              # Glyphix: всегда иконка 'glyphix' пака - не автоплитка и не «wscript/деинсталлятор» по имени
                $selfIc = @($Pack.Icons | Where-Object { [string]$_.Id -ieq 'glyphix' }) | Select-Object -First 1
                if ($selfIc) { $m = [pscustomobject]@{ Icon = $selfIc; Rule = 'self' } }
            }
            $matchId = $(if ($c.PSObject.Properties['RawId'] -and [string]$c.RawId) { [string]$c.RawId } else { [string]$c.Id })        # закреплённые: id с '\' (имя файла в конце), а не склеенный через '_'
            if (-not $m) { $m = Find-TileMatch $index $c.Name $matchId }
            if (-not $m -and $c.PSObject.Properties['Target'] -and [string]$c.Target -and -not (Test-LauncherHostName ([string]$c.Target))) { $m = Find-IconMatch $index $c.Name ([string]$c.Target) ([string]$c.Args) }       # .lnk закреплённого: цель - настоящий exe
            if (-not $m -and $c.PSObject.Properties['Aumid'] -and [string]$c.Aumid) { $m = Find-TileMatch $index '' ([string]$c.Aumid) }          # .lnk с AUMID (Glyphix: F1KS.Glyphix)
            if (-not $m) {
                if ($autoP) { $ai = New-AutoTileItem $c ([string]$Pack.Id) $Overrides ([bool]$NoName); if ($ai) { $out.Add($ai) } }
                continue
            }
            $src = $m.Icon.TilePath
            if ($NoName -and $m.Icon.TileNoNamePath) { $src = $m.Icon.TileNoNamePath }
            if (-not $src) { continue }
            $dest = Get-Start11TileDest ([string]$Pack.Id) ([string]$m.Icon.Id) $src
            $out.Add([pscustomobject]@{
                TileId = [string]$c.Id; Name = [string]$c.Name; Title = $(if ([string]$c.Name) { [string]$c.Name } else { [string]$m.Icon.Name }); Source = [string]$c.Source
                IconId = [string]$m.Icon.Id; IconName = [string]$m.Icon.Name; Group = [string]$m.Icon.Group; TilePath = $src
                Rule = $m.Rule; Already = (Test-Start11TileSet ([string]$c.Id) $dest $src); Auto = $false
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
    $tmp = Get-TempSibling $Path
    try {
        [IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding($true)))
        Move-IntoPlace -Tmp $tmp -Dest $Path
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
            $ak = $null
            if ($e.PSObject.Properties['AppKey'] -and $e.AppKey) { $ak = [string]$e.AppKey }
            $map[[string]$e.Id] = [pscustomobject]@{ Absent = $absent; Data = $(if ($absent) { $null } else { [string]$e.Data }); Kind = $kind; AppKey = $ak }
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
    $arr = foreach ($k in $Map.Keys) {
        $o = [ordered]@{ Id = $k; Absent = [bool]$Map[$k].Absent; Data = $Map[$k].Data; Kind = $(if ($Map[$k].PSObject.Properties['Kind'] -and $Map[$k].Kind) { [string]$Map[$k].Kind } else { 'String' }) }
        if ($Map[$k].PSObject.Properties['AppKey'] -and $Map[$k].AppKey) { $o['AppKey'] = [string]$Map[$k].AppKey }
        [pscustomobject]$o
    }
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
    $r = [pscustomobject]@{ Ok = $true; Paths = ([System.Collections.Generic.List[string]]::new()); Launch = ([System.Collections.Generic.List[object]]::new()) }
    try {
        if ($null -eq $Procs) { $Procs = @(Get-Start11Processes) }
        $ids = [System.Collections.Generic.List[int]]::new()
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
    param([Parameter(Mandatory)]$Pack, $Items, [switch]$NoName, [switch]$NoReload, [switch]$NoAuto)
    Assert-ElevationSafe
    Assert-LegacyMigrationComplete               # бэкап прежней версии ещё не перенесён - не применяем
    $none = [pscustomobject]@{ Changed = 0; Same = 0; Failed = 0; Total = 0; Reload = $null; Hint = '' }
    if (-not (Test-Start11)) { Write-Log 'Start11 не найден - плитки пропускаю.'; return $none }
    # сначала index.json + pack.json + файлы плиток (Install-Pack), потом пак заново читаем с диска: плитки применяем только по свежему pack.json
    $fr = Resolve-FreshPack $Pack @($(if ($NoName) { 'noname' } else { 'tiles' }))
    $Pack = $fr.Pack
    if ($fr.Replaced -and $null -ne $Items) {
        Write-Log 'Пак обновился с момента сканирования - сопоставляю плитки заново'
        $Items = @(Convert-TileItemsToFreshPack $Items $Pack ([bool]$NoName) ((-not $NoAuto) -and (Get-AutoEnabled)))
    }
    Write-Log "Применяю плитки Start11: $($Pack.Name) $($Pack.Version)"
    if ($null -eq $Items) { $Items = @(Get-Start11Matches -Pack $Pack -NoName:$NoName -Auto:((-not $NoAuto) -and (Get-AutoEnabled))) }
    $Items = @($Items | Where-Object { $_ -and -not (Test-UrlTileId ([string]$_.TileId)) })      # плитки-ссылки (https://...) не трогаем ни при каких условиях
    $preFailed = 0
    if (@($Items | Where-Object { Test-AutoItem $_ }).Count -gt 0) {      # автоплитки: режим приложения + создание .jpg до записи в реестр
        $ri = Resolve-AutoTileItems $Pack $Items ([bool]$NoName)
        $Items = @($ri.Items); $preFailed = [int]$ri.Failed
        if ($ri.Skipped -gt 0) { Write-Log "Автоплитки: пропущено $($ri.Skipped) (режим «родная»/«не трогать» или автоиконки недоступны)" }
    }
    $backup = Load-S11Backup           # не читается - исключение до любых изменений, исходные значения не потеряем
    $changed = 0; $same = 0; $failed = $preFailed
    # есть что менять -> сначала закрываем Start11, пишем реестр, потом запускаем обратно
    # значения не REG_SZ/REG_EXPAND_SZ не трогаем - ради них Start11 не закрываем
    $needs = @($Items | Where-Object {
        try {
            $kind = Get-S11Kind $script:SI_S11Tiles ([string]$_.TileId)
            if ($kind -and $kind -ne 'String' -and $kind -ne 'ExpandString') { return $false }
            -not (Test-Start11TileSet ([string]$_.TileId) (Get-Start11TileDest (Get-ItemPackId $_ $Pack) ([string]$_.IconId) ([string]$_.TilePath)) ([string]$_.TilePath))
        } catch { $true } })
    $stop = $null; $restarted = $true
    if ($needs.Count -gt 0 -and -not $NoReload) { $stop = Stop-Start11 }
    try {
    foreach ($m in @($Items)) {
        try {
            $id = [string]$m.TileId; $src = [string]$m.TilePath; $icId = [string]$m.IconId
            if (-not $id -or $icId -notmatch '^[A-Za-z0-9_\-]+$') { throw 'неверные данные плитки' }
            if ($src -notmatch '\.(png|jpe?g)$' -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { throw "нет файла плитки $src" }
            $dest = Get-Start11TileDest (Get-ItemPackId $m $Pack) $icId $src
            if (Test-Start11TileSet $id $dest $src) { Remove-StaleTileFiles $dest; $same++; continue }
            $cur = Get-S11Value $script:SI_S11Tiles $id                    # не REG_SZ - исключение, значение не трогаем
            $curKind = 'String'
            if ($null -ne $cur) { $k0 = Get-S11Kind $script:SI_S11Tiles $id; if ($k0 -eq 'ExpandString') { $curKind = 'ExpandString' } }
            Save-FileAtomic $dest ([IO.File]::ReadAllBytes($src))
            if (-not $backup.ContainsKey($id)) {                           # первый оригинал храним, пока не откатим
                $backup[$id] = [pscustomobject]@{ Absent = ($null -eq $cur); Data = $cur; Kind = $curKind; AppKey = $(Get-ItemAppKey $m) }
                Save-S11Backup $backup
            }
            Set-S11Value $script:SI_S11Tiles $id $dest
            if ((Get-S11Value $script:SI_S11Tiles $id) -ine $dest) { throw 'значение в реестре не записалось' }
            Remove-StaleTileFiles $dest                                     # реестр уже смотрит на новый файл - старый (.png <-> .jpg) не нужен
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
    # диагностика по log.txt: под каким id записана плитка самого Glyphix (закреплённые id, Get-StartApps, AUMID ярлыков, записанные id)
    try {
        $selfM = @($Items | Where-Object { [string]$_.IconId -ieq 'glyphix' })
        if ($selfM.Count -gt 0 -or @($Pack.Icons | Where-Object { [string]$_.Id -ieq 'glyphix' }).Count -gt 0) {
            $wr = [System.Collections.Generic.List[string]]::new()
            foreach ($sm in $selfM) {
                $now = $null; try { $now = Get-S11Value $script:SI_S11Tiles ([string]$sm.TileId) } catch { }
                $wr.Add([string]$sm.TileId + $(if ($now) { ' (в реестре: ' + $now + ')' } else { ' (значения в реестре нет)' }))
                Write-Log ("  плитка Glyphix: id '" + [string]$sm.TileId + "' <- иконка glyphix, " + $(if ($now) { 'в реестре: ' + $now } else { 'в реестре значения нет' }))
            }
            $dg = Get-GlyphixTileDiagnostics -Written $wr.ToArray()
            foreach ($ln in $dg.Lines) { Write-Log ('  ' + $ln) }
            if ($selfM.Count -eq 0) { Write-Log ("  плитка Glyphix: не применена - среди кандидатов Start11 нет '" + [string]$script:SI_AppId + "' (нет ярлыка в меню Пуск и Get-StartApps его не вернул)") }
        }
    } catch { }
    $st = Read-State
    if ($changed -gt 0 -or $same -gt 0) {
        $st['Tiles'] = @{ PackId = $(if ($Pack.PSObject.Properties['BaseId'] -and $Pack.BaseId) { [string]$Pack.BaseId } else { [string]$Pack.Id }); VariantId = [string]$Pack.Id; Version = $Pack.Version; At = (Get-Date).ToString('s'); Count = ($changed + $same) }
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
    return [pscustomobject]@{ Changed = $changed; Same = $same; Failed = $failed; Total = @($Items).Count; Reload = $reload; Hint = $hint; PackName = [string]$Pack.Name; PackVersion = [string]$Pack.Version; FromCache = [bool]($Pack.PSObject.Properties['FromCache'] -and $Pack.FromCache) }
}

# Откат плиток: возвращаем ровно то, что сохранено (значение того же вида или его отсутствие). Как и при применении:
# сначала закрываем Start11, пишем реестр, в finally запускаем обратно. PNG и start11.json удаляем только когда всё вернулось
# и Start11 либо корректно перезапущен, либо вообще не запущен; при -NoReload и работающем Start11 оставляем их (Kept = $true).
function Undo-Start11Tiles {
    [CmdletBinding()]
    param([switch]$NoReload, [string[]]$Ids = $null)          # -Ids (3.0): вернуть только эти плитки (частичный откат приложений), остальное в бэкапе остаётся
    Assert-ElevationSafe
    $backup = Load-S11Backup
    $partial = ($null -ne $Ids)
    if ($partial) { $want = @{}; foreach ($i in @($Ids)) { $want[[string]$i] = $true } }
    $keys = @($backup.Keys | Where-Object { -not $partial -or $want.ContainsKey([string]$_) })
    if ($backup.Count -eq 0 -or $keys.Count -eq 0) { return [pscustomobject]@{ Restored = 0; Failed = 0; Nothing = $true; Kept = $false; Reload = $null; Hint = '' } }
    $n = 0; $failed = 0
    $stop = $null; $restarted = $true; $running = $false
    if ($NoReload) {
        try { $running = (@(Get-Start11Processes).Count -gt 0) } catch { $running = $true }
    } else {
        $stop = Stop-Start11
    }
    try {
        foreach ($id in $keys) {
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
    if ($failed -eq 0 -and $safe -and $backup.Count -eq 0) { Remove-Start11Files }
    elseif ($failed -eq 0 -and $kept) { Write-Log 'Start11 работает: PNG плиток и start11.json оставлены, повторите откат после перезапуска Start11.' }
    $st = Read-State
    if ($failed -eq 0 -and $safe -and $backup.Count -eq 0 -and $st.ContainsKey('Tiles')) { $st.Remove('Tiles'); Save-State $st }
    Write-Log "Плитки Start11 возвращены: $n$(if ($failed -gt 0) { ', не удалось: ' + $failed })"
    return [pscustomobject]@{ Restored = $n; Failed = $failed; Nothing = $false; Kept = $kept; Reload = $reload; Hint = $hint }
}

function Remove-Start11Files {
    try { if (Test-Path -LiteralPath $script:SI_S11Dir) { [void](Remove-TreeSafe $script:SI_S11Dir $script:SI_Home) } } catch { Write-Log "start11 не удалена: $($_.Exception.Message)" }
}

function Remove-CopyQuiet {
    param([string]$Copy)
    try { if ($Copy -and (Test-Path -LiteralPath $Copy)) { Remove-Item -LiteralPath $Copy -Force } } catch { }
}

# ---------- Автоиконки (2.4.0) ----------
# Приложения, для которых в применённом паке нет иконки, получают СВОЮ родную иконку, перекрашенную в стиль пака (локально, без сети):
# пак отдаёт только параметры стиля (packs\<id>\auto.json), всё остальное считается на этом компьютере.
# Файлы: %LOCALAPPDATA%\Glyphix\auto\<пак>\<ключ>.ico (+ .png превью, .jpg плитка Start11, .key - ключ кэша). Применяются так же, как иконки пака
# (бэкап, откат, значения Start11), поэтому откат возвращает всё, а папка auto\ после полного отката удаляется.
$script:SI_AutoDir = Join-Path $script:SI_Home 'auto'
$script:SI_AutoStyleVersion = 1                         # = GlyphixAuto.AutoStyle.StyleVersion; меняется вместе с алгоритмом - кэш пересоздаётся
$script:SI_AutoIcoSizes = [int[]]@(16, 24, 32, 48, 64, 128, 256)
$script:SI_AutoModes = @('Auto', 'Native', 'Off')        # Auto - перекрасить; Native - оставить родную иконку приложения; Off - не трогать
$script:SI_AutoTileSize = 640
$script:SI_AutoTileIcon = 384                           # холст иконки для плитки (сжимается в плитку, отсюда чёткость)
$script:SI_AutoLastError = ''

# C#: чистая стилизация (без System.Drawing/WinAPI - компилируется и проверяется и на Linux) и Windows-часть (оболочка, GDI+, плитка).
# C# 5 / .NET 4.x: без интерполяции строк, ?., expression-bodied членов.
$script:SI_AutoStyleCode = @'
using System;
using System.IO;
using System.IO.Compression;

namespace GlyphixAuto
{
    // Параметры стиля пака (auto.json). Цвета - 0xRRGGBB.
    public sealed class AutoParams
    {
        public int Dark;
        public int Mid;
        public int Light;
        public int Rim;
        public int Glow;
        public int GlowPx;
        public int Pixelate;
        public bool Rainbow;
        public bool Hud;
        public bool Sticker;
    }

    // Чистая стилизация пикселей (без System.Drawing и без WinAPI): работает и в тестах на Linux.
    // Пиксели - BGRA, 4 байта, прозрачность не предумножена (straight alpha), строки сверху вниз.
    public static class AutoStyle
    {
        public const int StyleVersion = 1;

        static float Clamp01(float v) { return v < 0f ? 0f : (v > 1f ? 1f : v); }

        // ---------- BGRA <-> float RGBA (предумноженный) ----------
        static float[] FromBgra(byte[] bgra, int w, int h)
        {
            float[] p = new float[w * h * 4];
            for (int i = 0, n = w * h; i < n; i++)
            {
                float a = bgra[i * 4 + 3] / 255f;
                p[i * 4] = bgra[i * 4 + 2] / 255f * a;
                p[i * 4 + 1] = bgra[i * 4 + 1] / 255f * a;
                p[i * 4 + 2] = bgra[i * 4] / 255f * a;
                p[i * 4 + 3] = a;
            }
            return p;
        }

        static byte ToByte(float v)
        {
            int b = (int)(v * 255f + 0.5f);
            return (byte)(b < 0 ? 0 : (b > 255 ? 255 : b));
        }

        static byte[] ToBgra(float[] p, int w, int h)
        {
            byte[] o = new byte[w * h * 4];
            for (int i = 0, n = w * h; i < n; i++)
            {
                float a = p[i * 4 + 3];
                if (a <= 0.001f) continue;
                o[i * 4 + 3] = ToByte(a);
                o[i * 4 + 2] = ToByte(p[i * 4] / a);
                o[i * 4 + 1] = ToByte(p[i * 4 + 1] / a);
                o[i * 4] = ToByte(p[i * 4 + 2] / a);
            }
            return o;
        }

        // ---------- предумноженная ли картинка (HBITMAP из оболочки бывает и такой) ----------
        // Предумноженной считаем, если есть полупрозрачные пиксели и нигде цвет не больше альфы.
        public static bool LooksPremultiplied(byte[] bgra)
        {
            bool semi = false;
            for (int i = 0; i + 3 < bgra.Length; i += 4)
            {
                int a = bgra[i + 3];
                if (bgra[i] > a || bgra[i + 1] > a || bgra[i + 2] > a) return false;
                if (a > 0 && a < 255) semi = true;
            }
            return semi;
        }

        public static byte[] FixPremultiplied(byte[] bgra)
        {
            if (!LooksPremultiplied(bgra)) return bgra;
            for (int i = 0; i + 3 < bgra.Length; i += 4)
            {
                int a = bgra[i + 3];
                if (a == 0 || a == 255) continue;
                for (int c = 0; c < 3; c++)
                {
                    int v = (bgra[i + c] * 255 + a / 2) / a;
                    bgra[i + c] = (byte)(v > 255 ? 255 : v);
                }
            }
            return bgra;
        }

        // есть ли в картинке хоть что-то видимое (не пустая и не полностью прозрачная)
        public static bool HasContent(byte[] bgra)
        {
            int n = 0;
            for (int i = 3; i < bgra.Length; i += 4) { if (bgra[i] > 16) { n++; if (n >= 16) return true; } }
            return false;
        }

        // ---------- изменение размера (предумноженный float RGBA): box-фильтр при уменьшении, билинейно при увеличении ----------
        static void BuildWeights(int sn, int dn, out int[] start, out float[][] wts)
        {
            start = new int[dn];
            wts = new float[dn][];
            double ratio = (double)sn / dn;
            for (int i = 0; i < dn; i++)
            {
                if (ratio > 1.0)
                {
                    double a = i * ratio, b = (i + 1) * ratio;
                    int s0 = (int)Math.Floor(a);
                    int s1 = (int)Math.Ceiling(b) - 1;
                    if (s0 < 0) s0 = 0;
                    if (s1 > sn - 1) s1 = sn - 1;
                    if (s1 < s0) s1 = s0;
                    int n = s1 - s0 + 1;
                    float[] w = new float[n];
                    double sum = 0;
                    for (int k = 0; k < n; k++)
                    {
                        double lo = Math.Max(a, s0 + k), hi = Math.Min(b, s0 + k + 1);
                        double v = Math.Max(0.0, hi - lo);
                        w[k] = (float)v;
                        sum += v;
                    }
                    if (sum <= 0) { w[0] = 1f; sum = 1; }
                    for (int k = 0; k < n; k++) w[k] = (float)(w[k] / sum);
                    start[i] = s0;
                    wts[i] = w;
                }
                else
                {
                    double c = (i + 0.5) * ratio - 0.5;
                    int s0 = (int)Math.Floor(c);
                    float f = (float)(c - s0);
                    int s1 = s0 + 1;
                    if (s0 < 0) { s0 = 0; f = 0f; }
                    if (s0 > sn - 1) { s0 = sn - 1; f = 0f; }
                    if (s1 > sn - 1) s1 = sn - 1;
                    if (s1 <= s0) { start[i] = s0; wts[i] = new float[] { 1f }; }
                    else { start[i] = s0; wts[i] = new float[] { 1f - f, f }; }
                }
            }
        }

        static float[] Resample(float[] src, int sw, int sh, int dw, int dh)
        {
            if (sw == dw && sh == dh) return (float[])src.Clone();
            int[] xs; float[][] xw; int[] ys; float[][] yw;
            BuildWeights(sw, dw, out xs, out xw);
            BuildWeights(sh, dh, out ys, out yw);
            float[] tmp = new float[dw * sh * 4];
            for (int y = 0; y < sh; y++)
                for (int x = 0; x < dw; x++)
                {
                    float[] w = xw[x];
                    float r = 0, g = 0, b = 0, a = 0;
                    for (int k = 0; k < w.Length; k++)
                    {
                        int si = (y * sw + xs[x] + k) * 4;
                        r += src[si] * w[k]; g += src[si + 1] * w[k]; b += src[si + 2] * w[k]; a += src[si + 3] * w[k];
                    }
                    int di = (y * dw + x) * 4;
                    tmp[di] = r; tmp[di + 1] = g; tmp[di + 2] = b; tmp[di + 3] = a;
                }
            float[] dst = new float[dw * dh * 4];
            for (int y = 0; y < dh; y++)
            {
                float[] w = yw[y];
                for (int x = 0; x < dw; x++)
                {
                    float r = 0, g = 0, b = 0, a = 0;
                    for (int k = 0; k < w.Length; k++)
                    {
                        int si = ((ys[y] + k) * dw + x) * 4;
                        r += tmp[si] * w[k]; g += tmp[si + 1] * w[k]; b += tmp[si + 2] * w[k]; a += tmp[si + 3] * w[k];
                    }
                    int di = (y * dw + x) * 4;
                    dst[di] = r; dst[di + 1] = g; dst[di + 2] = b; dst[di + 3] = a;
                }
            }
            return dst;
        }

        public static byte[] Resize(byte[] bgra, int w, int h, int nw, int nh)
        {
            return ToBgra(Resample(FromBgra(bgra, w, h), w, h, nw, nh), nw, nh);
        }

        static float[] NearestUp(float[] src, int sw, int sh, int dw, int dh)
        {
            float[] dst = new float[dw * dh * 4];
            for (int y = 0; y < dh; y++)
            {
                int sy = Math.Min(sh - 1, (int)((long)y * sh / dh));
                for (int x = 0; x < dw; x++)
                {
                    int sx = Math.Min(sw - 1, (int)((long)x * sw / dw));
                    int si = (sy * sw + sx) * 4, di = (y * dw + x) * 4;
                    dst[di] = src[si]; dst[di + 1] = src[si + 1]; dst[di + 2] = src[si + 2]; dst[di + 3] = src[si + 3];
                }
            }
            return dst;
        }

        // ---------- маски (float 0..1, w*h) ----------
        static float[] Dilate(float[] m, int w, int h, int r)
        {
            if (r < 1) return (float[])m.Clone();
            int cnt = 0;
            int[] dx = new int[(2 * r + 1) * (2 * r + 1)];
            int[] dy = new int[dx.Length];
            for (int y = -r; y <= r; y++)
                for (int x = -r; x <= r; x++)
                    if (x * x + y * y <= r * r + 1) { dx[cnt] = x; dy[cnt] = y; cnt++; }
            float[] o = new float[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    float best = 0f;
                    for (int k = 0; k < cnt; k++)
                    {
                        int xx = x + dx[k], yy = y + dy[k];
                        if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
                        float v = m[yy * w + xx];
                        if (v > best) { best = v; if (best >= 1f) break; }
                    }
                    o[y * w + x] = best;
                }
            return o;
        }

        // минимум по кругу (эрозия); за краем холста - 0
        static float[] Erode(float[] m, int w, int h, int r)
        {
            int cnt = 0;
            int[] dx = new int[(2 * r + 1) * (2 * r + 1)];
            int[] dy = new int[dx.Length];
            for (int y = -r; y <= r; y++)
                for (int x = -r; x <= r; x++)
                    if (x * x + y * y <= r * r + 1) { dx[cnt] = x; dy[cnt] = y; cnt++; }
            float[] o = new float[w * h];
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                {
                    float best = 1f;
                    for (int k = 0; k < cnt && best > 0f; k++)
                    {
                        int xx = x + dx[k], yy = y + dy[k];
                        float v = (xx < 0 || yy < 0 || xx >= w || yy >= h) ? 0f : m[yy * w + xx];
                        if (v < best) best = v;
                    }
                    o[y * w + x] = best;
                }
            return o;
        }

        static void Box1D(float[] src, float[] dst, int n, int stride, int offset, int r, float[] pre)
        {
            pre[0] = 0f;
            for (int i = 0; i < n; i++) pre[i + 1] = pre[i] + src[offset + i * stride];
            float div = 2 * r + 1;
            for (int i = 0; i < n; i++)
            {
                int lo = i - r; if (lo < 0) lo = 0;
                int hi = i + r + 1; if (hi > n) hi = n;
                dst[offset + i * stride] = (pre[hi] - pre[lo]) / div;
            }
        }

        // три прохода коробочного размытия ~ гауссиан; за краем маска нулевая
        static float[] Blur(float[] m, int w, int h, int r)
        {
            if (r < 1) return (float[])m.Clone();
            float[] a = (float[])m.Clone();
            float[] b = new float[a.Length];
            float[] pre = new float[Math.Max(w, h) + 1];
            for (int pass = 0; pass < 3; pass++)
            {
                for (int y = 0; y < h; y++) Box1D(a, b, w, 1, y * w, r, pre);
                for (int x = 0; x < w; x++) Box1D(b, a, h, w, x, r, pre);
            }
            return a;
        }

        static float[] Shift(float[] m, int w, int h, int dx, int dy)
        {
            float[] o = new float[m.Length];
            for (int y = 0; y < h; y++)
            {
                int sy = y - dy;
                if (sy < 0 || sy >= h) continue;
                for (int x = 0; x < w; x++)
                {
                    int sx = x - dx;
                    if (sx < 0 || sx >= w) continue;
                    o[y * w + x] = m[sy * w + sx];
                }
            }
            return o;
        }

        // слой цвета с маской поверх накопленного результата (предумноженный float RGBA)
        static void OverMask(float[] dst, float[] mask, int rgb, float mul)
        {
            float cr = ((rgb >> 16) & 255) / 255f, cg = ((rgb >> 8) & 255) / 255f, cb = (rgb & 255) / 255f;
            for (int i = 0; i < mask.Length; i++)
            {
                float la = Clamp01(mask[i] * mul);
                if (la <= 0f) continue;
                float k = 1f - la;
                dst[i * 4] = cr * la + dst[i * 4] * k;
                dst[i * 4 + 1] = cg * la + dst[i * 4 + 1] * k;
                dst[i * 4 + 2] = cb * la + dst[i * 4 + 2] * k;
                dst[i * 4 + 3] = la + dst[i * 4 + 3] * k;
            }
        }

        static void Hsv(float h, float s, float v, out float r, out float g, out float b)
        {
            h = h - (float)Math.Floor(h / 360f) * 360f;
            float c = v * s;
            float hp = h / 60f;
            float x = c * (1f - Math.Abs(hp % 2f - 1f));
            float r1 = 0, g1 = 0, b1 = 0;
            if (hp < 1) { r1 = c; g1 = x; }
            else if (hp < 2) { r1 = x; g1 = c; }
            else if (hp < 3) { g1 = c; b1 = x; }
            else if (hp < 4) { g1 = x; b1 = c; }
            else if (hp < 5) { r1 = x; b1 = c; }
            else { r1 = c; b1 = x; }
            float m = v - c;
            r = r1 + m; g = g1 + m; b = b1 + m;
        }

        // ---------- главная функция ----------
        // Иконка (любого размера) -> холст canvas x canvas (256 для .ico, больше для плиток): обрезка по видимой части, вписывание с полями ~8%
        // (поля увеличиваются под свечение), опционально пикселизация, дуотон по яркости (тёмный -> средний -> светлый) или радуга,
        // потом слои: тень/белый контур (sticker) либо свечение и кайма; сверху сама иконка. Прозрачность иконки сохраняется.
        public static byte[] Stylize(byte[] bgra, int w, int h, AutoParams p, int canvas)
        {
            if (bgra == null || w < 1 || h < 1 || bgra.Length < w * h * 4) throw new ArgumentException("bitmap");
            if (p == null) throw new ArgumentNullException("p");
            if (canvas < 16 || canvas > 2048) throw new ArgumentException("canvas");
            float s = canvas / 256f;
            int n = canvas * canvas;
            float[] src = FromBgra(bgra, w, h);

            int x0 = w, y0 = h, x1 = -1, y1 = -1;
            for (int y = 0; y < h; y++)
                for (int x = 0; x < w; x++)
                    if (src[(y * w + x) * 4 + 3] > 0.04f)
                    {
                        if (x < x0) x0 = x; if (x > x1) x1 = x;
                        if (y < y0) y0 = y; if (y > y1) y1 = y;
                    }
            if (x1 < 0) return new byte[n * 4];
            int cw = x1 - x0 + 1, ch = y1 - y0 + 1;
            float[] crop = new float[cw * ch * 4];
            for (int y = 0; y < ch; y++) Array.Copy(src, ((y0 + y) * w + x0) * 4, crop, y * cw * 4, cw * 4);

            float glowR = p.GlowPx * s;
            float margin = Math.Max(canvas * 0.08f, glowR * 1.3f + 3f);
            if (margin > canvas * 0.2f) margin = canvas * 0.2f;
            float scale = (canvas - 2f * margin) / Math.Max(cw, ch);
            int nw = Math.Max(1, (int)Math.Round(cw * scale));
            int nh = Math.Max(1, (int)Math.Round(ch * scale));
            float[] fit = Resample(crop, cw, ch, nw, nh);
            if (p.Pixelate >= 2)
            {
                int pw = Math.Max(1, (int)Math.Round((double)p.Pixelate * nw / Math.Max(nw, nh)));
                int ph = Math.Max(1, (int)Math.Round((double)p.Pixelate * nh / Math.Max(nw, nh)));
                fit = NearestUp(Resample(fit, nw, nh, pw, ph), pw, ph, nw, nh);
            }
            float[] shape = new float[n * 4];
            int ox = (canvas - nw) / 2, oy = (canvas - nh) / 2;
            for (int y = 0; y < nh; y++) Array.Copy(fit, y * nw * 4, shape, ((oy + y) * canvas + ox) * 4, nw * 4);

            // яркость и растяжение по 5%..95% (альфа-взвешенно)
            float[] lum = new float[n];
            int[] hist = new int[256];
            int cnt = 0;
            for (int i = 0; i < n; i++)
            {
                float a = shape[i * 4 + 3];
                if (a <= 0.02f) continue;
                float r = Clamp01(shape[i * 4] / a), g = Clamp01(shape[i * 4 + 1] / a), b = Clamp01(shape[i * 4 + 2] / a);
                float l = 0.2126f * r + 0.7152f * g + 0.0722f * b;
                lum[i] = l;
                if (a > 0.5f) { hist[(int)(l * 255f)]++; cnt++; }
            }
            float lo = 0f, hi = 1f;
            if (cnt > 20)
            {
                int acc = 0, i5 = 0, i95 = 255;
                bool got5 = false;
                for (int i = 0; i < 256; i++)
                {
                    acc += hist[i];
                    if (!got5 && acc >= cnt * 0.05) { i5 = i; got5 = true; }
                    if (acc >= cnt * 0.95) { i95 = i; break; }
                }
                if (i95 - i5 >= 16) { lo = i5 / 255f; hi = i95 / 255f; }
            }
            float dr = ((p.Dark >> 16) & 255) / 255f, dg = ((p.Dark >> 8) & 255) / 255f, db = (p.Dark & 255) / 255f;
            float mr = ((p.Mid >> 16) & 255) / 255f, mg = ((p.Mid >> 8) & 255) / 255f, mb = (p.Mid & 255) / 255f;
            float lr = ((p.Light >> 16) & 255) / 255f, lg = ((p.Light >> 8) & 255) / 255f, lb = (p.Light & 255) / 255f;
            int hudStep = Math.Max(3, (int)Math.Round(4 * s)), hudThick = Math.Max(1, (int)Math.Round(s));

            float[] sh = new float[n * 4];
            float[] alpha = new float[n];
            for (int y = 0; y < canvas; y++)
                for (int x = 0; x < canvas; x++)
                {
                    int i = y * canvas + x;
                    float a = shape[i * 4 + 3];
                    if (a <= 0.0005f) continue;
                    alpha[i] = a;
                    float t = Clamp01((lum[i] - lo) / (hi - lo));
                    float cr, cg, cb;
                    if (p.Rainbow)
                    {
                        Hsv((x + y) / (2f * canvas) * 360f, 0.85f, 0.25f + 0.75f * t, out cr, out cg, out cb);
                    }
                    else if (t < 0.5f)
                    {
                        float u = t * 2f;
                        cr = dr + (mr - dr) * u; cg = dg + (mg - dg) * u; cb = db + (mb - db) * u;
                    }
                    else
                    {
                        float u = (t - 0.5f) * 2f;
                        cr = mr + (lr - mr) * u; cg = mg + (lg - mg) * u; cb = mb + (lb - mb) * u;
                    }
                    if (p.Hud && (y % hudStep) < hudThick) { cr *= 0.72f; cg *= 0.72f; cb *= 0.72f; }
                    sh[i * 4] = cr * a; sh[i * 4 + 1] = cg * a; sh[i * 4 + 2] = cb * a; sh[i * 4 + 3] = a;
                }

            float[] outp = new float[n * 4];
            if (p.Sticker)
            {
                int rr = Math.Max(2, (int)Math.Round(6 * s));
                float[] d = Dilate(alpha, canvas, canvas, rr);
                d = Blur(d, canvas, canvas, 1);
                for (int i = 0; i < n; i++) d[i] = Clamp01(d[i] * 1.5f);
                float[] shadow = Blur(Shift(d, canvas, canvas, (int)Math.Round(2 * s), (int)Math.Round(4 * s)), canvas, canvas, Math.Max(1, (int)Math.Round(2 * s)));
                OverMask(outp, shadow, 0x000000, 0.55f);
                OverMask(outp, d, 0xFFFFFF, 1f);
            }
            else
            {
                if (p.GlowPx > 0)
                {
                    float[] gl = Blur(alpha, canvas, canvas, Math.Max(1, (int)Math.Round(glowR / 2f)));
                    OverMask(outp, gl, p.Glow, 1.8f);
                }
                int rimR = Math.Max(1, (int)Math.Round((p.Hud ? 2.5f : 2f) * s));
                OverMask(outp, Dilate(alpha, canvas, canvas, rimR), p.Rim, 1f);
            }
            // внутри формы (все пиксели в радиусе 3 px хоть немного непрозрачны) подложки нет: полупрозрачная заливка иконки остаётся такой, какая была
            float[] inner = Erode(alpha, canvas, canvas, Math.Max(2, (int)Math.Round(3 * s)));
            for (int i = 0; i < n; i++)
            {
                float keep = 1f - Clamp01(inner[i] * 4f);
                if (keep >= 1f) continue;
                outp[i * 4] *= keep; outp[i * 4 + 1] *= keep; outp[i * 4 + 2] *= keep; outp[i * 4 + 3] *= keep;
            }
            // подложка (свечение, кайма, контур) - только снаружи формы: там, где иконка полупрозрачна, общая прозрачность остаётся её собственной,
            // а снаружи равна max(иконка, подложка). Подложка p поверх иконки a даёт a + p*(1-a), поэтому берём p' = (u - a) / (1 - a).
            for (int i = 0; i < n; i++)
            {
                float a = alpha[i];
                float u = outp[i * 4 + 3];
                if (u <= 0f) continue;
                if (a >= 0.999f || u <= a)
                {
                    outp[i * 4] = 0f; outp[i * 4 + 1] = 0f; outp[i * 4 + 2] = 0f; outp[i * 4 + 3] = 0f;
                    continue;
                }
                float f = (u - a) / (1f - a) / u;
                outp[i * 4] *= f; outp[i * 4 + 1] *= f; outp[i * 4 + 2] *= f; outp[i * 4 + 3] *= f;
            }
            for (int i = 0; i < n; i++)
            {
                float a = sh[i * 4 + 3];
                if (a <= 0f) continue;
                float k = 1f - a;
                outp[i * 4] = sh[i * 4] + outp[i * 4] * k;
                outp[i * 4 + 1] = sh[i * 4 + 1] + outp[i * 4 + 1] * k;
                outp[i * 4 + 2] = sh[i * 4 + 2] + outp[i * 4 + 2] * k;
                outp[i * 4 + 3] = a + outp[i * 4 + 3] * k;
            }
            return ToBgra(outp, canvas, canvas);
        }

        // ---------- PNG ----------
        static uint[] crcTable;

        static uint Crc32(byte[] buf, int off, int len, uint crc)
        {
            if (crcTable == null)
            {
                uint[] t = new uint[256];
                for (uint n = 0; n < 256; n++)
                {
                    uint c = n;
                    for (int k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                    t[n] = c;
                }
                crcTable = t;
            }
            crc = crc ^ 0xFFFFFFFFu;
            for (int i = 0; i < len; i++) crc = crcTable[(crc ^ buf[off + i]) & 255] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }

        static void WriteBE(Stream s, uint v)
        {
            s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
        }

        static void Chunk(Stream s, string type, byte[] data)
        {
            byte[] tb = new byte[4 + data.Length];
            for (int i = 0; i < 4; i++) tb[i] = (byte)type[i];
            Array.Copy(data, 0, tb, 4, data.Length);
            WriteBE(s, (uint)data.Length);
            s.Write(tb, 0, tb.Length);
            WriteBE(s, Crc32(tb, 0, tb.Length, 0));
        }

        static uint Adler32(byte[] d)
        {
            uint a = 1, b = 0;
            for (int i = 0; i < d.Length; i++) { a = (a + d[i]) % 65521u; b = (b + a) % 65521u; }
            return (b << 16) | a;
        }

        // BGRA -> PNG (RGBA 8 бит, без фильтров)
        public static byte[] EncodePng(byte[] bgra, int w, int h)
        {
            int stride = w * 4 + 1;
            byte[] raw = new byte[stride * h];
            for (int y = 0; y < h; y++)
            {
                int ro = y * stride;
                raw[ro] = 0;
                for (int x = 0; x < w; x++)
                {
                    int si = (y * w + x) * 4, di = ro + 1 + x * 4;
                    raw[di] = bgra[si + 2]; raw[di + 1] = bgra[si + 1]; raw[di + 2] = bgra[si]; raw[di + 3] = bgra[si + 3];
                }
            }
            MemoryStream z = new MemoryStream();
            z.WriteByte(0x78); z.WriteByte(0x9C);
            using (DeflateStream ds = new DeflateStream(z, CompressionMode.Compress, true)) { ds.Write(raw, 0, raw.Length); }
            WriteBE(z, Adler32(raw));
            MemoryStream ms = new MemoryStream();
            byte[] sig = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            ms.Write(sig, 0, sig.Length);
            MemoryStream ih = new MemoryStream();
            WriteBE(ih, (uint)w); WriteBE(ih, (uint)h);
            ih.WriteByte(8); ih.WriteByte(6); ih.WriteByte(0); ih.WriteByte(0); ih.WriteByte(0);
            Chunk(ms, "IHDR", ih.ToArray());
            Chunk(ms, "IDAT", z.ToArray());
            Chunk(ms, "IEND", new byte[0]);
            return ms.ToArray();
        }

        // ---------- ICO из PNG-кадров ----------
        public static byte[] BuildIco(byte[][] pngs, int[] sizes)
        {
            int n = pngs.Length;
            MemoryStream ms = new MemoryStream();
            BinaryWriter bw = new BinaryWriter(ms);
            bw.Write((ushort)0); bw.Write((ushort)1); bw.Write((ushort)n);
            int offset = 6 + 16 * n;
            for (int i = 0; i < n; i++)
            {
                byte sz = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                bw.Write(sz); bw.Write(sz); bw.Write((byte)0); bw.Write((byte)0);
                bw.Write((ushort)1); bw.Write((ushort)32);
                bw.Write((uint)pngs[i].Length); bw.Write((uint)offset);
                offset += pngs[i].Length;
            }
            for (int i = 0; i < n; i++) bw.Write(pngs[i]);
            bw.Flush();
            return ms.ToArray();
        }

        // квадратный холст size0 x size0 -> .ico с кадрами указанных размеров (PNG)
        public static byte[] MakeIco(byte[] bgra, int size0, int[] sizes)
        {
            float[] pm = FromBgra(bgra, size0, size0);
            byte[][] frames = new byte[sizes.Length][];
            for (int i = 0; i < sizes.Length; i++)
            {
                byte[] f = ToBgra(Resample(pm, size0, size0, sizes[i], sizes[i]), sizes[i], sizes[i]);
                frames[i] = EncodePng(f, sizes[i], sizes[i]);
            }
            return BuildIco(frames, sizes);
        }
    }
}
'@

$script:SI_AutoShellCode = @'
namespace GlyphixAuto
{
    using System;
    using System.Drawing;
    using System.Drawing.Drawing2D;
    using System.Drawing.Imaging;
    using System.Drawing.Text;
    using System.IO;
    using System.Runtime.InteropServices;

    // Только Windows: родная иконка приложения (оболочка / ассоциированная иконка) и плитка Start11 (GDI+).
    public static class AutoShell
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct SIZE { public int cx; public int cy; }

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAP
        {
            public int bmType;
            public int bmWidth;
            public int bmHeight;
            public int bmWidthBytes;
            public ushort bmPlanes;
            public ushort bmBitsPixel;
            public IntPtr bmBits;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFO
        {
            public uint biSize;
            public int biWidth;
            public int biHeight;
            public ushort biPlanes;
            public ushort biBitCount;
            public uint biCompression;
            public uint biSizeImage;
            public int biXPelsPerMeter;
            public int biYPelsPerMeter;
            public uint biClrUsed;
            public uint biClrImportant;
            public uint bmiColors;
        }

        [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IShellItemImageFactory
        {
            [PreserveSig]
            int GetImage(SIZE size, int flags, out IntPtr phbm);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        static extern int SHCreateItemFromParsingName([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr pbc, ref Guid riid,
            [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);

        [DllImport("gdi32.dll")]
        static extern int GetObject(IntPtr h, int c, out BITMAP pv);

        [DllImport("gdi32.dll")]
        static extern bool DeleteObject(IntPtr h);

        [DllImport("gdi32.dll")]
        static extern IntPtr CreateCompatibleDC(IntPtr hdc);

        [DllImport("gdi32.dll")]
        static extern bool DeleteDC(IntPtr hdc);

        [DllImport("gdi32.dll")]
        static extern int GetDIBits(IntPtr hdc, IntPtr hbm, uint start, uint lines, byte[] bits, ref BITMAPINFO bmi, uint usage);

        // HBITMAP -> BGRA (сверху вниз). Без альфа-канала (все нули) - считаем непрозрачной.
        static byte[] HbitmapToBgra(IntPtr hbm, out int w, out int h)
        {
            w = 0; h = 0;
            BITMAP bm;
            if (GetObject(hbm, Marshal.SizeOf(typeof(BITMAP)), out bm) == 0) return null;
            w = bm.bmWidth; h = Math.Abs(bm.bmHeight);
            if (w < 1 || h < 1 || w > 4096 || h > 4096) return null;
            BITMAPINFO bi = new BITMAPINFO();
            bi.biSize = 40;
            bi.biWidth = w;
            bi.biHeight = -h;
            bi.biPlanes = 1;
            bi.biBitCount = 32;
            bi.biCompression = 0;
            byte[] px = new byte[w * h * 4];
            IntPtr dc = CreateCompatibleDC(IntPtr.Zero);
            if (dc == IntPtr.Zero) return null;
            try
            {
                if (GetDIBits(dc, hbm, 0, (uint)h, px, ref bi, 0) == 0) return null;
            }
            finally { DeleteDC(dc); }
            bool anyAlpha = false;
            for (int i = 3; i < px.Length; i += 4) { if (px[i] != 0) { anyAlpha = true; break; } }
            if (!anyAlpha) { for (int i = 3; i < px.Length; i += 4) px[i] = 255; }
            return px;
        }

        // IShellItemImageFactory.GetImage(SIIGBF_ICONONLY | SIIGBF_BIGGERSIZEOK) для файла / .lnk / shell:AppsFolder\<AppID>
        public static byte[] ExtractShell(string path, int size, out int w, out int h)
        {
            w = 0; h = 0;
            IShellItemImageFactory f;
            Guid iid = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
            int hr = SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out f);
            if (hr != 0 || f == null) return null;
            IntPtr hbm = IntPtr.Zero;
            try
            {
                SIZE sz; sz.cx = size; sz.cy = size;
                hr = f.GetImage(sz, 0x5, out hbm);
            }
            finally { Marshal.ReleaseComObject(f); }
            if (hr != 0 || hbm == IntPtr.Zero) return null;
            try
            {
                byte[] raw = HbitmapToBgra(hbm, out w, out h);
                if (raw == null) return null;
                return AutoStyle.FixPremultiplied(raw);
            }
            finally { DeleteObject(hbm); }
        }

        static byte[] BitmapToBgra(Bitmap bmp, out int w, out int h)
        {
            w = bmp.Width; h = bmp.Height;
            Rectangle r = new Rectangle(0, 0, w, h);
            BitmapData d = bmp.LockBits(r, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            try
            {
                byte[] px = new byte[w * h * 4];
                for (int y = 0; y < h; y++) Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), px, y * w * 4, w * 4);
                return px;
            }
            finally { bmp.UnlockBits(d); }
        }

        // запасной путь: Icon.ExtractAssociatedIcon (32x32 для exe/dll; .ico - как есть)
        public static byte[] ExtractFile(string path, out int w, out int h)
        {
            w = 0; h = 0;
            Icon ic = null;
            try
            {
                if (path.EndsWith(".ico", StringComparison.OrdinalIgnoreCase))
                {
                    try { ic = new Icon(path, new Size(256, 256)); } catch (Exception) { ic = null; }
                }
                if (ic == null) ic = Icon.ExtractAssociatedIcon(path);
                if (ic == null) return null;
                using (Bitmap bmp = ic.ToBitmap()) { return BitmapToBgra(bmp, out w, out h); }
            }
            finally { if (ic != null) ic.Dispose(); }
        }

        static Color Rgb(int rgb) { return Color.FromArgb(255, (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255); }

        static ImageCodecInfo JpegCodec()
        {
            foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) { if (c.MimeType == "image/jpeg") return c; }
            return null;
        }

        // Плитка Start11 size x size (JPEG): диагональный градиент фона, рамка 3 px, иконка по центру верхней части, подпись Segoe UI Semibold.
        public static byte[] RenderTile(byte[] icon, int iw, int ih, string title, int bg0, int bg1, int border, int titleRgb, int size, int quality)
        {
            using (Bitmap bmp = new Bitmap(size, size, PixelFormat.Format24bppRgb))
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                using (LinearGradientBrush lb = new LinearGradientBrush(new Rectangle(0, 0, size, size), Rgb(bg0), Rgb(bg1), 45f))
                {
                    g.FillRectangle(lb, 0, 0, size, size);
                }
                using (Pen pen = new Pen(Rgb(border), 3f))
                {
                    pen.Alignment = PenAlignment.Inset;
                    g.DrawRectangle(pen, 0, 0, size - 1, size - 1);
                }
                int box = (int)(size * 0.58);
                int ix = (size - box) / 2, iy = (int)(size * 0.07);
                using (Bitmap ib = new Bitmap(iw, ih, PixelFormat.Format32bppArgb))
                {
                    BitmapData d = ib.LockBits(new Rectangle(0, 0, iw, ih), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
                    try
                    {
                        for (int y = 0; y < ih; y++) Marshal.Copy(icon, y * iw * 4, new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), iw * 4);
                    }
                    finally { ib.UnlockBits(d); }
                    g.DrawImage(ib, new Rectangle(ix, iy, box, box));
                }
                if (!string.IsNullOrEmpty(title))
                {
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    float maxW = size - 80f, maxH = size * 0.25f;
                    float px = size * 0.07f;
                    Font font = null;
                    try
                    {
                        while (true)
                        {
                            if (font != null) font.Dispose();
                            font = new Font("Segoe UI Semibold", px, FontStyle.Regular, GraphicsUnit.Pixel);
                            SizeF m = g.MeasureString(title, font, (int)maxW);
                            if (m.Height <= maxH || px <= size * 0.04f) break;
                            px -= 2f;
                        }
                        using (StringFormat sf = new StringFormat())
                        using (SolidBrush br = new SolidBrush(Rgb(titleRgb)))
                        {
                            sf.Alignment = StringAlignment.Center;
                            sf.LineAlignment = StringAlignment.Center;
                            sf.Trimming = StringTrimming.EllipsisWord;
                            RectangleF rc = new RectangleF(40f, size * 0.70f, maxW, maxH);
                            g.DrawString(title, font, br, rc, sf);
                        }
                    }
                    finally { if (font != null) font.Dispose(); }
                }
                ImageCodecInfo codec = JpegCodec();
                MemoryStream ms = new MemoryStream();
                if (codec == null) { bmp.Save(ms, ImageFormat.Jpeg); return ms.ToArray(); }
                using (EncoderParameters ep = new EncoderParameters(1))
                {
                    ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                    bmp.Save(ms, codec, ep);
                }
                return ms.ToArray();
            }
        }
    }
}
'@

# Компиляция один раз на процесс (фоновые runspace'ы - тот же процесс, тип уже загружен). Windows: стилизатор + оболочка одной сборкой; иначе только стилизатор.
function Initialize-AutoNative {
    $win = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
    if ($win) { if (('GlyphixAuto.AutoStyle' -as [type]) -and ('GlyphixAuto.AutoShell' -as [type])) { return $true } }
    elseif ('GlyphixAuto.AutoStyle' -as [type]) { return $true }
    # именованный мьютекс: превью и применение (разные runspace'ы) не компилируют тип дважды
    $mtx = $null; $held = $false
    try { $mtx = New-Object System.Threading.Mutex($false, 'Local\GlyphixAutoCompile') } catch { $mtx = $null }
    try {
        if ($mtx) {
            try { $held = $mtx.WaitOne(20000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        }
        $loaded = { ('GlyphixAuto.AutoStyle' -as [type]) -and (-not $win -or ('GlyphixAuto.AutoShell' -as [type])) }
        if (& $loaded) { return $true }                       # другой runspace успел раньше
        try {
            if ($win) { Add-Type -TypeDefinition ($script:SI_AutoStyleCode + "`n" + $script:SI_AutoShellCode) -Language CSharp -ReferencedAssemblies 'System.Drawing' }
            else { Add-Type -TypeDefinition $script:SI_AutoStyleCode -Language CSharp }
        } catch {
            if (-not (& $loaded)) { throw }
        }
    } finally {
        if ($mtx) { if ($held) { try { $mtx.ReleaseMutex() } catch { } }; $mtx.Dispose() }
    }
    return $true
}

# ---------- auto.json ----------
function Test-AutoHex { param($V) return (([string]$V) -match '^#[0-9a-fA-F]{6}$') }
function ConvertTo-AutoRgb { param([string]$Hex) return [int][Convert]::ToInt32($Hex.TrimStart('#'), 16) }

function Get-JsonProp {
    param($Obj, [string]$Name)
    $p = $Obj.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Разбор и проверка auto.json. Возвращает нормализованные параметры или $null (причина - в $script:SI_AutoLastError, и пак тогда
# считается «без автоиконок»). Лишние поля игнорируются; необязательные: rim (= light), glow (= mid), glow_px (0), bg, border (= rim), title (= light),
# pixelate (0 = нет; иначе 2..128), rainbow/hud/sticker (false).
function ConvertFrom-AutoJson {
    param([string]$Text, [string]$Sha = '')
    $script:SI_AutoLastError = ''
    try {
        if ($Text.Length -gt 0 -and $Text[0] -eq [char]0xFEFF) { $Text = $Text.Substring(1) }
        $j = $Text | ConvertFrom-Json
        if ($null -eq $j -or $j -isnot [pscustomobject]) { throw 'ожидался объект JSON' }
        $schema = Get-JsonProp $j 'schema'
        if ($null -ne $schema -and (($schema -isnot [int] -and $schema -isnot [long]) -or [int]$schema -ne 1)) { throw "неподдерживаемая schema '$schema'" }
        $style = Get-JsonProp $j 'style'
        if ($null -eq $style) { $style = 'custom' }
        if (([string]$style) -notmatch '^[A-Za-z0-9_\-]{1,32}$') { throw "неверный style '$style'" }
        $col = {
            param([string]$Name, $Default)
            $v = Get-JsonProp $j $Name
            if ($null -eq $v) {
                if ($null -eq $Default) { throw "нет цвета '$Name'" }
                return $Default
            }
            if (-not (Test-AutoHex $v)) { throw "цвет '$Name' должен быть вида #rrggbb" }
            return ([string]$v).ToLowerInvariant()
        }
        $dark = & $col 'dark' $null; $mid = & $col 'mid' $null; $light = & $col 'light' $null
        $rim = & $col 'rim' $light; $glow = & $col 'glow' $mid
        $border = & $col 'border' $rim; $title = & $col 'title' $light
        $intv = {
            param([string]$Name, [int]$Def, [int]$Min, [int]$Max)
            $v = Get-JsonProp $j $Name
            if ($null -eq $v) { return $Def }
            if ($v -is [bool] -or ($v -isnot [int] -and $v -isnot [long] -and $v -isnot [double])) { throw "'$Name' должно быть числом" }
            if ([double]$v -ne [math]::Floor([double]$v)) { throw "'$Name' должно быть целым" }
            if ([double]$v -lt $Min -or [double]$v -gt $Max) { throw "'$Name' вне диапазона $Min..$Max" }
            return [int]$v
        }
        $glowPx = & $intv 'glow_px' 0 0 64
        $pix = & $intv 'pixelate' 0 0 128
        if ($pix -eq 1) { throw "'pixelate' должно быть 0 или 2..128" }
        $bg = @($dark, '#000000')
        $bgv = Get-JsonProp $j 'bg'
        if ($null -ne $bgv) {
            $arr = @($bgv)
            if ($arr.Count -ne 2 -or -not (Test-AutoHex $arr[0]) -or -not (Test-AutoHex $arr[1])) { throw "'bg' должно быть двумя цветами #rrggbb" }
            $bg = @(([string]$arr[0]).ToLowerInvariant(), ([string]$arr[1]).ToLowerInvariant())
        }
        $flag = {
            param([string]$Name)
            $v = Get-JsonProp $j $Name
            if ($null -eq $v) { return $false }
            if ($v -isnot [bool]) { throw "'$Name' должно быть true/false" }
            return [bool]$v
        }
        return [pscustomobject]@{
            Schema = 1; Style = [string]$style; Dark = $dark; Mid = $mid; Light = $light; Rim = $rim; Glow = $glow; GlowPx = $glowPx
            Bg0 = $bg[0]; Bg1 = $bg[1]; Border = $border; Title = $title; Pixelate = $pix
            Rainbow = (& $flag 'rainbow'); Hud = (& $flag 'hud'); Sticker = (& $flag 'sticker'); Sha = [string]$Sha
        }
    } catch {
        $script:SI_AutoLastError = $_.Exception.Message
        return $null
    }
}

# файл auto.json (до 64 КБ) -> параметры; $ExpectSha - sha256 из pack.json: не совпал - файл не принимаем
function Read-AutoParams {
    param([string]$Path, [string]$ExpectSha = '')
    $script:SI_AutoLastError = ''
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { $script:SI_AutoLastError = 'файла нет'; return $null }
        if ((Get-Item -LiteralPath $Path).Length -gt 65536) { $script:SI_AutoLastError = 'файл больше 64 КБ'; return $null }
        $bytes = [IO.File]::ReadAllBytes($Path)
        $sha = Get-BytesSha256 $bytes
        if ($ExpectSha -and $sha -ne $ExpectSha.ToLowerInvariant()) { $script:SI_AutoLastError = 'sha256 не совпал с pack.json'; return $null }
        return (ConvertFrom-AutoJson ([System.Text.Encoding]::UTF8.GetString($bytes)) $sha)
    } catch { $script:SI_AutoLastError = $_.Exception.Message; return $null }
}

# параметры пака (если у пака есть auto.json): из Get-Packs; объявлен, но не скачан - докачиваем один этот файл (часть 'auto')
function Get-PackAuto {
    param($Pack)
    if (-not $Pack) { return $null }
    if ($Pack.PSObject.Properties['Auto'] -and $Pack.Auto) { return $Pack.Auto }
    if (-not ($Pack.PSObject.Properties['AutoDeclared'] -and $Pack.AutoDeclared)) { return $null }
    try {
        Confirm-PackFiles $Pack -Parts @('auto')
        $a = Read-AutoParams ([string]$Pack.AutoPath) ([string]$Pack.AutoSha)
        if (-not $a) { Write-Log ('auto.json пака ' + $Pack.Id + ' не принят: ' + $script:SI_AutoLastError) }
        return $a
    } catch { Write-Log ('auto.json пака ' + $Pack.Id + ' не получен: ' + $_.Exception.Message); return $null }
}

function ConvertTo-AutoNativeParams {
    param($A)
    $p = New-Object GlyphixAuto.AutoParams
    $p.Dark = ConvertTo-AutoRgb $A.Dark; $p.Mid = ConvertTo-AutoRgb $A.Mid; $p.Light = ConvertTo-AutoRgb $A.Light
    $p.Rim = ConvertTo-AutoRgb $A.Rim; $p.Glow = ConvertTo-AutoRgb $A.Glow
    $p.GlowPx = [int]$A.GlowPx; $p.Pixelate = [int]$A.Pixelate
    $p.Rainbow = [bool]$A.Rainbow; $p.Hud = [bool]$A.Hud; $p.Sticker = [bool]$A.Sticker
    return $p
}

# ---------- настройки: общий выключатель и режим по приложениям (state.json: AutoIcons, AutoOverrides) ----------
function Get-AutoEnabled {
    try { $st = Read-State; if ($st.ContainsKey('AutoIcons')) { return [bool]$st['AutoIcons'] } } catch { }
    return $true
}

function Set-AutoEnabled {
    param([bool]$On)
    $st = Read-State; $st['AutoIcons'] = $On; Save-State $st
}

function Get-AutoModeName {
    param([string]$Mode)
    foreach ($m in $script:SI_AutoModes) { if ($m -ieq $Mode) { return $m } }
    return $null
}

# режимы, отличные от Auto: ключ приложения -> 'Native' | 'Off' (неизвестные значения в файле игнорируются)
function Get-AutoOverrides {
    param($State = $null)
    $h = @{}
    try {
        if ($null -eq $State) { $State = Read-State }
        if ($State.ContainsKey('AutoOverrides') -and $State['AutoOverrides']) {
            $o = $State['AutoOverrides']
            $pairs = if ($o -is [System.Collections.IDictionary]) { @($o.Keys | ForEach-Object { @{ N = [string]$_; V = $o[$_] } }) } else { @($o.PSObject.Properties | ForEach-Object { @{ N = $_.Name; V = $_.Value } }) }
            foreach ($pr in $pairs) {
                $m = Get-AutoModeName ([string]$pr.V)
                if ($m -and $m -ne 'Auto' -and $pr.N) { $h[[string]$pr.N] = $m }
            }
        }
    } catch { }
    return $h
}

function Get-AutoMode {
    param([string]$Key, $Overrides)
    if ($Key -and $Overrides -and $Overrides.ContainsKey($Key)) { return [string]$Overrides[$Key] }
    return 'Auto'
}

function Set-AutoOverride {
    param([string]$Key, [string]$Mode)
    if (-not $Key) { return }
    $canon = Get-AutoModeName $Mode
    if (-not $canon) { throw "неизвестный режим автоиконки '$Mode'" }
    $st = Read-State
    $h = Get-AutoOverrides $st
    if ($canon -eq 'Auto') { $h.Remove($Key) } else { $h[$Key] = $canon }
    if ($h.Count -eq 0) { [void]$st.Remove('AutoOverrides') } else { $st['AutoOverrides'] = $h }
    Save-State $st
    try { Sync-AppOverrideFromLegacy $Key $canon } catch { Write-Log ('AppOverrides: ' + $_.Exception.Message) }       # 3.0: тот же выбор в AppOverrides (приложение 'auto:<ключ>')
}

# ключ приложения для режима: по имени (один выбор действует на все его ярлыки и плитку Start11)
function Get-AutoAppKey {
    param([string]$Name)
    return (Get-Key $Name)
}

# ---------- что считать приложением ----------
# имена «справка / readme / сайт / удаление / панель управления»: не приложения
$script:SI_AutoJunkNameRx = '(?i)readme|read me|release notes|changelog|license|licence|\beula\b|\bhelp\b|\bfaq\b|\bmanual\b|documentation|справк|помощь|руководств|документац|лицензи|что нового|веб-?сайт|\bwebsite\b|\bсайт\b|панель управления|control panel|uninstall|удалить|удаление|деинсталл'
$script:SI_AutoJunkTargetRx = '(?i)\.(url|html?|mht|txt|pdf|chm|hlp|rtf|md|xml|json|log|ini|doc|docx|msi|msp|reg|inf|msc|cpl)$'
$script:SI_AutoJunkArgsRx = '(?i)ms-settings:|shell:::|::\{|\.cpl\b|control\.exe|/uninstall|--uninstall|-uninstall|/x\s*\{'
$script:SI_AutoJunkExeKeys = @('control', 'rundll32', 'msiexec', 'mmc', 'regedit')

# $null - приложение; строка - почему пропускаем (для журнала и тестов)
function Get-AutoSkipReason {
    param($S)
    $name = [string]$S.Name
    if (-not (Get-AutoAppKey $name)) { return 'нет имени' }
    if ($name -match $script:SI_AutoJunkNameRx) { return 'справка/сайт/удаление/панель управления' }
    $path = [string]$S.Path
    if ($path -and [IO.Path]::GetExtension($path) -ine '.lnk') { return 'не .lnk (.url и т.п.)' }
    $target = [string]$S.Target
    $ar = [string]$S.Args
    $tk = if ($target) { Get-Key (Get-BaseNameSafe $target) } else { '' }
    if (Test-UninstallLike (Get-Key $name) $tk) { return 'деинсталлятор' }
    if ($target) {
        if ($target -match $script:SI_AutoJunkTargetRx) { return 'документ/ссылка/панель управления' }
        if ($target -match '^[A-Za-z][A-Za-z0-9+.\-]*://') { return 'ссылка' }
        if ($script:SI_AutoJunkExeKeys -contains $tk) { return 'системная утилита' }
        if ($tk -eq 'explorer' -and $ar) { return 'explorer с аргументами (папка/панель)' }
        try { if (Test-Path -LiteralPath $target -PathType Container) { return 'папка' } } catch { }
    }
    if ($ar -match $script:SI_AutoJunkArgsRx) { return 'панель управления/параметры/удаление' }
    return $null
}

function Get-AutoSkipReasonTile {
    param($C)
    $name = [string]$C.Name
    $aid = ''
    if ($C.PSObject.Properties['AppId']) { $aid = [string]$C.AppId }
    if (-not $aid) { return 'нет AppID' }
    if (-not (Get-AutoAppKey $name)) { return 'нет имени' }
    if ($name -match $script:SI_AutoJunkNameRx) { return 'справка/сайт/удаление/панель управления' }
    if ($C.PSObject.Properties['Ambiguous'] -and $C.Ambiguous) { return 'общий хост (wscript/cmd/powershell) без AUMID' }
    $info = Get-TileIdInfo ([string]$C.Id)
    if ($info.Url -or $aid -match '^[A-Za-z][A-Za-z0-9+.\-]*://') { return 'ссылка' }
    if (Test-UninstallLike (Get-Key $name) $info.Last) { return 'деинсталлятор' }
    if ($aid -match '(?i)controlpanel|control\.exe|\.cpl|\.msc|\.url|ms-settings:|\\help\\|readme') { return 'панель управления/справка' }
    return $null
}

# ---------- ключи, пути, кэш ----------
# имя файла: латиница из имени (до 20 символов) + 10 hex от (имя | идентификатор цели); один ключ - один набор файлов
function Get-AutoSafeKey {
    param([string]$Name, [string]$Ident)
    $k = Get-Key $Name
    $ascii = [regex]::Replace($k, '[^a-z0-9]', '')
    if ($ascii.Length -gt 20) { $ascii = $ascii.Substring(0, 20) }
    if (-not $ascii) { $ascii = 'app' }
    $h = (Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($k + '|' + ([string]$Ident).ToLowerInvariant()))).Substring(0, 10)
    return ($ascii + '_' + $h)
}

function Get-AutoPaths {
    param([string]$PackId, [string]$SafeKey)
    if ($PackId -notmatch '^[a-z0-9][a-z0-9_\-]{0,63}$' -or $SafeKey -notmatch '^[a-z0-9_]{1,40}$') { throw 'неверный ключ автоиконки' }
    $d = Join-Path $script:SI_AutoDir $PackId
    return [pscustomobject]@{ Dir = $d; Ico = (Join-Path $d ($SafeKey + '.ico')); Png = (Join-Path $d ($SafeKey + '.png')); Tile = (Join-Path $d ($SafeKey + '.jpg')) }
}

# ключ кэша: версия алгоритма | что строим (ico/tile) | sha256 пикселей исходной иконки | sha256 auto.json | подпись плитки
function Get-AutoCacheKey {
    param([string]$Kind, [string]$SrcHash, [string]$AutoSha, [string]$Title = '', [string]$OpsKey = '')
    $s = ('v' + $script:SI_AutoStyleVersion + '|' + $Kind + '|' + $SrcHash + '|' + $AutoSha + '|' + $Title + $(if ($Kind -eq 'ico') { '|' + ($script:SI_AutoIcoSizes -join ',') } else { '' }) + $(if ($OpsKey) { '|ops:' + $OpsKey } else { '' }))
    return (Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($s)))
}

function Test-AutoCache {
    param([string]$File, [string]$Key)
    try {
        if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return $false }
        $kf = $File + '.key'
        if (-not (Test-Path -LiteralPath $kf -PathType Leaf)) { return $false }
        return (([IO.File]::ReadAllText($kf)).Trim() -eq $Key)
    } catch { return $false }
}

function Save-AutoCacheKey {
    param([string]$File, [string]$Key)
    Save-FileAtomic ($File + '.key') ([System.Text.UTF8Encoding]::new($false).GetBytes($Key))
}

# иконка ярлыка уже указывает в нашу папку auto\ (значит сам ярлык отдаст уже перекрашенную иконку, а не родную)
function Test-AutoIconLocation {
    param([string]$Loc)
    try {
        $p = (Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$Loc))).Path
        if (-not $p) { return $false }
        return (Test-PathUnder ([IO.Path]::GetFullPath($p)) ([IO.Path]::GetFullPath($script:SI_AutoDir)))
    } catch { return $false }
}

# ---------- кандидаты ----------
function New-AutoLinkItem {
    param($S, $PackId, $Overrides)
    if (Get-AutoSkipReason $S) { return $null }
    $key = Get-AutoAppKey ([string]$S.Name)
    $mode = Get-AutoMode $key $Overrides
    $ident = ([string]$S.Target + '|' + [string]$S.Args)
    if ($ident -eq '|') { $ident = [string]$S.Path }
    $safe = Get-AutoSafeKey ([string]$S.Name) $ident
    $pp = Get-AutoPaths $PackId $safe
    return [pscustomobject]@{
        Name = $S.Name; Path = $S.Path; Location = $S.Location; Target = $S.Target; Args = $S.Args; Icon = $S.Icon
        IconId = 'auto'; IconName = 'авто'; Group = 'auto'; IcoPath = $pp.Ico; PngPath = $pp.Png
        Rule = 'auto'; Already = (($mode -eq 'Auto') -and (Test-IconIsSet ([string]$S.Icon) $pp.Ico))
        Auto = $true; AutoKey = $key; AutoMode = $mode; SafeKey = $safe
    }
}

function New-AutoTileItem {
    param($C, $PackId, $Overrides, [bool]$NoName)
    if (Get-AutoSkipReasonTile $C) { return $null }
    $name = [string]$C.Name
    $key = Get-AutoAppKey $name
    $mode = Get-AutoMode $key $Overrides
    $safe = Get-AutoSafeKey $name ([string]$C.AppId)
    $pp = Get-AutoPaths $PackId $safe
    $iconId = 'auto_' + $safe
    $dest = Get-Start11TileDest $PackId $iconId $pp.Tile
    return [pscustomobject]@{
        TileId = [string]$C.Id; Name = $name; Source = [string]$C.Source
        IconId = $iconId; IconName = 'авто'; Group = 'auto'; TilePath = $pp.Tile
        Rule = 'auto'; Already = (($mode -eq 'Auto') -and (Test-Start11TileSet ([string]$C.Id) $dest $pp.Tile))
        Auto = $true; AutoKey = $key; AutoMode = $mode; SafeKey = $safe; AppId = [string]$C.AppId; AutoNoName = $NoName
        Pinned = [bool]($C.PSObject.Properties['Pinned'] -and $C.Pinned)
    }
}

function Test-AutoItem {
    param($M)
    return [bool]($M -and $M.PSObject.Properties['Auto'] -and $M.Auto)
}

# ---------- исходная иконка ----------
# Источники по порядку (первый, давший картинку, побеждает). Ярлык с явной иконкой (.ico, либо иконка самой цели с индексом 0) читаем по
# файлу иконки/цели - без стрелки ярлыка; иначе - сам .lnk (или его копия из бэкапа: после нашей замены сам ярлык уже отдаёт НАШУ иконку).
function Get-AutoLinkSources {
    param($Item, $Backup)
    $list = [System.Collections.Generic.List[object]]::new()
    $lnk = [string]$Item.Path
    $copy = ''
    $orig = [string]$Item.Icon
    if ($Backup -and $lnk -and $Backup.ContainsKey($lnk)) {
        $e = $Backup[$lnk]
        if ($e.Copy -and (Test-Path -LiteralPath ([string]$e.Copy) -PathType Leaf)) { $copy = [string]$e.Copy }
        if ($null -ne $e.Icon) { $orig = [string]$e.Icon }
    }
    $ours = Test-AutoIconLocation $orig
    $target = [Environment]::ExpandEnvironmentVariables([string]$Item.Target)
    $hasTarget = $false
    try { $hasTarget = [bool]($target -and (Test-Path -LiteralPath $target -PathType Leaf)) } catch { }
    $loc = Split-IconLocation ([Environment]::ExpandEnvironmentVariables($orig))
    $direct = ''
    if (-not $ours) {
        $ip = [string]$loc.Path
        if ($ip -match '(?i)\.ico$' -and (Test-Path -LiteralPath $ip -PathType Leaf)) {
            $direct = $ip
            # файл иконки приложения уже подменяли (старые версии) - оригинал лежит в бэкапе, а не по этому пути
            if ($Backup -and $Backup.ContainsKey($ip)) {
                $be = $Backup[$ip]
                if ($be -and $be.Copy -and (Test-Path -LiteralPath ([string]$be.Copy) -PathType Leaf)) { $direct = [string]$be.Copy }
            }
        }
        elseif ($hasTarget -and (-not $ip -or ($loc.Index -eq 0 -and $ip -ieq $target))) { $direct = $target }
    }
    if ($direct) { $list.Add(@{ Kind = 'shell'; Path = $direct }) }
    if ($copy) { $list.Add(@{ Kind = 'shell'; Path = $copy }) }
    elseif (-not $ours -and $lnk) { $list.Add(@{ Kind = 'shell'; Path = $lnk }) }
    if ($hasTarget -and $direct -ne $target) { $list.Add(@{ Kind = 'shell'; Path = $target }) }
    if ($hasTarget) { $list.Add(@{ Kind = 'file'; Path = $target }) }
    return $list.ToArray()
}

function Get-AutoTileSources {
    param($Item)
    $list = [System.Collections.Generic.List[object]]::new()
    $aid = [string]$Item.AppId
    if ($aid) {
        $pinP = ''; if ($Item.PSObject.Properties['Pinned'] -and $Item.Pinned) { $pinP = Expand-PinnedPath $aid }
        if ($pinP) { try { if (Test-Path -LiteralPath $pinP -PathType Leaf) { $list.Add(@{ Kind = 'shell'; Path = $pinP }) } } catch { } }       # закреплённый путь / .lnk - иконку берём у файла
        else { $list.Add(@{ Kind = 'shell'; Path = ('shell:AppsFolder\' + $aid) }) }
        $ex = [Environment]::ExpandEnvironmentVariables($aid)
        try { if ($ex -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $ex -PathType Leaf)) { $list.Add(@{ Kind = 'file'; Path = $ex }) } } catch { }
    }
    return $list.ToArray()
}

# 256-px иконка (BGRA) из первого рабочего источника; $null - не удалось
function Get-AutoSourceImage {
    param($Sources)
    foreach ($s in @($Sources)) {
        try {
            $w = 0; $h = 0
            $px = if ($s.Kind -eq 'shell') { [GlyphixAuto.AutoShell]::ExtractShell([string]$s.Path, 256, [ref]$w, [ref]$h) } else { [GlyphixAuto.AutoShell]::ExtractFile([string]$s.Path, [ref]$w, [ref]$h) }
            if ($px -and [GlyphixAuto.AutoStyle]::HasContent($px)) {
                return [pscustomobject]@{ Pixels = $px; W = [int]$w; H = [int]$h; Source = [string]$s.Path; Hash = ((Get-BytesSha256 $px) + ':' + $w + 'x' + $h) }
            }
        } catch { Write-Log ('  иконка не прочитана (' + $s.Path + '): ' + $_.Exception.Message) }
    }
    return $null
}

# ---------- генерация файлов ----------
# .ico (кадры PNG 16..128) + превью .png для ярлыка. 'cached' - файлы актуальны (тот же ключ), 'generated' - пересозданы. Ошибка - исключение.
function New-AutoLinkFiles {
    param($Item, $Auto, [string]$PackId, $Backup, $Variant = $null)
    [void](Initialize-AutoNative)
    $pp = Get-AutoPaths $PackId ([string]$Item.SafeKey)
    $img = Get-AutoSourceImage (Get-AutoLinkSources $Item $Backup)
    if (-not $img) { throw 'не удалось получить иконку приложения' }
    $vk = Get-AutoVariantKey $Variant
    $ck = Get-AutoCacheKey 'ico' $img.Hash ([string]$Auto.Sha) '' $vk
    if ((Test-AutoCache $pp.Ico $ck) -and (Test-Path -LiteralPath $pp.Png -PathType Leaf)) { return 'cached' }
    $st = [GlyphixAuto.AutoStyle]::Stylize($img.Pixels, $img.W, $img.H, (ConvertTo-AutoNativeParams $Auto), 256)
    $st = Invoke-AutoVariantOps $st $Variant $Auto 'icon'
    Save-FileAtomic $pp.Png ([GlyphixAuto.AutoStyle]::EncodePng($st, 256, 256))
    Save-FileAtomic $pp.Ico ([GlyphixAuto.AutoStyle]::MakeIco($st, 256, $script:SI_AutoIcoSizes))
    Save-AutoCacheKey $pp.Ico $ck
    return 'generated'
}

# плитка Start11 640x640 (.jpg): фон-градиент, рамка, иконка, подпись (без подписи при $NoName)
function New-AutoTileFile {
    param($Item, $Auto, [string]$PackId, [bool]$NoName = $false, $Variant = $null)
    [void](Initialize-AutoNative)
    $pp = Get-AutoPaths $PackId ([string]$Item.SafeKey)
    $img = Get-AutoSourceImage (Get-AutoTileSources $Item)
    if (-not $img) { throw 'не удалось получить иконку приложения' }
    $title = if ($NoName) { '' } else { [string]$Item.Name }
    $vk = Get-AutoVariantKey $Variant
    $ck = Get-AutoCacheKey 'tile' $img.Hash ([string]$Auto.Sha) $title $vk
    if (Test-AutoCache $pp.Tile $ck) { return 'cached' }
    $cv = [int]$script:SI_AutoTileIcon
    $st = [GlyphixAuto.AutoStyle]::Stylize($img.Pixels, $img.W, $img.H, (ConvertTo-AutoNativeParams $Auto), $cv)
    if ($vk) {           # вариант с операциями: плитка с качеством 100, операции для плиток, и итоговое сохранение с качеством 92 (см. Invoke-AutoVariantTile)
        $jpg = [GlyphixAuto.AutoShell]::RenderTile($st, $cv, $cv, $title, (ConvertTo-AutoRgb $Auto.Bg0), (ConvertTo-AutoRgb $Auto.Bg1), (ConvertTo-AutoRgb $Auto.Border), (ConvertTo-AutoRgb $Auto.Title), $script:SI_AutoTileSize, 100)
        $jpg = Invoke-AutoVariantTile $jpg $Variant $Auto
    } else {
        $jpg = [GlyphixAuto.AutoShell]::RenderTile($st, $cv, $cv, $title, (ConvertTo-AutoRgb $Auto.Bg0), (ConvertTo-AutoRgb $Auto.Bg1), (ConvertTo-AutoRgb $Auto.Border), (ConvertTo-AutoRgb $Auto.Title), $script:SI_AutoTileSize, 92)
    }
    Save-FileAtomic $pp.Tile $jpg
    Save-AutoCacheKey $pp.Tile $ck
    return 'generated'
}

# файлы для одного элемента (ярлык или плитка); для превью в GUI и перед применением
function New-AutoFiles {
    param($Item, $Auto, [string]$PackId, $Backup, [bool]$NoName = $false, $Variant = $null)
    if ($Item.PSObject.Properties['TileId']) { return (New-AutoTileFile $Item $Auto $PackId $NoName $Variant) }
    return (New-AutoLinkFiles $Item $Auto $PackId $Backup $Variant)
}

# папка auto\ целиком (только внутри папки данных); вызывается после полного отката и при удалении приложения
function Remove-AutoFiles {
    try {
        if (-not (Test-Path -LiteralPath $script:SI_AutoDir)) { return }
        if (-not (Test-PathUnder ([IO.Path]::GetFullPath($script:SI_AutoDir)) ([IO.Path]::GetFullPath($script:SI_Home)))) { return }
        if (([IO.File]::GetAttributes($script:SI_AutoDir) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return }
        [void](Remove-TreeSafe $script:SI_AutoDir $script:SI_Home)       # без захода в ссылки
    } catch { Write-Log ('auto не удалена: ' + $_.Exception.Message) }
}

# перед применением плиток: режимы приложений -> готовые .jpg; возвращает @{ Items = что применять; Failed = сколько не получилось; Skipped = Native/Off }
function Resolve-AutoTileItems {
    param($Pack, $Items, [bool]$NoName)
    $keep = [System.Collections.Generic.List[object]]::new()
    $failed = 0; $skipped = 0
    $auto = $null; $ov = $null; $ready = $false; $tried = $false
    foreach ($m in @($Items)) {
        if (-not (Test-AutoItem $m)) { $keep.Add($m); continue }
        if (-not $m.PSObject.Properties['ModeSet']) {            # элементы плана (ModeSet) уже прошли через режимы приложений
            if ($null -eq $ov) { $ov = Get-AutoOverrides }
            if ((Get-AutoMode ([string]$m.AutoKey) $ov) -ne 'Auto') { $skipped++; continue }
        }
        if (-not $tried) {
            $tried = $true
            $auto = Get-PackAuto $Pack
            if ($auto) { try { $ready = Initialize-AutoNative } catch { Write-Log ('Автоиконки: ' + $_.Exception.Message) } }
        }
        if (-not $ready) { $skipped++; continue }
        try { [void](New-AutoTileFile $m $auto ([string]$Pack.Id) $NoName $Pack); $keep.Add($m) }
        catch { $failed++; Write-Log "  автоплитка $($m.Name): $($_.Exception.Message)" }
    }
    return [pscustomobject]@{ Items = $keep.ToArray(); Failed = $failed; Skipped = $skipped }
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
        if ($pendingCommon -eq 0) { Write-Log 'Бэкапа нет - восстанавливать нечего.'; if (-not $CommonOnly) { Clear-AppIconState } }
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
    if ($st.ContainsKey('Applied') -and $failed -eq 0 -and $pendingCommon -eq 0 -and -not $CommonOnly) { $st.Remove('Applied'); [void]$st.Remove('AppIcon'); Save-State $st }
    $tail = if ($failed -gt 0) { ", не удалось: $failed (для общих ярлыков отметьте «Также общие ярлыки» - нужны права администратора)" } else { '' }
    Write-Log "Восстановлено: $n$tail"
    if ($failed -eq 0 -and -not $CommonOnly) { Invoke-LegacyCleanup }
    if ($failed -eq 0 -and -not $CommonOnly -and $pendingCommon -eq 0 -and $backup.Count -eq 0) { Remove-AutoFiles; Remove-AppliedFiles -KeepReferenced }      # всё возвращено - созданные автоиконки и копии применённых иконок больше не нужны (копии, на которые ещё смотрит ярлык без записи в бэкапе, остаются)
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
    $removed = [System.Collections.Generic.List[string]]::new()
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

# Прочитать AppUserModelID ярлыка: { Ok = прочитали ли; Id = значение ('' - не задан) }; исключений не бросает
function Get-ShortcutAppId {
    param([string]$Path)
    try {
        if (-not ('GlyphixNative.ShortcutAppId' -as [type])) { Add-Type -TypeDefinition $script:SI_AumidCode -Language CSharp }
        return [pscustomobject]@{ Ok = $true; Id = [string][GlyphixNative.ShortcutAppId]::Get($Path) }
    } catch { return [pscustomobject]@{ Ok = $false; Id = '' } }
}

# Прежние версии не всегда ставили AppUserModelID на ярлык «Glyphix» (из-за этого Start11 не показывал плитку Glyphix). При запуске окна: если свой ярлык
# (меню «Пуск» / рабочий стол) есть, а ID на нём нет или другой - один раз тихо пересоздаём ярлыки (Install-AppShortcuts -OnlyExisting) и пишем одну строку в журнал.
# Проверка (она компилирует C#) - один раз на версию приложения: результат в state.json (AumidChecked). Возвращает $true, если ярлыки пересоздавали.
function Repair-AppShortcutAppId {
    try {
        $ver = Get-AppVersion
        $st = Read-State
        if ($st.ContainsKey('AumidChecked') -and [string]$st['AumidChecked'] -eq $ver) { return $false }
        $bad = [System.Collections.Generic.List[string]]::new()
        foreach ($p in @(Get-AppShortcutPaths)) {
            if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
            $r = Get-ShortcutAppId $p
            if ($r.Ok -and $r.Id -ne [string]$script:SI_AppId) { $bad.Add($p) }
        }
        $st['AumidChecked'] = $ver; Save-State $st
        if ($bad.Count -eq 0) { return $false }
        Write-Log ('Ярлык Glyphix без AppUserModelID ' + $script:SI_AppId + ' (' + ($bad -join '; ') + ') - пересоздаю ярлыки')
        Install-AppShortcuts -OnlyExisting
        return $true
    } catch { Write-Log ('Проверка AppUserModelID ярлыка не выполнена: ' + $_.Exception.Message); return $false }
}

function Install-AppShortcuts {
    param([switch]$OnlyExisting)       # только уже существующие ярлыки (не воскрешать ярлык, который пользователь убрал)
    $wsh = Get-WshShell
    $vbs = Join-Path $script:SI_AppDir 'launch.vbs'
    $ico = Join-Path (Join-Path $script:SI_AppDir 'assets') 'app.ico'
    foreach ($p in (Get-AppShortcutPaths)) {
        if ($OnlyExisting -and -not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        try {
            $d = [IO.Path]::GetDirectoryName($p)
            if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            $sc = $wsh.CreateShortcut($p)
            $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
            $sc.Arguments = '"' + $vbs + '"'
            $sc.WorkingDirectory = $script:SI_Home      # не app\: рабочая папка запущенного процесса мешала бы заменить app\ при обновлении
            $sc.IconLocation = "$ico,0"
            $sc.Description = 'Glyphix'
            $sc.Save()
            [void](Set-ShortcutAppId -Path $p)
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
    $rel = Get-HomeRelation $old $new
    if ($rel -eq 'equal') { return 'та же папка' }
    if ($rel -ne 'separate') { return 'папки вложены друг в друга' }
    if (Test-Path -LiteralPath (Join-Path $new 'migrated.json')) { return 'уже перенесено' }
    return ''
}

# $true - метки нет, а бэкап прежней версии (backup\ или backup.migrating\) ещё лежит в прежней папке: перенос не завершён.
# Пока так, применять пак нельзя: исходные иконки уже заменены, и новый бэкап записал бы в «оригиналы» иконки пака.
function Test-LegacyMigrationIncomplete {
    $old = [string]$script:SI_OldHome
    $new = [string]$script:SI_Home
    if (-not $old -or -not (Test-Path -LiteralPath $old -PathType Container)) { return $false }
    if ((Get-HomeRelation $old $new) -ne 'separate') { return $false }
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
    $out = [System.Collections.Generic.List[object]]::new()
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
    $created = [System.Collections.Generic.List[string]]::new()
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
    if ((Get-HomeRelation $old $new) -ne 'separate') {
        Write-Log "Отказ: прежняя и новая папки данных совпадают или вложены друг в друга ($old | $new) - ничего не переношу и не удаляю"
        $res.Reason = 'папки совпадают или вложены'
        return $res
    }

    Write-Log "Переношу данные прежней версии: $old"
    $oldBackup = Join-Path $old 'backup'
    $oldMig = Join-Path $old 'backup.migrating'      # старый backup\ после переименования: замок и метка «перенос идёт» (найден при запуске - продолжаем с него)
    $oldS11 = Join-Path $old 'start11'
    $retry = $false          # true - не перенесён бэкап: метку не ставим, перенос повторится при следующем запуске (идемпотентно)

    # 0) старый backup\ -> backup.migrating\ одним переименованием (атомарно); дальше работаем только с ним
    $sources = [System.Collections.Generic.List[object]]::new()
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
        $rew = [System.Collections.Generic.List[object]]::new()
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
            if ($canDelete -and -not (Test-SafeOldHomeDelete $oldS11)) { $canDelete = $false; Write-Log '  PNG плиток в прежней папке оставлены (путь не прошёл проверку безопасного удаления)' }
            if ($canDelete) { Remove-OldTree $oldS11 }
            else { Write-Log '  PNG плиток в прежней папке оставлены (Start11 не перезапущен или значения не переписаны)' }
        }
    } catch { $res.Failed++; Write-Log ('  плитки Start11 не перенесены: ' + $_.Exception.Message) }     # старые PNG остаются на месте: значения реестра, которые не переписали, продолжают работать

    # 4) бэкап: слияние с бэкапом Glyphix (старые записи главнее); backup.migrating\ удаляем после успеха - отдельным try, который только пишет в журнал
    foreach ($s in $sources) {
        $merged = $false
        try { $res.Backup += (Merge-LegacyBackup $s.Dir $oldBackup $oldS11 $s.OldFirst); $merged = $true }
        catch { $res.Failed++; $retry = $true; Write-Log ('  бэкап не перенесён: ' + $_.Exception.Message) }      # повтор продолжит с backup.migrating
        if (-not $merged) { break }
        try {
            if (-not (Test-SafeOldHomeDelete $s.Dir)) { throw 'путь вне прежней папки или внутри новой - не удаляю' }
            Remove-OldTree $s.Dir
        }
        catch { Write-Log ('  старый бэкап не удалён (он уже перенесён, остаток можно удалить вручную): ' + $s.Dir + ' - ' + $_.Exception.Message) }
    }

    # 5) журнал: старый - перед новым
    try {
        foreach ($ln in @('log.txt.old', 'log.txt')) {
            $ol = Join-Path $old $ln
            if (-not (Test-Path -LiteralPath $ol -PathType Leaf)) { continue }
            $nl = Join-Path $new $ln
            if ($ln -eq 'log.txt' -and (Test-Path -LiteralPath $nl)) {
                Save-FileAtomic $nl ([System.Text.UTF8Encoding]::new($false).GetBytes([IO.File]::ReadAllText($ol) + [IO.File]::ReadAllText($nl)))
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
                $cd = Get-NormalPath $cd
                if ($cd -and (($cd -ieq (Get-NormalPath $oa)) -or (Test-PathUnder $cd (Get-NormalPath $oa)))) { Write-Log '  прежняя папка app используется сейчас - не удаляю' }
                elseif (-not (Test-SafeOldHomeDelete $oa)) { Write-Log '  прежняя папка app не удалена: путь не прошёл проверку безопасного удаления' }
                else { Remove-OldTree $oa; Write-Log '  удалена прежняя папка app' }
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
        $script:SI_LnkReadFails = 0
        foreach ($s in @(Get-ReferenceLinks)) {
            $loc = Split-IconLocation ([string]$s.Icon)
            $p = [Environment]::ExpandEnvironmentVariables($loc.Path.Trim('"'))
            if ($p -and (Test-PathUnder $p $old)) { return $true }
        }
        if ($script:SI_LnkReadFails -gt 0) { return $true }
    } catch { return $true }          # не смогли проверить - считаем, что ссылки есть
    return $false
}

# пустые подпапки внутри $Root (сам $Root не трогаем); в ссылки/junction не заходим
function Remove-EmptyDirs {
    param([string]$Root)
    # обход вручную: Get-ChildItem -Recurse в Windows PowerShell 5.1 заходит в junction/symlink, поэтому ссылки (ReparsePoint) пропускаем целиком
    foreach ($d in @(Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        Remove-EmptyDirs $d.FullName
        try { if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -Confirm:$false } } catch { }
    }
}

# Удалить из прежней папки данных packs\ и icons\ (и остатки v2: Set-TaskbarIcons.ps1, log.txt, run-hidden.vbs, пустые папки), когда на неё больше не ссылается ни один ярлык;
# саму папку - если она опустела. Пока бэкап не перенесён (нет метки, а backup\ на месте) - ничего не трогаем.
# Папка прежней версии (внутри $script:SI_OldHome) целиком, без захода в junction/symlink (Remove-TreeSafe); не вышло полностью - исключение (вызывающий пишет в журнал)
function Remove-OldTree {
    param([string]$Path)
    $root = [string]$script:SI_OldHome
    $r = Remove-TreeSafe $Path $root
    if (Test-Path -LiteralPath $Path) { throw ('осталось элементов: ' + [Math]::Max(1, [int]$r.Left) + ' (ссылки / занятые файлы)') }
}

function Remove-LegacyHomeIfUnused {
    $old = [string]$script:SI_OldHome
    if (-not $old -or -not (Test-Path -LiteralPath $old -PathType Container)) { return $false }
    if ((Get-HomeRelation $old ([string]$script:SI_Home)) -ne 'separate') { return $false }
    if (Test-LegacyMigrationIncomplete) { return $false }
    if (Test-LegacyHomeReferenced) { return $false }
    $subs = @('packs', 'icons')
    if (Test-Path -LiteralPath (Join-Path ([string]$script:SI_Home) 'migrated.json')) { $subs += 'backup.migrating' }       # остаток уже перенесённого бэкапа
    foreach ($sub in $subs) {
        $d = Join-Path $old $sub
        try { if ((Test-Path -LiteralPath $d) -and (Test-SafeOldHomeDelete $d)) { Remove-OldTree $d; Write-Log "Удалена прежняя папка: $d" } } catch { Write-Log "Не удалена $d : $($_.Exception.Message)" }
    }
    foreach ($fn in @('Set-TaskbarIcons.ps1', 'log.txt', 'log.txt.old', 'run-hidden.vbs')) {
        $f = Join-Path $old $fn
        try { if (Test-Path -LiteralPath $f -PathType Leaf) { Remove-Item -LiteralPath $f -Force; Write-Log "Удалён остаток прежней версии: $f" } } catch { Write-Log "Не удалён $f : $($_.Exception.Message)" }
    }
    try { Remove-EmptyDirs $old } catch { }
    try { if (-not (Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $old -Recurse -Force -Confirm:$false } } catch { }
    return $true
}

function Invoke-LegacyCleanup {
    try { [void](Remove-LegacyHomeIfUnused) } catch { Write-Log ('Прежняя папка данных: ' + $_.Exception.Message) }
}

# Текст помощника удаления: ждёт завершения процесса $WaitPid (GUI/CLI, из чьих файлов он запущен), затем удаляет папку приложения
# (повторы - файлы могут ещё секунду быть заняты) и саму папку данных, если она опустела. Ничего другого не трогает.
function New-UninstallHelperScript {
    param([int]$WaitPid, [string]$AppDir, [string]$HomeDir, [string[]]$ExtraFiles = @())
    $qa = $AppDir.Replace("'", "''")
    $qh = $HomeDir.Replace("'", "''")
    $lines = @(
        '$ErrorActionPreference = ''SilentlyContinue''',
        ('$wp = ' + [int]$WaitPid),
        ('$app = ''' + $qa + ''''),
        ('$home1 = ''' + $qh + ''''),
        '$dl = (Get-Date).AddSeconds(120)',
        'while ((Get-Date) -lt $dl -and (Get-Process -Id $wp -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 300 }',
        '# удаление дерева без захода в junction/symlink (в Windows PowerShell 5.1 Remove-Item -Recurse в них заходит); ссылки остаются на месте',
        'function Remove-TreeNoLinks([string]$p) {',
        '    foreach ($c in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)) {',
        '        if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }',
        '        if ($c.PSIsContainer) { Remove-TreeNoLinks $c.FullName } else { Remove-Item -LiteralPath $c.FullName -Force -Confirm:$false -ErrorAction SilentlyContinue }',
        '    }',
        '    if (-not (Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $p -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }',
        '}',
        'for ($i = 0; $i -lt 40; $i++) {',
        '    if (-not (Test-Path -LiteralPath $app)) { break }',
        '    if (-not ((Get-Item -LiteralPath $app -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { Remove-TreeNoLinks $app }',
        '    if (-not (Test-Path -LiteralPath $app)) { break }',
        '    Start-Sleep -Milliseconds 500',
        '}',
        '# файлы, которые были заняты при удалении (например, GlyphixSetup.exe)',
        '$extra = @(' + ((@($ExtraFiles | Where-Object { $_ } | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" })) -join ', ') + ')',
        'foreach ($x in $extra) { for ($i = 0; $i -lt 40; $i++) { if (-not (Test-Path -LiteralPath $x)) { break }; Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath $x)) { break }; Start-Sleep -Milliseconds 500 } }',
        '# пустые подпапки (backup\ и т.п.), затем сама папка данных, если опустела',
        'if (Test-Path -LiteralPath $home1) {',
        '    function Remove-EmptySub([string]$r) {',
        '        foreach ($d in @(Get-ChildItem -LiteralPath $r -Directory -Force -ErrorAction SilentlyContinue)) {',
        '            if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }',
        '            Remove-EmptySub $d.FullName',
        '            if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $d.FullName -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }',
        '        }',
        '    }',
        '    Remove-EmptySub $home1',
        '    if (-not (Get-ChildItem -LiteralPath $home1 -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $home1 -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue }',
        '}'
    )
    return ($lines -join "`r`n")
}

# запустить помощника отдельным скрытым powershell.exe; бросает исключение, если не запустился
function Start-UninstallHelper {
    param([string]$AppDir, [string]$HomeDir, [int]$WaitPid = $PID, [string]$WorkDir = '', [string[]]$ExtraFiles = @())
    if (-not $WorkDir) { $WorkDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() } }
    if (-not (Test-PathUnder (Get-NormalPath $AppDir) (Get-NormalPath $HomeDir))) { throw 'папка приложения не внутри папки данных - помощник не запускаю' }
    $code = New-UninstallHelperScript -WaitPid $WaitPid -AppDir $AppDir -HomeDir $HomeDir -ExtraFiles $ExtraFiles
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $enc) -WindowStyle Hidden -WorkingDirectory $WorkDir
}

# След установщика GlyphixSetup.exe: запись «Приложения и возможности» (HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Glyphix) и его копия
# %LOCALAPPDATA%\Glyphix\GlyphixSetup.exe (имена - как в GlyphixSetup.cs: UninstallKey, InstalledSetupPath). Ключ удаляем только свой, файл - только внутри папки данных.
$script:SI_UninstallKeyPath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\Glyphix'
function Remove-AppUninstallEntry {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:SI_UninstallKeyPath, $false)
}
# Возвращает { Key (удалён/нет); File (удалён/нет/не было); Locked (путь файла, если занят) }
function Remove-InstallerTraces {
    $r = [pscustomobject]@{ Key = $false; File = $false; Locked = '' }
    try { Remove-AppUninstallEntry; $r.Key = $true; Write-Log 'Удалена запись «Приложения и возможности» (Uninstall\Glyphix)' } catch { Write-Log ('Запись Uninstall\Glyphix не удалена: ' + $_.Exception.Message) }
    try {
        $f = Join-Path $script:SI_Home 'GlyphixSetup.exe'
        if (Test-Path -LiteralPath $f -PathType Leaf) {
            if (-not (Test-PathUnder (Get-NormalPath $f) (Get-NormalPath $script:SI_Home))) { return $r }
            if (Test-IsReparse (Get-Item -LiteralPath $f -Force)) { return $r }
            try { Remove-Item -LiteralPath $f -Force -ErrorAction Stop; $r.File = $true; Write-Log 'Удалён GlyphixSetup.exe' }
            catch { $r.Locked = $f; Write-Log ('GlyphixSetup.exe занят - удалю после выхода: ' + $_.Exception.Message) }
        } else { $r.File = $true }
    } catch { Write-Log ('GlyphixSetup.exe не удалён: ' + $_.Exception.Message) }
    return $r
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
    Remove-AutoFiles                     # созданные автоиконки (откат уже вернул все ярлыки)
    Remove-AppliedFiles                  # копии применённых иконок (applied\)
    foreach ($vd in @($script:SI_VariantsDir, $script:SI_CatalogDir)) {      # 3.0: кэш отрисованных вариантов (variants\) и каталог с превью (catalog\)
        try { if ($vd -and (Test-Path -LiteralPath $vd -PathType Container)) { [void](Remove-TreeSafe $vd $script:SI_Home) } } catch { Write-Log ('не удалено: ' + $vd) }
    }
    Write-LegacyCommonIconsNote          # папка %ProgramData%\Glyphix от 2.4.1 (если есть) - только запись в журнал, не трогаем
    # не держим папку приложения/данных текущей: иначе её не удалить
    $tmpDir = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    try { [Environment]::CurrentDirectory = $tmpDir } catch { }
    try { Set-Location -LiteralPath $tmpDir } catch { }
    [void](Remove-Legacy)
    foreach ($p in @(Get-AppShortcutPaths) + @(Get-LegacyShortcutPaths)) {
        try { if ($p -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force; Write-Log "Удалён ярлык: $p" } } catch { Write-Log "Ярлык не удалён: $p" }
    }
    $inst = Remove-InstallerTraces       # запись в «Приложениях и возможностях» и GlyphixSetup.exe (если приложение ставил установщик)
    Invoke-LegacyCleanup                 # откат выполнен: прежняя папка данных (packs\, icons\) больше не нужна
    try { if (Test-Path -LiteralPath $script:SI_StateFile) { Remove-Item -LiteralPath $script:SI_StateFile -Force } } catch { }
    try { $mg = Join-Path $script:SI_Home 'migrated.json'; if (Test-Path -LiteralPath $mg) { Remove-Item -LiteralPath $mg -Force } } catch { }
    try { if (Test-Path -LiteralPath $script:SI_PacksDir) { [void](Remove-TreeSafe $script:SI_PacksDir $script:SI_Home) } } catch { Write-Log "packs не удалён: $($_.Exception.Message)" }      # без захода в ссылки
    $appRemoved = $true
    $helperStarted = $false
    $extra = @(); if ($inst -and $inst.Locked) { $extra = @([string]$inst.Locked) }
    try {
        if (Test-Path -LiteralPath $script:SI_AppDir) {
            [void](Remove-TreeSafe $script:SI_AppDir $script:SI_Home)      # без захода в ссылки
            if (Test-Path -LiteralPath $script:SI_AppDir) { throw 'часть файлов приложения занята' }
        }
    } catch {
        $appRemoved = $false
        try {   # файлы заняты (мы из них запущены) - дочищаем после завершения процесса
            Start-UninstallHelper -AppDir $script:SI_AppDir -HomeDir $script:SI_Home -WaitPid $PID -WorkDir $tmpDir -ExtraFiles $extra
            $appRemoved = $true; $helperStarted = $true
        } catch { Write-Log "Папка приложения не удалена: $($_.Exception.Message)" }
    }
    if ($extra.Count -gt 0 -and -not $helperStarted) { try { Start-UninstallHelper -AppDir $script:SI_AppDir -HomeDir $script:SI_Home -WaitPid $PID -WorkDir $tmpDir -ExtraFiles $extra } catch { Write-Log "GlyphixSetup.exe не удалён: $($_.Exception.Message)" } }
    Write-Log 'Приложение удалено.'
    $script:SI_NoLogFile = $true
    try { if (Test-Path -LiteralPath $script:SI_LogFile) { Remove-Item -LiteralPath $script:SI_LogFile -Force } } catch { }
    try { if (Test-Path -LiteralPath ($script:SI_LogFile + '.old')) { Remove-Item -LiteralPath ($script:SI_LogFile + '.old') -Force } } catch { }
    try { if (Test-Path -LiteralPath $script:SI_Home -PathType Container) { Remove-EmptyDirs $script:SI_Home } } catch { }      # пустые backup\ и т.п.
    try { if ((Test-Path -LiteralPath $script:SI_Home) -and -not (Get-ChildItem -LiteralPath $script:SI_Home -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $script:SI_Home -Recurse -Force -Confirm:$false } } catch { }
    return [pscustomobject]@{ Ok = $appRemoved; KeptBackup = $false; Aborted = $false; Message = '' }
}

# =====================================================================================================================================
# ======================================================  GLYPHIX 3.0  ================================================================
# =====================================================================================================================================
# Цветовые варианты, план по приложениям, режимы, частичный откат, избранное, плитки из закреплённых элементов Start11.
# Описание API: docs/engine_api_3.md. Спецификация операций: docs/variants_spec.md (эталон gen/variants.py).

# ---------- Перекраска (C#): GlyphixVariants ----------
# Чистое ядро (байты RGBA, без System.Drawing/WPF - компилируется и проверяется на Linux): операции variants.json, PNG (чтение/запись), ICO, уменьшение,
# параллельная пакетная отрисовка. Слой кодеков JPEG: на Windows - GDI+ (System.Drawing), в тестах на Linux - заглушка (JPEG недоступен).
# C# 5 / .NET 4.x: без интерполяции строк, ?., expression-bodied членов, out var.
$script:SI_VariantsCoreCode = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Threading;

namespace GlyphixVariants
{
    // Одна операция каталога. Name: gradient_map | brand_map | hue_rotate | saturate | brightness | contrast | gamma | mix | colorize | alpha.
    // Цвета - 0xRRGGBB, -1 в StopRgb = "{brand}".
    public sealed class Op
    {
        public string Name;
        public int Target;                         // 0 - иконки и плитки, 1 - только иконки, 2 - только плитки
        public double[] StopPos;
        public int[] StopRgb;
        public double Strength = 1.0;
        public bool SourceMax;
        public double Deg;
        public double K;
        public double G = 1.0;
        public int Color;
        public bool ColorBrand;
        public double MinL = double.NaN;
        public double MaxL = double.NaN;
        public double Scale = 1.0;
        public double Lo = 0.0;
        public double Hi = 1.0;
        public double A0 = 1.0;
        public double A1 = 1.0;
        public double Gain = 1.5;
        public bool KeepV;
    }

    public static class Recolor
    {
        // rnd(x) = clamp(floor(x + 0.5), 0, 255)
        public static int Rnd(double x)
        {
            if (double.IsNaN(x)) return 0;
            double v = Math.Floor(x + 0.5);
            if (v < 0.0) return 0;
            if (v > 255.0) return 255;
            return (int)v;
        }

        public static int LumIndex(int r, int g, int b)
        {
            return (2126 * r + 7152 * g + 722 * b + 5000) / 10000;
        }

        // Зажим светлоты цвета бренда (0xRRGGBB -> 0xRRGGBB); NaN в minL / maxL = параметр не задан.
        public static int ClampBrand(int rgb, double minL, double maxL)
        {
            double r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
            double L = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255.0;
            if (!double.IsNaN(minL) && L < minL)
            {
                double t = (minL - L) / (1.0 - L);
                r = r + (255.0 - r) * t; g = g + (255.0 - g) * t; b = b + (255.0 - b) * t;
            }
            else if (!double.IsNaN(maxL) && L > maxL)
            {
                double f = maxL / L;
                r = r * f; g = g * f; b = b * f;
            }
            return (Rnd(r) << 16) | (Rnd(g) << 8) | Rnd(b);
        }

        // LUT 256 x RGB (768 байт) по точкам градиента; brandRgb - уже зажатый цвет для точек "{brand}"
        public static byte[] BuildLut(double[] pos, int[] rgb, int brandRgb)
        {
            int n = pos.Length;
            double[] cr = new double[n], cg = new double[n], cb = new double[n];
            for (int i = 0; i < n; i++)
            {
                int c = rgb[i];
                if (c < 0)
                {
                    if (brandRgb < 0) throw new InvalidOperationException("brand_map: нужен цвет бренда");
                    c = brandRgb;
                }
                cr[i] = (c >> 16) & 255; cg[i] = (c >> 8) & 255; cb[i] = c & 255;
            }
            byte[] lut = new byte[768];
            for (int i = 0; i < 256; i++)
            {
                double t = i / 255.0;
                double r, g, b;
                if (t <= pos[0]) { r = cr[0]; g = cg[0]; b = cb[0]; }
                else if (t >= pos[n - 1]) { r = cr[n - 1]; g = cg[n - 1]; b = cb[n - 1]; }
                else
                {
                    r = cr[n - 1]; g = cg[n - 1]; b = cb[n - 1];
                    for (int k = 0; k < n - 1; k++)
                    {
                        double p0 = pos[k], p1 = pos[k + 1];
                        if (p0 <= t && t <= p1)
                        {
                            double u = (p1 == p0) ? 0.0 : (t - p0) / (p1 - p0);
                            r = cr[k] + (cr[k + 1] - cr[k]) * u;
                            g = cg[k] + (cg[k + 1] - cg[k]) * u;
                            b = cb[k] + (cb[k + 1] - cb[k]) * u;
                            break;
                        }
                    }
                }
                lut[i * 3] = (byte)Rnd(r); lut[i * 3 + 1] = (byte)Rnd(g); lut[i * 3 + 2] = (byte)Rnd(b);
            }
            return lut;
        }

        static int BrandFor(Op op, int brand)
        {
            if (brand < 0) throw new InvalidOperationException("операция " + op.Name + " с {brand}: нужен цвет бренда");
            return ClampBrand(brand, op.MinL, op.MaxL);
        }

        static void Matrix(byte[] p, double[] m)
        {
            for (int i = 0; i + 3 < p.Length; i += 4)
            {
                double r = p[i], g = p[i + 1], b = p[i + 2];
                p[i] = (byte)Rnd(r * m[0] + g * m[1] + b * m[2]);
                p[i + 1] = (byte)Rnd(r * m[3] + g * m[4] + b * m[5]);
                p[i + 2] = (byte)Rnd(r * m[6] + g * m[7] + b * m[8]);
            }
        }

        static void ApplyOne(byte[] p, Op op, int brand)
        {
            int n = p.Length;
            switch (op.Name)
            {
                case "gradient_map":
                case "brand_map":
                {
                    bool needBrand = false;
                    for (int i = 0; i < op.StopRgb.Length; i++) { if (op.StopRgb[i] < 0) needBrand = true; }
                    int bc = needBrand ? BrandFor(op, brand) : -1;
                    byte[] lut = BuildLut(op.StopPos, op.StopRgb, bc);
                    double s = op.Strength;
                    for (int i = 0; i + 3 < n; i += 4)
                    {
                        int idx = op.SourceMax ? Math.Max(p[i], Math.Max(p[i + 1], p[i + 2])) : LumIndex(p[i], p[i + 1], p[i + 2]);
                        for (int c = 0; c < 3; c++)
                        {
                            double src = p[i + c];
                            double m = lut[idx * 3 + c];
                            p[i + c] = (byte)Rnd(src + (m - src) * s);
                        }
                    }
                    break;
                }
                case "hue_rotate":
                {
                    double a = op.Deg * Math.PI / 180.0;
                    double c = Math.Cos(a), s = Math.Sin(a);
                    double[] m = new double[] {
                        0.213 + c * 0.787 - s * 0.213, 0.715 - c * 0.715 - s * 0.715, 0.072 - c * 0.072 + s * 0.928,
                        0.213 - c * 0.213 + s * 0.143, 0.715 + c * 0.285 + s * 0.140, 0.072 - c * 0.072 - s * 0.283,
                        0.213 - c * 0.213 - s * 0.787, 0.715 - c * 0.715 + s * 0.715, 0.072 + c * 0.928 + s * 0.072 };
                    Matrix(p, m);
                    break;
                }
                case "saturate":
                {
                    double k = op.K;
                    double[] m = new double[] {
                        0.213 + 0.787 * k, 0.715 - 0.715 * k, 0.072 - 0.072 * k,
                        0.213 - 0.213 * k, 0.715 + 0.285 * k, 0.072 - 0.072 * k,
                        0.213 - 0.213 * k, 0.715 - 0.715 * k, 0.072 + 0.928 * k };
                    Matrix(p, m);
                    break;
                }
                case "brightness":
                    for (int i = 0; i + 3 < n; i += 4) { for (int c = 0; c < 3; c++) p[i + c] = (byte)Rnd(p[i + c] * op.K); }
                    break;
                case "contrast":
                    for (int i = 0; i + 3 < n; i += 4) { for (int c = 0; c < 3; c++) p[i + c] = (byte)Rnd((p[i + c] - 128.0) * op.K + 128.0); }
                    break;
                case "gamma":
                {
                    byte[] lut = new byte[256];
                    for (int i = 0; i < 256; i++) lut[i] = (byte)Rnd(255.0 * Math.Pow(i / 255.0, 1.0 / op.G));
                    for (int i = 0; i + 3 < n; i += 4) { p[i] = lut[p[i]]; p[i + 1] = lut[p[i + 1]]; p[i + 2] = lut[p[i + 2]]; }
                    break;
                }
                case "mix":
                {
                    int col = op.ColorBrand ? BrandFor(op, brand) : op.Color;
                    double cr = (col >> 16) & 255, cg = (col >> 8) & 255, cb = col & 255, k = op.K;
                    for (int i = 0; i + 3 < n; i += 4)
                    {
                        double r = p[i], g = p[i + 1], b = p[i + 2];
                        p[i] = (byte)Rnd(r + (cr - r) * k); p[i + 1] = (byte)Rnd(g + (cg - g) * k); p[i + 2] = (byte)Rnd(b + (cb - b) * k);
                    }
                    break;
                }
                case "colorize":
                {
                    int col = op.ColorBrand ? BrandFor(op, brand) : op.Color;
                    double tr = (col >> 16) & 255, tg = (col >> 8) & 255, tb = col & 255;
                    for (int i = 0; i + 3 < n; i += 4)
                    {
                        double r = p[i], g = p[i + 1], b = p[i + 2];
                        double mx = Math.Max(r, Math.Max(g, b)), mn = Math.Min(r, Math.Min(g, b));
                        double S = mx > 0 ? (mx - mn) / Math.Max(mx, 1.0) : 0.0;
                        double w = S * op.Gain;
                        if (w < 0.0) w = 0.0; else if (w > 1.0) w = 1.0;
                        double ur = tr, ug = tg, ub = tb;
                        if (op.KeepV) { double f = mx / 255.0; ur = tr * f; ug = tg * f; ub = tb * f; }
                        p[i] = (byte)Rnd(r * (1.0 - w) + ur * w);
                        p[i + 1] = (byte)Rnd(g * (1.0 - w) + ug * w);
                        p[i + 2] = (byte)Rnd(b * (1.0 - w) + ub * w);
                    }
                    break;
                }
                case "alpha":
                    for (int i = 0; i + 3 < n; i += 4)
                    {
                        double L = LumIndex(p[i], p[i + 1], p[i + 2]) / 255.0;
                        double t = (op.Hi == op.Lo) ? (L >= op.Hi ? 1.0 : 0.0) : (L - op.Lo) / (op.Hi - op.Lo);
                        if (t < 0.0) t = 0.0; else if (t > 1.0) t = 1.0;
                        double m = op.A0 + (op.A1 - op.A0) * t;
                        p[i + 3] = (byte)Rnd(p[i + 3] * op.Scale * m);
                    }
                    break;
                default:
                    throw new InvalidOperationException("неизвестная операция: " + op.Name);
            }
        }

        // Применить ops к RGBA (новый массив). tile = true: плитка (op с target "icons" пропускаются, в конце A = 255); иначе иконка (пропускаются "tiles").
        // brand - цвет бренда 0xRRGGBB или -1.
        public static byte[] Apply(byte[] rgba, Op[] ops, bool tile, int brand)
        {
            byte[] p = new byte[rgba.Length];
            Buffer.BlockCopy(rgba, 0, p, 0, rgba.Length);
            if (ops != null)
            {
                for (int i = 0; i < ops.Length; i++)
                {
                    Op op = ops[i];
                    if (op.Target == 1 && tile) continue;
                    if (op.Target == 2 && !tile) continue;
                    ApplyOne(p, op, brand);
                }
            }
            if (tile) { for (int i = 3; i < p.Length; i += 4) p[i] = 255; }
            return p;
        }

        public static byte[] SwapRB(byte[] px)
        {
            byte[] o = new byte[px.Length];
            for (int i = 0; i + 3 < px.Length; i += 4) { o[i] = px[i + 2]; o[i + 1] = px[i + 1]; o[i + 2] = px[i]; o[i + 3] = px[i + 3]; }
            return o;
        }
    }

    // ---------- PNG / ICO / уменьшение (чистый C#) ----------
    public static class Img
    {
        static uint[] crcTable;

        static uint Crc32(byte[] d, int off, int len, uint crc)
        {
            if (crcTable == null)
            {
                uint[] t = new uint[256];
                for (uint n = 0; n < 256; n++)
                {
                    uint c = n;
                    for (int k = 0; k < 8; k++) c = ((c & 1) != 0) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
                    t[n] = c;
                }
                crcTable = t;
            }
            crc = crc ^ 0xFFFFFFFFu;
            for (int i = 0; i < len; i++) crc = crcTable[(crc ^ d[off + i]) & 0xFF] ^ (crc >> 8);
            return crc ^ 0xFFFFFFFFu;
        }

        static void WriteBE(Stream s, uint v)
        {
            s.WriteByte((byte)(v >> 24)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)v);
        }

        static void Chunk(Stream s, string type, byte[] data)
        {
            WriteBE(s, (uint)data.Length);
            byte[] tb = new byte[4 + data.Length];
            for (int i = 0; i < 4; i++) tb[i] = (byte)type[i];
            Buffer.BlockCopy(data, 0, tb, 4, data.Length);
            s.Write(tb, 0, tb.Length);
            WriteBE(s, Crc32(tb, 0, tb.Length, 0));
        }

        static uint Adler32(byte[] d)
        {
            uint a = 1, b = 0;
            for (int i = 0; i < d.Length; i++) { a = (a + d[i]) % 65521u; b = (b + a) % 65521u; }
            return (b << 16) | a;
        }

        // RGBA -> PNG (RGBA 8 бит)
        public static byte[] EncodePng(byte[] rgba, int w, int h)
        {
            int stride = w * 4 + 1;
            byte[] raw = new byte[stride * h];
            for (int y = 0; y < h; y++)
            {
                raw[y * stride] = 0;
                Buffer.BlockCopy(rgba, y * w * 4, raw, y * stride + 1, w * 4);
            }
            MemoryStream z = new MemoryStream();
            z.WriteByte(0x78); z.WriteByte(0x9C);
            using (DeflateStream ds = new DeflateStream(z, CompressionMode.Compress, true)) { ds.Write(raw, 0, raw.Length); }
            WriteBE(z, Adler32(raw));
            MemoryStream ms = new MemoryStream();
            byte[] sig = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
            ms.Write(sig, 0, sig.Length);
            MemoryStream ih = new MemoryStream();
            WriteBE(ih, (uint)w); WriteBE(ih, (uint)h);
            ih.WriteByte(8); ih.WriteByte(6); ih.WriteByte(0); ih.WriteByte(0); ih.WriteByte(0);
            Chunk(ms, "IHDR", ih.ToArray());
            Chunk(ms, "IDAT", z.ToArray());
            Chunk(ms, "IEND", new byte[0]);
            return ms.ToArray();
        }

        static uint ReadBE(byte[] d, int o) { return ((uint)d[o] << 24) | ((uint)d[o + 1] << 16) | ((uint)d[o + 2] << 8) | d[o + 3]; }

        // PNG -> RGBA (без чересстрочности; 8 и 16 бит; типы 0, 2, 3, 4, 6). Не поддерживается / битый - null.
        public static byte[] DecodePng(byte[] d, out int w, out int h)
        {
            w = 0; h = 0;
            if (d == null || d.Length < 33 || d[0] != 137 || d[1] != 80 || d[2] != 78 || d[3] != 71) return null;
            int pos = 8, depth = 0, ctype = -1, interlace = 0;
            byte[] pal = null, trns = null;
            MemoryStream idat = new MemoryStream();
            while (pos + 8 <= d.Length)
            {
                long len = ReadBE(d, pos);
                string type = "" + (char)d[pos + 4] + (char)d[pos + 5] + (char)d[pos + 6] + (char)d[pos + 7];
                int dp = pos + 8;
                if (len < 0 || dp + len > d.Length) return null;
                if (type == "IHDR")
                {
                    if (len < 13) return null;
                    w = (int)ReadBE(d, dp); h = (int)ReadBE(d, dp + 4);
                    depth = d[dp + 8]; ctype = d[dp + 9]; interlace = d[dp + 12];
                }
                else if (type == "PLTE") { pal = new byte[len]; Buffer.BlockCopy(d, dp, pal, 0, (int)len); }
                else if (type == "tRNS") { trns = new byte[len]; Buffer.BlockCopy(d, dp, trns, 0, (int)len); }
                else if (type == "IDAT") { idat.Write(d, dp, (int)len); }
                else if (type == "IEND") break;
                pos = dp + (int)len + 4;
            }
            if (w < 1 || h < 1 || w > 16384 || h > 16384 || interlace != 0 || (depth != 8 && depth != 16)) return null;
            int ch;
            switch (ctype) { case 0: ch = 1; break; case 2: ch = 3; break; case 3: ch = 1; break; case 4: ch = 2; break; case 6: ch = 4; break; default: return null; }
            if (ctype == 3 && (depth != 8 || pal == null)) return null;
            int bps = depth / 8, bpp = ch * bps, rowLen = w * bpp;
            byte[] comp = idat.ToArray();
            if (comp.Length < 3) return null;
            byte[] raw = new byte[(rowLen + 1) * h];
            try
            {
                using (MemoryStream cs = new MemoryStream(comp, 2, comp.Length - 2))
                using (DeflateStream ds = new DeflateStream(cs, CompressionMode.Decompress))
                {
                    int got = 0;
                    while (got < raw.Length)
                    {
                        int r = ds.Read(raw, got, raw.Length - got);
                        if (r <= 0) break;
                        got += r;
                    }
                    if (got < raw.Length) return null;
                }
            }
            catch (Exception) { return null; }
            byte[] cur = new byte[rowLen], prev = new byte[rowLen];
            byte[] o = new byte[w * h * 4];
            for (int y = 0; y < h; y++)
            {
                int ro = y * (rowLen + 1);
                int ft = raw[ro];
                for (int x = 0; x < rowLen; x++)
                {
                    int v = raw[ro + 1 + x];
                    int a = x >= bpp ? cur[x - bpp] : 0, b = prev[x], c = x >= bpp ? prev[x - bpp] : 0;
                    switch (ft)
                    {
                        case 0: break;
                        case 1: v += a; break;
                        case 2: v += b; break;
                        case 3: v += (a + b) / 2; break;
                        case 4:
                        {
                            int pp = a + b - c, pa = Math.Abs(pp - a), pb = Math.Abs(pp - b), pc = Math.Abs(pp - c);
                            v += (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c);
                            break;
                        }
                        default: return null;
                    }
                    cur[x] = (byte)v;
                }
                for (int x = 0; x < w; x++)
                {
                    int si = x * bpp, di = (y * w + x) * 4;
                    byte r8, g8, b8, a8 = 255;
                    switch (ctype)
                    {
                        case 0: r8 = g8 = b8 = cur[si]; break;
                        case 2: r8 = cur[si]; g8 = cur[si + bps]; b8 = cur[si + 2 * bps]; break;
                        case 3:
                        {
                            int pi = cur[si];
                            if (pi * 3 + 2 >= pal.Length) return null;
                            r8 = pal[pi * 3]; g8 = pal[pi * 3 + 1]; b8 = pal[pi * 3 + 2];
                            if (trns != null && pi < trns.Length) a8 = trns[pi];
                            break;
                        }
                        case 4: r8 = g8 = b8 = cur[si]; a8 = cur[si + bps]; break;
                        default: r8 = cur[si]; g8 = cur[si + bps]; b8 = cur[si + 2 * bps]; a8 = cur[si + 3 * bps]; break;
                    }
                    o[di] = r8; o[di + 1] = g8; o[di + 2] = b8; o[di + 3] = a8;
                }
                byte[] t = prev; prev = cur; cur = t;
            }
            return o;
        }

        // Уменьшение/масштаб RGBA усреднением по площади (в предумноженном виде): для иконок 256 -> 48/32/24/16 без «лесенки»
        public static byte[] Resize(byte[] rgba, int w, int h, int nw, int nh)
        {
            byte[] o = new byte[nw * nh * 4];
            double sx = (double)w / nw, sy = (double)h / nh;
            for (int dy = 0; dy < nh; dy++)
            {
                double y0 = dy * sy, y1 = (dy + 1) * sy;
                int iy0 = (int)Math.Floor(y0), iy1 = Math.Min(h - 1, (int)Math.Ceiling(y1) - 1);
                for (int dx = 0; dx < nw; dx++)
                {
                    double x0 = dx * sx, x1 = (dx + 1) * sx;
                    int ix0 = (int)Math.Floor(x0), ix1 = Math.Min(w - 1, (int)Math.Ceiling(x1) - 1);
                    double sw = 0, sa = 0, sr = 0, sg = 0, sb = 0;
                    for (int y = iy0; y <= iy1; y++)
                    {
                        double wy = Math.Min(y + 1, y1) - Math.Max(y, y0);
                        if (wy <= 0) continue;
                        for (int x = ix0; x <= ix1; x++)
                        {
                            double wx = Math.Min(x + 1, x1) - Math.Max(x, x0);
                            if (wx <= 0) continue;
                            double wt = wx * wy;
                            int i = (y * w + x) * 4;
                            double a = rgba[i + 3] / 255.0;
                            sw += wt; sa += a * wt;
                            sr += rgba[i] * a * wt; sg += rgba[i + 1] * a * wt; sb += rgba[i + 2] * a * wt;
                        }
                    }
                    int di = (dy * nw + dx) * 4;
                    if (sw <= 0 || sa <= 0) continue;
                    o[di] = (byte)Recolor.Rnd(sr / sa); o[di + 1] = (byte)Recolor.Rnd(sg / sa); o[di + 2] = (byte)Recolor.Rnd(sb / sa);
                    o[di + 3] = (byte)Recolor.Rnd(sa / sw * 255.0);
                }
            }
            return o;
        }

        public static byte[] BuildIco(byte[][] pngs, int[] sizes)
        {
            int n = pngs.Length;
            MemoryStream ms = new MemoryStream();
            BinaryWriter bw = new BinaryWriter(ms);
            bw.Write((ushort)0); bw.Write((ushort)1); bw.Write((ushort)n);
            int offset = 6 + 16 * n;
            for (int i = 0; i < n; i++)
            {
                byte sz = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                bw.Write(sz); bw.Write(sz); bw.Write((byte)0); bw.Write((byte)0);
                bw.Write((ushort)1); bw.Write((ushort)32);
                bw.Write((uint)pngs[i].Length); bw.Write((uint)offset);
                offset += pngs[i].Length;
            }
            for (int i = 0; i < n; i++) bw.Write(pngs[i]);
            bw.Flush();
            return ms.ToArray();
        }

        // RGBA -> .ico (кадры PNG): главный кадр = размер исходника (не больше 256, без «раздувания»: у паков иконки 128 px) и уменьшенные 64, 48, 40, 32, 24, 20, 16
        // (усреднение по площади). Для исходника 256 px это 256 + 64/48/40/32/24/20/16.
        public static byte[] MakeIco(byte[] rgba, int w, int h)
        {
            int top = Math.Min(256, Math.Max(w, h));
            byte[] big = rgba;
            if (w != top || h != top) big = Resize(rgba, w, h, top, top);
            List<byte[]> frames = new List<byte[]>();
            List<int> szs = new List<int>();
            frames.Add(EncodePng(big, top, top)); szs.Add(top);
            foreach (int s in new int[] { 64, 48, 40, 32, 24, 20, 16 })
            {
                if (s >= top) continue;
                frames.Add(EncodePng(Resize(big, top, top, s, s), s, s)); szs.Add(s);
            }
            return BuildIco(frames.ToArray(), szs.ToArray());
        }

        // PNG или JPEG (по сигнатуре) -> RGBA; JPEG - через слой кодеков (только Windows)
        public static byte[] Decode(byte[] data, out int w, out int h)
        {
            w = 0; h = 0;
            if (data == null || data.Length < 4) throw new InvalidDataException("пустой файл");
            byte[] px = null;
            if (data[0] == 137 && data[1] == 80) px = DecodePng(data, out w, out h);
            if (px != null) return px;
            return Codec.Decode(data, out w, out h);
        }
    }

    // ---------- Пакетная отрисовка в несколько потоков ----------
    public sealed class Job
    {
        public string Kind;                // "icon" | "tile"
        public string Src;
        public string OutPng;              // icon: PNG 256 (необязательно)
        public string OutIco;              // icon: ICO (необязательно)
        public string OutTile;             // tile: .jpg / .jpeg (JPEG, качество 92) или .png
        public Op[] Ops;
        public int Brand = -1;
        public string Error;
    }

    public sealed class Batch
    {
        readonly Job[] jobs;
        readonly int threads;
        Thread[] ths;
        int next = -1, done = 0, failed = 0;
        volatile bool cancel = false;

        public Batch(Job[] jobs, int threads) { this.jobs = jobs; this.threads = Math.Max(1, threads); }
        public int Total { get { return jobs.Length; } }
        public int Done { get { return Thread.VolatileRead(ref done); } }
        public int Failed { get { return Thread.VolatileRead(ref failed); } }
        public bool IsCompleted { get { return Done >= jobs.Length; } }
        public Job[] Jobs { get { return jobs; } }
        public void Cancel() { cancel = true; }

        public void Start()
        {
            int n = Math.Min(threads, Math.Max(1, jobs.Length));
            ths = new Thread[n];
            for (int i = 0; i < n; i++)
            {
                ths[i] = new Thread(Work);
                ths[i].IsBackground = true;
                ths[i].Start();
            }
        }

        public bool Wait(int ms)
        {
            if (ths == null) return true;
            DateTime end = DateTime.UtcNow.AddMilliseconds(ms);
            foreach (Thread t in ths)
            {
                int left = (int)(end - DateTime.UtcNow).TotalMilliseconds;
                if (left < 0) left = 0;
                if (!t.Join(left)) return false;
            }
            return true;
        }

        void Work()
        {
            while (true)
            {
                int i = Interlocked.Increment(ref next);
                if (i >= jobs.Length) break;
                if (cancel) { jobs[i].Error = "отменено"; Interlocked.Increment(ref failed); Interlocked.Increment(ref done); continue; }
                try { Process(jobs[i]); }
                catch (Exception ex) { jobs[i].Error = ex.Message; Interlocked.Increment(ref failed); }
                Interlocked.Increment(ref done);
            }
        }

        static void WriteAtomic(string path, byte[] bytes)
        {
            string dir = Path.GetDirectoryName(path);
            if (!Directory.Exists(dir)) Directory.CreateDirectory(dir);
            string tmp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllBytes(tmp, bytes);
            try
            {
                if (File.Exists(path)) File.Replace(tmp, path, null);
                else
                {
                    try { File.Move(tmp, path); }
                    catch (IOException) { if (!File.Exists(path)) throw; File.Replace(tmp, path, null); }       // тот же файл успел записать другой поток / процесс
                }
            }
            finally { if (File.Exists(tmp)) { try { File.Delete(tmp); } catch (Exception) { } } }
        }

        public static void Process(Job j)
        {
            int w, h;
            byte[] px = Img.Decode(File.ReadAllBytes(j.Src), out w, out h);
            bool tile = (j.Kind == "tile");
            byte[] o = Recolor.Apply(px, j.Ops, tile, j.Brand);
            if (!tile)
            {
                if (!string.IsNullOrEmpty(j.OutPng)) WriteAtomic(j.OutPng, Img.EncodePng(o, w, h));
                if (!string.IsNullOrEmpty(j.OutIco)) WriteAtomic(j.OutIco, Img.MakeIco(o, w, h));
            }
            else
            {
                string ext = Path.GetExtension(j.OutTile).ToLowerInvariant();
                byte[] enc = (ext == ".jpg" || ext == ".jpeg") ? Codec.EncodeJpeg(o, w, h, 92) : Img.EncodePng(o, w, h);
                WriteAtomic(j.OutTile, enc);
            }
        }
    }
}
'@

# слой кодеков: заглушка (Linux / тесты) - JPEG недоступен
$script:SI_VariantsCodecStub = @'
namespace GlyphixVariants
{
    using System;
    public static class Codec
    {
        public static bool Available { get { return false; } }
        public static byte[] Decode(byte[] data, out int w, out int h) { w = 0; h = 0; throw new NotSupportedException("JPEG-кодек доступен только в Windows"); }
        public static byte[] EncodeJpeg(byte[] rgba, int w, int h, int quality) { throw new NotSupportedException("JPEG-кодек доступен только в Windows"); }
    }
}
'@

# слой кодеков Windows: GDI+ (System.Drawing). Только Windows; в тестах не проверяется.
$script:SI_VariantsCodecWin = @'
namespace GlyphixVariants
{
    using System;
    using System.Drawing;
    using System.Drawing.Imaging;
    using System.IO;
    using System.Runtime.InteropServices;

    public static class Codec
    {
        public static bool Available { get { return true; } }

        // PNG / JPEG / любой формат GDI+ -> RGBA (прямая прозрачность)
        public static byte[] Decode(byte[] data, out int w, out int h)
        {
            using (MemoryStream ms = new MemoryStream(data))
            using (Bitmap src = new Bitmap(ms))
            {
                w = src.Width; h = src.Height;
                BitmapData d = src.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                try
                {
                    byte[] o = new byte[w * h * 4];
                    byte[] row = new byte[w * 4];
                    for (int y = 0; y < h; y++)
                    {
                        Marshal.Copy(new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), row, 0, w * 4);
                        for (int x = 0; x < w; x++)
                        {
                            int i = (y * w + x) * 4;
                            o[i] = row[x * 4 + 2]; o[i + 1] = row[x * 4 + 1]; o[i + 2] = row[x * 4]; o[i + 3] = row[x * 4 + 3];
                        }
                    }
                    return o;
                }
                finally { src.UnlockBits(d); }
            }
        }

        public static byte[] EncodeJpeg(byte[] rgba, int w, int h, int quality)
        {
            using (Bitmap bmp = new Bitmap(w, h, PixelFormat.Format24bppRgb))
            {
                BitmapData d = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format24bppRgb);
                try
                {
                    byte[] row = new byte[Math.Abs(d.Stride)];
                    for (int y = 0; y < h; y++)
                    {
                        Array.Clear(row, 0, row.Length);
                        for (int x = 0; x < w; x++)
                        {
                            int i = (y * w + x) * 4;
                            row[x * 3] = rgba[i + 2]; row[x * 3 + 1] = rgba[i + 1]; row[x * 3 + 2] = rgba[i];
                        }
                        Marshal.Copy(row, 0, new IntPtr(d.Scan0.ToInt64() + (long)y * d.Stride), Math.Abs(d.Stride));
                    }
                }
                finally { bmp.UnlockBits(d); }
                ImageCodecInfo codec = null;
                foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders()) { if (c.MimeType == "image/jpeg") { codec = c; break; } }
                MemoryStream ms = new MemoryStream();
                if (codec == null) { bmp.Save(ms, ImageFormat.Jpeg); return ms.ToArray(); }
                using (EncoderParameters ep = new EncoderParameters(1))
                {
                    ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                    bmp.Save(ms, codec, ep);
                }
                return ms.ToArray();
            }
        }
    }
}
'@

# Компиляция один раз на процесс (как Initialize-AutoNative: мьютекс - фоновые runspace'ы одного процесса не компилируют тип дважды)
function Initialize-VariantsNative {
    if ('GlyphixVariants.Recolor' -as [type]) { return $true }
    $win = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
    $mtx = $null; $held = $false
    try { $mtx = New-Object System.Threading.Mutex($false, 'Local\GlyphixVariantsCompile') } catch { $mtx = $null }
    try {
        if ($mtx) {
            try { $held = $mtx.WaitOne(20000) } catch [System.Threading.AbandonedMutexException] { $held = $true }
        }
        if ('GlyphixVariants.Recolor' -as [type]) { return $true }
        try {
            if ($win) { Add-Type -TypeDefinition ($script:SI_VariantsCoreCode + "`n" + $script:SI_VariantsCodecWin) -Language CSharp -ReferencedAssemblies 'System.Drawing' }
            else { Add-Type -TypeDefinition ($script:SI_VariantsCoreCode + "`n" + $script:SI_VariantsCodecStub) -Language CSharp }
        } catch {
            if (-not ('GlyphixVariants.Recolor' -as [type])) { throw }
        }
    } finally {
        if ($mtx) { if ($held) { try { $mtx.ReleaseMutex() } catch { } }; $mtx.Dispose() }
    }
    return $true
}

$script:SI_VariantOpNames = @('gradient_map', 'brand_map', 'hue_rotate', 'saturate', 'brightness', 'contrast', 'gamma', 'mix', 'colorize', 'alpha')
$script:SI_VariantRenderVersion = 1                  # меняется вместе с алгоритмом отрисовки (часть ключа кэша)
$script:SI_Inv = [Globalization.CultureInfo]::InvariantCulture

function ConvertTo-VariantRgb {
    param($Hex)
    $s = ([string]$Hex).Trim()
    if ($s -eq '{brand}') { return -1 }
    if ($s -notmatch '^#[0-9a-fA-F]{6}$') { throw "неверный цвет '$s'" }
    return [int][Convert]::ToInt32($s.Substring(1), 16)
}

function ConvertTo-VariantNum {
    param($V)
    return [double]::Parse(([string]([double]$V)), $script:SI_Inv)
}

# JSON-операции каталога (массив объектов) -> GlyphixVariants.Op[]; неизвестная операция / неверное значение - исключение
function ConvertTo-VariantOps {
    param($Ops)
    [void](Initialize-VariantsNative)
    $list = [System.Collections.Generic.List[GlyphixVariants.Op]]::new()
    foreach ($o in @($Ops)) {
        if ($null -eq $o) { continue }
        $name = [string](Get-JsonProp $o 'op')
        if ($script:SI_VariantOpNames -notcontains $name) { throw "неизвестная операция '$name'" }
        $op = New-Object GlyphixVariants.Op
        $op.Name = $name
        $tg = Get-JsonProp $o 'target'
        if ($null -ne $tg) {
            if ([string]$tg -eq 'icons') { $op.Target = 1 } elseif ([string]$tg -eq 'tiles') { $op.Target = 2 } else { throw "неверный target '$tg'" }
        }
        $num = {
            param([string]$Key, [double]$Def)
            $v = Get-JsonProp $o $Key
            if ($null -eq $v) { return $Def }
            return [double]$v
        }
        $mn = Get-JsonProp $o 'min_l'; if ($null -ne $mn) { $op.MinL = [double]$mn }
        $mx = Get-JsonProp $o 'max_l'; if ($null -ne $mx) { $op.MaxL = [double]$mx }
        switch ($name) {
            { $_ -eq 'gradient_map' -or $_ -eq 'brand_map' } {
                $st = @(Get-JsonProp $o 'stops')
                if ($st.Count -lt 1) { throw 'gradient_map: нет точек' }
                $pos = New-Object 'double[]' $st.Count; $rgb = New-Object 'int[]' $st.Count
                for ($i = 0; $i -lt $st.Count; $i++) {
                    $pr = @($st[$i])
                    if ($pr.Count -ne 2) { throw 'gradient_map: точка должна быть [pos, цвет]' }
                    $pos[$i] = [double]$pr[0]; $rgb[$i] = ConvertTo-VariantRgb $pr[1]
                    if ($i -gt 0 -and $pos[$i] -lt $pos[$i - 1]) { throw 'gradient_map: pos должны идти по возрастанию' }
                }
                $op.StopPos = $pos; $op.StopRgb = $rgb
                $op.Strength = (& $num 'strength' 1.0)
                $op.SourceMax = ([string](Get-JsonProp $o 'source') -eq 'max')
            }
            'hue_rotate' { $op.Deg = (& $num 'deg' 0.0) }
            'saturate' { $op.K = (& $num 'k' 1.0) }
            'brightness' { $op.K = (& $num 'k' 1.0) }
            'contrast' { $op.K = (& $num 'k' 1.0) }
            'gamma' { $op.G = (& $num 'g' 1.0); if ($op.G -le 0) { throw 'gamma: g должно быть > 0' } }
            'mix' {
                $c = ConvertTo-VariantRgb (Get-JsonProp $o 'color'); if ($c -lt 0) { $op.ColorBrand = $true } else { $op.Color = $c }
                $op.K = (& $num 'k' 0.0)
            }
            'colorize' {
                $c = ConvertTo-VariantRgb (Get-JsonProp $o 'color'); if ($c -lt 0) { $op.ColorBrand = $true } else { $op.Color = $c }
                $op.Gain = (& $num 'gain' 1.5)
                $kv = Get-JsonProp $o 'keep_v'; if ($null -ne $kv) { $op.KeepV = [bool]$kv }
            }
            'alpha' {
                $op.Scale = (& $num 'scale' 1.0); $op.Lo = (& $num 'lo' 0.0); $op.Hi = (& $num 'hi' 1.0); $op.A0 = (& $num 'a0' 1.0); $op.A1 = (& $num 'a1' 1.0)
            }
        }
        $list.Add($op)
    }
    return , $list.ToArray()
}

# цвет '#RRGGBB' -> int (-1 - нет / неверный)
function ConvertTo-BrandRgb {
    param($Hex)
    $s = ([string]$Hex).Trim()
    if ($s -notmatch '^#[0-9a-fA-F]{6}$') { return -1 }
    return [int][Convert]::ToInt32($s.Substring(1), 16)
}

# Перекрасить RGBA-пиксели (byte[]): $Kind 'icon' | 'tile', $Brand '#RRGGBB' или ''
function Invoke-VariantOps {
    param([byte[]]$Rgba, $Ops, [string]$Kind = 'icon', [string]$Brand = '')
    [void](Initialize-VariantsNative)
    $nOps = if ($Ops -is [GlyphixVariants.Op[]]) { $Ops } else { ConvertTo-VariantOps $Ops }
    return , [GlyphixVariants.Recolor]::Apply($Rgba, $nOps, ($Kind -eq 'tile'), (ConvertTo-BrandRgb $Brand))
}

# Зажим светлоты цвета бренда: '#RRGGBB' -> '#RRGGBB'; MinL / MaxL необязательны ($null)
function Get-ClampedBrand {
    param([string]$Hex, $MinL = $null, $MaxL = $null)
    $mn = [double]::NaN; $mx = [double]::NaN
    if ($null -ne $MinL) { $mn = [double]$MinL }
    if ($null -ne $MaxL) { $mx = [double]$MaxL }
    [void](Initialize-VariantsNative)
    $c = [GlyphixVariants.Recolor]::ClampBrand((ConvertTo-VariantRgb $Hex), $mn, $mx)
    return ('#{0:X6}' -f $c)
}

# ---------- Каталог вариантов (variants.json) ----------
# Локально: catalog\variants.json + catalog\previews\<id>.jpg (скачиваются вместе с index.json, Update-Packs -> Update-VariantCatalog).
# Нет каталога / он не читается - запасной каталог из паков (index.json): каждый пак = один вариант без операций (id варианта = id пака).
$script:SI_CatalogDir = Join-Path $script:SI_Home 'catalog'
$script:SI_CatalogFile = Join-Path $script:SI_CatalogDir 'variants.json'
$script:SI_PreviewDir = Join-Path $script:SI_CatalogDir 'previews'
$script:SI_PreviewStamp = Join-Path $script:SI_CatalogDir 'previews.stamp'
$script:SI_VariantsDir = Join-Path $script:SI_Home 'variants'                        # кэш отрисованных вариантов: variants\<id>\<ключ>\...
$script:SI_CatalogMaxBytes = 2097152
$script:SI_CatalogCache = $null
$script:SI_IdRx = '^[a-z0-9][a-z0-9_\-]{0,63}$'

function Test-OpsUseBrand {
    param($Ops)
    foreach ($o in @($Ops)) {
        if ([string](Get-JsonProp $o 'color') -eq '{brand}') { return $true }
        foreach ($st in @(Get-JsonProp $o 'stops')) { if ($st -and @($st).Count -ge 2 -and [string]@($st)[1] -eq '{brand}') { return $true } }
    }
    return $false
}

function Add-VariantProps {
    param($V, $Section, [string]$PreviewDir)
    $pp = $null
    $cand = Join-Path $PreviewDir ([string]$V.Id + '.jpg')
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $pp = $cand }
    return [pscustomobject]@{
        Id = [string]$V.Id; Title = [string]$V.Title; Base = [string]$V.Base; Ops = @($V.Ops); IsBase = (@($V.Ops).Count -eq 0)
        UsesBrand = (Test-OpsUseBrand $V.Ops); Preview = [string]$V.Preview; PreviewPath = $pp; Tags = @($V.Tags)
        SectionId = [string]$Section.Id; SectionTitle = [string]$Section.Title; Fallback = $false; Description = ''
    }
}

# Разбор и проверка variants.json. Возвращает каталог или бросает исключение (такой файл не сохраняется и не принимается). Варианты с неизвестной
# операцией / неверными данными пропускаются (в журнал), остальные работают.
function ConvertFrom-VariantCatalog {
    param([byte[]]$Bytes, [string]$PreviewDir = $script:SI_PreviewDir)
    $j = ConvertFrom-JsonBytes $Bytes
    if ($null -eq $j -or $j -isnot [pscustomobject]) { throw 'variants.json: ожидался объект' }
    $schema = Get-JsonProp $j 'schema'
    if ($null -eq $schema -or [int]$schema -ne 1) { throw "variants.json: неподдерживаемая schema '$schema'" }
    $secs = @(Get-JsonProp $j 'sections')
    if ($secs.Count -eq 0) { throw 'variants.json: нет секций' }
    $brand = @{}
    $bc = Get-JsonProp $j 'brand_colors'
    if ($bc) { foreach ($p in $bc.PSObject.Properties) { if ($p.Name -match '^[A-Za-z0-9_\-]+$' -and ([string]$p.Value) -match '^#[0-9a-fA-F]{6}$') { $brand[$p.Name] = ([string]$p.Value).ToUpperInvariant() } } }
    $flags = @{}
    $bf = Get-JsonProp $j 'brand_flags'
    if ($bf) { foreach ($p in $bf.PSObject.Properties) { if ($p.Name -match '^[A-Za-z0-9_\-]+$') { $flags[$p.Name] = $p.Value } } }
    $outSecs = [System.Collections.Generic.List[object]]::new()
    $flat = [System.Collections.Generic.List[object]]::new()
    $byId = @{}
    foreach ($s in $secs) {
        $sid = [string](Get-JsonProp $s 'id')
        if ($sid -notmatch '^[A-Za-z0-9_\-]{1,40}$') { Write-Log "  каталог вариантов: секция с неверным id '$sid' пропущена"; continue }
        $sec = [pscustomobject]@{ Id = $sid; Title = [string](Get-JsonProp $s 'title'); Subtitle = [string](Get-JsonProp $s 'subtitle'); Variants = $null }
        $vl = [System.Collections.Generic.List[object]]::new()
        foreach ($v in @(Get-JsonProp $s 'variants')) {
            $vid = [string](Get-JsonProp $v 'id'); $vb = [string](Get-JsonProp $v 'base')
            if ($vid -notmatch $script:SI_IdRx -or $vb -notmatch $script:SI_IdRx) { Write-Log "  каталог вариантов: вариант '$vid' (base '$vb') пропущен - неверный id"; continue }
            if ($byId.ContainsKey($vid)) { Write-Log "  каталог вариантов: повторный id '$vid' пропущен"; continue }
            $ops = @(Get-JsonProp $v 'ops')
            try { [void](ConvertTo-VariantOps $ops) } catch { Write-Log "  каталог вариантов: '$vid' пропущен - $($_.Exception.Message)"; continue }
            $prev = [string](Get-JsonProp $v 'preview')
            if ($prev -and -not (Test-SafeRel $prev @('.jpg', '.jpeg', '.png'))) { Write-Log "  каталог вариантов: у '$vid' небезопасный путь превью - убран"; $prev = '' }
            $tags = @(Get-JsonProp $v 'tags' | ForEach-Object { [string]$_ })
            $o = Add-VariantProps ([pscustomobject]@{ Id = $vid; Title = $(if (Get-JsonProp $v 'title') { [string](Get-JsonProp $v 'title') } else { $vid }); Base = $vb; Ops = $ops; Preview = $prev; Tags = $tags }) $sec $PreviewDir
            $vl.Add($o); $flat.Add($o); $byId[$vid] = $o
        }
        $sec.Variants = $vl.ToArray()
        if ($vl.Count -gt 0) { $outSecs.Add($sec) }
    }
    if ($flat.Count -eq 0) { throw 'variants.json: ни одного допустимого варианта' }
    return [pscustomobject]@{ Schema = 1; Updated = [string](Get-JsonProp $j 'updated'); Source = 'catalog'; Sections = $outSecs.ToArray(); Variants = $flat.ToArray(); ById = $byId; BrandColors = $brand; BrandFlags = $flags }
}

# Запасной каталог: паки из локального packs\index.json (порядок как в нём), иначе - прочитанные Get-Packs. Каждый пак = вариант без операций.
function Get-FallbackVariantCatalog {
    $entries = [System.Collections.Generic.List[object]]::new()
    $ixf = Join-Path $script:SI_PacksDir 'index.json'
    try {
        if (Test-Path -LiteralPath $ixf -PathType Leaf) {
            foreach ($e in @((Read-JsonFile $ixf).packs)) {
                $id = [string]$e.id
                if ($id -match $script:SI_IdRx) { $entries.Add([pscustomobject]@{ Id = $id; Name = [string]$e.name; Description = [string]$e.description }) }
            }
        }
    } catch { Write-Log ('запасной каталог: index.json не прочитан - ' + $_.Exception.Message) }
    if ($entries.Count -eq 0) {
        try { foreach ($p in @(Get-Packs)) { $entries.Add([pscustomobject]@{ Id = [string]$p.Id; Name = [string]$p.Name; Description = [string]$p.Description }) } } catch { }
    }
    $sec = [pscustomobject]@{ Id = 'packs'; Title = 'Паки'; Subtitle = ''; Variants = $null }
    $flat = [System.Collections.Generic.List[object]]::new()
    $byId = @{}
    foreach ($e in $entries) {
        if ($byId.ContainsKey($e.Id)) { continue }
        $pv = Join-Path (Join-Path $script:SI_PacksDir $e.Id) 'preview.png'
        $o = [pscustomobject]@{
            Id = $e.Id; Title = $(if ($e.Name) { $e.Name } else { $e.Id }); Base = $e.Id; Ops = @(); IsBase = $true; UsesBrand = $false; Preview = ''
            PreviewPath = $(if (Test-Path -LiteralPath $pv -PathType Leaf) { $pv } else { $null }); Tags = @(); SectionId = 'packs'; SectionTitle = 'Паки'; Fallback = $true; Description = $e.Description
        }
        $flat.Add($o); $byId[$e.Id] = $o
    }
    $sec.Variants = $flat.ToArray()
    return [pscustomobject]@{ Schema = 1; Updated = ''; Source = 'fallback'; Sections = $(if ($flat.Count -gt 0) { @($sec) } else { @() }); Variants = $flat.ToArray(); ById = $byId; BrandColors = @{}; BrandFlags = @{} }
}

# Каталог для показа: локальный catalog\variants.json (если читается и проходит проверку), иначе запасной из паков. Результат кэшируется по файлу.
function Get-VariantCatalog {
    param([switch]$Fallback)
    if (-not $Fallback -and (Test-Path -LiteralPath $script:SI_CatalogFile -PathType Leaf)) {
        try {
            $fi = Get-Item -LiteralPath $script:SI_CatalogFile
            $key = $script:SI_CatalogFile + '|' + $fi.LastWriteTimeUtc.Ticks + '|' + $fi.Length
            $pc = $script:SI_CatalogCache
            if ($pc -and $pc.Key -eq $key -and -not $pc.PreviewsChanged) { return $pc.Value }
            $cat = ConvertFrom-VariantCatalog ([IO.File]::ReadAllBytes($script:SI_CatalogFile))
            $script:SI_CatalogCache = [pscustomobject]@{ Key = $key; Value = $cat; PreviewsChanged = $false }
            return $cat
        } catch { Write-Log ('каталог вариантов не прочитан, беру паки: ' + $_.Exception.Message) }
    }
    return (Get-FallbackVariantCatalog)
}

# Вариант по id: из каталога; нет там - пак с таким id (старые вызовы 2.x: «применить пак shadow»); иначе $null
function Get-Variant {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $cat = Get-VariantCatalog
    if ($cat.ById.ContainsKey($Id)) { return $cat.ById[$Id] }
    if ($cat.Source -ne 'fallback') { $fb = Get-FallbackVariantCatalog; if ($fb.ById.ContainsKey($Id)) { return $fb.ById[$Id] } }
    return $null
}

# Путь к превью карточки варианта (JPEG из каталога или preview.png пака); файла нет - $null
function Get-VariantPreviewPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)
    $v = Get-Variant $Id
    if (-not $v) { return $null }
    if ($v.PreviewPath -and (Test-Path -LiteralPath ([string]$v.PreviewPath) -PathType Leaf)) { return [string]$v.PreviewPath }
    $cand = Join-Path $script:SI_PreviewDir ($Id + '.jpg')
    if (Test-Path -LiteralPath $cand -PathType Leaf) { return $cand }
    return $null
}

# Скачать variants.json и превью (вместе с index.json: вызывается из Update-Packs). Те же повторы и зеркало, что у паков. Ничего не бросает.
# Возвращает { Ok; Updated (каталог заменён); Previews (скачано); Failed; Message }.
function Update-VariantCatalog {
    [CmdletBinding()]
    param([string]$BaseUrl = $script:SI_BaseUrl, $Index = $null, [switch]$NoPreviews, $Cancel = $null)
    $res = [pscustomobject]@{ Ok = $false; Updated = $false; Previews = 0; Failed = 0; Message = '' }
    try {
        if (-not $BaseUrl.EndsWith('/')) { $BaseUrl += '/' }
        $bytes = Get-WebBytes ($BaseUrl + 'variants.json') $script:SI_CatalogMaxBytes
        if ($Index) {
            $want = [string](Get-JsonProp $Index 'variants_sha256')           # необязательно: если издатель указал хэш в index.json - сверяем
            if ($want -and (Get-BytesSha256 $bytes) -ne $want.ToLowerInvariant()) { throw 'sha256 variants.json не совпал с index.json' }
        }
        $cat = ConvertFrom-VariantCatalog $bytes
        $keepLocal = $false
        if (Test-Path -LiteralPath $script:SI_CatalogFile -PathType Leaf) {
            try {
                $loc = ConvertFrom-VariantCatalog ([IO.File]::ReadAllBytes($script:SI_CatalogFile))
                if ($loc.Updated -and $cat.Updated -and [string]::CompareOrdinal($loc.Updated, $cat.Updated) -gt 0) { $keepLocal = $true; Write-Log "каталог вариантов на сервере (зеркало?) старше локального ($($cat.Updated) < $($loc.Updated)) - локальный оставляю" }
                elseif ((Get-FileSha256 $script:SI_CatalogFile) -eq (Get-BytesSha256 $bytes)) { $keepLocal = $true }
            } catch { }
        }
        if (-not $keepLocal) { Save-FileAtomic $script:SI_CatalogFile $bytes; $res.Updated = $true; $script:SI_CatalogCache = $null; Write-Log "Каталог вариантов обновлён: вариантов $(@($cat.Variants).Count)" }
        $res.Ok = $true
        if ($NoPreviews -or (Test-RefreshCancelled $Cancel)) { return $res }
        $cur = Get-VariantCatalog
        $stampWant = [string]$cur.Updated + ':' + (Get-FileSha256 $script:SI_CatalogFile).Substring(0, 8)
        $stampHave = ''; try { if (Test-Path -LiteralPath $script:SI_PreviewStamp -PathType Leaf) { $stampHave = ([IO.File]::ReadAllText($script:SI_PreviewStamp)).Trim() } } catch { }
        $items = [System.Collections.Generic.List[object]]::new()
        $jpegCheck = { param($b) ($b.Length -gt 4 -and $b[0] -eq 0xFF -and $b[1] -eq 0xD8) -or ($b.Length -gt 8 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50) }
        foreach ($v in @($cur.Variants)) {
            if (-not $v.Preview) { continue }
            $dest = Join-Path $script:SI_PreviewDir ([string]$v.Id + '.jpg')
            if ($stampHave -eq $stampWant -and (Test-Path -LiteralPath $dest -PathType Leaf)) { continue }
            $items.Add([pscustomobject]@{ Rel = [string]$v.Preview; Url = ($BaseUrl + [string]$v.Preview); Dest = $dest; Sha = ''; Check = $jpegCheck })
        }
        if ($items.Count -gt 0) {
            $d = Invoke-ParallelDownload -Items $items.ToArray() -Label 'превью вариантов'
            $res.Previews = [int]$d.Done; $res.Failed = [int]$d.Failed.Count
            $script:SI_CatalogCache = $null
        }
        if ($res.Failed -eq 0) { try { Save-FileAtomic $script:SI_PreviewStamp ([System.Text.UTF8Encoding]::new($false).GetBytes($stampWant)) } catch { } }
        else { $res.Ok = $false; $res.Message = "превью не скачано: $($res.Failed)" }
    } catch {
        $res.Ok = $false; $res.Message = $_.Exception.Message
        Write-Log ('Каталог вариантов не обновлён: ' + $_.Exception.Message)
    }
    return $res
}

# ---------- Варианты как паки ----------
# Канонический JSON (ключи по алфавиту, числа в инвариантной записи): не зависит от версии PowerShell - иначе ключ кэша менялся бы между 5.1 и 7
function ConvertTo-CanonicalJson {
    param($V)
    if ($null -eq $V) { return 'null' }
    if ($V -is [bool]) { return $(if ($V) { 'true' } else { 'false' }) }
    if ($V -is [string]) { return ('"' + ($V -replace '\\', '\\' -replace '"', '\"') + '"') }
    if ($V -is [int] -or $V -is [long] -or $V -is [double] -or $V -is [single] -or $V -is [decimal]) { return ([double]$V).ToString('R', $script:SI_Inv) }
    if ($V -is [System.Collections.IDictionary]) {
        $parts = foreach ($k in @($V.Keys | Sort-Object { [string]$_ })) { '"' + [string]$k + '":' + (ConvertTo-CanonicalJson $V[$k]) }
        return ('{' + (@($parts) -join ',') + '}')
    }
    if ($V -is [System.Collections.IEnumerable]) { return ('[' + ((@($V | ForEach-Object { ConvertTo-CanonicalJson $_ })) -join ',') + ']') }
    $props = @($V.PSObject.Properties | Sort-Object Name)
    $parts2 = foreach ($p in $props) { '"' + $p.Name + '":' + (ConvertTo-CanonicalJson $p.Value) }
    return ('{' + (@($parts2) -join ',') + '}')
}

# Ключ кэша отрисованного варианта: sha256(версия отрисовки | пак-основа, его версия и хэш pack.json | операции | таблица цветов брендов (если операции её используют))[0..7]
function Get-VariantCacheKey {
    param($Variant, $Base, $Catalog = $null)
    $brand = ''
    if ($Variant.UsesBrand) {
        $bc = if ($Catalog) { $Catalog.BrandColors } else { @{} }
        $brand = (@($bc.Keys | Sort-Object | ForEach-Object { $_ + '=' + $bc[$_] }) -join ';')
        $brand = Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($brand))
    }
    $s = 'r' + $script:SI_VariantRenderVersion + '|' + [string]$Variant.Base + '|' + [string]$Base.Version + '|' + [string]$Base.ManifestSha + '|' + (ConvertTo-CanonicalJson @($Variant.Ops)) + '|' + $brand
    return (Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes($s))).Substring(0, 8)
}

# цвет бренда иконки для {brand}: из каталога; нет - основной цвет автоиконок пака, иначе фиолетовый Glyphix
function Get-VariantBrandColor {
    param($Catalog, [string]$IconId, $Base = $null)
    if ($Catalog -and $Catalog.BrandColors.ContainsKey($IconId)) { return [string]$Catalog.BrandColors[$IconId] }
    if ($Base -and $Base.PSObject.Properties['Auto'] -and $Base.Auto -and $Base.Auto.Mid) { return ([string]$Base.Auto.Mid).ToUpperInvariant() }
    return '#7C5CFF'
}

# Паки-основы, которые нужны для вариантов: id пака, версия, хэш pack.json
function Get-VariantBasePack {
    param([string]$BaseId, [string[]]$SyncParts, [bool]$Sync = $true)
    if ($Sync) { return (Sync-PackForApply -Id $BaseId -Parts $SyncParts) }
    $pk = @(Get-Packs -OnlyId $BaseId) | Select-Object -First 1
    if (-not $pk) { throw "пак '$BaseId' не найден" }
    return $pk
}

# Вариант -> объект, совместимый с конвейером применения (как элемент Get-Packs): Id (= id варианта), Name, Version, Icons[ { Id, Name, Group, IcoPath, PngPath,
# Names, Exes, TilePath, TileNoNamePath } ], Dir, Files, PartFiles, State, Auto*, плюс BaseId, VariantId, Ops, CacheKey, Failed, Synced.
#  * ops = [] (базовый вариант): файлы - сам скачанный пак; * иначе: файлы рисуются в variants\<id>\<ключ>\icons|tiles|tiles_noname и только для
#    нужных id: -IconIds (по умолчанию все). -Parts: icons (png+ico) | png (только превью) | tiles | noname; по умолчанию @('icons'). -Parts @() ничего не рисует
#    (только описание: сопоставление по именам). Параллельно (потоков до 8), -OnProgress { param($done, $total) }.
#    Нет сети - работает из кэша пака (Sync-PackForApply); -NoSync - вообще без сети (пак уже на диске).
function Resolve-VariantPack {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariantId, [string[]]$IconIds = $null, [string[]]$Parts = @('icons'), [scriptblock]$OnProgress = $null, [switch]$NoSync)
    $variant = Get-Variant $VariantId
    if (-not $variant) { throw "вариант '$VariantId' не найден в каталоге" }
    $Parts = @($Parts | Where-Object { $_ })
    $syncParts = @('icons')
    if ($Parts -contains 'tiles') { $syncParts += 'tiles' }
    if ($Parts -contains 'noname') { $syncParts += 'noname' }
    $base = Get-VariantBasePack ([string]$variant.Base) $syncParts (-not $NoSync)
    $catalog = Get-VariantCatalog
    $all = @('icons', 'tiles', 'noname')
    if ($variant.IsBase) {
        $base.Id = [string]$variant.Id
        if ($variant.Title -and -not $variant.Fallback) { $base.Name = [string]$variant.Title }
        foreach ($kv in @(@('BaseId', [string]$variant.Base), @('VariantId', [string]$variant.Id), @('Ops', @()), @('CacheKey', ''), @('Variant', $variant), @('Failed', @()), @('Rendered', 0))) {
            $base | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force
        }
        $base | Add-Member -NotePropertyName Synced -NotePropertyValue $true -Force
        $base | Add-Member -NotePropertyName SyncedParts -NotePropertyValue $all -Force
        return $base
    }
    [void](Initialize-VariantsNative)
    $key = Get-VariantCacheKey $variant $base $catalog
    $dir = Join-Path (Join-Path $script:SI_VariantsDir ([string]$variant.Id)) $key
    $opsN = ConvertTo-VariantOps $variant.Ops
    $want = $null
    if ($null -ne $IconIds) { $want = @{}; foreach ($i in @($IconIds)) { if ($i) { $want[[string]$i] = $true } } }
    $icons = [System.Collections.Generic.List[object]]::new()
    $jobs = [System.Collections.Generic.List[GlyphixVariants.Job]]::new()
    $files = [System.Collections.Generic.List[string]]::new()
    $pIcons = [System.Collections.Generic.List[string]]::new(); $pTiles = [System.Collections.Generic.List[string]]::new(); $pNoName = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[object]]::new()
    $doIcons = ($Parts -contains 'icons'); $doPng = ($doIcons -or ($Parts -contains 'png'))
    foreach ($ic in @($base.Icons)) {
        $id = [string]$ic.Id
        $png = Join-Path (Join-Path $dir 'icons') ($id + '.png'); $ico = Join-Path (Join-Path $dir 'icons') ($id + '.ico')
        $tile = $null; $tileNn = $null
        if ($ic.TilePath) { $tile = Join-Path (Join-Path $dir 'tiles') ($id + [IO.Path]::GetExtension([string]$ic.TilePath)) }
        if ($ic.TileNoNamePath -and ([string]$ic.TileNoNamePath -ne [string]$ic.TilePath)) { $tileNn = Join-Path (Join-Path $dir 'tiles_noname') ($id + [IO.Path]::GetExtension([string]$ic.TileNoNamePath)) }
        $icons.Add([pscustomobject]@{ Id = $id; Name = [string]$ic.Name; Group = [string]$ic.Group; IcoPath = $ico; PngPath = $png; Names = @($ic.Names); Exes = @($ic.Exes); TilePath = $tile; TileNoNamePath = $tileNn })
        $files.Add($ico); $files.Add($png); $pIcons.Add($ico); $pIcons.Add($png)
        if ($tile) { $files.Add($tile); $pTiles.Add($tile) }
        if ($tileNn) { $files.Add($tileNn); $pNoName.Add($tileNn) } elseif ($tile) { $pNoName.Add($tile) }
        if ($want -and -not $want.ContainsKey($id)) { continue }
        $brand = if ($variant.UsesBrand) { ConvertTo-BrandRgb (Get-VariantBrandColor $catalog $id $base) } else { -1 }
        if ($doPng) {
            $needPng = -not (Test-Path -LiteralPath $png -PathType Leaf)
            $needIco = $doIcons -and -not (Test-Path -LiteralPath $ico -PathType Leaf)
            if ($needPng -or $needIco) {
                $src = [string]$ic.PngPath
                if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { $missing.Add([pscustomobject]@{ IconId = $id; Kind = 'icon'; Error = 'в паке нет файла иконки' }) }
                else {
                    $j = New-Object GlyphixVariants.Job; $j.Kind = 'icon'; $j.Src = $src; $j.Ops = $opsN; $j.Brand = $brand
                    if ($needPng) { $j.OutPng = $png }
                    if ($needIco) { $j.OutIco = $ico }
                    $jobs.Add($j)
                }
            }
        }
        $needTiles = ($Parts -contains 'tiles') -or (($Parts -contains 'noname') -and -not $tileNn)          # нет отдельной плитки без имени - для noname нужна обычная
        foreach ($tp in @(@('tiles', $ic.TilePath, $tile), @('noname', $ic.TileNoNamePath, $tileNn))) {
            if (($tp[0] -eq 'tiles' -and -not $needTiles) -or ($tp[0] -eq 'noname' -and $Parts -notcontains 'noname') -or -not $tp[1] -or -not $tp[2]) { continue }
            if (Test-Path -LiteralPath ([string]$tp[2]) -PathType Leaf) { continue }
            if (-not (Test-Path -LiteralPath ([string]$tp[1]) -PathType Leaf)) { $missing.Add([pscustomobject]@{ IconId = $id; Kind = 'tile'; Error = 'в паке нет файла плитки' }); continue }
            $j = New-Object GlyphixVariants.Job; $j.Kind = 'tile'; $j.Src = [string]$tp[1]; $j.OutTile = [string]$tp[2]; $j.Ops = $opsN; $j.Brand = $brand
            $jobs.Add($j)
        }
    }
    $failed = [System.Collections.Generic.List[object]]::new()
    foreach ($m in $missing) { $failed.Add($m) }
    $rendered = 0
    if ($jobs.Count -gt 0) {
        $label = 'Рисую ' + [string]$variant.Title
        Write-Log ("$label : файлов $($jobs.Count)")
        $threads = [Math]::Max(1, [Math]::Min(8, [Environment]::ProcessorCount))
        $batch = [GlyphixVariants.Batch]::new($jobs.ToArray(), $threads)
        $batch.Start()
        $last = [Diagnostics.Stopwatch]::StartNew()
        while (-not $batch.Wait(100)) {
            if ($OnProgress) { try { & $OnProgress ([int]$batch.Done) ([int]$batch.Total) } catch { } }
            if ($last.ElapsedMilliseconds -ge 400) { $last.Restart(); Write-Log ("${label}: $($batch.Done)/$($batch.Total)") }
        }
        if ($OnProgress) { try { & $OnProgress ([int]$batch.Total) ([int]$batch.Total) } catch { } }
        foreach ($j in $jobs) {
            if ($j.Error) { $failed.Add([pscustomobject]@{ IconId = [IO.Path]::GetFileNameWithoutExtension([string]$(if ($j.OutPng) { $j.OutPng } elseif ($j.OutIco) { $j.OutIco } else { $j.OutTile })); Kind = [string]$j.Kind; Error = [string]$j.Error }) }
            else { $rendered++ }
        }
        foreach ($f in $failed) { Write-Log ("  не нарисовано $($f.IconId) ($($f.Kind)): $($f.Error)") }
    }
    $pk = [pscustomobject]@{
        Id = [string]$variant.Id; Name = [string]$variant.Title; Version = [string]$base.Version; Author = [string]$base.Author; License = [string]$base.License; Description = ''
        IconCount = $icons.Count; Dir = $dir; Preview = $(if ($variant.PreviewPath) { [string]$variant.PreviewPath } else { $base.Preview }); Icons = $icons.ToArray()
        Files = @($files | Select-Object -Unique); PartFiles = @{ icons = $pIcons.ToArray(); tiles = $pTiles.ToArray(); noname = $pNoName.ToArray(); auto = @() }
        State = 'ready'; Ready = $true; ManifestSha = ([string]$base.ManifestSha + '-' + $key)
        Auto = $base.Auto; AutoDeclared = $base.AutoDeclared; AutoPath = $base.AutoPath; AutoSha = $base.AutoSha
        BaseId = [string]$variant.Base; VariantId = [string]$variant.Id; Ops = @($variant.Ops); CacheKey = $key; Variant = $variant; Failed = $failed.ToArray(); Rendered = $rendered
        FromCache = [bool]($base.PSObject.Properties['FromCache'] -and $base.FromCache); Synced = $true; SyncedParts = $all
    }
    return $pk
}

# Удалить кэш отрисованных вариантов (variants\): без параметров - всё; -KeepKeys: у каждого варианта оставить только эти ключи (вариант -> ключ). Возвращает { Files; Bytes }.
function Clear-VariantCache {
    [CmdletBinding()]
    param([hashtable]$KeepKeys = @{}, [string[]]$OnlyVariants = $null)
    $res = [pscustomobject]@{ Files = 0; Bytes = [long]0 }
    try {
        if (-not (Test-Path -LiteralPath $script:SI_VariantsDir -PathType Container)) { return $res }
        $root = Get-NormalPath $script:SI_VariantsDir
        if (-not (Test-PathUnder $root (Get-NormalPath $script:SI_Home))) { return $res }
        foreach ($vd in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if (Test-IsReparse $vd) { continue }
            if ($vd.Name -notmatch $script:SI_IdRx) { continue }
            if ($OnlyVariants -and ($OnlyVariants -notcontains $vd.Name)) { continue }
            foreach ($kd in @(Get-ChildItem -LiteralPath $vd.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                if (Test-IsReparse $kd) { continue }
                if ($KeepKeys.ContainsKey($vd.Name) -and $KeepKeys[$vd.Name] -eq $kd.Name) { continue }
                $t = Remove-TreeSafe $kd.FullName $root
                $res.Files += $t.Files; $res.Bytes += $t.Bytes
            }
            try { if (-not (Get-ChildItem -LiteralPath $vd.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $vd.FullName -Force -Confirm:$false } } catch { }
        }
        if ($res.Files -gt 0) { Write-Log ('  variants\: удалено файлов ' + $res.Files + ' (' + (Format-DownloadSize $res.Bytes) + ')') }
    } catch { Write-Log ('  кэш вариантов не очищен: ' + $_.Exception.Message) }
    return $res
}

# ---------- Плитки Start11 из закреплённых элементов (GroupContents) ----------
# Start11 хранит закреплённые плитки не в Get-StartApps, а в HKCU\...\Start8.ini\GroupContents\<группа> (группы $PINNEDDEF$, GRP2001...): значения "0", "1", ...
# с данными вида «Telegram.TelegramDesktop|-1|3|1|4|...», «{6D809377-...}\obs-studio\bin\64bit\obs64.exe|...», «C:\Users\X\...\User Pinned\StartMenu\PulseSync.lnk|...»,
# «Microsoft.AutoGenerated.{GUID}|...», «Chrome._crx_...|...». id = текст до первого '|'; имя значения CustomTiles = id с '\' -> '_'.
$script:SI_S11Groups = $script:SI_S11Root + '\GroupContents'
$script:SI_LauncherHosts = @('wscript', 'cscript', 'cmd', 'powershell', 'pwsh', 'mshta', 'rundll32', 'conhost', 'explorer')       # общие хосты: по ним приложение не определить
$script:SI_KnownFolderIds = @{
    '6D809377-6AF0-444B-8957-A3773F02200E' = 'ProgramFiles64'; '7C5A40EF-A0FB-4BFC-874A-C0F2E0B9FA8E' = 'ProgramFilesX86'; '905E63B6-C1BF-494E-B29C-65B732D3D21A' = 'ProgramFiles'
    '1AC14E77-02E7-4E5D-B744-2EB1AE5198B7' = 'System'; 'F38BF404-1D43-42F2-9305-67DE0B28FC23' = 'Windows'; 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091' = 'LocalAppData'
    '3EB685DB-65F9-4CF6-A03A-E3EF65729F3D' = 'RoamingAppData'; '62AB5D82-FDC1-4DC3-A9DD-070D1D495D97' = 'CommonAppData'
}

# подключи (имена) одного ключа реестра HKCU; нет ключа / не Windows - пусто; в тестах подменяется
function Get-S11SubKeyNames {
    param([string]$Sub)
    try {
        $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Sub, $false)
        if (-not $k) { return @() }
        try { return @($k.GetSubKeyNames() | ForEach-Object { [string]$_ }) } finally { $k.Close() }
    } catch { return @() }
}

# данные значения GroupContents -> id (текст до первого '|'; без '|' - вся строка); пусто - $null
function ConvertFrom-PinnedData {
    param([string]$Data)
    if ($null -eq $Data) { return $null }
    $s = $Data
    $i = $s.IndexOf('|')
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    $s = $s.Trim()
    if (-not $s) { return $null }
    return $s
}

# id плитки (имя значения CustomTiles) по id закреплённого элемента
function ConvertTo-PinnedTileName {
    param([string]$Id)
    return ($Id -replace '\\', '_')
}

# Все закреплённые id: { Id (как в GroupContents); TileName (имя в CustomTiles); Group; Index }. Пустые группы и значения не id (не REG_SZ, не число в имени) пропускаются.
function Get-PinnedTileIds {
    $out = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($g in @(Get-S11SubKeyNames $script:SI_S11Groups)) {
        if (-not $g) { continue }
        $sub = $script:SI_S11Groups + '\' + $g
        foreach ($n in @(Get-S11ValueNames $sub)) {
            $idx = 0
            if ([string]$n -notmatch '^\d+$' -or -not [int]::TryParse([string]$n, [ref]$idx)) { continue }
            $data = $null
            try { $data = Get-S11Value $sub ([string]$n) } catch { continue }
            $id = ConvertFrom-PinnedData $data
            if (-not $id) { continue }
            $tn = ConvertTo-PinnedTileName $id
            if ($seen.ContainsKey($tn)) { continue }
            $seen[$tn] = $true
            $out.Add([pscustomobject]@{ Id = $id; TileName = $tn; Group = [string]$g; Index = $idx })
        }
    }
    return $out.ToArray()
}

# Путь из id закреплённого элемента: %VAR%, {KnownFolderId}\... -> обычный путь ('' - не путь)
function Expand-PinnedPath {
    param([string]$Id)
    $s = [Environment]::ExpandEnvironmentVariables($Id.Trim())
    if ($s -match '^\{([0-9A-Fa-f\-]{36})\}[\\/](.*)$') {
        $guid = $Matches[1].ToUpperInvariant(); $rest = $Matches[2]
        $dir = ''
        switch ([string]$script:SI_KnownFolderIds[$guid]) {
            'ProgramFiles64' { $dir = $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) }
            'ProgramFilesX86' { $dir = ${env:ProgramFiles(x86)} }
            'ProgramFiles' { $dir = $env:ProgramFiles }
            'System' { if ($env:SystemRoot) { $dir = Join-Path $env:SystemRoot 'System32' } }
            'Windows' { $dir = $env:SystemRoot }
            'LocalAppData' { $dir = $env:LOCALAPPDATA }
            'RoamingAppData' { $dir = $env:APPDATA }
            'CommonAppData' { $dir = $env:ALLUSERSPROFILE }
        }
        if ($dir) { return (Join-Path $dir ($rest -replace '/', '\')) }
        return ''
    }
    if ($s -match '^[A-Za-z]:[\\/]') { return $s }
    return ''
}

# содержимое .lnk закреплённого элемента: { Exists; Name; Target; Args; AppId }; в тестах подменяется
function Get-LnkInfo {
    param([string]$Path)
    $r = [pscustomobject]@{ Exists = $false; Name = [IO.Path]::GetFileNameWithoutExtension(($Path -replace '\\', '/')); Target = ''; Args = ''; AppId = '' }
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $r }
        $r.Exists = $true
        try { $sc = (Get-WshShell).CreateShortcut($Path); $r.Target = [string]$sc.TargetPath; $r.Args = [string]$sc.Arguments } catch { }
        try {
            if (-not ('GlyphixNative.ShortcutAppId' -as [type])) { Add-Type -TypeDefinition $script:SI_AumidCode -Language CSharp }
            $r.AppId = [string][GlyphixNative.ShortcutAppId]::Get($Path)
        } catch { }
    } catch { }
    return $r
}

function Test-LauncherHostName {
    param([string]$PathOrName)
    $k = Get-Key (Get-BaseNameSafe $PathOrName)
    return ($k -and ($script:SI_LauncherHosts -contains $k))
}

# Закреплённый элемент -> кандидат плитки или $null (общий хост без других данных). Кандидат: Id (= имя в CustomTiles), RawId, Name, Source = 'pinned', AppId = RawId,
# Pinned = $true, Aumid / Target / Args (из .lnk), Ambiguous (.lnk через wscript/cmd/powershell без AUMID: только по имени).
function ConvertTo-PinnedCandidate {
    param($Pin, [System.Collections.Generic.List[string]]$Skipped = $null)
    $raw = [string]$Pin.Id
    if (Test-UrlTileId $raw) { return $null }
    $name = ''; $target = ''; $args2 = ''; $aumid = ''; $amb = $false
    $isLnk = ($raw -match '(?i)\.lnk$')
    if ($isLnk) {
        $p = Expand-PinnedPath $raw
        $li = Get-LnkInfo $(if ($p) { $p } else { $raw })
        $name = [string]$li.Name; $target = [string]$li.Target; $args2 = [string]$li.Args; $aumid = [string]$li.AppId
        if ($target -and (Test-LauncherHostName $target) -and -not $aumid) { $amb = $true }
    } elseif ($raw -match '(?i)\.exe$' -and (Test-LauncherHostName $raw)) {
        if ($null -ne $Skipped) { $Skipped.Add("$raw : общий хост (wscript/cmd/powershell) без других данных - пропущен") }
        return $null
    }
    return [pscustomobject]@{ Id = [string]$Pin.TileName; Name = $name; Source = 'pinned'; AppId = $raw; RawId = $raw; Pinned = $true; Aumid = $aumid; Target = $target; Args = $args2; Ambiguous = $amb; PinGroup = [string]$Pin.Group }
}

# Кандидаты из закреплённых: уже известные по Get-StartApps / CustomTiles id дополняются (Pinned, RawId), новые добавляются в $List / $Map. Пропущенные - в $Skipped.
function Add-PinnedCandidates {
    param($List, $Map, [System.Collections.Generic.List[string]]$Skipped = $null)
    $n = 0
    foreach ($pin in @(Get-PinnedTileIds)) {
        try {
            $c = ConvertTo-PinnedCandidate $pin $Skipped
            if (-not $c) { continue }
            if ($Map.ContainsKey($c.Id)) {
                $o = $Map[$c.Id]
                $o | Add-Member -NotePropertyName Pinned -NotePropertyValue $true -Force
                $o | Add-Member -NotePropertyName RawId -NotePropertyValue $c.RawId -Force
                if (-not [string]$o.Name -and $c.Name) { $o.Name = $c.Name }
                foreach ($pn in @('Aumid', 'Target', 'Args', 'Ambiguous')) { if (-not $o.PSObject.Properties[$pn]) { $o | Add-Member -NotePropertyName $pn -NotePropertyValue $c.$pn } }
                continue
            }
            $Map[$c.Id] = $c; $List.Add($c); $n++
        } catch { Write-Log ('  закреплённый элемент ' + [string]$pin.Id + ': ' + $_.Exception.Message) }
    }
    return $n
}

# Диагностика плитки Glyphix (журнал и тесты): закреплённые id с glyph/wscript, записи Get-StartApps про Glyphix, AUMID наших ярлыков, куда записана плитка.
# $Written - id значений CustomTiles, записанных для иконки glyphix. Возвращает { Lines; Pinned; StartApps; Shortcuts; Written }.
function Get-GlyphixTileDiagnostics {
    param($Candidates = $null, [string[]]$Written = @())
    $lines = [System.Collections.Generic.List[string]]::new()
    $pins = @(); try { $pins = @(Get-PinnedTileIds | Where-Object { $_.Id -match '(?i)glyph|wscript' }) } catch { }
    $apps = @(); try { if (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue) { $apps = @(Get-StartApps | Where-Object { $_ -and (([string]$_.Name -match '(?i)glyph') -or ([string]$_.AppID -match '(?i)glyph')) }) } } catch { }
    $lnks = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($p in @(Get-AppShortcutPaths)) {
            if (-not $p) { continue }
            $li = Get-LnkInfo $p
            $lnks.Add([pscustomobject]@{ Path = [string]$p; Exists = [bool]$li.Exists; AppId = [string]$li.AppId; Target = [string]$li.Target })
        }
    } catch { }
    $lines.Add('Диагностика плитки Glyphix:')
    if ($pins.Count -gt 0) { foreach ($p in $pins) { $lines.Add("  закреплённый id (группа $($p.Group)): $($p.Id)  -> имя в CustomTiles: $($p.TileName)") } } else { $lines.Add('  закреплённых элементов с glyph/wscript нет') }
    if ($apps.Count -gt 0) { foreach ($a in $apps) { $lines.Add("  Get-StartApps: '$($a.Name)' AppID '$($a.AppID)'") } } else { $lines.Add('  Get-StartApps: записей Glyphix нет') }
    foreach ($l in $lnks) { $lines.Add("  ярлык $($l.Path): " + $(if ($l.Exists) { "AUMID '" + $l.AppId + "', цель '" + $l.Target + "'" } else { 'нет файла' })) }
    if (@($Written).Count -gt 0) { $lines.Add("  плитка записана под id: " + (@($Written) -join ', ')) } else { $lines.Add('  плитка Glyphix не записана (нет кандидата для иконки glyphix)') }
    return [pscustomobject]@{ Lines = $lines.ToArray(); Pinned = $pins; StartApps = $apps; Shortcuts = $lnks.ToArray(); Written = @($Written) }
}

# ---------- Автоиконки варианта ----------
# Автоиконка варианта = обычная автоиконка пака-основы (Stylize по auto.json), к которой применяются операции варианта: иконке - ops для icons (kind icon),
# плитке - ops для tiles (kind tile; плитка рисуется с качеством 100, перекрашивается и сохраняется с качеством 92). Цвет {brand} для автоиконок - основной
# цвет auto.json пака (mid): у неизвестного приложения своего бренда нет. Ключ кэша автоиконки включает хэш операций.
function Get-AutoVariantOps {
    param($Variant)
    if ($null -eq $Variant) { return @() }
    if ($Variant.PSObject.Properties['Ops'] -and @($Variant.Ops).Count -gt 0) { return @($Variant.Ops) }
    return @()
}

function Get-AutoVariantKey {
    param($Variant)
    $ops = @(Get-AutoVariantOps $Variant)
    if ($ops.Count -eq 0) { return '' }
    return (Get-BytesSha256 ([System.Text.Encoding]::UTF8.GetBytes('r' + $script:SI_VariantRenderVersion + '|' + (ConvertTo-CanonicalJson $ops)))).Substring(0, 12)
}

function Get-AutoVariantBrand {
    param($Auto)
    if ($Auto -and $Auto.Mid) { return ([string]$Auto.Mid).ToUpperInvariant() }
    return '#7C5CFF'
}

# BGRA-иконка автоиконки (результат Stylize) -> BGRA после операций варианта (без операций - как есть)
function Invoke-AutoVariantOps {
    param([byte[]]$Bgra, $Variant, $Auto, [string]$Kind = 'icon')
    $ops = @(Get-AutoVariantOps $Variant)
    if ($ops.Count -eq 0) { return , $Bgra }
    [void](Initialize-VariantsNative)
    $rgba = [GlyphixVariants.Recolor]::SwapRB($Bgra)
    $o = [GlyphixVariants.Recolor]::Apply($rgba, (ConvertTo-VariantOps $ops), ($Kind -eq 'tile'), (ConvertTo-BrandRgb (Get-AutoVariantBrand $Auto)))
    return , [GlyphixVariants.Recolor]::SwapRB($o)
}

# JPEG плитки (качество 100 из RenderTile) -> JPEG качества 92 после операций варианта для плиток
function Invoke-AutoVariantTile {
    param([byte[]]$Jpeg, $Variant, $Auto)
    [void](Initialize-VariantsNative)
    $w = 0; $h = 0
    $rgba = [GlyphixVariants.Img]::Decode($Jpeg, [ref]$w, [ref]$h)
    $o = [GlyphixVariants.Recolor]::Apply($rgba, (ConvertTo-VariantOps @(Get-AutoVariantOps $Variant)), $true, (ConvertTo-BrandRgb (Get-AutoVariantBrand $Auto)))
    return , [GlyphixVariants.Codec]::EncodeJpeg($o, $w, $h, 92)
}

# ---------- Вспомогательное для плана ----------
# AppKey приложения для элемента-ярлыка / элемента-плитки: id иконки пака; приложения без иконки в паке (автоиконки) - 'auto:<ключ имени>'
function Get-ItemAppKey {
    param($M)
    if (-not $M) { return '' }
    if ($M.PSObject.Properties['Auto'] -and $M.Auto -and $M.PSObject.Properties['AutoKey'] -and [string]$M.AutoKey) { return ('auto:' + [string]$M.AutoKey) }
    if ($M.PSObject.Properties['IconId'] -and [string]$M.IconId) { return [string]$M.IconId }
    return ''
}

# пак-источник элемента: PackId элемента (иконка из другого варианта), иначе id применяемого пака
function Get-ItemPackId {
    param($M, $Pack)
    if ($M -and $M.PSObject.Properties['PackId'] -and [string]$M.PackId) { return [string]$M.PackId }
    return [string]$Pack.Id
}

# ---------- Режимы приложений (state.json: AppOverrides) и избранное ----------
# AppOverrides = { "<AppKey>": { "Icon": "skip|restore", "Tile": "skip|restore", "Source": "<id варианта>" } } - только отличия от умолчания (apply, без источника).
# AppKey: id иконки пака ('discord') или 'auto:<ключ имени>' для приложений без иконки в паке. Режим отдельно для иконки (ярлыки) и плитки Start11:
#   apply - применить вариант; skip - не трогать (как есть сейчас); restore - вернуть родную иконку из бэкапа.
# Миграция 2.x: AutoOverrides { <ключ имени>: Native | Off } -> AppOverrides['auto:<ключ>']: Авто -> apply, Родная -> restore, Не трогать -> skip (один раз, флаг AppOverridesMigrated).
$script:SI_AppModes = @('apply', 'skip', 'restore')
$script:SI_AppKeyRx = '^(auto:)?[\p{L}\p{Nd}_\-]{1,80}$'

function Get-AppModeName {
    param([string]$Mode)
    $m = ([string]$Mode).Trim().ToLowerInvariant()
    switch ($m) { 'auto' { return 'apply' } 'native' { return 'restore' } 'off' { return 'skip' } }
    if ($script:SI_AppModes -contains $m) { return $m }
    return $null
}

function ConvertTo-LegacyAutoMode {
    param([string]$Mode)
    switch ($Mode) { 'restore' { return 'Native' } 'skip' { return 'Off' } default { return 'Auto' } }
}

function ConvertFrom-AppOverrideState {
    param($Raw)
    $h = @{}
    if (-not $Raw) { return $h }
    $pairs = if ($Raw -is [System.Collections.IDictionary]) { @($Raw.Keys | ForEach-Object { @{ N = [string]$_; V = $Raw[$_] } }) } else { @($Raw.PSObject.Properties | ForEach-Object { @{ N = $_.Name; V = $_.Value } }) }
    foreach ($pr in $pairs) {
        if ($pr.N -notmatch $script:SI_AppKeyRx) { continue }
        $v = $pr.V
        $get = { param($k) if ($v -is [System.Collections.IDictionary]) { if ($v.Contains($k)) { return $v[$k] } else { return $null } } elseif ($v -and $v.PSObject.Properties[$k]) { return $v.PSObject.Properties[$k].Value } else { return $null } }
        $ic = Get-AppModeName ([string](& $get 'Icon')); $tl = Get-AppModeName ([string](& $get 'Tile'))
        $src = [string](& $get 'Source'); if ($src -notmatch $script:SI_IdRx) { $src = '' }
        if (-not $ic) { $ic = 'apply' }; if (-not $tl) { $tl = 'apply' }
        if ($ic -eq 'apply' -and $tl -eq 'apply' -and -not $src) { continue }
        $h[$pr.N] = [pscustomobject]@{ Icon = $ic; Tile = $tl; Source = $(if ($src) { $src } else { $null }) }
    }
    return $h
}

function ConvertTo-AppOverrideState {
    param($Map)
    $o = [ordered]@{}
    foreach ($k in @($Map.Keys | Sort-Object)) {
        $e = $Map[$k]
        $d = [ordered]@{}
        if ($e.Icon -ne 'apply') { $d['Icon'] = $e.Icon }
        if ($e.Tile -ne 'apply') { $d['Tile'] = $e.Tile }
        if ($e.Source) { $d['Source'] = $e.Source }
        if ($d.Count -gt 0) { $o[$k] = $d }
    }
    return $o
}

# Режимы всех приложений, отличающиеся от умолчания: ключ -> { Icon; Tile; Source }. Первое чтение переносит прежние AutoOverrides.
function Get-AppOverrides {
    param($State = $null)
    $persist = ($null -eq $State)
    if ($null -eq $State) { $State = Read-State }
    $h = ConvertFrom-AppOverrideState $(if ($State.ContainsKey('AppOverrides')) { $State['AppOverrides'] } else { $null })
    if (-not ($State.ContainsKey('AppOverridesMigrated') -and $State['AppOverridesMigrated'])) {
        $leg = Get-AutoOverrides $State
        $changed = $false
        foreach ($k in @($leg.Keys)) {
            $ak = 'auto:' + $k
            if ($ak -notmatch $script:SI_AppKeyRx -or $h.ContainsKey($ak)) { continue }
            $m = if ($leg[$k] -eq 'Native') { 'restore' } elseif ($leg[$k] -eq 'Off') { 'skip' } else { 'apply' }
            if ($m -eq 'apply') { continue }
            $h[$ak] = [pscustomobject]@{ Icon = $m; Tile = $m; Source = $null }; $changed = $true
        }
        if ($persist) {
            $st = Read-State
            if ($changed -or $leg.Count -gt 0 -or $st.ContainsKey('AutoOverrides')) {
                $o = ConvertTo-AppOverrideState $h
                if ($o.Count -gt 0) { $st['AppOverrides'] = $o }
                $st['AppOverridesMigrated'] = $true
                Save-State $st
                if ($changed) { Write-Log "Режимы приложений перенесены из AutoOverrides: $(@($leg.Keys).Count)" }
            }
        }
    }
    return $h
}

# Изменить режимы приложения. Заданные параметры меняются, остальные остаются. -Source '' снимает источник. Всё по умолчанию - запись удаляется.
function Set-AppOverride {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$AppKey, [string]$Icon, [string]$Tile, [string]$Source)
    if ($AppKey -notmatch $script:SI_AppKeyRx) { throw "неверный ключ приложения '$AppKey'" }
    $st = Read-State
    $h = Get-AppOverrides -State $st
    $cur = if ($h.ContainsKey($AppKey)) { $h[$AppKey] } else { [pscustomobject]@{ Icon = 'apply'; Tile = 'apply'; Source = $null } }
    $ic = $cur.Icon; $tl = $cur.Tile; $src = $cur.Source
    if ($PSBoundParameters.ContainsKey('Icon')) { $ic = Get-AppModeName $Icon; if (-not $ic) { throw "неизвестный режим иконки '$Icon' (apply | skip | restore)" } }
    if ($PSBoundParameters.ContainsKey('Tile')) { $tl = Get-AppModeName $Tile; if (-not $tl) { throw "неизвестный режим плитки '$Tile' (apply | skip | restore)" } }
    if ($PSBoundParameters.ContainsKey('Source')) {
        if ($Source -and $Source -notmatch $script:SI_IdRx) { throw "неверный id варианта '$Source'" }
        $src = $(if ($Source) { $Source } else { $null })
    }
    if ($ic -eq 'apply' -and $tl -eq 'apply' -and -not $src) { [void]$h.Remove($AppKey) } else { $h[$AppKey] = [pscustomobject]@{ Icon = $ic; Tile = $tl; Source = $src } }
    $o = ConvertTo-AppOverrideState $h
    if ($o.Count -eq 0) { [void]$st.Remove('AppOverrides') } else { $st['AppOverrides'] = $o }
    $st['AppOverridesMigrated'] = $true
    if ($AppKey.StartsWith('auto:')) {                       # приложения без иконки в паке: то же видят и функции 2.x (Get-AutoOverrides)
        $leg = Get-AutoOverrides $st
        $lk = $AppKey.Substring(5)
        $lm = if ($ic -ne 'apply') { ConvertTo-LegacyAutoMode $ic } elseif ($tl -ne 'apply') { ConvertTo-LegacyAutoMode $tl } else { 'Auto' }
        if ($lm -eq 'Auto') { [void]$leg.Remove($lk) } else { $leg[$lk] = $lm }
        if ($leg.Count -eq 0) { [void]$st.Remove('AutoOverrides') } else { $st['AutoOverrides'] = $leg }
    }
    Save-State $st
}

# Прежний Set-AutoOverride -> AppOverrides (иконка и плитка получают один режим)
function Sync-AppOverrideFromLegacy {
    param([string]$LegacyKey, [string]$CanonMode)
    $ak = 'auto:' + $LegacyKey
    if ($ak -notmatch $script:SI_AppKeyRx) { return }
    $m = if ($CanonMode -eq 'Native') { 'restore' } elseif ($CanonMode -eq 'Off') { 'skip' } else { 'apply' }
    $st = Read-State
    $h = Get-AppOverrides -State $st
    $src = if ($h.ContainsKey($ak)) { $h[$ak].Source } else { $null }
    if ($m -eq 'apply' -and -not $src) { [void]$h.Remove($ak) } else { $h[$ak] = [pscustomobject]@{ Icon = $m; Tile = $m; Source = $src } }
    $o = ConvertTo-AppOverrideState $h
    if ($o.Count -eq 0) { [void]$st.Remove('AppOverrides') } else { $st['AppOverrides'] = $o }
    $st['AppOverridesMigrated'] = $true
    Save-State $st
}

# ---------- Избранные варианты (state.json: Favorites - упорядоченный список id) ----------
function Get-Favorites {
    $out = [System.Collections.Generic.List[string]]::new()
    try {
        $st = Read-State
        if ($st.ContainsKey('Favorites') -and $st['Favorites']) {
            foreach ($f in @($st['Favorites'])) { $id = [string]$f; if ($id -match $script:SI_IdRx -and -not $out.Contains($id)) { $out.Add($id) } }
        }
    } catch { }
    return $out.ToArray()
}

# Set-Favorite <id> <bool>: добавить (в конец; -Position - на место, с 0) или убрать. Возвращает новый список.
function Set-Favorite {
    [CmdletBinding()]
    param([Parameter(Mandatory, Position = 0)][string]$VariantId, [Parameter(Mandatory, Position = 1)][bool]$On, [int]$Position = -1)
    if ($VariantId -notmatch $script:SI_IdRx) { throw "неверный id варианта '$VariantId'" }
    $list = [System.Collections.Generic.List[string]]::new()
    foreach ($f in @(Get-Favorites)) { $list.Add($f) }
    if ($On) {
        if (-not $list.Contains($VariantId) -or $Position -ge 0) {
            [void]$list.Remove($VariantId)
            if ($Position -ge 0 -and $Position -lt $list.Count) { $list.Insert($Position, $VariantId) } else { $list.Add($VariantId) }
        }
    } else { [void]$list.Remove($VariantId) }
    $st = Read-State
    if ($list.Count -eq 0) { [void]$st.Remove('Favorites') } else { $st['Favorites'] = @($list.ToArray()) }
    Save-State $st
    return $list.ToArray()
}

# применённый сейчас вариант (state.json Applied): id варианта; у 2.x - id пака
function Get-AppliedVariantId {
    try {
        $st = Read-State
        if ($st.ContainsKey('Applied') -and $st['Applied']) {
            $a = $st['Applied']
            if ($a.PSObject.Properties['VariantId'] -and [string]$a.VariantId) { return [string]$a.VariantId }
            return [string]$a.PackId
        }
    } catch { }
    return ''
}

function Get-AppliedVariantKey {
    param([string]$VariantId)
    try {
        $st = Read-State
        if ($st.ContainsKey('Applied') -and $st['Applied']) {
            $a = $st['Applied']
            if ($a.PSObject.Properties['VariantId'] -and [string]$a.VariantId -eq $VariantId -and $a.PSObject.Properties['CacheKey']) { return [string]$a.CacheKey }
        }
    } catch { }
    return ''
}

# ---------- План по приложениям ----------
$script:SI_LocationCodes = @{ start = 'Start'; taskbar = 'Taskbar'; desktop = 'Desktop'; start_all = 'CommonStart'; desktop_all = 'CommonDesktop' }
$script:SI_LocationLabels = @{ Start = 'Пуск'; Taskbar = 'Панель задач'; Desktop = 'Рабочий стол'; CommonStart = 'Пуск (все пользователи)'; CommonDesktop = 'Рабочий стол (все пользователи)'; Start11Tile = 'Плитка Start11' }
$script:SI_LocationOrder = @('Start', 'Taskbar', 'Desktop', 'CommonStart', 'CommonDesktop', 'Start11Tile')

function Get-PlanOptions {
    param($O)
    $r = @{ AllUsers = $false; Tiles = $null; NoName = $false; Auto = $null; Render = $true; Sync = $true }
    if ($O) {
        if ($O -is [System.Collections.IDictionary]) { foreach ($k in @($O.Keys)) { if ($r.ContainsKey([string]$k)) { $r[[string]$k] = $O[$k] } } }
        else { foreach ($p in $O.PSObject.Properties) { if ($r.ContainsKey($p.Name)) { $r[$p.Name] = $p.Value } } }
    }
    if ($null -eq $r.Tiles) { $r.Tiles = [bool](Test-Start11) }
    if ($null -eq $r.Auto) { $r.Auto = [bool](Get-AutoEnabled) }
    foreach ($k in @('AllUsers', 'Tiles', 'NoName', 'Auto', 'Render', 'Sync')) { $r[$k] = [bool]$r[$k] }
    return $r
}

# id варианта, чья папка содержит файл (applied\<id>\, auto\<id>\, start11\<id>\); '' - файл не наш
function Get-OurPathVariant {
    param([string]$Path)
    try {
        $full = Get-NormalPath $Path
        if (-not $full) { return '' }
        foreach ($d in @($script:SI_AppliedDir, $script:SI_AutoDir, $script:SI_S11Dir)) {
            $root = Get-NormalPath $d
            if ($root -and (Test-PathUnder $full $root)) {
                $seg = ($full.Substring($root.Length).TrimStart($script:SI_Seps)).Split($script:SI_Seps)[0]
                if ($seg -match $script:SI_IdRx) { return $seg }
            }
        }
    } catch { }
    return ''
}

# Состояние иконки ярлыка: 'ours:<вариант>' | 'native' | 'other' (своя иконка: .ico/.png вне папки приложения и не наша)
function Get-LinkIconState {
    param([string]$Icon, [string]$Target = '', [bool]$HasBackup = $false)
    $loc = Split-IconLocation ([Environment]::ExpandEnvironmentVariables([string]$Icon))
    $path = ([string]$loc.Path).Trim('"')
    if ($path) {
        $v = Get-OurPathVariant $path
        if ($v) { return ('ours:' + $v) }
    }
    if ($HasBackup) { return 'other' }                        # мы меняли этот ярлык, но иконка теперь не наша: кто-то поменял после нас
    if (-not $path) { return 'native' }
    if ($path -match '(?i)\.(exe|dll|icl|mun|cpl|scr)$') { return 'native' }
    if ($path -match '(?i)\.(ico|png|jpe?g|bmp)$') {
        try {
            $t = [Environment]::ExpandEnvironmentVariables([string]$Target)
            if ($t) {
                $pd = [IO.Path]::GetDirectoryName($path.Replace('\', '/')); $td = [IO.Path]::GetDirectoryName($t.Replace('\', '/'))
                if ($pd -and $td -and ((($pd.TrimEnd('/') + '/').StartsWith($td.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)) -or (($td.TrimEnd('/') + '/').StartsWith($pd.TrimEnd('/') + '/', [StringComparison]::OrdinalIgnoreCase)))) { return 'native' }
            }
        } catch { }
        return 'other'
    }
    return 'native'
}

function Get-TileState {
    param([string]$TileId)
    $v = $null
    try { $v = Get-S11Value $script:SI_S11Tiles $TileId } catch { return 'other' }
    if ($null -eq $v -or $v -eq '') { return 'native' }
    $ov = Get-OurPathVariant $v
    if ($ov) { return ('ours:' + $ov) }
    return 'other'
}

function Merge-AppState {
    param([string[]]$States)
    foreach ($s in @($States)) { if ($s -like 'ours:*') { return $s } }
    foreach ($s in @($States)) { if ($s -eq 'other') { return 'other' } }
    return 'native'
}

# План применения варианта: по записи на приложение (ярлыки и плитки Start11, найденные по одной иконке пака / одному приложению, собраны вместе).
#  AppKey, Name, IconId, Group, Rank, Auto (иконки нет в паке - автоиконка), Variant (откуда иконка: Source или $VariantId), Source (переопределение или $null),
#  Before (IconLocation исходной иконки: из бэкапа, если мы её меняли), BeforeKind (native|other), BeforeTarget (цель ярлыка - для получения иконки оболочкой),
#  After (PNG новой иконки), AfterReady, AfterTile (плитка), AfterTileReady,
#  Locations [{Code, Label, Count}] (Start, Taskbar, Desktop, CommonStart, CommonDesktop, Start11Tile), Shortcuts[], Tiles[],
#  IconState / TileState (native | ours:<вариант> | other), IsCurrent, IconMode / TileMode (apply | skip | restore).
# -Options: AllUsers, Tiles (по умолчанию - есть Start11), NoName, Auto (по умолчанию - включены в настройках), Render (рисовать PNG превью нужных приложений, по умолчанию да),
# Sync (докачать пак-основу, по умолчанию да). -Shortcuts / -Candidates - уже прочитанные списки (иначе читаются заново).
function Get-AppPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariantId, $Options = $null, $Shortcuts = $null, $Candidates = $null, [scriptblock]$OnProgress = $null)
    $o = Get-PlanOptions $Options
    $vp = Resolve-VariantPack -VariantId $VariantId -Parts @() -NoSync:(-not $o.Sync)
    $links = @(Get-Matches -Pack $vp -Shortcuts $Shortcuts -AllUsers:$o.AllUsers -Auto:$o.Auto -Overrides @{})
    $tiles = @()
    if ($o.Tiles) { $tiles = @(Get-Start11Matches -Pack $vp -Candidates $Candidates -NoName:$o.NoName -Auto:$o.Auto -Overrides @{}) }
    $by = @{}
    $order = [System.Collections.Generic.List[string]]::new()
    $touch = {
        param($M, [bool]$IsTile)
        $k = Get-ItemAppKey $M
        if (-not $k) { return }
        if (-not $by.ContainsKey($k)) {
            $auto = [bool]($M.PSObject.Properties['Auto'] -and $M.Auto)
            $by[$k] = [pscustomobject]@{ AppKey = $k; Name = $(if ($auto) { [string]$M.Name } else { [string]$M.IconName }); IconId = $(if ($auto) { '' } else { [string]$M.IconId }); Group = [string]$M.Group; Auto = $auto
                Sh = ([System.Collections.Generic.List[object]]::new()); Ti = ([System.Collections.Generic.List[object]]::new()) }
            $order.Add($k)
        }
        if ($IsTile) { $by[$k].Ti.Add($M) } else { $by[$k].Sh.Add($M) }
    }
    foreach ($m in $links) { & $touch $m $false }
    foreach ($m in $tiles) { & $touch $m $true }
    $ov = Get-AppOverrides
    # приложения с источником - другим вариантом: его иконки (пак-основа качается при необходимости)
    $srcIds = @{}
    foreach ($k in $order) {
        $e = $by[$k]
        if ($e.Auto -or -not $ov.ContainsKey($k) -or -not $ov[$k].Source -or $ov[$k].Source -eq $VariantId) { continue }
        if (-not $srcIds.ContainsKey($ov[$k].Source)) { $srcIds[$ov[$k].Source] = [System.Collections.Generic.List[string]]::new() }
        $srcIds[$ov[$k].Source].Add($e.IconId)
    }
    $partsR = if ($o.Render) { @('png') } else { @() }
    $srcIcons = @{}; $srcPackId = @{}
    foreach ($sv in @($srcIds.Keys)) {
        try {
            $sp = Resolve-VariantPack -VariantId $sv -IconIds $srcIds[$sv].ToArray() -Parts $partsR -NoSync:(-not $o.Sync)
            $srcIcons[$sv] = @{}; foreach ($ic in @($sp.Icons)) { $srcIcons[$sv][[string]$ic.Id] = $ic }
            $srcPackId[$sv] = [string]$sp.Id
        } catch { Write-Log ("  источник '$sv' недоступен: " + $_.Exception.Message) }
    }
    $mainIcons = @{}
    $ids = @($order | ForEach-Object { $by[$_] } | Where-Object { -not $_.Auto -and $_.IconId } | ForEach-Object { $_.IconId } | Select-Object -Unique)
    $rp = if ($o.Render -and $ids.Count -gt 0) { Resolve-VariantPack -VariantId $VariantId -IconIds $ids -Parts @('png') -NoSync -OnProgress $OnProgress } else { $vp }
    foreach ($ic in @($rp.Icons)) { $mainIcons[[string]$ic.Id] = $ic }
    $backup = @{}; try { $backup = Load-Backup } catch { }
    $s11bk = @{}; try { $s11bk = Load-S11Backup } catch { }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($k in $order) {
        $e = $by[$k]
        $ovE = if ($ov.ContainsKey($k)) { $ov[$k] } else { $null }
        $src = if ($ovE -and $ovE.Source) { [string]$ovE.Source } else { $null }
        $eff = $VariantId; $effPack = [string]$vp.Id; $ico = $null; $srcMissing = $false
        if (-not $e.Auto) {
            $ico = $mainIcons[$e.IconId]
            if ($src -and $src -ne $VariantId) {
                if ($srcIcons.ContainsKey($src) -and $srcIcons[$src].ContainsKey($e.IconId)) { $ico = $srcIcons[$src][$e.IconId]; $eff = $src; $effPack = $srcPackId[$src] }
                else { $srcMissing = $true }
            }
        }
        foreach ($m in $e.Sh) {
            $m | Add-Member -NotePropertyName ModeSet -NotePropertyValue $true -Force
            if ($ico) {
                $m.IcoPath = [string]$ico.IcoPath; $m.PngPath = [string]$ico.PngPath
                $m | Add-Member -NotePropertyName PackId -NotePropertyValue $effPack -Force
                $m.AppliedPath = Get-AppliedIconDest $effPack $e.IconId ([string]$ico.IcoPath)
                $m.Already = [bool]($m.AppliedPath -and (Test-IconIsSet ([string]$m.Icon) $m.AppliedPath))
            }
        }
        foreach ($m in $e.Ti) {
            $m | Add-Member -NotePropertyName ModeSet -NotePropertyValue $true -Force
            if ($ico) {
                $ts = if ($o.NoName -and $ico.TileNoNamePath) { [string]$ico.TileNoNamePath } else { [string]$ico.TilePath }
                if ($ts) {
                    $m.TilePath = $ts
                    $m | Add-Member -NotePropertyName PackId -NotePropertyValue $effPack -Force
                    $m.Already = [bool](Test-Start11TileSet ([string]$m.TileId) (Get-Start11TileDest $effPack $e.IconId $ts) $ts)
                }
            }
        }
        # где лежат
        $locCount = @{}
        foreach ($m in $e.Sh) { $c = $script:SI_LocationCodes[[string]$m.Location]; if (-not $c) { $c = 'Start' }; $locCount[$c] = 1 + [int]$locCount[$c] }
        if ($e.Ti.Count -gt 0) { $locCount['Start11Tile'] = $e.Ti.Count }
        $locs = @($script:SI_LocationOrder | Where-Object { $locCount.ContainsKey($_) } | ForEach-Object { [pscustomobject]@{ Code = $_; Label = [string]$script:SI_LocationLabels[$_]; Count = [int]$locCount[$_] } })
        # было / станет
        $first = $e.Sh.ToArray() | Select-Object -First 1
        $before = ''; $bkind = 'native'; $btarget = ''
        if ($first) {
            $bk = $backup[[string]$first.Path]
            $before = if ($bk -and $null -ne $bk.Icon) { [string]$bk.Icon } else { [string]$first.Icon }
            $btarget = [string]$first.Target
            $bkind = (Get-LinkIconState $before $btarget $false)
            if ($bkind -like 'ours:*') { $bkind = 'native' }
        } elseif ($e.Ti.Count -gt 0) {
            $t0 = $e.Ti[0]; $tb = $s11bk[[string]$t0.TileId]
            if ($tb) { $before = $(if ($tb.Absent) { '' } else { [string]$tb.Data }) } else { try { $before = [string](Get-S11Value $script:SI_S11Tiles ([string]$t0.TileId)) } catch { } }
            $bkind = $(if ($before) { 'other' } else { 'native' })
        }
        $after = $null; $afterTile = $null
        if ($e.Auto) { $a0 = $e.Sh.ToArray() | Select-Object -First 1; if ($a0) { $after = [string]$a0.PngPath }; $a1 = $e.Ti.ToArray() | Select-Object -First 1; if ($a1) { $afterTile = [string]$a1.TilePath } }
        elseif ($ico) { $after = [string]$ico.PngPath; $afterTile = $(if ($o.NoName -and $ico.TileNoNamePath) { [string]$ico.TileNoNamePath } else { [string]$ico.TilePath }) }
        $iState = Merge-AppState @($e.Sh | ForEach-Object { Get-LinkIconState ([string]$_.Icon) ([string]$_.Target) ([bool]$backup.ContainsKey([string]$_.Path)) })
        $tState = Merge-AppState @($e.Ti | ForEach-Object { Get-TileState ([string]$_.TileId) })
        $want = 'ours:' + $eff
        $cur = ((($e.Sh.Count -eq 0) -or $iState -eq $want) -and (($e.Ti.Count -eq 0) -or $tState -eq $want))
        $out.Add([pscustomobject]@{
            AppKey = $k; Name = $e.Name; IconId = $e.IconId; Group = $e.Group; Rank = (Get-GroupRank (Get-GroupKey $e.Group)); Auto = $e.Auto
            Variant = $eff; Source = $src; SourceMissing = $srcMissing
            Before = $before; BeforeKind = $bkind; BeforeTarget = $btarget
            After = $after; AfterReady = [bool]($after -and (Test-Path -LiteralPath $after -PathType Leaf)); AfterTile = $afterTile; AfterTileReady = [bool]($afterTile -and (Test-Path -LiteralPath $afterTile -PathType Leaf))
            Locations = $locs; ShortcutCount = $e.Sh.Count; TileCount = $e.Ti.Count; Shortcuts = $e.Sh.ToArray(); Tiles = $e.Ti.ToArray()
            IconState = $iState; TileState = $tState; IsCurrent = [bool]$cur
            IconMode = $(if ($ovE) { [string]$ovE.Icon } else { 'apply' }); TileMode = $(if ($ovE) { [string]$ovE.Tile } else { 'apply' })
        })
    }
    $res = @($out | Sort-Object @{ Expression = { $_.Rank } }, @{ Expression = { $_.Name } })
    Write-Log ("План '$VariantId': приложений $($res.Count), ярлыков $($links.Count), плиток $($tiles.Count)")
    return $res
}

# ---------- Применение плана ----------
# Применить план (Get-AppPlan) с учётом режимов: apply - иконка / плитка варианта (или источника, если задан), restore - вернуть родную из бэкапа, skip - не трогать.
# Рисуются только нужные иконки нужных вариантов. -Plan не задан - строится заново. Возвращает { Variant; Icons (Apply-Pack); Tiles (Apply-Start11Tiles);
# RestoredShortcuts; RestoredTiles; Skipped; Changed; Same; Failed }.
function Apply-Plan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VariantId, $Plan = $null, $Options = $null, [switch]$RestartExplorer, [switch]$NoReload, [scriptblock]$OnProgress = $null)
    Assert-ElevationSafe
    Assert-LegacyMigrationComplete
    $o = Get-PlanOptions $Options
    if ($null -eq $Plan) { $Plan = @(Get-AppPlan -VariantId $VariantId -Options $o -OnProgress $OnProgress) }
    $Plan = @($Plan)
    $iconApply = [System.Collections.Generic.List[object]]::new(); $tileApply = [System.Collections.Generic.List[object]]::new()
    $restoreLinks = [System.Collections.Generic.List[string]]::new(); $restoreTiles = [System.Collections.Generic.List[string]]::new()
    $skipped = 0
    $need = @{}
    $needOf = { param([string]$v) if (-not $need.ContainsKey($v)) { $need[$v] = @{ Ids = @{}; Icons = $false; Tiles = $false } }; return $need[$v] }
    foreach ($e in $Plan) {
        $eff = if ($e.Variant) { [string]$e.Variant } else { $VariantId }
        if (@($e.Shortcuts).Count -gt 0) {
            switch ([string]$e.IconMode) {
                'apply' { foreach ($m in @($e.Shortcuts)) { $iconApply.Add($m) }; if (-not $e.Auto) { $n = & $needOf $eff; $n.Ids[[string]$e.IconId] = $true; $n.Icons = $true } }
                'restore' { foreach ($m in @($e.Shortcuts)) { $restoreLinks.Add([string]$m.Path) } }
                default { $skipped++ }
            }
        }
        if ($o.Tiles -and @($e.Tiles).Count -gt 0) {
            switch ([string]$e.TileMode) {
                'apply' { foreach ($m in @($e.Tiles)) { $tileApply.Add($m) }; if (-not $e.Auto) { $n = & $needOf $eff; $n.Ids[[string]$e.IconId] = $true; $n.Tiles = $true } }
                'restore' { foreach ($m in @($e.Tiles)) { $restoreTiles.Add([string]$m.TileId) } }
                default { $skipped++ }
            }
        }
    }
    $res = [pscustomobject]@{ Variant = $VariantId; Icons = $null; Tiles = $null; RestoredShortcuts = 0; RestoredTiles = 0; Skipped = $skipped; Changed = 0; Same = 0; Failed = 0; Rendered = 0; RenderFailed = @() }
    # нужные иконки / плитки нужных вариантов (по умолчанию - ничего лишнего)
    [void](& $needOf $VariantId)
    $packs = @{}; $renderFailed = [System.Collections.Generic.List[object]]::new()
    foreach ($v in @($need.Keys)) {
        $n = $need[$v]
        $parts = @(); if ($n.Icons) { $parts += 'icons' }; if ($n.Tiles) { $parts += $(if ($o.NoName) { 'noname' } else { 'tiles' }) }
        $pk = Resolve-VariantPack -VariantId $v -IconIds @($n.Ids.Keys) -Parts $parts -OnProgress $OnProgress -NoSync:(-not $o.Sync)
        $packs[$v] = $pk
        $res.Rendered += [int]$pk.Rendered
        foreach ($f in @($pk.Failed)) { $renderFailed.Add($f) }
    }
    $res.RenderFailed = $renderFailed.ToArray()
    $main = $packs[$VariantId]
    $repoint = {
        param($Items)
        $keep = [System.Collections.Generic.List[object]]::new()
        foreach ($m in @($Items)) {
            if (Test-AutoItem $m) { $keep.Add($m); continue }
            $v = if ($m.PSObject.Properties['PackId'] -and [string]$m.PackId) { [string]$m.PackId } else { $VariantId }
            $pk = $packs[$v]; if (-not $pk) { foreach ($k in @($packs.Keys)) { if ([string]$packs[$k].Id -eq $v) { $pk = $packs[$k] } } }
            $ic = if ($pk) { @($pk.Icons | Where-Object { [string]$_.Id -eq [string]$m.IconId }) | Select-Object -First 1 } else { $null }
            if ($ic) {
                if ($m.PSObject.Properties['IcoPath']) { $m.IcoPath = [string]$ic.IcoPath; $m.PngPath = [string]$ic.PngPath }
                if ($m.PSObject.Properties['TileId']) { $m.TilePath = $(if ($o.NoName -and $ic.TileNoNamePath) { [string]$ic.TileNoNamePath } else { [string]$ic.TilePath }) }
            }
            $keep.Add($m)
        }
        return $keep.ToArray()
    }
    $failedPre = 0
    # 1) вернуть родное
    if ($restoreLinks.Count -gt 0) {
        $rr = Restore-AppShortcuts -Paths $restoreLinks.ToArray()
        $res.RestoredShortcuts = [int]$rr.Restored; $failedPre += [int]$rr.Failed
    }
    # 2) применить иконки
    $iconItems = @(& $repoint $iconApply.ToArray() | Where-Object { $_ })
    if ($iconItems.Count -gt 0) {
        $ar = Apply-Pack -Pack $main -Items $iconItems -RestartExplorer:$RestartExplorer -NoAuto:(-not $o.Auto)
        $res.Icons = $ar; $res.Changed += [int]$ar.Changed; $res.Same += [int]$ar.Same; $res.Failed += [int]$ar.Failed
    } elseif ($res.RestoredShortcuts -gt 0) { Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true }
    # 3) плитки Start11
    $tileItems = @(& $repoint $tileApply.ToArray() | Where-Object { $_ })
    if ($tileItems.Count -gt 0) {
        $tr = Apply-Start11Tiles -Pack $main -Items $tileItems -NoName:$o.NoName -NoReload:$NoReload -NoAuto:(-not $o.Auto)
        $res.Tiles = $tr; $res.Changed += [int]$tr.Changed; $res.Same += [int]$tr.Same; $res.Failed += [int]$tr.Failed
    }
    if ($restoreTiles.Count -gt 0) {
        $ut = Undo-Start11Tiles -NoReload:$NoReload -Ids $restoreTiles.ToArray()
        $res.RestoredTiles = [int]$ut.Restored; $failedPre += [int]$ut.Failed
    }
    $res.Failed += $failedPre + @($renderFailed | Where-Object { $_.Kind -eq 'icon' -or $_.Kind -eq 'tile' }).Count
    Write-Log ("План применён ($VariantId): изменено $($res.Changed), уже стояли $($res.Same), возвращено родных: $($res.RestoredShortcuts + $res.RestoredTiles), пропущено приложений: $skipped, ошибок: $($res.Failed)")
    return $res
}

# ---------- Частичный откат ----------
# Вернуть исходную иконку только указанных ярлыков (записи бэкапа удаляются; остальное в бэкапе остаётся для общего отката). Общие ярлыки без прав
# администратора не трогаем (CommonPending). Возвращает { Restored; NoBackup; Failed; CommonPending }.
function Restore-AppShortcuts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Paths, [string[]]$AppKeys = @())
    Assert-ElevationSafe
    $r = [pscustomobject]@{ Restored = 0; NoBackup = 0; Failed = 0; CommonPending = 0 }
    $backup = Load-Backup
    $commonRoots = @(Get-CommonRootPaths)
    $origIco = @{}
    $keys = @{}; foreach ($k in @($AppKeys)) { $keys[[string]$k] = $true }
    foreach ($path in @($Paths | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not $backup.ContainsKey($path)) { $r.NoBackup++; continue }
        if ((Test-CommonPath $path $commonRoots) -and -not (Test-Admin)) { $r.CommonPending++; continue }
        $e = $backup[$path]; $copy = [string]$e.Copy
        $bad = Test-BackupEntry $path $copy
        if ($bad) { Write-Log "  запись бэкапа отклонена ($bad): $path"; $backup.Remove($path); continue }
        try {
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Write-Log "  ярлык удалён, не воскрешаю: $(Get-BaseNameSafe $path)"; Remove-CopyQuiet $copy; $backup.Remove($path); continue }
            $loc = $e.Icon
            if ($null -eq $loc) {
                if (-not (Test-Path -LiteralPath $copy)) { Write-Log "  нет копии для $path - пропускаю"; $backup.Remove($path); continue }
                $loc = [string](Get-WshShell).CreateShortcut($copy).IconLocation
            }
            $sp = Split-IconLocation $loc
            [void](Set-LinkIcon $path $sp.Path $sp.Index)
            if ($sp.Path) { try { $origIco[[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($sp.Path.Trim('"'))).ToLowerInvariant()] = $true } catch { } }
            if ($e.AppKey) { $keys[[string]$e.AppKey] = $true }
            Remove-CopyQuiet $copy
            Send-ItemNotify $path
            $backup.Remove($path); $r.Restored++
            Write-Log "  возвращён: $(Get-BaseNameSafe $path)"
        } catch { $r.Failed++; Write-Log "  ошибка с $path : $($_.Exception.Message)" }
    }
    # подменённые .ico самого приложения (Apply-Pack подменяет файл иконки, на который смотрел ярлык): возвращаем те, что относятся к этим приложениям
    foreach ($path in @($backup.Keys)) {
        if ([IO.Path]::GetExtension($path) -ine '.ico') { continue }
        $e = $backup[$path]
        $mine = ($e.AppKey -and $keys.ContainsKey([string]$e.AppKey))
        if (-not $mine) { try { $mine = $origIco.ContainsKey([IO.Path]::GetFullPath($path).ToLowerInvariant()) } catch { } }
        if (-not $mine) { continue }
        $copy = [string]$e.Copy
        $bad = Test-BackupEntry $path $copy
        if ($bad) { $backup.Remove($path); continue }
        try {
            if ((Test-Path -LiteralPath $copy) -and (Test-Path -LiteralPath ([IO.Path]::GetDirectoryName($path)))) { Copy-Item -LiteralPath $copy -Destination $path -Force; Send-ItemNotify $path; Write-Log "  возвращён файл иконки: $(Split-Path $path -Leaf)" }
            Remove-CopyQuiet $copy; $backup.Remove($path)
        } catch { $r.Failed++; Write-Log "  ошибка с $path : $($_.Exception.Message)" }
    }
    Save-Backup $backup
    return $r
}

# Откат выбранных приложений (по AppKey плана): ярлыки (-Icon) и/или плитки Start11 (-Tile); без обоих флагов - и то, и другое. Остальное в бэкапе остаётся:
# полный Undo-All потом возвращает его же. Записи бэкапа, сделанные до 3.0 (без AppKey), находятся по плану (-VariantId; по умолчанию применённый вариант).
# Возвращает { Restored (ярлыков); TilesRestored; Failed; CommonPending; Nothing; Hint }.
function Undo-Apps {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$AppKeys, [switch]$Icon, [switch]$Tile, [string]$VariantId = '', $Plan = $null, [switch]$NoReload, [switch]$RestartExplorer)
    Assert-ElevationSafe
    $doIcon = ($Icon -or -not $Tile); $doTile = ($Tile -or -not $Icon)
    $keys = @{}; foreach ($k in @($AppKeys)) { if ($k) { $keys[[string]$k] = $true } }
    $res = [pscustomobject]@{ Restored = 0; TilesRestored = 0; Failed = 0; CommonPending = 0; Nothing = $true; Hint = ''; Keys = @($keys.Keys) }
    $backup = Load-Backup
    $s11 = Load-S11Backup
    $paths = [System.Collections.Generic.List[string]]::new()
    $tileIds = [System.Collections.Generic.List[string]]::new()
    $legacy = $false
    foreach ($p in @($backup.Keys)) { $ak = [string]$backup[$p].AppKey; if ($ak -and $keys.ContainsKey($ak)) { $paths.Add($p) } elseif (-not $ak) { $legacy = $true } }
    foreach ($i in @($s11.Keys)) { $ak = [string]$s11[$i].AppKey; if ($ak -and $keys.ContainsKey($ak)) { $tileIds.Add($i) } elseif (-not $ak) { $legacy = $true } }
    if ($legacy -and $null -eq $Plan) {
        try {
            $vid = $VariantId; if (-not $vid) { $vid = Get-AppliedVariantId }
            $wantAuto = (@($keys.Keys | Where-Object { ([string]$_).StartsWith('auto:') }).Count -gt 0)       # записи 2.x автоиконок находятся только планом с автоиконками
            if ($vid) { $Plan = @(Get-AppPlan -VariantId $vid -Options @{ AllUsers = $true; Render = $false; Sync = $false; Auto = $wantAuto }) }
        } catch { Write-Log ('  частичный откат: записи без AppKey не сопоставлены (' + $_.Exception.Message + ')') }
    }
    foreach ($e in @($Plan)) {
        if (-not $keys.ContainsKey([string]$e.AppKey)) { continue }
        foreach ($m in @($e.Shortcuts)) { if ($backup.ContainsKey([string]$m.Path) -and -not $paths.Contains([string]$m.Path)) { $paths.Add([string]$m.Path) } }
        foreach ($m in @($e.Tiles)) { if ($s11.ContainsKey([string]$m.TileId) -and -not $tileIds.Contains([string]$m.TileId)) { $tileIds.Add([string]$m.TileId) } }
    }
    if ($doIcon -and $paths.Count -gt 0) {
        $rr = Restore-AppShortcuts -Paths $paths.ToArray() -AppKeys @($keys.Keys)
        $res.Restored = [int]$rr.Restored; $res.Failed += [int]$rr.Failed; $res.CommonPending = [int]$rr.CommonPending
        if ($rr.Restored -gt 0) { $res.Nothing = $false; Update-IconView -RestartExplorer ([bool]$RestartExplorer) -ClearCache $true }
    }
    if ($doTile -and $tileIds.Count -gt 0) {
        $ut = Undo-Start11Tiles -NoReload:$NoReload -Ids $tileIds.ToArray()
        $res.TilesRestored = [int]$ut.Restored; $res.Failed += [int]$ut.Failed; $res.Hint = [string]$ut.Hint
        if ($ut.Restored -gt 0) { $res.Nothing = $false }
    }
    Write-Log ("Откат приложений ($((@($keys.Keys)) -join ', ')): ярлыков $($res.Restored), плиток $($res.TilesRestored), ошибок $($res.Failed)")
    return $res
}
