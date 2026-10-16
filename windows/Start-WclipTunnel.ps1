#requires -Version 7
<#
.SYNOPSIS
    Keeps an SSH reverse tunnel open so `wclip` on -SshHost reaches this box's receiver.

.DESCRIPTION
    Runs `ssh -N -R <Port>:localhost:<Port> <SshHost>`: localhost:<Port> on the remote host
    forwards to the wclip receiver on localhost:<Port> here. The connection is outbound from
    Win11, so no port is opened on this machine. Runs forever from a logon scheduled task and
    restarts ssh whenever it exits.

    Uses native OpenSSH with BatchMode, so key-based auth for -SshHost must already work
    (`ssh <host>` without a prompt).

.NOTES
    Same retry/backoff pattern as the bridge MCP tunnel: VPN-only hosts time out while the
    VPN is down, so retries back off from 10 s to -MaxDelaySeconds and reset once a
    connection has stayed up for a minute.

    ExitOnForwardFailure=yes: if the remote port is still held by a half-dead previous
    session, ssh exits and is retried instead of sitting there without a forward. sshd
    releases the stale port once ClientAlive/TCP keepalive notices the old session is gone.

    On Intune-managed boxes a logon task re-stamps a BOSSINFO\<user> ACE onto ~\.ssh, which
    native OpenSSH refuses ("Bad owner or permissions"). Repair-SshConfigAcl strips it before
    each attempt; it is a no-op on machines without that ACE.

    If you hit a blocker running this, fix it here and update this header so the next run
    does not have to re-derive it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SshHost,
    [int]$Port = 17790,
    [int]$MaxDelaySeconds = 60
)

$ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'   # native OpenSSH, NOT a WSL ssh shim
$stateDir = Join-Path $env:LOCALAPPDATA 'wclip'
$log = Join-Path $stateDir 'tunnel.log'
$minDelay = 10
$stableAfter = [timespan]::FromMinutes(1)
New-Item -ItemType Directory -Force $stateDir | Out-Null

function Write-TunnelLog {
    param([string]$Message)
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
    Add-Content $log "$(Get-Date -Format s) $Message"
}

function Repair-SshConfigAcl {
    $sshDir = Join-Path $env:USERPROFILE '.ssh'
    $sshConfig = Join-Path $sshDir 'config'
    $me = "$env:USERDOMAIN\$env:USERNAME"
    foreach ($path in @($sshDir, $sshConfig)) {
        if (-not (Test-Path $path)) { continue }
        if ((& icacls $path 2>&1) -match 'BOSSINFO\\') {
            Write-TunnelLog "stale Intune-stamped ACL on $path, stripping BOSSINFO\* ACE"
            & icacls $path /inheritance:r | Out-Null
            if ($path -eq $sshDir) {
                & icacls $path /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "${me}:(OI)(CI)F" | Out-Null
            } else {
                & icacls $path /grant:r "*S-1-5-18:F" "*S-1-5-32-544:F" "${me}:F" | Out-Null
            }
        }
    }
}

$delay = $minDelay
while ($true) {
    Repair-SshConfigAcl
    Write-TunnelLog "starting tunnel ${SshHost}:localhost:$Port -> localhost:$Port"
    $started = Get-Date
    & $ssh -N -R "${Port}:localhost:${Port}" `
        -o BatchMode=yes `
        -o ServerAliveInterval=15 `
        -o ServerAliveCountMax=3 `
        -o ExitOnForwardFailure=yes `
        -o ConnectTimeout=10 `
        $SshHost 2>&1 | ForEach-Object { Write-TunnelLog "ssh: $_" }
    $exitCode = $LASTEXITCODE

    if ((Get-Date) - $started -ge $stableAfter) { $delay = $minDelay }
    Write-TunnelLog "ssh exited with $exitCode, retrying in ${delay}s"
    Start-Sleep -Seconds $delay
    $delay = [math]::Min($delay * 2, $MaxDelaySeconds)
}
