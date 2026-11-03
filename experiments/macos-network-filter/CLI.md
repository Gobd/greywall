# Combined Greywall/native-helper test build

**Experimental, not Linux-equivalent containment. Keep the old extension disabled
until the operator explicitly approves another bounded live test.** The prior
host-wide DNS/proxy incident is unresolved. Compilation is not runtime proof.

## Build only (Apple Silicon)

```sh
cd experiments/macos-network-filter
bash run-tests.sh
bash build-combined.sh --unsigned
```

This generates an app bundle and `.build/tools/greywall`, without replacing the
installed binary/app, editing routes/DNS, or activating an extension. The unsigned
bundle cannot be activated. For an operator-approved signed build:

```sh
DEVELOPMENT_TEAM=YOUR_TEAM BUNDLE_ID=YOUR_UNIQUE_ID \
  bash build-combined.sh --provision
```

Then follow `App/README.md` for deliberate app replacement/approval. Build 2 adds
Copy Log, dynamic colors, project policy save/load, actual readiness/counters over
read-only authenticated XPC, a single-session lease and a CLI supervisor. It has
NOT yet had an approved live readiness/CLI replay test.

## Files / explicit opt-in

From the target project, using the isolated CLI (not your installed Greywall):

```sh
/path/to/.build/tools/greywall \
  --experimental-native-network --native-learn-network \
  --no-credential-protection -- /absolute/path/to/finite-test-command
```

- Requires signed app build 2+ and an explicitly enabled helper. It does not
  install/activate one or silently fall back when readiness fails.
- Starts no target until a generation/mode-matched ready snapshot is received.
- Uses the existing filesystem sandbox; network-only learning does NOT relax it.
- Saves `.greywall/network.json` only after command success, final verified
  snapshot, candidate validation and ownership-checked cleanup.
- Use `--native-project /path/to/project` to select another policy root.
- `--learning` additionally starts the existing filesystem tracer; sudo/FDA may
  be required on macOS. It saves `.greywall/filesystem.json`, does not mutate XDG
  variables, and fails if tracing is dead/empty/unscoped.
- Project policy/control state is denied to the sandboxed child. Single-session
  and project locks serialize management. Multi-file commit has rollback but is
  NOT crash-atomic; improve that before production.
- Credential substitution through Greyproxy is unavailable for native direct
  traffic. The explicit `--no-credential-protection` acknowledgment is required;
  `--inject/--secret` and proxy-specific options are rejected, not silently ignored.

## Important: macOS enforcement limitation

The test of numeric-IP Seatbelt rules FAILED: `sandbox-exec` only accepts `*` or
`localhost` in its supported network-address syntax. Do NOT resurrect the earlier
invalid “inherited exact-IP fallback” claim from the historical TODO.

- An empty enforcing policy remains inherited deny-all for direct egress.
- A nonempty project policy refuses launch by default: there is no valid kernel
  IP-list fallback that closes the helper's ancestry gaps.
- To experiment with scoped-helper enforcement, the operator must explicitly add
  `--native-best-effort`. This grants direct egress through Seatbelt and relies on
  helper attribution, which can miss detached/reparented children. It is NOT a
  safe substitute for Linux network namespaces and must not become the default.
- Shared/system-mediated flows are left alone to avoid breaking shared host
  services. System-resolver IPC is permitted. This is NOT DNS-query/content or
  cryptographic hostname enforcement.
- Policy addresses currently must be exact IPs with nonzero ports and TCP/UDP.
  Hostnames, interface zones, wildcard patterns and protocol widening fail closed.
  DNS/CDN address churn may require additional approved observations.

After an approved learning run, best-effort replay would be:

```sh
/path/to/.build/tools/greywall \
  --experimental-native-network --native-best-effort \
  --no-credential-protection -- /absolute/path/to/finite-test-command
```

**Do not use that command as containment for untrusted code.** Pending-destination
approval/resume UI and durable approval integration are still not implemented.

## Linux status

Existing namespace/TUN/proxy enforcement is unchanged. The shared policy reader
and explicit filesystem-output selector compile independently of the macOS app.
Linux network-learning/export is NOT wired into the CLI yet.

Verified upstream Greyproxy API contract:

- `GET /api/logs` accepts `container`, `from_date`, `to_date`, `limit`, `offset`;
  returns `items`, `total`, `page`, `pages`.
- `container` is a substring SQL LIKE filter: a collector MUST exact-match each
  returned record and use a unique current-session identity.
- Log JSON has destination/port/method/result but NO protocol or session-ID field.
- Rule JSON has container/destination/port/action but NO transport selector.

Do not infer TCP/UDP or widen a native TCP-only grant into all protocols. Finish
collector/session scoping and capability-aware translation against this contract,
with fixture-backed tests and Linux integration validation, before claiming the
same saved-network workflow works there.
