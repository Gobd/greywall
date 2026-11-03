# Native macOS network-filter feasibility experiment

**Not a sandbox. Not installed or activated. No claim of live interception.**

This isolated Swift package and optional containing app test a possible native companion to Greywall's
Seatbelt filesystem sandbox. It uses `NEFilterDataProvider` socket-flow verdicts,
not a VM, `utun` routes, application proxy variables, TLS interception, or binary
injection. It is not integrated with Greywall or lambdap.

## Safety and scope

All source and build artifacts belong in this directory. Build/tests perform no
sudo, system-file edits, network settings writes, extension registration or
installed Greywall replacement. The optional containing app has explicit buttons
for activation, enabling/disabling its filter and deactivation; none runs on launch.
These operator actions change the experiment's OS configuration and need approval.
See [App/README.md](App/README.md) for the build and deliberate live test procedure.
`network-probe preflight` only calls `NEFilterManager.loadFromPreferences`; it never
saves preferences.

The fixtures use existing Bun/Git/Python installations, ephemeral loopback ports,
and a disposable empty bare Git repository under `.build/tmp`. They do not run
`bun install`, start the stage app, read AWS credentials, contact external hosts,
or modify your current project. Proxy variables and user/system Git configuration
are disabled only in their child environments.

## Run

Xcode and Apple Silicon macOS 15+ are required for the app. No Intel slice is built.
No third-party Swift packages are downloaded.

```sh
cd /path/to/greywall/experiments/macos-network-filter
bash run-tests.sh
bash build-app.sh --unsigned  # containing app + embedded extension compile check
python3 fixtures/baseline.py
# Optional read-only entitlement/API probe (may exit 2 or time out):
bash run-tests.sh --preflight
```

SwiftPM may add `.build` to the enclosing repository's `.gitignore`; use this
package's local `.gitignore` rather than retaining that unrelated repository edit.

## What exists

- A compiling `NEFilterDataProvider` prototype reading an explicit immutable
  session configuration from `vendorConfiguration["sessionJSON"]`.
- Audit-token PID extraction and a live `libproc` ancestry probe. Root identity
  includes start time to reject a reused root PID.
- Exact address + port + TCP/UDP policy matching. No wildcard host, subnet, port,
  or protocol grants. Unknown tracked endpoints are dropped.
- In-memory learning, deduplicated deterministic JSON **candidate** export, and
  replay tests. Exported destinations do not contain process IDs. Active session
  root identity is separate from reusable destination permissions.
- Explicit IPv4/IPv6 loopback filter rules. Apple's default action otherwise
  exempts loopback, which could expose local services/proxies.
- Local traffic fixtures for Bun fetch, Git HTTP and a raw TCP/UDP grandchild.

There is **no live export/persistence path**, project config loader, pending-flow
approval UI or trusted launch handshake yet. The containing app builds an embedded
system extension and provides explicit activate, learn, drop-all, disable and
deactivate controls. Signed provisioning and live activation are not yet proven.
The fixtures establish a baseline; they have not been run against an active filter.

## Results on this machine

- Compiled provider against the installed macOS 27.2 SDK.
- Nine unit tests passed: descendants vs unrelated, root PID reuse, cycle bounds,
  deduplication, candidate export/replay, exact port/protocol matching, IPv6,
  missing endpoints, deterministic JSON and known reparenting limitation.
- Live root/child/grandchild probe passed; calling terminal/agent was unrelated.
- Proxy-free loopback Bun HTTP, Git HTTP, raw TCP and raw UDP baseline passed.
- Containing app + embedded system extension compile successfully without signing.
- Valid Apple Development signing identity is now available after the operator
  installed Apple's WWDR G3 intermediate certificate.
- Signed provisioning attempt was blocked: Xcode identifies the selected team as
  a free **Personal Development Team**, which cannot provision Network Extensions
  or System Extensions. An activated paid Developer Program team is required.
- Read-only filter-preferences probe timed out after 10 seconds. No settings saved.
- No app installed, extension activated or traffic intercepted yet.

These results do NOT establish that `libproc` is accessible inside the real
provider sandbox or that socket attribution works for these applications there.

## Gaps before this can be a safety boundary

1. **Signing and activation:** the app/extension compile, but still need an
   activated paid signing team, supported Network Extension entitlements/provisioning
   and user approval. Do not bypass signing/SIP or modify system files. Another
   installed network component (Tailscale here) must be tested for coexistence,
   not disabled to make this pass.
