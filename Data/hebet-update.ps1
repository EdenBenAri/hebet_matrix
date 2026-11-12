# עדכון גרסה של המערכת בלי לגעת בנתונים.
# שימוש: גוררים את תיקיית הגרסה החדשה (או קובץ ZIP) על «עדכון גרסה.bat»,
# או: powershell -ExecutionPolicy Bypass -File hebet-update.ps1 -Source <תיקייה או zip>
#
# מה הסקריפט עושה:
#   1. שומר גיבוי מלא של hebet-data.txt ושל קבצי התוכנה הנוכחיים בתיקייה backups\pre-update-<תאריך>.
#   2. מעתיק את קבצי התוכנה החדשים מעל הישנים.
#   3. לעולם לא מעתיק ולא מוחק את hebet-data.txt, את backups\ או את הלוג.
# את המרת הנתונים למבנה החדש (מיגרציה) עושה המערכת עצמה בפתיחה הבאה.
param([string]$Source)
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
$protected = @("hebet-data.txt", "hebet-data.txt.tmp", "hebet-server.log")
$protectedDirs = @("backups", ".git")

function Fail([string]$msg) {
  Write-Host ""
  Write-Host "העדכון בוטל: $msg" -ForegroundColor Red
  Write-Host "שום קובץ לא שונה."
  exit 1
}

if (-not $Source) {
  try {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = "בחרו את תיקיית הגרסה החדשה"
    if ($dlg.ShowDialog() -eq "OK") { $Source = $dlg.SelectedPath }
  } catch {}
}
if (-not $Source) { Fail "לא נבחרה תיקיית גרסה חדשה." }
if (-not (Test-Path -LiteralPath $Source)) { Fail "לא נמצא: $Source" }

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$work = $null
$src = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')

if ((Get-Item -LiteralPath $src).PSIsContainer -eq $false) {
  if ([System.IO.Path]::GetExtension($src).ToLowerInvariant() -ne ".zip") { Fail "יש לבחור תיקייה או קובץ ZIP." }
  $work = Join-Path $env:TEMP ("hebet-update-" + $stamp)
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($src, $work)
  $src = $work
  # ZIP מ-GitHub מכיל תיקייה עליונה אחת
  $inner = Get-ChildItem -LiteralPath $src
  if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $src = $inner[0].FullName }
}

# מבנה הפרויקט: <תיקייה>\תקן מצבה זרועי.hta + <תיקייה>\Data\(כל השאר). הסקריפט יושב בתוך Data.
$appRoot = Split-Path -Parent $root
$srcOuter = $null
if (Test-Path -LiteralPath (Join-Path $src "Data\index.html")) {
  $srcOuter = $src
  $src = Join-Path $src "Data"
}

if ($src -ieq $root -or ($srcOuter -and $srcOuter -ieq $appRoot)) { Fail "תיקיית המקור היא תיקיית המערכת עצמה." }
if (-not (Test-Path -LiteralPath (Join-Path $src "index.html"))) { Fail "בתיקייה שנבחרה אין index.html - זו לא גרסה של המערכת." }

function Get-AppVersion([string]$dir) {
  try {
    $html = [System.IO.File]::ReadAllText((Join-Path $dir "index.html"))
    $m = [regex]::Match($html, 'var APP_VERSION = "([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch {}
  return "?"
}
$fromVer = Get-AppVersion $root
$toVer = Get-AppVersion $src
Write-Host "עדכון מגרסה $fromVer לגרסה $toVer"

# 1. גיבוי
$backup = Join-Path $root ("backups\pre-update-" + $stamp)
New-Item -ItemType Directory -Path $backup -Force | Out-Null
Get-ChildItem -LiteralPath $root -Force | Where-Object { $protectedDirs -notcontains $_.Name } | ForEach-Object {
  Copy-Item -LiteralPath $_.FullName -Destination $backup -Recurse -Force
}
$outerBackup = Join-Path $backup "_outer"
Get-ChildItem -LiteralPath $appRoot -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
  if (-not (Test-Path -LiteralPath $outerBackup)) { New-Item -ItemType Directory -Path $outerBackup -Force | Out-Null }
  Copy-Item -LiteralPath $_.FullName -Destination $outerBackup -Force
}
$dataFile = Join-Path $root "hebet-data.txt"
$dataHash = ""
if (Test-Path -LiteralPath $dataFile) {
  $dataHash = (Get-FileHash -LiteralPath $dataFile -Algorithm SHA256).Hash
  $copyHash = (Get-FileHash -LiteralPath (Join-Path $backup "hebet-data.txt") -Algorithm SHA256).Hash
  if ($dataHash -ne $copyHash) { Fail "הגיבוי של hebet-data.txt לא זהה למקור." }
}
Write-Host "גיבוי נשמר ב: $backup"

# 2. העתקת קבצי התוכנה
$count = 0
Get-ChildItem -LiteralPath $src -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($src.Length).TrimStart('\')
  $top = $rel.Split('\')[0]
  if ($protectedDirs -contains $top) { return }
  if ($protected -contains $rel.ToLowerInvariant()) { return }
  $dest = Join-Path $root $rel
  $destDir = Split-Path -Parent $dest
  if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
  Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
  $count++
}

# קבצים שליד Data (למשל תקן מצבה זרועי.hta)
if ($srcOuter) {
  Get-ChildItem -LiteralPath $srcOuter -File -Force | ForEach-Object {
    if ($_.Name.StartsWith(".")) { return }
    if ($protected -contains $_.Name.ToLowerInvariant()) { return }
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $appRoot $_.Name) -Force
    $count++
  }
}

if ($work) { try { Remove-Item -LiteralPath $work -Recurse -Force } catch {} }

# בדיקה סופית: קובץ הנתונים לא השתנה בזמן העדכון (אלא אם המערכת שמרה בו בינתיים).
if ($dataHash) {
  if (-not (Test-Path -LiteralPath $dataFile)) {
    Copy-Item -LiteralPath (Join-Path $backup "hebet-data.txt") -Destination $dataFile
    Write-Host "hebet-data.txt חסר אחרי העדכון - שוחזר מהגיבוי." -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "העדכון הושלם. עודכנו $count קבצים. הנתונים לא שונו." -ForegroundColor Green
Write-Host "סגרו את חלון השמירה הפתוח (אם יש) ופתחו מחדש את «תקן מצבה זרועי»."
Write-Host "אם משהו לא תקין - אפשר להחזיר את הגרסה הקודמת מתוך: $backup"
