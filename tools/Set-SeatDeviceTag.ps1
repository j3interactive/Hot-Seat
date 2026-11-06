#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Identity.DirectoryManagement
<#
.SYNOPSIS
    Stamps each Metro desk PC's Entra device object with its seat ID.

.DESCRIPTION
    Device -> seat lives on the device (docs/automation.md), not in this repo
    and not in the device name, so a PC can be renamed or moved without
    touching the app. This script reads a CSV of SeatId,ComputerName (exported
    from the Metro Seat -> Computer Map workbook; never commit it), finds each
    computer in Entra ID by display name and writes the seat ID to an
    extension attribute (extensionAttribute1 by default).

    Safe by default:
      - Run with -WhatIf first; it reports every change without making it.
      - Seat IDs are checked against data/floor-layout.json.
      - A computer that matches more than one Entra device is skipped.
      - A device whose attribute already holds something that is not a seat
        ID is skipped unless -Force, so an attribute used for something else
        is never overwritten.
      - -ClearUnlisted clears the seat ID from devices that carry one but are
        no longer in the CSV (a PC that left the floor).

    Writes a results CSV next to the input for review.

.PARAMETER CsvPath
    CSV with columns SeatId, ComputerName.

.PARAMETER Attribute
    Which extensionAttribute (1-15) to use. Default 1. Use the same one in
    every run and in the app's device lookup.

.EXAMPLE
    ./tools/Set-SeatDeviceTag.ps1 -CsvPath ~/seat-computers.csv -WhatIf
    ./tools/Set-SeatDeviceTag.ps1 -CsvPath ~/seat-computers.csv

.NOTES
    Needs Device.ReadWrite.All (delegated: Cloud Device Administrator or
    Intune Administrator). Primary tenant fte.emovisops.com.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $CsvPath,
    [ValidateRange(1, 15)] [int] $Attribute = 1,
    [string] $LayoutPath = (Join-Path $PSScriptRoot '..' 'data' 'floor-layout.json'),
    [string] $TenantId = 'fte.emovisops.com',
    [switch] $ClearUnlisted,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$attrName = "extensionAttribute$Attribute"
$seatPattern = '^[A-Z]{1,2}\d{1,3}$'

# Seat IDs from the layout, so a typo in the CSV can't tag a PC with a seat that doesn't exist
$layout = Get-Content $LayoutPath -Raw | ConvertFrom-Json
$validSeats = [System.Collections.Generic.HashSet[string]]::new()
foreach ($area in $layout.areas) {
    foreach ($pod in $area.pods) {
        if ($pod.cells) { $pod.cells | ForEach-Object { [void]$validSeats.Add($_[0]) } }
        else { $pod.rows | ForEach-Object { $_ | Where-Object { $_ } | ForEach-Object { [void]$validSeats.Add($_) } } }
    }
}

$rows = Import-Csv $CsvPath | ForEach-Object {
    [pscustomobject]@{ SeatId = "$($_.SeatId)".Trim().ToUpper(); ComputerName = "$($_.ComputerName)".Trim() }
} | Where-Object { $_.ComputerName -and $_.ComputerName -ne 'NONE' }

$problems = @()
$problems += $rows | Where-Object { -not $validSeats.Contains($_.SeatId) } | ForEach-Object { "Unknown seat $($_.SeatId)" }
$problems += $rows | Group-Object ComputerName | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) is on seats $($_.Group.SeatId -join ', ')" }
$problems += $rows | Group-Object SeatId | Where-Object Count -gt 1 | ForEach-Object { "Seat $($_.Name) has more than one computer" }
if ($problems) { throw "Fix the CSV first:`n  $($problems -join "`n  ")" }

Write-Host "$($rows.Count) seat/computer pairs, writing $attrName" -ForegroundColor Cyan

if (-not (Get-MgContext)) { Connect-MgGraph -TenantId $TenantId -Scopes 'Device.ReadWrite.All' -NoWelcome }

# One pull of all devices with their extension attributes; cheaper than one filter call per PC
$devices = Get-MgDevice -All -Property 'id,deviceId,displayName,accountEnabled,approximateLastSignInDateTime,extensionAttributes'
$byName = $devices | Group-Object { $_.DisplayName.ToUpper() } -AsHashTable -AsString

function Get-Attr($device) { if ($device.ExtensionAttributes) { $device.ExtensionAttributes.$attrName } }

function Set-Attr($device, $value) {
    Update-MgDevice -DeviceId $device.Id -BodyParameter @{ extensionAttributes = @{ $attrName = $value } }
}

$results = @(foreach ($row in $rows) {
    $match = @($byName[$row.ComputerName.ToUpper()])
    $match = @($match | Where-Object { $_ })
    $r = [ordered]@{ SeatId = $row.SeatId; ComputerName = $row.ComputerName; Result = ''; Previous = '' }

    if ($match.Count -eq 0) { $r.Result = 'NotFound' }
    elseif ($match.Count -gt 1) { $r.Result = "Ambiguous ($($match.Count) Entra devices; remove stale ones)" }
    else {
        $dev = $match[0]
        $current = Get-Attr $dev
        $r.Previous = $current
        if ($current -eq $row.SeatId) { $r.Result = 'AlreadySet' }
        elseif ($current -and $current -notmatch $seatPattern -and -not $Force) { $r.Result = "Skipped: $attrName holds '$current' (use -Force)" }
        elseif ($PSCmdlet.ShouldProcess("$($row.ComputerName)", "$attrName = $($row.SeatId)")) {
            Set-Attr $dev $row.SeatId
            $r.Result = if ($current) { 'Moved' } else { 'Set' }
        } else { $r.Result = 'WouldSet' }
    }
    [pscustomobject]$r
})

if ($ClearUnlisted) {
    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]($rows.ComputerName.ToUpper()))
    foreach ($dev in $devices) {
        $current = Get-Attr $dev
        if ($current -match $seatPattern -and -not $listed.Contains($dev.DisplayName.ToUpper())) {
            $res = 'WouldClear'
            if ($PSCmdlet.ShouldProcess($dev.DisplayName, "clear $attrName (was $current)")) { Set-Attr $dev $null; $res = 'Cleared' }
            $results += [pscustomobject]@{ SeatId = ''; ComputerName = $dev.DisplayName; Result = $res; Previous = $current }
        }
    }
}

$out = [IO.Path]::ChangeExtension($CsvPath, $null).TrimEnd('.') + "-results-$(Get-Date -Format yyyyMMdd-HHmm).csv"
$results | Export-Csv $out -NoTypeInformation -WhatIf:$false
$results | Group-Object { ($_.Result -split '[ :(]')[0] } | Sort-Object Name |
    ForEach-Object { '{0,-12} {1}' -f $_.Name, $_.Count } | Write-Host
Write-Host "Details: $out" -ForegroundColor Cyan
