<#
  Glyphix - приложение (WPF, Windows PowerShell 5.1).
  Паки: список (index.json), pack.json и превью обновляются кнопкой «Обновить паки»; иконки и плитки пака качаются по требованию
  (при «Применить» или «Скачать»). Данные прежней версии (Shadow Icons) переносятся при первом запуске.
  GUI:  powershell -STA -File Glyphix.ps1      (обычно запускается через launch.vbs)
  CLI:  Glyphix.ps1 -Cli [-Update] [-Variants] [-List <вариант|пак>] [-Apply <вариант|пак>] [-Undo] [-UndoApp <ключи>] [-NoRestart] [-AllUsers] [-NoTiles] [-NoName] [-NoAuto] [-CommonOnly]
  3.0:  -Apply / -List принимают id варианта (shadow-red, brand-neon...) и id пака (пак = вариант без операций); -Variants (или -List variants) - каталог вариантов;
        -UndoApp discord,telegram - вернуть родные иконки и плитки только этих приложений (AppKey из плана); режимы приложений - в state.json (AppOverrides).
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
    [switch]$CommonOnly,
    [switch]$Variants,
    [string[]]$UndoApp
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
    if (-not ($Cli -or $List -or $Apply -or $Undo -or $Update -or $CheckUpdate -or $Variants -or $UndoApp)) {
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
    if ($UndoApp) {
        $ua = $null
        try { $ua = Undo-Apps -AppKeys @($UndoApp | ForEach-Object { ([string]$_).Split(',') } | Where-Object { $_ }) -NoReload:$NoRestart -RestartExplorer:(-not $NoRestart) -Icon:$false -Tile:$false } catch { Write-Log ('Откат приложений не выполнен: ' + $_.Exception.Message) }
        if (-not $ua -or $ua.Failed -gt 0) { $code = 1 }
        if ($ua -and $ua.Hint) { Write-Host $ua.Hint }
        if ($ua -and $ua.Nothing) { Write-Host 'По этим приложениям в бэкапе ничего нет.' }
    }
    if ($Variants -or $List -eq 'variants') {
        $cat = Get-VariantCatalog
        $fav = @(Get-Favorites)
        Write-Host ("Варианты ({0}): {1}, секций: {2}" -f $(if ($cat.Source -eq 'fallback') { 'из паков' } else { 'каталог' }), @($cat.Variants).Count, @($cat.Sections).Count)
        foreach ($sec in @($cat.Sections)) {
            Write-Host ('{0}' -f $sec.Title)
            foreach ($v in @($sec.Variants)) {
                $star = if ($fav -contains $v.Id) { '*' } else { ' ' }
                Write-Host ("  {0} {1,-18} {2,-22} основа: {3}{4}" -f $star, $v.Id, $v.Title, $v.Base, $(if ($v.IsBase) { '' } else { ' (+' + @($v.Ops).Count + ' оп.)' }))
            }
        }
        if ($List -eq 'variants') { $List = '' }
    }
    foreach ($mode in @('List', 'Apply')) {
        $id = if ($mode -eq 'List') { $List } else { $Apply }
        if (-not $id) { continue }
        $vr = Get-Variant $id
        if (-not $vr) {
            Write-Host ("Вариант '{0}' не найден. Доступные: {1}" -f $id, ((@((Get-VariantCatalog).Variants) | ForEach-Object { $_.Id }) -join ', '))
            return 2
        }
        $planOpts = @{ AllUsers = $all; Tiles = $tilesOn; NoName = [bool]$NoName; Auto = $autoOn; Render = ($mode -eq 'List'); Sync = $true }
        $plan = @()
        try { $plan = @(Get-AppPlan -VariantId $id -Options $planOpts) }
        catch { Write-Log ('Пак не обновлён: ' + $_.Exception.Message); return 1 }
        if ($mode -eq 'List') {
            Write-Host ("Вариант: {0} ({1}), основа {2}; приложений: {3}" -f $vr.Title, $vr.Id, $vr.Base, $plan.Count)
            foreach ($e in $plan) {
                $where = (@($e.Locations | ForEach-Object { $_.Label + $(if ($_.Count -gt 1) { ' x' + $_.Count } else { '' }) }) -join ', ')
                $mark = if ($e.IsCurrent) { ' (уже стоит)' } else { '' }
                $modes = if ($e.IconMode -ne 'apply' -or $e.TileMode -ne 'apply') { ' [иконка: ' + $e.IconMode + ', плитка: ' + $e.TileMode + ']' } else { '' }
                Write-Host ("  {0,-30} {1}{2}{3}   ({4}; {5}){6}" -f $e.Name, $e.AppKey, $(if ($e.Auto) { ' авто' } else { '' }), $mark, $where, $e.IconState, $modes)
            }
        } else {
            if (Test-LegacyMigrationIncomplete) { Write-Log $script:SI_MigrationPendingMsg; return 4 }     # бэкап прежней версии ещё не перенесён
            try { $r = Apply-Plan -VariantId $id -Plan $plan -Options $planOpts -RestartExplorer:(-not $NoRestart) -NoReload:$NoRestart }
            catch { Write-Log ('Не применено: ' + $_.Exception.Message); return 1 }
            if ($r.Failed -gt 0) { $code = 1 }
            if ($r.Tiles -and $r.Tiles.Hint) { Write-Host $r.Tiles.Hint }
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
    if (-not ($Cli -or $List -or $Apply -or $Undo -or $Update -or $Variants -or $UndoApp)) { exit $rcCheck }
}
if ($Cli -or $List -or $Apply -or $Undo -or $Update -or $Variants -or $UndoApp) {
    $rc = Invoke-Cli
    exit $rc
}

# ======================= GUI =======================
#region GuiModel
# ---------------------------------------------------------------------------------------------------------------------------------
# Модель GUI 3.0: чистые функции (без WPF и без обращений к диску/сети) - из каталога, избранного и состояния паков строят секции и карточки,
# из записей Get-AppPlan - строки плана; фильтры и счётчики. Этот блок целиком проверяется на Linux (test_engine.ps1 вырезает его между
# маркерами region/endregion и подключает). Класс строки плана (C# 5, без WPF) нужен привязке данных: INotifyPropertyChanged.
# ---------------------------------------------------------------------------------------------------------------------------------
$script:GxPlanRowCode = @'
using System;
using System.ComponentModel;
namespace GlyphixGui
{
    public class Bindable : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        protected void Raise(string name)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }
    }

    // Одна строка панели «Что поменяется» = одно приложение. Постоянные поля - обычные свойства, меняющиеся (режимы, стиль, галочка, картинки) уведомляют привязку.
    public class PlanRow : Bindable
    {
        public string AppKey { get; set; }
        public string Name { get; set; }
        public string IconId { get; set; }
        public string SearchKey { get; set; }
        public string Tip { get; set; }
        public string[] Chips { get; set; }
        public bool IsAuto { get; set; }
        public bool IsCurrent { get; set; }
        public bool HasIcon { get; set; }
        public bool HasTile { get; set; }
        public bool CanStyle { get; set; }

        string status, statusText, iconMode, iconModeText, tileMode, tileModeText, styleText, source;
        bool styleCustom, checkedRow;
        object beforeImage, afterImage;

        public string Status { get { return status; } set { if (status != value) { status = value; Raise("Status"); } } }
        public string StatusText { get { return statusText; } set { if (statusText != value) { statusText = value; Raise("StatusText"); } } }
        public string IconMode { get { return iconMode; } set { if (iconMode != value) { iconMode = value; Raise("IconMode"); } } }
        public string IconModeText { get { return iconModeText; } set { if (iconModeText != value) { iconModeText = value; Raise("IconModeText"); } } }
        public string TileMode { get { return tileMode; } set { if (tileMode != value) { tileMode = value; Raise("TileMode"); } } }
        public string TileModeText { get { return tileModeText; } set { if (tileModeText != value) { tileModeText = value; Raise("TileModeText"); } } }
        public string StyleText { get { return styleText; } set { if (styleText != value) { styleText = value; Raise("StyleText"); } } }
        public string Source { get { return source; } set { if (source != value) { source = value; Raise("Source"); } } }
        public bool StyleCustom { get { return styleCustom; } set { if (styleCustom != value) { styleCustom = value; Raise("StyleCustom"); } } }
        public bool Checked { get { return checkedRow; } set { if (checkedRow != value) { checkedRow = value; Raise("Checked"); } } }
        public object BeforeImage { get { return beforeImage; } set { if (!object.ReferenceEquals(beforeImage, value)) { beforeImage = value; Raise("BeforeImage"); } } }
        public object AfterImage { get { return afterImage; } set { if (!object.ReferenceEquals(afterImage, value)) { afterImage = value; Raise("AfterImage"); } } }
    }
}
'@

function Initialize-GuiModel {
    if (-not ('GlyphixGui.PlanRow' -as [type])) { Add-Type -TypeDefinition $script:GxPlanRowCode -Language CSharp }
}

# теги варианта -> короткие слова для описания карточки (в каталоге у вариантов нет описания, только теги)
$script:GxTagWords = @{
    dark = 'тёмный'; bright = 'яркий'; light = 'светлый'; cool = 'холодные тона'; warm = 'тёплые тона'; mono = 'монохром'; neon = 'неон'; pixel = 'пиксель-арт'
    retro = 'ретро'; metal = 'металл'; glass = 'стекло'; transparent = 'прозрачный'; hud = 'интерфейс охотника'; holo = 'голограмма'; colorful = 'разноцветный'; brand = 'цвета брендов'
}

# «Светящиеся цветные глифы · яркий, холодные тона»: подзаголовок секции и слова из тегов (default - метка базового стиля, в текст не идёт)
function Get-VariantBlurb {
    param($Variant, [string]$SectionSubtitle = '')
    $w = [System.Collections.Generic.List[string]]::new()
    foreach ($t in @($Variant.Tags)) {
        $k = ([string]$t).ToLowerInvariant()
        if ($script:GxTagWords.ContainsKey($k)) { $w.Add([string]$script:GxTagWords[$k]) }
    }
    $tags = ($w.ToArray() -join ', ')
    if ($SectionSubtitle -and $tags) { return ($SectionSubtitle + ' · ' + $tags) }
    if ($SectionSubtitle) { return $SectionSubtitle }
    return $tags
}

# применённый вариант (state.json: у 2.x - id пака): id варианта каталога или '' - если такого нет. Пак 2.x = первый базовый вариант с этой основой
function Get-AppliedAlias {
    param($Catalog, [string]$AppliedId)
    if (-not $AppliedId -or -not $Catalog) { return '' }
    if ($Catalog.ById.ContainsKey($AppliedId)) { return $AppliedId }
    foreach ($v in @($Catalog.Variants)) { if ($v.IsBase -and [string]$v.Base -eq $AppliedId) { return [string]$v.Id } }
    return ''
}

# пак-основа -> названия стилей, которые на ней построены («Glow · Violet»): для подсказки «Скачан»
function Get-BaseUsers {
    param($Catalog)
    $h = @{}
    foreach ($v in @($Catalog.Variants)) {
        $b = [string]$v.Base
        if (-not $h.ContainsKey($b)) { $h[$b] = [System.Collections.Generic.List[string]]::new() }
        $h[$b].Add(([string]$v.SectionTitle + ' · ' + [string]$v.Title))
    }
    return $h
}

# «Glow · Violet» (секция · название) для подписи источника и меню
function Format-VariantLabel {
    param($Catalog, [string]$Id)
    if (-not $Id) { return '' }
    if ($Catalog -and $Catalog.ById.ContainsKey($Id)) { $v = $Catalog.ById[$Id]; return ([string]$v.SectionTitle + ' · ' + [string]$v.Title) }
    return $Id
}

function New-CardModel {
    param($Variant, $SectionSubtitle, $PackMap, [string]$AppliedId, $FavSet, $BaseUsers)
    $pk = $PackMap[[string]$Variant.Base]
    $users = @(); if ($BaseUsers -and $BaseUsers.ContainsKey([string]$Variant.Base)) { $users = $BaseUsers[[string]$Variant.Base].ToArray() }
    $author = ''; if ($pk -and $pk.Author) { $author = [string]$pk.Author }
    return [pscustomobject]@{
        Id = [string]$Variant.Id; Title = [string]$Variant.Title; SectionId = [string]$Variant.SectionId; SectionTitle = [string]$Variant.SectionTitle
        BaseId = [string]$Variant.Base; BaseName = $(if ($pk -and $pk.Name) { [string]$pk.Name } else { [string]$Variant.Base })
        Version = $(if ($pk) { [string]$pk.Version } else { '' }); IconCount = $(if ($pk) { [int]$pk.IconCount } else { 0 })
        Author = $(if ($author) { $author } else { 'F1KS' }); Blurb = (Get-VariantBlurb $Variant $SectionSubtitle)
        State = $(if ($pk -and $pk.State) { [string]$pk.State } else { 'none' }); PackDir = $(if ($pk) { [string]$pk.Dir } else { '' })
        IsApplied = [bool]($AppliedId -and $AppliedId -eq [string]$Variant.Id); IsFavorite = [bool]$FavSet.ContainsKey([string]$Variant.Id)
        PreviewPath = $(if ($Variant.PreviewPath) { [string]$Variant.PreviewPath } else { '' }); SharedWith = $users; Tags = @($Variant.Tags); IsBase = [bool]$Variant.IsBase
    }
}

# совпадение карточки с поисковой строкой («Поиск стиля…»): название, секция, id, основа, теги (и русские слова тегов); несколько слов - все должны встретиться
function Test-CardMatch {
    param($Card, [string]$Query)
    $q = ([string]$Query).Trim().ToLowerInvariant()
    if (-not $q) { return $true }
    $words = @()
    foreach ($t in @($Card.Tags)) { $k = ([string]$t).ToLowerInvariant(); $words += $k; if ($script:GxTagWords.ContainsKey($k)) { $words += [string]$script:GxTagWords[$k] } }
    $hay = (@([string]$Card.Title, [string]$Card.SectionTitle, [string]$Card.Id, [string]$Card.BaseId) + $words) -join ' '
    $hay = $hay.ToLowerInvariant()
    foreach ($part in @($q -split '\s+' | Where-Object { $_ })) { if (-not $hay.Contains($part)) { return $false } }
    return $true
}

# Секции для показа: «★ Избранное» (только если есть избранные; порядок как в Get-Favorites; id, которых нет в каталоге, пропускаются) и секции каталога по порядку.
# Секция с пустым результатом поиска не показывается; если поиск совпал с названием секции - показываются все её стили.
function New-SectionModels {
    param($Catalog, $Favorites, $Packs, [string]$AppliedId = '', [string]$Query = '', [string]$FavTitle = '★ Избранное', [string]$FavSubtitle = 'Ваши любимые стили')
    $packMap = @{}; foreach ($p in @($Packs)) { $packMap[[string]$p.Id] = $p }
    $favList = @(@($Favorites) | Where-Object { $_ -and $Catalog.ById.ContainsKey([string]$_) })
    $favSet = @{}; foreach ($f in $favList) { $favSet[[string]$f] = $true }
    $users = Get-BaseUsers $Catalog
    $subOf = @{}; foreach ($s in @($Catalog.Sections)) { $subOf[[string]$s.Id] = [string]$s.Subtitle }
    $mk = { param($v) New-CardModel $v $subOf[[string]$v.SectionId] $packMap $AppliedId $favSet $users }
    $out = [System.Collections.Generic.List[object]]::new()
    $favCards = @($favList | ForEach-Object { & $mk $Catalog.ById[[string]$_] } | Where-Object { Test-CardMatch $_ $Query })
    if ($favCards.Count -gt 0) { $out.Add([pscustomobject]@{ Id = 'fav'; Title = $FavTitle; Subtitle = $FavSubtitle; IsFavorites = $true; Cards = $favCards }) }
    $qq = ([string]$Query).Trim().ToLowerInvariant()
    foreach ($s in @($Catalog.Sections)) {
        $all = @(@($s.Variants) | ForEach-Object { & $mk $_ })
        $secHit = ($qq -and ([string]$s.Title).ToLowerInvariant().Contains($qq))
        $cards = if ($secHit) { $all } else { @($all | Where-Object { Test-CardMatch $_ $Query }) }
        if ($cards.Count -eq 0) { continue }
        $out.Add([pscustomobject]@{ Id = [string]$s.Id; Title = [string]$s.Title; Subtitle = [string]$s.Subtitle; IsFavorites = $false; Cards = $cards })
    }
    return $out.ToArray()
}

