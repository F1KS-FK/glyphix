<#
  Glyphix - приложение (WPF, Windows PowerShell 5.1).
  Паки: список (index.json), pack.json и превью обновляются кнопкой «Обновить паки»; иконки и плитки пака качаются по требованию
  (при «Применить» или «Скачать»). Данные прежней версии (Shadow Icons) переносятся при первом запуске.
  GUI:  powershell -STA -File Glyphix.ps1      (обычно запускается через launch.vbs)
  CLI:  Glyphix.ps1 -Cli [-Update] [-List <пак>] [-Apply <пак>] [-Undo] [-NoRestart] [-AllUsers] [-NoTiles] [-NoName] [-NoAuto] [-CommonOnly]
  Версии:  Glyphix.ps1 -CheckUpdate   (покажет локальную версию и версию на GitHub; приложение само предлагает обновиться кнопкой в шапке)
  Плитки Start11 применяются вместе с ярлыками (если Start11 найден); -NoTiles - без плиток, -NoName - плитки без подписи.
  Автоиконки (приложения без иконки в паке получают свою родную иконку в стиле пака) включены по умолчанию, если у пака есть auto.json;
  -NoAuto - без них (общий выключатель и режимы по приложениям - в state.json: AutoIcons, AutoOverrides).
  Прав администратора при запуске НЕ запрашивается. Общие ярлыки (-AllUsers) требуют повышения: GUI сам
  перезапускает этот скрипт в режиме CLI с UAC на одно действие.
  -CommonOnly (с -Undo): откатить только записи общих папок (его использует GUI через повышенный процесс).
