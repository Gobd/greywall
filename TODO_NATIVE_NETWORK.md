# Native networking + project learning — paused handoff

**Work resumed with operator approval. Builds/offline tests are allowed; installation,
activation and live network tests still require an explicit operator go-ahead.**

## Resume checkpoint (supersedes historical WIP notes below)

- `runNativeCommand` is now implemented with an unsupported-platform stub; the
  checkout compiles. Full `go test ./...` passes; `make fmt && make lint` is clean.
- Project policy validation, candidate rollback and old/missing-helper rejection
  tests pass. Filesystem tracer startup/empty-scope checks are implemented.
- Swift suite: 15 tests; Python suite: 4 tests. The combined ARM-only app + isolated
  Greywall binary builds successfully; the build-2 app is signed and verified.
  No installed app/binary or extension state changed by these builds.
- Build-2 readiness/counters, Copy Log, ownership-aware cleanup, timeout monitoring,
  policy store and CLI supervisor are source/build validated, NOT live verified.
- **Critical correction:** numeric-IP Seatbelt network rules are unsupported.
  The planned exact-IP inherited fallback is NOT viable. Nonempty native enforcement
  now fails by default and requires an explicit `--native-best-effort` acknowledgment;
  ancestry gaps remain. Never claim Linux-equivalent or detached-safe containment.
- Shared/system-mediated socket handling/root loss were changed in source to protect
  unrelated host services. The earlier DNS/proxy incident remains unexplained.
- Linux collector is still pending: verified Greyproxy logs lack protocol/session ID
  and rules lack a transport selector. Exact/session-scoped, capability-aware export
  must be implemented/tested without guessing or broadening permissions.
- See `experiments/macos-network-filter/CLI.md` and `build-combined.sh` for the new
  isolated build/CLI workflow. Installed binary/app and disabled extension unchanged.
- Historical sections below describe the pause snapshot; read this checkpoint first.
- Next operator checkpoint: confirm normal DNS/proxy health, then decide whether
  to replace the app with signed build 2 for an explicit bounded readiness test.
  Do not enable the extension until the operator agrees to that test.

## Repository / review

- Checkout: `/Users/briankemper/Developer/greywall`
- Fork: https://github.com/Gobd/greywall
- Branch: `experiment/native-macos-network-filter`
- Draft PR: https://github.com/Gobd/greywall/pull/1
- Last committed/pushed checkpoint: `4c62f09` — signed packaging and Finder test UI.
- Substantial later edits are **uncommitted and partially implemented**. Preserve
  them; do not reset the worktree or assume they are already in the PR.
- **Current Go CLI is incomplete:** `cmd/greywall/main.go` calls
  `runNativeCommand`, which has NOT been implemented. Restore a compiling,
  fail-closed checkout before attempting any combined build.
- The latest Swift app/launcher edits also have not received a complete app build
  or runtime test. The installed app/build artifacts are older than this WIP.

## Safety first: host networking incident

The operator reported transient DNS failure and a proxy that would not start,
then disabled/killed the experimental network extension. Cause is **unresolved**.
Do not dismiss it or label the backend safe based on the earlier fixture alone.

Last read-only check:

- Greywall extension `dev.briankemper.GreywallNetworkExperiment.filter`:
  **activated disabled**, installed build `0.1.0/1`.
- LuLu: **activated disabled**.
- Greyproxy running/listening on HTTP 43051, SOCKS 43052, DNS UDP 43053, UI 43080.
  Listening sockets do not prove DNS/upstream health.
- Tailscale and corporate security extensions remain present. Do NOT disable,
  remove, or blame them without evidence.
- The coding agent did not change routes, DNS settings, system proxy settings,
  or restart proxy services. Later source edits/offline tests did not activate a
  filter. Normal OS installation/configuration was performed by operator actions.
- Historical `log show` access started failing with `Operation not permitted`.
  Do not fix this by bypassing privacy controls or silently using sudo.

Before the next live test:

- [ ] Ask the operator to confirm normal DNS/proxy/networking is restored.
- [ ] Keep the extension disabled during compilation/unit tests.
- [ ] Audit system-mediated/shared sockets, root death, config disable/cleanup,
      and callbacks on unrelated traffic. Do not assume app attribution means a
      shared daemon socket can safely be dropped.