# Какие базовые паки качать для отмеченных стилей: уникальные id основ в порядке выбора (стили одной основы - один пак)
function Get-BaseIdsForVariants {
    param($Catalog, $VariantIds)
    $seen = @{}; $out = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($VariantIds)) {
        if (-not $id -or -not $Catalog.ById.ContainsKey([string]$id)) { continue }
        $b = [string]$Catalog.ById[[string]$id].Base
        if (-not $seen.ContainsKey($b)) { $seen[$b] = $true; $out.Add($b) }
    }
    return $out.ToArray()
}

# Подсказка к плашке «Скачан / Не скачан»: состояние относится к паку-основе, общему для нескольких стилей
function Get-CardStateTip {
    param($Card, $Text)
    $others = @($Card.SharedWith | Where-Object { $_ -ne ([string]$Card.SectionTitle + ' · ' + [string]$Card.Title) })
    $t = ($Text.StateTip -f $Card.BaseName)
    if ($others.Count -gt 0) { $t += "`n" + ($Text.StateTipShared -f ($others -join ', ')) }
    return $t
}

# ---- строки плана ----
function Get-ModeText {
    param([string]$Mode, $Text)
    switch ($Mode) { 'skip' { return [string]$Text.ModeSkip } 'restore' { return [string]$Text.ModeRestore } default { return [string]$Text.ModeApply } }
}

# статус строки: missing (нет в паке - автоиконка) | current (уже стоит) | replace (заменится) | idle (всё «не трогать» / «вернуть родную»)
function Get-PlanStatus {
    param([bool]$IsAuto, [string]$IconId, [bool]$IsCurrent, [bool]$HasIcon, [bool]$HasTile, [string]$IconMode, [string]$TileMode)
    if ($IsAuto -or -not $IconId) { return 'missing' }
    $modes = @(); if ($HasIcon) { $modes += $IconMode }; if ($HasTile) { $modes += $TileMode }
    if (@($modes | Where-Object { $_ -eq 'apply' }).Count -eq 0) { return 'idle' }
    if ($IsCurrent) { return 'current' }
    return 'replace'
}

function Get-PlanStatusText {
    param([string]$Status, [bool]$HasIcon, [bool]$HasTile, [string]$IconMode, [string]$TileMode, $Text)
    switch ($Status) {
        'replace' { return [string]$Text.StReplace }
        'current' { return [string]$Text.StCurrent }
        'missing' { return [string]$Text.StMissing }
        default {
            $modes = @(); if ($HasIcon) { $modes += $IconMode }; if ($HasTile) { $modes += $TileMode }
            if (@($modes | Where-Object { $_ -eq 'restore' }).Count -eq $modes.Count -and $modes.Count -gt 0) { return [string]$Text.StIdleRestore }
            if (@($modes | Where-Object { $_ -eq 'skip' }).Count -eq $modes.Count -and $modes.Count -gt 0) { return [string]$Text.StIdleSkip }
            return [string]$Text.StIdleMixed
        }
    }
}

# «Пуск», «Панель задач ×2», «Start11»: чипы мест (порядок как в плане). Подписи по коду места - из таблицы строк (ключ Loc_<код>), иначе из плана
function Get-PlanChips {
    param($Locations, $Text)
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($l in @($Locations)) {
        $k = 'Loc_' + [string]$l.Code
        $label = if ($Text.ContainsKey($k)) { [string]$Text[$k] } else { [string]$l.Label }
        if ([int]$l.Count -gt 1) { $label += ' ×' + [int]$l.Count }
        $out.Add($label)
    }
    return $out.ToArray()
}

# запись Get-AppPlan -> данные строки (все поля строки; без WPF)
function ConvertTo-PlanRowData {
    param($Entry, $Catalog, $Text)
    $e = $Entry
    $hasIcon = ([int]$e.ShortcutCount -gt 0); $hasTile = ([int]$e.TileCount -gt 0)
    $im = if ($e.IconMode) { [string]$e.IconMode } else { 'apply' }; $tm = if ($e.TileMode) { [string]$e.TileMode } else { 'apply' }
    $st = Get-PlanStatus ([bool]$e.Auto) ([string]$e.IconId) ([bool]$e.IsCurrent) $hasIcon $hasTile $im $tm
    $src = if ($e.Source) { [string]$e.Source } else { '' }
    $tip = @(@($e.Shortcuts) | ForEach-Object { [string]$_.Path } | Where-Object { $_ } | Select-Object -First 6)
    $extra = [int]$e.ShortcutCount - $tip.Count
    if ($extra -gt 0) { $tip += ('… +' + $extra) }
    return [pscustomobject]@{
        AppKey = [string]$e.AppKey; Name = [string]$e.Name; IconId = [string]$e.IconId; IsAuto = [bool]$e.Auto; IsCurrent = [bool]$e.IsCurrent
        HasIcon = $hasIcon; HasTile = $hasTile; CanStyle = [bool](-not $e.Auto -and $e.IconId); IconMode = $im; TileMode = $tm; Status = $st
        StatusText = (Get-PlanStatusText $st $hasIcon $hasTile $im $tm $Text)
        IconModeText = (Get-ModeText $im $Text); TileModeText = (Get-ModeText $tm $Text)
        Chips = @(Get-PlanChips $e.Locations $Text); Source = $src; StyleCustom = [bool]$src
        StyleText = $(if ($src) { $Text.StyleFmt -f (Format-VariantLabel $Catalog $src) } else { [string]$Text.StyleDefault })
        SearchKey = (([string]$e.Name + ' ' + [string]$e.AppKey).ToLowerInvariant()); Tip = ($tip -join "`n")
        Before = [string]$e.Before; BeforeTarget = [string]$e.BeforeTarget; After = $(if ($e.AfterReady) { [string]$e.After } else { '' })
    }
}

# данные строки -> объект привязки (класс GlyphixGui.PlanRow)
function New-PlanRowVm {
    param($D)
    $r = New-Object GlyphixGui.PlanRow
    $r.AppKey = $D.AppKey; $r.Name = $D.Name; $r.IconId = $D.IconId; $r.IsAuto = $D.IsAuto; $r.IsCurrent = $D.IsCurrent; $r.HasIcon = $D.HasIcon; $r.HasTile = $D.HasTile; $r.CanStyle = $D.CanStyle
    $r.SearchKey = $D.SearchKey; $r.Tip = $(if ([string]$D.Tip) { [string]$D.Tip } else { $null });   # пустая строка = пустая белая подсказка WPF
    $r.Chips = [string[]]@($D.Chips)
    Set-PlanRowFields $r $D
    return $r
}

function Set-PlanRowFields {
    param($Row, $D)
    $Row.Status = $D.Status; $Row.StatusText = $D.StatusText; $Row.IconMode = $D.IconMode; $Row.IconModeText = $D.IconModeText
    $Row.TileMode = $D.TileMode; $Row.TileModeText = $D.TileModeText; $Row.StyleText = $D.StyleText; $Row.Source = $D.Source; $Row.StyleCustom = $D.StyleCustom
}

# после смены режима / источника: пересчитать статус и подписи строки (данные не пересоздаются, картинки и галочка остаются)
function Update-PlanRowState {
    param($Row, $Catalog, $Text)
    $st = Get-PlanStatus ([bool]$Row.IsAuto) ([string]$Row.IconId) ([bool]$Row.IsCurrent) ([bool]$Row.HasIcon) ([bool]$Row.HasTile) ([string]$Row.IconMode) ([string]$Row.TileMode)
    $Row.Status = $st
    $Row.StatusText = (Get-PlanStatusText $st ([bool]$Row.HasIcon) ([bool]$Row.HasTile) ([string]$Row.IconMode) ([string]$Row.TileMode) $Text)
    $Row.IconModeText = (Get-ModeText ([string]$Row.IconMode) $Text); $Row.TileModeText = (Get-ModeText ([string]$Row.TileMode) $Text)
    $Row.StyleCustom = [bool]$Row.Source
    $Row.StyleText = $(if ($Row.Source) { $Text.StyleFmt -f (Format-VariantLabel $Catalog ([string]$Row.Source)) } else { [string]$Text.StyleDefault })
}

# счётчики фильтров: all / replace / current / missing
function Get-PlanCounts {
    param($Rows)
    $c = @{ all = 0; replace = 0; current = 0; missing = 0 }
    foreach ($r in @($Rows)) { if ($null -eq $r) { continue }; $c.all++; if ($c.ContainsKey([string]$r.Status)) { $c[[string]$r.Status]++ } }
    return $c
}

# фильтр плана: вкладка (all | replace | current | missing) + поиск по имени приложения (подстрока, без регистра)
function Select-PlanRows {
    param($Rows, [string]$Filter = 'all', [string]$Query = '')
    $q = ([string]$Query).Trim().ToLowerInvariant()
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        if ($Filter -and $Filter -ne 'all' -and [string]$r.Status -ne $Filter) { continue }
        if ($q -and -not ([string]$r.SearchKey).Contains($q)) { continue }
        $out.Add($r)
    }
    return $out.ToArray()
}

# меню «Стиль» строки: секции каталога по порядку; первый пункт - «по умолчанию» (Id = '')
function New-StyleMenuModel {
    param($Catalog, [string]$CurrentSource = '', [string]$DefaultLabel = 'По умолчанию')
    $groups = [System.Collections.Generic.List[object]]::new()
    $groups.Add([pscustomobject]@{ Title = ''; Items = @([pscustomobject]@{ Id = ''; Title = $DefaultLabel; Current = (-not $CurrentSource) }) })
    foreach ($s in @($Catalog.Sections)) {
        $items = @(@($s.Variants) | ForEach-Object { [pscustomobject]@{ Id = [string]$_.Id; Title = [string]$_.Title; Current = ([string]$_.Id -eq $CurrentSource) } })
        if ($items.Count -gt 0) { $groups.Add([pscustomobject]@{ Title = [string]$s.Title; Items = $items }) }
    }
    return $groups.ToArray()
}

# ---- отчёт для багрепорта ----
# последние N строк файла журнала (файл открыт на запись другим потоком: читаем с FileShare.ReadWrite); нет файла - пусто
function Get-LogTail {
    param([string]$Path, [int]$Count = 200)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $fs = $null; $sr = $null
    try {
        $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $q = [System.Collections.Generic.Queue[string]]::new()
        while (-not $sr.EndOfStream) { $q.Enqueue($sr.ReadLine()); if ($q.Count -gt $Count) { [void]$q.Dequeue() } }
        return $q.ToArray()
    } catch { return @() }
    finally { if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() } }
}

function Format-BugReport {
    param([string]$Version, [string]$WindowsBuild, [bool]$Start11, [bool]$Admin, [string]$Applied = '', $LogLines = @(), [string]$Catalog = '')
    $nl = "`r`n"
    $s = '=== Glyphix: отчёт ===' + $nl
    $s += 'Версия Glyphix: ' + $Version + $nl
    $s += 'Windows: ' + $WindowsBuild + $nl
    $s += 'Start11: ' + $(if ($Start11) { 'найден' } else { 'не найден' }) + $nl
    $s += 'Права администратора: ' + $(if ($Admin) { 'да' } else { 'нет' }) + $nl
    if ($Applied) { $s += 'Применён стиль: ' + $Applied + $nl }
    if ($Catalog) { $s += 'Каталог: ' + $Catalog + $nl }
    $lines = @($LogLines | ForEach-Object { [string]$_ })
    $s += ('--- журнал (последние ' + $lines.Count + ' строк) ---' + $nl)
    $s += ($lines -join $nl) + $nl
    return $s
}