#>
[CmdletBinding()]
param(
    [switch]$Cli,
    [string]$List,
    [string]$Apply,
    [switch]$Undo,
    [switch]$Update,
    [switch]$CheckUpdate,
    [switch]$NoRestart,
    [switch]$AllUsers,
    [switch]$NoTiles,
    [switch]$NoName,
    [switch]$NoAuto,
    [switch]$CommonOnly
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
$script:EnginePath = Join-Path $script:Root 'Engine.ps1'
# Текст движка читаем один раз: фоновые операции (runspace) получают его из памяти и не зависят от файла на диске (см. Start-EngineJob)
# Файл повреждён/отсутствует/не разбирается - понятное сообщение вместо молчаливого падения (и запись в %TEMP%\Glyphix-error.log)
try {
    $script:EngineText = [IO.File]::ReadAllText($script:EnginePath, [System.Text.Encoding]::UTF8)
    . $script:EnginePath
} catch {
    $gxMsg = 'Файлы приложения повреждены — переустановите Glyphix командой: irm https://raw.githubusercontent.com/F1KS-FK/glyphix/main/install.ps1 | iex'
    try {
        $gxTmp = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
        $gxLog = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  Glyphix.ps1: ' + $script:EnginePath + ' не загружен: ' + $_.Exception.Message + "`r`n"
        [IO.File]::AppendAllText((Join-Path $gxTmp 'Glyphix-error.log'), $gxLog, (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
    try { Write-Host $gxMsg } catch { }
    if (-not ($Cli -or $List -or $Apply -or $Undo -or $Update -or $CheckUpdate)) {
        try {
            Add-Type -AssemblyName PresentationFramework
            [void][System.Windows.MessageBox]::Show($gxMsg, 'Glyphix', 'OK', 'Error')
        } catch { }
    }
    exit 1
}

# Рабочая папка процесса - папка данных, а не app\: текущая папка процесса держит каталог, и установщик не смог бы переименовать app\ при обновлении
try {
    if (-not (Test-Path -LiteralPath $script:SI_Home)) { New-Item -ItemType Directory -Path $script:SI_Home -Force | Out-Null }
    [Environment]::CurrentDirectory = $script:SI_Home
    Set-Location -LiteralPath $script:SI_Home
} catch { }

# ======================= CLI =======================
function Invoke-Cli {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    Set-EngineLogHandler { param($m) Write-Host $m }
    $code = 0
    $prob = Get-ElevationProblem
    if ($prob) { Write-Log $prob; return 3 }
    if (-not $CommonOnly) { try { [void](Invoke-LegacyMigration) } catch { Write-Log ('Перенос данных: ' + $_.Exception.Message) } }
    $all = [bool]$AllUsers
    if ($all -and -not (Test-Admin)) { Write-Host 'Общие ярлыки требуют прав администратора - пропускаю их.'; $all = $false }
    $tilesOn = ((-not $NoTiles) -and (Test-Start11))
    $autoOn = ((-not $NoAuto) -and (Get-AutoEnabled))
    $packs = @(Get-Packs)
    # паки качаем, только если они нужны: явный -Update или -List/-Apply при пустом кэше. Один -Undo работает по бэкапу и сеть не трогает (откат должен сработать и без интернета)
    if ($Update -or ($packs.Count -eq 0 -and ($List -or $Apply))) {
        $r = Update-Packs
        if (-not $r.Ok) { $code = 1 }
        $packs = @(Get-Packs)
    }
    if ($Undo) {
        $u = $null
        try { $u = Undo-All -RestartExplorer:(-not $NoRestart) -NoReload:$NoRestart -NoTiles:$NoTiles -CommonOnly:$CommonOnly } catch { Write-Log ('Откат не выполнен: ' + $_.Exception.Message) }
        if (-not $u -or $u.Failed -gt 0) { $code = 1 }
        if ($u -and $u.Hint) { Write-Host $u.Hint }
    }
    foreach ($mode in @('List', 'Apply')) {
        $id = if ($mode -eq 'List') { $List } else { $Apply }
        if (-not $id) { continue }
        $pk = $packs | Where-Object { $_.Id -eq $id } | Select-Object -First 1
        if (-not $pk) {
            Write-Host ("Пак '{0}' не найден. Доступные: {1}" -f $id, (($packs | ForEach-Object { $_.Id }) -join ', '))
            return 2
        }
        if ($mode -eq 'Apply') {
            # применяем только свежий пак: index + pack.json + файлы, затем пак заново читается с диска и по нему ищутся ярлыки
            try { $pk = Sync-PackForApply -Id ([string]$pk.Id) -Parts (Get-PackParts -Tiles $tilesOn -NoName ([bool]$NoName)) }
            catch { Write-Log ('Пак не обновлён: ' + $_.Exception.Message); return 1 }
        }
        $items = @(Get-Matches -Pack $pk -AllUsers:$all -Auto:$autoOn)
        if ($mode -eq 'List') {
            Write-Host ("Пак: {0} {1}, иконок: {2}; найдено ярлыков: {3}" -f $pk.Name, $pk.Version, $pk.IconCount, $items.Count)
            foreach ($m in $items) {
                $mark = if ($m.Already) { ' (уже стоит)' } else { '' }
                Write-Host ("  [{0,-7}] {1,-32} -> {2} ({3}){4}" -f $m.Location, $m.Name, $m.IconName, $m.Rule, $mark)
            }
            if ($tilesOn) {
                $tiles = @(Get-Start11Matches -Pack $pk -NoName:$NoName -Auto:$autoOn)
                Write-Host ("Плитки Start11: {0}" -f $tiles.Count)
                foreach ($m in $tiles) {
                    $mark = if ($m.Already) { ' (уже стоит)' } else { '' }
                    Write-Host ("  [start11] {0,-32} -> {1} ({2}){3}" -f (Get-TileTitle $m), $m.IconName, $m.Rule, $mark)
                }
            }
        } else {
            if (Test-LegacyMigrationIncomplete) { Write-Log $script:SI_MigrationPendingMsg; return 4 }     # бэкап прежней версии ещё не перенесён
            $r = Apply-Pack -Pack $pk -Items $items -RestartExplorer:(-not $NoRestart) -NoAuto:(-not $autoOn)
            if ($r.Failed -gt 0) { $code = 1 }
            if ($tilesOn) {
                $tr = Apply-Start11Tiles -Pack $pk -NoName:$NoName -NoReload:$NoRestart -NoAuto:(-not $autoOn)
                if ($tr.Failed -gt 0) { $code = 1 }
                if ($tr.Hint) { Write-Host $tr.Hint }
            }
            # применено без ошибок - копии иконок/плиток других паков и старых версий, на которые уже никто не ссылается, удаляем (повышенный дочерний процесс
            # с -AllUsers -NoTiles этого не делает: плитки ещё не записаны, очистку сделает родительское окно после плиток)
            if ($r.Failed -eq 0 -and ($r.Changed + $r.Same) -gt 0 -and -not ($AllUsers -and $NoTiles)) {
                try { $cl = Clear-UnusedCopies; if ($cl.Bytes -gt 0) { Write-Host ('Освобождено: ' + (Format-DownloadSize $cl.Bytes)) } } catch { Write-Log ('Очистка копий: ' + $_.Exception.Message) }
            }
        }
    }
    return $code
}

function Invoke-CheckUpdate {
    try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
    $info = Get-AppUpdateInfo
    Write-Host ('Локальная версия: ' + $info.Local)
    if ($info.Reason -eq 'bad-remote') {
        Write-Host 'Версия на GitHub: не удалось получить (нет сети или неверный ответ)'
        return 1
    }
    Write-Host ('Версия на GitHub: ' + $info.Remote)
    if ($info.Available) { Write-Host 'Доступно обновление: нажмите кнопку «Доступна версия ... - обновить приложение» в окне или выполните: irm https://raw.githubusercontent.com/F1KS-FK/glyphix/main/install.ps1 | iex' }
    else { Write-Host 'Обновление не требуется' }
    return 0
}

if ($CheckUpdate) {
    $rcCheck = Invoke-CheckUpdate
    if (-not ($Cli -or $List -or $Apply -or $Undo -or $Update)) { exit $rcCheck }
}
if ($Cli -or $List -or $Apply -or $Undo -or $Update) {
    $rc = Invoke-Cli
    exit $rc
}

# ======================= GUI =======================

# WPF требует STA; в Windows PowerShell 5.1 это по умолчанию, но проверим
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    $a = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -WindowStyle Hidden
    exit 0
}

# Автоматического повышения прав нет: приложение работает от обычного пользователя (ярлыки пользователя, панель задач,
# Пуск и рабочий стол пользователя). Общие ярлыки - по галочке, через UAC на одно действие (см. Invoke-Apply).

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Один экземпляр окна: именованный мьютекс сессии. Второй запуск лишь сообщает, что приложение уже открыто, и выходит
# (два окна писали бы в одни и те же state.json/backup и мешали бы обновлению файлов).
$script:InstanceMutex = $null
$gxAlready = $false
try {
    $gxNew = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\Glyphix.App', [ref]$gxNew)
    if (-not $gxNew) { $gxAlready = $true }
} catch {
    for ($gxE = $_.Exception; $gxE; $gxE = $gxE.InnerException) { if ($gxE -is [UnauthorizedAccessException]) { $gxAlready = $true } }      # создан другим уровнем доступа (например, повышенным процессом) - значит, окно уже есть
    if (-not $gxAlready) { try { Write-Log ('Мьютекс единственного экземпляра недоступен: ' + $_.Exception.Message) } catch { } }      # не смогли проверить - работаем как раньше
}
if ($gxAlready) {
    if ($script:InstanceMutex) { try { $script:InstanceMutex.Dispose() } catch { } }
    [void][System.Windows.MessageBox]::Show('Glyphix уже открыт', 'Glyphix', 'OK', 'Information')
    exit 0
}
try { [void](Remove-StaleTempFiles) } catch { }          # остатки прерванных записей (*.tmp); мы единственный экземпляр, никто другой не пишет

try {
    if (-not ('GlyphixNative.Gui' -as [type])) {
        Add-Type -Namespace GlyphixNative -Name Gui -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
'@
    }
    [void][GlyphixNative.Gui]::SetCurrentProcessExplicitAppUserModelID($script:SI_AppId)
} catch { }
try { [void](Repair-AppShortcutAppId) } catch { }          # ярлык «Glyphix» без AppUserModelID (старые версии) - пересоздаём один раз: так Start11 увидит плитку

# Все строки интерфейса - здесь (для будущей локализации)
$T = @{
    Title        = 'Glyphix'
    Packs        = 'Паки иконок'
    Apply        = 'Применить'
    Applied      = '✓ Применён'
    Update       = 'Обновить паки'
    Undo         = 'Откатить всё'
    Open         = 'Открыть папку'
    Uninstall    = 'Удалить приложение'
    Restart      = 'Перезапустить проводник'
    LogShow      = 'Журнал ▾'
    LogHide      = 'Журнал ▴'
    WillChange   = 'Что поменяется'
    NoPackSel    = 'Выберите пак слева'
    PackLine     = 'Пак: {0}'
    Scanning     = 'Ищу ярлыки...'
    Found        = 'Найдено ярлыков: {0}'
    FoundSame    = ' (из них уже стоит: {0})'
    NoneFound    = 'Подходящих ярлыков не найдено'
    AlreadySet   = 'уже стоит'
    AdminNote    = 'Общие ярлыки (для всех пользователей) не затрагиваются. Отметьте «Также общие ярлыки», чтобы включить их (понадобятся права администратора).'
    AllUsers     = 'Также общие ярлыки'
    ElevCancel   = 'Запрос прав администратора отклонён - ничего не изменено'
    ElevDone     = 'Готово (общие ярлыки применены с правами администратора)'
    ElevFail     = 'Действие с правами администратора завершилось с ошибками (код {0}), подробности - в журнале'
    ElevRefused  = 'Отказ: повышенный процесс запущен от другой учётной записи администратора, ничего не изменено'
    ElevBlocked  = 'Нельзя работать: {0}'
    LinkCopied   = 'Из-под администратора ссылки не открываются - адрес скопирован в буфер обмена: {0}'
    Admin        = '● Администратор'
    NoAdmin      = 'Без прав администратора'
    Ready        = 'Готово'
    Updating     = 'Проверяю обновления паков...'
    AppUpdate    = 'Доступна версия {0} — обновить приложение'
    AppUpdateTip = 'Установлена {0}, на GitHub {1}. Нажмите, чтобы скачать и установить новую версию.'
    ConfirmAppUpdate = 'Доступна версия {1} (установлена {0}).' + "`n`n" + 'Скачать установщик, проверить файлы по sha256 и обновить Glyphix? Приложение закроется и запустится заново.'
    AppUpdating  = 'Скачиваю установщик обновления...'
    AppUpdateStarted = 'Установщик запущен, приложение закрывается...'
    RestartTip   = 'Иконки обновятся сразу, без выхода из системы'
    AllUsersTip  = 'Для общих ярлыков нужны права администратора (запрос UAC на одно действие)'
    FirstRun     = 'Первый запуск: загружаю список паков с GitHub...'
    Migrating    = 'Переношу данные из Shadow Icons...'
    Download     = 'Скачать'
    Downloading  = 'Скачиваю пак...'
    DownloadDone = 'Пак скачан (файлов: {0})'
    SelCount     = 'Выбрано: {0}'
    SelDownload  = 'Скачать выбранные'
    SelAll       = 'Выбрать все'
    SelNone      = 'Снять'
    SelTip       = 'Отметьте паки галочками на карточках (или Ctrl + щелчок по карточке) и скачайте их разом; уже скачанные свежие паки пропускаются'
    SelNothing   = 'Ничего не выбрано'
    SelDownloading = 'Скачиваю выбранные паки...'
    SelDone      = 'Скачано паков: {0} (файлов: {1})'
    SelSkipped   = ', уже скачаны: {0}'
    SelFailed    = ', ошибок: {0}'
    SelAllFresh  = 'Все выбранные паки уже скачаны'
    CheckTip     = 'Выбрать пак (Ctrl + щелчок по карточке - то же самое)'
    Delete       = '🗑'
    DeleteTip    = 'Удалить скачанные файлы пака ({0}); сам пак останется в списке, «Скачать» вернёт файлы'
    Deleting     = 'Удаляю скачанные файлы пака...'
    DeleteDone   = 'Пак удалён с диска: {0}'
    DeleteFail   = 'Не удалено: {0}'
    ClearCache   = 'Очистить кэш'
    ConfirmCache = 'Удалить все скачанные паки, кроме применённого, и ненужные файлы (копии иконок других паков и старых версий)?' + "`n`n" + 'Ярлыки и плитки это не затронет; пак можно скачать снова.'
    ClearingCache = 'Очищаю кэш...'
    CacheDone    = 'Кэш очищен: освобождено {0}'
    Freed        = 'освобождено {0}'
    StateReady   = 'Скачан'
    StateNone    = 'Не скачан'
    StateStale   = 'Есть обновление'
    NotReadyNote = 'Пак ещё не скачан: иконки загрузятся при нажатии «Применить» (или «Скачать» на карточке), плитки Start11 - при их применении.'
    GroupHeader  = '{0} · {1}'
    Group_apps   = 'Приложения'
    Group_games  = 'Игры'
    Group_system = 'Система'
    Group_work   = 'Работа'
    Group_creative = 'Творчество'
    Group_other  = 'Прочее'
    Applying     = 'Применяю пак...'
    Undoing      = 'Возвращаю исходные ярлыки...'
    Uninstalling = 'Удаляю приложение...'
    ApplyDone    = '{0}: заменено {1}, уже стояли {2}'
    ApplyCached  = 'Не удалось обновить пак с GitHub — применена сохранённая версия {0}'
    WaitSilent   = 'Жду обновления паков…'
    ApplyFail    = ', ошибок: {0}'
    UndoDone     = 'Возвращено ярлыков: {0}'
    UndoNothing  = 'Откатывать нечего: бэкапа нет'
    UndoFail     = ', не удалось: {0} (для общих ярлыков отметьте «Также общие ярлыки» и повторите)'
    Offline      = 'Не удалось обновить (нет сети?). Работаю с сохранёнными паками.'
    NoPacks      = 'Паков пока нет.' + "`n" + 'Нажмите «Обновить паки» (нужен интернет).'
    ConfirmUndo  = 'Вернуть все ярлыки к исходным иконкам?'
    ConfirmUn    = 'Удалить Glyphix? Исходные иконки будут возвращены, папка приложения и ярлыки Glyphix удалены.'
    Busy         = 'Операция ещё выполняется. Дождитесь окончания.'
    Error        = 'Ошибка: {0}'
    Removed      = 'Приложение удалено'
    IconsN       = 'Иконок: {0}'
    Loc_taskbar  = 'Панель задач'
    Loc_desktop  = 'Рабочий стол'
    Loc_start    = 'Пуск'
    Loc_desktop_all = 'Рабочий стол (общий)'
    Loc_start_all   = 'Пуск (общий)'
    IconWord     = 'Иконка'
    Tiles        = 'Плитки Start11'
    TilesNoName  = 'Плитки без подписи'
    TilesFound   = 'Плиток Start11: {0}'
    TilesPill    = 'Плитка Start11'
    TileSub      = 'Плитка: {0} · id: {1}'
    TilesDone    = 'Плитки Start11: заменено {0}, уже стояли {1}'
    TilesFail    = ', ошибок: {0}'
    TilesUndone  = ', плиток Start11: {0}'
    Auto         = 'Автоиконки для остальных приложений'
    AutoTip      = 'Приложения, для которых в паке нет иконки, получат СВОЮ родную иконку в стиле пака (создаётся на этом компьютере, сеть не нужна)'
    AutoBadge    = 'авто'
    AutoFound    = 'Автоиконок: {0}'
    AutoNotSupported = 'В этом паке нет параметров автоиконок (auto.json) - для остальных приложений иконки не создаются.'
    AutoSub      = 'Своя иконка в стиле пака'
    AutoTileSub  = 'Плитка в стиле пака · id: {0}'
    AutoMode_Auto   = 'Авто'
    AutoMode_Native = 'Родная'
    AutoMode_Off    = 'Не трогать'
    AutoModeTip_Auto   = 'Перекрасить иконку приложения в стиль пака'
    AutoModeTip_Native = 'Оставить родную иконку приложения'
    AutoModeTip_Off    = 'Ничего не менять у этого приложения'
    AutoModeSet  = 'Для «{0}»: {1}'
    ApplyAuto    = ', автоиконок: {0}'
    Group_auto   = 'Автоиконки'
}

# ---- загрузка XAML ----
$script:Window = $null
try {
    $xamlPath = Join-Path $script:Root 'MainWindow.xaml'
    $reader = [System.Xml.XmlReader]::Create($xamlPath)
    try { $script:Window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
} catch {
    Write-Log ('XAML не загружен: ' + $_.Exception.Message)
    [void][System.Windows.MessageBox]::Show('Не удалось открыть окно: ' + $_.Exception.Message, 'Glyphix', 'OK', 'Error')
    exit 1
}
$script:ui = @{}
$names = @('ImgLogo', 'TxtVersion', 'TxtAdmin', 'TxtPacksTitle', 'PackList', 'TxtEmpty', 'TxtMatchTitle', 'TxtSelectedPack', 'MatchList',
    'TxtMatchSummary', 'BtnUpdate', 'BtnUndo', 'BtnOpen', 'BtnMenu', 'ChkRestart', 'ChkAllUsers', 'ChkTiles', 'ChkNoName', 'ChkAuto', 'LnkGitHub', 'LnkAuthor', 'PopMenu', 'BtnUninstall', 'BtnClearCache', 'TxtSelCount', 'BtnSelDownload', 'BtnSelAll', 'BtnSelNone',
    'PrgBusy', 'TxtStatus', 'BtnLog', 'LogPanel', 'TxtLog', 'BtnAppUpdate')
foreach ($n in $names) {
    $script:ui[$n] = $script:Window.FindName($n)
    if ($null -eq $script:ui[$n]) { Write-Log "В XAML нет элемента $n"; [void][System.Windows.MessageBox]::Show("В MainWindow.xaml нет элемента $n", 'Glyphix', 'OK', 'Error'); exit 1 }
}

# ---- состояние GUI ----
$script:Packs = @()
$script:Cards = @{}
$script:CardButtons = @()
$script:CardChecks = @{}          # id пака -> CheckBox на карточке
$script:Checked = @{}             # id отмеченных паков (переживает перестройку карточек)
$script:SelectedId = $null
$script:PendingSelect = $null
$script:Job = $null
$script:Closing = $false
$script:UpdJob = $null
$script:SilentJob = $null
$script:SilentCtl = $null         # синхронизированная hashtable { Cancel }: GUI просит тихое обновление остановиться
$script:BgPending = $null         # операция, ждущая окончания тихого обновления паков (Start-Bg -WaitSilent)
$script:UpdateInfo = $null
$script:DataHome = $script:SI_Home
$script:HasStart11 = $false
try { $script:HasStart11 = [bool](Test-Start11) } catch { }
$script:AutoThumbs = @{}          # 'ключ|l' (ярлык) / 'ключ|t' (плитка) -> Image-элементы строк: сюда ложится превью, когда фон его создал
$script:AutoRows = @{}            # ключ приложения -> строки (для синхронного переключения режима)
$script:PrevJob = $null           # фоновая генерация автоиконок для превью (отдельно от $script:Job: окно не блокируется)
$script:PrevOld = @()             # остановленные, но ещё не завершившиеся задания превью

function Get-Res { param([string]$Key) return $script:Window.FindResource($Key) }

function New-Img {
    param([string]$Path, [int]$DecodeWidth = 0)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
        $ms = New-Object System.IO.MemoryStream(, $bytes)
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        if ($DecodeWidth -gt 0) { $bi.DecodePixelWidth = $DecodeWidth }
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        $ms.Dispose()
        return $bi
    } catch { return $null }
}

# Картинка в Image: только в настоящий System.Windows.Controls.Image, через SetValue(Image.SourceProperty, ImageSource), а не через `$im.Source = ...`
# (динамический биндер PowerShell 5.1 для присвоения свойства на элементе из List[object] / обёрнутом PSObject падал с «Argument types do not match»,
# 273 раза за сеанс: у каждой строки списка автоиконок). Ошибка одной картинки не мешает остальным; возвращает `$true`, если картинка поставлена.
function Set-ImageSource {
    param($Target, $Source)
    try {
        $t = $Target; if ($t -is [System.Management.Automation.PSObject]) { $t = $t.psobject.BaseObject }
        $s = $Source; if ($s -is [System.Management.Automation.PSObject]) { $s = $s.psobject.BaseObject }
        if ($t -isnot [System.Windows.Controls.Image] -or $s -isnot [System.Windows.Media.ImageSource]) { return $false }
        $t.SetValue([System.Windows.Controls.Image]::SourceProperty, [System.Windows.Media.ImageSource]$s)
        return $true
    } catch { Show-Error $_ 'картинка' ; return $false }
}

function Add-LogLine {
    param([string]$Line)
    try {
        if ($script:ui.TxtLog.Text.Length -gt 200000) { $script:ui.TxtLog.Clear() }
        $script:ui.TxtLog.AppendText($Line + "`r`n")
        $script:ui.TxtLog.ScrollToEnd()
    } catch { }
}

function Set-Status { param([string]$Text) $script:ui.TxtStatus.Text = $Text; $script:ui.TxtStatus.ToolTip = $Text }

# Ошибка действия GUI: сообщение в строку состояния, в журнал (log.txt) - сообщение, место ошибки и стек вызовов. Сама не бросает исключений.
function Show-Error {
    param($Err, [string]$Action = '', [string]$Stack = '')
    try {
        $m = ''
        if ($Err -is [System.Management.Automation.ErrorRecord]) {
            $m = $Err.Exception.Message
            if (-not $Stack) { $Stack = [string]$Err.ScriptStackTrace }
            $im = ''
            try { if ($Err.InvocationInfo) { $im = ('{0}:{1}  {2}' -f $Err.InvocationInfo.ScriptName, $Err.InvocationInfo.ScriptLineNumber, $Err.InvocationInfo.Line.Trim()) } } catch { }
            if ($im) { $Stack = ('в ' + $im + "`n" + $Stack) }
        } elseif ($Err -and $Err.PSObject.Properties['Error']) {
            $m = [string]$Err.Error
            if (-not $Stack -and $Err.PSObject.Properties['Stack']) { $Stack = [string]$Err.Stack }
        } else { $m = [string]$Err }
        $head = if ($Action) { 'ОШИБКА GUI [' + $Action + ']: ' } else { 'ОШИБКА GUI: ' }
        if ($m -eq $script:SI_NoNetMsg -or (Test-NetworkErrorText $m)) { Set-Status $script:SI_NoNetMsg }      # сеть: понятная фраза вместо текста исключения (сам текст - в журнале)
        else { Set-Status ($script:T.Error -f $m) }
        # одну и ту же ошибку (действие + текст) пишем в журнал один раз за сеанс: повтор на каждом тике таймера раздувал log.txt (273 строки)
        $sig = $head + $m
        if (-not $script:GuiErrSeen) { $script:GuiErrSeen = @{} }
        if ($script:GuiErrSeen.ContainsKey($sig)) { $script:GuiErrSeen[$sig] = [int]$script:GuiErrSeen[$sig] + 1; return }
        $script:GuiErrSeen[$sig] = 1
        Write-Log ($head + $m)
        if ($Stack) { Write-Log ('  стек: ' + (($Stack.Trim() -replace "`r?`n", ' <- '))) }
    } catch { }
}

# Действие GUI не должно валить окно и соседние действия: любая ошибка - в журнал со стеком и в строку состояния
function Invoke-Safe {
    param([string]$Action, [scriptblock]$Do)
    try { & $Do } catch { Show-Error $_ $Action }
}

function Set-Busy {
    param([bool]$Busy)
    $script:ui.PrgBusy.IsIndeterminate = $Busy
    $script:ui.PrgBusy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    foreach ($b in @($script:ui.BtnUpdate, $script:ui.BtnUndo, $script:ui.BtnMenu, $script:ui.BtnAppUpdate)) { $b.IsEnabled = (-not $Busy) }
    foreach ($b in $script:CardButtons) { $b.IsEnabled = (-not $Busy) }
    $script:BusyNow = $Busy
    Update-SelBar
}

# ---- фоновые операции (отдельный runspace, UI не замирает; код - Start-EngineJob / Receive-EngineJob в Engine.ps1) ----
# -WaitSilent (Применить / Откат / Удаление / Обновить / Скачать / Обновление приложения): операции, пишущие state.json, pack.json, packs\.
# Идёт тихое обновление паков - просим его остановиться и стартуем операцию, когда оно закончится (окно не блокируется, таймер WaitTimer).
function Start-Bg {
    param([string]$Title, [string]$Body, [hashtable]$Params, [scriptblock]$OnDone, [switch]$WaitSilent)
    if ($script:Job -or $script:BgPending -or $script:Closing) { return }
    if ($WaitSilent -and $script:SilentJob) {
        if ($script:SilentCtl) { try { $script:SilentCtl['Cancel'] = $true } catch { } }
        Set-Status $script:T.WaitSilent
        Set-Busy $true
        $script:BgPending = @{ Title = $Title; Body = $Body; Params = $Params; OnDone = $OnDone }
        $script:WaitTimer.Start()
        return
    }
    Set-Status $Title
    Set-Busy $true
    try {
        if (-not (Test-Path -LiteralPath $script:EnginePath -PathType Leaf)) {
            Write-Log ('Engine.ps1 нет на диске: ' + $script:EnginePath + ' (папка app есть: ' + (Test-Path -LiteralPath $script:Root) + ') - работаю с копией из памяти')
        }
        $j = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Body $Body -Params $Params
    } catch {
        Set-Busy $false
        throw
    }
    $j.OnDone = $OnDone
    $script:Job = $j
    $script:Timer.Start()
}

# ждём окончания тихого обновления паков (оно уже получило Cancel), затем запускаем отложенную операцию; всё в потоке интерфейса (DispatcherTimer)
function Step-BgPending {
    $pd = $script:BgPending
    if (-not $pd) { $script:WaitTimer.Stop(); return }
    $j = $script:SilentJob
    if ($j) {
        $line = $null
        while ($j.Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
        if (-not $j.Async.IsCompleted) { return }
        $script:SilentTimer.Stop()
        try { [void](Receive-EngineJob $j) } catch { }
        $script:SilentJob = $null
    }
    $script:WaitTimer.Stop()
    $script:BgPending = $null
    if ($script:Closing) { Set-Busy $false; return }
    Start-Bg -Title $pd.Title -Body $pd.Body -Params $pd.Params -OnDone $pd.OnDone
}

function Step-Job {
    $job = $script:Job
    if (-not $job) { $script:Timer.Stop(); return }
    $line = $null
    while ($job.Queue.TryDequeue([ref]$line)) { Add-LogLine $line; Set-Status $line }
    if (-not $job.Async.IsCompleted) { return }
    $script:Timer.Stop()
    $res = Receive-EngineJob $job
    $script:Job = $null
    Set-Busy $false
    if ($res -and $res.PSObject.Properties['Error'] -and $res.Error) { Write-Log ('Фоновая операция завершилась ошибкой: ' + $res.Error) }
    try { & $job.OnDone $res } catch { Show-Error $_ 'после операции' }
    if ($script:PendingSelect) { $p = $script:PendingSelect; $script:PendingSelect = $null; try { Select-Pack $p } catch { Show-Error $_ 'выбор пака' } }
}

# ---- обновление самого приложения ----
# Проверка идёт в отдельном runspace (не занимает общий $script:Job), ошибки сети молча игнорируются: кнопка просто не появляется.
function Show-AppUpdateButton {
    $i = $script:UpdateInfo
    if ($i -and $i.Available) {
        $script:ui.BtnAppUpdate.Content = ($script:T.AppUpdate -f $i.Remote)
        $script:ui.BtnAppUpdate.ToolTip = ($script:T.AppUpdateTip -f $i.Local, $i.Remote)
        $script:ui.BtnAppUpdate.Visibility = 'Visible'
    } else {
        $script:ui.BtnAppUpdate.Visibility = 'Collapsed'
    }
}

function Step-UpdateCheck {
    $u = $script:UpdJob
    if (-not $u) { $script:UpdTimer.Stop(); return }
    if (-not $u.Async.IsCompleted) { return }
    $script:UpdTimer.Stop()
    $info = $null
    try { $info = Receive-EngineJob $u } catch { }
    $script:UpdJob = $null
    if ($info -and $info.PSObject.Properties['Available']) { $script:UpdateInfo = $info; Show-AppUpdateButton }
}

function Start-UpdateCheck {
    if ($script:UpdJob -or $script:Closing) { return }
    try {
        $script:UpdJob = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Body 'param($p) Get-AppUpdateInfo' -Params @{}
        $script:UpdTimer.Start()
    } catch { $script:UpdJob = $null; Write-Log ('Проверка версии не запущена: ' + $_.Exception.Message) }
}

# ---- тихое обновление паков на каждом запуске ----
# index.json + pack.json + превью всех паков (без иконок и плиток) в отдельном runspace, без строки состояния и индикатора занятости:
# карточки (версия, число иконок, превью) обновляются по готовности. Иначе кэш старой версии показывался бы до ручного «Обновить паки».
function Step-SilentRefresh {
    $j = $script:SilentJob
    if (-not $j) { $script:SilentTimer.Stop(); return }
    $line = $null
    while ($j.Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
    if (-not $j.Async.IsCompleted) { return }
    if ($script:Job -or $script:BgPending) { return }      # идёт другая операция (или она ждёт конца этого обновления) - карточки обновим, когда она закончится
    $script:SilentTimer.Stop()
    $res = $null
    try { $res = Receive-EngineJob $j } catch { }
    $script:SilentJob = $null
    if ($script:Closing) { return }
    if ($res -and $res.PSObject.Properties['Error'] -and $res.Error) { Write-Log ('Тихое обновление паков: ' + $res.Error); return }
    if ($res -and $res.PSObject.Properties['Downloaded'] -and [int]$res.Downloaded -gt 0) {
        Rebuild-Packs
        if ($script:SelectedId -and $script:Cards.ContainsKey($script:SelectedId)) { Select-Pack $script:SelectedId }
        elseif ($script:Packs.Count -gt 0) { Select-Pack ([string]$script:Packs[0].Id) }
    }
}

function Start-SilentRefresh {
    if ($script:SilentJob -or $script:Job -or $script:BgPending -or $script:Closing) { return }      # идёт Применить / Откат / ...: тихое обновление не стартует (оно пишет те же файлы)
    try {
        $script:SilentCtl = [hashtable]::Synchronized(@{ Cancel = $false })
        $script:SilentJob = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Body 'param($p) Update-Packs -Cancel $p.Ctl' -Params @{ Ctl = $script:SilentCtl }
        $script:SilentTimer.Start()
    } catch { $script:SilentJob = $null; Write-Log ('Тихое обновление паков не запущено: ' + $_.Exception.Message) }
}

function Invoke-AppUpdate {
    if ($script:Job -or $script:BgPending) { Set-Status $script:T.Busy; return }
    $i = $script:UpdateInfo
    if (-not $i -or -not $i.Available) { return }
    $ans = [System.Windows.MessageBox]::Show($script:Window, ($script:T.ConfirmAppUpdate -f $i.Local, $i.Remote), $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Bg -WaitSilent -Title $script:T.AppUpdating -Params @{} -Body @'
param($p)
[pscustomobject]@{ Started = $true; Installer = (Start-AppSelfUpdate) }
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Обновление не вернуло результат'; return }
        if ($res.Error) { Show-Error $res 'обновление приложения'; return }
        Set-Status $script:T.AppUpdateStarted
        $script:Closing = $true
        $script:Window.Close()
    }
}

# ---- карточки паков ----
function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Brush = 'TextBrush', [string]$Weight = 'Normal')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = (Get-Res $Brush)
    $tb.FontWeight = [System.Windows.FontWeights]::$Weight
    return $tb
}

function Update-CardHighlight {
    foreach ($id in $script:Cards.Keys) {
        $c = $script:Cards[$id]
        if ($id -eq $script:SelectedId) { $c.BorderBrush = (Get-Res 'AccentBrush') } else { $c.BorderBrush = (Get-Res 'CardBorderBrush') }
    }
}

# плашка состояния пака на карточке: применён / скачан / не скачан / есть обновление
function New-StatePill {
    param([string]$Text, [bool]$Accent)
    $pill = New-Object System.Windows.Controls.Border
    $pill.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $pill.Padding = New-Object System.Windows.Thickness(8, 2, 8, 2)
    $pill.VerticalAlignment = 'Center'
    if ($Accent) {
        $pill.Background = (Get-Res 'AccentBrush')
        $tb = New-Text $Text 11 'TextBrush' 'SemiBold'
    } else {
        $pill.Background = (Get-Res 'GhostBrush')
        $tb = New-Text $Text 11 'MutedBrush'
    }
    $pill.Child = $tb
    return $pill
}

# панель выбора: «Выбрано: N», «Скачать выбранные» (доступна, когда что-то выбрано и нет операции), «Выбрать все», «Снять»
function Update-SelBar {
    try {
        $n = @($script:Checked.Keys).Count
        $script:ui.TxtSelCount.Text = ($script:T.SelCount -f $n)
        $script:ui.BtnSelDownload.IsEnabled = ($n -gt 0 -and -not $script:BusyNow)
        $script:ui.BtnSelNone.IsEnabled = ($n -gt 0)
        $script:ui.BtnSelAll.IsEnabled = ($script:Packs.Count -gt 0)
    } catch { }
}

function Set-PackChecked {
    param([string]$Id, [bool]$On)
    if ($On) { $script:Checked[$Id] = $true } else { $script:Checked.Remove($Id) }
    if ($script:CardChecks.ContainsKey($Id)) { $script:CardChecks[$Id].IsChecked = $On }
    Update-SelBar
}

function Rebuild-Packs {
    $script:ui.PackList.Children.Clear()
    $script:Cards = @{}
    $script:CardButtons = @()
    $script:CardChecks = @{}
    $script:Packs = @(Get-Packs)
    foreach ($ck in @($script:Checked.Keys)) { if (-not (@($script:Packs | Where-Object { $_.Id -eq $ck }).Count)) { $script:Checked.Remove($ck) } }      # пака уже нет - выбор снимаем
    $script:ui.TxtEmpty.Text = $script:T.NoPacks
    $script:ui.TxtEmpty.Visibility = if ($script:Packs.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $applied = $null
    $st = Read-State
    if ($st.ContainsKey('Applied') -and $st['Applied']) { $applied = [string]$st['Applied'].PackId }
    foreach ($pk in $script:Packs) {
      try {
        # карточка = Grid с жёсткими строками: высота и положение элементов не зависят от длины текста
        $card = New-Object System.Windows.Controls.Border
        $card.Style = (Get-Res 'CardStyle')
        $card.Margin = New-Object System.Windows.Thickness(6)           # размер карточки задаёт ItemWidth/ItemHeight у WrapPanel
        $card.Tag = $pk.Id
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $card.ToolTip = $pk.Name
        $sp = New-Object System.Windows.Controls.Grid
        foreach ($h in @(92, 34, 20, 36)) {
            $rd = New-Object System.Windows.Controls.RowDefinition
            $rd.Height = New-Object System.Windows.GridLength($h)
            [void]$sp.RowDefinitions.Add($rd)
        }
        $rd = New-Object System.Windows.Controls.RowDefinition
        $rd.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$sp.RowDefinitions.Add($rd)

        $pv = New-Object System.Windows.Controls.Border
        $pv.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $img = New-Img $pk.Preview 600
        if ($img) {
            $ib = New-Object System.Windows.Media.ImageBrush($img)
            $ib.Stretch = [System.Windows.Media.Stretch]::UniformToFill
            $pv.Background = $ib
        } else { $pv.Background = (Get-Res 'RowBrush') }
        [System.Windows.Controls.Grid]::SetRow($pv, 0)
        [void]$sp.Children.Add($pv)
        # галочка выбора (поверх превью, слева сверху): несколько паков можно скачать разом
        $ckBox = New-Object System.Windows.Controls.Border
        $ckBox.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $ckBox.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(190, 7, 10, 24))
        $ckBox.Padding = New-Object System.Windows.Thickness(5, 0, 5, 0)
        $ckBox.Margin = New-Object System.Windows.Thickness(6)
        $ckBox.HorizontalAlignment = 'Left'
        $ckBox.VerticalAlignment = 'Top'
        $chk = New-Object System.Windows.Controls.CheckBox
        $chk.Style = (Get-Res 'DarkCheck')
        $chk.Tag = $pk.Id
        $chk.ToolTip = $script:T.CheckTip
        $chk.IsChecked = [bool]$script:Checked.ContainsKey([string]$pk.Id)
        $chk.Add_Click({ param($s, $e) try { Set-PackChecked ([string]$s.Tag) ([bool]$s.IsChecked) } catch { Show-Error $_ 'выбор паков' } })
        $ckBox.Child = $chk
        [System.Windows.Controls.Grid]::SetRow($ckBox, 0)
        [void]$sp.Children.Add($ckBox)
        $script:CardChecks[[string]$pk.Id] = $chk

        # название + состояние (применён / скачан / не скачан)
        $head = New-Object System.Windows.Controls.Grid
        $h1 = New-Object System.Windows.Controls.ColumnDefinition; $h1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $h2 = New-Object System.Windows.Controls.ColumnDefinition; $h2.Width = [System.Windows.GridLength]::Auto
        [void]$head.ColumnDefinitions.Add($h1); [void]$head.ColumnDefinitions.Add($h2)
        $head.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
        $nm = New-Text $pk.Name 16 'TextBrush' 'SemiBold'
        $nm.TextTrimming = 'CharacterEllipsis'
        $nm.VerticalAlignment = 'Center'
        $nm.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
        [void]$head.Children.Add($nm)
        $isApplied = ($applied -and $applied -eq $pk.Id)
        $stateText = if ($isApplied) { $script:T.Applied } elseif ($pk.State -eq 'ready') { $script:T.StateReady } elseif ($pk.State -eq 'stale') { $script:T.StateStale } else { $script:T.StateNone }
        $diskText = ''
        if ($pk.State -ne 'none') { $diskText = (Format-DownloadSize (Get-PackDiskBytes ([string]$pk.Dir))); $stateText += ' · ' + $diskText }      # размер скачанного на диске
        $pill = New-StatePill $stateText ([bool]$isApplied)
        [System.Windows.Controls.Grid]::SetColumn($pill, 1)
        [void]$head.Children.Add($pill)
        [System.Windows.Controls.Grid]::SetRow($head, 1)
        [void]$sp.Children.Add($head)

        $meta = New-Text ("{0} · v{1} · {2}" -f $pk.Author, $pk.Version, ($script:T.IconsN -f $pk.IconCount)) 12 'MutedBrush'
        $meta.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
        $meta.VerticalAlignment = 'Center'
        $meta.TextTrimming = 'CharacterEllipsis'
        [System.Windows.Controls.Grid]::SetRow($meta, 2)
        [void]$sp.Children.Add($meta)
        if ($pk.Description) {                 # строка описания есть всегда (36 px), даже если текста нет
            $ds = New-Text $pk.Description 12 'MutedBrush'
            $ds.TextWrapping = 'Wrap'
            $ds.TextTrimming = 'CharacterEllipsis'
            $ds.VerticalAlignment = 'Top'
            $ds.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
            $ds.ToolTip = [string]$pk.Description
            [System.Windows.Controls.Grid]::SetRow($ds, 3)
            [void]$sp.Children.Add($ds)
        }
        # кнопки: две фиксированные колонки (Применить | Скачать), всегда в одном и том же месте карточки
        $row = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(112)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(100)
        $c3 = New-Object System.Windows.Controls.ColumnDefinition; $c3.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2); [void]$row.ColumnDefinitions.Add($c3)
        $row.VerticalAlignment = 'Center'
        $row.Height = 36
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = (Get-Res 'AccentButton')
        $btn.Content = $script:T.Apply
        $btn.Tag = $pk.Id
        $btn.Add_Click({ param($s, $e) try { Invoke-Apply ([string]$s.Tag) } catch { Show-Error $_ 'Применить' } })
        [void]$row.Children.Add($btn)
        $script:CardButtons += $btn
        if ($pk.State -ne 'ready') {          # «Скачать» - иконки этого пака и плитки, если они включены (по требованию)
            $dl = New-Object System.Windows.Controls.Button
            $dl.Style = (Get-Res 'GhostButton')
            $dl.Content = $script:T.Download
            $dl.Tag = $pk.Id
            $dl.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
            $dl.Add_Click({ param($s, $e) try { Invoke-Download ([string]$s.Tag) } catch { Show-Error $_ 'Скачать' } })
            [System.Windows.Controls.Grid]::SetColumn($dl, 1)
            [void]$row.Children.Add($dl)
            $script:CardButtons += $dl
        }
        if ($pk.State -ne 'none' -and -not $isApplied) {       # скачанный, но не применённый пак можно убрать с диска (карточка остаётся, «Скачать» вернёт файлы)
            $del = New-Object System.Windows.Controls.Button
            $del.Style = (Get-Res 'GhostButton')
            $del.Content = $script:T.Delete
            $del.Tag = $pk.Id
            $del.MinWidth = 40
            $del.Width = 40
            $del.Padding = New-Object System.Windows.Thickness(0)
            $del.HorizontalAlignment = 'Right'
            $del.ToolTip = ($script:T.DeleteTip -f $diskText)
            $del.Add_Click({ param($s, $e) try { Invoke-DeletePack ([string]$s.Tag) } catch { Show-Error $_ 'Удалить пак' } })
            [System.Windows.Controls.Grid]::SetColumn($del, 2)
            [void]$row.Children.Add($del)
            $script:CardButtons += $del
        }
        [System.Windows.Controls.Grid]::SetRow($row, 4)
        [void]$sp.Children.Add($row)
        $card.Child = $sp
        $card.Add_MouseLeftButtonUp({
            param($s, $e)
            try {
                $id = [string]$s.Tag
                if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) { Set-PackChecked $id (-not $script:Checked.ContainsKey($id)); return }      # Ctrl + щелчок: выбрать / снять
                Select-Pack $id
            } catch { Show-Error $_ 'выбор пака' }
        })
        [void]$script:ui.PackList.Children.Add($card)
        $script:Cards[$pk.Id] = $card
      } catch { Show-Error $_ ('карточка пака ' + $pk.Id) }      # одна неудачная карточка не должна оставлять без списка остальные
    }
    Update-CardHighlight
    Update-SelBar
}

# ---- панель «Что поменяется» ----
function New-MatchRow {
    param([string]$ImgPath, [string]$Title, [string]$Sub, [string]$PillText, [string]$Tip)
    $row = New-Object System.Windows.Controls.Border
    $row.Background = (Get-Res 'RowBrush')
    $row.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $row.Padding = New-Object System.Windows.Thickness(10, 0, 10, 0)
    $row.Height = 58
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $row.SnapsToDevicePixels = $true
    $row.ToolTip = $Tip
    $g = New-Object System.Windows.Controls.Grid
    $d1 = New-Object System.Windows.Controls.ColumnDefinition; $d1.Width = [System.Windows.GridLength]::Auto
    $d2 = New-Object System.Windows.Controls.ColumnDefinition; $d2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $d3 = New-Object System.Windows.Controls.ColumnDefinition; $d3.Width = [System.Windows.GridLength]::Auto
    [void]$g.ColumnDefinitions.Add($d1); [void]$g.ColumnDefinitions.Add($d2); [void]$g.ColumnDefinitions.Add($d3)
    $im = New-Object System.Windows.Controls.Image
    $im.Width = 34; $im.Height = 34
    $im.VerticalAlignment = 'Center'
    $src = New-Img $ImgPath 68
    if ($src) { $im.Source = $src }
    [void]$g.Children.Add($im)
    $tx = New-Object System.Windows.Controls.StackPanel
    $tx.Margin = New-Object System.Windows.Thickness(12, 0, 8, 0)
    $tx.VerticalAlignment = 'Center'
    $n1 = New-Text $Title 13 'TextBrush' 'SemiBold'
    $n1.TextTrimming = 'CharacterEllipsis'
    [void]$tx.Children.Add($n1)
    $n2 = New-Text $Sub 11 'MutedBrush'
    $n2.TextTrimming = 'CharacterEllipsis'
    [void]$tx.Children.Add($n2)
    [System.Windows.Controls.Grid]::SetColumn($tx, 1)
    [void]$g.Children.Add($tx)
    $pill = New-Object System.Windows.Controls.Border
    $pill.Background = (Get-Res 'GhostBrush')
    $pill.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $pill.Padding = New-Object System.Windows.Thickness(8, 3, 8, 3)
    $pill.VerticalAlignment = 'Center'
    $pill.MaxWidth = 140
    $pill.Child = New-Text $PillText 11 'MutedBrush'
    $pill.Child.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetColumn($pill, 2)
    [void]$g.Children.Add($pill)
    $row.Child = $g
    return $row
}

function Get-GroupTitle {
    param([string]$Key)
    $k = 'Group_' + $(if ($Key) { $Key } else { 'other' })
    if ($script:T.ContainsKey($k)) { return [string]$script:T[$k] }
    return ($Key.Substring(0, 1).ToUpper() + $Key.Substring(1))
}

function New-GroupHeader {
    param([string]$Text)
    $tb = New-Text $Text 12 'MutedBrush' 'SemiBold'
    $tb.Margin = New-Object System.Windows.Thickness(2, 8, 0, 6)
    return $tb
}

# ---- автоиконки: превью в фоне и выбор режима ----
function Get-AutoWanted { return [bool]$script:ui.ChkAuto.IsChecked }

function New-AutoChip {
    param([string]$Mode)
    $c = New-Object System.Windows.Controls.Border
    $c.CornerRadius = New-Object System.Windows.CornerRadius(7)
    $c.Padding = New-Object System.Windows.Thickness(9, 2, 9, 2)
    $c.Margin = New-Object System.Windows.Thickness(0, 0, 6, 0)
    $c.Cursor = [System.Windows.Input.Cursors]::Hand
    $c.ToolTip = $script:T['AutoModeTip_' + $Mode]
    $c.Child = New-Text $script:T['AutoMode_' + $Mode] 11 'MutedBrush'
    return $c
}

function Set-AutoChipLook {
    param($Chips, [string]$Mode)
    foreach ($c in @($Chips)) {
        if ([string]$c.Tag.Mode -eq $Mode) { $c.Background = (Get-Res 'AccentBrush'); $c.Child.Foreground = (Get-Res 'TextBrush') }
        else { $c.Background = (Get-Res 'GhostBrush'); $c.Child.Foreground = (Get-Res 'MutedBrush') }
    }
}

# режим приложения: в state.json и во всех его строках (ярлыки в разных папках и плитка делят один режим)
function Set-AutoRowsMode {
    param([string]$Key, [string]$Mode)
    foreach ($r in @($script:AutoRows[$Key])) {
        Set-AutoChipLook $r.Chips $Mode
        $r.Row.Opacity = if ($Mode -eq 'Auto') { 1.0 } else { 0.6 }
    }
}

# строка автоиконки: превью, имя, значок «авто» и выбор режима (Авто / Родная / Не трогать)
function New-AutoRow {
    param($M, [bool]$IsTile)
    $row = New-Object System.Windows.Controls.Border
    $row.Background = (Get-Res 'RowBrush')
    $row.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $row.Padding = New-Object System.Windows.Thickness(10, 6, 10, 6)
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $row.SnapsToDevicePixels = $true
    $row.ToolTip = $(if ($IsTile) { [string]$M.TileId } else { [string]$M.Path })
    $g = New-Object System.Windows.Controls.Grid
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength(46)
    $r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = [System.Windows.GridLength]::Auto
    [void]$g.RowDefinitions.Add($r1); [void]$g.RowDefinitions.Add($r2)
    $top = New-Object System.Windows.Controls.Grid
    $d1 = New-Object System.Windows.Controls.ColumnDefinition; $d1.Width = [System.Windows.GridLength]::Auto
    $d2 = New-Object System.Windows.Controls.ColumnDefinition; $d2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $d3 = New-Object System.Windows.Controls.ColumnDefinition; $d3.Width = [System.Windows.GridLength]::Auto
    [void]$top.ColumnDefinitions.Add($d1); [void]$top.ColumnDefinitions.Add($d2); [void]$top.ColumnDefinitions.Add($d3)
    $im = New-Object System.Windows.Controls.Image
    $im.Width = 34; $im.Height = 34
    $im.VerticalAlignment = 'Center'
    $prev = $(if ($IsTile) { [string]$M.TilePath } else { [string]$M.PngPath })
    [void](Set-ImageSource $im (New-Img $prev 68))
    [void]$top.Children.Add($im)
    $thumbKey = [string]$M.SafeKey + $(if ($IsTile) { '|t' } else { '|l' })
    if (-not $script:AutoThumbs.ContainsKey($thumbKey)) { $script:AutoThumbs[$thumbKey] = New-Object 'System.Collections.Generic.List[System.Windows.Controls.Image]' }
    $script:AutoThumbs[$thumbKey].Add($im)
    $tx = New-Object System.Windows.Controls.StackPanel
    $tx.Margin = New-Object System.Windows.Thickness(12, 0, 8, 0)
    $tx.VerticalAlignment = 'Center'
    $n1 = New-Text ([string]$M.Name) 13 'TextBrush' 'SemiBold'
    $n1.TextTrimming = 'CharacterEllipsis'
    [void]$tx.Children.Add($n1)
    $sub = $(if ($IsTile) { $script:T.AutoTileSub -f $M.TileId } else { $script:T.AutoSub })
    if ($M.Already) { $sub += ' · ' + $script:T.AlreadySet }
    $n2 = New-Text $sub 11 'MutedBrush'
    $n2.TextTrimming = 'CharacterEllipsis'
    [void]$tx.Children.Add($n2)
    [System.Windows.Controls.Grid]::SetColumn($tx, 1)
    [void]$top.Children.Add($tx)
    $badge = New-Object System.Windows.Controls.Border
    $badge.Background = (Get-Res 'AccentBrush')
    $badge.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $badge.Padding = New-Object System.Windows.Thickness(8, 2, 8, 2)
    $badge.VerticalAlignment = 'Center'
    $badge.Child = New-Text $script:T.AutoBadge 11 'TextBrush' 'SemiBold'
    [System.Windows.Controls.Grid]::SetColumn($badge, 2)
    [void]$top.Children.Add($badge)
    [void]$g.Children.Add($top)
    $chipRow = New-Object System.Windows.Controls.StackPanel
    $chipRow.Orientation = 'Horizontal'
    $chipRow.Margin = New-Object System.Windows.Thickness(46, 2, 0, 0)
    $chips = @()
    foreach ($mode in @('Auto', 'Native', 'Off')) {
        $c = New-AutoChip $mode
        $c.Tag = @{ Key = [string]$M.AutoKey; Mode = $mode; Name = [string]$M.Name }
        $c.Add_MouseLeftButtonUp({
            param($s, $e)
            try {
                $t = $s.Tag
                Set-AutoOverride $t.Key $t.Mode
                Set-AutoRowsMode $t.Key $t.Mode
                Set-Status ($script:T.AutoModeSet -f $t.Name, $script:T['AutoMode_' + $t.Mode])
            } catch { Show-Error $_ 'режим автоиконки' }
        })
        [void]$chipRow.Children.Add($c)
        $chips += $c
    }
    [System.Windows.Controls.Grid]::SetRow($chipRow, 1)
    [void]$g.Children.Add($chipRow)
    $row.Child = $g
    $key = [string]$M.AutoKey
    if (-not $script:AutoRows.ContainsKey($key)) { $script:AutoRows[$key] = New-Object 'System.Collections.Generic.List[object]' }
    $script:AutoRows[$key].Add(@{ Row = $row; Chips = $chips })
    Set-AutoChipLook $chips ([string]$M.AutoMode)
    if ([string]$M.AutoMode -ne 'Auto') { $row.Opacity = 0.6 }
    return $row
}

function Set-AutoThumb {
    param([string]$Line)
    $p = $Line.Split('|')
    if ($p.Count -lt 3) { return }
    $k = $p[0] + '|' + $p[1]
    if (-not $script:AutoThumbs.ContainsKey($k)) { return }
    $path = $Line.Substring($p[0].Length + $p[1].Length + 2)
    $src = New-Img $path 68
    if (-not $src) { return }
    foreach ($it in @($script:AutoThumbs[$k])) { [void](Set-ImageSource $it $src) }
}

# превью автоиконок создаёт отдельное фоновое задание (свой runspace): список остаётся отзывчивым, картинки появляются по мере готовности
function Stop-AutoPreviews {
    $j = $script:PrevJob
    if ($j) {
        try { $j.Ctl['Stop'] = $true } catch { }
        $script:PrevOld = @($script:PrevOld) + @($j)
        $script:PrevJob = $null
    }
}

function Start-AutoPreviews {
    param($Links, $Tiles)
    Stop-AutoPreviews
    if ($script:Closing -or -not $script:SelectedId) { return }
    $its = @(@($Links) + @($Tiles) | Where-Object { (Test-AutoItem $_) -and [string]$_.AutoMode -eq 'Auto' })
    if ($its.Count -eq 0) { return }
    $out = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $ctl = @{ Stop = $false }
    try {
        $j = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Params @{ Id = [string]$script:SelectedId; Items = $its; Out = $out; Ctl = $ctl; NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
$pk = @(Get-Packs) | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
if (-not $pk) { return }
$auto = Get-PackAuto $pk
if (-not $auto) { return }
[void](Initialize-AutoNative)
$bk = @{}
try { $bk = Load-Backup } catch { }
foreach ($it in @($p.Items)) {
    if ($p.Ctl['Stop']) { break }
    try {
        $isTile = [bool]$it.PSObject.Properties['TileId']
        [void](New-AutoFiles $it $auto ([string]$p.Id) $bk ([bool]$p.NoName))
        $pp = Get-AutoPaths ([string]$p.Id) ([string]$it.SafeKey)
        $p.Out.Enqueue(([string]$it.SafeKey + '|' + $(if ($isTile) { 't' } else { 'l' }) + '|' + $(if ($isTile) { $pp.Tile } else { $pp.Png })))
    } catch { Write-Log ('  автоиконка ' + [string]$it.Name + ': ' + $_.Exception.Message) }
}
'@
        $j.Out = $out; $j.Ctl = $ctl
        $script:PrevJob = $j
        $script:PrevTimer.Start()
    } catch { $script:PrevJob = $null; Write-Log ('Превью автоиконок не запущено: ' + $_.Exception.Message) }
}

function Step-Previews {
    $j = $script:PrevJob
    $line = $null
    if ($j) {
        while ($j.Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
        while ($j.Out.TryDequeue([ref]$line)) { Set-AutoThumb $line }
        if ($j.Async.IsCompleted) {
            while ($j.Out.TryDequeue([ref]$line)) { Set-AutoThumb $line }
            [void](Receive-EngineJob $j)
            $script:PrevJob = $null
        }
    }
    $left = @()
    foreach ($o in @($script:PrevOld)) {
        if ($o.Async.IsCompleted) { [void](Receive-EngineJob $o) } else { $left += $o }
    }
    $script:PrevOld = $left
    if (-not $script:PrevJob -and $script:PrevOld.Count -eq 0) { $script:PrevTimer.Stop() }
}

# ярлыки и плитки, сгруппированные по группе иконки (apps, games, system, work, creative, автоиконки, прочее); внутри группы - по названию
function Fill-Matches {
    param($Matches2, $TileMatches)
    Stop-AutoPreviews
    $script:ui.MatchList.Children.Clear()
    $script:AutoThumbs = @{}; $script:AutoRows = @{}
    $all = @($Matches2 | Where-Object { $_ })
    $allT = @($TileMatches | Where-Object { $_ -and -not (Test-UrlTileId ([string]$_.TileId)) })       # плитки-ссылки (https://...) в списке не показываем
    $items = @($all | Where-Object { -not (Test-AutoItem $_) })
    $tiles = @($allT | Where-Object { -not (Test-AutoItem $_) })
    $autoCount = @($all | Where-Object { Test-AutoItem $_ }).Count + @($allT | Where-Object { Test-AutoItem $_ }).Count
    $same = 0; $tsame = 0
    foreach ($g in @(Get-MatchGroups $all $allT)) {
        [void]$script:ui.MatchList.Children.Add((New-GroupHeader ($script:T.GroupHeader -f (Get-GroupTitle ([string]$g.Group)), $g.Count)))
        foreach ($r in $g.Rows) {
          try {
            $m = $r.Item
            if (Test-AutoItem $m) {
                [void]$script:ui.MatchList.Children.Add((New-AutoRow $m ($r.Kind -eq 'tile')))
            } elseif ($r.Kind -eq 'link') {
                if ($m.Already) { $same++ }
                $sub = "{0}: {1}" -f $script:T.IconWord, $m.IconName
                if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
                $locKey = 'Loc_' + [string]$m.Location
                $pillText = if ($script:T.ContainsKey($locKey)) { $script:T[$locKey] } else { [string]$m.Location }
                [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.PngPath ([string]$m.Name) $sub $pillText ([string]$m.Path)))
            } else {
                if ($m.Already) { $tsame++ }
                $title = Get-TileTitle $m                                  # имя приложения; сырой id - только в серой строке ниже
                $sub = $script:T.TileSub -f $m.IconName, $m.TileId
                if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
                [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.TilePath $title $sub $script:T.TilesPill ([string]$m.TileId)))
            }
          } catch { Show-Error $_ 'строка списка' }
        }
    }
    if ($items.Count -eq 0 -and $tiles.Count -eq 0 -and $autoCount -eq 0) {
        $s = $script:T.NoneFound
    } else {
        $s = if ($items.Count -gt 0) { $script:T.Found -f $items.Count } else { '' }
        if ($same -gt 0) { $s += ($script:T.FoundSame -f $same) }
        if ($tiles.Count -gt 0) {
            if ($s) { $s += "`n" }
            $s += ($script:T.TilesFound -f $tiles.Count)
            if ($tsame -gt 0) { $s += ($script:T.FoundSame -f $tsame) }
        }
        if ($autoCount -gt 0) {
            if ($s) { $s += "`n" }
            $s += ($script:T.AutoFound -f $autoCount)
        }
    }
    if (-not [bool]$script:ui.ChkAllUsers.IsChecked) { $s += "`n" + $script:T.AdminNote }
    $sel = $script:Packs | Where-Object { $_.Id -eq $script:SelectedId } | Select-Object -First 1
    if ($sel -and $sel.State -ne 'ready') { $s += "`n" + $script:T.NotReadyNote }
    if ($sel -and (Get-AutoWanted) -and -not $sel.AutoDeclared) { $s += "`n" + $script:T.AutoNotSupported }
    $script:ui.TxtMatchSummary.Text = $s
    Start-AutoPreviews $all $allT
}

# плитки Start11 включены: Start11 найден и галочка стоит
function Get-TilesWanted {
    return [bool]($script:HasStart11 -and [bool]$script:ui.ChkTiles.IsChecked)
}

function Select-Pack {
    param([string]$Id)
    if (-not $Id) { return }
    $script:SelectedId = $Id
    Update-CardHighlight
    if ($script:Job -or $script:BgPending) { $script:PendingSelect = $Id; return }
    $pk = $script:Packs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $pk) { return }
    $script:ui.TxtSelectedPack.Text = $script:T.PackLine -f ('{0} {1}' -f $pk.Name, $pk.Version)
    $script:ui.MatchList.Children.Clear()
    $script:ui.TxtMatchSummary.Text = $script:T.Scanning
    Stop-AutoPreviews
    Start-Bg -Title $script:T.Scanning -Params @{ Id = $Id; All = [bool]$script:ui.ChkAllUsers.IsChecked; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked; Auto = (Get-AutoWanted) } -Body @'
param($p)
$pk = @(Get-Packs) | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
if (-not $pk) { throw 'Пак не найден' }
$au = [bool]$p.Auto
$tm = @()
if ($p.Tiles) { try { $tm = @(Get-Start11Matches -Pack $pk -NoName:([bool]$p.NoName) -Auto:$au) } catch { Write-Log ('Плитки Start11: ' + $_.Exception.Message) } }
[pscustomobject]@{ Matches = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All) -Auto:$au); TileMatches = $tm }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'сканирование ярлыков'; $script:ui.TxtMatchSummary.Text = ''; return }
        Fill-Matches $res.Matches $res.TileMatches
        Set-Status $script:T.Ready
    }
}

