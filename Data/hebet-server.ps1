# Local project server. Reads and writes hebet-data.txt beside this script.
# No internet. The folder may be a local disk or a network share.
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = [System.IO.Path]::GetFullPath($root)
$rootFull = $root.TrimEnd('\') + '\'
$dataFile = [System.IO.Path]::GetFullPath((Join-Path $root "hebet-data.txt"))
$utf8 = New-Object System.Text.UTF8Encoding $false

function ConvertTo-HebetRoot([string]$path) {
  if (-not $path) { return "" }
  return ([System.IO.Path]::GetFullPath($path).TrimEnd('\')).ToLowerInvariant()
}

function Get-InfoJson {
  $exists = Test-Path -LiteralPath $dataFile
  $obj = [ordered]@{
    name = "hebet"
    root = $root
    dataFile = $dataFile
    exists = [bool]$exists
    pid = $PID
  }
  return ($obj | ConvertTo-Json -Compress)
}

function Read-HttpText([string]$url) {
  $req = [System.Net.HttpWebRequest]::Create($url)
  $req.Method = "GET"
  $req.Timeout = 800
  $req.ReadWriteTimeout = 800
  $res = $req.GetResponse()
  try {
    $mark = $res.Headers["X-Hebet-Project"]
    $reader = New-Object System.IO.StreamReader($res.GetResponseStream(), $utf8)
    $text = $reader.ReadToEnd()
    $reader.Close()
    return @{ Mark = $mark; Text = $text; Status = [int]$res.StatusCode }
  } finally {
    $res.Close()
  }
}

function Get-ChromePath {
  $candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
  )
  foreach ($path in $candidates) {
    if ($path -and (Test-Path -LiteralPath $path)) { return $path }
  }
  foreach ($key in @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
  )) {
    try {
      $found = (Get-ItemProperty -LiteralPath $key -ErrorAction Stop)."(default)"
      if ($found -and (Test-Path -LiteralPath $found)) { return [string]$found }
    } catch {}
  }
  return ""
}

function Open-Browser([string]$url) {
  $chrome = Get-ChromePath
  if ($chrome) {
    Start-Process -FilePath $chrome -ArgumentList $url
    return
  }
  Start-Process $url
}

$wantedRoot = ConvertTo-HebetRoot $root
foreach ($candidate in @(18765, 18766, 18767)) {
  $base = "http://127.0.0.1:$candidate/"
  try {
    $info = Read-HttpText ($base + "api/info")
    if ($info.Mark -ne "1" -or -not $info.Text) { continue }
    $parsed = $info.Text | ConvertFrom-Json
    $other = ""
    if ($parsed.root) { $other = ConvertTo-HebetRoot ([string]$parsed.root) }
    if ($other -and $other -eq $wantedRoot) {
      Open-Browser $base
      exit 0
    }
  } catch {}
}

function Add-ShareTrust {
  if (-not $root.StartsWith("\\")) { return }
  $hostName = $root.Substring(2).Split('\')[0]
  if (-not $hostName) { return }
  $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings\ZoneMap\Domains\$hostName"
  try {
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    New-ItemProperty -Path $key -Name "*" -Value 1 -PropertyType DWord -Force | Out-Null
  } catch {}
}

Add-ShareTrust

$listener = $null
$prefix = ""
$port = 0
foreach ($candidate in @(18765, 18766, 18767)) {
  $tryPrefix = "http://127.0.0.1:$candidate/"
  $tryListener = New-Object System.Net.HttpListener
  $tryListener.Prefixes.Add($tryPrefix)
  try {
    $tryListener.Start()
    $listener = $tryListener
    $prefix = $tryPrefix
    $port = $candidate
    break
  } catch {
    try { $tryListener.Close() } catch {}
  }
}

if (-not $listener) {
  Write-Host "לא נמצאה כתובת מקומית פנויה לשמירת הקובץ."
  exit 1
}

try { $Host.UI.RawUI.WindowTitle = "הבט - שמירת הפרויקט" } catch {}
Write-Host "השמירה פועלת מקומית, בלי אינטרנט."
Write-Host "השאירו את החלון הזה פתוח כל זמן העבודה."
Write-Host "קובץ הנתונים:"
Write-Host $dataFile
if (Test-Path -LiteralPath $dataFile) { Write-Host "הקובץ נמצא." }
else { Write-Host "הקובץ עדיין לא קיים. הוא ייווצר בשמירה הראשונה, והקובץ הקיים לא יידרס." }
Write-Host $prefix
if ($env:HEBET_NO_BROWSER -ne "1") { Open-Browser $prefix }

function Add-HebetHeaders([System.Net.HttpListenerResponse]$res) {
  $res.Headers["X-Hebet-Project"] = "1"
  $res.Headers["Access-Control-Allow-Origin"] = "*"
  $res.Headers["Access-Control-Allow-Methods"] = "GET, PUT, OPTIONS"
  $res.Headers["Access-Control-Allow-Headers"] = "Content-Type, X-Hebet-Root"
  $res.Headers["Access-Control-Expose-Headers"] = "X-Hebet-Project"
  $res.Headers["Access-Control-Allow-Private-Network"] = "true"
  $res.Headers["Cache-Control"] = "no-store"
}

function Send-Bytes([System.Net.HttpListenerResponse]$res, [int]$status, [string]$type, [byte[]]$bytes) {
  Add-HebetHeaders $res
  $res.StatusCode = $status
  if ($type) { $res.ContentType = $type }
  if (-not $bytes) { $bytes = New-Object byte[] 0 }
  $res.ContentLength64 = $bytes.LongLength
  if ($bytes.LongLength -gt 0) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
  $res.OutputStream.Close()
}

function Send-Text([System.Net.HttpListenerResponse]$res, [int]$status, [string]$type, [string]$text) {
  Send-Bytes $res $status $type $utf8.GetBytes([string]$text)
}

function Get-ContentType([string]$path) {
  switch ([System.IO.Path]::GetExtension($path).ToLowerInvariant()) {
    ".html" { return "text/html; charset=utf-8" }
    ".txt" { return "text/plain; charset=utf-8" }
    ".json" { return "application/json; charset=utf-8" }
    ".png" { return "image/png" }
    ".gif" { return "image/gif" }
    ".jpg" { return "image/jpeg" }
    ".jpeg" { return "image/jpeg" }
    ".webp" { return "image/webp" }
    ".woff2" { return "font/woff2" }
    ".svg" { return "image/svg+xml" }
    ".ico" { return "image/x-icon" }
    ".css" { return "text/css; charset=utf-8" }
    default { return "" }
  }
}

function Read-HebetData {
  if (-not (Test-Path -LiteralPath $dataFile)) { return '{"version":1,"fresh":true}' }
  for ($i = 0; $i -lt 8; $i++) {
    try {
      $text = [System.IO.File]::ReadAllText($dataFile, $utf8)
      if ($text.Length -gt 0 -and [int][char]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
      if (-not $text.Trim()) { return '{"version":1,"fresh":true}' }
      return $text
    } catch {
      Start-Sleep -Milliseconds 80
    }
  }
  throw "read failed"
}

function Write-Log([string]$msg) {
  try {
    $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") + " " + $msg + "`r`n"
    [System.IO.File]::AppendAllText((Join-Path $root "hebet-server.log"), $line, $utf8)
  } catch {}
}

function Test-HebetJson([string]$text) {
  $trim = $text.Trim()
  if ($trim.Length -lt 2 -or -not $trim.StartsWith("{") -or -not $trim.EndsWith("}")) { return $false }
  return ($trim.Contains('"soldiers"') -or $trim.Contains('"units"') -or $trim.Contains('"fresh"') -or $trim.Contains('"version"'))
}

$backupDir = Join-Path $root "backups"
$dailyDir = Join-Path $backupDir "daily"
$backupKeep = 60
$dailyKeep = 120
$script:lastBackup = [DateTime]::MinValue
$indexFile = Join-Path $root "index.html"
$script:indexStamp = [DateTime]::MinValue
$script:indexVersion = ""

function Get-DataVersion([string]$text) {
  $m = [regex]::Match($text, '"version"\s*:\s*(\d+)')
  if ($m.Success) { return [int]$m.Groups[1].Value }
  return 1
}

function Get-AppVersionOf([string]$text) {
  $m = [regex]::Match($text, '"appVersion"\s*:\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ""
}

# Every soldier record carries a personalId key, so this counts soldiers cheaply.
function Get-SoldierCount([string]$text) {
  return ([regex]::Matches($text, '"personalId"\s*:')).Count
}

# APP_VERSION of the index.html that is installed on disk right now (cached by file time).
function Get-InstalledAppVersion {
  try {
    $stamp = (Get-Item -LiteralPath $indexFile).LastWriteTimeUtc
    if ($stamp -ne $script:indexStamp) {
      $html = [System.IO.File]::ReadAllText($indexFile, $utf8)
      $m = [regex]::Match($html, 'var APP_VERSION = "([^"]+)"')
      $script:indexVersion = ""
      if ($m.Success) { $script:indexVersion = $m.Groups[1].Value }
      $script:indexStamp = $stamp
    }
  } catch {}
  return $script:indexVersion
}

# Copies the current data file into backups\ before it is overwritten.
# Runs on the first save of every server session, then at most once an hour,
# and always (force) when soldiers are removed or the data version changes.
# One copy per day is also kept in backups\daily for $dailyKeep days.
function Backup-HebetData([string]$reason, [bool]$force) {
  if (-not (Test-Path -LiteralPath $dataFile)) { return }
  $now = Get-Date
  try {
    if (-not (Test-Path -LiteralPath $dailyDir)) { New-Item -ItemType Directory -Path $dailyDir -Force | Out-Null }
    $daily = Join-Path $dailyDir ("hebet-data-" + $now.ToString("yyyyMMdd") + ".txt")
    if (-not (Test-Path -LiteralPath $daily)) {
      [System.IO.File]::Copy($dataFile, $daily, $false)
      $oldDaily = Get-ChildItem -LiteralPath $dailyDir -Filter "hebet-data-*.txt" | Sort-Object Name -Descending | Select-Object -Skip $dailyKeep
      foreach ($f in $oldDaily) { try { Remove-Item -LiteralPath $f.FullName -Force } catch {} }
    }
  } catch {
    Write-Log ("daily backup failed: " + $_.Exception.Message)
  }
  if (-not $force -and ($now - $script:lastBackup).TotalMinutes -lt 60) { return }
  try {
    $name = "hebet-data-" + $now.ToString("yyyyMMdd-HHmmss-fff") + "-" + $reason + ".txt"
    [System.IO.File]::Copy($dataFile, (Join-Path $backupDir $name), $true)
    $script:lastBackup = $now
    $old = Get-ChildItem -LiteralPath $backupDir -Filter "hebet-data-*.txt" | Sort-Object LastWriteTime -Descending | Select-Object -Skip $backupKeep
    foreach ($f in $old) { try { Remove-Item -LiteralPath $f.FullName -Force } catch {} }
  } catch {
    Write-Log ("backup failed: " + $_.Exception.Message)
    # Soldiers being removed or a migration: do not overwrite without a backup.
    if ($force) { throw "backup failed" }
  }
}

function Write-HebetData([string]$text) {
  if (Test-Path -LiteralPath $dataFile) {
    try { (Get-Item -LiteralPath $dataFile -Force).IsReadOnly = $false } catch {}
  }
  $tmp = $dataFile + ".tmp"
  $bytes = $utf8.GetBytes($text)
  $out = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
  } finally {
    $out.Close()
  }
  $ok = $false
  $reason = "save failed"
  for ($i = 0; $i -lt 12; $i++) {
    try {
      [System.IO.File]::Copy($tmp, $dataFile, $true)
      $ok = $true
      break
    } catch {
      $reason = $_.Exception.Message
      Start-Sleep -Milliseconds 150
    }
  }
  try { [System.IO.File]::Delete($tmp) } catch {}
  if (-not $ok) { throw $reason }
}

function Read-RequestText([System.Net.HttpListenerRequest]$req) {
  $max = 80MB
  $len = $req.ContentLength64
  if ($len -gt $max) { throw "too large" }
  $ms = New-Object System.IO.MemoryStream
  $buf = New-Object byte[] 65536
  $total = 0
  while ($true) {
    $n = $req.InputStream.Read($buf, 0, $buf.Length)
    if ($n -le 0) { break }
    $total += $n
    if ($total -gt $max) { throw "too large" }
    $ms.Write($buf, 0, $n)
    if ($len -gt 0 -and $total -ge $len) { break }
  }
  return $utf8.GetString($ms.ToArray())
}

$stopRequested = $false
try {
  while ($listener.IsListening -and -not $stopRequested) {
    $ctx = $null
    try {
      $ctx = $listener.GetContext()
    } catch {
      if (-not $listener.IsListening) { break }
      Start-Sleep -Milliseconds 50
      continue
    }
    try {
      $req = $ctx.Request
      $res = $ctx.Response
      $path = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath)

      if ($req.HttpMethod -eq "OPTIONS") {
        Send-Bytes $res 204 "" $null
        continue
      }

      if ($path -eq "/api/info" -and $req.HttpMethod -eq "GET") {
        Send-Text $res 200 "application/json; charset=utf-8" (Get-InfoJson)
        continue
      }

      # Used by the version update. Only the folder this server is saving for can stop it.
      if ($path -eq "/api/shutdown" -and $req.HttpMethod -eq "POST") {
        $claimedRoot = $req.Headers["X-Hebet-Root"]
        $claimed = ""
        if ($claimedRoot) {
          try { $claimed = ConvertTo-HebetRoot ([System.Uri]::UnescapeDataString($claimedRoot)) } catch {}
        }
        if ($claimed -ne $wantedRoot) {
          Send-Text $res 409 "text/plain; charset=utf-8" "wrong-project"
          continue
        }
        Send-Bytes $res 204 "" $null
        $stopRequested = $true
        continue
      }

      if ($path -eq "/api/data" -and $req.HttpMethod -eq "GET") {
        Send-Text $res 200 "application/json; charset=utf-8" (Read-HebetData)
        continue
      }

      if ($path -eq "/api/data" -and $req.HttpMethod -eq "PUT") {
        try {
          $text = (Read-RequestText $req).Trim()
          if (-not (Test-HebetJson $text)) {
            Send-Text $res 400 "text/plain; charset=utf-8" "invalid"
            continue
          }
          # A page opened from another project folder (or left open from an earlier
          # run on the same port) must not write into this folder's data file.
          $claimedRoot = $req.Headers["X-Hebet-Root"]
          if ($claimedRoot) {
            $claimed = ""
            try { $claimed = ConvertTo-HebetRoot ([System.Uri]::UnescapeDataString($claimedRoot)) } catch {}
            if ($claimed -ne $wantedRoot) {
              Write-Log ("rejected save from another project folder: " + $claimed)
              Send-Text $res 409 "text/plain; charset=utf-8" "wrong-project"
              continue
            }
          }
          # A page left open from before an update must not save over data
          # handled by the newly installed version. It is told to reload.
          $installed = Get-InstalledAppVersion
          if ($installed -and (Get-AppVersionOf $text) -ne $installed) {
            Write-Log ("rejected save from outdated page " + (Get-AppVersionOf $text) + ", installed " + $installed)
            Send-Text $res 409 "text/plain; charset=utf-8" "outdated"
            continue
          }
          $currentRev = -1
          $baseRev = -1
          $currentVer = 0
          $currentCount = 0
          if (Test-Path -LiteralPath $dataFile) {
            $currentText = Read-HebetData
            $currentMatch = [regex]::Match($currentText, '"revision"\s*:\s*(\d+)')
            if ($currentMatch.Success) { $currentRev = [int]$currentMatch.Groups[1].Value }
            $currentVer = Get-DataVersion $currentText
            $currentCount = Get-SoldierCount $currentText
          }
          $newCount = Get-SoldierCount $text
          if ($currentCount -ge 3 -and $newCount -eq 0) {
            # Wiping a full file in one save is never a normal action - keep the file.
            Write-Log ("rejected save: would remove all " + $currentCount + " soldiers")
            Send-Text $res 409 "text/plain; charset=utf-8" "empty"
            continue
          }
          $baseMatch = [regex]::Match($text, '"baseRevision"\s*:\s*(\d+)')
          if ($baseMatch.Success) { $baseRev = [int]$baseMatch.Groups[1].Value }
          if ($currentRev -ge 0 -and $baseRev -lt $currentRev) {
            Send-Text $res 409 "text/plain; charset=utf-8" "stale"
            continue
          }
          $newVer = Get-DataVersion $text
          if ($currentVer -gt $newVer) {
            # An older app version must never overwrite data saved by a newer one.
            Write-Log ("rejected save: data version " + $currentVer + " > incoming " + $newVer)
            Send-Text $res 409 "text/plain; charset=utf-8" "stale"
            continue
          }
          if ($currentVer -gt 0 -and $newVer -ne $currentVer) { Backup-HebetData ("v" + $currentVer + "-to-v" + $newVer) $true }
          elseif ($newCount -lt $currentCount) { Backup-HebetData ("removed-" + ($currentCount - $newCount)) $true }
          else { Backup-HebetData "auto" $false }
          Write-HebetData $text
          Send-Bytes $res 204 "" $null
        } catch {
          Write-Log $_.Exception.Message
          try { Send-Text $res 500 "text/plain; charset=utf-8" "save failed" } catch {}
        }
        continue
      }

      if ($req.HttpMethod -ne "GET" -and $req.HttpMethod -ne "HEAD") {
        Send-Text $res 405 "text/plain; charset=utf-8" "method"
        continue
      }

      $rel = $path.TrimStart("/")
      if (-not $rel) { $rel = "index.html" }
      $rel = $rel.Replace("/", "\")
      if ($rel.Contains("..")) {
        Send-Text $res 403 "text/plain; charset=utf-8" "forbidden"
        continue
      }
      $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
      if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        Send-Text $res 403 "text/plain; charset=utf-8" "forbidden"
        continue
      }
      $type = Get-ContentType $full
      if (-not $type -or -not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Send-Text $res 404 "text/plain; charset=utf-8" "missing"
        continue
      }
      $fileBytes = [System.IO.File]::ReadAllBytes($full)
      if ($req.HttpMethod -eq "HEAD") { $fileBytes = New-Object byte[] 0 }
      Send-Bytes $res 200 $type $fileBytes
    } catch {
      try { Write-Log $_.Exception.Message } catch {}
      try { if ($ctx) { $ctx.Response.Abort() } } catch {}
    }
  }
} finally {
  if ($listener -and $listener.IsListening) { $listener.Stop() }
  if ($listener) { $listener.Close() }
}
