$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$EnsureScript = Join-Path $RepoRoot "scripts\ensure-monk-agent.ps1"
$PowerShellExe = (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source
if (-not $PowerShellExe) { $PowerShellExe = (Get-Process -Id $PID).Path }

function Start-Installer {
  param([string]$Root, [string]$LockTimeout = "2")
  $Info = [Diagnostics.ProcessStartInfo]::new()
  $Info.FileName = $PowerShellExe
  $Info.UseShellExecute = $false
  $Info.RedirectStandardOutput = $true
  $Info.RedirectStandardError = $true
  if ($PowerShellExe -match '(?i)powershell\.exe$') {
    $Info.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$EnsureScript`""
  } else {
    $Info.Arguments = "-NoLogo -NoProfile -File `"$EnsureScript`""
  }
  $Info.Environment['MONK_AGENT_INSTALL_DIR'] = (Join-Path $Root 'install')
  $Info.Environment['MONK_AGENT_HOME'] = (Join-Path $Root 'home')
  $Info.Environment['MONK_AGENT_DOWNLOAD_BASE'] = 'http://127.0.0.1:1'
  $Info.Environment['MONK_AGENT_INSTALL_LOCK_TIMEOUT'] = $LockTimeout
  $P = [Diagnostics.Process]::new(); $P.StartInfo = $Info
  if (-not $P.Start()) { throw 'failed to start installer child' }
  return $P
}

function Collect-Exit {
  param($Process, [int]$TimeoutMs = 7000)
  if (-not $Process.WaitForExit($TimeoutMs)) {
    try { $Process.Kill(); $Process.WaitForExit() } catch {}
    throw "installer exceeded bounded test wait"
  }
  $Process.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $Process.ExitCode
    Stdout = $Process.StandardOutput.ReadToEnd()
    Stderr = $Process.StandardError.ReadToEnd()
  }
}

$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('monk-installer-lock-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $TempRoot | Out-Null
try {
  # A live owner holds the exact shared installer mutex. The second installer
  # must return a bounded actionable error rather than wait forever.
  $Mutex = [Threading.Mutex]::new($false, 'Local\monk-agent-installer')
  $Owned = $Mutex.WaitOne(0)
  if (-not $Owned) { throw 'fixture could not acquire installer mutex' }
  try {
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $P = Start-Installer (Join-Path $TempRoot 'blocked') '2'
    $Result = Collect-Exit $P
    $Timer.Stop()
    if ($Result.ExitCode -eq 0) { throw 'contended installer unexpectedly succeeded' }
    if ($Timer.Elapsed.TotalSeconds -gt 6) { throw "lock timeout was not bounded: $($Timer.Elapsed.TotalSeconds)s" }
    if ($Result.Stderr -notmatch 'Timed out after 2s waiting for another monk-agent installer') {
      throw "missing installer-lock timeout diagnostic: $($Result.Stderr)"
    }
    $ChecksumTmp = Join-Path (Join-Path $TempRoot 'blocked') 'install\.monk-agent.tmp.sha256'
    if (Test-Path $ChecksumTmp) { throw 'contended installer reached download work before owning the mutex' }
  } finally {
    if ($Owned) { $Mutex.ReleaseMutex() }
    $Mutex.Dispose()
  }

  # No-contention control: the same child proceeds immediately past the mutex
  # and fails at the deliberately unreachable download endpoint, not lock wait.
  $Timer = [Diagnostics.Stopwatch]::StartNew()
  $P = Start-Installer (Join-Path $TempRoot 'free') '2'
  $Control = Collect-Exit $P
  $Timer.Stop()
  if ($Control.ExitCode -eq 0) { throw 'unreachable-endpoint control unexpectedly succeeded' }
  if ($Timer.Elapsed.TotalSeconds -gt 5) { throw 'no-contention control did not proceed promptly' }
  if ($Control.Stderr -match 'waiting for another monk-agent installer') {
    throw 'no-contention control incorrectly reported installer-lock timeout'
  }

  # Invalid lock timeout fails closed before any installer work.
  $P = Start-Installer (Join-Path $TempRoot 'invalid') '0'
  $Invalid = Collect-Exit $P 3000
  if ($Invalid.ExitCode -ne 2) { throw "invalid timeout exit was $($Invalid.ExitCode), expected 2" }
  if ($Invalid.Stderr -notmatch 'MONK_AGENT_INSTALL_LOCK_TIMEOUT must be a positive integer') {
    throw 'invalid timeout diagnostic missing'
  }

  $Copies = @(
    'scripts\ensure-monk-agent.ps1',
    'plugins\monk\scripts\ensure-monk-agent.ps1',
    '.antigravity-plugin\scripts\ensure-monk-agent.ps1'
  ) | ForEach-Object { Join-Path $RepoRoot $_ }
  $Hashes = $Copies | ForEach-Object { (Get-FileHash -Algorithm SHA256 $_).Hash }
  if (($Hashes | Select-Object -Unique).Count -ne 1) { throw 'distributed PowerShell installer copies differ' }

  Write-Host 'windows_installer_lock_timeout_status=pass contended=bounded free=proceeded invalid=closed copies=3'
} finally {
  Remove-Item -Recurse -Force $TempRoot -ErrorAction SilentlyContinue
}