# ---- действия ----
function Invoke-Apply {
    param([string]$Id)
    if (Test-LegacyMigrationIncomplete) {       # бэкап прежней версии ещё не перенесён: применять нельзя (Apply-Pack откажет и сам)
        Show-Error $script:SI_MigrationPendingMsg
        [void][System.Windows.MessageBox]::Show($script:SI_MigrationPendingMsg, 'Glyphix', 'OK', 'Warning')
        return
    }
    $script:SelectedId = $Id
    Update-CardHighlight
    Stop-AutoPreviews
    $all = [bool]$script:ui.ChkAllUsers.IsChecked
    $restart = [bool]$script:ui.ChkRestart.IsChecked
    # общие ярлыки при обычных правах: один раз перезапускаем этот скрипт с UAC (режим CLI) и ждём его завершения
    $elevate = ($all -and -not (Test-Admin))
    Start-Bg -WaitSilent -Title $script:T.Applying -Params @{ Id = $Id; Restart = $restart; All = $all; Elevate = $elevate; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked; Auto = (Get-AutoWanted) } -Body @'
param($p)
# 1) index.json + pack.json этого пака + нужные файлы (иконки, плитки) качаем СЕЙЧАС, до повышения прав; 2) пак заново читаем с диска - ярлыки и плитки ищем и применяем только по свежему паку
$pk = Sync-PackForApply -Id ([string]$p.Id) -Parts (Get-PackParts -Tiles ([bool]$p.Tiles) -NoName ([bool]$p.NoName))
# плитки Start11 - в реестре текущего пользователя: применяем здесь, а не в повышенном процессе (там -NoTiles)
$tr = $null
$au = [bool]$p.Auto
$doTiles = { param($packObj)
    if (-not $p.Tiles) { return $null }
    try { return (Apply-Start11Tiles -Pack $packObj -NoName:([bool]$p.NoName) -NoAuto:(-not $au)) } catch { Write-Log ('Плитки Start11: ' + $_.Exception.Message); return [pscustomobject]@{ Changed = 0; Same = 0; Failed = 1; Hint = '' } }
}
$getTiles = { param($packObj)
    if (-not $p.Tiles) { return @() }
    try { return @(Get-Start11Matches -Pack $packObj -NoName:([bool]$p.NoName) -Auto:$au) } catch { return @() }
}
if ($p.Elevate) {
    $a = @('-Cli', '-Apply', [string]$p.Id, '-AllUsers', '-NoTiles')
    if (-not $p.Restart) { $a += '-NoRestart' }
    if (-not $au) { $a += '-NoAuto' }
    $er = Invoke-ElevatedCli -CliArgs $a
    $tr = & $doTiles $pk
    $cl = $null
    if ($er.Started -and -not $er.Cancelled -and [int]$er.ExitCode -eq 0) { try { $cl = Clear-UnusedCopies } catch { Write-Log ('Очистка копий: ' + $_.Exception.Message) } }       # применено - неиспользуемые копии других паков и старых версий удаляем (после плиток)
    return [pscustomobject]@{ Elevated = $true; Elev = $er; Tiles = $tr; Cleanup = $cl; Matches = @(Get-Matches -Pack $pk -AllUsers:$true -Auto:$au); TileMatches = @(& $getTiles $pk); PackName = $pk.Name; PackVersion = [string]$pk.Version; FromCache = [bool]$pk.FromCache }
}
$items = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All) -Auto:$au)
$r = Apply-Pack -Pack $pk -Items $items -RestartExplorer:([bool]$p.Restart) -NoAuto:(-not $au)
$tr = & $doTiles $pk
$cl = $null
if ($r.Failed -eq 0 -and ($r.Changed + $r.Same) -gt 0) { try { $cl = Clear-UnusedCopies } catch { Write-Log ('Очистка копий: ' + $_.Exception.Message) } }       # применено без ошибок - неиспользуемые копии других паков и старых версий удаляем (после плиток)
[pscustomobject]@{ Elevated = $false; Result = $r; Tiles = $tr; Cleanup = $cl; Matches = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All) -Auto:$au); TileMatches = @(& $getTiles $pk); PackName = $pk.Name; PackVersion = [string]$pk.Version; FromCache = [bool]$pk.FromCache }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'применение'; return }
        if ($res.Elevated) {
            $code = [int]$res.Elev.ExitCode
            if ($res.Elev.Cancelled) { Set-Status $script:T.ElevCancel }
            elseif ($code -eq 0) { Set-Status $script:T.ElevDone }
            elseif ($code -eq 3) { Set-Status $script:T.ElevRefused }
            else { Set-Status ($script:T.ElevFail -f $code) }
            if ($res.FromCache) { Set-Status ($script:ui.TxtStatus.Text + ' | ' + ($script:T.ApplyCached -f $res.PackVersion)) }
        } else {
            $r = $res.Result
            $s = $script:T.ApplyDone -f ('{0} {1}' -f $r.PackName, $r.PackVersion).Trim(), $r.Changed, $r.Same
            if ($r.Failed -gt 0) { $s += ($script:T.ApplyFail -f $r.Failed) }
            if ($r.Auto -gt 0) { $s += ($script:T.ApplyAuto -f $r.Auto) }
            $rh = ''
            try { if ($r.PSObject.Properties['Running']) { $rh = Format-RunningHint @($r.Running) } } catch { }       # приложение запущено - окно может показывать прежнюю иконку (один раз, до 3 имён)
            if ($rh) { $s += ' | ' + $rh }
            if ($r.FromCache) { $s += ' | ' + ($script:T.ApplyCached -f $r.PackVersion) }       # GitHub недоступен: применён кэш - показываем, чтобы «уже стояли» не казалось поломкой
            Set-Status $s
        }
        if ($res.Tiles) {
            $ts = $script:T.TilesDone -f $res.Tiles.Changed, $res.Tiles.Same
            if ($res.Tiles.Failed -gt 0) { $ts += ($script:T.TilesFail -f $res.Tiles.Failed) }
            if ($res.Tiles.Hint) { $ts += '. ' + $res.Tiles.Hint }
            Set-Status ($script:ui.TxtStatus.Text + ' | ' + $ts)
        }
        if ($res.Cleanup -and [long]$res.Cleanup.Bytes -gt 0) { Set-Status ($script:ui.TxtStatus.Text + ' | ' + ($script:T.Freed -f (Format-DownloadSize ([long]$res.Cleanup.Bytes)))) }
        Set-WindowIcon                 # иконка приложения из применённого пака (если в паке есть 'glyphix') - сразу, без перезапуска
        Rebuild-Packs
        $pk = $script:Packs | Where-Object { $_.Id -eq $script:SelectedId } | Select-Object -First 1
        if ($pk) { $script:ui.TxtSelectedPack.Text = $script:T.PackLine -f ('{0} {1}' -f $pk.Name, $pk.Version) }
        Fill-Matches $res.Matches $res.TileMatches
    }
}

