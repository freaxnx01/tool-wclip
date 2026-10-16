# tool-wclip

Copy text or **HTML** to the Windows 11 clipboard from a shell on a remote Linux box: an SSH
session, a terminal multiplexer pane, or a Claude Code session running there.

```sh
wclip --html mail.html          # rich HTML (pastes formatted into Outlook/Word), plus a plain-text fallback
git log -5 --oneline | wclip    # plain text from stdin
wclip --check                   # is the Win11 side reachable?
```

## Why not OSC 52?

OSC 52 (the terminal escape most "remote clipboard" tools use) has three problems here:

- **Plain text only.** It has no `HTML Format`, so pasting into Outlook gives raw markup.

- **It only works from the terminal's own output stream.** Programs whose output is captured
  rather than written to the TTY can't use it, and that includes Claude Code's tool calls.

- **Multiplexers have to pass it through**, and not all of them do.

## How it works

```
Linux host                                    Win11 (outbound SSH, no open port)
wclip ──HTTP──► localhost:17790 ══ ssh -R ══► localhost:17790 ──► receiver ──► clipboard
                                                                  (CF_HTML + CF_UNICODETEXT)
```

- **`windows/Start-WclipReceiver.ps1`**: an HTTP listener on `localhost:17790` in your desktop
  session. It sets the clipboard with WinForms, writing a CF_HTML envelope (UTF-8 byte offsets)
  and a plain-text fallback for HTML.

- **`windows/Start-WclipTunnel.ps1`**: keeps `ssh -N -R 17790:localhost:17790 <host>` open with
  backoff, so `localhost:17790` on the Linux host leads to the receiver. The connection goes
  out from Win11, so no inbound port is opened on the workstation.

- **`client/wclip`**: a bash + curl client. It sends with a bearer token, and the receiver
  rejects anything without it. Without the token, any process on the shared host could
  rewrite your clipboard, and a swapped clipboard is a paste-hijack vector.

The receiver logs only metadata (format, size, status), never content. Under **WSL2 mirrored
networking** the client also works from WSL2 directly, with no tunnel needed.

## Install

Prerequisites:

- **Win11:** PowerShell 7, native OpenSSH, and key-based `ssh <host>` working without a
  prompt.

- **Linux host:** `bash` and `curl`.

```powershell
cd windows
pwsh -NoProfile -File .\Install-Wclip.ps1 -SshHost myhost -InstallClient
```

This:

1. Registers two hidden per-user logon tasks, `\Custom\wclip receiver` and
   `\Custom\wclip tunnel <host>`, and starts them.

2. Creates the token at `%LOCALAPPDATA%\wclip\token` on first start.

3. With `-InstallClient`, copies `client/wclip` to `~/.local/bin/wclip` and the token to
   `~/.config/wclip/token` (mode 600) on the host. Both go over ssh stdin, so the token never
   appears on a command line.

Re-run the same command after pulling changes; it stops the old instances first. To remove
everything on the Windows side:

```powershell
pwsh -NoProfile -File .\Install-Wclip.ps1 -Unregister
```

The tasks run straight from this checkout, so keep the clone where it is, or re-run install
after moving it.

### Check SSH first

The tunnel uses **native Windows OpenSSH** (`C:\Windows\System32\OpenSSH\ssh.exe`), not a WSL
`ssh`. Native ssh has to log in to the host on its own, without a prompt:

```powershell
& C:\Windows\System32\OpenSSH\ssh.exe -o BatchMode=yes <host> true
```

If your hosts only accept certificates that live in WSL2 (opkssh, a CA-signed cert routed through
an `ssh.bat` shim), native ssh doesn't have them. Add a plain key for that host to `~\.ssh` first.

### More than one host (e.g. a homelab)

Run the installer again with another `-SshHost`:

```powershell
pwsh -NoProfile -File .\Install-Wclip.ps1 -SshHost homelab-host -InstallClient
```

