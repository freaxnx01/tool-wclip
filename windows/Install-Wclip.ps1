#requires -Version 7
<#
.SYNOPSIS
    Registers the wclip receiver and reverse tunnel as hidden per-user logon tasks, starts
    them, and (optionally) installs the client + token on the remote host.

.EXAMPLE
    pwsh -NoProfile -File .\Install-Wclip.ps1 -SshHost myhost -InstallClient
.EXAMPLE
    pwsh -NoProfile -File .\Install-Wclip.ps1 -Unregister
.NOTES
    Tasks: \Custom\wclip receiver and \Custom\wclip tunnel <host>. Interactive logon type,
    limited rights — the receiver needs the user's desktop session for the clipboard.

    -InstallClient copies client/wclip to ~/.local/bin/wclip on the host and the token to
    ~/.config/wclip/token (mode 600) over native ssh. The token goes through ssh stdin,
    never on a command line.

    If you hit a blocker running this, fix it here and update this header so the next run
    does not have to re-derive it.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)][string]$SshHost,
    [Parameter(ParameterSetName = 'Install')][int]$Port = 17790,
    [Parameter(ParameterSetName = 'Install')][switch]$InstallClient,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)][switch]$Unregister
)

$taskPath = '\Custom\'
$pwsh = (Get-Command pwsh).Source
$vbs = Join-Path $PSScriptRoot 'run-hidden.vbs'
$ssh = 'C:\Windows\System32\OpenSSH\ssh.exe'

function Stop-Wclip {
    param([switch]$Remove)
    Get-ScheduledTask -TaskPath $taskPath -ErrorAction SilentlyContinue |
        Where-Object TaskName -like 'wclip *' |
        ForEach-Object {
            Stop-ScheduledTask -TaskPath $taskPath -TaskName $_.TaskName -ErrorAction SilentlyContinue
            if ($Remove) {
                Unregister-ScheduledTask -TaskPath $taskPath -TaskName $_.TaskName -Confirm:$false
                Write-Host "removed $($_.TaskName)"
            }
        }
    # Stopping a task does not reliably end the hidden pwsh under wscript, and killing the
    # tunnel's pwsh orphans its ssh.exe, which keeps holding the remote port. Stop both, so a
    # reinstall really runs the new code (Register -Force leaves the old instance running).
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='ssh.exe'" |
        Where-Object { $_.CommandLine -match 'Start-Wclip(Receiver|Tunnel)\.ps1' -or
                       ($_.Name -eq 'ssh.exe' -and $_.CommandLine -match '-R \d+:localhost:\d+') } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "stopped $($_.Name) pid $($_.ProcessId)" }
}

if ($Unregister) { Stop-Wclip -Remove; return }
Stop-Wclip

function Register-HiddenTask {
    param([string]$Name, [string]$Script, [string]$ScriptArgs)
    $arguments = "//B //NoLogo `"$vbs`" `"$pwsh`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Script`" $ScriptArgs"
    $action = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\wscript.exe" -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskPath $taskPath -TaskName $Name -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskPath $taskPath -TaskName $Name
    Write-Host "registered + started $taskPath$Name"
}

Register-HiddenTask 'wclip receiver' (Join-Path $PSScriptRoot 'Start-WclipReceiver.ps1') "-Port $Port"
Register-HiddenTask "wclip tunnel $SshHost" (Join-Path $PSScriptRoot 'Start-WclipTunnel.ps1') "-SshHost $SshHost -Port $Port"

$tokenFile = Join-Path $env:LOCALAPPDATA 'wclip\token'
for ($i = 0; $i -lt 20 -and -not (Test-Path $tokenFile); $i++) { Start-Sleep -Milliseconds 250 }
if (-not (Test-Path $tokenFile)) { throw "receiver did not create $tokenFile — see $env:LOCALAPPDATA\wclip\receiver.log" }

if ($InstallClient) {
    $client = Join-Path (Split-Path $PSScriptRoot) 'client\wclip'
    # pwsh appends a CRLF when piping a string to a native exe (and a CRLF checkout would add
    # more), so the remote side strips every \r rather than trusting the bytes it gets.
    Get-Content -Raw $client |
        & $ssh -o BatchMode=yes $SshHost 'mkdir -p ~/.local/bin && tr -d "\r" > ~/.local/bin/wclip && chmod 755 ~/.local/bin/wclip'
    if ($LASTEXITCODE) { throw "copying the client to $SshHost failed" }
    Get-Content -Raw $tokenFile |
        & $ssh -o BatchMode=yes $SshHost 'umask 077 && mkdir -p ~/.config/wclip && tr -d "\r\n" > ~/.config/wclip/token'
    if ($LASTEXITCODE) { throw "copying the token to $SshHost failed" }
    Write-Host "installed ~/.local/bin/wclip and ~/.config/wclip/token on $SshHost"
}