- [ ] Provide a clear emergency Disable/Uninstall path and prove it works.
- [ ] Make provider readiness and counters observable without privileged OS logs.
- [ ] Only re-enable through explicit operator approval for a bounded test.

## Intended product contract

A clean, shareable Greywall fork, independent of lambdap:

- Project-local filesystem and network policies; no old `.lambdap` migration layer.
- One project policy shared across harnesses; distinct identities for running
  sessions. Do not identify projects only by their final folder names.
- Trusted learning permits the selected workload's traffic and saves **observed
  exact destinations**, never the temporary blanket session grant.
- Enforcement uses saved permissions. New destinations should be presented for
  explicit project approval; Allow Once is not persisted.
- No global/shared grants by default. Greyproxy `source: global` means durable
  storage, not necessarily a wildcard client/project rule.
- Same learning/persistence semantics for Linux and macOS. Different OS backends.
- ARM macOS only for this helper; no Intel slice. Native Windows is unsupported.
- Do not auto-install/activate a helper just because a normal command runs.
- Never silently fall back to broad egress/proxy-only mode if native readiness fails.

## Verified before the pause

### Build/setup

- Paid Apple Developer team is active; Mac registered; profiles generated.
- Apple Development signing and app/extension signature verification succeeded.
- Development uses `content-filter-provider`; Apple's
  `content-filter-provider-systemextension` value is for Developer ID signing.
  Do not confuse these or weaken security to make signing succeed.
- WWDR G3 was imported by the operator. No private keys exported or trust overrides.
- Initial `errSecInternalComponent` was traced to a canceled codesign Keychain
  prompt and resolved with local operator approval.
- ARM-only app and embedded extension built via `build-app.sh`.
- Operator copied `Greywall Network Experiment.app` to `/Applications`, approved
  extension activation and filter configuration. This proves development-signed
  local activation worked; distribution/notarization remains separate.

### Our native provider, installed build 1

- `mode=learn root=44687` settings-applied record verified.
- GUI fixture passed Bun HTTP, Git HTTP, raw TCP and UDP with proxy vars removed.
- Provider logged five `scope=tracked decision=allow` records matching those flows.
- `mode=enforce root=44687` settings-applied record verified.
- Outside-app fixture passed while drop-all was enabled.
- Inside-app first Bun HTTP request failed with EBADF; local server saw a reset.
  The exact matching drop-log query was denied by OS log-store permissions.
  **Do not claim full drop-log verification or full protocol enforcement matrix.**
- The operator subsequently disabled the filter/extension after reporting the
  host networking issue. No further live tests should run until safety review.

### Independent LuLu 4.5.7 baseline

See `experiments/macos-network-filter/fixtures/LULU.md`.

- Lifetime parent “Process + Kids” rule blocked normal child + grandchild;
  LuLu logs explicitly confirmed inheritance of the parent's rule.
- Unrelated process was allowed under passive allow/no-new-rules mode.
- Reparented descendant connected after the intermediate exited, while the
  selected root remained alive. Ordinary ancestry walking is NOT sealed containment.
- Disposable fixture root was stopped; no direct LuLu preferences/rules edits.
- No LuLu code copied (GPL-3.0 must be considered if that changes).

## WIP files and what they currently do

### Greywall filesystem-learning reliability (partly tested)

- `internal/sandbox/tracer_health.go` / `_test.go`: require a valid event and a
  live tracer during startup; reject empty/malformed output and early exit.
- `manager.go`: sole Wait goroutine + done channel; new stop routine; startup
  no longer logs “proceeding anyway” when eslogger is not ready.
- `manager_darwin.go`: reject an unexpectedly dead tracer before profile save.
- `learning_darwin.go`: reject invalid root PID/no matching filesystem events;
  still permit an empty *additional grant set* when real events were filtered.
- `cmd/greywall/main.go`: profile-generation failure becomes a command error.
- `learning.go`: `GenerateLearnedTemplateAt` for project-local output without
  mutating XDG variables. Darwin and Linux manager paths use the new selector.
- Focused Go tracer/parser tests passed before the later native CLI/kernel edits.

Remaining:

- [ ] Review shutdown: the post-Kill wait is still unbounded if killing fails;
      handle signal errors, sudo child lifetime, cleanup and trace flush safely.
- [ ] Add early-death-during-command tests and previous-profile-retention tests.
- [ ] Test root PID/schema mismatch, malformed-only/unrelated-only traces,
      system-only real events, missing fork/spawn lineage, and signal shutdown.
