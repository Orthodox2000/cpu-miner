# Script reference

All scripts live in `scripts/`. Most are PowerShell 5.1 compatible and are
designed to be launched with:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\<name>.ps1
```

## One-click entry point

| File | Purpose | Notes |
|---|---|---|
| `RUN.cmd` | The drop-and-play launcher | Double-click it. It calls `scripts\Run.ps1`, keeps the console open on failure, and needs no commands typed. |
| `UNATTENDED.cmd` | One-time unattended-boot setup | Calls `Run.ps1 -Unattended`. Adds auto-login, RustDesk startup and no-sleep, all scoped to this PC. Add `-BlankPassword` for a passwordless account. |
| `Run.ps1` | Logic behind both launchers | Detects an existing install; if missing, it invokes `Install.ps1` once with UAC (passing the original user and Startup folder), waits for the heat sensor, starts XMRig, then opens `Menu.ps1`. `-Unattended` / `-BlankPassword` are forwarded to the installer. Re-running it downloads nothing. |

## Core control

| Script | Purpose | How it is started | Notes |
|---|---|---|---|
| `Miner.ps1` | `start`, `stop`, `restart`, `status` for XMRig | Manually, or dot-sourced by other scripts | Validates the wallet, checks temperature, writes `state\was-active`, rotates nothing (log is appended). `start` refuses to mine if temperature is unreadable and `TEMP_REQUIRED=true`. |
| `Menu.ps1` | Interactive control panel (`S` start, `X` stop, `R` restart, `Q` quit) | `ResumeOnLogin.ps1`, or manually | Shows temperature, guard limits, 45-minute countdown, earnings, pool and shortened wallet. Closing it does not stop mining. |
| `ResumeOnLogin.ps1` | Opens the control window at login | Startup shortcut `LTC Miner.lnk` | With `AUTO_START_ON_LOGIN=true` (default) it waits for the heat sensor and starts mining at every login. If set to `false`, it only starts when `state\was-active` exists. Idempotent with the supervisor. |

## Background safety

| Script | Purpose | How it is started | Notes |
|---|---|---|---|
| `Supervisor.ps1` | Single always-on loop: watchdog + heat guard + 45-minute restart | Scheduled task `CpuMiner-Supervisor` at logon (hidden, normal user) | Checks temperature every `TEMP_SECONDS` (60), process every `WATCHDOG_SECONDS` (180), restart every `RESTART_MINUTES` (45). Starts at logon when `AUTO_START_ON_LOGIN=true` or `was-active` exists. |
| `Start-Lhm.ps1` | Starts LibreHardwareMonitor minimized | Scheduled task `CpuMiner-LHM` at logon (elevated) | LHM's config enables its local web server on `127.0.0.1:8085` only. Required for temperature readings. |
| `Common.ps1` | Shared helpers | Dot-sourced | Paths, config parser, logging, mutex lock, process lookup, LHM JSON reader, `Wait-ForTemperature`, cooling state, restart countdown, runtime-state cleanup. |
| `Validate-Wallet.ps1` | Address validation | Dot-sourced | Full LTC validation (legacy Base58 checksum and Bech32 `ltc1...`) plus SOL Base58 length check. |

## Reporting / maintenance

| Script | Purpose | How it is started | Notes |
|---|---|---|---|
| `Earnings.ps1` | Unmineable balance and payout progress | Manually, or called by `Menu.ps1`/`HealthCheck.ps1` | Caches for 5 minutes in `state\earnings.cache`. `-Raw` gives machine fields; `-Refresh` forces network. |
| `HealthCheck.ps1` | Read-only verification of the whole setup | Manually | Checks config, wallet, binaries, process, temperature source, tasks, shortcut, firewall rules and earnings. Exits 1 on any critical failure. |
| `Install.ps1` | One-time / repair installer | `Run.ps1` with UAC, or manually elevated | Idempotent: skips downloads when verified binaries already exist. Copies config, sets ACLs, checksum-verifies XMRig 6.26.0 and LHM 0.9.6, writes LHM config, creates firewall rules, tasks and shortcut. `-Owner` / `-StartupFolder` keep setup on the launching account after UAC; `-Wallet` overrides the committed address. `-Unattended` adds local auto-login, RustDesk startup and no-sleep; `-BlankPassword` attempts passwordless auto-login. |
| `Uninstall.ps1` | Removes tasks, shortcut, firewall rules and stops mining | Manually, elevated | `-RemoveData` also deletes `%ProgramData%\CpuMiner`. `-RemoveUnattended` also removes auto-login and the RustDesk startup shortcut. |

## State and log files

All under `%ProgramData%\CpuMiner`:

| Path | Written by | Meaning |
|---|---|---|
| `config.env` | `Install.ps1` / user | Effective configuration, including wallet |
| `state\was-active` | `Miner.ps1` | Persistent marker used as fallback when `AUTO_START_ON_LOGIN=false` |
| `state\xmrig.pid` | `Miner.ps1` | Last miner PID (informational) |
| `state\cooling.state` | `Supervisor.ps1` | `normal` or `cooling` with timestamp/temperature |
| `state\next-restart.txt` | `Common.ps1` | Epoch + interval for the panel countdown |
| `state\earnings.cache` | `Earnings.ps1` | Cached Unmineable response |
| `logs\*.log` | all scripts | `events`, `supervisor`, `temp`, `watchdog`, `auto-restart`, `earnings`, `lhm`, `stdout`, `stderr`, `miner` |

## Safety rules encoded in the scripts

- Only XMRig is restarted. There are no reboot, shutdown, poweroff or halt commands.
- A manual `X` / `Miner.ps1 stop` removes `was-active`, so the supervisor, watchdog and heat guard stay idle until the next login. With `AUTO_START_ON_LOGIN=true`, the next login starts mining again.
- Heat guard stops at `STOP_TEMP` (75 °C) and resumes at `RESUME_TEMP` (65 °C).
- If LHM cannot be read, `TEMP_REQUIRED=true` makes `Start-Miner` fail and the supervisor stop any running miner.
- Firewall rules restrict XMRig to pool TLS (TCP 443) and DNS (UDP 53).
- The wallet address is public and committed in `config\wallet.txt`; private keys are never stored here.
- Unattended setup touches only this Windows PC and the launching user. Auto-login skips the local sign-in prompt, so use it only on a physically secure machine.
