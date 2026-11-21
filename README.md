# Windows CPU miner (Unmineable → LTC)

A Windows 10 port of the Linux `~/mining` setup. It mines RandomX with XMRig,
pays out as Litecoin through Unmineable, and keeps the same behaviour:

- start / stop / restart control window (`S`, `X`, `R`, `Q`)
- background mining that survives closing the window
- watchdog restart if XMRig dies
- **automatic restart every 45 minutes**
- start mining at every login by default (configurable fallback: resume only if it was active)
- conservative heat guard: **stop at 75 °C, resume at 65 °C**

Nothing in this repo restarts or shuts down the PC — only the miner process.

## Quick start (drop and play)

1. Copy this whole folder to the Windows 10 PC — anywhere (Desktop, Downloads,
   a USB stick, etc.).
2. Double-click **`RUN.cmd`**.
3. Approve the one-time administrator prompt.

That is all. The first run downloads XMRig and LibreHardwareMonitor, verifies
their SHA-256 checksums, installs the background tasks and firewall rules,
waits for the heat sensor, starts mining, and opens the control panel.

Later runs detect the existing install and go straight to mining — no repeated
downloads and, in the normal case, no administrator prompt. Everything is
visible: logs are in `%ProgramData%\CpuMiner\logs`.

Keep the folder after installation: the scheduled tasks launch its scripts.

See [docs/SCRIPTS.md](docs/SCRIPTS.md) for a description of every script and
state/log file.

## Unattended boot (this PC only)

If you want the PC to come up by itself when power returns:

1. In BIOS/UEFI set **Restore on AC Power Loss / AC Recovery = Power On**.
   Windows cannot change this firmware setting.
2. Double-click **`UNATTENDED.cmd`**. If the Windows account truly has no
   password, use `UNATTENDED.cmd -BlankPassword`.
3. It performs the normal install, then configures:
   - Windows auto-login for the account that launched it;
   - RustDesk service = Automatic plus a RustDesk Startup shortcut;
   - sleep and hibernate = Never on the current power plan.

Everything is scoped to this computer and this user. No domain or other PC is
changed.

Warnings:

- Skipping the sign-in prompt means anyone with physical access reaches the
  desktop. Only do this on a physically secure machine.
- Blank-password auto-login is unreliable on Windows 10; keeping a password is
  more reliable. The password is stored only in the local Windows registry.
- Set a permanent password **inside RustDesk** for unattended access. This repo
  never stores it.
- To revert, run `Uninstall.ps1 -RemoveUnattended`.

## Payout wallet

The committed LTC payout address is:

```text
ltc1qh8u0cpkuhk9rn5sz2dwe0j4hu8as52f6tuyml3
```

It is the single source of truth in `config/wallet.txt` and is read by
`Install.ps1` when no `-Wallet` override is supplied.

## Safety and security

- The LTC payout address is public and committed in `config/wallet.txt`. No
  private keys or secrets are stored here. `config/local.env` is optional and
  git-ignored for local overrides.
- Config/logs live under `%ProgramData%\CpuMiner` with ACLs restricted to your
  user and SYSTEM.
- On first install, XMRig and LibreHardwareMonitor are downloaded from their
  official GitHub releases and verified by SHA-256; later runs reuse them.
- XMRig runs as your normal user, not administrator.
- Windows Firewall is configured so XMRig may only reach the pool on TCP 443
  and DNS on UDP 53.
- LibreHardwareMonitor's web interface binds to `127.0.0.1` only.
- Fail-safe: if the CPU temperature cannot be read, mining is stopped rather
  than running unguarded (`TEMP_REQUIRED=true`).
- `--donate-level=0` and TLS pool connection are configured by default.

## Manual / advanced install

`RUN.cmd` already does all of this. Use the commands below only if you want to
install without starting mining, or repair an existing setup.

Open **PowerShell as Administrator** in the repo folder and run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install.ps1
```

Or with an explicit wallet:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Install.ps1 -Wallet 'LTC...'
```

The installer will:

