<#
  Glyphix - приложение (WPF, Windows PowerShell 5.1).
  Паки: список (index.json), pack.json и превью обновляются кнопкой «Обновить паки»; иконки и плитки пака качаются по требованию
  (при «Применить» или «Скачать»). Данные прежней версии (Shadow Icons) переносятся при первом запуске.
  GUI:  powershell -STA -File Glyphix.ps1      (обычно запускается через launch.vbs)
  CLI:  Glyphix.ps1 -Cli [-Update] [-List <пак>] [-Apply <пак>] [-Undo] [-NoRestart] [-AllUsers] [-NoTiles] [-NoName] [-CommonOnly]
  Версии:  Glyphix.ps1 -CheckUpdate   (покажет локальную версию и версию на GitHub; приложение само предлагает обновиться кнопкой в шапке)
  Плитки Start11 применяются вместе с ярлыками (если Start11 найден); -NoTiles - без плиток, -NoName - плитки без подписи.
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
    [switch]$CommonOnly
)

$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot
. (Join-Path $script:Root 'Engine.ps1')

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
    $packs = @(Get-Packs)
    if ($Update -or $packs.Count -eq 0) {
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
        $items = @(Get-Matches -Pack $pk -AllUsers:$all)
        if ($mode -eq 'List') {
            Write-Host ("Пак: {0} {1}, иконок: {2}; найдено ярлыков: {3}" -f $pk.Name, $pk.Version, $pk.IconCount, $items.Count)
            foreach ($m in $items) {
                $mark = if ($m.Already) { ' (уже стоит)' } else { '' }
                Write-Host ("  [{0,-7}] {1,-32} -> {2} ({3}){4}" -f $m.Location, $m.Name, $m.IconName, $m.Rule, $mark)
            }
            if ($tilesOn) {
                $tiles = @(Get-Start11Matches -Pack $pk -NoName:$NoName)
                Write-Host ("Плитки Start11: {0}" -f $tiles.Count)
                foreach ($m in $tiles) {
                    $mark = if ($m.Already) { ' (уже стоит)' } else { '' }
                    Write-Host ("  [start11] {0,-32} -> {1} ({2}){3}" -f $(if ($m.Name) { $m.Name } else { $m.TileId }), $m.IconName, $m.Rule, $mark)
                }
            }
        } else {
            if (Test-LegacyMigrationIncomplete) { Write-Log $script:SI_MigrationPendingMsg; return 4 }     # бэкап прежней версии ещё не перенесён
            $r = Apply-Pack -Pack $pk -Items $items -RestartExplorer:(-not $NoRestart)
            if ($r.Failed -gt 0) { $code = 1 }
            if ($tilesOn) {
                $tr = Apply-Start11Tiles -Pack $pk -NoName:$NoName -NoReload:$NoRestart
                if ($tr.Failed -gt 0) { $code = 1 }
                if ($tr.Hint) { Write-Host $tr.Hint }
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
    StateReady   = 'Скачан'
    StateNone    = 'Не скачан'
    StateStale   = 'Есть обновление'
    NotReadyNote = 'Пак ещё не скачан: иконки и плитки загрузятся при нажатии «Применить» (или «Скачать» на карточке).'
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
    ApplyDone    = 'Готово: заменено {0}, уже стояли {1}'
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
    'TxtMatchSummary', 'BtnUpdate', 'BtnUndo', 'BtnOpen', 'BtnMenu', 'ChkRestart', 'ChkAllUsers', 'ChkTiles', 'ChkNoName', 'LnkGitHub', 'PopMenu', 'BtnUninstall',
    'PrgBusy', 'TxtStatus', 'BtnLog', 'LogPanel', 'TxtLog', 'BtnAppUpdate')
foreach ($n in $names) {
    $script:ui[$n] = $script:Window.FindName($n)
    if ($null -eq $script:ui[$n]) { Write-Log "В XAML нет элемента $n"; [void][System.Windows.MessageBox]::Show("В MainWindow.xaml нет элемента $n", 'Glyphix', 'OK', 'Error'); exit 1 }
}

# ---- состояние GUI ----
$script:Packs = @()
$script:Cards = @{}
$script:CardButtons = @()
$script:SelectedId = $null
$script:PendingSelect = $null
$script:Job = $null
$script:Closing = $false
$script:UpdJob = $null
$script:UpdateInfo = $null
$script:DataHome = $script:SI_Home
$script:HasStart11 = $false
try { $script:HasStart11 = [bool](Test-Start11) } catch { }

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

function Add-LogLine {
    param([string]$Line)
    try {
        if ($script:ui.TxtLog.Text.Length -gt 200000) { $script:ui.TxtLog.Clear() }
        $script:ui.TxtLog.AppendText($Line + "`r`n")
        $script:ui.TxtLog.ScrollToEnd()
    } catch { }
}

function Set-Status { param([string]$Text) $script:ui.TxtStatus.Text = $Text; $script:ui.TxtStatus.ToolTip = $Text }

function Show-Error {
    param($Err)
    $m = if ($Err -is [System.Management.Automation.ErrorRecord]) { $Err.Exception.Message } else { [string]$Err }
    Write-Log ('ОШИБКА GUI: ' + $m)
    Set-Status ($script:T.Error -f $m)
}

function Set-Busy {
    param([bool]$Busy)
    $script:ui.PrgBusy.IsIndeterminate = $Busy
    $script:ui.PrgBusy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    foreach ($b in @($script:ui.BtnUpdate, $script:ui.BtnUndo, $script:ui.BtnMenu, $script:ui.BtnAppUpdate)) { $b.IsEnabled = (-not $Busy) }
    foreach ($b in $script:CardButtons) { $b.IsEnabled = (-not $Busy) }
}

# ---- фоновые операции (отдельный runspace, UI не замирает) ----
$script:Prologue = @'
param($enginePath, $queue, $params, $body)
$ErrorActionPreference = 'Stop'
. $enginePath
$q = $queue
Set-EngineLogHandler ({ param($m) $q.Enqueue([string]$m) }.GetNewClosure())
try { & ([scriptblock]::Create($body)) $params }
catch { Write-Log ('ОШИБКА: ' + $_.Exception.Message); [pscustomobject]@{ Error = $_.Exception.Message } }
'@

function Start-Bg {
    param([string]$Title, [string]$Body, [hashtable]$Params, [scriptblock]$OnDone)
    if ($script:Job -or $script:Closing) { return }
    Set-Status $Title
    Set-Busy $true
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = [Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($script:Prologue).AddArgument((Join-Path $script:Root 'Engine.ps1')).AddArgument($q).AddArgument($Params).AddArgument($Body)
    $async = $ps.BeginInvoke()
    $script:Job = @{ PS = $ps; RS = $rs; Async = $async; Queue = $q; OnDone = $OnDone }
    $script:Timer.Start()
}

function Step-Job {
    $job = $script:Job
    if (-not $job) { $script:Timer.Stop(); return }
    $line = $null
    while ($job.Queue.TryDequeue([ref]$line)) { Add-LogLine $line; Set-Status $line }
    if (-not $job.Async.IsCompleted) { return }
    $script:Timer.Stop()
    $res = $null
    try {
        $out = $job.PS.EndInvoke($job.Async)
        if ($out -and $out.Count -gt 0) { $res = $out[$out.Count - 1] }
    } catch {
        $res = [pscustomobject]@{ Error = $_.Exception.Message }
    }
    try { $job.PS.Dispose(); $job.RS.Close(); $job.RS.Dispose() } catch { }
    $script:Job = $null
    Set-Busy $false
    try { & $job.OnDone $res } catch { Show-Error $_ }
    if ($script:PendingSelect) { $p = $script:PendingSelect; $script:PendingSelect = $null; Select-Pack $p }
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
    try {
        $out = $u.PS.EndInvoke($u.Async)
        if ($out -and $out.Count -gt 0) { $info = $out[$out.Count - 1] }
    } catch { }
    try { $u.PS.Dispose(); $u.RS.Close(); $u.RS.Dispose() } catch { }
    $script:UpdJob = $null
    if ($info -and $info.PSObject.Properties['Available']) { $script:UpdateInfo = $info; Show-AppUpdateButton }
}

function Start-UpdateCheck {
    if ($script:UpdJob -or $script:Closing) { return }
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        [void]$ps.AddScript($script:Prologue).AddArgument((Join-Path $script:Root 'Engine.ps1')).AddArgument($q).AddArgument(@{}).AddArgument('param($p) Get-AppUpdateInfo')
        $async = $ps.BeginInvoke()
        $script:UpdJob = @{ PS = $ps; RS = $rs; Async = $async }
        $script:UpdTimer.Start()
    } catch { $script:UpdJob = $null }
}

function Invoke-AppUpdate {
    if ($script:Job) { Set-Status $script:T.Busy; return }
    $i = $script:UpdateInfo
    if (-not $i -or -not $i.Available) { return }
    $ans = [System.Windows.MessageBox]::Show($script:Window, ($script:T.ConfirmAppUpdate -f $i.Local, $i.Remote), $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Bg -Title $script:T.AppUpdating -Params @{} -Body @'
param($p)
[pscustomobject]@{ Started = $true; Installer = (Start-AppSelfUpdate) }
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Обновление не вернуло результат'; return }
        if ($res.Error) { Show-Error $res.Error; return }
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

function Rebuild-Packs {
    $script:ui.PackList.Children.Clear()
    $script:Cards = @{}
    $script:CardButtons = @()
    $script:Packs = @(Get-Packs)
    $script:ui.TxtEmpty.Text = $script:T.NoPacks
    $script:ui.TxtEmpty.Visibility = if ($script:Packs.Count -eq 0) { 'Visible' } else { 'Collapsed' }
    $applied = $null
    $st = Read-State
    if ($st.ContainsKey('Applied') -and $st['Applied']) { $applied = [string]$st['Applied'].PackId }
    foreach ($pk in $script:Packs) {
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
        $btn.Add_Click({ param($s, $e) try { Invoke-Apply ([string]$s.Tag) } catch { Show-Error $_ } })
        [void]$row.Children.Add($btn)
        $script:CardButtons += $btn
        if ($pk.State -ne 'ready') {          # «Скачать» - иконки и плитки этого пака (по требованию)
            $dl = New-Object System.Windows.Controls.Button
            $dl.Style = (Get-Res 'GhostButton')
            $dl.Content = $script:T.Download
            $dl.Tag = $pk.Id
            $dl.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
            $dl.Add_Click({ param($s, $e) try { Invoke-Download ([string]$s.Tag) } catch { Show-Error $_ } })
            [System.Windows.Controls.Grid]::SetColumn($dl, 1)
            [void]$row.Children.Add($dl)
            $script:CardButtons += $dl
        }
        [System.Windows.Controls.Grid]::SetRow($row, 4)
        [void]$sp.Children.Add($row)
        $card.Child = $sp
        $card.Add_MouseLeftButtonUp({ param($s, $e) try { Select-Pack ([string]$s.Tag) } catch { Show-Error $_ } })
        [void]$script:ui.PackList.Children.Add($card)
        $script:Cards[$pk.Id] = $card
    }
    Update-CardHighlight
}

# ---- панель «Что поменяется» ----
function New-MatchRow {
    param([string]$ImgPath, [string]$Title, [string]$Sub, [string]$Pill, [string]$Tip)
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
    $pill.Child = New-Text $Pill 11 'MutedBrush'
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

# ярлыки и плитки, сгруппированные по группе иконки (apps, games, system, work, creative, прочее); внутри группы - по названию
function Fill-Matches {
    param($Matches2, $TileMatches)
    $script:ui.MatchList.Children.Clear()
    $items = @($Matches2 | Where-Object { $_ })
    $tiles = @($TileMatches | Where-Object { $_ })
    $same = 0; $tsame = 0
    foreach ($g in @(Get-MatchGroups $items $tiles)) {
        [void]$script:ui.MatchList.Children.Add((New-GroupHeader ($script:T.GroupHeader -f (Get-GroupTitle ([string]$g.Group)), $g.Count)))
        foreach ($r in $g.Rows) {
            $m = $r.Item
            if ($r.Kind -eq 'link') {
                if ($m.Already) { $same++ }
                $sub = "{0}: {1}" -f $script:T.IconWord, $m.IconName
                if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
                $locKey = 'Loc_' + [string]$m.Location
                $pillText = if ($script:T.ContainsKey($locKey)) { $script:T[$locKey] } else { [string]$m.Location }
                [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.PngPath ([string]$m.Name) $sub $pillText ([string]$m.Path)))
            } else {
                if ($m.Already) { $tsame++ }
                $title = if ($m.Name) { [string]$m.Name } else { [string]$m.TileId }
                $sub = $script:T.TileSub -f $m.IconName, $m.TileId
                if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
                [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.TilePath $title $sub $script:T.TilesPill ([string]$m.TileId)))
            }
        }
    }
    if ($items.Count -eq 0 -and $tiles.Count -eq 0) {
        $s = $script:T.NoneFound
    } else {
        $s = if ($items.Count -gt 0) { $script:T.Found -f $items.Count } else { '' }
        if ($same -gt 0) { $s += ($script:T.FoundSame -f $same) }
        if ($tiles.Count -gt 0) {
            if ($s) { $s += "`n" }
            $s += ($script:T.TilesFound -f $tiles.Count)
            if ($tsame -gt 0) { $s += ($script:T.FoundSame -f $tsame) }
        }
    }
    if (-not [bool]$script:ui.ChkAllUsers.IsChecked) { $s += "`n" + $script:T.AdminNote }
    $sel = $script:Packs | Where-Object { $_.Id -eq $script:SelectedId } | Select-Object -First 1
    if ($sel -and $sel.State -ne 'ready') { $s += "`n" + $script:T.NotReadyNote }
    $script:ui.TxtMatchSummary.Text = $s
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
    if ($script:Job) { $script:PendingSelect = $Id; return }
    $pk = $script:Packs | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if (-not $pk) { return }
    $script:ui.TxtSelectedPack.Text = $script:T.PackLine -f ('{0} {1}' -f $pk.Name, $pk.Version)
    $script:ui.MatchList.Children.Clear()
    $script:ui.TxtMatchSummary.Text = $script:T.Scanning
    Start-Bg -Title $script:T.Scanning -Params @{ Id = $Id; All = [bool]$script:ui.ChkAllUsers.IsChecked; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
$pk = @(Get-Packs) | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
if (-not $pk) { throw 'Пак не найден' }
$tm = @()
if ($p.Tiles) { try { $tm = @(Get-Start11Matches -Pack $pk -NoName:([bool]$p.NoName)) } catch { Write-Log ('Плитки Start11: ' + $_.Exception.Message) } }
[pscustomobject]@{ Matches = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All)); TileMatches = $tm }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res.Error; $script:ui.TxtMatchSummary.Text = ''; return }
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
    $all = [bool]$script:ui.ChkAllUsers.IsChecked
    $restart = [bool]$script:ui.ChkRestart.IsChecked
    # общие ярлыки при обычных правах: один раз перезапускаем этот скрипт с UAC (режим CLI) и ждём его завершения
    $elevate = ($all -and -not (Test-Admin))
    Start-Bg -Title $script:T.Applying -Params @{ Id = $Id; Restart = $restart; All = $all; Elevate = $elevate; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
$pk = @(Get-Packs) | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
if (-not $pk) { throw 'Пак не найден' }
Confirm-PackFiles $pk          # иконки и плитки именно этого пака качаем сейчас, до повышения прав и применения
# плитки Start11 - в реестре текущего пользователя: применяем здесь, а не в повышенном процессе (там -NoTiles)
$tr = $null
$doTiles = { param($packObj)
    if (-not $p.Tiles) { return $null }
    try { return (Apply-Start11Tiles -Pack $packObj -NoName:([bool]$p.NoName)) } catch { Write-Log ('Плитки Start11: ' + $_.Exception.Message); return [pscustomobject]@{ Changed = 0; Same = 0; Failed = 1; Hint = '' } }
}
$getTiles = { param($packObj)
    if (-not $p.Tiles) { return @() }
    try { return @(Get-Start11Matches -Pack $packObj -NoName:([bool]$p.NoName)) } catch { return @() }
}
if ($p.Elevate) {
    $a = @('-Cli', '-Apply', [string]$p.Id, '-AllUsers', '-NoTiles')
    if (-not $p.Restart) { $a += '-NoRestart' }
    $er = Invoke-ElevatedCli -CliArgs $a
    $tr = & $doTiles $pk
    return [pscustomobject]@{ Elevated = $true; Elev = $er; Tiles = $tr; Matches = @(Get-Matches -Pack $pk -AllUsers:$true); TileMatches = @(& $getTiles $pk); PackName = $pk.Name }
}
$items = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All))
$r = Apply-Pack -Pack $pk -Items $items -RestartExplorer:([bool]$p.Restart)
$tr = & $doTiles $pk
[pscustomobject]@{ Elevated = $false; Result = $r; Tiles = $tr; Matches = @(Get-Matches -Pack $pk -AllUsers:([bool]$p.All)); TileMatches = @(& $getTiles $pk); PackName = $pk.Name }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res.Error; return }
        if ($res.Elevated) {
            $code = [int]$res.Elev.ExitCode
            if ($res.Elev.Cancelled) { Set-Status $script:T.ElevCancel }
            elseif ($code -eq 0) { Set-Status $script:T.ElevDone }
            elseif ($code -eq 3) { Set-Status $script:T.ElevRefused }
            else { Set-Status ($script:T.ElevFail -f $code) }
        } else {
            $r = $res.Result
            $s = $script:T.ApplyDone -f $r.Changed, $r.Same
            if ($r.Failed -gt 0) { $s += ($script:T.ApplyFail -f $r.Failed) }
            Set-Status $s
        }
        if ($res.Tiles) {
            $ts = $script:T.TilesDone -f $res.Tiles.Changed, $res.Tiles.Same
            if ($res.Tiles.Failed -gt 0) { $ts += ($script:T.TilesFail -f $res.Tiles.Failed) }
            if ($res.Tiles.Hint) { $ts += '. ' + $res.Tiles.Hint }
            Set-Status ($script:ui.TxtStatus.Text + ' | ' + $ts)
        }
        Rebuild-Packs
        $pk = $script:Packs | Where-Object { $_.Id -eq $script:SelectedId } | Select-Object -First 1
        if ($pk) { $script:ui.TxtSelectedPack.Text = $script:T.PackLine -f ('{0} {1}' -f $pk.Name, $pk.Version) }
        Fill-Matches $res.Matches $res.TileMatches
    }
}

