# Privileged control

Corplink Control 1.6.0 supports two authorization modes for Start and Stop actions. Status inspection remains unprivileged in both modes.

## Modes

### Administrator prompt

This is the default and fallback. Each control action runs the bundled helper through the standard macOS administrator authorization dialog. It remains available when passwordless control is off, has not yet been approved, or cannot safely use the registered service.

### Passwordless control

The user must explicitly enable **Settings > Privileged control > Passwordless start and stop**. The app then registers the embedded LaunchDaemon with `SMAppService`. macOS requires an administrator to approve it under **System Settings > General > Login Items & Extensions** before the daemon can run. Once enabled, the app sends fixed control requests over privileged XPC instead of requesting a password for every action.

The app must be installed directly in `/Applications` before it can register the daemon. A copy launched from Downloads, a build directory, or another location continues to use the administrator-prompt fallback.

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
- The daemon accepts only the effective user currently logged in at the console.
- XPC exposes one method whose action must match an exact allowlist. It does not accept executable paths, shell fragments, environment variables other than the UI language, or arbitrary component identifiers.
- Privileged operations are serialized to prevent overlapping Start and Stop mutations.
- Approved actions run inside the already validated root process. The daemon never re-executes a helper from a path that an unprivileged process might replace.
- The administrator-prompt fallback applies the same action allowlist and shell-quotes every fixed argument.
- Both app and helper are separately signed with Hardened Runtime. Set `CORPLINK_CODE_SIGN_IDENTITY` when building to use a Developer ID identity; public releases should also be notarized.

Passwordless control delegates a narrow set of root actions to this exact signed app. It does not store an administrator password, weaken `sudoers`, accept arbitrary commands, or override jobs disabled by organization policy.

## Lifecycle and cleanup

Turning passwordless control off calls `SMAppService.unregister()`. macOS terminates a running daemon and prevents future launches. The helper executable and daemon plist remain only inside the app bundle and disappear when the app is deleted.

macOS may retain a disabled historical entry in its Background Task Management database after unregistering. That record is system-managed metadata; it is not a loaded launchd job, running process, copied helper, or retained root permission. Corplink Control does not call the system-wide `sfltool resetbtm` command because it would reset unrelated applications' background-item records.

Before uninstalling, turn off both **Passwordless start and stop** and **Launch Corplink Control at login**. Then remove the app normally. If the app was deleted while its helper was still registered, reinstall the same signed version, turn the option off, and uninstall again.

`/Library/Application Support/CorplinkControl/restore-state.json`, when present, is unrelated to helper registration. Stop operations use it to remember which Corplink jobs can be restored; it is removed after the pending recovery state is completed.

## Release versioning

The source version for this feature is 1.6.0 with bundle build number 10. The Homebrew Cask must remain on the latest published release until a matching `v1.6.0` archive exists and its SHA-256 can be recorded. Do not point the Cask at an unpublished version or use a placeholder checksum.
