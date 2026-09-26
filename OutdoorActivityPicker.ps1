<#
.SYNOPSIS
    Recommends a random outdoor activity that matches your preferences and current weather.
.DESCRIPTION
    Windows PowerShell 5.1+ command-line app. Weather and geocoding are provided by Open-Meteo.
    Your profile is stored locally in %LOCALAPPDATA%\OutdoorActivityPicker\profile.json.
    Height and weight are optional, stored only in that local profile, and are not used to
    assess fitness or determine recommendations.
.PARAMETER Setup
    Create or replace your personal profile.
.PARAMETER Location
    Use a location for this run instead of the location saved in your profile.
.EXAMPLE
    .\OutdoorActivityPicker.ps1 -Setup
.EXAMPLE
    .\OutdoorActivityPicker.ps1
.EXAMPLE
    .\OutdoorActivityPicker.ps1 -Location "Seattle"
.NOTES
    Open-Meteo conditions are model-based, not emergency alerts. Check local forecasts and
    official warnings before heading out. Requires an internet connection for weather data.
#>
[CmdletBinding()]
param(
    [switch]$Setup,
    [string]$Location
)

$ErrorActionPreference = 'Stop'
$script:ProfileDirectory = Join-Path $env:LOCALAPPDATA 'OutdoorActivityPicker'
$script:ProfilePath = Join-Path $script:ProfileDirectory 'profile.json'

function Read-NonEmptyText {
    param([string]$Prompt)
    do { $answer = (Read-Host $Prompt).Trim() } while ([string]::IsNullOrWhiteSpace($answer))
    return $answer
}

function Read-OptionalNumber {
    param([string]$Prompt, [double]$Minimum, [double]$Maximum)
    while ($true) {
        $raw = (Read-Host $Prompt).Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        $number = 0.0
        $valid = [double]::TryParse($raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::CurrentCulture, [ref]$number)
        if (-not $valid) {
            $valid = [double]::TryParse($raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$number)
        }
        if ($valid -and $number -ge $Minimum -and $number -le $Maximum) { return $number }
        Write-Host "Enter a number from $Minimum to $Maximum, or leave blank to skip." -ForegroundColor Yellow
    }
}

function Read-CategoryList {
    param([string]$Prompt, [string[]]$AllowedCategories)
    Write-Host ("Available: " + ($AllowedCategories -join ', ')) -ForegroundColor DarkGray
    $raw = (Read-Host $Prompt).Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $chosen = @()
    foreach ($item in ($raw -split ',')) {
        $value = $item.Trim().ToLowerInvariant()
        if ($AllowedCategories -contains $value -and $chosen -notcontains $value) { $chosen += $value }
    }
    return $chosen
}

function Save-Profile {
    param([object]$UserSettings)
    if (-not (Test-Path -LiteralPath $script:ProfileDirectory)) {
        New-Item -ItemType Directory -Path $script:ProfileDirectory -Force | Out-Null
    }
    $temporaryPath = $script:ProfilePath + '.tmp'
    $json = $UserSettings | ConvertTo-Json -Depth 5
    Set-Content -LiteralPath $temporaryPath -Value $json -Encoding UTF8
    Move-Item -LiteralPath $temporaryPath -Destination $script:ProfilePath -Force
}

