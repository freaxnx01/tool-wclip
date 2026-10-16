# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-16

### Added

- `client/wclip`: bash + curl client that copies text or HTML (file or stdin) to the
  Windows clipboard, with `--check` for reachability.
- `windows/Start-WclipReceiver.ps1`: localhost HTTP receiver that writes CF_HTML plus a
  plain-text fallback, guarded by a bearer token.
- `windows/Start-WclipTunnel.ps1`: self-healing `ssh -R` reverse tunnel with backoff.
- `windows/Install-Wclip.ps1`: registers both as hidden logon tasks and installs the client
  and token on the remote host.
- `tests/Wclip.Tests.ps1`: CF_HTML offset and plain-text fallback checks.