# прогресс из строки журнала движка: «Рисую Glow: 12/40», «Скачиваю Azure: 230/508 (7.4 МБ)» -> @{ Done; Total; Percent } или $null
function ConvertFrom-ProgressLine {
    param([string]$Line)
    $m = [regex]::Match($Line, '(?<!\d)(\d+)/(\d+)(?!\d)')
    if (-not $m.Success) { return $null }
    $d = [long]$m.Groups[1].Value; $t = [long]$m.Groups[2].Value
    if ($t -le 0 -or $d -gt $t) { return $null }
    return @{ Done = $d; Total = $t; Percent = [int][Math]::Floor(100.0 * $d / $t) }
}
#endregion GuiModel

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
# остатки прерванных записей (*.tmp старше 10 минут) удаляет фоновое задание прогрева (Start-Warmup): обход всей папки данных (паки, кэш вариантов) на потоке окна задерживал его появление на секунды

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
    Packs        = 'Стили иконок'
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
    NoPackSel    = 'Выберите стиль слева'
    Scanning     = 'Ищу ярлыки...'
    NoneFound    = 'Подходящих ярлыков не найдено'
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
    ConfirmAppUpdate = 'Доступна версия {1} (установлена {0}).' + "`n`n" + 'Скачать установщик, проверить его по sha256 и обновить Glyphix? Окно приложения закроется; небольшое окно установщика покажет ход обновления и откроет Glyphix заново.'
    AppUpdating  = 'Скачиваю установщик…'
    AppUpdateStarted = 'Установщик запущен, приложение закрывается...'
    AppUpdateFail = 'Автоматически обновить не удалось:' + "`n`n" + '{0}' + "`n`n" + 'Скачайте установщик вручную и запустите его:' + "`n" + '{1}' + "`n`n" + 'Открыть эту ссылку в браузере?'
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
    SelTip       = 'Отметьте стили галочками на карточках (или Ctrl + щелчок по карточке) и скачайте их разом; пак-основа общая для нескольких стилей, уже скачанные свежие пропускаются'
    SelNothing   = 'Ничего не выбрано'
    SelDownloading = 'Скачиваю выбранные паки...'
    SelDone      = 'Скачано паков: {0} (файлов: {1})'
    SelSkipped   = ', уже скачаны: {0}'
    SelFailed    = ', ошибок: {0}'
    SelAllFresh  = 'Все выбранные паки уже скачаны'
    CheckTip     = 'Выбрать стиль (Ctrl + щелчок по карточке - то же самое)'
    Delete       = '🗑'
    DeleteTip    = 'Удалить скачанные файлы пака «{0}» ({1}); стили на нём останутся в списке, «Скачать» вернёт файлы'
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
    NotReadyNote = 'Стиль ещё не скачан: список приложений показан по описанию пака, иконки появятся после «Скачать» (или загрузятся при «Применить»).'
    Applying     = 'Применяю: {0}…'
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
    NoPacks      = 'Стилей пока нет.' + "`n" + 'Нажмите «Обновить паки» (нужен интернет).'
    ConfirmUndo  = 'Вернуть все ярлыки к исходным иконкам?'
    ConfirmUn    = 'Удалить Glyphix? Исходные иконки будут возвращены, папка приложения и ярлыки Glyphix удалены.'
    Busy         = 'Операция ещё выполняется. Дождитесь окончания.'
    Error        = 'Ошибка: {0}'
    Removed      = 'Приложение удалено'
    IconsN       = 'Иконок: {0}'
    Tiles        = 'Плитки Start11'
    TilesNoName  = 'Плитки без подписи'
    TilesDone    = 'Плитки Start11: заменено {0}, уже стояли {1}'
    TilesFail    = ', ошибок: {0}'
    TilesUndone  = ', плиток Start11: {0}'
    Auto         = 'Автоиконки для остальных приложений'
    AutoTip      = 'Приложения, для которых в паке нет иконки, получат СВОЮ родную иконку в стиле пака (создаётся на этом компьютере, сеть не нужна)'
    AutoNotSupported = 'В этом паке нет параметров автоиконок (auto.json) - для остальных приложений иконки не создаются.'
    # ---- 3.0: секции, избранное, план по приложениям ----
    SearchStyle  = 'Поиск стиля…'
    SearchApp    = 'Поиск приложения…'
    FavTitle     = '★ Избранное'
    FavSubtitle  = 'Ваши любимые стили'
    FavOn        = 'В избранное'
    FavOff       = 'Убрать из избранного'
    FavAdded     = 'В избранное: {0}'
    FavRemoved   = 'Убрано из избранного: {0}'
    StylesCount  = 'Стилей: {0}'
    NoMatches    = 'Ничего не найдено — измените запрос.'
    StateTip     = 'Состояние пака-основы «{0}»: «Скачан» значит, что его иконки уже на диске.'
    StateTipShared = 'Основа общая — скачав её, вы получите стили: {0}'
    OnDisk       = 'На диске: {0}'
    DownloadTip  = 'Скачать пак-основу «{0}» (общую для нескольких стилей)'
    StyleLine    = 'Стиль: {0}'
    PlanSummary  = 'Приложений: {0} · заменятся: {1} · уже стоят: {2}'
    PlanFilterEmpty = 'Нет приложений по этому фильтру'
    Filter_all     = 'Все · {0}'
    Filter_replace = 'Заменятся · {0}'
    Filter_current = 'Уже стоят · {0}'
    Filter_missing = 'Нет в паке · {0}'
    ModeApply    = 'Ставить'
    ModeSkip     = 'Не трогать'
    ModeRestore  = 'Вернуть родную'
    ModeTip_apply   = 'Заменить на иконку выбранного стиля'
    ModeTip_skip    = 'Оставить как есть, ничего не менять'
    ModeTip_restore = 'Вернуть исходную иконку (из бэкапа Glyphix)'
    ModeIconHead = 'Иконка ярлыков: {0}'
    ModeTileHead = 'Плитка Start11: {0}'
    ModeSet      = '«{0}»: {1}'
    StReplace    = 'Заменится'
    StCurrent    = 'Уже стоит'
    StMissing    = 'Нет в паке · авто'
    StIdleRestore = 'Вернётся родная'
    StIdleSkip   = 'Не трогаем'
    StIdleMixed  = 'Выборочно'
    StyleDefault = 'Стиль: по умолчанию'
    StyleDefaultShort = 'по умолчанию'
    StyleFmt     = 'Стиль: {0}'
    StyleMenuHead = 'Иконка «{0}» из стиля:'
    StyleMenuDefault = 'По умолчанию (стиль выбранной карточки)'
    SourceSet    = '«{0}»: иконка из стиля — {1}'
    RenderOne    = 'Рисую иконку…'
    Loc_Start    = 'Пуск'
    Loc_Taskbar  = 'Панель задач'
    Loc_Desktop  = 'Рабочий стол'
    Loc_CommonStart   = 'Пуск (общий)'
    Loc_CommonDesktop = 'Рабочий стол (общий)'
    Loc_Start11Tile   = 'Start11'
    PlanSel      = 'Выбрано: {0} из {1}'
    PlanSelHint  = 'Отметьте приложения галочками слева'
    PlanSelAll   = 'Все видимые'
    UndoSel      = 'Откатить выбранные'
    UndoSelFmt   = 'Откатить выбранные ({0})'
    UndoSelTip   = 'Вернуть родные иконки и плитки только отмеченных приложений; остальное не затрагивается'
    UndoSelDoing = 'Возвращаю родные иконки: приложений {0}…'
    UndoSelNothing = 'Отметьте приложения галочками слева'
    UndoSelNone  = 'По этим приложениям в бэкапе ничего нет'
    UndoSelDone  = 'Возвращено: ярлыков {0}, плиток {1}'
    UndoCommon   = ', общих ярлыков без прав администратора: {0} (отметьте «Также общие ярлыки»)'
    ApplyRestored = ', возвращено родных: {0}'
    CheckUpd     = 'Проверить обновления'
    CheckUpdTip  = 'Спросить GitHub, вышла ли новая версия Glyphix (само проверяется при запуске и раз в 30 минут, пока окно открыто)'
    CheckUpdRun  = 'Проверяю обновления…'
    CheckUpdSame = 'У тебя последняя версия {0}'
    CheckUpdNew  = 'Вышла версия {0} — нажми «Обновить» вверху окна'
    CheckUpdFail = 'Не удалось проверить обновления: нет связи с GitHub. Проверь интернет или VPN'
    Report       = 'Скопировать отчёт'
    ReportTip    = 'Версия, сборка Windows, Start11 и последние 200 строк журнала — в буфер обмена, для сообщения об ошибке'
    ReportDone   = 'Отчёт скопирован в буфер обмена (строк журнала: {0})'
    ReportFail   = 'Буфер обмена занят другой программой — повторите'
    DiscordCopied = 'Скопировано'
    DiscordCopiedStatus = 'Discord {0}: ник скопирован в буфер обмена'
    DiscordTip   = 'Нажмите, чтобы скопировать ник'
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
$names = @('ImgLogo', 'TxtVersion', 'TxtAdmin', 'TxtPacksTitle', 'TxtPackSearch', 'TxtPackSearchHint', 'ScrSections', 'SectionsHost', 'TxtEmpty',
    'TxtMatchTitle', 'TxtSelectedPack', 'RbAll', 'RbReplace', 'RbCurrent', 'RbMissing', 'TxtPlanSearch', 'TxtPlanSearchHint', 'PlanList', 'TxtPlanEmpty',
    'ChkPlanAll', 'TxtPlanSel', 'BtnUndoSel', 'TxtMatchSummary', 'BtnUpdate', 'BtnUndo', 'BtnOpen', 'BtnMenu', 'ChkRestart', 'ChkAllUsers', 'ChkTiles', 'ChkNoName', 'ChkAuto',
    'LnkGitHub', 'LnkAuthor', 'LnkDiscord', 'RunDiscord', 'PopMenu', 'PopChoice', 'PopChoiceItems', 'BtnCheckUpd', 'BtnReport', 'BtnUninstall', 'BtnClearCache',
    'TxtSelCount', 'BtnSelDownload', 'BtnSelAll', 'BtnSelNone', 'PrgBusy', 'TxtStatus', 'TxtPct', 'BtnLog', 'LogPanel', 'TxtLog', 'BtnAppUpdate')
foreach ($n in $names) {
    $script:ui[$n] = $script:Window.FindName($n)
    if ($null -eq $script:ui[$n]) { Write-Log "В XAML нет элемента $n"; [void][System.Windows.MessageBox]::Show("В MainWindow.xaml нет элемента $n", 'Glyphix', 'OK', 'Error'); exit 1 }
}
try { Initialize-GuiModel } catch { Write-Log ('Класс строки плана не скомпилирован: ' + $_.Exception.Message); [void][System.Windows.MessageBox]::Show('Не удалось подготовить окно: ' + $_.Exception.Message, 'Glyphix', 'OK', 'Error'); exit 1 }

# ---- состояние GUI ----
$script:Catalog = $null           # Get-VariantCatalog (секции и варианты)
$script:Packs = @()               # Get-Packs: состояние паков-основ (State: ready | stale | none)
$script:Favs = @()                # избранные id вариантов (по порядку)
$script:AppliedId = ''            # применённый вариант (id каталога)
$script:Cards = @{}               # id варианта -> карточка (Border); если вариант есть и в «Избранном», и в своей секции - последняя построенная
$script:CardButtons = @()
$script:CardChecks = @{}          # id варианта -> список CheckBox'ов карточек (в «Избранном» и в своей секции)
$script:UpdManual = $false
$script:Checked = @{}             # отмеченные варианты (переживает перестройку секций)
$script:SelectedId = $null        # выбранный вариант: по нему строится «Что поменяется»
$script:PendingSelect = $null
$script:Job = $null
$script:Closing = $false
$script:UpdJob = $null
$script:SilentJob = $null
$script:SilentCtl = $null         # синхронизированная hashtable { Cancel }: GUI просит тихое обновление остановиться
$script:BgPending = $null         # операция, ждущая окончания тихого обновления паков (Start-Bg -WaitSilent)
$script:SilentWanted = $false     # тихое обновление отложено до конца текущей операции
$script:UpdateInfo = $null
$script:DataHome = $script:SI_Home
$script:HasStart11 = $false
try { $script:HasStart11 = [bool](Test-Start11) } catch { }
$script:BusyNow = $false
$script:PendingWrites = [System.Collections.Generic.List[hashtable]]::new()      # записи в state.json (избранное, режимы), отложенные до конца фоновой операции
$script:OvRecent = $null          # режимы / источники, заданные с начала сканирования плана (Select-Variant): задание могло прочитать state.json до их записи
$script:BuildQueue = $null        # секции, ждущие построения (по одной за такт таймера)
$script:BuildHost = $null         # панель, в которую строятся секции
$script:SectionsPanel = $script:ui.SectionsHost
$script:RowSV = @{}               # id секции -> ScrollViewer ряда карточек
$script:RowOffsets = @{}          # прокрутка рядов и списка, чтобы перестройка секций не сбрасывала положение
$script:SavedV = 0.0
$script:DiskCache = @{}           # id пака -> размер на диске (сбрасывается при перечитывании данных - Load-StyleData)
$script:CardModels = @{}          # id варианта -> модель карточки (для подсказок, которые считаются при наведении)
$script:ImgCache = @{}            # 'путь|ширина|время файла' -> BitmapImage (замороженный)
$script:ThumbQueue = [System.Collections.Generic.Queue[object]]::new()          # превью карточек: Image + путь, грузятся по несколько штук за такт
$script:RowThumbQueue = [System.Collections.Generic.Queue[object]]::new()       # картинки строк плана: Row + Kind (before | after) + путь
$script:PlanAll = $null           # все строки плана выбранного варианта (List[PlanRow])
$script:PlanShown = $null         # то, что показано в списке (ObservableCollection[PlanRow]) - после фильтра
$script:PlanFilter = 'all'
$script:RowIndex = @{}            # AppKey -> строка
$script:ChoiceRow = $null         # строка, для которой открыто общее меню выбора
$script:ChoiceKind = ''
$script:PrevJob = $null           # фоновые картинки «было» и превью автоиконок (отдельно от $script:Job: окно не блокируется)
$script:PrevOld = @()             # остановленные, но ещё не завершившиеся задания
$script:WarmJob = $null
$script:WarmDone = $false

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


# Присвоить свойство элементу интерфейса без динамического биндера: снимаем обёртку PSObject, у DependencyObject пишем через
# SetValue(<Prop>Property), иначе - через PropertyInfo.SetValue; значение приводится к типу свойства.
# (Корень «Argument types do not match» в 3.0.1: @() над List[object], созданным через New-Object, - коллекции теперь только через ::new().)
function Set-UiValue {
    param($Target, [string]$Prop, $Value)
    $t = $Target; if ($t -is [System.Management.Automation.PSObject]) { $t = $t.psobject.BaseObject }
    if ($null -eq $t) { return }
    $v = $Value; if ($v -is [System.Management.Automation.PSObject]) { $v = $v.psobject.BaseObject }
    $ty = $t.GetType()
    $dpo = 'System.Windows.DependencyObject' -as [type]
    if ($dpo -and $dpo.IsInstanceOfType($t)) {
        $f = $ty.GetField($Prop + 'Property', [System.Reflection.BindingFlags]'Public, Static, FlattenHierarchy')
        if ($f) {
            $dp = $f.GetValue($null)
            $t.SetValue($dp, [System.Management.Automation.LanguagePrimitives]::ConvertTo($v, $dp.PropertyType))
            return
        }
    }
    $pi = $ty.GetProperty($Prop)
    if (-not $pi) { throw ("нет свойства " + $Prop + " у " + $ty.FullName) }
    $pi.SetValue($t, [System.Management.Automation.LanguagePrimitives]::ConvertTo($v, $pi.PropertyType), $null)
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

# BitmapImage из файла с кэшем (ключ: путь + ширина декодирования + время файла): одна и та же картинка в «Избранном» и в секции читается с диска один раз
function Get-CachedImg {
    param([string]$Path, [int]$DecodeWidth = 0)
    if (-not $Path) { return $null }
    $stamp = 0
    try { $fi = Get-Item -LiteralPath $Path -ErrorAction Stop; $stamp = $fi.LastWriteTimeUtc.Ticks } catch { return $null }
    $k = $Path + '|' + $DecodeWidth + '|' + $stamp
    if ($script:ImgCache.ContainsKey($k)) { return $script:ImgCache[$k] }
    $bi = New-Img $Path $DecodeWidth
    if ($bi) {
        if ($script:ImgCache.Count -gt 600) { $script:ImgCache.Clear() }
        $script:ImgCache[$k] = $bi
    }
    return $bi
}

# Запись в state.json (избранное, режимы приложений): пока идёт фоновая операция или тихое обновление паков (они тоже читают и пишут
# state.json целиком: Read-State ... Save-State без блокировки) - откладывается до их конца, иначе одна из записей теряется.
# Операция - hashtable (не scriptblock: замыкание не видит функции этого скрипта): @{ Kind = 'favorite'; Id; On } | @{ Kind = 'override'; Key; [Icon]; [Tile]; [Source] }
function Write-StateOp {
    param([hashtable]$Op)
    try {
        if ($Op.Kind -eq 'favorite') { [void](Set-Favorite ([string]$Op.Id) ([bool]$Op.On)) }
        elseif ($Op.Kind -eq 'override') {
            $a = @{ AppKey = [string]$Op.Key }
            foreach ($f in @('Icon', 'Tile', 'Source')) { if ($Op.ContainsKey($f)) { $a[$f] = [string]$Op[$f] } }
            Set-AppOverride @a
        }
    } catch { Show-Error $_ 'запись состояния' }
}

function Invoke-StateWrite {
    param([hashtable]$Op)
    if ($Op.Kind -eq 'override' -and $null -ne $script:OvRecent) { $script:OvRecent.Add($Op) }      # план, который сейчас сканируется, получит этот режим поверх прочитанного (Fill-Plan)
    if ($script:Job -or $script:BgPending -or $script:SilentJob) { $script:PendingWrites.Add($Op); return }
    Write-StateOp $Op
}

# -Force: при закрытии окна (пишем, даже если тихое обновление ещё не остановилось - иначе выбор пропал бы совсем)
function Flush-StateWrites {
    param([switch]$Force)
    if ($script:PendingWrites.Count -eq 0) { return }
    if (-not $Force -and ($script:Job -or ($script:SilentJob -and -not $script:SilentJob.Async.IsCompleted))) { return }      # тихое обновление паков ещё пишет (в конце - state.json: LastUpdate)
    $list = @($script:PendingWrites.ToArray())
    $script:PendingWrites.Clear()
    foreach ($d in $list) { Write-StateOp $d }
}

# индикатор в строке состояния: из строк журнала движка («Рисую Glow: 12/40», «Скачиваю Azure: 230/508 (7.4 МБ)») берём done/total
function Set-Progress {
    param($Pg)
    if ($Pg) {
        $script:ui.PrgBusy.IsIndeterminate = $false
        $script:ui.PrgBusy.Maximum = 100
        $script:ui.PrgBusy.Value = [double]$Pg.Percent
        $script:ui.TxtPct.Text = ('{0}%' -f $Pg.Percent)
    } else {
        $script:ui.PrgBusy.IsIndeterminate = $script:BusyNow
        $script:ui.TxtPct.Text = ''
    }
}

function Set-Busy {
    param([bool]$Busy)
    $script:BusyNow = $Busy
    $script:ui.PrgBusy.Visibility = if ($Busy) { 'Visible' } else { 'Hidden' }
    Set-Progress $null
    foreach ($b in @($script:ui.BtnUpdate, $script:ui.BtnUndo, $script:ui.BtnMenu, $script:ui.BtnAppUpdate)) { Set-UiValue $b 'IsEnabled' (-not $Busy) }
    foreach ($b in $script:CardButtons) { Set-UiValue $b 'IsEnabled' (-not $Busy) }
    if (-not $Busy) { Flush-StateWrites }
    Update-SelBar
    Update-PlanSel
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
        Flush-StateWrites          # отложенные режимы / избранное - до старта операции: Apply-Plan и Get-AppPlan читают их из state.json
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
    while ($job.Queue.TryDequeue([ref]$line)) { Add-LogLine $line; Set-Status $line; $pg = ConvertFrom-ProgressLine $line; if ($pg) { Set-Progress $pg } }
    if (-not $job.Async.IsCompleted) { return }
    $script:Timer.Stop()
    $res = Receive-EngineJob $job
    $script:Job = $null
    Set-Busy $false
    if ($res -and $res.PSObject.Properties['Error'] -and $res.Error) { Write-Log ('Фоновая операция завершилась ошибкой: ' + $res.Error) }
    try { & $job.OnDone $res } catch { Show-Error $_ 'после операции' }
    if ($script:PendingSelect) { $p = $script:PendingSelect; $script:PendingSelect = $null; try { Select-Variant $p } catch { Show-Error $_ 'выбор стиля' } }
    if ($script:SilentWanted -and -not $script:Job -and -not $script:BgPending) { try { Start-SilentRefresh } catch { } }      # Start-Initial: первое сканирование плана заняло $script:Job
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
    if ($script:UpdManual) {
        $script:UpdManual = $false
        if (-not $info -or -not $info.PSObject.Properties['Available'] -or -not [string]$info.Remote) { Set-Status $script:T.CheckUpdFail }
        elseif ($info.Available) { Set-Status ($script:T.CheckUpdNew -f [string]$info.Remote) }
        else { Set-Status ($script:T.CheckUpdSame -f [string]$info.Local) }
    }
}

function Start-UpdateCheck {
    param([switch]$Manual)
    if ($Manual) { $script:UpdManual = $true; Set-Status $script:T.CheckUpdRun }
    if ($script:UpdJob -or $script:Closing) { return }
    try {
        $script:UpdJob = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Body 'param($p) Get-AppUpdateInfo' -Params @{}
        $script:UpdTimer.Start()
    } catch {
        $script:UpdJob = $null; Write-Log ('Проверка версии не запущена: ' + $_.Exception.Message)
        if ($script:UpdManual) { $script:UpdManual = $false; Set-Status $script:T.CheckUpdFail }
    }
}

# ---- тихое обновление паков на каждом запуске ----
# index.json + variants.json + pack.json + превью (без иконок и плиток) в отдельном runspace, без строки состояния и индикатора занятости:
# карточки (версия, число иконок, превью, состав секций) обновляются по готовности. Иначе кэш старой версии показывался бы до ручного «Обновить паки».
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
    Flush-StateWrites
    if ($script:Closing) { return }
    if ($res -and $res.PSObject.Properties['Error'] -and $res.Error) { Write-Log ('Тихое обновление паков: ' + $res.Error); return }
    $changed = $false
    if ($res -and $res.PSObject.Properties['Downloaded'] -and [int]$res.Downloaded -gt 0) { $changed = $true }
    if ($res -and $res.PSObject.Properties['Variants'] -and $res.Variants) {          # каталог вариантов или его превью обновились
        $vr = $res.Variants
        if (($vr.PSObject.Properties['Updated'] -and $vr.Updated) -or ($vr.PSObject.Properties['Previews'] -and [int]$vr.Previews -gt 0)) { $changed = $true }
    }
    if ($changed) {
        Reload-Styles
        if ($script:SelectedId -and $script:Catalog.ById.ContainsKey($script:SelectedId)) { Select-Variant $script:SelectedId }
        else { $first = Get-InitialSelection; if ($first) { Select-Variant $first } }
    }
}

