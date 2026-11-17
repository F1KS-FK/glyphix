<#
  Shadow Icons - приложение (WPF, Windows PowerShell 5.1).
  GUI:  powershell -STA -File ShadowIcons.ps1      (обычно запускается через launch.vbs)
  CLI:  ShadowIcons.ps1 -Cli [-Update] [-List <пак>] [-Apply <пак>] [-Undo] [-NoRestart] [-AllUsers] [-NoTiles] [-NoName] [-CommonOnly]
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
    if (-not ('ShadowIconsNative.Gui' -as [type])) {
        Add-Type -Namespace ShadowIconsNative -Name Gui -MemberDefinition @'
[DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
[DllImport("shell32.dll")]
public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
'@
    }
    [void][ShadowIconsNative.Gui]::SetCurrentProcessExplicitAppUserModelID('ShadowIcons.App')
} catch { }

# Все строки интерфейса - здесь (для будущей локализации)
$T = @{
    Title        = 'Shadow Icons'
    Packs        = 'Паки иконок'
    Apply        = 'Применить'
    Applied      = '✓ Применён'
    Update       = 'Обновить паки'
    Undo         = 'Откатить всё'
    Open         = 'Открыть папку'
    Uninstall    = 'Удалить приложение'
    Restart      = 'Перезапустить проводник (иконки обновятся сразу)'
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
    AllUsers     = 'Также общие ярлыки (нужны права администратора)'
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
    FirstRun     = 'Первый запуск: загружаю паки с GitHub...'
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
    ConfirmUn    = 'Удалить Shadow Icons? Исходные иконки будут возвращены, папка приложения и ярлыки Shadow Icons удалены.'
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
    [void][System.Windows.MessageBox]::Show('Не удалось открыть окно: ' + $_.Exception.Message, 'Shadow Icons', 'OK', 'Error')
    exit 1
}
$script:ui = @{}
$names = @('ImgLogo', 'TxtVersion', 'TxtAdmin', 'TxtPacksTitle', 'PackList', 'TxtEmpty', 'TxtMatchTitle', 'TxtSelectedPack', 'MatchList',
    'TxtMatchSummary', 'BtnUpdate', 'BtnUndo', 'BtnOpen', 'BtnMenu', 'ChkRestart', 'ChkAllUsers', 'ChkTiles', 'ChkNoName', 'LnkGitHub', 'PopMenu', 'BtnUninstall',
    'PrgBusy', 'TxtStatus', 'BtnLog', 'LogPanel', 'TxtLog')
foreach ($n in $names) {
    $script:ui[$n] = $script:Window.FindName($n)
    if ($null -eq $script:ui[$n]) { Write-Log "В XAML нет элемента $n"; [void][System.Windows.MessageBox]::Show("В MainWindow.xaml нет элемента $n", 'Shadow Icons', 'OK', 'Error'); exit 1 }
}

# ---- состояние GUI ----
$script:Packs = @()
$script:Cards = @{}
$script:CardButtons = @()
$script:SelectedId = $null
$script:PendingSelect = $null
$script:Job = $null
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
    foreach ($b in @($script:ui.BtnUpdate, $script:ui.BtnUndo, $script:ui.BtnMenu)) { $b.IsEnabled = (-not $Busy) }
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
    if ($script:Job) { return }
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
        $card = New-Object System.Windows.Controls.Border
        $card.Style = (Get-Res 'CardStyle')
        $card.Width = 282
        $card.Margin = New-Object System.Windows.Thickness(6)
        $card.Tag = $pk.Id
        $card.Cursor = [System.Windows.Input.Cursors]::Hand
        $sp = New-Object System.Windows.Controls.StackPanel

        $pv = New-Object System.Windows.Controls.Border
        $pv.Height = 92
        $pv.CornerRadius = New-Object System.Windows.CornerRadius(10)
        $img = New-Img $pk.Preview 600
        if ($img) {
            $ib = New-Object System.Windows.Media.ImageBrush($img)
            $ib.Stretch = [System.Windows.Media.Stretch]::UniformToFill
            $pv.Background = $ib
        } else { $pv.Background = (Get-Res 'RowBrush') }
        [void]$sp.Children.Add($pv)

        $nm = New-Text $pk.Name 16 'TextBrush' 'SemiBold'
        $nm.Margin = New-Object System.Windows.Thickness(2, 10, 0, 0)
        [void]$sp.Children.Add($nm)
        $meta = New-Text ("{0} · v{1} · {2}" -f $pk.Author, $pk.Version, ($script:T.IconsN -f $pk.IconCount)) 12 'MutedBrush'
        $meta.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
        [void]$sp.Children.Add($meta)
        if ($pk.Description) {
            $ds = New-Text $pk.Description 12 'MutedBrush'
            $ds.TextWrapping = 'Wrap'
            $ds.TextTrimming = 'CharacterEllipsis'
            $ds.MaxHeight = 34
            $ds.Margin = New-Object System.Windows.Thickness(2, 6, 0, 0)
            [void]$sp.Children.Add($ds)
        }
        $row = New-Object System.Windows.Controls.Grid
        $c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = [System.Windows.GridLength]::Auto
        [void]$row.ColumnDefinitions.Add($c1); [void]$row.ColumnDefinitions.Add($c2)
        $row.Margin = New-Object System.Windows.Thickness(0, 12, 0, 2)
        $btn = New-Object System.Windows.Controls.Button
        $btn.Style = (Get-Res 'AccentButton')
        $btn.Content = $script:T.Apply
        $btn.Tag = $pk.Id
        $btn.Add_Click({ param($s, $e) try { Invoke-Apply ([string]$s.Tag) } catch { Show-Error $_ } })
        [void]$row.Children.Add($btn)
        if ($applied -and $applied -eq $pk.Id) {
            $bd = New-Text $script:T.Applied 12 'MutedBrush' 'SemiBold'
            $bd.VerticalAlignment = 'Center'
            $bd.Margin = New-Object System.Windows.Thickness(12, 0, 0, 0)
            [System.Windows.Controls.Grid]::SetColumn($bd, 1)
            [void]$row.Children.Add($bd)
        }
        [void]$sp.Children.Add($row)
        $card.Child = $sp
        $card.Add_MouseLeftButtonUp({ param($s, $e) try { Select-Pack ([string]$s.Tag) } catch { Show-Error $_ } })
        [void]$script:ui.PackList.Children.Add($card)
        $script:Cards[$pk.Id] = $card
        $script:CardButtons += $btn
    }
    Update-CardHighlight
}

