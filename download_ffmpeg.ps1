$ErrorActionPreference = "Stop"

$url = "https://github.com/GyanD/codexffmpeg/releases/download/5.1.2/ffmpeg-5.1.2-full_build-shared.7z"
$archiveName = "ffmpeg-5.1.2.7z"
$destinationFolder = "ffmpeg-temp"
$outputDir = "server-dotnet\bin\Debug\net8.0-windows"

Write-Host "Downloading FFmpeg 5.1.2 shared build..."
Invoke-WebRequest -Uri $url -OutFile $archiveName

Write-Host "Extracting..."
# Create temp folder
if (Test-Path $destinationFolder) { Remove-Item -Recurse -Force $destinationFolder }
New-Item -ItemType Directory -Path $destinationFolder | Out-Null

# Extract using tar (built-in on Windows 10/11)
tar -xf $archiveName -C $destinationFolder

# Find the bin folder
$binPath = Get-ChildItem -Path $destinationFolder -Recurse -Filter "bin" | Select-Object -First 1 -ExpandProperty FullName

if ($binPath) {
    Write-Host "Found bin folder at: $binPath"
    Write-Host "Copying DLLs to $outputDir..."
    
    # Ensure output dir exists
    if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir | Out-Null }
    
    # Copy DLLs
    Copy-Item "$binPath\*.dll" -Destination $outputDir -Force
    
    Write-Host "Success! FFmpeg DLLs installed."
} else {
    Write-Error "Could not find bin folder in extracted archive."
}

# Cleanup
Remove-Item $archiveName -Force
Remove-Item $destinationFolder -Recurse -Force

Write-Host "Done. Try running ./serverstarter.ps1 now."