- [ ] Validate real eslogger with operator-approved sudo/FDA; never run the
      harness itself as root. Do not silently synthesize a successful profile.
- [ ] Linux empty/broken strace health handling also needs review.
- [ ] Keep configurable ignore-for-learning distinct from enforced deny rules.
      Protected keys/.env paths must not become grants; file contents are not captured.

### Shared network-policy store / inherited kernel fallback (unfinished)

- New `internal/sandbox/native_network.go`: schema-1 exact IP/port/TCP-or-UDP
  policy reader; no wildcard/DNS expansion; reject symlinks/oversize/bad JSON.
- `manager.go`: new native policy selection and project filesystem output path.
- `macos.go`: WIP native exact egress rendering; trusted network learning is
  explicitly relaxed, enforcing mode must not grant blanket egress or inherit
  broad legacy localhost grants.
- Goal: inherited Seatbelt restrictions survive reparenting/root loss, rather
  than assuming the helper's ancestry walker can contain every descendant.

Remaining:

- [ ] Validate SBPL syntax/semantics for IPv4/IPv6, TCP/UDP, localhost, binding,
      Unix sockets and DNS. Do not ship rules without real tests.
- [ ] Validate public API inputs, not only file inputs; never render protocol injection.
- [ ] Audit remaining proxy/Unix-socket exceptions for native-policy widening.
- [ ] Protect project policy and helper control state from sandboxed writes.
- [ ] Define a deliberate system-resolver policy. Exact socket destinations are
      NOT DNS query/content or hostname identity enforcement.
- [ ] Relearning should preserve reviewed grants unless explicit reset, without
      accepting policy edits made by the workload during the learning session.
- [ ] Atomic/locked filesystem+network policy commit and failure retention.

### Native helper readiness/snapshot channel (compiled in isolation, not live)

New Swift components:

- `Sources/NativeControl/Control.swift`: read-only XPC snapshot protocol/client.
- `Sources/NativeControl/SessionLease.swift`: single-session user-state lock.
- `Sources/FilterPrototype/ControlService.swift`: authenticate peer PID, UID and
  root start identity; expose snapshots, not rule mutation.
- `FilterDataProvider.swift`: readiness/counters/snapshot, stop reset, root-loss
  callback-rule removal, outbound-only settings, shared/system-mediated bypass.
- Extension entry/Info: named Mach service; build number raised to 2.
- Shared policy storage: `Sources/NetworkPolicy/ProjectPolicyStore.swift`.
- Earlier Swift package tests passed after the first snapshot-channel changes;
  later safety/launcher/UI/store changes have NOT had a complete app build/test.

Remaining:

- [ ] Verify Mach service registration, entitlements, peer auth and reply types.
- [ ] Unauthorized/descendant client, PID reuse, stale root, wrong UID tests.
- [ ] Fix/readiness failure states and timeouts; no fail-open launch.
- [ ] Review XPC lifetimes/invalidations/cycles and overlapping polls.
- [ ] Ensure system-mediated bypass cannot be mistaken for complete containment.
- [ ] Prove root-loss clears callbacks without impacting unrelated host services.
- [ ] No live readiness/counter-channel claim until operator-approved integration test.

### App polish (source only; not installed)

- Standard Edit menu + dynamic colors were in the last signed build; the
  installed older copy still had UX issues.
- New explicit **Copy Log** button (copies full text to NSPasteboard).
- Status label + readiness/counter polling; save/load project policy buttons.
- Fixture blocked from starting while configured but not actually ready.
- Single-session lease and explicit replacement confirmation.

Remaining:

- [ ] Test CMD-C selection, Copy Log, CMD-V/path tilde expansion in dark/light mode.
- [ ] Fix success-but-not-ready snapshot timeout (currently can stay Starting).
- [ ] Reflect failures/disabled external state reliably, not cached GUI booleans.
- [ ] Ensure lease release on every failure/disable/ownership-mismatch path.
- [ ] Do not disable a newer/other active session during stale GUI cleanup.
- [ ] Layout: extra buttons may overflow the current horizontal stacks.
- [ ] Clear distinction: fixture baseline, real readiness, learning vs enforcing,
      saved policy vs drop-all diagnostic, pending vs actual approval.
- [ ] Install/uninstall/update/version flow; no automatic activation on app launch.