function New-InteractiveProfile {
    $categories = @('walking', 'cycling', 'nature', 'water', 'sports', 'gardening', 'photography')
    Write-Host ''
    Write-Host 'Set up your activity profile' -ForegroundColor Cyan
    Write-Host 'Your height and weight are optional. They are saved locally and do not affect recommendations.' -ForegroundColor DarkGray
    $homeLocation = Read-NonEmptyText 'Your city, town, or postal code'
    $preferred = Read-CategoryList 'Favorite categories (comma-separated, optional)' $categories
    $avoid = Read-CategoryList 'Categories to avoid (comma-separated, optional)' $categories
    while ($true) {
        $minutesRaw = Read-Host 'How many minutes do you have? (15-360, default 60)'
        if ([string]::IsNullOrWhiteSpace($minutesRaw)) { $minutes = 60; break }
        $minutes = 0
        if ([int]::TryParse($minutesRaw, [ref]$minutes) -and $minutes -ge 15 -and $minutes -le 360) { break }
        Write-Host 'Enter a whole number from 15 to 360.' -ForegroundColor Yellow
    }
    Write-Host 'Choose your usual preferred effort: 1) Easy  2) Moderate  3) Challenging' -ForegroundColor DarkGray
    do { $effortChoice = (Read-Host 'Enter 1, 2, or 3').Trim() } while ($effortChoice -notin @('1', '2', '3'))
    $effort = @{ '1' = 'easy'; '2' = 'moderate'; '3' = 'challenging' }[$effortChoice]
    $height = Read-OptionalNumber 'Height in cm (optional; Enter to skip)' 80 250
    $weight = Read-OptionalNumber 'Weight in kg (optional; Enter to skip)' 20 350

    $userSettings = [pscustomobject]@{
        Version = 1
        Location = $homeLocation
        PreferredCategories = @($preferred)
        AvoidCategories = @($avoid)
        AvailableMinutes = $minutes
        PreferredEffort = $effort
        HeightCm = $height
        WeightKg = $weight
    }
    Save-Profile $userSettings
    Write-Host "Profile saved locally: $script:ProfilePath" -ForegroundColor Green
    return $userSettings
}

function Get-Profile {
    if ($Setup -or -not (Test-Path -LiteralPath $script:ProfilePath)) {
        return New-InteractiveProfile
    }
    try {
        $userSettings = Get-Content -LiteralPath $script:ProfilePath -Raw | ConvertFrom-Json
        if ($userSettings.Version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$userSettings.Location)) {
            throw 'The profile format is incomplete.'
        }
        return $userSettings
    }
    catch {
        Write-Host "Could not read the saved profile ($($_.Exception.Message)). Run with -Setup to recreate it." -ForegroundColor Red
        throw
    }
}

function Get-LocationMatch {
    param([string]$Query)
    $encoded = [Uri]::EscapeDataString($Query.Trim())
    $uri = "https://geocoding-api.open-meteo.com/v1/search?name=$encoded`&count=5`&language=en`&format=json"
    $response = Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
    if (-not $response.results -or $response.results.Count -eq 0) {
        throw "No matching location found for '$Query'. Try a nearby city or postal code."
    }
    $results = @($response.results)
    if ($results.Count -eq 1) { return $results[0] }
    Write-Host "`nMatching locations for '$Query':" -ForegroundColor Cyan
    for ($i = 0; $i -lt $results.Count; $i++) {
        $parts = @($results[$i].name, $results[$i].admin1, $results[$i].country) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        Write-Host ("  {0}) {1}" -f ($i + 1), ($parts -join ', '))
    }
    while ($true) {
        $selection = 0
        if ([int]::TryParse((Read-Host 'Choose a number'), [ref]$selection) -and $selection -ge 1 -and $selection -le $results.Count) {
            return $results[$selection - 1]
        }
        Write-Host 'Choose one of the listed numbers.' -ForegroundColor Yellow
    }
}

function Get-Weather {
    param([double]$Latitude, [double]$Longitude)
    $lat = $Latitude.ToString('0.#####', [Globalization.CultureInfo]::InvariantCulture)
    $lon = $Longitude.ToString('0.#####', [Globalization.CultureInfo]::InvariantCulture)
    $uri = "https://api.open-meteo.com/v1/forecast?latitude=$lat`&longitude=$lon`&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_gusts_10m`&hourly=precipitation_probability,temperature_2m`&forecast_hours=6`&timezone=auto`&wind_speed_unit=kmh"
    return Invoke-RestMethod -Uri $uri -Method Get -TimeoutSec 20
}

