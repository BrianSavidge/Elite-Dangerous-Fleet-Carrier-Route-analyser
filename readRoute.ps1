# read the newest file staring "Journal." and ending in ".log" in the "C:\Users\a_sna\Saved Games\Frontier Developments\Elite Dangerous" folder

# search the file for a row with the newest timestamp for an event called "event":"CarrierLocation"

# for that row read the column starting with  "StarSystem":"  and display that value

# put the value into the clipboard

# wait 1 minute and repeat all the steps

$logPath = "C:\Users\a_sna\Saved Games\Frontier Developments\Elite Dangerous"
$previousNextStarSystem = $null
$lastCheckedTimestamp = $null
$eventTypesToMonitor = @("CarrierJumpRequest")

while ($true) {
    # Get the newest Journal.*.log file
    $logFile = Get-ChildItem -Path $logPath -Filter "Journal.*.log" | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
    
    if ($logFile) {
        # Read the file line by line and parse as JSON
        $lines = Get-Content -Path $logFile.FullName
        
        # Find all CarrierLocation events and get the most recent one
        $carrierLocationEvent = $null
        foreach ($line in $lines) {
            try {
                $jsonObject = $line | ConvertFrom-Json
                if ($jsonObject.event -eq "CarrierLocation") {
                    $carrierLocationEvent = $jsonObject
                }
            }
            catch {
                # Skip lines that can't be parsed as JSON
                continue
            }
        }
        
        if ($carrierLocationEvent -and $carrierLocationEvent.StarSystem) {
            $starSystem = $carrierLocationEvent.StarSystem
            
            # Read the route.json file in the same folder as this script
            $routeJsonPath = Join-Path (Split-Path -Parent $PSCommandPath) "route.json"
            
            if (Test-Path $routeJsonPath) {
                $routeData = Get-Content -Path $routeJsonPath -Raw | ConvertFrom-Json
                
                # Find the current star system in the result.jumps array
                $jumps = $routeData.result.jumps
                $currentIndex = -1
                
                for ($i = 0; $i -lt $jumps.Count; $i++) {
                    if ($jumps[$i].name -eq $starSystem) {
                        $currentIndex = $i
                        break
                    }
                }
                
                # Get the next star system if it exists
                if ($currentIndex -ge 0 -and $currentIndex -lt ($jumps.Count - 1)) {
                    $nextStarSystem = $jumps[$currentIndex + 1].name
                    
                    # Only output if the next star system has changed or if it's the first run
                    if ($nextStarSystem -ne $previousNextStarSystem) {
                        Write-Host "Current Star System: $starSystem"
                        Write-Host "Next Star System: $nextStarSystem" -ForegroundColor Green
                        $jumps[$currentIndex + 1] | Format-List | Out-String -Stream | Where-Object { $_ -ne '' } | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
                        
                        # Put the next star system into the clipboard
                        Write-Host "Putting next star system into clipboard: $nextStarSystem"
                        $nextStarSystem | Set-Clipboard
                        
                        $previousNextStarSystem = $nextStarSystem

                        # Get nearby unvisited K-class systems
                        Write-Host "`nSearching for nearby unvisited K-class systems..." -ForegroundColor Cyan
                        $scriptPath = Join-Path (Split-Path -Parent $PSCommandPath) "getUnvisitedSystems.ps1"
                        if (Test-Path $scriptPath) {
                            & $scriptPath -OriginSystem $starSystem -RadiusLy 50
                        }
                        else {
                            Write-Host "getUnvisitedSystems.ps1 not found" -ForegroundColor Red
                        }
                    }
                }
                else {
                    Write-Host "No next system found in route"
                    $starSystem | Set-Clipboard
                }
            }
            else {
                Write-Host "route.json not found"
                $starSystem | Set-Clipboard
            }
        }
        
        # Check for monitored events since last check
        foreach ($line in $lines) {
            try {
                $jsonObject = $line | ConvertFrom-Json
                
                # Check if this is one of the events we're monitoring
                if ($eventTypesToMonitor -contains $jsonObject.event) {
                    $eventTimestamp = [datetime]::Parse($jsonObject.timestamp)
                    
                    # Only process if this event is newer than the last checked timestamp
                    if ($null -eq $lastCheckedTimestamp -or $eventTimestamp -gt $lastCheckedTimestamp) {
                        Write-Host "Event: $($jsonObject.event)" -ForegroundColor Green
                        $jsonObject | Format-List | Out-String -Stream | Where-Object { $_ -ne '' } | ForEach-Object { Write-Host $_ -ForegroundColor Green }
                        
                        # If DepartureTime exists, display it with UTC and local time
                        if ($jsonObject.DepartureTime) {
                            try {
                                # Parse as UTC and convert to local time
                                $departureTimeUtc = [datetime]::ParseExact($jsonObject.DepartureTime, 'dd/MM/yyyy HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal)
                                $departureTimeLocal = $departureTimeUtc.ToLocalTime()
                                
                                Write-Host "`nDeparture Time:" -ForegroundColor Yellow
                                Write-Host "  UTC: $($departureTimeUtc.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White -NoNewline
                                Write-Host " | Local: $($departureTimeLocal.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
                            }
                            catch {
                                # Skip if timestamp parsing fails
                            }
                        }
                   
                        # Update the last checked timestamp
                        $lastCheckedTimestamp = $eventTimestamp
                    }
                }
            }
            catch {
                # Skip lines that can't be parsed as JSON
                continue
            }
        }
    }
    
    # Wait 1 minute before repeating
    Start-Sleep -Seconds 60
}