function Start-SilentRefresh {
    if ($script:SilentJob -or $script:Closing) { return }
    if ($script:Job -or $script:BgPending) { $script:SilentWanted = $true; return }      # идёт сканирование / Применить / ...: тихое обновление (оно пишет те же файлы) - сразу после неё (Step-Job)
    $script:SilentWanted = $false
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
    # Весь путь - в фоновом runspace без консоли: Engine.ps1 Start-AppSelfUpdate (скачать и проверить GlyphixSetup.exe, запустить /update /wait-pid <наш PID>)
    Start-Bg -WaitSilent -Title $script:T.AppUpdating -Params @{} -Body @'
param($p)
try { [pscustomobject]@{ Started = $true; Installer = (Start-AppSelfUpdate) } }
catch { [pscustomobject]@{ Error = $_.Exception.Message; Url = (Get-SetupFallbackUrl) } }
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Обновление не вернуло результат'; return }
        if ($res.Error) {
            Show-Error $res 'обновление приложения'
            $url = if ($res.PSObject.Properties['Url'] -and $res.Url) { [string]$res.Url } else { 'https://github.com/F1KS-FK/glyphix/releases/latest' }
            $ans = [System.Windows.MessageBox]::Show($script:Window, ($script:T.AppUpdateFail -f $res.Error, $url), $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
            if ($ans -eq [System.Windows.MessageBoxResult]::Yes) {
                try { if (Test-Admin) { [System.Windows.Clipboard]::SetText($url); Set-Status ($script:T.LinkCopied -f $url) } else { Start-Process -FilePath $url } } catch { Show-Error $_ 'открыть ссылку' }
            }
            return
        }
        Set-Status $script:T.AppUpdateStarted
        $script:Closing = $true
        $script:Window.Close()
    }
}

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Brush = 'TextBrush', [string]$Weight = 'Normal')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.Foreground = (Get-Res $Brush)
    $tb.FontWeight = [System.Windows.FontWeights]::$Weight
    return $tb
}

# ---- секции и карточки стилей ----
function Update-CardHighlight {
    foreach ($id in @($script:Cards.Keys)) {
        foreach ($c in $script:Cards[$id].ToArray()) {
            if ($id -eq $script:SelectedId) { Set-UiValue $c 'BorderBrush' (Get-Res 'AccentBrush') } else { Set-UiValue $c 'BorderBrush' (Get-Res 'CardBorderBrush') }
        }
    }
}

# плашка состояния на карточке: применён / скачан / не скачан / есть обновление
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
        $script:ui.BtnSelAll.IsEnabled = ($script:Cards.Count -gt 0)
    } catch { }
}

function Set-VariantChecked {
    param([string]$Id, [bool]$On)
    if ($On) { $script:Checked[$Id] = $true } else { $script:Checked.Remove($Id) }
    if ($script:CardChecks.ContainsKey($Id)) { foreach ($ck in $script:CardChecks[$Id].ToArray()) { Set-UiValue $ck 'IsChecked' $On } }
    Update-SelBar
}

function Get-PackDiskText {
    param($C)
    if ($C.State -eq 'none' -or -not $C.PackDir) { return '' }
    if (-not $script:DiskCache.ContainsKey($C.BaseId)) { $script:DiskCache[$C.BaseId] = (Format-DownloadSize (Get-PackDiskBytes ([string]$C.PackDir))) }
    return [string]$script:DiskCache[$C.BaseId]
}

function New-RowDef {
    param([double]$H, [bool]$Star = $false)
    $rd = New-Object System.Windows.Controls.RowDefinition
    $rd.Height = $(if ($Star) { New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star) } else { New-Object System.Windows.GridLength($H) })
    return $rd
}

# Карточка варианта: фиксированный размер (как в 2.x: 288x250 + поля 6), строки заданы жёстко - текст высоту не растягивает.
# Превью - Image (картинку подгружает таймер превью через Set-ImageSource), поверх: галочка выбора (слева) и звезда «в избранное» (справа).
function New-VariantCard {
    param($C, [string]$AppliedBaseId)
    $id = [string]$C.Id
    $card = New-Object System.Windows.Controls.Border
    $card.Style = (Get-Res 'CardStyle')
    $card.Width = 288
    $card.Height = 250
    $card.Margin = New-Object System.Windows.Thickness(6)
    $card.Tag = $id
    $card.Cursor = [System.Windows.Input.Cursors]::Hand
    $card.ToolTip = ([string]$C.SectionTitle + ' · ' + [string]$C.Title)
    $g = New-Object System.Windows.Controls.Grid
    foreach ($h in @(92, 34, 20, 36)) { [void]$g.RowDefinitions.Add((New-RowDef $h)) }
    [void]$g.RowDefinitions.Add((New-RowDef 0 $true))

    # превью 266x92 со скруглением (Clip), пока картинка грузится - тёмная подложка
    $pv = New-Object System.Windows.Controls.Grid
    $bg = New-Object System.Windows.Controls.Border
    $bg.CornerRadius = New-Object System.Windows.CornerRadius(10)
    $bg.Background = (Get-Res 'RowBrush')
    [void]$pv.Children.Add($bg)
    $img = New-Object System.Windows.Controls.Image
    $img.Width = 266
    $img.Height = 92
    $img.Stretch = [System.Windows.Media.Stretch]::UniformToFill
    $clip = New-Object System.Windows.Media.RectangleGeometry
    $clip.Rect = New-Object System.Windows.Rect(0, 0, 266, 92)
    $clip.RadiusX = 10
    $clip.RadiusY = 10
    $img.Clip = $clip
    [System.Windows.Media.RenderOptions]::SetBitmapScalingMode($img, [System.Windows.Media.BitmapScalingMode]::HighQuality)
    [void]$pv.Children.Add($img)
    $pp = [string]$C.PreviewPath
    if (-not $pp) { $pp = [string](Get-VariantPreviewPath $id) }
    if ($pp) { $script:ThumbQueue.Enqueue(@{ Image = $img; Path = $pp; Width = 600 }) }
    # галочка выбора (поверх превью, слева сверху): несколько стилей можно скачать разом
    $ckBox = New-Object System.Windows.Controls.Border
    $ckBox.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $ckBox.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(190, 7, 10, 24))
    $ckBox.Padding = New-Object System.Windows.Thickness(5, 0, 5, 0)
    $ckBox.Margin = New-Object System.Windows.Thickness(6)
    $ckBox.HorizontalAlignment = 'Left'
    $ckBox.VerticalAlignment = 'Top'
    $chk = New-Object System.Windows.Controls.CheckBox
    $chk.Style = (Get-Res 'DarkCheck')
    $chk.Tag = $id
    $chk.ToolTip = $script:T.CheckTip
    $chk.IsChecked = [bool]$script:Checked.ContainsKey($id)
    $chk.Add_Click({ param($s, $e) try { Set-VariantChecked ([string]$s.Tag) ([bool]$s.IsChecked) } catch { Show-Error $_ 'выбор стилей' } })
    $ckBox.Child = $chk
    [void]$pv.Children.Add($ckBox)
    if (-not $script:CardChecks.ContainsKey($id)) { $script:CardChecks[$id] = [System.Collections.Generic.List[object]]::new() }
    $script:CardChecks[$id].Add($chk.psobject.BaseObject)
    # звезда «в избранное» (справа сверху)
    $star = New-Object System.Windows.Controls.Border
    $star.Width = 28
    $star.Height = 28
    $star.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $star.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Color]::FromArgb(190, 7, 10, 24))
    $star.Margin = New-Object System.Windows.Thickness(6)
    $star.HorizontalAlignment = 'Right'
    $star.VerticalAlignment = 'Top'
    $star.Cursor = [System.Windows.Input.Cursors]::Hand
    $star.Tag = $id
    $star.ToolTip = $(if ($C.IsFavorite) { $script:T.FavOff } else { $script:T.FavOn })
    $st = New-Text $(if ($C.IsFavorite) { '★' } else { '☆' }) 16 $(if ($C.IsFavorite) { 'StarBrush' } else { 'MutedBrush' }) 'Normal'
    $st.HorizontalAlignment = 'Center'
    $st.VerticalAlignment = 'Center'
    $st.Margin = New-Object System.Windows.Thickness(0, -1, 0, 0)
    $star.Child = $st
    $star.Add_MouseLeftButtonUp({ param($s, $e) try { $e.Handled = $true; Toggle-Favorite ([string]$s.Tag) } catch { Show-Error $_ 'избранное' } })
    [void]$pv.Children.Add($star)
    [System.Windows.Controls.Grid]::SetRow($pv, 0)
    [void]$g.Children.Add($pv)

    # название + состояние базового пака (применён / скачан / не скачан); подсказка объясняет, что пак-основа общая для нескольких стилей
    $head = New-Object System.Windows.Controls.Grid
    $h1 = New-Object System.Windows.Controls.ColumnDefinition; $h1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $h2 = New-Object System.Windows.Controls.ColumnDefinition; $h2.Width = [System.Windows.GridLength]::Auto
    [void]$head.ColumnDefinitions.Add($h1); [void]$head.ColumnDefinitions.Add($h2)
    $head.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
    $nm = New-Text ([string]$C.Title) 16 'TextBrush' 'SemiBold'
    $nm.TextTrimming = 'CharacterEllipsis'
    $nm.VerticalAlignment = 'Center'
    $nm.Margin = New-Object System.Windows.Thickness(0, 0, 8, 0)
    [void]$head.Children.Add($nm)
    $stateText = if ($C.IsApplied) { $script:T.Applied } elseif ($C.State -eq 'ready') { $script:T.StateReady } elseif ($C.State -eq 'stale') { $script:T.StateStale } else { $script:T.StateNone }
    # размер пака на диске - обход всех его файлов (сотни мс на пак в PowerShell 5.1): считаем не при построении карточек, а при первом показе подсказки
    $script:CardModels[$id] = $C
    $pill = New-StatePill $stateText ([bool]$C.IsApplied)
    $tip = Get-CardStateTip $C $script:T
    $pill.ToolTip = $tip
    $pill.Tag = $id
    if ($C.State -ne 'none' -and $C.PackDir) {
        $pill.Add_ToolTipOpening({
            param($s, $e)
            try {
                $cm = $script:CardModels[[string]$s.Tag]
                if (-not $cm) { return }
                $dt = Get-PackDiskText $cm
                $t = Get-CardStateTip $cm $script:T
                if ($dt) { $t += "`n" + ($script:T.OnDisk -f $dt) }
                $s.ToolTip = $t
            } catch { }
        })
    }
    [System.Windows.Controls.Grid]::SetColumn($pill, 1)
    [void]$head.Children.Add($pill)
    [System.Windows.Controls.Grid]::SetRow($head, 1)
    [void]$g.Children.Add($head)

    $metaText = [string]$C.Author
    if ($C.Version) { $metaText += ' · v' + $C.Version }
    if ([int]$C.IconCount -gt 0) { $metaText += ' · ' + ($script:T.IconsN -f $C.IconCount) }
    $meta = New-Text $metaText 12 'MutedBrush'
    $meta.Margin = New-Object System.Windows.Thickness(2, 0, 0, 0)
    $meta.VerticalAlignment = 'Center'
    $meta.TextTrimming = 'CharacterEllipsis'
    [System.Windows.Controls.Grid]::SetRow($meta, 2)
    [void]$g.Children.Add($meta)
    if ($C.Blurb) {
        $ds = New-Text ([string]$C.Blurb) 12 'MutedBrush'
        $ds.TextWrapping = 'Wrap'
        $ds.TextTrimming = 'CharacterEllipsis'
        $ds.VerticalAlignment = 'Top'
        $ds.Margin = New-Object System.Windows.Thickness(2, 2, 0, 0)
        $ds.ToolTip = [string]$C.Blurb
        [System.Windows.Controls.Grid]::SetRow($ds, 3)
        [void]$g.Children.Add($ds)
    }
    # кнопки: три фиксированные колонки (Применить | Скачать | корзина), всегда в одном и том же месте карточки
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
    $btn.Tag = $id
    $btn.IsEnabled = (-not $script:BusyNow)
    $btn.Add_Click({ param($s, $e) try { Invoke-Apply ([string]$s.Tag) } catch { Show-Error $_ 'Применить' } })
    [void]$row.Children.Add($btn)
    $script:CardButtons += $btn
    if ($C.State -ne 'ready') {          # «Скачать» - иконки и плитки базового пака (по требованию)
        $dl = New-Object System.Windows.Controls.Button
        $dl.Style = (Get-Res 'GhostButton')
        $dl.Content = $script:T.Download
        $dl.Tag = $id
        $dl.Margin = New-Object System.Windows.Thickness(10, 0, 0, 0)
        $dl.ToolTip = ($script:T.DownloadTip -f $C.BaseName)
        $dl.IsEnabled = (-not $script:BusyNow)
        $dl.Add_Click({ param($s, $e) try { Invoke-Download ([string]$s.Tag) } catch { Show-Error $_ 'Скачать' } })
        [System.Windows.Controls.Grid]::SetColumn($dl, 1)
        [void]$row.Children.Add($dl)
        $script:CardButtons += $dl
    }
    if ($C.State -ne 'none' -and [string]$C.BaseId -ne $AppliedBaseId) {       # скачанную основу, не применённую сейчас, можно убрать с диска («Скачать» вернёт файлы)
        $del = New-Object System.Windows.Controls.Button
        $del.Style = (Get-Res 'GhostButton')
        $del.Content = $script:T.Delete
        $del.Tag = $id
        $del.MinWidth = 40
        $del.Width = 40
        $del.Padding = New-Object System.Windows.Thickness(0)
        $del.HorizontalAlignment = 'Right'
        $del.ToolTip = ($script:T.DeleteTip -f $C.BaseName, '…')
        $del.Add_ToolTipOpening({
            param($s, $e)
            try { $cm = $script:CardModels[[string]$s.Tag]; if ($cm) { $s.ToolTip = ($script:T.DeleteTip -f $cm.BaseName, (Get-PackDiskText $cm)) } } catch { }
        })
        $del.IsEnabled = (-not $script:BusyNow)
        $del.Add_Click({ param($s, $e) try { Invoke-DeletePack ([string]$s.Tag) } catch { Show-Error $_ 'Удалить пак' } })
        [System.Windows.Controls.Grid]::SetColumn($del, 2)
        [void]$row.Children.Add($del)
        $script:CardButtons += $del
    }
    [System.Windows.Controls.Grid]::SetRow($row, 4)
    [void]$g.Children.Add($row)
    $card.Child = $g
    $card.Add_MouseLeftButtonUp({
        param($s, $e)
        try {
            $vid = [string]$s.Tag
            if (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0) { Set-VariantChecked $vid (-not $script:Checked.ContainsKey($vid)); return }      # Ctrl + щелчок: выбрать / снять
            Select-Variant $vid
        } catch { Show-Error $_ 'выбор стиля' }
    })
    if (-not $script:Cards.ContainsKey($id)) { $script:Cards[$id] = [System.Collections.Generic.List[object]]::new() }
    $script:Cards[$id].Add($card.psobject.BaseObject)
    return $card
}