function Get-WeatherDescription {
    param([int]$Code)
    switch ($Code) {
        { $_ -in 0 } { return 'clear sky' }
        { $_ -in 1, 2 } { return 'mostly clear or partly cloudy' }
        3 { return 'overcast' }
        { $_ -in 45, 48 } { return 'foggy' }
        { $_ -in 51, 53, 55 } { return 'drizzle' }
        { $_ -in 56, 57 } { return 'freezing drizzle' }
        { $_ -in 61, 63, 65 } { return 'rain' }
        { $_ -in 66, 67 } { return 'freezing rain' }
        71 { return 'light snow' }
        { $_ -in 73, 75, 77, 85, 86 } { return 'snow or snow showers' }
        { $_ -in 80, 81, 82 } { return 'rain showers' }
        { $_ -in 95, 96, 99 } { return 'thunderstorm' }
        default { return 'changing conditions' }
    }
}

function Get-ActivityCatalog {
    return @(
        [pscustomobject]@{ Name='Scenic neighborhood walk'; Category='walking'; Effort='easy'; MinMinutes=15; MaxMinutes=180; MaxWind=55; MaxRainChance=85; MinTemp=-5; MaxTemp=38; Base=5; Tip='Pick a route with an easy turn-back point.' }
        [pscustomobject]@{ Name='Park or forest trail walk'; Category='nature'; Effort='moderate'; MinMinutes=30; MaxMinutes=240; MaxWind=45; MaxRainChance=65; MinTemp=0; MaxTemp=34; Base=6; Tip='Choose a marked trail and tell someone your route.' }
        [pscustomobject]@{ Name='Birdwatching walk'; Category='nature'; Effort='easy'; MinMinutes=20; MaxMinutes=180; MaxWind=40; MaxRainChance=65; MinTemp=-2; MaxTemp=35; Base=5; Tip='Bring binoculars if you have them and keep a respectful distance.' }
        [pscustomobject]@{ Name='Outdoor photography walk'; Category='photography'; Effort='easy'; MinMinutes=20; MaxMinutes=180; MaxWind=45; MaxRainChance=70; MinTemp=-2; MaxTemp=36; Base=5; Tip='Pick a nearby subject and try a short photo theme.' }
        [pscustomobject]@{ Name='Easy bike ride on a protected route'; Category='cycling'; Effort='moderate'; MinMinutes=25; MaxMinutes=150; MaxWind=32; MaxRainChance=35; MinTemp=5; MaxTemp=32; Base=5; Tip='Use a helmet, lights when needed, and a route separated from traffic.' }
        [pscustomobject]@{ Name='Leisurely bike ride'; Category='cycling'; Effort='easy'; MinMinutes=20; MaxMinutes=120; MaxWind=28; MaxRainChance=25; MinTemp=8; MaxTemp=30; Base=4; Tip='Check your bike and stay on a familiar, low-traffic route.' }
        [pscustomobject]@{ Name='Outdoor bodyweight mobility session'; Category='sports'; Effort='moderate'; MinMinutes=15; MaxMinutes=60; MaxWind=35; MaxRainChance=45; MinTemp=5; MaxTemp=32; Base=5; Tip='Keep movements comfortable and use a stable, dry surface.' }
        [pscustomobject]@{ Name='Casual ball game or catch'; Category='sports'; Effort='moderate'; MinMinutes=20; MaxMinutes=120; MaxWind=30; MaxRainChance=30; MinTemp=8; MaxTemp=32; Base=4; Tip='Choose an open space away from roads and fragile areas.' }
        [pscustomobject]@{ Name='Garden or balcony plant care'; Category='gardening'; Effort='easy'; MinMinutes=15; MaxMinutes=120; MaxWind=45; MaxRainChance=85; MinTemp=2; MaxTemp=36; Base=5; Tip='Water plants only if they need it; take breaks in shade on hot days.' }
        [pscustomobject]@{ Name='Nature sketching or journaling'; Category='nature'; Effort='easy'; MinMinutes=20; MaxMinutes=120; MaxWind=30; MaxRainChance=40; MinTemp=5; MaxTemp=32; Base=4; Tip='Bring a small notebook and settle somewhere safe and comfortable.' }
        [pscustomobject]@{ Name='Outdoor picnic'; Category='walking'; Effort='easy'; MinMinutes=30; MaxMinutes=180; MaxWind=25; MaxRainChance=25; MinTemp=12; MaxTemp=32; Base=3; Tip='Pack water, take litter with you, and use shade when it is sunny.' }
        [pscustomobject]@{ Name='Easy shoreline stroll'; Category='water'; Effort='easy'; MinMinutes=20; MaxMinutes=150; MaxWind=28; MaxRainChance=35; MinTemp=8; MaxTemp=32; Base=4; Tip='Stay well back from surf, tides, unstable banks, and restricted areas.' }
        [pscustomobject]@{ Name='Outdoor yoga or stretching'; Category='sports'; Effort='easy'; MinMinutes=15; MaxMinutes=60; MaxWind=25; MaxRainChance=30; MinTemp=10; MaxTemp=31; Base=4; Tip='Use a level surface and keep the session gentle if you are unsure.' }
        [pscustomobject]@{ Name='Short local nature scavenger hunt'; Category='nature'; Effort='easy'; MinMinutes=20; MaxMinutes=90; MaxWind=40; MaxRainChance=60; MinTemp=2; MaxTemp=34; Base=4; Tip='Look for colors, leaf shapes, or birds without disturbing wildlife.' }
        [pscustomobject]@{ Name='Easy jog or brisk walk'; Category='walking'; Effort='challenging'; MinMinutes=20; MaxMinutes=90; MaxWind=25; MaxRainChance=25; MinTemp=5; MaxTemp=27; Base=3; Tip='Choose a familiar route and adjust pace to how you feel.' }
    )
}

