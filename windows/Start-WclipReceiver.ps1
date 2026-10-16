#requires -Version 7
<#
.SYNOPSIS
    Receives clipboard content over HTTP on localhost and puts it on the Windows clipboard.

.DESCRIPTION
    Listens on http://localhost:<Port>/clip. The `wclip` client on a remote Linux host reaches
    it through an SSH reverse tunnel (Start-WclipTunnel.ps1); under WSL2 mirrored networking
    it reaches it directly.

        POST /clip   Content-Type: text/plain | text/html (UTF-8)
                     Authorization: Bearer <token>
        GET  /health → "ok" (no auth, no clipboard access)

    The token lives in %LOCALAPPDATA%\wclip\token and is created on first start. Without it,
    any process on the remote host could rewrite this clipboard, and a swapped clipboard is a
    paste-hijack vector, so requests without the right token are rejected.

    Only metadata (format, size, status) is logged, never content.

.NOTES
    Must run in the interactive user session on an STA thread (pwsh's default): a service or
    "run whether user is logged on or not" task has no clipboard. Install-Wclip.ps1 registers
    it as a hidden logon task.

    http.sys only matches the Host header against the registered prefix, so the client must
    use http://localhost:<port>, not http://127.0.0.1:<port> (400 Bad Request otherwise).

    If you hit a blocker running this, fix it here and update this header so the next run
    does not have to re-derive it.
#>
[CmdletBinding()]
param(
    [int]$Port = 17790,
    [int]$MaxBytes = 4MB
)

# Stop on every error: a non-terminating failure while loading the token used to leave
# $token empty, and an empty token matches an empty Authorization header.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Wclip.psm1') -Force

$stateDir = Join-Path $env:LOCALAPPDATA 'wclip'
$log = Join-Path $stateDir 'receiver.log'
$tokenFile = Join-Path $stateDir 'token'
New-Item -ItemType Directory -Force $stateDir | Out-Null

function Write-WclipLog {
    param([string]$Message)
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log "$log.1" -Force }
    Add-Content $log "$(Get-Date -Format s) $Message"
}

if (-not (Test-Path $tokenFile)) {
    $bytes = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
    # Named parameters on purpose: pwsh 7.6 bound `Set-Content -NoNewline $path $value`
    # as Path=$value, writing a file *named* after the token into the current directory.
    Set-Content -Path $tokenFile -Value ([Convert]::ToHexString($bytes).ToLowerInvariant()) -NoNewline
    Write-WclipLog "created token $tokenFile"
}
$token = (Get-Content -Raw -Path $tokenFile).Trim()
if ($token.Length -lt 32) {
    Write-WclipLog "refusing to start: token in $tokenFile is shorter than 32 characters"
    throw "token in $tokenFile is shorter than 32 characters"
}

function Send-Reply {
    param($Context, [int]$Status, [string]$Body)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes("$Body`n")
    $Context.Response.StatusCode = $Status
    $Context.Response.ContentType = 'text/plain; charset=utf-8'
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
try {
    $listener.Start()
} catch {
    Write-WclipLog "cannot listen on localhost:${Port}: $($_.Exception.Message)"
    throw
}
Write-WclipLog "listening on http://localhost:$Port/"

try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $req = $ctx.Request
        try {
            if ($req.HttpMethod -eq 'GET' -and $req.Url.AbsolutePath -eq '/health') {
                Send-Reply $ctx 200 'ok'; continue
            }
            if ($req.Url.AbsolutePath -ne '/clip') { Send-Reply $ctx 404 'not found'; continue }
            if ($req.HttpMethod -ne 'POST') { Send-Reply $ctx 405 'POST only'; continue }

            $auth = $req.Headers['Authorization']
            $given = if ($auth -and $auth.StartsWith('Bearer ')) { $auth.Substring(7).Trim() } else { '' }
            $ok = [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals(
                [System.Text.Encoding]::UTF8.GetBytes($given), [System.Text.Encoding]::UTF8.GetBytes($token))
            if (-not $ok) {
                Write-WclipLog "401 bad or missing token"
                Send-Reply $ctx 401 'bad or missing token'; continue
            }

            $type = "$($req.ContentType)".Split(';')[0].Trim().ToLowerInvariant()
            $format = switch ($type) { 'text/html' { 'html' } 'text/plain' { 'text' } '' { 'text' } default { $null } }
            if (-not $format) { Send-Reply $ctx 415 "unsupported Content-Type '$type' (text/plain or text/html)"; continue }
            if ($req.ContentLength64 -gt $MaxBytes) { Send-Reply $ctx 413 "too large (max $MaxBytes bytes)"; continue }

            # Read at most MaxBytes+1 so a chunked body without Content-Length is capped too.
            $buffer = [System.IO.MemoryStream]::new()
            $chunk = [byte[]]::new(64KB)
            while (($n = $req.InputStream.Read($chunk, 0, $chunk.Length)) -gt 0) {
                $buffer.Write($chunk, 0, $n)
                if ($buffer.Length -gt $MaxBytes) { break }
            }
            if ($buffer.Length -gt $MaxBytes) { Send-Reply $ctx 413 "too large (max $MaxBytes bytes)"; continue }

            $content = [System.Text.UTF8Encoding]::new($false).GetString($buffer.ToArray())
            Set-WclipClipboard -Content $content -Format $format
            Write-WclipLog "200 $format $($buffer.Length) bytes"
            Send-Reply $ctx 200 "ok $format $($buffer.Length) bytes"
        } catch {
            Write-WclipLog "500 $($_.Exception.Message)"
            try { Send-Reply $ctx 500 $_.Exception.Message } catch { }
        }
    }
} finally {
    $listener.Close()
    Write-WclipLog 'stopped'
}