# стрелки ‹ › у края ряда: видны, только когда ряд не помещается и есть куда крутить
function Update-RowNav {
    param($Sv)
    $t = $Sv.Tag
    if (-not $t) { return }
    $max = [double]$Sv.ScrollableWidth
    $cur = [double]$Sv.HorizontalOffset
    $t.Left.Visibility = $(if ($max -gt 1 -and $cur -gt 1) { 'Visible' } else { 'Collapsed' })
    $t.Right.Visibility = $(if ($max -gt 1 -and $cur -lt ($max - 1)) { 'Visible' } else { 'Collapsed' })
}

# колесо над рядом: ряд не помещается и есть куда крутить - листаем ряд по горизонтали; иначе колесо уходит списку секций (вложенный ScrollViewer иначе съел бы его)
$script:OnRowWheel = {
    param($s, $e)
    try {
        $d = [double]$e.Delta
        $max = [double]$s.ScrollableWidth
        $cur = [double]$s.HorizontalOffset
        $shift = (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift) -ne 0)
        if ($max -gt 1) {
            $new = [Math]::Max(0.0, [Math]::Min($max, $cur - $d * 1.5))
            if ([Math]::Abs($new - $cur) -gt 0.5) { $s.ScrollToHorizontalOffset($new); $e.Handled = $true; return }
            if ($shift) { $e.Handled = $true; return }
        }
        $o = $script:ui.ScrSections
        $o.ScrollToVerticalOffset([Math]::Max(0.0, [double]$o.VerticalOffset - $d))
        $e.Handled = $true
    } catch { Show-Error $_ 'прокрутка ряда' }
}

# Секция: заголовок (крупное название семейства + подзаголовок + счётчик) и под ним горизонтальный ряд карточек
function New-SectionView {
    param($M, [string]$AppliedBaseId)
    $sec = New-Object System.Windows.Controls.Border
    $sec.Background = (Get-Res 'SectionBrush')
    $sec.BorderBrush = (Get-Res 'SectionBorderBrush')
    $sec.BorderThickness = New-Object System.Windows.Thickness(1)
    $sec.CornerRadius = New-Object System.Windows.CornerRadius(18)
    $sec.Padding = New-Object System.Windows.Thickness(16, 14, 16, 8)
    $sec.Margin = New-Object System.Windows.Thickness(0, 0, 0, 14)
    $sec.Tag = [string]$M.Id
    $g = New-Object System.Windows.Controls.StackPanel
    $hd = New-Object System.Windows.Controls.Grid
    $hd.Margin = New-Object System.Windows.Thickness(6, 0, 6, 8)
    $ha = New-Object System.Windows.Controls.ColumnDefinition; $ha.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    $hb = New-Object System.Windows.Controls.ColumnDefinition; $hb.Width = [System.Windows.GridLength]::Auto
    [void]$hd.ColumnDefinitions.Add($ha); [void]$hd.ColumnDefinitions.Add($hb)
    $left = New-Object System.Windows.Controls.StackPanel
    $left.Orientation = 'Horizontal'
    $bar = New-Object System.Windows.Controls.Border
    $bar.Width = 5
    $bar.Height = 30
    $bar.CornerRadius = New-Object System.Windows.CornerRadius(3)
    $bar.Background = (Get-Res 'AccentBrush')
    $bar.Margin = New-Object System.Windows.Thickness(0, 0, 12, 0)
    $bar.VerticalAlignment = 'Center'
    [void]$left.Children.Add($bar)
    $title = New-Text ([string]$M.Title) 28 'TextBrush' 'SemiBold'
    $title.Foreground = (Get-Res 'SectionTitleBrush')
    $title.VerticalAlignment = 'Center'
    [void]$left.Children.Add($title)
    if ($M.Subtitle) {
        $sub = New-Text ([string]$M.Subtitle) 14 'MutedBrush'
        $sub.VerticalAlignment = 'Bottom'
        $sub.Margin = New-Object System.Windows.Thickness(16, 0, 0, 5)
        $sub.TextTrimming = 'CharacterEllipsis'
        [void]$left.Children.Add($sub)
    }
    [void]$hd.Children.Add($left)
    $cnt = New-StatePill ($script:T.StylesCount -f @($M.Cards).Count) $false
    [System.Windows.Controls.Grid]::SetColumn($cnt, 1)
    [void]$hd.Children.Add($cnt)
    [void]$g.Children.Add($hd)

    # ряд карточек: ScrollViewer без видимых полос (колесо и стрелки), стрелки лежат поверх краёв и не двигают раскладку
    $rowHost = New-Object System.Windows.Controls.Grid
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.HorizontalScrollBarVisibility = 'Hidden'
    $sv.VerticalScrollBarVisibility = 'Disabled'
    $sv.Focusable = $false
    $strip = New-Object System.Windows.Controls.StackPanel
    $strip.Orientation = 'Horizontal'
    foreach ($c in @($M.Cards)) {
        try { [void]$strip.Children.Add((New-VariantCard $c $AppliedBaseId)) } catch { Show-Error $_ ('карточка ' + $c.Id) }      # одна неудачная карточка не оставляет без ряда остальные
    }
    $sv.Content = $strip
    [void]$rowHost.Children.Add($sv)
    $nl = New-Object System.Windows.Controls.Button
    $nl.Style = (Get-Res 'NavButton')
    $nl.Content = '‹'
    $nl.HorizontalAlignment = 'Left'
    $nl.VerticalAlignment = 'Top'
    $nl.Margin = New-Object System.Windows.Thickness(2, 44, 0, 0)          # на уровне превью (середина картинки), а не поверх названий и кнопок
    $nl.Visibility = 'Collapsed'
    $nl.Tag = $sv
    $nl.Add_Click({ param($s, $e) try { $x = $s.Tag; $x.ScrollToHorizontalOffset([Math]::Max(0.0, [double]$x.HorizontalOffset - 300)) } catch { Show-Error $_ 'прокрутка' } })
    [void]$rowHost.Children.Add($nl)
    $nr = New-Object System.Windows.Controls.Button
    $nr.Style = (Get-Res 'NavButton')
    $nr.Content = '›'
    $nr.HorizontalAlignment = 'Right'
    $nr.VerticalAlignment = 'Top'
    $nr.Margin = New-Object System.Windows.Thickness(0, 44, 2, 0)
    $nr.Visibility = 'Collapsed'
    $nr.Tag = $sv
    $nr.Add_Click({ param($s, $e) try { $x = $s.Tag; $x.ScrollToHorizontalOffset([Math]::Min([double]$x.ScrollableWidth, [double]$x.HorizontalOffset + 300)) } catch { Show-Error $_ 'прокрутка' } })
    [void]$rowHost.Children.Add($nr)
    $sv.Tag = @{ Left = $nl; Right = $nr }
    $sv.Add_ScrollChanged({ param($s, $e) try { Update-RowNav $s } catch { } })
    $sv.Add_PreviewMouseWheel($script:OnRowWheel)
    $script:RowSV[[string]$M.Id] = $sv
    [void]$g.Children.Add($rowHost)
    $sec.Child = $g
    return $sec
}

# Секции строятся по одной за такт таймера (окно не замирает: ~50 карточек за один заход давали бы паузу). При перестройке готовый список остаётся на экране,
# новый строится отдельно и подменяется целиком, а положение прокрутки возвращается (RestoreTimer).
function Show-Sections {
    if (-not $script:Catalog) { return }
    $script:BuildTimer.Stop()
    $script:RestoreTimer.Stop()
    try {
        $script:SavedV = [double]$script:ui.ScrSections.VerticalOffset
        foreach ($k in @($script:RowSV.Keys)) { $script:RowOffsets[$k] = [double]$script:RowSV[$k].HorizontalOffset }
    } catch { }
    $query = ([string]$script:ui.TxtPackSearch.Text).Trim()
    $models = @(New-SectionModels $script:Catalog $script:Favs $script:Packs $script:AppliedId $query $script:T.FavTitle $script:T.FavSubtitle)
    $script:CardModels = @{}
    $script:Cards = @{}; $script:CardButtons = @(); $script:CardChecks = @{}; $script:RowSV = @{}
    $script:ThumbQueue.Clear()
    $script:ui.TxtEmpty.Text = $(if ($query -and $script:Catalog.Variants.Count -gt 0) { $script:T.NoMatches } else { $script:T.NoPacks })
    $script:ui.TxtEmpty.Visibility = $(if ($models.Count -eq 0) { 'Visible' } else { 'Collapsed' })
    if ($script:SectionsPanel.Children.Count -eq 0) { $script:BuildHost = $script:SectionsPanel }
    else {
        $h = New-Object System.Windows.Controls.StackPanel
        $h.Margin = $script:SectionsPanel.Margin
        $script:BuildHost = $h
    }
    $script:BuildQueue = [System.Collections.Generic.Queue[object]]::new()
    foreach ($m in $models) { $script:BuildQueue.Enqueue($m) }
    Update-SelBar
    if ($script:BuildQueue.Count -eq 0) { Complete-Build } else { $script:BuildTimer.Start() }
}

function Step-Build {
    $q = $script:BuildQueue
    if (-not $q -or $q.Count -eq 0) { Complete-Build; return }
    $m = $q.Dequeue()
    try { [void]$script:BuildHost.Children.Add((New-SectionView $m (Get-AppliedBaseId))) } catch { Show-Error $_ ('секция ' + $m.Id) }
    if ($q.Count -eq 0) { Complete-Build }
}

function Complete-Build {
    $script:BuildTimer.Stop()
    if ($script:BuildHost -and -not [object]::ReferenceEquals($script:BuildHost, $script:SectionsPanel)) {
        $script:ui.ScrSections.Content = $script:BuildHost
        $script:SectionsPanel = $script:BuildHost
    }
    Update-CardHighlight
    Update-SelBar
    Start-Thumbs
    $script:RestoreTimer.Start()
}

function Restore-Offsets {
    $script:RestoreTimer.Stop()
    try {
        $script:ui.ScrSections.ScrollToVerticalOffset([double]$script:SavedV)
        foreach ($k in @($script:RowSV.Keys)) {
            if ($script:RowOffsets.ContainsKey($k)) { $script:RowSV[$k].ScrollToHorizontalOffset([double]$script:RowOffsets[$k]) }
            Update-RowNav $script:RowSV[$k]
        }
    } catch { }
}

# основа применённого сейчас варианта (её файлы удалять нельзя)
function Get-AppliedBaseId {
    if ($script:AppliedId -and $script:Catalog -and $script:Catalog.ById.ContainsKey($script:AppliedId)) { return [string]$script:Catalog.ById[$script:AppliedId].Base }
    return ''
}

# данные с диска (каталог, состояние паков, избранное, применённый вариант) - быстрое чтение, как Get-Packs в 2.x
function Load-StyleData {
    $script:DiskCache = @{}          # паки могли скачаться / удалиться - размеры пересчитаются при наведении
    try {
        $script:Catalog = Get-VariantCatalog
        $script:Packs = @(Get-Packs)
        $script:Favs = @(Get-Favorites)
        $script:AppliedId = Get-AppliedAlias $script:Catalog (Get-AppliedVariantId)
    } catch { Show-Error $_ 'каталог стилей' }
    if ($script:Catalog) { foreach ($ck in @($script:Checked.Keys)) { if (-not $script:Catalog.ById.ContainsKey([string]$ck)) { $script:Checked.Remove($ck) } } }      # стиля уже нет - выбор снимаем
}

function Reload-Styles {
    Load-StyleData
    Show-Sections
}

# какой стиль показать первым: применённый, иначе первый избранный, иначе первый в каталоге
function Get-InitialSelection {
    if (-not $script:Catalog) { return $null }
    if ($script:AppliedId) { return $script:AppliedId }
    foreach ($f in @($script:Favs)) { if ($script:Catalog.ById.ContainsKey([string]$f)) { return [string]$f } }
    $v = @($script:Catalog.Variants) | Select-Object -First 1
    if ($v) { return [string]$v.Id }
    return $null
}

function Toggle-Favorite {
    param([string]$Id)
    $on = -not (@($script:Favs) -contains $Id)
    if ($on) { $script:Favs = @(@($script:Favs) + $Id) } else { $script:Favs = @(@($script:Favs) | Where-Object { $_ -ne $Id }) }
    Invoke-StateWrite @{ Kind = 'favorite'; Id = $Id; On = $on }
    Show-Sections
    Set-Status ($(if ($on) { $script:T.FavAdded } else { $script:T.FavRemoved }) -f (Format-VariantLabel $script:Catalog $Id))
}

# превью и картинки строк плана: по несколько штук за такт (декодирование на потоке интерфейса, но малыми порциями)
function Step-Thumbs {
    $n = 0
    while ($n -lt 4 -and $script:ThumbQueue.Count -gt 0) {
        $it = $script:ThumbQueue.Dequeue(); $n++
        try { $src = Get-CachedImg ([string]$it.Path) ([int]$it.Width); if ($src) { [void](Set-ImageSource $it.Image $src) } } catch { Show-Error $_ 'превью' }
    }
    $m = 0
    while ($m -lt 8 -and $script:RowThumbQueue.Count -gt 0) {
        $it = $script:RowThumbQueue.Dequeue(); $m++
        try {
            $src = Get-CachedImg ([string]$it.Path) 96
            if ($src -is [System.Management.Automation.PSObject]) { $src = $src.psobject.BaseObject }      # в свойство object класса строки - сам BitmapImage, не обёртку PowerShell (иначе привязка Image.Source его не примет)
            if ($src) { if ([string]$it.Kind -eq 'before') { $it.Row.BeforeImage = $src } else { $it.Row.AfterImage = $src } }
        } catch { Show-Error $_ 'картинка строки' }
    }
    if ($script:ThumbQueue.Count -eq 0 -and $script:RowThumbQueue.Count -eq 0) { $script:ThumbTimer.Stop() }
}

function Start-Thumbs {
    if (-not $script:ThumbTimer.IsEnabled) { $script:ThumbTimer.Start() }
}

# ---- панель «Что поменяется»: по одной строке на приложение (Get-AppPlan), список виртуализуется ----
function Set-PlanItems {
    param($Items)
    try {
        $script:ui.PlanList.ItemsSource = $null
        $script:ui.PlanList.ItemsSource = $Items
    } catch {
        try { $script:ui.PlanList.SetValue([System.Windows.Controls.ItemsControl]::ItemsSourceProperty, $Items) } catch { Show-Error $_ 'список приложений' }
    }
}

function Get-PlanFilterButton {
    param([string]$Key)
    switch ($Key) { 'replace' { return $script:ui.RbReplace } 'current' { return $script:ui.RbCurrent } 'missing' { return $script:ui.RbMissing } default { return $script:ui.RbAll } }
}

