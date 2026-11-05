# WinSenior v6.5.0 — all-in-one toolbox, evidence-based

**Why.** Users download a separate (often paid, cracked or malware-laden) utility for every
maintenance job: driver updaters, uninstallers, RAM "cleaners". WinSenior should cover them
in one free tool that uses only official sources (Microsoft Update, winget, vendor sites) and
honest math instead of placebo numbers.

## Goals
1. **Drivers** — scan/install from Microsoft Update (WUA COM), GPU vendor guidance
   (NVIDIA/AMD/Intel official pages/apps), backup + restore of the driver store, hide a WU
   GPU driver so it does not overwrite the vendor one.
2. **Apps** — inventory (Win32 uninstall keys + Store packages), quiet uninstall (+ leftovers
   with a confidence score), updates and curated installs via winget.
3. **Smart memory** — reclaim RAM held by real leftovers (build daemons, WSL VM, orphaned
   Java/Node), triggered by measured memory pressure; never placebo working-set trimming.
4. **Disk** — reduced hiberfile, CompactOS, orphaned Windows Installer quarantine, WSL/Docker
   VHDX compaction; space-target planner; disk-full forecast.
5. **Evidence** — boot-time history from Diagnostics-Performance, before/after verdicts with
   robust statistics, defaults corrected where Microsoft docs contradict them.

## Non-goals / anti-goals
- No third-party download sites, no bundled vendor binaries, no unofficial driver databases.
- No "RAM booster" that empties working sets or the standby list by default (placebo/harmful:
  standby is cache, emptied working sets fault straight back).
- Never kill a process that is doing work (CPU > threshold, has a window, active build child).
- Never delete Windows Installer cache files outright (Microsoft: unrecoverable) — quarantine.

## Decisions (with sources)
| Area | Decision | Source |
|---|---|---|
| Stats | Mann–Whitney U, exact for n ≤ 20 w/o ties, else normal approx with tie + continuity correction; Hodges–Lehmann shift + rank CI; verdict needs p < 0.05 AND > margin; "Equivalent" when the CI sits inside ±margin; ≥ 4 runs/arm | scipy mannwhitneyu; BenchmarkDotNet TOST |
| Outliers | NIST modified Z = 0.6745(x−median)/MAD > 3.5 | NIST e-Handbook 1.3.5.17 |
| Forecast | Theil–Sen on segments split at upward jumps (> max(1 GB, 3·1.4826·MAD)); gross drop rate as worst case; ≥ 5 points over ≥ 7 days | Sen 1968; scikit-learn TheilSen |
| Boot | Event 100 BootTime/MainPathBootTime/BootPostBootTime (ms); skip BootIsRebootAfterInstall; 101–110 = degraders | eventlogxp, MS WDI CSP |
| Perf counters | locale-proof CIM `Win32_PerfFormattedData_PerfOS_Memory`; disk latency from `PerfRawData` deltas | MS Learn perf troubleshooting |
| Memory pressure | Available < 10 % RAM (and < 4 GB) or commit > 80 % → act; Available > 4 GB → never act | MS Learn troubleshoot-performance-problems |
| Hiberfile | `powercfg /h /type reduced` = 20 % RAM, keeps Fast Startup (full = 40 %) | MS Learn system-power-states |
| CompactOS | `compact /CompactOS:always`, 2.6–4.7 GB, undo `:never` | MS Learn compact-os |
| MSI orphans | union of `ProductsEx`/`PatchesEx` LocalPackage (elevated, all contexts); root .msi/.msp only; move to quarantine; abort if enumeration fails | MS missing-installer-cache; PatchCleaner |
| winget | CLI with `--accept-* --disable-interactivity`, parse by column position (output is localized), `winget export` JSON for inventory; not as SYSTEM | MS winget troubleshooting/returnCodes |
| GPU | vendor driver preferred for gaming; WU for everything else; hide WU GPU update via `IUpdate.IsHidden` | MS wuapi |

## Pieces
- `WinSenior.Stats.ps1` — pure math (done first, Pester-pinned).
- `WinSenior.Memory.ps1` — pressure probe, leftover classifier (pure rules over process
  snapshots), graceful stop table, opt-in low-priority standby purge, pool-leak alarm,
  per-user scheduled auto mode.
- `WinSenior.Drivers.ps1` — WUA scan/install with timeout, GPU detection, pnputil backup/restore.
- `WinSenior.Apps.ps1` — inventory, uninstall, leftover scoring, winget upgrade/install catalog.
- Cleanup registry: `hiber-reduced`, `compactos`, `msi-orphans`, `vhdx-compact`.
- Repair registry: boot history/degraders, commit exhaustion, disk latency, CPU throttling.
- `WinSenior.ps1` menu + CLI switches. GUI pages follow once the v6.4.0 UX branch lands
  (a parallel session owns `WinSenior.Gui.ps1`).

## Left to the builder
Exact cost weights for the planner, catalog contents, thresholds' sustained-time windows.