### Greywall CLI integration (currently incomplete)

Root flags added in `cmd/greywall/main.go`:

- `--experimental-native-network`
- `--native-learn-network`
- `--native-app`
- `--native-project`

**`runNativeCommand` is missing. Do not run/install this CLI build yet.**

New `App/Host/NativeLaunch.swift` is a first-draft signed CLI supervisor:

- Read-only installed/enabled-extension properties check; no activation request.
- Configure session root; establish matching ready snapshot before child launch.
- Preserve stdio, clear proxy vars, heartbeat, candidate export on successful
  learning, ownership-checked cleanup.
- Headless entry selected by `--native-launch` in Host main.
- Xcode generator now includes all Host Swift files.

Remaining:

- [ ] Implement Darwin `runNativeCommand` + unsupported-platform stub/tests.
- [ ] Fail closed for old helper build/missing channel/disabled extension before launch.
- [ ] Load project filesystem/network policy, reject unsafe policy paths/flags,
      build inherited Seatbelt wrapper; do not turn broad egress on for enforcement.
- [ ] Explicitly handle unsupported credential substitution/proxy options;
      never silently expose real credentials contrary to existing defaults.
- [ ] Forward signals/TTY correctly; define child/group cleanup and detached lifetime.
- [ ] Candidate policy export/commit, successful-only save and retained prior policy.
- [ ] Headless run-loop/Timer behavior, property callbacks, failure cleanup timeouts.
- [ ] Build an isolated local Greywall binary for combined testing; do NOT replace
      `~/.local/bin/greywall` until explicitly requested.

### Linux network learning — required, NOT implemented yet

- Same project policy semantics/store are a product requirement.
- Linux already has TUN/proxy capture; no macOS app dependency on Linux.
- [ ] Verify Greyproxy event/session API contract (do not guess endpoint names).
- [ ] Collect only exact current-session observations; discard blanket, global,
      unrelated, temporary approval and expired-rule artifacts.
- [ ] Verify enforcement can represent the schema's protocol/host distinctions;
      never broaden TCP-only into all protocols or silently invent DNS expansion.
- [ ] Linux learning exporter + project-rule restore/approval persistence.
- [ ] Fixture-backed collector/translation unit tests + Linux integration test/CI.
- [ ] Clearly distinguish cross-compilation/unit validation from live Linux proof.

## Suggested next sequence after resume approval

1. Restore compiling source and add offline tests first. No live helper activation.
2. Finish tracer health + project-policy storage/validation and kernel-profile tests.
3. Finish readiness/control channel, single-session ownership and app state/copy UX.
4. Complete native CLI wrapper and candidate commit; test with mocked/no-helper paths.
5. Implement Linux collector/translation against verified API + CI tests.
6. Build/sign updated app (build 2) and isolated Greywall binary; report exact results.
7. Ask operator before installation/replacement/activation; verify host DNS and
   unrelated traffic before/during/after one bounded test.
8. Learn -> save -> disable -> enforce same endpoints, plus denied endpoint,
   direct TCP/UDP, IPv6, detached child, DNS delegation, root exit/helper crash,
   disabled/restart and cleanup tests. Do not rely only on first HTTP failure.
9. New-destination UI approval/persistence and further polish, then release work.

## Commands / boundaries

From `experiments/macos-network-filter` (when work is explicitly resumed):

- `bash run-tests.sh` — Swift/Python tests and ancestry probe; no activation.
- `bash build-app.sh --unsigned` — compile-only; not usable for activation.
- Signed build: `DEVELOPMENT_TEAM=YOUR_TEAM BUNDLE_ID=YOUR_ID bash build-app.sh --provision`
- Optional explicit first-time device registration: add `--register-device`.
- Source-root instructions: `App/README.md`, `fixtures/LULU.md`.

Go: run focused tests first, then full tests as appropriate. Project instructions
require `make fmt && make lint` before committing. The last experiment-only commits
preceded the WIP Go edits; the WIP has NOT been linted/committed/pushed.

Do not export passwords/private keys, alter trust settings/SIP, install a VM,
change system routes/DNS/proxy settings, or automatically activate an extension.
Any push must update the existing draft PR (or create a PR if using a new branch).
No subagent delegation was authorized. Most importantly: do not call the current
prototype production-ready or claim a completed Linux collector/approval UI.