# подписи фильтров со счётчиками: «Все · 120»
function Update-PlanChips {
    $c = Get-PlanCounts $script:PlanAll
    $script:ui.RbAll.Content = ($script:T.Filter_all -f $c.all)
    $script:ui.RbReplace.Content = ($script:T.Filter_replace -f $c.replace)
    $script:ui.RbCurrent.Content = ($script:T.Filter_current -f $c.current)
    $script:ui.RbMissing.Content = ($script:T.Filter_missing -f $c.missing)
}

function Update-PlanSel {
    try {
        $n = 0; $all = 0
        if ($script:PlanAll) { foreach ($r in $script:PlanAll) { $all++; if ($r.Checked) { $n++ } } }
        $shown = $(if ($script:PlanShown) { @($script:PlanShown) } else { @() })
        $allShown = ($shown.Count -gt 0 -and @($shown | Where-Object { -not $_.Checked }).Count -eq 0)
        $script:ui.ChkPlanAll.IsChecked = $allShown
        $script:ui.TxtPlanSel.Text = $(if ($n -gt 0) { $script:T.PlanSel -f $n, $all } else { $script:T.PlanSelHint })
        $script:ui.BtnUndoSel.Content = $(if ($n -gt 0) { $script:T.UndoSelFmt -f $n } else { $script:T.UndoSel })
        $script:ui.BtnUndoSel.IsEnabled = ($n -gt 0 -and -not $script:BusyNow)
    } catch { }
}

# применить фильтр и поиск: список пересобирается из строк (сами строки, галочки и картинки остаются)
function Update-PlanView {
    if ($null -eq $script:PlanAll) {          # не `-not`: пустой List в PowerShell - ложь, а пустой план - это «ничего не найдено», а не «нет плана»
        Set-PlanItems $null
        $script:PlanShown = $null
        foreach ($b in @($script:ui.RbAll, $script:ui.RbReplace, $script:ui.RbCurrent, $script:ui.RbMissing)) { Set-UiValue $b 'IsEnabled' $false }
        Update-PlanSel
        return
    }
    foreach ($b in @($script:ui.RbAll, $script:ui.RbReplace, $script:ui.RbCurrent, $script:ui.RbMissing)) { Set-UiValue $b 'IsEnabled' $true }
    Update-PlanChips
    $q = ([string]$script:ui.TxtPlanSearch.Text)
    $sel = @(Select-PlanRows $script:PlanAll $script:PlanFilter $q)
    $list = [System.Collections.Generic.List[GlyphixGui.PlanRow]]::new()
    foreach ($r in $sel) { $list.Add($r) }
    $oc = New-Object 'System.Collections.ObjectModel.ObservableCollection[GlyphixGui.PlanRow]' -ArgumentList (, $list)
    $script:PlanShown = $oc
    Set-PlanItems $oc
    $script:ui.TxtPlanEmpty.Text = $script:T.PlanFilterEmpty
    $script:ui.TxtPlanEmpty.Visibility = $(if ($oc.Count -eq 0 -and $script:PlanAll.Count -gt 0) { 'Visible' } else { 'Collapsed' })
    Update-PlanSel
}

function Set-PlanSummary {
    param($Pk)
    $s = ''
    if ($null -ne $script:PlanAll) {
        $c = Get-PlanCounts $script:PlanAll
        $s = ($script:T.PlanSummary -f $c.all, $c.replace, $c.current)
        if ($c.all -eq 0) { $s = $script:T.NoneFound }
    }
    if (-not [bool]$script:ui.ChkAllUsers.IsChecked) { $s += "`n" + $script:T.AdminNote }
    if ($Pk -and $Pk.State -eq 'none') { $s += "`n" + $script:T.NotReadyNote }
    $script:ui.TxtMatchSummary.Text = $s
}

# плитки Start11 включены: Start11 найден и галочка стоит
function Get-TilesWanted { return [bool]($script:HasStart11 -and [bool]$script:ui.ChkTiles.IsChecked) }
function Get-AutoWanted { return [bool]$script:ui.ChkAuto.IsChecked }

function Get-BasePack {
    param([string]$VariantId)
    if (-not $script:Catalog -or -not $script:Catalog.ById.ContainsKey($VariantId)) { return $null }
    $b = [string]$script:Catalog.ById[$VariantId].Base
    return (@($script:Packs | Where-Object { [string]$_.Id -eq $b }) | Select-Object -First 1)
}

function Select-Variant {
    param([string]$Id)
    if (-not $Id) { return }
    $script:SelectedId = $Id
    Update-CardHighlight
    if ($script:Job -or $script:BgPending) { $script:PendingSelect = $Id; return }
    if (-not $script:Catalog -or -not $script:Catalog.ById.ContainsKey($Id)) { return }
    $pk = Get-BasePack $Id
    $ready = [bool]($pk -and $pk.State -ne 'none')       # пак ещё не скачан: список приложений из pack.json, без отрисовки превью (она нужна иконкам пака)
    $script:ui.TxtSelectedPack.Text = ($script:T.StyleLine -f (Format-VariantLabel $script:Catalog $Id))
    $script:PlanAll = $null
    $script:RowIndex = @{}
    Update-PlanView
    $script:ui.TxtMatchSummary.Text = $script:T.Scanning
    Stop-RowThumbs
    $script:OvRecent = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($w in @($script:PendingWrites.ToArray())) { if ($w.Kind -eq 'override') { $script:OvRecent.Add($w) } }      # ещё не записаны (идёт тихое обновление) - задание их не увидит
    Start-Bg -Title $script:T.Scanning -Params @{ Id = $Id; All = [bool]$script:ui.ChkAllUsers.IsChecked; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked; Auto = (Get-AutoWanted); Render = $ready } -Body @'
param($p)
$o = @{ AllUsers = [bool]$p.All; Tiles = [bool]$p.Tiles; NoName = [bool]$p.NoName; Auto = [bool]$p.Auto; Render = [bool]$p.Render; Sync = $false }
[pscustomobject]@{ Id = [string]$p.Id; Plan = @(Get-AppPlan -VariantId ([string]$p.Id) -Options $o) }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'сканирование ярлыков'; $script:ui.TxtMatchSummary.Text = ''; return }
        if ([string]$res.Id -ne [string]$script:SelectedId) { return }        # пока шло сканирование, выбрали другой стиль - его план запустится следом
        Fill-Plan @($res.Plan) ([string]$res.Id)
        Set-Status $script:T.Ready
        Start-Warmup
    }
}

# строки плана из записей Get-AppPlan; картинки «станет» (PNG, уже нарисован) - в очередь превью, «было» и автоиконки - фоновым заданием
function Fill-Plan {
    param($Plan, [string]$VariantId)
    $rows = [System.Collections.Generic.List[GlyphixGui.PlanRow]]::new()
    $script:RowIndex = @{}
    $script:RowThumbQueue.Clear()
    foreach ($e in @($Plan)) {
        try {
            $d = ConvertTo-PlanRowData $e $script:Catalog $script:T
            $r = New-PlanRowVm $d
            $rows.Add($r)
            $script:RowIndex[[string]$d.AppKey] = $r
            if ($d.After) { $script:RowThumbQueue.Enqueue(@{ Row = $r; Kind = 'after'; Path = [string]$d.After }) }
        } catch { Show-Error $_ 'строка плана' }
    }
    # режимы, выбранные, пока шло сканирование (или ещё не записанные в state.json), - поверх прочитанного заданием
    foreach ($op in @($(if ($null -ne $script:OvRecent) { $script:OvRecent.ToArray() } else { @() }))) {
        try {
            if (-not $script:RowIndex.ContainsKey([string]$op.Key)) { continue }
            $r = $script:RowIndex[[string]$op.Key]
            if ($op.ContainsKey('Icon')) { $r.IconMode = [string]$op.Icon }
            if ($op.ContainsKey('Tile')) { $r.TileMode = [string]$op.Tile }
            if ($op.ContainsKey('Source')) { $r.Source = [string]$op.Source }
            Update-PlanRowState $r $script:Catalog $script:T
        } catch { Show-Error $_ 'режим строки' }
    }
    $script:PlanAll = $rows
    $script:PlanFilter = 'all'
    $script:ui.RbAll.IsChecked = $true
    Update-PlanView
    Set-PlanSummary (Get-BasePack $VariantId)
    Start-Thumbs
    Start-RowThumbs @($Plan) $VariantId
}

# «было» (иконка исходного ярлыка / плитки через оболочку, 96 px в кэш cache\before) и превью автоиконок (приложений нет в паке) - отдельное задание со своим runspace
function Stop-RowThumbs {
    $j = $script:PrevJob
    if ($j) {
        try { $j.Ctl['Stop'] = $true } catch { }
        $script:PrevOld = @($script:PrevOld) + @($j)
        $script:PrevJob = $null
    }
}