function Get-RecommendedActivity {
    param([object]$UserSettings, [object]$Weather)
    $current = $Weather.current
    $code = [int]$current.weather_code
    $temperature = [double]$current.apparent_temperature
    $windGust = [double]$current.wind_gusts_10m
    $precipChance = 0.0
    if ($Weather.hourly.precipitation_probability) {
        $hoursToCheck = [Math]::Max(1, [Math]::Min(6, [Math]::Ceiling([double]$UserSettings.AvailableMinutes / 60.0)))
        $nextProbabilities = @($Weather.hourly.precipitation_probability | Select-Object -First $hoursToCheck)
        if ($nextProbabilities.Count -gt 0) { $precipChance = [double](($nextProbabilities | Measure-Object -Maximum).Maximum) }
    }

    if ($code -in @(95, 96, 99, 56, 57, 66, 67, 71, 73, 75, 77, 85, 86)) {
        return [pscustomobject]@{ Activity=$null; Reason='The current conditions include a thunderstorm, freezing precipitation, or snow. No outdoor activity is recommended by this app right now.'; PrecipChance=$precipChance }
    }
    if ($windGust -ge 70) {
        return [pscustomobject]@{ Activity=$null; Reason='Strong wind gusts are forecast. Wait for conditions to improve before choosing an outdoor activity.'; PrecipChance=$precipChance }
    }
    if ($temperature -ge 39 -or $temperature -le -10) {
        return [pscustomobject]@{ Activity=$null; Reason='The feels-like temperature is outside the recommended activity range. Consider postponing and check local advice.'; PrecipChance=$precipChance }
    }

    $activities = Get-ActivityCatalog
    $candidates = @()
    foreach ($activity in $activities) {
        if ($activity.MinMinutes -gt [int]$UserSettings.AvailableMinutes -or $activity.MaxMinutes -lt [int]$UserSettings.AvailableMinutes) { continue }
        if (@($UserSettings.AvoidCategories) -contains $activity.Category) { continue }
        if ($temperature -lt $activity.MinTemp -or $temperature -gt $activity.MaxTemp) { continue }
        if ($windGust -gt $activity.MaxWind -or $precipChance -gt $activity.MaxRainChance) { continue }
        if ($code -in @(45, 48) -and $activity.Category -in @('cycling', 'water')) { continue }
        if ($precipChance -ge 60 -and $activity.Category -in @('cycling', 'sports', 'water')) { continue }

        $score = [double]$activity.Base
        if (@($UserSettings.PreferredCategories) -contains $activity.Category) { $score += 5 }
        if ($activity.Effort -eq [string]$UserSettings.PreferredEffort) { $score += 3 }
        elseif (($UserSettings.PreferredEffort -eq 'easy' -and $activity.Effort -eq 'moderate') -or ($UserSettings.PreferredEffort -eq 'challenging' -and $activity.Effort -eq 'moderate')) { $score += 1 }
        $durationDifference = [Math]::Abs(([double]$activity.MinMinutes + [double]$activity.MaxMinutes) / 2 - [double]$UserSettings.AvailableMinutes)
        $score -= [Math]::Min(2, $durationDifference / 120)
        $candidates += [pscustomobject]@{ Activity=$activity; Score=$score }
    }
    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Activity=$null; Reason='No activity in your profile fits both the current weather and available time. Try a different time, duration, or location.'; PrecipChance=$precipChance }
    }

    $ranked = @($candidates | Sort-Object -Property Score -Descending)
    $topCount = [Math]::Min(4, $ranked.Count)
    $picked = Get-Random -InputObject @($ranked | Select-Object -First $topCount)
    return [pscustomobject]@{ Activity=$picked.Activity; Reason=$null; PrecipChance=$precipChance }
}