- verify admin rights;
- create `%ProgramData%\CpuMiner\{state,logs}` with restricted ACLs;
- download and checksum-verify XMRig 6.26.0 and LibreHardwareMonitor 0.9.6 only
  if they are missing (verified cached copies are reused);
- enable LibreHardwareMonitor's local web server on `127.0.0.1:8085`;
- install firewall rules and two scheduled tasks:
  - `CpuMiner-Supervisor` (watchdog + heat guard + 45-minute restart),
  - `CpuMiner-LHM` (elevated temperature sensor);
- add an `LTC Miner` shortcut to your Startup folder.

Afterwards, double-click `RUN.cmd` to start mining and open the control panel.

## Control panel

At every GUI login a command window opens with:

| Key | Action |
|---|---|
| `S` | Start mining |
| `X` | Stop mining |
| `R` | Restart now |
| `Q` | Close the window (mining keeps running) |

It shows CPU temperature, heat-guard limits, the 45-minute restart countdown,
earnings, pool and a shortened payout address.

Headless commands:

```powershell
.\scripts\Miner.ps1 start
.\scripts\Miner.ps1 stop
.\scripts\Miner.ps1 restart
.\scripts\Miner.ps1 status
.\scripts\HealthCheck.ps1
.\scripts\Earnings.ps1
```

## What happens after a reboot

`AUTO_START_ON_LOGIN=true` by default, so mining and the 45-minute scheduler
start at every login. The `state\was-active` marker is still written when mining
starts and removed when it stops; it is used as a fallback.

If you set `AUTO_START_ON_LOGIN=false`, the old behaviour returns:

- marker exists → mining resumes;
- marker absent → the control window opens, stopped.

The scheduled tasks themselves are At-Log-On tasks, not boot-time services.
With `UNATTENDED.cmd`, Windows auto-login reaches that logon automatically.

## Heat control

LibreHardwareMonitor runs minimized with its local web server enabled. The
supervisor reads the CPU package temperature every 60 seconds:

- `>= 75 °C` → stop mining and set cooling state;
- `<= 65 °C` → start mining again;
- a manual `X` clears the marker so the guard will not resume mining;
- unreadable temperature → stop mining (fail-safe).

Change limits in `%ProgramData%\CpuMiner\config.env` and restart the supervisor
task (or log off/on).

## Logs and state

| Path | Contents |
|---|---|
| `%ProgramData%\CpuMiner\logs\miner.log` | XMRig output |
| `%ProgramData%\CpuMiner\logs\supervisor.log` | supervisor start/stop |
| `%ProgramData%\CpuMiner\logs\temp.log` | heat guard decisions |
| `%ProgramData%\CpuMiner\logs\watchdog.log` | crash restarts |
| `%ProgramData%\CpuMiner\logs\auto-restart.log` | 45-minute restarts |
| `%ProgramData%\CpuMiner\logs\events.log` | start/stop events |
| `%ProgramData%\CpuMiner\state\next-restart.txt` | countdown used by the panel |

## Change the restart interval / worker / coin

Edit `%ProgramData%\CpuMiner\config.env`:

```ini
RESTART_MINUTES=45
POOL_WORKER=HomePC
PAYOUT_COIN=LTC
WALLET=...
STOP_TEMP=75
RESUME_TEMP=65
AUTO_START_ON_LOGIN=true
```

The PowerShell validator supports LTC and SOL. For other coins, keep the Python
validator from the Linux setup available and extend `Validate-Wallet.ps1`.

## Uninstall

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\Uninstall.ps1
```

Add `-RemoveData` to also delete `%ProgramData%\CpuMiner`. Add
`-RemoveUnattended` to undo auto-login and the RustDesk startup shortcut.

## Notes

- Only run mining where you are authorized to. Home/employer network policies
  may prohibit it.
- The installer needs administrator rights once; daily mining and the control
  panel do not.
- XMRig 6.26.0 and LibreHardwareMonitor 0.9.6 are pinned so checksums stay
  meaningful. Update the version, URL and hash together when upgrading.
