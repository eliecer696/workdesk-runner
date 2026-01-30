$ErrorActionPreference = "Stop"
$url = "https://github.com/GyanD/codexffmpeg/releases/download/5.1.2/ffmpeg-5.1.2-full_build-shared.7z"
$archiveName = "ffmpeg-5.1.2-win.7z"
$targetDir = "addons\h264_decoder"
$extractDir = "$targetDir\ffmpeg_extract_temp"

Write-Host "Downloading FFmpeg for Windows..."
Invoke-WebRequest -Uri $url -OutFile $archiveName

Write-Host "Extracting (using 7zip executable via cmd if available, otherwise trying tar)..."
# Try system tar first as it's common on newer Windows, but might fail on 7z LZMA
# We will use the hacky way: assume 7z might be in standard paths or just rely on the user having modern Windows tar

# Actually, let's just use the .zip version if 7z fails? No, specific link.
# Let's try to assume 'tar' works if it's updated. If not, we fail.
# But wait, 7z failed in CLI.
# Let's try to find 7z.exe
$7z = "C:\Program Files\7-Zip\7z.exe"
if (Test-Path $7z) {
    & $7z x $archiveName -o"$extractDir" -y
} else {
    Write-Warning "7-Zip not found at default location. Trying 'tar' again (might fail on 7z compression)."
    New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
    tar -xf $archiveName -C $extractDir
}

# Move files
$extractedRoot = Get-ChildItem $extractDir | Select-Object -First 1
$ffmpegWinDir = "$targetDir\ffmpeg_windows"
if (Test-Path $ffmpegWinDir) { Remove-Item -Recurse -Force $ffmpegWinDir }
New-Item -ItemType Directory -Force -Path $ffmpegWinDir | Out-Null

Copy-Item -Recurse "$($extractedRoot.FullName)\include" "$ffmpegWinDir\include"
Copy-Item -Recurse "$($extractedRoot.FullName)\lib" "$ffmpegWinDir\lib"
Copy-Item -Recurse "$($extractedRoot.FullName)\bin" "$ffmpegWinDir\bin"

# Cleanup
Remove-Item $archiveName -Force
Remove-Item $extractDir -Recurse -Force
Write-Host "Done! Windows FFmpeg files are in $ffmpegWinDir"