function Invoke-Update {
    param([bool]$FirstRun = $false)
    $title = if ($FirstRun) { $script:T.FirstRun } else { $script:T.Updating }
    Start-Bg -Title $title -Params @{} -Body @'
param($p)
Update-Packs
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res.Error }
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
    Start-Bg -Title $script:T.Downloading -Params @{ Id = $Id } -Body @'
param($p)
Install-Pack -Id ([string]$p.Id)
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res.Error }
        elseif ($res) { Set-Status ($script:T.DownloadDone -f $res.Downloaded) }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

function Invoke-Undo {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUndo, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Bg -Title $script:T.Undoing -Params @{ Restart = [bool]$script:ui.ChkRestart.IsChecked } -Body @'
param($p)
Undo-Routed -RestartExplorer:([bool]$p.Restart)
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Откат не вернул результат'; return }
        if ($res.Error) { Show-Error $res.Error; return }
        if ($res.Nothing) { Set-Status $script:T.UndoNothing }
        else {
            $s = $script:T.UndoDone -f $res.Restored
            if ($res.TilesRestored -gt 0) { $s += ($script:T.TilesUndone -f $res.TilesRestored) }
            if ($res.Failed -gt 0) { $s += ($script:T.UndoFail -f $res.Failed) }
            if ($res.Hint) { $s += '. ' + $res.Hint }
            Set-Status $s
        }
        Rebuild-Packs
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    }
}

