<#
  Прежнее имя скрипта Glyphix (бывший Shadow Icons): нужно только старым ярлыкам и командам.
  Запускает Glyphix.ps1 с теми же параметрами.
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
& (Join-Path $PSScriptRoot 'Glyphix.ps1') @PSBoundParameters
if ($null -ne $LASTEXITCODE) { exit $LASTEXITCODE }