function Invoke-Update {
    param([bool]$FirstRun = $false)
    $title = if ($FirstRun) { $script:T.FirstRun } else { $script:T.Updating }
    Start-Bg -WaitSilent -Title $title -Params @{} -Body @'
param($p)
Update-Packs
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'обновление паков' }
        elseif ($res -and -not $res.Ok -and $res.Downloaded -eq 0) { Set-Status $script:T.Offline }
        elseif ($res) { Set-Status $res.Message }
        Rebuild-Packs
        if (-not $script:SelectedId -or -not $script:Cards.ContainsKey($script:SelectedId)) {
            $st = Read-State
            $first = $null
            if ($st.ContainsKey('Applied') -and $st['Applied'] -and $script:Cards.ContainsKey([string]$st['Applied'].PackId)) { $first = [string]$st['Applied'].PackId }
            elseif ($script:Packs.Count -gt 0) { $first = $script:Packs[0].Id }
            $script:SelectedId = $first
        }
        if ($script:SelectedId) { Select-Pack $script:SelectedId } else { $script:ui.MatchList.Children.Clear(); $script:ui.TxtMatchSummary.Text = '' }
    }
}

function Invoke-Download {
    param([string]$Id)
    # иконки - всегда; плитки Start11 - только если включены; плитки без подписи - только если выбрано «без подписи» (остальное докачается при применении)
    Start-Bg -WaitSilent -Title $script:T.Downloading -Params @{ Id = $Id; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
Install-Pack -Id ([string]$p.Id) -Parts (Get-PackParts -Tiles ([bool]$p.Tiles) -NoName ([bool]$p.NoName))
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'скачивание пака' }
        elseif ($res) { Set-Status ($script:T.DownloadDone -f $res.Downloaded) }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

# выбранные паки (галочки на карточках) - одним заданием; уже скачанные свежие пропускаются
function Invoke-DownloadSelected {
    $ids = @($script:Checked.Keys | Where-Object { $_ })
    if ($ids.Count -eq 0) { Set-Status $script:T.SelNothing; return }
    Start-Bg -WaitSilent -Title $script:T.SelDownloading -Params @{ Ids = [string[]]$ids; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
Install-Packs -Ids ([string[]]$p.Ids) -Parts (Get-PackParts -Tiles ([bool]$p.Tiles) -NoName ([bool]$p.NoName))
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'скачивание выбранных паков' }
        elseif ($res) {
            $s = $script:T.SelDone -f $res.Downloaded, $res.Files
            if (@($res.Skipped).Count -gt 0) { $s += ($script:T.SelSkipped -f @($res.Skipped).Count) }
            if (@($res.Failed).Count -gt 0) { $s += ($script:T.SelFailed -f @($res.Failed).Count) }
            if ($res.Downloaded -eq 0 -and @($res.Failed).Count -eq 0 -and @($res.Skipped).Count -gt 0) { $s = $script:T.SelAllFresh }
            Set-Status $s
            $bad = @{}; foreach ($f in @($res.Failed)) { $bad[[string]$f.Id] = $true }
            foreach ($k in @($script:Checked.Keys)) { if (-not $bad.ContainsKey([string]$k)) { $script:Checked.Remove($k) } }      # скачанное и пропущенное снимаем, неудавшиеся остаются отмеченными
        }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

# убрать с диска скачанные файлы одного (не применённого) пака
function Invoke-DeletePack {
    param([string]$Id)
    Start-Bg -WaitSilent -Title $script:T.Deleting -Params @{ Id = $Id } -Body @'
param($p)
Remove-PackDownload -Id ([string]$p.Id)
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'удаление пака' }
        elseif ($res -and $res.Ok) { Set-Status ($script:T.DeleteDone -f $res.Message) }
        elseif ($res) { Set-Status ($script:T.DeleteFail -f $res.Message) }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

# «Очистить кэш»: скачанные паки, кроме применённого, остатки прежних версий и ненужные копии иконок/плиток
function Invoke-ClearCache {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmCache, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Bg -WaitSilent -Title $script:T.ClearingCache -Params @{} -Body @'
param($p)
Clear-PackCache
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'очистка кэша'; return }
        if ($res) { Set-Status ($script:T.CacheDone -f (Format-DownloadSize ([long]$res.Bytes))) }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

function Invoke-Undo {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUndo, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Stop-AutoPreviews
    Start-Bg -WaitSilent -Title $script:T.Undoing -Params @{ Restart = [bool]$script:ui.ChkRestart.IsChecked } -Body @'
param($p)
Undo-Routed -RestartExplorer:([bool]$p.Restart)
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Откат не вернул результат'; return }
        if ($res.Error) { Show-Error $res 'откат'; return }
        if ($res.Nothing) { Set-Status $script:T.UndoNothing }
        else {
            $s = $script:T.UndoDone -f $res.Restored
            if ($res.TilesRestored -gt 0) { $s += ($script:T.TilesUndone -f $res.TilesRestored) }
            if ($res.Failed -gt 0) { $s += ($script:T.UndoFail -f $res.Failed) }
            if ($res.Hint) { $s += '. ' + $res.Hint }
            Set-Status $s
        }
        Set-WindowIcon                 # откат убрал AppIcon из state.json - возвращаем assets\app.ico
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

function Invoke-Uninstall {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUn, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Stop-AutoPreviews
    Start-Bg -WaitSilent -Title $script:T.Uninstalling -Params @{ Restart = [bool]$script:ui.ChkRestart.IsChecked } -Body @'
param($p)
Uninstall-App -RestartExplorer:([bool]$p.Restart)
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Удаление не вернуло результат'; return }
        if ($res.Error) { Show-Error $res 'удаление'; return }
        if ($res.Aborted) { Set-Status $res.Message; return }       # откат не удался - приложение остаётся
        # приложение удалено: этот процесс (отдельная копия движка) больше не пишет журнал, иначе он воссоздал бы папку данных
        $script:SI_NoLogFile = $true
        try { foreach ($lf in @($script:SI_LogFile, ($script:SI_LogFile + '.old'))) { if (Test-Path -LiteralPath $lf) { Remove-Item -LiteralPath $lf -Force } } } catch { }
        try { if ((Test-Path -LiteralPath $script:SI_Home) -and -not (Get-ChildItem -LiteralPath $script:SI_Home -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $script:SI_Home -Recurse -Force -Confirm:$false } } catch { }
        Set-Status $script:T.Removed
        $script:Window.Close()
    }
}

# ---- привязка текстов и событий ----
$script:ui.TxtVersion.Text = 'v' + (Get-AppVersion)
$script:ui.TxtAdmin.Text = if (Test-Admin) { $script:T.Admin } else { $script:T.NoAdmin }
$script:ui.TxtPacksTitle.Text = $script:T.Packs
$script:ui.TxtMatchTitle.Text = $script:T.WillChange
$script:ui.TxtSelectedPack.Text = $script:T.NoPackSel
$script:ui.BtnUpdate.Content = $script:T.Update
$script:ui.BtnUndo.Content = $script:T.Undo
$script:ui.BtnOpen.Content = $script:T.Open
$script:ui.BtnUninstall.Content = $script:T.Uninstall
$script:ui.BtnClearCache.Content = $script:T.ClearCache
$script:ui.BtnSelDownload.Content = $script:T.SelDownload
$script:ui.BtnSelDownload.ToolTip = $script:T.SelTip
$script:ui.BtnSelAll.Content = $script:T.SelAll
$script:ui.BtnSelNone.Content = $script:T.SelNone
Update-SelBar
$script:ui.ChkRestart.Content = $script:T.Restart
$script:ui.ChkAllUsers.Content = $script:T.AllUsers
$script:ui.ChkAllUsers.ToolTip = $script:T.AllUsersTip
$script:ui.ChkRestart.ToolTip = $script:T.RestartTip
$script:ui.ChkTiles.Content = $script:T.Tiles
$script:ui.ChkNoName.Content = $script:T.TilesNoName
$script:ui.ChkAuto.Content = $script:T.Auto
$script:ui.ChkAuto.ToolTip = $script:T.AutoTip
$script:ui.ChkAuto.IsChecked = (Get-AutoEnabled)
# галочки плиток видны только если Start11 найден (ключ реестра есть)
$script:ui.ChkTiles.Visibility = if ($script:HasStart11) { 'Visible' } else { 'Collapsed' }
$script:ui.ChkNoName.Visibility = if ($script:HasStart11) { 'Visible' } else { 'Collapsed' }
$script:ui.ChkTiles.IsEnabled = $script:HasStart11
$script:ui.ChkNoName.IsEnabled = $script:HasStart11
$script:ui.BtnLog.Content = $script:T.LogShow
$script:ui.TxtStatus.Text = $script:T.Ready
$script:Window.Title = $script:T.Title

$logo = New-Img (Join-Path (Join-Path $script:Root 'assets') 'logo_tile.png') 96
if ($logo) { $script:ui.ImgLogo.Source = $logo }
# иконка окна: иконка 'glyphix' применённого пака (state.json -> AppIcon), иначе assets\app.ico; BitmapFrame + OnLoad - файл не остаётся занятым
function Set-WindowIcon {
    try {
        $fallback = Join-Path (Join-Path $script:Root 'assets') 'app.ico'
        $icoPath = Get-AppIconPath $fallback
        foreach ($cand in @($icoPath, $fallback)) {
            if (-not $cand -or -not (Test-Path -LiteralPath $cand -PathType Leaf)) { continue }
            try {
                $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($cand)), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
                return
            } catch { Write-Log ('иконка окна не загружена: ' + $cand + ' - ' + $_.Exception.Message) }
        }
    } catch { }
}
Set-WindowIcon

Set-EngineLogHandler { param($m) Add-LogLine $m }

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick({ try { Step-Job } catch { Show-Error $_ 'таймер' } })

$script:PrevTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:PrevTimer.Interval = [TimeSpan]::FromMilliseconds(200)
$script:PrevTimer.Add_Tick({ try { Step-Previews } catch { Show-Error $_ 'превью автоиконок' } })

$script:SilentTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SilentTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:SilentTimer.Add_Tick({ try { Step-SilentRefresh } catch { Write-Log ('тихое обновление паков: ' + $_.Exception.Message) } })

$script:WaitTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WaitTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:WaitTimer.Add_Tick({ try { Step-BgPending } catch { $script:WaitTimer.Stop(); $script:BgPending = $null; Set-Busy $false; Show-Error $_ 'ожидание обновления паков' } })

$script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:UpdTimer.Add_Tick({ try { Step-UpdateCheck } catch { } })

$script:ui.BtnUpdate.Add_Click({ try { Invoke-Update; Start-UpdateCheck } catch { Show-Error $_ 'Обновить паки' } })
$script:ui.BtnAppUpdate.Add_Click({ try { Invoke-AppUpdate } catch { Show-Error $_ 'Обновить приложение' } })
$script:ui.BtnUndo.Add_Click({ try { Invoke-Undo } catch { Show-Error $_ 'Откатить' } })
$script:ui.BtnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:DataHome)) { New-Item -ItemType Directory -Path $script:DataHome -Force | Out-Null }
        Start-Process -FilePath $script:DataHome
    } catch { Show-Error $_ }
})
$script:ui.ChkAllUsers.Add_Click({ try { if ($script:SelectedId) { Select-Pack $script:SelectedId } } catch { Show-Error $_ 'общие ярлыки' } })
$script:ui.ChkTiles.Add_Click({
    try {
        $script:ui.ChkNoName.IsEnabled = ($script:HasStart11 -and [bool]$script:ui.ChkTiles.IsChecked)
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    } catch { Show-Error $_ }
})
$script:ui.ChkNoName.Add_Click({ try { if ($script:SelectedId) { Select-Pack $script:SelectedId } } catch { Show-Error $_ 'плитки без подписи' } })
$script:ui.ChkAuto.Add_Click({
    try {
        Set-AutoEnabled ([bool]$script:ui.ChkAuto.IsChecked)
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    } catch { Show-Error $_ 'автоиконки' }
})
$script:ui.BtnMenu.Add_Click({ try { $script:ui.PopMenu.IsOpen = (-not $script:ui.PopMenu.IsOpen) } catch { Show-Error $_ 'меню' } })
$script:ui.BtnClearCache.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Invoke-ClearCache } catch { Show-Error $_ 'Очистить кэш' } })
$script:ui.BtnSelDownload.Add_Click({ try { Invoke-DownloadSelected } catch { Show-Error $_ 'Скачать выбранные' } })
$script:ui.BtnSelAll.Add_Click({ try { foreach ($pk in @($script:Packs)) { $script:Checked[[string]$pk.Id] = $true; if ($script:CardChecks.ContainsKey([string]$pk.Id)) { $script:CardChecks[[string]$pk.Id].IsChecked = $true } }; Update-SelBar } catch { Show-Error $_ 'Выбрать все' } })
$script:ui.BtnSelNone.Add_Click({ try { $script:Checked.Clear(); foreach ($ck in @($script:CardChecks.Values)) { $ck.IsChecked = $false }; Update-SelBar } catch { Show-Error $_ 'Снять выбор' } })
$script:ui.BtnUninstall.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Invoke-Uninstall } catch { Show-Error $_ 'Удалить приложение' } })
$script:ui.BtnLog.Add_Click({
    try {
        if ($script:ui.LogPanel.Visibility -eq 'Visible') { $script:ui.LogPanel.Visibility = 'Collapsed'; $script:ui.BtnLog.Content = $script:T.LogShow }
        else { $script:ui.LogPanel.Visibility = 'Visible'; $script:ui.BtnLog.Content = $script:T.LogHide }
    } catch { Show-Error $_ 'журнал' }
})
$script:OnLinkNavigate = {
    param($s, $e)
    try {
        $url = $e.Uri.AbsoluteUri
        if (Test-Admin) {   # из повышенного процесса ссылки не открываем: браузер получил бы права администратора
            [System.Windows.Clipboard]::SetText($url)
            Set-Status ($script:T.LinkCopied -f $url)
        } else {
            Start-Process -FilePath $url
        }
    } catch { Show-Error $_ }
    $e.Handled = $true
}
$script:ui.LnkGitHub.Add_RequestNavigate($script:OnLinkNavigate)
$script:ui.LnkAuthor.Add_RequestNavigate($script:OnLinkNavigate)
$script:Window.Add_Closing({
    param($s, $e)
    try {
        if ($script:Job -or $script:BgPending) { $e.Cancel = $true; Set-Status $script:T.Busy; return }
        if ($script:SilentCtl) { try { $script:SilentCtl['Cancel'] = $true } catch { } }      # закрываем окно - тихое обновление ничего нового не пишет
        $script:Closing = $true
        Stop-AutoPreviews
    } catch { Show-Error $_ 'закрытие' }
})
# последняя линия обороны: необработанное исключение в обработчике WPF - в журнал со стеком, окно остаётся открытым
$script:Window.Dispatcher.add_UnhandledException({
    param($s, $e)
    try { Write-Log ('НЕОБРАБОТАННАЯ ОШИБКА GUI: ' + $e.Exception.Message + ' | ' + ([string]$e.Exception.StackTrace -replace "`r?`n", ' <- ')); $e.Handled = $true } catch { }
})
$script:Window.Add_SourceInitialized({
    try {   # тёмный заголовок окна (Windows 10 1903+/11)
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
        $v = 1
        [void][GlyphixNative.Gui]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
        [void][GlyphixNative.Gui]::DwmSetWindowAttribute($h, 19, [ref]$v, 4)
        $c = 0x180A07   # COLORREF 0x00BBGGRR для #070A18
        [void][GlyphixNative.Gui]::DwmSetWindowAttribute($h, 35, [ref]$c, 4)
    } catch { }
})
# после (необязательного) переноса данных: нет паков или только что перенесли кэш прежней версии - сразу обновляем список паков
function Start-Initial {
    param([bool]$ForceUpdate = $false)
    $script:Packs = @(Get-Packs)
    if ($script:Packs.Count -eq 0 -or $ForceUpdate) {
        Rebuild-Packs
        Invoke-Update $true
    } else {
        Rebuild-Packs
        $st = Read-State
        $first = $script:Packs[0].Id
        if ($st.ContainsKey('Applied') -and $st['Applied'] -and $script:Cards.ContainsKey([string]$st['Applied'].PackId)) { $first = [string]$st['Applied'].PackId }
        Select-Pack $first
        Start-SilentRefresh            # кэш показан сразу, а index + pack.json + превью всех паков обновляются в фоне при каждом запуске
    }
}

