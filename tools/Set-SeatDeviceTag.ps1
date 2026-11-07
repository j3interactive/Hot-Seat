#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Tags each Metro desk PC with its seat in Entra ID and Intune.

.DESCRIPTION
    Device -> seat lives on the device (docs/automation.md, decision 0004),
    not in this repo and not in the device name, so a PC can be renamed or
    moved without touching the app. This script reads a CSV of
    SeatId,ComputerName (exported from the Metro Seat -> Computer Map
    workbook; never commit it) and, for each PC, writes:

      1. Entra device  extensionAttribute1 = A1
         For dynamic device groups and the Hot-Seat device signal.
      2. Intune notes  a line "[Seat] A1 · Main Floor · Pod A1–A14"
         Shown on the device's Overview page. Only the [Seat] line is managed;
         anything else in the notes is kept.
      3. Intune device category  "Metro - Main Floor" (one per area)
         A column in the Intune device list; usable in assignment filters.
         Missing categories are created.

    The Entra device is found by display name; the Intune device by its
    Entra device ID, so a rename between the two can't mismatch them.

    Safe by default:
      - Run with -WhatIf first; it reports every change without making it.
      - Seat IDs are checked against data/floor-layout.json.
      - A name that matches more than one Entra device is skipped.
      - An extension attribute holding something that isn't a seat ID, or a
        device category that isn't a Metro one, is left alone unless -Force.
      - -ClearUnlisted untags PCs that carry a seat but are no longer in the
        CSV (attribute, [Seat] note line and Metro category).

    Writes a results CSV next to the input for review.

.PARAMETER CsvPath
    CSV with columns SeatId, ComputerName.

.PARAMETER Attribute
    Which extensionAttribute (1-15) to use. Default 1. Use the same one in
    every run and in the app's device lookup.

.PARAMETER CategoryPrefix
    Prefix for the per-area Intune device categories. Default "Metro - ".

.PARAMETER EntraOnly
    Only set the Entra attribute; skip Intune notes and category.

.EXAMPLE
    ./tools/Set-SeatDeviceTag.ps1 -CsvPath ~/seat-computers.csv -WhatIf
    ./tools/Set-SeatDeviceTag.ps1 -CsvPath ~/seat-computers.csv

.NOTES
    Graph scopes: Device.ReadWrite.All (Entra attribute) and
    DeviceManagementManagedDevices.ReadWrite.All (Intune notes and
    categories). Notes and category assignment use the Graph beta endpoint.
    Delegated roles: Cloud Device Administrator + Intune Administrator.
    Primary tenant fte.emovisops.com.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)] [string] $CsvPath,
    [ValidateRange(1, 15)] [int] $Attribute = 1,
    [string] $CategoryPrefix = 'Metro - ',
    [string] $LayoutPath = (Join-Path $PSScriptRoot '..' 'data' 'floor-layout.json'),
    [string] $TenantId = 'fte.emovisops.com',
    [switch] $EntraOnly,
    [switch] $ClearUnlisted,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
$attrName = "extensionAttribute$Attribute"
$seatPattern = '^[A-Z]{1,2}\d{1,3}$'
$noteTag = '[Seat]'
$G = 'https://graph.microsoft.com'

# ---- seats from the layout: id -> area + pod, so a typo can't tag a PC with a seat that doesn't exist
$layout = Get-Content $LayoutPath -Raw | ConvertFrom-Json
$seatInfo = @{}
foreach ($area in $layout.areas) {
    foreach ($pod in $area.pods) {
        $ids = if ($pod.cells) { $pod.cells | ForEach-Object { $_[0] } } else { $pod.rows | ForEach-Object { $_ } | Where-Object { $_ } }
        foreach ($id in $ids) { $seatInfo[$id] = [pscustomobject]@{ Area = $area.name; Pod = $pod.label } }
    }
}

$rows = Import-Csv $CsvPath | ForEach-Object {
    [pscustomobject]@{ SeatId = "$($_.SeatId)".Trim().ToUpper(); ComputerName = "$($_.ComputerName)".Trim() }
} | Where-Object { $_.ComputerName -and $_.ComputerName -ne 'NONE' }

