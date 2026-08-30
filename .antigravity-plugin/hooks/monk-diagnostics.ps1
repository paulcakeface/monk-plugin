# PostToolUse hook for MANIFEST/MonkScript edits.
# Windows (stock, no Git Bash) counterpart of monk-diagnostics.sh.
#
# All logic (path resolution, workspace discovery, the MCP call, and formatting)
# lives in `monk-agent hook diagnostics`, so this wrapper depends only on the
# binary the plugin already installs. Best-effort: a missing binary, missing
# agent, auth issues, or unavailable analyzer support must never block the
# user's edit, so we always exit 0.

$ErrorActionPreference = "SilentlyContinue"

# On non-Windows the .sh sibling handles this; bow out to avoid emitting the same
# diagnostics twice. On Windows the .ps1 owns it: a host may spawn the .sh in an
# interactive git-bash window whose stdin is a TTY, where the .sh can't read the
# payload - so the .sh bows out on Windows and the .ps1 does the work here.
if ($env:OS -ne 'Windows_NT' -and (Get-Command bash -ErrorAction SilentlyContinue)) { exit 0 }

$InstallDir = if ($env:MONK_AGENT_INSTALL_DIR) { $env:MONK_AGENT_INSTALL_DIR } else { Join-Path $HOME ".monk\bin" }
$agent = if ($env:MONK_AGENT_PATH) { $env:MONK_AGENT_PATH } else { Join-Path $InstallDir "monk-agent.exe" }

if (-not (Test-Path $agent)) { exit 0 }


# Buffer the hook payload as bytes so the helper receives the original stdin
# exactly, while still allowing us to run it as a bounded child process.
$inputStream = [Console]::OpenStandardInput()
$inputBuffer = New-Object byte[] 4096
$payloadStream = New-Object System.IO.MemoryStream
while (($bytesRead = $inputStream.Read($inputBuffer, 0, $inputBuffer.Length)) -gt 0) {
  $payloadStream.Write($inputBuffer, 0, $bytesRead)
}
$hookBytes = $payloadStream.ToArray()
$payloadStream.Dispose()

$helperTimeoutMs = 10000
if ($env:MONK_DIAGNOSTICS_HELPER_TIMEOUT_MS -match '^[1-9][0-9]*$') {
  $helperTimeoutMs = [int]$env:MONK_DIAGNOSTICS_HELPER_TIMEOUT_MS
}

$agentProcess = $null
try {
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $agent
  $startInfo.Arguments = "hook diagnostics --format antigravity"
  $startInfo.UseShellExecute = $false
  $startInfo.RedirectStandardInput = $true
  $startInfo.RedirectStandardOutput = $true
  $startInfo.RedirectStandardError = $true
  $startInfo.CreateNoWindow = $true

  $agentProcess = New-Object System.Diagnostics.Process
  $agentProcess.StartInfo = $startInfo
  [void]$agentProcess.Start()
  $outputTask = $agentProcess.StandardOutput.ReadToEndAsync()
  $errorTask = $agentProcess.StandardError.ReadToEndAsync()
  $agentProcess.StandardInput.BaseStream.Write($hookBytes, 0, $hookBytes.Length)
  $agentProcess.StandardInput.BaseStream.Close()

  if ($agentProcess.WaitForExit($helperTimeoutMs)) {
    $agentText = $outputTask.GetAwaiter().GetResult()
    $agentError = $errorTask.GetAwaiter().GetResult()
    if ($agentError) { [Console]::Error.Write($agentError) }
    if ($agentText) { [Console]::Out.Write($agentText) }
  } else {
    try { $agentProcess.Kill() } catch { }
    try { [void]$agentProcess.WaitForExit(1000) } catch { }
  }
} catch {
} finally {
  if ($agentProcess) { $agentProcess.Dispose() }
}
exit 0