2. **Trusted process lifecycle attribution:** the current ancestry walk is only
   a feasibility probe. Reparented/daemonized children can look unrelated; exiting
   processes, PID reuse during lookup and system-mediated connections complicate
   attribution. Audit tokens contain generation information, but this prototype
   extracts only the PID. Unknown scope is logged and allowed to avoid disrupting
   unrelated host traffic; this is explicitly NOT fail-closed containment.
   A trusted event-driven tracker (possibly Endpoint Security, subject to separate
   entitlement/access requirements), generation validation and launch handshake
   are needed before calling this secure. No binary-name-wide Bun/Git filtering.
3. **Endpoints and protocols:** POSIX sockets commonly expose IPs, not domain
   names. CDN/AWS IP churn, IPv6 scope IDs, DNS/system resolver attribution and
   DNS-to-flow correlation need investigation. TCP/UDP flows are the target;
   no claim for every socket family/protocol. Missing endpoints are dropped in
   the prototype; a proper implementation must decide at later data callbacks.
4. **Delegation and local relays:** filtering a connection to a local proxy does
   not automatically constrain destinations that proxy contacts. Avoid broad
   loopback grants; restrict trusted auth-proxy ports and account for DNS/XPC
   delegation. Inbound/listening access is outside this outbound experiment.
5. **Lifecycle and tamper resistance:** validate what happens if the provider or
   tracker crashes, the root exits, policies change, pre-existing sockets are
   inherited/passed, or an approved flow changes UDP destination. Current
   callbacks are insufficient to claim those properties.
6. **Seatbelt integration:** the existing normal Greywall profile blocks direct
   outbound traffic. A working native filter needs a deliberate backend-specific
   change so Seatbelt does not block connections before they reach the filter.
   Never loosen that installed profile until the provider is active and the
   launch handshake confirms enforcement.
7. **Learning/approval export:** add durable project storage and pending-flow
   approval/resume. `NEFilterNewFlowVerdict.pause()` is available; UDP pauses have
   a deadline. Handle retries/timeouts and prevent sandboxed children from
   modifying the trusted active policy or approving their own requests.

## Intended project policy contract (not implemented)

This should be a clean, standalone feature in a shareable Greywall fork. Greywall
owns discovery, persistence, project config and approval integration. No lambdap
folder layout, old-profile migration or compatibility layer is required. A caller
such as lambdap only launches Greywall; it does not implement policy persistence.
The final CLI and project-directory schema are still to be designed (a native
`.greywall/` directory is a candidate, not an implemented interface).

One project network policy should be shared by its harnesses, while each running
session has its own identity and process tree. Project identity must distinguish
full paths/worktrees, not merely the last two folder names.

- **Trusted learning:** permit the tracked tree's traffic and save observed
  destination permissions for that project; never export the temporary blanket
  session grant. Record attempted destinations, not proof an application requires
  or successfully used them. Review should remain possible before enforcement.
- **Enforcement:** load that project policy, allow matching destinations, and
  show new requests in the approval UI. Approval defaults to **this project** and
  is persisted there. Allow-once is not persisted.
- **Global grants:** none by default. Any future global/shared action must be
  separate and explicit. Greyproxy's existing `source: global` is a storage/source
  label, distinct from a wildcard project/client selector.

## Signed live acceptance test still required

Before integration, run the same fixture tree in learning and enforcement:

1. Observe flows from Bun, Git and raw TCP/UDP descendants with proxies unset.
2. Allow one exact endpoint, block another, and verify the unrelated terminal
   remains unaffected. Include IPv4/IPv6 and loopback, not only HTTP.
3. Export learning observations; restart in enforcement with that project policy
   and repeat. Exercise new-flow UI approval, retry/resume and saved approval.
4. Test reparenting, short-lived children, PID generation reuse, root exit,
   provider restart, DNS, system-mediated networking and local relay escape paths.

The signing/activation stage needs operator-provided credentials and explicit
approval. The current experiment does not alter the laptop to work around it.

## Fence upstream check

Read the current upstream GitHub tree at
`737751a82b49f287b41f8a3e62ec62919d7b9224` (also the local Fence checkout).
`internal/sandbox/macos.go` still uses HTTP/SOCKS proxy variables + Seatbelt;
wildcard mode permits direct connections and warns that domain denials then only
apply to proxy-aware applications. No Network Extension implementation was found
in that tree. There is no upstream native interception layer to reuse today.
