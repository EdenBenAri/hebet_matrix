# בונה ZIP לשליחה ללקוח, בלי קובץ הנתונים ובלי הגיבויים.
# הלקוח מחלץ את הקובץ ומריץ «עדכון את המערכת שלי».
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
$data = Join-Path $root "Data"
$index = Join-Path $data "index.html"
if (-not (Test-Path -LiteralPath $index)) { throw "לא נמצא Data\index.html" }

function Fail([string]$msg) {
  Write-Host $msg -ForegroundColor Red
  exit 1
}

function Test-SkippedName([string]$name) {
  $leaf = $name.ToLowerInvariant()
  if ($leaf -like "hebet-data*") { return $true }
  if ($leaf -eq "hebet-server.log") { return $true }
  if ($leaf -like "*.tmp" -or $leaf -eq "thumbs.db" -or $leaf -eq "desktop.ini") { return $true }
  return $false
}

function Copy-TreeFiltered([string]$from, [string]$to) {
  if (-not (Test-Path -LiteralPath $to)) { New-Item -ItemType Directory -Path $to -Force | Out-Null }
  Get-ChildItem -LiteralPath $from -Force | ForEach-Object {
    if ($_.Name -eq "backups" -or $_.Name -eq ".git") { return }
    if (-not $_.PSIsContainer) {
      if (Test-SkippedName $_.Name) { return }
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $to $_.Name) -Force
      return
    }
    Copy-TreeFiltered $_.FullName (Join-Path $to $_.Name)
  }
}

$html = [System.IO.File]::ReadAllText($index)
$version = "0"
$match = [regex]::Match($html, 'var APP_VERSION = "([^"]+)"')
if ($match.Success) { $version = $match.Groups[1].Value }

$desktop = [Environment]::GetFolderPath("Desktop")
$zipName = "תקן מצבה זרועי - עדכון $version.zip"
$zipPath = Join-Path $desktop $zipName
$stage = Join-Path $env:TEMP ("hebet-pack-" + [guid]::NewGuid().ToString("n"))
$bundle = Join-Path $stage "bundle"

New-Item -ItemType Directory -Path $bundle -Force | Out-Null
try {
  Copy-Item -LiteralPath (Join-Path $root "תקן מצבה זרועי.hta") -Destination $bundle -Force
  Copy-Item -LiteralPath (Join-Path $root "עדכון את המערכת שלי.bat") -Destination $bundle -Force
  Copy-Item -LiteralPath (Join-Path $root "איך מעדכנים.txt") -Destination $bundle -Force
  Copy-TreeFiltered $data (Join-Path $bundle "Data")

  $leaks = @(Get-ChildItem -LiteralPath $bundle -Recurse -Force -File | Where-Object {
    $_.Name -like "hebet-data*" -or $_.Name -eq "hebet-server.log" -or $_.FullName -match '\\backups\\'
  })
  if ($leaks.Count -gt 0) { Fail "החבילה כוללת קבצי נתונים ולא נבנתה." }

  if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)

  $opened = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
  try {
    $names = @($opened.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
  } finally {
    $opened.Dispose()
  }
  $bad = @($names | Where-Object { $_ -match '(^|/)hebet-data|(^|/)backups/|hebet-server\.log' })
  if ($bad.Count -gt 0) {
    Remove-Item -LiteralPath $zipPath -Force
    Fail "ה-ZIP כולל נתונים של הלקוח ולכן נמחק."
  }
  foreach ($need in @("Data/index.html", "Data/hebet-update.ps1", "Data/hebet-server.ps1", "איך מעדכנים.txt")) {
    if ($names -notcontains $need) { Fail "חסר בחבילה: $need" }
  }
  if (@($names | Where-Object { $_ -like "*.hta" }).Count -lt 1) { Fail "חסר בחבילה קובץ הפתיחה." }
  if (@($names | Where-Object { $_ -like "*.bat" }).Count -lt 1) { Fail "חסר בחבילה קובץ העדכון." }
} finally {
  try { Remove-Item -LiteralPath $stage -Recurse -Force } catch {}
}

Write-Host ""
Write-Host "החבילה מוכנה לשליחה:" -ForegroundColor Green
Write-Host $zipPath
Write-Host "גרסה $version. קובץ הנתונים והגיבויים לא נכללו."
Write-Host "הלקוח מחלץ את הקובץ, לוחץ «עדכון את המערכת שלי», ובוחר את התיקייה הקיימת."
