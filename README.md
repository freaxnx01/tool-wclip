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

### More than one host

Each host gets its own tunnel task. Run the install again with another `-SshHost`. The receiver
and the token are shared.

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
