# Privileged control

Corplink Control 1.6.1 supports two authorization modes for Start and Stop actions. Status inspection remains unprivileged in both modes.

## Modes

### Administrator prompt

This is the default and fallback. Each control action runs the bundled helper through the standard macOS administrator authorization dialog. It is used when passwordless control is off, has not yet been approved, the current console account is not an administrator, or an XPC request can be proven not to have been submitted.

### Passwordless control

The user must explicitly enable **Settings > Privileged control > Passwordless start and stop**. Every transition from off to on requires the foreground account to be a member of macOS's administrator group and creates a fresh `LocalAuthentication` device-owner authentication context. This adds no custom authorization-database right or persistent credential. The app then registers the embedded LaunchDaemon with `SMAppService`. macOS also requires an administrator to approve it under **System Settings > General > Login Items & Extensions** before the daemon can run. Once enabled, the current foreground administrator account can send fixed control requests over privileged XPC instead of requesting a password for every action. Other local accounts do not inherit passwordless control from that system-wide approval.

The app must be installed directly in `/Applications` before it can register the daemon. A copy launched from Downloads, a build directory, or another location continues to use the administrator-prompt fallback.

## Upgrade migration

The app records a non-secret registration fingerprint made from the bundle build number and the exact designated requirements of both the app and embedded helper. An official upgrade changes the build number; an ad-hoc local rebuild can change either cdhash even when the build number stays the same. Any such change marks an already registered helper as requiring migration, and the app refuses to select XPC until the fingerprint matches the current bundle.

Before the next passwordless control action, the foreground administrator completes a fresh device-owner authentication. The app then awaits `SMAppService.unregister()`, requires both fresh service-status reads to remain unregistered and `launchctl print` to confirm that the old system job is absent, clears the old fingerprint, and registers the current embedded helper with a new service object. Waiting for the launchd job as well as the API status prevents a rapid ad-hoc upgrade from reusing stale Background Task Management launch constraints. Cancelling authentication sends no Start or Stop request. If migration fails, the old helper is not trusted and the requested action uses the administrator-password path. If macOS requires renewed Background Item approval, the app records the current helper but continues to use password authorization until approval is complete.

Every passwordless connection performs a read-only XPC probe before sending a control action. The probe returns the protocol version and the app build captured by the helper at daemon launch. The app accepts it only when both match the running app. A probe failure occurs before the mutating request is submitted, so the app can safely use the administrator-password path once; an interruption after `perform` is submitted remains indeterminate and is never replayed automatically.

## Bundle layout

The build contains both service files inside the signed app bundle:

```text
Corplink Control.app/
  Contents/
    Resources/corplink-root-helper
    Library/LaunchDaemons/local.sunyi.corplink-control.root-helper.plist
```

`SMAppService` registers these embedded files. Corplink Control does not copy its helper into `/Library/PrivilegedHelperTools` or its plist into `/Library/LaunchDaemons`.

## Security model

The helper is a root security boundary and follows these restrictions:

- Both XPC peers validate the other peer against the exact designated code requirement extracted from the signed app bundle.
- The signature is strictly validated first, including all architectures, nested code, and sealed resources. Validation failure is fail-closed.
- Local ad-hoc builds therefore bind to their exact cdhash. Developer ID builds use the stable certificate-and-identifier designated requirement.
- The daemon accepts only a caller that is both the effective user currently logged in at the console and a member of macOS's administrator group (GID 80). The app performs the same administrator check before choosing XPC, but the daemon independently enforces it as the security boundary.
- XPC exposes one method whose action must match an exact allowlist. It does not accept executable paths, shell fragments, environment variables other than the UI language, or arbitrary component identifiers.
- Privileged operations are serialized to prevent overlapping Start and Stop mutations.
- Approved actions run inside the already validated root process. The daemon never re-executes a helper from a path that an unprivileged process might replace.
- The administrator-prompt fallback applies the same action allowlist and shell-quotes every fixed argument.
- If helper validation or XPC setup fails before the app submits a request, the app safely falls back to the administrator-password prompt. After submission, a connection interruption is treated as an indeterminate result and is never repeated automatically; the UI tells the user to refresh status and explicitly choose a password-mode retry. This prevents duplicate Start or Stop mutations.
- Fixed external commands have execution deadlines, and the app independently bounds status refreshes and XPC reply waits. A non-responsive vendor CLI, `launchctl` invocation, or helper cannot leave the UI busy indefinitely. A timed-out post-submission XPC request remains indeterminate, so the app preserves the last displayed state and never retries the privileged mutation automatically.
- Child-process output is captured in owner-only temporary files that are unlinked immediately after creation. This avoids pipe-buffer deadlocks without leaving named capture files behind.
- XPC is selected only when the persisted build-and-signature fingerprint matches the current app and embedded helper. Upgrade migration awaits both Service Management unregistration and launchd-job removal before registering the new helper, preventing old and new signed peers or launch constraints from being mixed.
- The registration fingerprint is only a migration hint, not proof that a daemon is healthy. A bounded, read-only protocol/build probe must succeed before every XPC mutation.
- Both app and helper are separately signed with Hardened Runtime. Set `CORPLINK_CODE_SIGN_IDENTITY` when building to use a Developer ID identity; public releases should also be notarized.

Passwordless control delegates a narrow set of root actions to this exact signed app. It does not store an administrator password, weaken `sudoers`, accept arbitrary commands, or override jobs disabled by organization policy.

## Lifecycle and cleanup

Turning passwordless control off calls `SMAppService.unregister()`. macOS terminates a running daemon and prevents future launches. This disables the service; it does not erase the approval decision stored by macOS. Corplink Control nevertheless requires a fresh device-owner authentication before every later registration, so turning the option on again cannot silently reuse the retained approval. Corplink Control does not store or replay an administrator password. The helper executable and daemon plist remain only inside the app bundle and disappear when the app is deleted.

macOS may retain a disabled historical entry in its Background Task Management database after unregistering. That record is system-managed metadata; it is not a loaded launchd job, running process, copied helper, or retained root permission. Corplink Control does not call the system-wide `sfltool resetbtm` command because it would reset unrelated applications' background-item records.

Normal registration, upgrade, status, and removal paths do not invoke `sfltool` at all and never request administrator access for it. They use `SMAppService` for registration state and a bounded `launchctl print` check only while waiting for the app's own daemon to disappear.

Before uninstalling, turn off both **Passwordless start and stop** and **Launch Corplink Control at login**. Then remove the app normally. If the app was deleted while its helper was still registered, reinstall the same signed version, turn the option off, and uninstall again.

`/Library/Application Support/CorplinkControl/restore-state.json`, when present, is unrelated to helper registration. Stop operations use it to remember which Corplink jobs can be restored; it is removed after the pending recovery state is completed.

## Release versioning

The source version is 1.6.1 with bundle build number 11, following upstream 1.6.0 build 10. Build 11 adds a protocol/build health probe, waits for stable helper unregistration during upgrades, batches independent Stop requests, verifies a five-second stable stopped state, rejects malformed status output, and bounds both XPC and administrator-prompt execution. The Homebrew Cask must remain on the latest published release until a matching `v1.6.1` archive exists and its SHA-256 can be recorded. Do not point the Cask at an unpublished version or use a placeholder checksum.
