# Stopping model, implementation, and verification

## Summary

The main window has intentionally simple suite-wide semantics:

- **Start** starts every installed Corplink component that is not disabled by macOS or organization policy. Missing legacy jobs are skipped, and an installed CorpLink or SealSuite client app is launched when no legacy client LaunchAgent exists. It does not use the pre-stop state as its scope.
- **Stop** stops every known Corplink launchd job and matching process without deleting the vendor's files.
- The Components page provides individual controls and diagnostics when needed.

The UI distinguishes a clean stop from a runtime stop that leaves a macOS System Extension enabled. On the Mac audited on 2026-08-23, macOS 26.6.2 with CorpLink 3.3.15 installed at least these independent jobs:

| launchd label | Purpose or executable | Included in suite Stop |
| --- | --- | --- |
| `com.volcengine.corplink.service` | Main `corplink-service` connection service | Yes |
| `com.volcengine.corplink.systemextension` | Firewall, EDR, EDLP, AV, and device protection | Yes |
| `com.corplink.networkmonitor` | `NetworkMonitor` | Yes |
| `com.corplink.data_forwarder` | Policy data forwarding | Yes |
| `com.corplink.mdm.policy` | MDM policy agent | Yes |
| `com.volcengine.corplink.agent` | `CorplinkNe` network extension agent | Yes |
| `com.corplink.appblocker` | Application control | Yes |
| `CorpLink` | Per-user client login task | Yes |

## Why killing processes is not enough

Several vendor jobs use `KeepAlive=true`. Under `launchd.plist(5)`, launchd may immediately relaunch a process after `kill` or `launchctl stop`. Corplink Control therefore removes the job from its exact launchd domain with `launchctl bootout` before it handles any orphan process.

`com.corplink.networkmonitor` also uses `LaunchOnlyOnce=true`. Live testing showed that after the old job was removed with `bootout`, registering the unchanged original plist with `bootstrap` created a new launchd job instance and ran it again. Corplink Control therefore does not edit `LaunchOnlyOnce` and does not run the vendor binary directly. It re-registers the original plist and verifies both the job and its PID. If verification fails on another macOS or CorpLink version, restarting the Mac is the safe fallback.

The vendor's `/usr/local/corplink/uninstall.sh` removes extensions, jobs, and files. That is an uninstall workflow and is deliberately outside the reversible on/off semantics of this app.

## What Stop does

1. Requests an active VPN disconnect through `corplink-cli vpn disconnect`.
2. Requests an active Secure Web Gateway disconnect through `corplink-cli swg disconnect`.
3. Saves recovery data needed for the client login plist, without using that snapshot to restrict the next suite-wide Start.
4. Stops user-level client, agent, and application-control jobs before system-level connection, policy, monitoring, and protection jobs.
5. Uses `launchctl bootout` with each job's exact `system` or `gui/<uid>` domain.
6. If a process remains after its job is unloaded, sends `SIGTERM`, waits two seconds, then uses `SIGKILL` only for a still-matching orphan.
7. Temporarily removes only the `schg` or `uchg` flags actually present on a plist and restores the identical flag set after the operation.
8. Observes the machine for five seconds. Any known job or process that returns makes the operation fail.
9. Reports known active Corplink System Extensions as a warning. The app does not uninstall them because that would change a reversible stop into an uninstall.

A suite stop is reported as clean only when all installed known jobs are unloaded, their matching processes are absent, matching Finder Sync or SealSuite auxiliary processes are absent, and no known Corplink System Extension is active. If jobs and processes are gone but an extension remains enabled, the operation succeeds as a **runtime stop with a warning**. Plists, application files, and System Extensions remain because Stop is not Uninstall.

## What Start does

Start processes all installed and non-disabled components in dependency order: system protection, Network Monitor, connection service, policy tasks, user agents, and client. A job counts as installed when its plist, loaded job, matching process, or pending recovery record exists; the legacy client LaunchAgent specifically requires plist, loaded-job, or recovery evidence because the client App is tracked separately. Missing legacy jobs are skipped and are not included in the installed-job total. It uses modern `launchctl bootstrap`; an already-loaded job can be restarted with `kickstart -k`. Jobs disabled by macOS or organization policy are skipped and are never force-enabled.

Each resident job must be loaded and have a matching process before the helper reports success. Network Monitor is registered from its unchanged original plist. The CorpLink client may recreate its per-user LaunchAgent, so the helper preserves and restores the original plist bytes, ownership, and mode where necessary. On installations without that legacy LaunchAgent, Start launches an installed `/Applications/CorpLink.app` or `/Applications/SealSuite.app` in the console user's GUI session and verifies its process instead of fabricating a vendor plist.

## Status and audit rules

The app reads launchd state and matches executable paths rather than relying on a button's last action. For the main service, “stopped” requires both of these conditions:

- `launchctl print system/com.volcengine.corplink.service` reports no job.
- No process exactly matches `/usr/local/corplink/corplink-service`.

VPN and SWG can become unavailable after the main service stops because their local status endpoint exits with the service. That is expected and is not evidence of a remaining connection.