function Invoke-Uninstall {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUn, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Start-Bg -Title $script:T.Uninstalling -Params @{ Restart = [bool]$script:ui.ChkRestart.IsChecked } -Body @'
param($p)
Uninstall-App -RestartExplorer:([bool]$p.Restart)
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Удаление не вернуло результат'; return }
        if ($res.Error) { Show-Error $res.Error; return }
        if ($res.Aborted) { Set-Status $res.Message; return }       # откат не удался - приложение остаётся
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
$script:ui.ChkRestart.Content = $script:T.Restart
$script:ui.ChkAllUsers.Content = $script:T.AllUsers
$script:ui.ChkAllUsers.ToolTip = $script:T.AllUsersTip
$script:ui.ChkRestart.ToolTip = $script:T.RestartTip
$script:ui.ChkTiles.Content = $script:T.Tiles
$script:ui.ChkNoName.Content = $script:T.TilesNoName
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
try {
    $icoPath = Join-Path (Join-Path $script:Root 'assets') 'app.ico'
    if (Test-Path -LiteralPath $icoPath) {
        $script:Window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create((New-Object System.Uri($icoPath)), [System.Windows.Media.Imaging.BitmapCreateOptions]::None, [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    }
} catch { }

Set-EngineLogHandler { param($m) Add-LogLine $m }

$script:Timer = New-Object System.Windows.Threading.DispatcherTimer
$script:Timer.Interval = [TimeSpan]::FromMilliseconds(120)
$script:Timer.Add_Tick({ try { Step-Job } catch { Show-Error $_ } })

$script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:UpdTimer.Add_Tick({ try { Step-UpdateCheck } catch { } })

$script:ui.BtnUpdate.Add_Click({ try { Invoke-Update; Start-UpdateCheck } catch { Show-Error $_ } })
$script:ui.BtnAppUpdate.Add_Click({ try { Invoke-AppUpdate } catch { Show-Error $_ } })
$script:ui.BtnUndo.Add_Click({ try { Invoke-Undo } catch { Show-Error $_ } })
$script:ui.BtnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:DataHome)) { New-Item -ItemType Directory -Path $script:DataHome -Force | Out-Null }
        Start-Process -FilePath $script:DataHome
    } catch { Show-Error $_ }
})
$script:ui.ChkAllUsers.Add_Click({ try { if ($script:SelectedId) { Select-Pack $script:SelectedId } } catch { Show-Error $_ } })
$script:ui.ChkTiles.Add_Click({
    try {
        $script:ui.ChkNoName.IsEnabled = ($script:HasStart11 -and [bool]$script:ui.ChkTiles.IsChecked)
        if ($script:SelectedId) { Select-Pack $script:SelectedId }
    } catch { Show-Error $_ }
})
$script:ui.ChkNoName.Add_Click({ try { if ($script:SelectedId) { Select-Pack $script:SelectedId } } catch { Show-Error $_ } })
$script:ui.BtnMenu.Add_Click({ $script:ui.PopMenu.IsOpen = (-not $script:ui.PopMenu.IsOpen) })
$script:ui.BtnUninstall.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Invoke-Uninstall } catch { Show-Error $_ } })
$script:ui.BtnLog.Add_Click({
    if ($script:ui.LogPanel.Visibility -eq 'Visible') { $script:ui.LogPanel.Visibility = 'Collapsed'; $script:ui.BtnLog.Content = $script:T.LogShow }
    else { $script:ui.LogPanel.Visibility = 'Visible'; $script:ui.BtnLog.Content = $script:T.LogHide }
})
$script:ui.LnkGitHub.Add_RequestNavigate({
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
})
$script:Window.Add_Closing({
    param($s, $e)
    if ($script:Job) { $e.Cancel = $true; Set-Status $script:T.Busy; return }
    $script:Closing = $true
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
    }
}

$script:Window.Add_ContentRendered({
    try { Start-UpdateCheck } catch { }
    try {
        $need = ((-not $script:ElevProblem) -and -not (Get-LegacyMigrationSkipReason))
        if ($need) {
            Start-Bg -Title $script:T.Migrating -Params @{} -Body @'
param($p)
Invoke-LegacyMigration
'@ -OnDone {
                param($res)
                if ($res -and $res.Error) { Show-Error $res.Error }
                Start-Initial ([bool]($res -and $res.PSObject.Properties['Migrated'] -and $res.Migrated))
            }
        } else {
            Start-Initial
        }
    } catch { Show-Error $_ }
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
    exit 1
}