$problems = @()
$problems += $rows | Where-Object { -not $seatInfo.ContainsKey($_.SeatId) } | ForEach-Object { "Unknown seat $($_.SeatId)" }
$problems += $rows | Group-Object ComputerName | Where-Object Count -gt 1 | ForEach-Object { "$($_.Name) is on seats $($_.Group.SeatId -join ', ')" }
$problems += $rows | Group-Object SeatId | Where-Object Count -gt 1 | ForEach-Object { "Seat $($_.Name) has more than one computer" }
if ($problems) { throw "Fix the CSV first:`n  $($problems -join "`n  ")" }

Write-Host "$($rows.Count) seat/computer pairs -> $attrName$(if (-not $EntraOnly) { ', Intune notes, Intune category' })" -ForegroundColor Cyan

# ---- Graph helpers
if (-not (Get-MgContext)) {
    $scopes = @('Device.ReadWrite.All'); if (-not $EntraOnly) { $scopes += 'DeviceManagementManagedDevices.ReadWrite.All' }
    Connect-MgGraph -TenantId $TenantId -Scopes $scopes -NoWelcome
}
function Invoke-Graph($Method, $Uri, $Body) {
    $p = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 5 -Compress); $p.ContentType = 'application/json' }
    Invoke-MgGraphRequest @p
}
function Get-GraphAll($Uri) {
    $out = [System.Collections.Generic.List[object]]::new()
    while ($Uri) { $r = Invoke-Graph GET $Uri; if ($r.value) { $out.AddRange([object[]]@($r.value)) }; $Uri = $r.'@odata.nextLink' }
    , $out.ToArray()
}

# ---- one pull of each list; cheaper than one lookup per PC
$devices = Get-GraphAll "$G/v1.0/devices?`$select=id,deviceId,displayName,extensionAttributes&`$top=999"
$byName = @{}; foreach ($d in $devices) { $k = "$($d.displayName)".ToUpper(); if (-not $byName[$k]) { $byName[$k] = @() }; $byName[$k] += $d }
function Get-Attr($d) { if ($d.extensionAttributes) { $d.extensionAttributes.$attrName } }
function Set-Attr($d, $value) { Invoke-Graph PATCH "$G/v1.0/devices/$($d.id)" @{ extensionAttributes = @{ $attrName = $value } } | Out-Null }

if (-not $EntraOnly) {
    $managed = Get-GraphAll "$G/beta/deviceManagement/managedDevices?`$select=id,deviceName,azureADDeviceId,deviceCategoryDisplayName&`$filter=operatingSystem eq 'Windows'"
    $byAadId = @{}; foreach ($m in $managed) { $k = "$($m.azureADDeviceId)".ToLower(); if (-not $byAadId[$k]) { $byAadId[$k] = @() }; $byAadId[$k] += $m }

    $categories = @{}; foreach ($c in (Get-GraphAll "$G/beta/deviceManagement/deviceCategories")) { $categories[$c.displayName] = $c.id }
    function Get-CategoryId($name) {
        if ($categories.ContainsKey($name)) { return $categories[$name] }
        if (-not $PSCmdlet.ShouldProcess($name, 'create Intune device category')) { return 'whatif' }
        $c = Invoke-Graph POST "$G/beta/deviceManagement/deviceCategories" @{ displayName = $name; description = 'Metro floor area. Set by Hot-Seat tools/Set-SeatDeviceTag.ps1.' }
        $categories[$name] = $c.id; $c.id
    }
    function Get-Notes($m) { "$((Invoke-Graph GET "$G/beta/deviceManagement/managedDevices/$($m.id)?`$select=id,notes").notes)" }
    # Replace only our [Seat] line; keep the rest of the notes as written by the helpdesk
    function Merge-Notes($notes, $seatLine) {
        $keep = @($notes -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith($noteTag) })
        (@($seatLine | Where-Object { $_ }) + $keep) -join "`n"
    }
    function Set-Notes($m, $notes) { Invoke-Graph PATCH "$G/beta/deviceManagement/managedDevices/$($m.id)" @{ notes = $notes } | Out-Null }
    function Set-Category($m, $catId) {
        if ($catId) { Invoke-Graph PUT "$G/beta/deviceManagement/managedDevices/$($m.id)/deviceCategory/`$ref" @{ '@odata.id' = "$G/beta/deviceManagement/deviceCategories/$catId" } | Out-Null }
        else { Invoke-Graph DELETE "$G/beta/deviceManagement/managedDevices/$($m.id)/deviceCategory/`$ref" | Out-Null }
    }
    function Test-OurCategory($name) { -not $name -or $name -eq 'Unknown' -or $name.StartsWith($CategoryPrefix) }
}