function Start-RowThumbs {
    param($Plan, [string]$VariantId)
    Stop-RowThumbs
    if ($script:Closing -or -not $VariantId) { return }
    $items = @(@($Plan) | Where-Object { $_ -and ((@($_.Shortcuts).Count -gt 0) -or (@($_.Tiles).Count -gt 0)) })
    if ($items.Count -eq 0) { return }
    $out = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $ctl = @{ Stop = $false }
    try {
        $j = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Params @{ Id = $VariantId; Items = $items; Out = $out; Ctl = $ctl; NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
[void](Initialize-AutoNative)
$bk = @{}
try { $bk = Load-Backup } catch { }
$dir = Join-Path $script:SI_Home 'cache\before'
$vp = $null; $auto = $null
try { $vp = Resolve-VariantPack -VariantId ([string]$p.Id) -Parts @() -NoSync; $auto = Get-PackAuto $vp } catch { }
foreach ($e in @($p.Items)) {
    if ($p.Ctl['Stop']) { break }
    $key = [string]$e.AppKey
    try {
        $sh = @($e.Shortcuts) | Select-Object -First 1
        $ti = @($e.Tiles) | Select-Object -First 1
        $srcs = @()
        if ($sh) { $srcs = @(Get-AutoLinkSources $sh $bk) } elseif ($ti) { $srcs = @(Get-AutoTileSources $ti) }
        if ($srcs.Count -gt 0) {
            $img = Get-AutoSourceImage $srcs
            if ($img) {
                $f = Join-Path $dir ((([string]$img.Hash) -replace '[^0-9A-Za-z]', '_') + '.png')
                if (-not (Test-Path -LiteralPath $f -PathType Leaf)) {
                    $px = $img.Pixels; $w = [int]$img.W; $h = [int]$img.H
                    if ($w -eq $h -and $w -gt 96) { $px = [GlyphixAuto.AutoStyle]::Resize($px, $w, $h, 96, 96); $w = 96; $h = 96 }
                    Save-FileAtomic $f ([GlyphixAuto.AutoStyle]::EncodePng($px, $w, $h))
                }
                $p.Out.Enqueue($key + '|before|' + $f)
            }
        }
        if ($e.Auto -and -not $e.AfterReady -and $auto -and $vp) {
            $item = if ($sh) { $sh } else { $ti }
            if ($item) {
                [void](New-AutoFiles $item $auto ([string]$vp.Id) $bk ([bool]$p.NoName) $vp)
                $pp = Get-AutoPaths ([string]$vp.Id) ([string]$item.SafeKey)
                $png = if ($item.PSObject.Properties['TileId']) { [string]$pp.Tile } else { [string]$pp.Png }
                $p.Out.Enqueue($key + '|after|' + $png)
            }
        }
    } catch { Write-Log ('  картинки ' + $key + ': ' + $_.Exception.Message) }
}
'@
        $j.Out = $out; $j.Ctl = $ctl
        $script:PrevJob = $j
        $script:PrevTimer.Start()
    } catch { $script:PrevJob = $null; Write-Log ('Картинки «было» не запущены: ' + $_.Exception.Message) }
}

function Set-RowThumb {
    param([string]$Line)
    $p = $Line.Split([char[]]'|', 3)
    if ($p.Count -lt 3) { return }
    if (-not $script:RowIndex.ContainsKey($p[0])) { return }
    $script:RowThumbQueue.Enqueue(@{ Row = $script:RowIndex[$p[0]]; Kind = $p[1]; Path = $p[2] })
    Start-Thumbs
}

function Step-Previews {
    $j = $script:PrevJob
    $line = $null
    if ($j) {
        while ($j.Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
        while ($j.Out.TryDequeue([ref]$line)) { Set-RowThumb $line }
        if ($j.Async.IsCompleted) {
            while ($j.Out.TryDequeue([ref]$line)) { Set-RowThumb $line }
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

# компиляция C# движка (перекраска, автоиконки) при первом запуске занимает секунды: прогреваем в фоне один раз, чтобы «Применить» не ждало
function Start-Warmup {
    if ($script:WarmDone -or $script:WarmJob -or $script:Closing) { return }
    $script:WarmDone = $true
    try {
        $script:WarmJob = Start-EngineJob -EngineText $script:EngineText -CodeDir $script:Root -Params @{} -Body @'
param($p)
try { [void](Initialize-VariantsNative) } catch { Write-Log ('Прогрев перекраски: ' + $_.Exception.Message) }
try { [void](Initialize-AutoNative) } catch { Write-Log ('Прогрев автоиконок: ' + $_.Exception.Message) }
try { [void](Remove-StaleTempFiles) } catch { }
'@
        $script:WarmTimer.Start()
    } catch { $script:WarmJob = $null }
}

function Step-Warmup {
    $j = $script:WarmJob
    if (-not $j) { $script:WarmTimer.Stop(); return }
    $line = $null
    while ($j.Queue.TryDequeue([ref]$line)) { Add-LogLine $line }
    if (-not $j.Async.IsCompleted) { return }
    $script:WarmTimer.Stop()
    try { [void](Receive-EngineJob $j) } catch { }
    $script:WarmJob = $null
}

# ---- режимы и стиль приложения ----
# клик по кнопке строки: список ловит ButtonBase.Click всплывшим событием (в DataTemplate обработчиков нет); Tag кнопки: chk | icon | tile | style
function Invoke-PlanClick {
    param($E)
    $src = $E.OriginalSource
    if ($src -isnot [System.Windows.Controls.Primitives.ButtonBase]) { return }
    $row = $src.DataContext
    if ($row -isnot [GlyphixGui.PlanRow]) { return }
    switch ([string]$src.Tag) {
        'chk' { Update-PlanSel }
        'icon' { Show-ModeMenu $src $row 'icon' }
        'tile' { Show-ModeMenu $src $row 'tile' }
        'style' { Show-StyleMenu $src $row }
    }
}

function Open-Choice {
    param($Target)
    $script:ui.PopChoice.PlacementTarget = $Target
    $script:ui.PopChoice.IsOpen = $true
}

function New-ChoiceText {
    param([string]$Text, [string]$Brush = 'MutedBrush')
    $t = New-Text $Text 11 $Brush 'SemiBold'
    $t.Margin = New-Object System.Windows.Thickness(2, 6, 0, 4)
    return $t
}

function Show-ModeMenu {
    param($Btn, $Row, [string]$Kind)
    $script:ChoiceRow = $Row
    $script:ChoiceKind = $Kind
    $cur = $(if ($Kind -eq 'icon') { [string]$Row.IconMode } else { [string]$Row.TileMode })
    $panel = $script:ui.PopChoiceItems
    $panel.Children.Clear()
    [void]$panel.Children.Add((New-ChoiceText ($(if ($Kind -eq 'icon') { $script:T.ModeIconHead } else { $script:T.ModeTileHead }) -f $Row.Name)))
    foreach ($m in @('apply', 'skip', 'restore')) {
        $b = New-Object System.Windows.Controls.Button
        $b.Style = (Get-Res 'MiniButton')
        $b.Height = 32
        $b.Margin = New-Object System.Windows.Thickness(0, 0, 0, 4)
        $b.HorizontalAlignment = 'Stretch'
        $b.Tag = $m
        $label = (Get-ModeText $m $script:T)
        $b.Content = $(if ($m -eq $cur) { '✓ ' + $label } else { '    ' + $label })
        $b.ToolTip = $script:T['ModeTip_' + $m]
        if ($m -eq $cur) { $b.BorderBrush = (Get-Res 'AccentBrush') }
        $b.Add_Click({ param($s, $e) try { $script:ui.PopChoice.IsOpen = $false; Set-RowMode $script:ChoiceRow $script:ChoiceKind ([string]$s.Tag) } catch { Show-Error $_ 'режим приложения' } })
        [void]$panel.Children.Add($b)
    }
    Open-Choice $Btn
}

function Show-StyleMenu {
    param($Btn, $Row)
    $script:ChoiceRow = $Row
    $script:ChoiceKind = 'style'
    $panel = $script:ui.PopChoiceItems
    $panel.Children.Clear()
    [void]$panel.Children.Add((New-ChoiceText ($script:T.StyleMenuHead -f $Row.Name)))
    foreach ($g in @(New-StyleMenuModel $script:Catalog ([string]$Row.Source) $script:T.StyleMenuDefault)) {
        if ($g.Title) { [void]$panel.Children.Add((New-ChoiceText ([string]$g.Title))) }
        $wp = New-Object System.Windows.Controls.WrapPanel
        $wp.Orientation = 'Horizontal'
        foreach ($it in @($g.Items)) {
            $b = New-Object System.Windows.Controls.Button
            $b.Style = (Get-Res 'MiniButton')
            $b.Margin = New-Object System.Windows.Thickness(0, 0, 6, 6)
            $b.Tag = [string]$it.Id
            $b.Content = [string]$it.Title
            if ($it.Current) { $b.Background = (Get-Res 'AccentBrush'); $b.BorderBrush = (Get-Res 'AccentBrush') }
            $b.Add_Click({ param($s, $e) try { $script:ui.PopChoice.IsOpen = $false; Set-RowSource $script:ChoiceRow ([string]$s.Tag) } catch { Show-Error $_ 'стиль приложения' } })
            [void]$wp.Children.Add($b)
        }
        [void]$panel.Children.Add($wp)
    }
    Open-Choice $Btn
}

# режим иконки / плитки: строка обновляется сразу, запись в state.json - через Invoke-StateWrite (во время операции откладывается до её конца)
function Set-RowMode {
    param($Row, [string]$Kind, [string]$Mode)
    if (-not $Row) { return }
    if ($Kind -eq 'icon') { $Row.IconMode = $Mode } else { $Row.TileMode = $Mode }
    Update-PlanRowState $Row $script:Catalog $script:T
    $op = @{ Kind = 'override'; Key = [string]$Row.AppKey }
    if ($Kind -eq 'icon') { $op.Icon = $Mode } else { $op.Tile = $Mode }
    Invoke-StateWrite $op
    # строка, переставшая подходить под активный фильтр, уходит из списка (без пересборки: положение прокрутки не сбрасывается)
    if ($script:PlanFilter -ne 'all' -and $script:PlanShown -and [string]$Row.Status -ne $script:PlanFilter) { [void]$script:PlanShown.Remove($Row) }
    Update-PlanChips
    Update-PlanSel
    Set-Status ($script:T.ModeSet -f $Row.Name, (Get-ModeText $Mode $script:T))
}

# «Стиль» приложения: взять его иконку из другого варианта (Source); id '' - по умолчанию. Картинку «станет» дорисовывает короткое задание
function Set-RowSource {
    param($Row, [string]$Id)
    if (-not $Row) { return }
    $Row.Source = $Id
    Update-PlanRowState $Row $script:Catalog $script:T
    $key = [string]$Row.AppKey
    Invoke-StateWrite @{ Kind = 'override'; Key = $key; Source = $Id }
    Set-Status ($script:T.SourceSet -f $Row.Name, $(if ($Id) { Format-VariantLabel $script:Catalog $Id } else { $script:T.StyleDefaultShort }))
    if ($Row.IsAuto -or -not $Row.IconId) { return }
    if ($script:Job -or $script:BgPending) { $script:PendingSelect = $script:SelectedId; return }       # занято: план перечитается после операции
    $eff = $(if ($Id) { $Id } else { [string]$script:SelectedId })
    Start-Bg -Title $script:T.RenderOne -Params @{ Key = $key; Src = $eff; IconId = [string]$Row.IconId } -Body @'
param($p)
$vp = Resolve-VariantPack -VariantId ([string]$p.Src) -IconIds @([string]$p.IconId) -Parts @('png') -NoSync
$ic = @($vp.Icons | Where-Object { [string]$_.Id -eq [string]$p.IconId }) | Select-Object -First 1
$png = ''
if ($ic -and $ic.PngPath -and (Test-Path -LiteralPath ([string]$ic.PngPath) -PathType Leaf)) { $png = [string]$ic.PngPath }
[pscustomobject]@{ Key = [string]$p.Key; Png = $png }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'превью иконки'; return }
        if ($res -and $script:RowIndex.ContainsKey([string]$res.Key)) {
            $r = $script:RowIndex[[string]$res.Key]
            if ($res.Png) { $script:RowThumbQueue.Enqueue(@{ Row = $r; Kind = 'after'; Path = [string]$res.Png }); Start-Thumbs } else { $r.AfterImage = $null }
        }
        Set-Status $script:T.Ready
    }
}

# отметить / снять все видимые строки (с учётом фильтра и поиска)
function Set-PlanAllChecked {
    param([bool]$On)
    if ($script:PlanShown) { foreach ($r in @($script:PlanShown)) { Set-UiValue $r 'Checked' $On } }
    Update-PlanSel
}

# ---- действия ----
# буфер обмена: занят другим процессом (CLIPBRD_E_CANTOPEN) - несколько попыток; возвращает $true, если текст скопирован
function Copy-ToClipboard {
    param([string]$Text)
    for ($i = 0; $i -lt 4; $i++) {
        try { [System.Windows.Clipboard]::SetDataObject($Text, $true); return $true } catch { Start-Sleep -Milliseconds 60 }
    }
    return $false
}

function Get-WindowsBuildText {
    try {
        $k = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $build = [string]$k.CurrentBuild
        $name = [string]$k.ProductName
        if ($build -match '^\d+$' -and [int]$build -ge 22000) { $name = $name -replace 'Windows 10', 'Windows 11' }      # ProductName у Windows 11 в реестре остался «Windows 10»
        $ver = $(if ($k.PSObject.Properties['DisplayVersion'] -and $k.DisplayVersion) { [string]$k.DisplayVersion } elseif ($k.PSObject.Properties['ReleaseId']) { [string]$k.ReleaseId } else { '' })
        $ubr = $(if ($k.PSObject.Properties['UBR']) { '.' + [string]$k.UBR } else { '' })
        return ('{0} {1}, сборка {2}{3}' -f $name, $ver, $build, $ubr).Replace('  ', ' ')
    } catch { return [Environment]::OSVersion.VersionString }
}

# «Скопировать отчёт»: версия, сборка Windows, есть ли Start11, последние 200 строк журнала - для багрепорта
function Copy-Report {
    $applied = ''
    if ($script:AppliedId) { $applied = Format-VariantLabel $script:Catalog $script:AppliedId }
    $cat = ''
    if ($script:Catalog) { $cat = ('{0}, секций {1}, стилей {2}, обновлён {3}' -f $script:Catalog.Source, @($script:Catalog.Sections).Count, @($script:Catalog.Variants).Count, $script:Catalog.Updated) }
    $lines = @(Get-LogTail $script:SI_LogFile 200)
    $txt = Format-BugReport -Version (Get-AppVersion) -WindowsBuild (Get-WindowsBuildText) -Start11 $script:HasStart11 -Admin ([bool](Test-Admin)) -Applied $applied -LogLines $lines -Catalog $cat
    if (Copy-ToClipboard $txt) { Set-Status ($script:T.ReportDone -f $lines.Count) } else { Set-Status $script:T.ReportFail }
}

function Invoke-Apply {
    param([string]$Id)
    if (Test-LegacyMigrationIncomplete) {       # бэкап прежней версии ещё не перенесён: применять нельзя (Apply-Pack откажет и сам)
        Show-Error $script:SI_MigrationPendingMsg
        [void][System.Windows.MessageBox]::Show($script:SI_MigrationPendingMsg, 'Glyphix', 'OK', 'Warning')
        return
    }
    $script:SelectedId = $Id
    Update-CardHighlight
    Stop-RowThumbs
    $all = [bool]$script:ui.ChkAllUsers.IsChecked
    $restart = [bool]$script:ui.ChkRestart.IsChecked
    $title = Format-VariantLabel $script:Catalog $Id
    # общие ярлыки при обычных правах: один раз перезапускаем этот скрипт с UAC (режим CLI) и ждём его завершения
    $elevate = ($all -and -not (Test-Admin))
    Start-Bg -WaitSilent -Title ($script:T.Applying -f $title) -Params @{ Id = $Id; Restart = $restart; All = $all; Elevate = $elevate; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked; Auto = (Get-AutoWanted) } -Body @'
param($p)
# План применяется целиком движком (Apply-Plan): качает пак-основу, рисует нужные иконки варианта, применяет с режимами и источниками приложений (state.json), плитки Start11.
# Журнал («Рисую Glow: 12/40», «Скачиваю …») идёт в строку состояния и индикатор.
$o = @{ AllUsers = [bool]$p.All; Tiles = [bool]$p.Tiles; NoName = [bool]$p.NoName; Auto = [bool]$p.Auto; Render = $true; Sync = $true }
$er = $null
if ($p.Elevate) {
    # общие ярлыки - повышенным процессом (CLI), плитки Start11 - в реестре текущего пользователя, здесь (в CLI с UAC они выключены)
    $a = @('-Cli', '-Apply', [string]$p.Id, '-AllUsers', '-NoTiles')
    if (-not $p.Restart) { $a += '-NoRestart' }
    if (-not $p.Auto) { $a += '-NoAuto' }
    $er = Invoke-ElevatedCli -CliArgs $a
    $o.AllUsers = $false
}
$r = Apply-Plan -VariantId ([string]$p.Id) -Options $o -RestartExplorer:([bool]$p.Restart -and -not $p.Elevate)
$cl = $null
$okElev = ((-not $p.Elevate) -or ($er -and $er.Started -and -not $er.Cancelled -and [int]$er.ExitCode -eq 0))
if ($r.Failed -eq 0 -and ($r.Changed + $r.Same) -gt 0 -and $okElev) { try { $cl = Clear-UnusedCopies } catch { Write-Log ('Очистка копий: ' + $_.Exception.Message) } }       # применено без ошибок - ненужные копии других паков и старых версий удаляем (после плиток)
[pscustomobject]@{ Elevated = [bool]$p.Elevate; Elev = $er; Result = $r; Cleanup = $cl }
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'применение'; Reload-Styles; if ($script:SelectedId) { Select-Variant $script:SelectedId }; return }
        $r = $res.Result
        $s = ''
        if ($res.Elevated) {
            $code = [int]$res.Elev.ExitCode
            if ($res.Elev.Cancelled) { $s = $script:T.ElevCancel }
            elseif ($code -eq 0) { $s = $script:T.ElevDone }
            elseif ($code -eq 3) { $s = $script:T.ElevRefused }
            else { $s = ($script:T.ElevFail -f $code) }
        } else {
            $s = ($script:T.ApplyDone -f (Format-VariantLabel $script:Catalog ([string]$r.Variant)), $r.Changed, $r.Same)
            $back = [int]$r.RestoredShortcuts + [int]$r.RestoredTiles
            if ($back -gt 0) { $s += ($script:T.ApplyRestored -f $back) }
            if ($r.Failed -gt 0) { $s += ($script:T.ApplyFail -f $r.Failed) }
            $rh = ''
            try { if ($r.Icons -and $r.Icons.PSObject.Properties['Running']) { $rh = Format-RunningHint @($r.Icons.Running) } } catch { }       # приложение запущено - окно может показывать прежнюю иконку (один раз, до 3 имён)
            if ($rh) { $s += ' | ' + $rh }
        }
        if ($r -and $r.Tiles) {
            $ts = $script:T.TilesDone -f $r.Tiles.Changed, $r.Tiles.Same
            if ($r.Tiles.Failed -gt 0) { $ts += ($script:T.TilesFail -f $r.Tiles.Failed) }
            if ($r.Tiles.Hint) { $ts += '. ' + $r.Tiles.Hint }
            $s += ' | ' + $ts
        }
        if ($res.Cleanup -and [long]$res.Cleanup.Bytes -gt 0) { $s += ' | ' + ($script:T.Freed -f (Format-DownloadSize ([long]$res.Cleanup.Bytes))) }
        Set-Status $s
        Set-WindowIcon                 # иконка приложения из применённого стиля (если в нём есть 'glyphix') - сразу, без перезапуска
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
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
        Reload-Styles
        if (-not $script:SelectedId -or -not $script:Catalog.ById.ContainsKey([string]$script:SelectedId)) { $script:SelectedId = Get-InitialSelection }
        if ($script:SelectedId) { Select-Variant $script:SelectedId } else { $script:PlanAll = $null; Update-PlanView; $script:ui.TxtMatchSummary.Text = '' }
    }
}

function Invoke-Download {
    param([string]$Id)
    $base = if ($script:Catalog -and $script:Catalog.ById.ContainsKey($Id)) { [string]$script:Catalog.ById[$Id].Base } else { $Id }
    # иконки - всегда; плитки Start11 - только если включены; плитки без подписи - только если выбрано «без подписи» (остальное докачается при применении)
    Start-Bg -WaitSilent -Title $script:T.Downloading -Params @{ Id = $base; Tiles = (Get-TilesWanted); NoName = [bool]$script:ui.ChkNoName.IsChecked } -Body @'
param($p)
Install-Pack -Id ([string]$p.Id) -Parts (Get-PackParts -Tiles ([bool]$p.Tiles) -NoName ([bool]$p.NoName))
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'скачивание пака' }
        elseif ($res) { Set-Status ($script:T.DownloadDone -f $res.Downloaded) }
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

# отмеченные стили (галочки на карточках) - одним заданием по их паковым основам; уже скачанные свежие пропускаются
function Invoke-DownloadSelected {
    $ids = @(Get-BaseIdsForVariants $script:Catalog @($script:Checked.Keys))
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
            foreach ($k in @($script:Checked.Keys)) {          # скачанное и пропущенное снимаем, неудавшиеся (по основе стиля) остаются отмеченными
                $bk = if ($script:Catalog.ById.ContainsKey([string]$k)) { [string]$script:Catalog.ById[[string]$k].Base } else { '' }
                if (-not $bad.ContainsKey($bk)) { $script:Checked.Remove($k) }
            }
        }
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

# убрать с диска скачанные файлы одной (не применённой) основы
function Invoke-DeletePack {
    param([string]$Id)
    $base = if ($script:Catalog -and $script:Catalog.ById.ContainsKey($Id)) { [string]$script:Catalog.ById[$Id].Base } else { $Id }
    Start-Bg -WaitSilent -Title $script:T.Deleting -Params @{ Id = $base } -Body @'
param($p)
Remove-PackDownload -Id ([string]$p.Id)
'@ -OnDone {
        param($res)
        if ($res -and $res.Error) { Show-Error $res 'удаление пака' }
        elseif ($res -and $res.Ok) { Set-Status ($script:T.DeleteDone -f $res.Message) }
        elseif ($res) { Set-Status ($script:T.DeleteFail -f $res.Message) }
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

# «Очистить кэш»: скачанные паки, кроме применённого, остатки прежних версий, отрисованные варианты и ненужные копии иконок/плиток
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
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

function Invoke-Undo {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUndo, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Stop-RowThumbs
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
        Reload-Styles
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

# «Откатить выбранные»: вернуть родные иконки и плитки только отмеченных приложений (Undo-Apps); остальное остаётся, полный «Откатить всё» вернёт его же
function Invoke-UndoSelected {
    $keys = @()
    if ($script:PlanAll) { $keys = @($script:PlanAll | Where-Object { $_.Checked } | ForEach-Object { [string]$_.AppKey }) }
    if ($keys.Count -eq 0) { Set-Status $script:T.UndoSelNothing; return }
    Stop-RowThumbs
    Start-Bg -WaitSilent -Title ($script:T.UndoSelDoing -f $keys.Count) -Params @{ Keys = [string[]]$keys; Restart = [bool]$script:ui.ChkRestart.IsChecked } -Body @'
param($p)
Undo-Apps -AppKeys ([string[]]$p.Keys) -RestartExplorer:([bool]$p.Restart) -VariantId (Get-AppliedVariantId)
'@ -OnDone {
        param($res)
        if (-not $res) { Show-Error 'Откат не вернул результат'; return }
        if ($res.Error) { Show-Error $res 'откат выбранных'; return }
        if ($res.Nothing) { $s = $script:T.UndoSelNone }
        else { $s = ($script:T.UndoSelDone -f $res.Restored, $res.TilesRestored) }
        if ($res.Failed -gt 0) { $s += ($script:T.UndoFail -f $res.Failed) }
        if ($res.CommonPending -gt 0) { $s += ($script:T.UndoCommon -f $res.CommonPending) }
        if ($res.Hint) { $s += '. ' + $res.Hint }
        Set-Status $s
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    }
}

function Invoke-Uninstall {
    $ans = [System.Windows.MessageBox]::Show($script:Window, $script:T.ConfirmUn, $script:T.Title, [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
    if ($ans -ne [System.Windows.MessageBoxResult]::Yes) { return }
    Stop-RowThumbs
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
$script:ui.TxtPackSearchHint.Text = $script:T.SearchStyle
$script:ui.TxtPlanSearchHint.Text = $script:T.SearchApp
$script:ui.TxtMatchTitle.Text = $script:T.WillChange
$script:ui.TxtSelectedPack.Text = $script:T.NoPackSel
$script:ui.TxtMatchSummary.Text = ''
$script:ui.BtnUpdate.Content = $script:T.Update
$script:ui.BtnUndo.Content = $script:T.Undo
$script:ui.BtnOpen.Content = $script:T.Open
$script:ui.BtnUninstall.Content = $script:T.Uninstall
$script:ui.BtnClearCache.Content = $script:T.ClearCache
$script:ui.BtnCheckUpd.Content = $script:T.CheckUpd
$script:ui.BtnCheckUpd.ToolTip = $script:T.CheckUpdTip
$script:ui.BtnReport.Content = $script:T.Report
$script:ui.BtnReport.ToolTip = $script:T.ReportTip
$script:ui.BtnSelDownload.Content = $script:T.SelDownload
$script:ui.BtnSelDownload.ToolTip = $script:T.SelTip
$script:ui.BtnSelAll.Content = $script:T.SelAll
$script:ui.BtnSelNone.Content = $script:T.SelNone
$script:ui.ChkPlanAll.Content = $script:T.PlanSelAll
$script:ui.BtnUndoSel.Content = $script:T.UndoSel
$script:ui.BtnUndoSel.ToolTip = $script:T.UndoSelTip
$script:ui.TxtPlanEmpty.Text = ''
Update-SelBar
Update-PlanView
$script:ui.ChkRestart.Content = $script:T.Restart
$script:ui.ChkAllUsers.Content = $script:T.AllUsers
$script:ui.ChkAllUsers.ToolTip = $script:T.AllUsersTip
$script:ui.ChkRestart.ToolTip = $script:T.RestartTip
$script:ui.ChkTiles.Content = $script:T.Tiles
$script:ui.ChkNoName.Content = $script:T.TilesNoName
$script:ui.ChkAuto.Content = $script:T.Auto
$script:ui.ChkAuto.ToolTip = $script:T.AutoTip
$script:ui.ChkAuto.IsChecked = (Get-AutoEnabled)
$script:ui.LnkDiscord.ToolTip = $script:T.DiscordTip
# галочки плиток видны только если Start11 найден (ключ реестра есть)
$script:ui.ChkTiles.Visibility = if ($script:HasStart11) { 'Visible' } else { 'Collapsed' }
$script:ui.ChkNoName.Visibility = if ($script:HasStart11) { 'Visible' } else { 'Collapsed' }
$script:ui.ChkTiles.IsEnabled = $script:HasStart11
$script:ui.ChkNoName.IsEnabled = $script:HasStart11
$script:ui.BtnLog.Content = $script:T.LogShow
$script:ui.TxtStatus.Text = $script:T.Ready
$script:Window.Title = $script:T.Title

$logo = New-Img (Join-Path (Join-Path $script:Root 'assets') 'logo_tile.png') 96
if ($logo) { [void](Set-ImageSource $script:ui.ImgLogo $logo) }

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
$script:PrevTimer.Add_Tick({ try { Step-Previews } catch { Show-Error $_ 'картинки «было»' } })

$script:SilentTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SilentTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:SilentTimer.Add_Tick({ try { Step-SilentRefresh } catch { Write-Log ('тихое обновление паков: ' + $_.Exception.Message) } })

$script:WaitTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WaitTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$script:WaitTimer.Add_Tick({ try { Step-BgPending } catch { $script:WaitTimer.Stop(); $script:BgPending = $null; Set-Busy $false; Show-Error $_ 'ожидание обновления паков' } })

$script:UpdTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdTimer.Interval = [TimeSpan]::FromMilliseconds(250)
# раз в 30 минут, пока окно открыто, тихо спрашиваем GitHub о новой версии (только эта проверка, без скачивания; закрыл окно - ничего не работает)
$script:UpdPeriodic = New-Object System.Windows.Threading.DispatcherTimer
$script:UpdPeriodic.Interval = [TimeSpan]::FromMinutes(30)
$script:UpdPeriodic.Add_Tick({ try { if (-not $script:Closing) { Start-UpdateCheck } } catch { } })
$script:UpdPeriodic.Start()
$script:UpdTimer.Add_Tick({ try { Step-UpdateCheck } catch { } })

# построение секций (по одной за такт), подгрузка картинок (малыми порциями), возврат положения прокрутки, поиск с задержкой, подпись «Скопировано», прогрев движка
$script:BuildTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:BuildTimer.Interval = [TimeSpan]::FromMilliseconds(12)
$script:BuildTimer.Add_Tick({ try { Step-Build } catch { $script:BuildTimer.Stop(); Show-Error $_ 'построение секций' } })

$script:ThumbTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:ThumbTimer.Interval = [TimeSpan]::FromMilliseconds(20)
$script:ThumbTimer.Add_Tick({ try { Step-Thumbs } catch { Show-Error $_ 'картинки' } })

$script:RestoreTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:RestoreTimer.Interval = [TimeSpan]::FromMilliseconds(90)
$script:RestoreTimer.Add_Tick({ try { Restore-Offsets } catch { $script:RestoreTimer.Stop() } })

$script:SearchTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:SearchTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:SearchTimer.Add_Tick({ try { $script:SearchTimer.Stop(); Show-Sections } catch { Show-Error $_ 'поиск стиля' } })

$script:DiscordTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DiscordTimer.Interval = [TimeSpan]::FromMilliseconds(1600)
$script:DiscordTimer.Add_Tick({ try { $script:DiscordTimer.Stop(); $script:ui.RunDiscord.Text = $script:DiscordNick } catch { } })

$script:WarmTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:WarmTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:WarmTimer.Add_Tick({ try { Step-Warmup } catch { $script:WarmTimer.Stop() } })

$script:DiscordNick = 'f1ks_'

$script:ui.BtnUpdate.Add_Click({ try { Invoke-Update; Start-UpdateCheck } catch { Show-Error $_ 'Обновить паки' } })
$script:ui.BtnAppUpdate.Add_Click({ try { Invoke-AppUpdate } catch { Show-Error $_ 'Обновить приложение' } })
$script:ui.BtnUndo.Add_Click({ try { Invoke-Undo } catch { Show-Error $_ 'Откатить' } })
$script:ui.BtnOpen.Add_Click({
    try {
        if (-not (Test-Path -LiteralPath $script:DataHome)) { New-Item -ItemType Directory -Path $script:DataHome -Force | Out-Null }
        Start-Process -FilePath $script:DataHome
    } catch { Show-Error $_ }
})
$script:ui.ChkAllUsers.Add_Click({ try { if ($script:SelectedId) { Select-Variant $script:SelectedId } } catch { Show-Error $_ 'общие ярлыки' } })
$script:ui.ChkTiles.Add_Click({
    try {
        $script:ui.ChkNoName.IsEnabled = ($script:HasStart11 -and [bool]$script:ui.ChkTiles.IsChecked)
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    } catch { Show-Error $_ }
})
$script:ui.ChkNoName.Add_Click({ try { if ($script:SelectedId) { Select-Variant $script:SelectedId } } catch { Show-Error $_ 'плитки без подписи' } })
$script:ui.ChkAuto.Add_Click({
    try {
        Set-AutoEnabled ([bool]$script:ui.ChkAuto.IsChecked)
        if ($script:SelectedId) { Select-Variant $script:SelectedId }
    } catch { Show-Error $_ 'автоиконки' }
})
$script:ui.BtnMenu.Add_Click({ try { $script:ui.PopMenu.IsOpen = (-not $script:ui.PopMenu.IsOpen) } catch { Show-Error $_ 'меню' } })
$script:ui.BtnClearCache.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Invoke-ClearCache } catch { Show-Error $_ 'Очистить кэш' } })
$script:ui.BtnCheckUpd.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Start-UpdateCheck -Manual } catch { Show-Error $_ 'Проверить обновления' } })
$script:ui.BtnReport.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Copy-Report } catch { Show-Error $_ 'Скопировать отчёт' } })
$script:ui.BtnUninstall.Add_Click({ try { $script:ui.PopMenu.IsOpen = $false; Invoke-Uninstall } catch { Show-Error $_ 'Удалить приложение' } })
$script:ui.BtnSelDownload.Add_Click({ try { Invoke-DownloadSelected } catch { Show-Error $_ 'Скачать выбранные' } })
$script:ui.BtnSelAll.Add_Click({ try { foreach ($vid in @($script:Cards.Keys)) { Set-VariantChecked ([string]$vid) $true } } catch { Show-Error $_ 'Выбрать все' } })
$script:ui.BtnSelNone.Add_Click({ try { foreach ($vid in @($script:Checked.Keys)) { Set-VariantChecked ([string]$vid) $false } } catch { Show-Error $_ 'Снять выбор' } })
$script:ui.BtnLog.Add_Click({
    try {
        if ($script:ui.LogPanel.Visibility -eq 'Visible') { $script:ui.LogPanel.Visibility = 'Collapsed'; $script:ui.BtnLog.Content = $script:T.LogShow }
        else { $script:ui.LogPanel.Visibility = 'Visible'; $script:ui.BtnLog.Content = $script:T.LogHide }
    } catch { Show-Error $_ 'журнал' }
})