try {
    # Windows PowerShell 5.1 may otherwise negotiate older TLS defaults.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $userSettings = Get-Profile
    $locationQuery = if (-not [string]::IsNullOrWhiteSpace($Location)) { $Location } else { [string]$userSettings.Location }
    Write-Host "`nFinding weather for $locationQuery..." -ForegroundColor Cyan
    $place = Get-LocationMatch $locationQuery
    $weather = Get-Weather ([double]$place.latitude) ([double]$place.longitude)
    if (-not $weather.current) { throw 'The weather service returned no current conditions.' }

    $placeParts = @($place.name, $place.admin1, $place.country) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    $placeLabel = $placeParts -join ', '
    $current = $weather.current
    $description = Get-WeatherDescription ([int]$current.weather_code)
    Write-Host "`nOutdoor Activity Picker" -ForegroundColor Cyan
    Write-Host ("Location: {0}" -f $placeLabel)
    Write-Host ("Weather:  {0} C feels like {1} C; {2}; wind {3} km/h, gusts {4} km/h" -f ([Math]::Round([double]$current.temperature_2m)), ([Math]::Round([double]$current.apparent_temperature)), $description, ([Math]::Round([double]$current.wind_speed_10m)), ([Math]::Round([double]$current.wind_gusts_10m)))
    Write-Host ("Updated:  {0}" -f $current.time)

    $result = Get-RecommendedActivity $userSettings $weather
    if (-not $result.Activity) {
        Write-Host "`nNo activity picked: $($result.Reason)" -ForegroundColor Yellow
    }
    else {
        Write-Host "`nYour random activity:" -ForegroundColor Green
        Write-Host ("  {0} ({1} effort, about {2}-{3} minutes)" -f $result.Activity.Name, $result.Activity.Effort, $result.Activity.MinMinutes, $result.Activity.MaxMinutes) -ForegroundColor White
        Write-Host ("  Tip: {0}" -f $result.Activity.Tip)
        if ($result.PrecipChance -ge 40) { Write-Host ("  Caution: rain probability over the next few hours reaches {0}%." -f [Math]::Round($result.PrecipChance)) -ForegroundColor Yellow }
        if ([double]$current.apparent_temperature -ge 30) { Write-Host '  Caution: it feels hot; take water, seek shade, and keep the effort comfortable.' -ForegroundColor Yellow }
        if ([double]$current.apparent_temperature -le 5) { Write-Host '  Caution: dress for the cold and limit exposure if conditions feel uncomfortable.' -ForegroundColor Yellow }
    }
    Write-Host "`nWeather is model-based, not an official alert. Check local conditions and warnings before going out." -ForegroundColor DarkGray
}
catch {
    Write-Host "`nUnable to make a weather-based recommendation: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Check your internet connection and location, then try again. No weather-dependent suggestion was made.' -ForegroundColor Yellow
    exit 1
}
