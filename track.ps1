param(
    [string]$JournalLog = "",
    [string]$JournalFolder = "C:\Users\a_sna\Saved Games\Frontier Developments\Elite Dangerous"
)

if ([string]::IsNullOrEmpty($JournalLog)) {
    $latestLog = Get-ChildItem -Path $JournalFolder -Filter 'Journal.*.log' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestLog) {
        # Fallback to script directory
        $latestLog = Get-ChildItem -Path $PSScriptRoot -Filter '*.log' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }
    if ($null -eq $latestLog) {
        Write-Host "No .log files found." -ForegroundColor Red
        exit 1
    }
    $JournalLog = $latestLog.FullName
    Write-Host "Using most recent log: $JournalLog" -ForegroundColor Cyan
}

$ErrorActionPreference = 'Stop'

# --- Load route.json jumps into memory ---
Write-Host "Loading route from route.json..." -ForegroundColor Cyan
$routeJson = Get-Content (Join-Path $PSScriptRoot "route.json") -Raw | ConvertFrom-Json
$script:RouteJumps = $routeJson.result.jumps
Write-Host "Loaded $($script:RouteJumps.Count) jumps from route.json." -ForegroundColor Green

# --- State variables ---
$script:CarrierSystem  = $null
$script:CurrentSystem  = $null
$script:OldSystem      = $null
$script:VisitedSystems = @()

# --- Most recent event of each tracked type ---
$script:LatestEvents = @{
    CarrierLocation = $null
    Undocked        = $null
    FSDJump         = $null
}

function Invoke-EventAction {
    param([psobject]$Event)

    switch ($Event.event) {
        'CarrierLocation' {
            $script:CarrierSystem = $Event.StarSystem
            $script:OldSystem     = $Event.StarSystem
            Write-Host "  [CarrierLocation $($Event.timestamp)] CarrierSystem='$($script:CarrierSystem)'  OldSystem='$($script:OldSystem)'" -ForegroundColor Yellow
        }
        'Undocked' {
            $script:CurrentSystem = $script:CarrierSystem
            $script:OldSystem     = $script:CarrierSystem
            Write-Host "  [Undocked $($Event.timestamp)] CurrentSystem='$($script:CurrentSystem)'  OldSystem='$($script:OldSystem)'" -ForegroundColor Yellow

            if (-not [string]::IsNullOrEmpty($script:CurrentSystem)) {
                Write-Host "  Running getUnvisitedSystems.ps1 for '$($script:CurrentSystem)'..." -ForegroundColor Cyan
                $rawOutput = & (Join-Path $PSScriptRoot "getUnvisitedSystems.ps1") -OriginSystem $script:CurrentSystem -OutputNames
                if ($rawOutput) {
                    $script:VisitedSystems = ($rawOutput -join "`n") | ConvertFrom-Json
                    Write-Host "  Stored $($script:VisitedSystems.Count) unvisited systems in memory." -ForegroundColor Green
                    if ($script:VisitedSystems.Count -gt 0) {
                        $firstSystem = $script:VisitedSystems[0]
                        Set-Clipboard -Value $firstSystem
                        Write-Host "  First system '$firstSystem' copied to clipboard." -ForegroundColor Green
                    }
                }
                else {
                    Write-Host "  No unvisited systems returned." -ForegroundColor Red
                }
            }
            else {
                Write-Host "  CarrierSystem not yet known; skipping getUnvisitedSystems." -ForegroundColor DarkYellow
            }
        }
        'FSDJump' {
            $script:OldSystem     = $Event.StarSystem
            $script:CurrentSystem = $Event.Body
            Write-Host "  [FSDJump $($Event.timestamp)] OldSystem='$($script:OldSystem)'  CurrentSystem='$($script:CurrentSystem)'" -ForegroundColor Yellow

            if ($script:VisitedSystems.Count -gt 0) {
                # Find CurrentSystem in the visited list (match on StarSystem name portion before " A"/body suffix)
                $currentSystemName = $script:CurrentSystem -replace '\s+[A-Z\d]+$', ''
                $matchIndex = -1
                for ($i = 0; $i -lt $script:VisitedSystems.Count; $i++) {
                    if ($script:VisitedSystems[$i] -eq $script:CurrentSystem -or
                        $script:VisitedSystems[$i] -eq $currentSystemName) {
                        $matchIndex = $i
                        break
                    }
                }

                if ($matchIndex -ge 0 -and $matchIndex + 1 -lt $script:VisitedSystems.Count) {
                    $nextSystem = $script:VisitedSystems[$matchIndex + 1]
                    Set-Clipboard -Value $nextSystem
                    Write-Host "  Next system '$nextSystem' (index $($matchIndex + 1)) copied to clipboard." -ForegroundColor Green
                }
                else {
                    # End of list or not found — put carrier back in clipboard
                    $clipValue = if (-not [string]::IsNullOrEmpty($script:CarrierSystem)) { $script:CarrierSystem } else { '' }
                    Set-Clipboard -Value $clipValue
                    if ($matchIndex -ge 0) {
                        Write-Host "  End of unvisited list reached. CarrierSystem '$clipValue' copied to clipboard." -ForegroundColor Cyan
                    }
                    else {
                        Write-Host "  '$($script:CurrentSystem)' not found in unvisited list. CarrierSystem '$clipValue' copied to clipboard." -ForegroundColor DarkYellow
                    }
                }
            }
        }
    }
}