# поиск стиля (с задержкой, чтобы не перестраивать секции на каждую букву) и поиск приложения в плане
$script:ui.TxtPackSearch.Add_TextChanged({
    try {
        $script:ui.TxtPackSearchHint.Visibility = $(if ($script:ui.TxtPackSearch.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' })
        $script:SearchTimer.Stop(); $script:SearchTimer.Start()
    } catch { Show-Error $_ 'поиск стиля' }
})
$script:ui.TxtPlanSearch.Add_TextChanged({
    try {
        $script:ui.TxtPlanSearchHint.Visibility = $(if ($script:ui.TxtPlanSearch.Text.Length -eq 0) { 'Visible' } else { 'Collapsed' })
        if ($script:PlanAll) { Update-PlanView }
    } catch { Show-Error $_ 'поиск приложения' }
})
# фильтры плана; галочка «выбрать все видимые», «Откатить выбранные»
foreach ($pair in @(@('RbAll', 'all'), @('RbReplace', 'replace'), @('RbCurrent', 'current'), @('RbMissing', 'missing'))) {
    $script:ui[$pair[0]].Tag = $pair[1]
    $script:ui[$pair[0]].Add_Click({ param($s, $e) try { $script:PlanFilter = [string]$s.Tag; Update-PlanView } catch { Show-Error $_ 'фильтр плана' } })
}
$script:ui.ChkPlanAll.Add_Click({ try { Set-PlanAllChecked ([bool]$script:ui.ChkPlanAll.IsChecked) } catch { Show-Error $_ 'выбрать все' } })
$script:ui.BtnUndoSel.Add_Click({ try { Invoke-UndoSelected } catch { Show-Error $_ 'Откатить выбранные' } })
# клики по кнопкам внутри строк (шаблон строки без обработчиков): всплывшее событие Click ловит список
$script:ui.PlanList.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{ param($s, $e) try { Invoke-PlanClick $e } catch { Show-Error $_ 'строка плана' } })

$script:OnLinkNavigate = {
    param($s, $e)
    try {
        $url = $e.Uri.AbsoluteUri
        if (Test-Admin) {   # из повышенного процесса ссылки не открываем: браузер получил бы права администратора
            [void](Copy-ToClipboard $url)
            Set-Status ($script:T.LinkCopied -f $url)
        } else {
            Start-Process -FilePath $url
        }
    } catch { Show-Error $_ }
    $e.Handled = $true
}
$script:ui.LnkGitHub.Add_RequestNavigate($script:OnLinkNavigate)
$script:ui.LnkAuthor.Add_RequestNavigate($script:OnLinkNavigate)
# Discord: ссылки нет - щелчок копирует ник и на секунду пишет «Скопировано»
$script:ui.LnkDiscord.Add_Click({
    try {
        if (Copy-ToClipboard $script:DiscordNick) {
            $script:ui.RunDiscord.Text = $script:T.DiscordCopied
            Set-Status ($script:T.DiscordCopiedStatus -f $script:DiscordNick)
            $script:DiscordTimer.Stop(); $script:DiscordTimer.Start()
        } else { Set-Status $script:T.ReportFail }
    } catch { Show-Error $_ 'Discord' }
})
$script:Window.Add_Closing({
    param($s, $e)
    try {
        if ($script:Job -or $script:BgPending) { $e.Cancel = $true; Set-Status $script:T.Busy; return }
        if ($script:SilentCtl) { try { $script:SilentCtl['Cancel'] = $true } catch { } }      # закрываем окно - тихое обновление ничего нового не пишет
        $script:Closing = $true
        Stop-RowThumbs
        foreach ($tm in @($script:BuildTimer, $script:ThumbTimer, $script:SearchTimer, $script:RestoreTimer)) { try { $tm.Stop() } catch { } }
        Flush-StateWrites -Force
    } catch { Show-Error $_ 'закрытие' }
})
# последняя линия обороны: необработанное исключение в обработчике WPF - в журнал со стеком, окно остаётся открытым
$script:Window.Dispatcher.add_UnhandledException({
    param($s, $e)
    try { Write-Log ('НЕОБРАБОТАННАЯ ОШИБКА GUI: ' + $e.Exception.Message + ' | ' + ([string]$e.Exception.StackTrace -replace "`r?`n", ' <- ')); $e.Handled = $true } catch { }
})
$script:Window.Add_SourceInitialized({
    try {   # окно не больше рабочей области (1920x1080 при 125-150% DPI = 1536x864 / 1280x720 условных пикселей), по центру
        $wa = [System.Windows.SystemParameters]::WorkArea
        $script:Window.MinWidth = [Math]::Min([double]$script:Window.MinWidth, [Math]::Max(600.0, [double]$wa.Width - 16))      # MinWidth 1040 / MinHeight 640 больше рабочей области 1366x768 при 125% - окно не помещалось бы на экран
        $script:Window.MinHeight = [Math]::Min([double]$script:Window.MinHeight, [Math]::Max(480.0, [double]$wa.Height - 16))
        $w = [Math]::Min([double]$script:Window.Width, [double]$wa.Width - 16)
        $h = [Math]::Min([double]$script:Window.Height, [double]$wa.Height - 16)
        $script:Window.Width = [Math]::Max($w, 600.0)
        $script:Window.Height = [Math]::Max($h, 480.0)
        $script:Window.Left = [double]$wa.Left + ([double]$wa.Width - [double]$script:Window.Width) / 2
        $script:Window.Top = [double]$wa.Top + ([double]$wa.Height - [double]$script:Window.Height) / 2
    } catch { }
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
    Load-StyleData
    $first = Get-InitialSelection
    if ($script:Packs.Count -eq 0 -or $ForceUpdate) {
        Show-Sections
        Invoke-Update $true
    } else {
        Show-Sections
        if ($first) { Select-Variant $first }
        Start-Warmup                   # компиляцию C# движка (перекраска, автоиконки) делаем в фоне заранее, чтобы «Применить» не ждало
        Start-SilentRefresh            # кэш показан сразу, а index + variants.json + pack.json + превью обновляются в фоне при каждом запуске
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