# ---- tag
$results = @(foreach ($row in $rows) {
    $info = $seatInfo[$row.SeatId]
    $r = [ordered]@{ SeatId = $row.SeatId; ComputerName = $row.ComputerName; Entra = ''; IntuneNotes = ''; IntuneCategory = ''; PreviousSeat = '' }
    $match = @($byName[$row.ComputerName.ToUpper()] | Where-Object { $_ })

    if ($match.Count -eq 0) { $r.Entra = 'NotFound' }
    elseif ($match.Count -gt 1) { $r.Entra = "Ambiguous ($($match.Count) Entra devices; remove stale ones)" }
    else {
        $dev = $match[0]
        $current = Get-Attr $dev
        $r.PreviousSeat = $current
        if ($current -eq $row.SeatId) { $r.Entra = 'AlreadySet' }
        elseif ($current -and $current -notmatch $seatPattern -and -not $Force) { $r.Entra = "Skipped: $attrName holds '$current' (use -Force)" }
        elseif ($PSCmdlet.ShouldProcess($row.ComputerName, "$attrName = $($row.SeatId)")) { Set-Attr $dev $row.SeatId; $r.Entra = if ($current) { 'Moved' } else { 'Set' } }
        else { $r.Entra = 'WouldSet' }

        if (-not $EntraOnly) {
            $md = @($byAadId["$($dev.deviceId)".ToLower()] | Where-Object { $_ })
            if ($md.Count -eq 0) { $r.IntuneNotes = $r.IntuneCategory = 'NotEnrolled' }
            elseif ($md.Count -gt 1) { $r.IntuneNotes = $r.IntuneCategory = "Ambiguous ($($md.Count) Intune records)" }
            else {
                $m = $md[0]
                $line = "$noteTag $($row.SeatId) · $($info.Area) · Pod $($info.Pod)"
                $notes = Get-Notes $m
                $new = Merge-Notes $notes $line
                if ($new -eq $notes) { $r.IntuneNotes = 'AlreadySet' }
                elseif ($PSCmdlet.ShouldProcess($row.ComputerName, "Intune notes: $line")) { Set-Notes $m $new; $r.IntuneNotes = 'Set' }
                else { $r.IntuneNotes = 'WouldSet' }

                $want = "$CategoryPrefix$($info.Area)"
                $have = "$($m.deviceCategoryDisplayName)"
                if ($have -eq $want) { $r.IntuneCategory = 'AlreadySet' }
                elseif (-not (Test-OurCategory $have) -and -not $Force) { $r.IntuneCategory = "Skipped: category is '$have' (use -Force)" }
                else {
                    $catId = Get-CategoryId $want
                    if ($catId -ne 'whatif' -and $PSCmdlet.ShouldProcess($row.ComputerName, "Intune category = $want")) { Set-Category $m $catId; $r.IntuneCategory = 'Set' }
                    else { $r.IntuneCategory = 'WouldSet' }
                }
            }
        }
    }
    [pscustomobject]$r
})

# ---- untag PCs that left the floor
if ($ClearUnlisted) {
    $listed = [System.Collections.Generic.HashSet[string]]::new([string[]]@($rows.ComputerName | ForEach-Object { $_.ToUpper() }))
    $handled = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($dev in $devices) {
        $current = Get-Attr $dev
        if ($current -notmatch $seatPattern -or $listed.Contains("$($dev.displayName)".ToUpper())) { continue }
        $r = [ordered]@{ SeatId = ''; ComputerName = $dev.displayName; Entra = 'WouldClear'; IntuneNotes = ''; IntuneCategory = ''; PreviousSeat = $current }
        if ($PSCmdlet.ShouldProcess($dev.displayName, "clear $attrName (was $current)")) { Set-Attr $dev $null; $r.Entra = 'Cleared' }
        if (-not $EntraOnly) {
            foreach ($m in @($byAadId["$($dev.deviceId)".ToLower()] | Where-Object { $_ })) {
                [void]$handled.Add($m.id)
                $notes = Get-Notes $m; $new = Merge-Notes $notes $null
                if ($new -ne $notes) {
                    $r.IntuneNotes = 'WouldClear'
                    if ($PSCmdlet.ShouldProcess($dev.displayName, 'remove [Seat] line from Intune notes')) { Set-Notes $m $new; $r.IntuneNotes = 'Cleared' }
                }
                if ("$($m.deviceCategoryDisplayName)".StartsWith($CategoryPrefix)) {
                    $r.IntuneCategory = 'WouldClear'
                    if ($PSCmdlet.ShouldProcess($dev.displayName, "remove category $($m.deviceCategoryDisplayName)")) { Set-Category $m $null; $r.IntuneCategory = 'Cleared' }
                }
            }
        }
        $results += [pscustomobject]$r
    }
    # Intune devices still in a Metro category but no longer on any seat
    if (-not $EntraOnly) {
        $listedAad = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($row in $rows) { foreach ($d in @($byName[$row.ComputerName.ToUpper()] | Where-Object { $_ })) { [void]$listedAad.Add("$($d.deviceId)".ToLower()) } }
        foreach ($m in $managed) {
            if ($handled.Contains($m.id) -or $listedAad.Contains("$($m.azureADDeviceId)".ToLower())) { continue }
            if (-not "$($m.deviceCategoryDisplayName)".StartsWith($CategoryPrefix)) { continue }
            $r = [ordered]@{ SeatId = ''; ComputerName = $m.deviceName; Entra = ''; IntuneNotes = ''; IntuneCategory = 'WouldClear'; PreviousSeat = '' }
            if ($PSCmdlet.ShouldProcess($m.deviceName, "remove category $($m.deviceCategoryDisplayName)")) { Set-Category $m $null; $r.IntuneCategory = 'Cleared' }
            $results += [pscustomobject]$r
        }
    }
}

# ---- report
$out = [IO.Path]::ChangeExtension($CsvPath, $null).TrimEnd('.') + "-results-$(Get-Date -Format yyyyMMdd-HHmm).csv"
$results | Export-Csv $out -NoTypeInformation -WhatIf:$false
foreach ($col in @('Entra') + $(if (-not $EntraOnly) { 'IntuneNotes', 'IntuneCategory' })) {
    Write-Host "$col" -ForegroundColor Cyan
    $results | Where-Object { $_.$col } | Group-Object { ($_.$col -split '[ :(]')[0] } | Sort-Object Name |
        ForEach-Object { '  {0,-12} {1}' -f $_.Name, $_.Count } | Write-Host
}
Write-Host "Details: $out" -ForegroundColor Cyan