$script:Window.Add_ContentRendered({
    try { Start-UpdateCheck } catch { Show-Error $_ 'проверка версии' }
    try {
        $need = ((-not $script:ElevProblem) -and -not (Get-LegacyMigrationSkipReason))
        if ($need) {
            Start-Bg -Title $script:T.Migrating -Params @{} -Body @'
param($p)
Invoke-LegacyMigration
'@ -OnDone {
                param($res)
                if ($res -and $res.Error) { Show-Error $res 'перенос данных' }
                Start-Initial ([bool]($res -and $res.PSObject.Properties['Migrated'] -and $res.Migrated))
            }
        } else {
            Start-Initial
        }
    } catch { Show-Error $_ 'запуск' }
})

$script:ElevProblem = Get-ElevationProblem
if ($script:ElevProblem) {
    Write-Log ('Отказ: ' + $script:ElevProblem)
    $script:ui.TxtStatus.Text = ($script:T.ElevBlocked -f $script:ElevProblem)
    [void][System.Windows.MessageBox]::Show($script:ElevProblem, 'Glyphix', 'OK', 'Warning')
}

try {
    Write-Log ('=== Glyphix ' + (Get-AppVersion) + ' запущен, admin=' + (Test-Admin) + ' ===')
    [void]$script:Window.ShowDialog()
} catch {
    Write-Log ('Фатальная ошибка: ' + $_.Exception.Message)
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Glyphix', 'OK', 'Error')
    try { $script:InstanceMutex.Dispose() } catch { }
    exit 1
}
try { $script:InstanceMutex.Dispose() } catch { }
