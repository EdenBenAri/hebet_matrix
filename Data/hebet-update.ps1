# עדכון גרסה של המערכת בלי לגעת בנתונים של הלקוח.
#
# אצל הלקוח (הסקריפט רץ מתוך חבילת העדכון):
#   עדכון את המערכת שלי.bat  →  בוחרים את התיקייה שבה המערכת כבר מותקנת.
#
# אצל מי שכבר מותקן (גרירה על Data\עדכון גרסה.bat):
#   powershell -File hebet-update.ps1 -Source <תיקייה או zip>
#
# מה נשמר תמיד: hebet-data.txt, hebet-server.log, תיקיית backups.
# את המרת הנתונים למבנה חדש עושה המערכת עצמה בפתיחה הבאה.
param(
  [string]$Source,
  [string]$Target,
  [switch]$PickTarget,
  [switch]$Yes
)
$ErrorActionPreference = "Stop"

$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$scriptDir = [System.IO.Path]::GetFullPath($scriptDir).TrimEnd('\')

$script:backup = ""
$script:work = ""
$script:changed = $false

function Fail([string]$msg) {
  Write-Host ""
  Write-Host "העדכון בוטל: $msg" -ForegroundColor Red
  if (-not $script:changed) {
    Write-Host "המערכת והנתונים לא שונו."
  } elseif ($script:backup) {
    Write-Host "אם התוכנה נראית חלקית, אפשר להחזיר את הגרסה הקודמת מתוך: $($script:backup)"
  }
  exit 1
}

function Cancel([string]$msg) {
  Write-Host $msg
  exit 0
}

function Normalize([string]$path) {
  if (-not $path) { return "" }
  $path = $path.Trim().Trim('"').TrimEnd('\')
  if (-not $path) { return "" }
  return [System.IO.Path]::GetFullPath($path).TrimEnd('\')
}

function Same-Folder([string]$a, [string]$b) {
  if (-not $a -or -not $b) { return $false }
  return $a.Equals($b, [System.StringComparison]::OrdinalIgnoreCase)
}

function Inside([string]$child, [string]$parent) {
  if (-not $child -or -not $parent) { return $false }
  $c = $child.TrimEnd('\') + '\'
  $p = $parent.TrimEnd('\') + '\'
  return $c.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)
}

function Resolve-InstallData([string]$path) {
  $path = Normalize $path
  if (-not $path) { return "" }
  if ((Test-Path -LiteralPath (Join-Path $path "Data\index.html")) -and (Test-Path -LiteralPath (Join-Path $path "Data\hebet-server.ps1"))) {
    return (Normalize (Join-Path $path "Data"))
  }
  $leaf = Split-Path -Leaf $path
  if ($leaf -eq "Data" -and (Test-Path -LiteralPath (Join-Path $path "index.html")) -and (Test-Path -LiteralPath (Join-Path $path "hebet-server.ps1"))) {
    return $path
  }
  return ""
}

function Get-AppVersion([string]$dir) {
  try {
    $html = [System.IO.File]::ReadAllText((Join-Path $dir "index.html"))
    $m = [regex]::Match($html, 'var APP_VERSION = "([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
  } catch {}
  return "?"
}

function Get-SoldierCount([string]$file) {
  if (-not (Test-Path -LiteralPath $file)) { return -1 }
  $text = [System.IO.File]::ReadAllText($file)
  return ([regex]::Matches($text, '"personalId"\s*:')).Count
}

function Test-SkippedRelative([string]$rel) {
  if (-not $rel) { return $true }
  $parts = $rel.ToLowerInvariant().Split('\')
  if ($parts[0] -eq "backups" -or $parts[0] -eq ".git") { return $true }
  $name = $parts[$parts.Length - 1]
  if ($name -like "hebet-data*") { return $true }
  if ($name -eq "hebet-server.log") { return $true }
  if ($name -like "*.tmp" -or $name -eq "thumbs.db" -or $name -eq "desktop.ini") { return $true }
  return $false
}

function Assert-SoftwareFile([string]$dest) {
  $name = [System.IO.Path]::GetFileName($dest).ToLowerInvariant()
  if ($name -like "hebet-data*" -or $name -eq "hebet-server.log") {
    throw "סירוב לדרוס את $name"
  }
}

function New-TopForm {
  Add-Type -AssemblyName System.Windows.Forms
  $form = New-Object System.Windows.Forms.Form
  $form.TopMost = $true
  $form.ShowInTaskbar = $false
  $form.StartPosition = "CenterScreen"
  $form.Size = New-Object System.Drawing.Size(1, 1)
  $form.Opacity = 0
  $form.Show()
  return $form
}

function Ask-Folder([string]$description) {
  $owner = New-TopForm
  try {
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.Description = $description
    $dlg.ShowNewFolderButton = $false
    try { $dlg.SelectedPath = [Environment]::GetFolderPath("Desktop") } catch {}
    if ($dlg.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.SelectedPath }
  } finally {
    $owner.Close()
    $owner.Dispose()
  }
  return ""
}

function Ask-Yes([string]$text) {
  $owner = New-TopForm
  try {
    $answer = [System.Windows.Forms.MessageBox]::Show(
      $owner,
      $text,
      "עדכון גרסה",
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question,
      [System.Windows.Forms.MessageBoxDefaultButton]::Button1
    )
    return $answer -eq [System.Windows.Forms.DialogResult]::Yes
  } finally {
    $owner.Close()
    $owner.Dispose()
  }
}

function Show-Done([string]$text) {
  if ($Yes) { return }
  $owner = New-TopForm
  try {
    [System.Windows.Forms.MessageBox]::Show(
      $owner,
      $text,
      "עדכון גרסה",
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  } finally {
    $owner.Close()
    $owner.Dispose()
  }
}

function Read-Info([int]$port) {
  $utf8 = New-Object System.Text.UTF8Encoding $false
  $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/api/info")
  $req.Method = "GET"
  $req.Timeout = 800
  $req.ReadWriteTimeout = 800
  $res = $req.GetResponse()
  try {
    $mark = [string]$res.Headers["X-Hebet-Project"]
    $reader = New-Object System.IO.StreamReader($res.GetResponseStream(), $utf8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return @{ Mark = $mark; Text = $text }
  } finally {
    $res.Close()
  }
}

function Request-Shutdown([int]$port, [string]$dataRoot) {
  try {
    $req = [System.Net.HttpWebRequest]::Create("http://127.0.0.1:$port/api/shutdown")
    $req.Method = "POST"
    $req.Timeout = 2000
    $req.ReadWriteTimeout = 2000
    $req.ContentLength = 0
    $req.Headers.Add("X-Hebet-Root", [System.Uri]::EscapeDataString((Normalize $dataRoot)))
    $res = $req.GetResponse()
    $code = [int]$res.StatusCode
    $res.Close()
    return ($code -eq 204 -or $code -eq 200)
  } catch {
    return $false
  }
}

function Stop-HebetProcess([int]$procId) {
  if ($procId -le 4 -or $procId -eq $PID) { return $false }
  $proc = $null
  try { $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop } catch { return $false }
  if (-not $proc) { return $false }
  $cmd = [string]$proc.CommandLine
  if (-not $cmd -or $cmd.ToLowerInvariant().IndexOf("hebet-server.ps1") -lt 0) { return $false }
  try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch { return $false }
  return $true
}

# עוצר רק את שרת השמירה של התיקייה הזו. לא נוגע בתיקייה אחרת ולא בתהליך המערכת.
function Stop-ProjectServer([string]$dataRoot) {
  $wanted = (Normalize $dataRoot).ToLowerInvariant()
  $scriptPath = (Normalize (Join-Path $dataRoot "hebet-server.ps1")).ToLowerInvariant()
  $found = $false
  foreach ($port in @(18765, 18766, 18767)) {
    $info = $null
    try { $info = Read-Info $port } catch { continue }
    if ($info.Mark -ne "1" -or -not $info.Text) { continue }
    $parsed = $null
    $other = ""
    try {
      $parsed = $info.Text | ConvertFrom-Json
      if ($parsed.root) { $other = (Normalize ([string]$parsed.root)).ToLowerInvariant() }
    } catch { continue }
    if ($other -ne $wanted) { continue }
    $found = $true
    Request-Shutdown $port $dataRoot | Out-Null
    $reported = 0
    try { $reported = [int]$parsed.pid } catch { $reported = 0 }
    if ($reported -gt 4) { Stop-HebetProcess $reported | Out-Null }
  }
  try {
    $procs = @(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {
      $_.ProcessId -gt 4 -and $_.CommandLine -and $_.CommandLine.ToLowerInvariant().IndexOf($scriptPath) -ge 0
    })
    if ($procs.Count -gt 0) { $found = $true }
    foreach ($proc in $procs) { Stop-HebetProcess ([int]$proc.ProcessId) | Out-Null }
  } catch {}
  if (-not $found) { return $true }
  Start-Sleep -Milliseconds 700
  foreach ($port in @(18765, 18766, 18767)) {
    try {
      $info = Read-Info $port
      if ($info.Mark -ne "1" -or -not $info.Text) { continue }
      $parsed = $info.Text | ConvertFrom-Json
      $other = ""
      if ($parsed.root) { $other = (Normalize ([string]$parsed.root)).ToLowerInvariant() }
      if ($other -eq $wanted) { return $false }
    } catch {}
  }
  Write-Host "השמירה שרצה ברקע נעצרה, כדי שהגרסה החדשה תיטען בפתיחה הבאה."
  return $true
}

function Restore-ClientData([string]$dataFile, [bool]$hadData) {
  if ($hadData) {
    $bak = Join-Path $script:backup "hebet-data.txt"
    if ((Test-Path -LiteralPath $bak) -and $script:backup) {
      Copy-Item -LiteralPath $bak -Destination $dataFile -Force
    }
  } elseif (Test-Path -LiteralPath $dataFile) {
    Remove-Item -LiteralPath $dataFile -Force
  }
}

if ($Source) { $Source = $Source.Trim().Trim('"') }
if ($Target) { $Target = $Target.Trim().Trim('"') }

if ($PickTarget -and -not $Source) {
  $Source = Split-Path -Parent $scriptDir
}
if (-not $Source -and -not $PickTarget) {
  $Source = Ask-Folder "בחרו את תיקיית הגרסה החדשה, או את התיקייה שנפתחה מקובץ העדכון"
}
if (-not $Source) { Cancel "לא נבחרה גרסה חדשה. שום קובץ לא שונה." }

if ($PickTarget -and -not $Target) {
  $Target = Ask-Folder "בחרו את התיקייה שבה המערכת כבר מותקנת אצלכם (זו שמכילה את תקן מצבה זרועי ואת תיקיית Data)"
}
if (-not $Target) { $Target = $scriptDir }
if (-not $Target) { Cancel "לא נבחרה התיקייה הקיימת. שום קובץ לא שונה." }

$installData = Resolve-InstallData $Target
if (-not $installData) { Fail "בתיקייה שנבחרה אין מערכת קיימת. צריך תיקייה שמכילה Data\index.html." }
$installRoot = Split-Path -Parent $installData

if (-not (Test-Path -LiteralPath $Source)) { Fail "לא נמצא: $Source" }

$stamp = (Get-Date).ToString("yyyyMMdd-HHmmss")
$src = Normalize $Source

try {
  if ((Get-Item -LiteralPath $src).PSIsContainer -eq $false) {
    if ([System.IO.Path]::GetExtension($src).ToLowerInvariant() -ne ".zip") { Fail "יש לבחור תיקייה או קובץ ZIP." }
    $script:work = Join-Path $env:TEMP ("hebet-update-" + $stamp)
    New-Item -ItemType Directory -Path $script:work -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($src, $script:work)
    $src = $script:work
    $inner = @(Get-ChildItem -LiteralPath $src -Force)
    if ($inner.Count -eq 1 -and $inner[0].PSIsContainer) { $src = $inner[0].FullName }
  }

  $srcOuter = ""
  $srcData = $src
  if (Test-Path -LiteralPath (Join-Path $src "Data\index.html")) {
    $srcOuter = $src
    $srcData = Join-Path $src "Data"
  }
  $srcData = Normalize $srcData
  if ($srcOuter) { $srcOuter = Normalize $srcOuter }

  if (-not (Test-Path -LiteralPath (Join-Path $srcData "index.html"))) {
    Fail "בתיקייה שנבחרה אין index.html - זו לא גרסה של המערכת."
  }
  if ((Same-Folder $srcData $installData) -or ($srcOuter -and (Same-Folder $srcOuter $installRoot))) {
    Fail "תיקיית המקור היא תיקיית המערכת עצמה. בחרו את התיקייה הקיימת, לא את תיקיית העדכון."
  }
  if ((Inside $installData $srcData) -or ($srcOuter -and (Inside $installData $srcOuter)) -or (Inside $srcData $installData)) {
    Fail "תיקיית העדכון ותיקיית המערכת נמצאות אחת בתוך השנייה. חלצו את העדכון למקום נפרד."
  }

  $fromVer = Get-AppVersion $installData
  $toVer = Get-AppVersion $srcData
  $dataFile = Join-Path $installData "hebet-data.txt"
  $soldierCount = Get-SoldierCount $dataFile
  $summary = if ($soldierCount -lt 0) {
    "אין עדיין קובץ נתונים בתיקייה הזו. אם יש לכם נתונים, זו לא התיקייה הנכונה."
  } else {
    "נמצאו $soldierCount חיילים. הקובץ hebet-data.txt והגיבויים לא יידרסו."
  }
  $question = "לעדכן את המערכת מגרסה $fromVer לגרסה $toVer?`r`n`r`n$installRoot`r`n`r`n$summary"
  Write-Host $question
  if (-not $Yes) {
    if (-not (Ask-Yes $question)) { Cancel "העדכון בוטל. שום קובץ לא שונה." }
  }

  if (-not (Stop-ProjectServer $installData)) {
    Write-Host "השמירה ברקע עדיין רצה. קובץ הנתונים לא יוחלף." -ForegroundColor Yellow
  }

  $backupRoot = Join-Path $installData "backups"
  $kept = @{}
  if (Test-Path -LiteralPath $backupRoot) {
    Get-ChildItem -LiteralPath $backupRoot -Recurse -File -Force | ForEach-Object {
      $kept[$_.FullName] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
  }

  $script:backup = Join-Path $installData ("backups\pre-update-" + $stamp)
  New-Item -ItemType Directory -Path $script:backup -Force | Out-Null
  Get-ChildItem -LiteralPath $installData -Force | Where-Object { $_.Name -ne "backups" -and $_.Name -ne ".git" } | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $script:backup -Recurse -Force
  }
  $outerBackup = Join-Path $script:backup "_outer"
  Get-ChildItem -LiteralPath $installRoot -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not (Test-Path -LiteralPath $outerBackup)) { New-Item -ItemType Directory -Path $outerBackup -Force | Out-Null }
    Copy-Item -LiteralPath $_.FullName -Destination $outerBackup -Force
  }

  $hadData = Test-Path -LiteralPath $dataFile
  $dataHash = ""
  $dataLength = 0L
  if ($hadData) {
    $dataHash = (Get-FileHash -LiteralPath $dataFile -Algorithm SHA256).Hash
    $dataLength = (Get-Item -LiteralPath $dataFile).Length
    $copyHash = (Get-FileHash -LiteralPath (Join-Path $script:backup "hebet-data.txt") -Algorithm SHA256).Hash
    if ($dataHash -ne $copyHash) { Fail "הגיבוי של hebet-data.txt לא זהה למקור." }
  }
  Write-Host "גיבוי נשמר ב: $($script:backup)"

  $script:changed = $true
  $count = 0
  try {
    Get-ChildItem -LiteralPath $srcData -Recurse -File -Force | ForEach-Object {
      $rel = $_.FullName.Substring($srcData.Length).TrimStart('\')
      if (Test-SkippedRelative $rel) { return }
      $dest = Join-Path $installData $rel
      Assert-SoftwareFile $dest
      $destDir = Split-Path -Parent $dest
      if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
      Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
      $count++
    }

    $skipOuter = @("עדכון את המערכת שלי.bat", "hebet-pack.ps1", "הכנת עדכון ללקוח.bat", ".gitignore")
    if ($srcOuter) {
      Get-ChildItem -LiteralPath $srcOuter -File -Force | ForEach-Object {
        if ($_.Name.StartsWith(".")) { return }
        if ($skipOuter -contains $_.Name) { return }
        if (Test-SkippedRelative $_.Name) { return }
        $dest = Join-Path $installRoot $_.Name
        Assert-SoftwareFile $dest
        Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        $count++
      }
    }
  } catch {
    Restore-ClientData $dataFile $hadData
    Fail ("ההעתקה נכשלה: " + $_.Exception.Message)
  }

  $packageData = Join-Path $srcData "hebet-data.txt"
  $packageHash = ""
  if (Test-Path -LiteralPath $packageData) {
    $packageHash = (Get-FileHash -LiteralPath $packageData -Algorithm SHA256).Hash
  }
  if ($hadData) {
    if (-not (Test-Path -LiteralPath $dataFile)) {
      Restore-ClientData $dataFile $true
      Fail "hebet-data.txt נמחק במהלך העדכון ושוחזר מהגיבוי."
    }
    $afterHash = (Get-FileHash -LiteralPath $dataFile -Algorithm SHA256).Hash
    if ($packageHash -and $afterHash -eq $packageHash -and $afterHash -ne $dataHash) {
      Restore-ClientData $dataFile $true
      Fail "קובץ הנתונים מהחבילה דרס את הנתונים שלכם, והקובץ שוחזר מהגיבוי."
    }
    if ($afterHash -ne $dataHash) {
      $soldierCount = Get-SoldierCount $dataFile
      Write-Host "בזמן העדכון המערכת שמרה נתונים, והשמירה החדשה נשארה."
    }
  } elseif (Test-Path -LiteralPath $dataFile) {
    $afterHash = (Get-FileHash -LiteralPath $dataFile -Algorithm SHA256).Hash
    if (-not $packageHash -or $afterHash -eq $packageHash) {
      Restore-ClientData $dataFile $false
      Fail "נוצר קובץ נתונים מתוך חבילת העדכון והוא הוסר."
    }
  }

  foreach ($path in @($kept.Keys)) {
    if (-not (Test-Path -LiteralPath $path)) {
      Fail "גיבוי קיים נמחק במהלך העדכון: $path"
    }
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($hash -ne $kept[$path]) {
      Fail "גיבוי קיים השתנה במהלך העדכון: $path"
    }
  }

  $keptText = if ($soldierCount -lt 0) { "לא היה קובץ נתונים, ולא נוצר אחד במקומו." } else { "הנתונים נשארו כמו שהיו ($soldierCount חיילים)." }
  Write-Host ""
  Write-Host "העדכון הושלם. עודכנו $count קבצים." -ForegroundColor Green
  Write-Host "התוכנה עודכנה מגרסה $fromVer לגרסה $toVer."
  Write-Host $keptText
  Write-Host "פתחו את «תקן מצבה זרועי» מהתיקייה הרגילה, לא מתיקיית העדכון."
  Show-Done "העדכון הושלם.`r`nהתוכנה עודכנה מגרסה $fromVer לגרסה $toVer.`r`n$keptText`r`n`r`nפתחו את תקן מצבה זרועי מהתיקייה הרגילה, לא מתיקיית העדכון."
} finally {
  if ($script:work) {
    try { Remove-Item -LiteralPath $script:work -Recurse -Force } catch {}
  }
}
