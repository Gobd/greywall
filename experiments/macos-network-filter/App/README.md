# Build and deliberately test the native helper

Apple Silicon macOS 15+ only. No Intel slice, VM, TUN routes or proxy variables.
This is a diagnostic experiment, **not a production sandbox**. It is independent
of the installed Greywall binary. Build commands never install or activate it.

## Compile without signing

From `experiments/macos-network-filter`:

```sh
bash build-app.sh --unsigned
bash run-tests.sh
```

Both app and embedded extension must have only an `arm64` slice; the script checks.
The Xcode project is generated under `.build/xcode`; no XcodeGen installation is
needed. All outputs are under `.build/`. An unsigned app cannot activate the helper.

## Signed build

Use an **activated paid Apple Developer Program team**, not the free Personal
Development Team. A valid Apple Development certificate alone does not establish
that this team can provision Network Extensions/System Extensions.

```sh
DEVELOPMENT_TEAM=YOUR_PAID_TEAM_ID \
BUNDLE_ID=your.reverse.dns.GreywallNetworkExperiment \
bash build-app.sh --provision
```

`BUNDLE_ID` must be an identifier you own. The app uses that ID; the extension
uses the same ID with `.filter` appended. Team IDs/certificates/private keys are
not baked into tracked source. Get the team ID from Apple membership details or
Xcode's paid team, not the parenthesized ID in a certificate's display name.

`--provision` explicitly permits Xcode to register the two test app identifiers
and create/download the required development provisioning profiles through the
account already signed into Xcode. Omit it if provisioning is already available.
No certificate/private-key export, login credentials or system trust changes.
If the capability is denied, stop and resolve the paid team/capability setup.
Do not relax SIP, enable system-extension developer mode, or bypass validation.

Output:

```text
.build/app/Build/Products/Debug/Greywall Network Experiment.app
  Contents/Library/SystemExtensions/<your-bundle-id>.filter.systemextension
```

A successful build and `codesign` verification do NOT prove OS activation,
notarization acceptance or traffic interception. Wider distribution will need
appropriate distribution signing/notarization, not this local development build.

## Installation/activation — operator actions only

**Not performed by the build script or coding agent.**

1. After a successful signed build, copy the app to `/Applications` using Finder.
   macOS normally rejects activation from unsupported containing-app locations.
   This is a normal application installation; no manual system-file editing.
2. Open the app. Launch does NOT submit an extension request or enable filtering.
3. Select the experiment source directory containing `fixtures/baseline.py`.
4. Click **Activate extension**. Follow macOS's authorization/approval UI. Do not
   disable Tailscale, security agents or another extension to make the test pass.
5. If activation fails, retain the exact error and stop. Do not assume a signing
   success means activation should work, and do not work around OS validation.

## Shortest live test

First open a diagnostic stream in a separate terminal:

```sh
/usr/bin/log stream --style compact \
  --predicate 'subsystem == "io.greywall.network-experiment"'
```

1. Before enabling any filter, click **Run local baseline** and expect success.
   It uses existing Bun/Git/Python, a disposable local repository, raw sockets and
   ephemeral loopback servers. No stage/cloud endpoints or dependency installs.
2. Click **Enable learning**. macOS may request additional filter approval. Wait
   for `Provider settings applied; mode=learn` in the diagnostics. Saved preferences
   alone are NOT a readiness signal.
3. Run the fixture. Expect success **and** `scope=tracked decision=allow` records
   from the real provider. Success without those records is not proof of capture.
4. Click **Disable filter**, then **Enable drop-all**. Wait for the provider's
   `mode=enforce` settings-applied record. No destinations are allowed in this
   deliberately empty test policy. Do not switch modes without disabling first.
5. Run the fixture. Expect its first Bun HTTP request to fail, correlated with
   `scope=tracked decision=drop`. This checks one drop, not a full protocol matrix.
6. While drop-all is enabled, run `python3 fixtures/baseline.py` from an unrelated
   terminal. It should still pass. The app's fixture process tree is the selected
   root; a separately launched terminal tree must be left alone.
7. Click **Disable filter** and verify the app fixture works again.

Provider flows with unknown attribution are permitted, with a diagnostic, rather
than breaking unrelated host apps. The prototype is therefore NOT fail-closed.
Unrelated processes' destinations are not logged or learned. OS callbacks may
still expose their flow metadata to the extension before that early allow verdict.

Learning export and an approval UI are not connected to this app yet. Allow-one/
block-another, raw TCP/UDP and IPv6 enforcement matrices, project replay and
lifecycle/reparenting tests remain follow-up work after the first live capture.

## Disable / remove

- **Disable filter** saves `isEnabled=false` for ONLY this app's filter configuration.
- **Deactivate extension** first disables that filter, then requests deactivation
  of ONLY this bundle's extension through macOS. A reboot may be required for
  final removal; the app reports the OS result rather than rebooting for you.
- Quit attempts to disable a filter enabled by this app. Wait for any fixture to
  complete before quitting. Do not depend on graceful cleanup for containment.
- After successful deactivation, delete the containing app through Finder.
  Dragging it to Trash without deactivation is not a reliable extension uninstall.

There are no automatic activation/installation actions, routes or changes to the
installed Greywall executable. Integration with Greywall's normal launch path
must wait for proven interception plus a trusted launch/readiness handshake.