Run the read-only audit from the repository root:

```bash
./scripts/audit-stop.sh
```

Its exit codes are:

| Code | Meaning |
| --- | --- |
| `0` | At least part of the suite is running and resident job/process state is consistent |
| `3` | No known job, process, auxiliary process, or active known extension remains |
| `1` | A resident job and its expected process disagree |

## Live verification on 2026-08-23

### Full Start and Network Monitor restart, version 1.4.0

Environment: macOS 26.6.2, CorpLink 3.3.15, Corplink Control 1.4.0. Before Start, both the main service and Network Monitor were unloaded, and only Network Monitor remained in the recovery snapshot.

| Check | Observed result |
| --- | --- |
| Start scope | Started all installed components that were not disabled by policy; did not restore only the old subset |
| Initial result | 7 of 8 jobs loaded; MDM was policy-disabled and was not overridden |
| Main service | `system/com.volcengine.corplink.service` was running as PID `73517`, with `runs=1` and no exit |
| Network Monitor | The unchanged original plist successfully bootstrapped a new running job as PID `73495`; `launch only once` remained present |
| Stability | Both PIDs were unchanged after 25 seconds; both jobs still showed `runs=1` and no exit |
| Recovery state | Cleared after successful verification, with no false pending-recovery state |
| VPN and SWG | Both reported disconnected; the status endpoint was queryable again |
| Network configuration | System proxy, DNS, and normalized IPv4 route hashes were unchanged before and after the delay |
| Delayed MDM policy | About two minutes later, logs showed `corplink-service` enabling MDM itself; MDM then ran stably as PID `74537`, producing 8 of 8 loaded jobs. Corplink Control did not perform that enable operation |

A separate temporary, network-neutral `LaunchOnlyOnce` user job verified the same macOS behavior: after the first instance ran and exited, the same unchanged plist could be bootstrapped as a new job and executed again. The temporary job and files were removed afterward.

### Full Stop and recovery, version 1.3.0

Two complete **Stop > delayed audit > restore previous state** cycles were run on the same macOS and CorpLink versions.

| Check | Observed result |
| --- | --- |
| Baseline | 6 of 8 jobs loaded and 12 known related processes; MDM was disabled by policy and the main service was already stopped |
| After Stop | 0 of 8 jobs loaded, 0 known related processes, helper exit code `3` |
| Relaunch observation | Built-in five-second watch passed; additional checks after 8 and 20 seconds remained at 0 of 8 and 0 processes |
| System Extensions | No known Corplink identifier was `activated enabled` |
| Plist protection | All three plists that originally had `schg` still had `schg` after Stop |
| Network configuration | DNS, system proxy, normalized IPv4 routes, and IPv6 routes returned to the baseline; there were no IPv4 `utun` routes |
| Restore result | Protection, forwarding, network agent, application control, and client returned; the originally stopped connection service and policy-disabled MDM were not enabled |
| Client LaunchAgent | Saved as original bytes and restored as a valid plist owned by `sunyi:staff` with mode `0644`; it still existed on delayed recheck |

The first recovery cycle exposed that the CorpLink client could delete its old user LaunchAgent after launch. Version 1.3.0 added byte-for-byte snapshot restoration plus ownership and permission repair, and the second cycle verified the fix.

### Main connection service Stop, version 1.2.0

A real **start > stop > delayed recheck** cycle confirmed that the main launchd job and exact-path process were both present after Start and both absent after Stop. The built-in five-second watch and a later recheck showed no relaunch. The original `schg` flag was restored. No known Corplink System Extension was active, DNS and system proxy hashes matched the baseline, and there were no IPv4 `utun` routes.

Independent protection, monitoring, network-agent, and application-control jobs remained running in this older connection-only test, which is why the current main window now uses complete-suite Start and Stop semantics.

## Boundaries and version sensitivity

- A `utun` interface is not Corplink-specific evidence; Tailscale, other VPNs, and macOS services can create one.
- Static Finder Sync registration does not prove that its extension process is running.
- The app checks known vendor extension identifiers and processes but does not delete VPN configurations, routes, or DNS settings. The vendor CLI is expected to disconnect active VPN and SWG sessions first.
- Enterprise MDM, a CorpLink update, or organization policy may load or disable jobs after an operation. The current live status is always authoritative.
- Component labels and paths were audited against CorpLink 3.3.15. A vendor update that changes them requires a new audit.
- Live results above establish behavior on the tested Mac and versions; they are evidence, not a universal guarantee for every organization configuration.

## References

- Local macOS manuals: `man launchctl` and `man launchd.plist`.
- [Apple: Creating Launch Daemons and Agents](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html)
- [Apple: System extensions in macOS](https://support.apple.com/guide/deployment/system-extensions-depa5fb8376f/web)
- CorpLink 3.3.15 bundled `corplink-cli --help`, `vpn disconnect --help`, `swg disconnect --help`, and `/usr/local/corplink/uninstall.sh`.
- [Volcengine Corplink product page](https://www.volcengine.com/product/feilian)
