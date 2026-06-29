param(
    [Parameter(Mandatory=$false)]
    [string]$OriginSystem = "Blau Eur XX-M b35-5",

    [int]$RadiusLy = 50,
    [switch]$OutputFirstName,
    [int]$OutputIndex = -1,
    [switch]$OutputNames
)

$scriptStartTime = Get-Date

# --- Helper: Call EDSM API ---
function Invoke-EDSM {
    param(
        [string]$Url
    )
    try {
        return Invoke-RestMethod -Uri $Url -Method Get -ErrorAction Stop
    }
    catch {
        Write-Error "Failed to call EDSM API: $_"
    }
}

Write-Host "=== Script started ===" -ForegroundColor Magenta
Write-Host "UTC Time: $($scriptStartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White -NoNewline
Write-Host " | Local Time: $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green

Write-Host "Searching for systems near $OriginSystem within $RadiusLy ly..." -ForegroundColor Cyan

# --- 1. Get nearby systems ---
$encoded = [uri]::EscapeDataString($OriginSystem)
$nearbyUrl = "https://www.edsm.net/api-v1/sphere-systems?systemName=$encoded&radius=$RadiusLy&showPrimaryStar=1&showCoordinates=1"

$systems = Invoke-EDSM $nearbyUrl

if (-not $systems) {
    Write-Host "No systems returned." -ForegroundColor Red
    exit
}

# --- 2. Filter to unvisited systems ---
# EDSM marks unvisited systems with no visits from players
$unvisited = $systems | Where-Object {
    ($_."visits" -eq $null -or $_."visits" -eq 0)
}

# --- 3. Filter to K-class primary stars ---
$kClass = $unvisited | Where-Object {
    ($_.primaryStar.type -like "F*" -or $_.primaryStar.type -like "G*") -and ($null -eq $_.bodyCount -or [int]$_.bodyCount -gt 15)
}

# --- 4. Order by shortest travel distance (TSP) ---
# Get origin system coordinates directly from EDSM
$originEncoded = [uri]::EscapeDataString($OriginSystem)
$originUrl = "https://www.edsm.net/api-v1/system?systemName=$originEncoded&showCoordinates=1"
$originSystemData = Invoke-EDSM $originUrl

if (-not $originSystemData -or -not $originSystemData.coords) {
    Write-Host "Error: Could not retrieve coordinates for origin system '$OriginSystem'" -ForegroundColor Red
    exit
}

Write-Host "`nOrigin system: $($originSystemData.name)" -ForegroundColor Cyan

$primaryStarCoords = @{
    x = [double]$originSystemData.coords.x
    y = [double]$originSystemData.coords.y
    z = [double]$originSystemData.coords.z
}
Write-Host "Primary star coordinates: X=$($primaryStarCoords.x), Y=$($primaryStarCoords.y), Z=$($primaryStarCoords.z)" -ForegroundColor Cyan

# Calculate 3D distance function
function Get-Distance {
    param(
        [hashtable]$Point1,
        [hashtable]$Point2
    )
    $dx = [double]$Point1.x - [double]$Point2.x
    $dy = [double]$Point1.y - [double]$Point2.y
    $dz = [double]$Point1.z - [double]$Point2.z
    return [Math]::Sqrt($dx*$dx + $dy*$dy + $dz*$dz)
}

# Greedy nearest-neighbor TSP algorithm
$visited = @()
$unvisited = @($kClass)
$currentPos = @{
    x = $primaryStarCoords.x
    y = $primaryStarCoords.y
    z = $primaryStarCoords.z
}
$totalDistance = 0

while ($unvisited.Count -gt 0) {
    $nearest = $null
    $nearestDist = [double]::MaxValue
    $nearestIndex = -1
    
    for ($i = 0; $i -lt $unvisited.Count; $i++) {
        $starCoords = @{
            x = $unvisited[$i].coords.x
            y = $unvisited[$i].coords.y
            z = $unvisited[$i].coords.z
        }
        $dist = Get-Distance $currentPos $starCoords
        
        if ($dist -lt $nearestDist) {
            $nearestDist = $dist
            $nearest = $unvisited[$i]
            $nearestIndex = $i
        }
    }
    
    $totalDistance += $nearestDist
    
    # Add leg distance to the star object
    $nearest | Add-Member -NotePropertyName LegDistance -NotePropertyValue $nearestDist -Force
    $visited += $nearest
    
    # Remove visited star from unvisited list
    $newUnvisited = @()
    for ($j = 0; $j -lt $unvisited.Count; $j++) {
        if ($j -ne $nearestIndex) {
            $newUnvisited += $unvisited[$j]
        }
    }
    $unvisited = $newUnvisited
    
    $currentPos = @{
        x = $nearest.coords.x
        y = $nearest.coords.y
        z = $nearest.coords.z
    }
}

# Add return distance to primary star
$returnDistance = Get-Distance $currentPos $primaryStarCoords
$totalDistance += $returnDistance

# --- 5. Output results ---
if ($OutputFirstName) {
    if ($visited.Count -gt 0) {
        Write-Output $visited[0].name
    }
    else {
        Write-Host "No systems found." -ForegroundColor Red
    }
}
elseif ($OutputIndex -ge 0) {
    if ($visited.Count -gt $OutputIndex) {
        Write-Output $visited[$OutputIndex].name
    }
    else {
        Write-Host "No system at index $OutputIndex." -ForegroundColor Yellow
    }
}
elseif ($OutputNames) {
    # Output a JSON array of system names for programmatic consumption
    $names = $visited | Select-Object -ExpandProperty name
    $names | ConvertTo-Json | Write-Output
}
else {
    Write-Host "`nFound $($visited.Count) unvisited K-class systems (ordered by shortest travel distance):`n" -ForegroundColor Green
    Write-Host "Total travel distance: $([Math]::Round($totalDistance, 2)) ly`n" -ForegroundColor Yellow

    $visited | Select-Object `
        @{Name="Order";Expression={$visited.IndexOf($_) + 1}},
        name,
        @{Name="LegDistanceLy";Expression={[Math]::Round($_.LegDistance, 2)}},
        @{Name="StarType";Expression={$_.primaryStar.type}},
        @{Name="Stars";Expression={$_.starCount ?? 1}},
        @{Name="Planets";Expression={$_.bodyCount}},
        @{Name="NoDiscovery";Expression={($_.bodyCount | Where-Object {-not $_.discovery}).Count}},
        @{Name="DistanceLy";Expression={$_.distance}},
        @{Name="X";Expression={$_.coords.x}},
        @{Name="Y";Expression={$_.coords.y}},
        @{Name="Z";Expression={$_.coords.z}} |
        Format-Table -AutoSize

    Write-Host "Return distance to primary star: $([Math]::Round($returnDistance, 2)) ly" -ForegroundColor Cyan
}

$scriptEndTime = Get-Date
$scriptDuration = $scriptEndTime - $scriptStartTime

Write-Host "`n=== Script completed ===" -ForegroundColor Magenta
Write-Host "UTC Time: $($scriptEndTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor White -NoNewline
Write-Host " | Local Time: $($scriptEndTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor Green
Write-Host "Execution time: $([Math]::Round($scriptDuration.TotalSeconds, 2)) seconds" -ForegroundColor Cyan

    #$systems