Each host gets its own tunnel task (`\Custom\wclip tunnel <host>`). The receiver and the token are
shared, and tunnels to other hosts keep running.

### A second Windows machine

Clone this repo there and run the installer on that machine:

```powershell
git clone https://github.com/freaxnx01/tool-wclip
cd tool-wclip\windows
pwsh -NoProfile -File .\Install-Wclip.ps1 -SshHost homelab-host -InstallClient
```

It gets its own receiver and token. `-InstallClient` overwrites the host's token file, so the
host's client then talks to the machine that installed last.

If **two Windows machines tunnel into the same host**, they compete for the remote port. The
second tunnel logs `remote port forwarding failed` and keeps retrying. Give one machine its own
port, e.g. `-Port 17791`, and set `WCLIP_PORT=17791` on the host for the user who should reach it.

## Configuration

| What | Where | Default |
|---|---|---|
| Target host(s) | `Install-Wclip.ps1 -SshHost <host>`, once per host | none (required) |
| Port | `-Port` on Windows, `WCLIP_PORT` on Linux. The two must match. | `17790` |
| Token | `WCLIP_TOKEN` env var, or the token file | `~/.config/wclip/token` (Linux), `%LOCALAPPDATA%\wclip\token` (Windows) |
| Max size | `Start-WclipReceiver.ps1 -MaxBytes`. The installer doesn't expose it, so changing it means editing the task arguments. | 4 MB |

Fixed:

- The receiver binds only to `localhost`, on purpose.

- Tasks go in the `\Custom\` folder.

- The tunnel uses native `C:\Windows\System32\OpenSSH\ssh.exe`.

## Client reference

```
wclip [--html|--text] [FILE]   FILE or stdin; *.html/*.htm default to --html
wclip --check                  receiver reachable?
```

| Setting | Default | |
|---|---|---|
| `WCLIP_PORT` | `17790` | Must match `-Port` on the Windows side. |
| `WCLIP_TOKEN` | — | Overrides the token file. |
| token file | `${XDG_CONFIG_HOME:-~/.config}/wclip/token` | Copy of `%LOCALAPPDATA%\wclip\token`. |

Exit code is non-zero, with a message on stderr, when the receiver is unreachable (no tunnel,
VPN down), the token is wrong (401), or the content is over 4 MB (413).

## Using it from Claude Code

Add a line like this to the host's `~/.claude/CLAUDE.md` (or a shared partial):

```markdown
On this host, copy to the Windows clipboard with `wclip` (`wclip --html file.html` for
Outlook-ready HTML, `… | wclip` for text). `clip.exe`/`pbcopy`/`wl-copy` don't exist here.
```

## Troubleshooting

Logs are in `%LOCALAPPDATA%\wclip\`: `receiver.log` and `tunnel.log`.

- **`no receiver on http://localhost:17790`**: the tunnel is down (VPN off, host unreachable)
  or the receiver isn't running. Check `tunnel.log`, and run
  `Get-ScheduledTask -TaskPath '\Custom\' -TaskName 'wclip*'`.

- **`remote port forwarding failed for listen port 17790`** in `tunnel.log`: an older session
  still holds the port on the host. The tunnel retries until sshd releases it. If an orphaned
  local `ssh.exe` is the culprit, `Install-Wclip.ps1 -Unregister` stops it.

- **`Bad owner or permissions` on `~\.ssh\config`**: on Intune-managed machines a logon task
  re-stamps an Entra ID ACE onto `~\.ssh`. The tunnel script strips it before each attempt.

- **400 Bad Request**: the client must use `http://localhost:…`, not `127.0.0.1`, because
  http.sys matches the Host header against the registered prefix.

## Tests

```powershell
pwsh -NoProfile -File tests/Wclip.Tests.ps1
```

These check the CF_HTML byte offsets (including non-ASCII) and the plain-text fallback.

## License

MIT