function Invoke-StoredEventProcessing {
    $toProcess = @()
    foreach ($key in 'CarrierLocation', 'Undocked', 'FSDJump') {
        if ($null -ne $script:LatestEvents[$key]) {
            $toProcess += $script:LatestEvents[$key]
        }
    }
    $toProcess = @($toProcess | Sort-Object { [datetime]$_.timestamp })

    Write-Host "--- Processing $($toProcess.Count) stored event(s) oldest-first ---" -ForegroundColor Magenta
    foreach ($evt in $toProcess) {
        Invoke-EventAction -Event $evt
    }
}

# --- Step 1: Scan existing log for most recent of each event type ---
Write-Host "`nScanning '$JournalLog' for initial state..." -ForegroundColor Cyan
foreach ($line in (Get-Content $JournalLog -Encoding UTF8)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
        $entry = $line | ConvertFrom-Json
        if ($entry.event -in 'CarrierLocation', 'Undocked', 'FSDJump') {
            $script:LatestEvents[$entry.event] = $entry
        }
    }
    catch { }
}

Write-Host "Most recent events found in log:" -ForegroundColor Cyan
Write-Host ("  CarrierLocation : " + $(if ($script:LatestEvents.CarrierLocation) { $script:LatestEvents.CarrierLocation.timestamp } else { 'none' }))
Write-Host ("  Undocked        : " + $(if ($script:LatestEvents.Undocked)        { $script:LatestEvents.Undocked.timestamp }        else { 'none' }))
Write-Host ("  FSDJump         : " + $(if ($script:LatestEvents.FSDJump)         { $script:LatestEvents.FSDJump.timestamp }         else { 'none' }))

Invoke-StoredEventProcessing

Write-Host "`nInitial state:" -ForegroundColor Cyan
Write-Host "  CarrierSystem : $script:CarrierSystem"
Write-Host "  CurrentSystem : $script:CurrentSystem"
Write-Host "  OldSystem     : $script:OldSystem"

# --- Step 2: Monitor log for new events using a StreamReader ---
Write-Host "`nMonitoring log for new events (Ctrl+C to stop)..." -ForegroundColor Cyan

$fileStream = [System.IO.FileStream]::new(
    $JournalLog,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::ReadWrite
)
$reader = [System.IO.StreamReader]::new($fileStream, [System.Text.Encoding]::UTF8)
# Seek to end so only new entries are processed
[void]$reader.BaseStream.Seek(0, [System.IO.SeekOrigin]::End)

try {
    while ($true) {
        $line = $reader.ReadLine()
        if ($null -ne $line) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try {
                $entry = $line | ConvertFrom-Json
                if ($entry.event -in 'CarrierLocation', 'Undocked', 'FSDJump') {
                    Write-Host "`nNew event: $($entry.event) at $($entry.timestamp)" -ForegroundColor Cyan
                    $script:LatestEvents[$entry.event] = $entry
                    Invoke-StoredEventProcessing
                    Write-Host "State: CarrierSystem='$script:CarrierSystem'  CurrentSystem='$script:CurrentSystem'  OldSystem='$script:OldSystem'" -ForegroundColor White
                }
            }
            catch { }
        }
        else {
            Start-Sleep -Milliseconds 500
        }
    }
}
finally {
    $reader.Dispose()
    $fileStream.Dispose()
}
