---
name: configure-codex-clash-proxy
description: Use when a Windows Codex desktop or CLI client must use a local Clash HTTP/Mixed proxy such as 127.0.0.1:7890 without TUN, including diagnosis, persistent setup, verification, or rollback.
---

# Configure Codex Clash Proxy

Route Codex through Clash by combining the Windows current-user system proxy with Codex's `respect_system_proxy` feature. Do not enable TUN or change Clash nodes, subscriptions, routing rules, WinHTTP, certificates, DNS, firewall, or machine-wide policy.

## Diagnose

Confirm the computer is Windows and Clash is already running. Resolve this skill's directory, then run the helper without `-Apply`:

```powershell
pwsh -NoProfile -File <skill-dir>\scripts\configure.ps1 -ProxyHost 127.0.0.1 -ProxyPort 7890
```

Use the user's host and port when specified. The dry run checks the listener, Codex config, intended feature setting, and current-user proxy state without persistent mutation. If the port is unreachable or TOML is ambiguous, report the exact failure and stop.

## Apply

Persistent changes require explicit user authorization. A direct instruction to configure or apply the proxy is sufficient; a diagnosis-only request is not. Immediately before mutation, state that the operation will:

- back up the current Codex config and WinINET proxy values;
- enable `features.respect_system_proxy`;
- enable the current-user system proxy at the requested address;
- leave TUN disabled and leave Clash configuration untouched.

Then run:

```powershell
pwsh -NoProfile -File <skill-dir>\scripts\configure.ps1 -ProxyHost 127.0.0.1 -ProxyPort 7890 -Apply
```

If registry or Codex-home writes are sandbox-blocked, request approval for that exact command. Do not substitute persistent `HTTP_PROXY`, `HTTPS_PROXY`, or `ALL_PROXY` environment variables; Codex sandboxes may inject their own proxy variables.

## Verify

Read the script result, confirm the listener remains reachable, and confirm WinINET `ProxyEnable=1`, `ProxyServer=host:port`, and `respect_system_proxy = true`. Run `codex doctor --json` when available. Treat sandbox-only TLS or certificate failures as unresolved evidence, not proof that the desktop client failed.

Tell the user to fully exit Codex, including tray/background processes, and restart it. A newly started chat is the final functional test.

## Roll Back

When the user explicitly requests rollback, run:

```powershell
pwsh -NoProfile -File <skill-dir>\scripts\rollback.ps1
```

The helper restores the most recent recorded Codex config and current-user proxy state. If backup state is missing or invalid, stop without guessing.