# ---- панель «Что поменяется» ----
function New-MatchRow {
    param([string]$ImgPath, [string]$Title, [string]$Sub, [string]$Pill, [string]$Tip)
    $row = New-Object System.Windows.Controls.Border
    $row.Background = (Get-Res 'RowBrush')
    $row.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $row.Padding = New-Object System.Windows.Thickness(10)
    $row.Margin = New-Object System.Windows.Thickness(0, 0, 0, 6)
    $row.ToolTip = $Tip
    $g = New-Object System.Windows.Controls.Grid
    $d1 = New-Object System.Windows.Controls.ColumnDefinition; $d1.Width = [System.Windows.GridLength]::Auto
    $d2 = New-Object System.Windows.Controls.ColumnDefinition; $d2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $d3 = New-Object System.Windows.Controls.ColumnDefinition; $d3.Width = [System.Windows.GridLength]::Auto
    [void]$g.ColumnDefinitions.Add($d1); [void]$g.ColumnDefinitions.Add($d2); [void]$g.ColumnDefinitions.Add($d3)
    $im = New-Object System.Windows.Controls.Image
    $im.Width = 34; $im.Height = 34
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
    $pill.Child = New-Text $Pill 11 'MutedBrush'
    [System.Windows.Controls.Grid]::SetColumn($pill, 2)
    [void]$g.Children.Add($pill)
    $row.Child = $g
    return $row
}

function Fill-Matches {
    param($Matches2, $TileMatches)
    $script:ui.MatchList.Children.Clear()
    $items = @($Matches2 | Where-Object { $_ })
    $tiles = @($TileMatches | Where-Object { $_ })
    $same = 0
    foreach ($m in $items) {
        if ($m.Already) { $same++ }
        $sub = "{0}: {1}" -f $script:T.IconWord, $m.IconName
        if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
        $locKey = 'Loc_' + [string]$m.Location
        $pillText = if ($script:T.ContainsKey($locKey)) { $script:T[$locKey] } else { [string]$m.Location }
        [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.PngPath ([string]$m.Name) $sub $pillText ([string]$m.Path)))
    }
    $tsame = 0
    foreach ($m in $tiles) {
        if ($m.Already) { $tsame++ }
        $title = if ($m.Name) { [string]$m.Name } else { [string]$m.TileId }
        $sub = $script:T.TileSub -f $m.IconName, $m.TileId
        if ($m.Already) { $sub += ' · ' + $script:T.AlreadySet }
        [void]$script:ui.MatchList.Children.Add((New-MatchRow $m.TilePath $title $sub $script:T.TilesPill ([string]$m.TileId)))
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

$script:ui.BtnUpdate.Add_Click({ try { Invoke-Update } catch { Show-Error $_ } })
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
    if ($script:Job) { $e.Cancel = $true; Set-Status $script:T.Busy }
})
$script:Window.Add_SourceInitialized({
    try {   # тёмный заголовок окна (Windows 10 1903+/11)
        $h = (New-Object System.Windows.Interop.WindowInteropHelper($script:Window)).Handle
        $v = 1
        [void][ShadowIconsNative.Gui]::DwmSetWindowAttribute($h, 20, [ref]$v, 4)
        [void][ShadowIconsNative.Gui]::DwmSetWindowAttribute($h, 19, [ref]$v, 4)
        $c = 0x180A07   # COLORREF 0x00BBGGRR для #070A18
        [void][ShadowIconsNative.Gui]::DwmSetWindowAttribute($h, 35, [ref]$c, 4)
    } catch { }
})
$script:Window.Add_ContentRendered({
    try {
        $script:Packs = @(Get-Packs)
        if ($script:Packs.Count -eq 0) {
            Rebuild-Packs
            Invoke-Update $true
        } else {
            Rebuild-Packs
            $st = Read-State
            $first = $script:Packs[0].Id
            if ($st.ContainsKey('Applied') -and $st['Applied'] -and $script:Cards.ContainsKey([string]$st['Applied'].PackId)) { $first = [string]$st['Applied'].PackId }
            Select-Pack $first
        }
    } catch { Show-Error $_ }
})

$script:ElevProblem = Get-ElevationProblem
if ($script:ElevProblem) {
    Write-Log ('Отказ: ' + $script:ElevProblem)
    $script:ui.TxtStatus.Text = ($script:T.ElevBlocked -f $script:ElevProblem)
    [void][System.Windows.MessageBox]::Show($script:ElevProblem, 'Shadow Icons', 'OK', 'Warning')
}

try {
    Write-Log ('=== Shadow Icons ' + (Get-AppVersion) + ' запущен, admin=' + (Test-Admin) + ' ===')
    [void]$script:Window.ShowDialog()
} catch {
    Write-Log ('Фатальная ошибка: ' + $_.Exception.Message)
    [void][System.Windows.MessageBox]::Show($_.Exception.Message, 'Shadow Icons', 'OK', 'Error')
    exit 1
}
