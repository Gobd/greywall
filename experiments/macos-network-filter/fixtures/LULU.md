# LuLu process-tree baseline

This tests a shipped native filter while Greywall's own helper is not yet active.
No LuLu code is copied; the C fixture is standalone. No direct LuLu preferences/
rules edits, privileged commands, UI automation or credential access.

## Confirmed with LuLu 4.5.7

The operator selected a **Block / Process + Kids / process-lifetime** rule for the
fresh `gw-lulu-parent` executable. The root remained alive throughout the test.

| Attempt | Result |
| --- | --- |
| Parent/child/grandchild baseline in passive allow/no-create mode | HTTP responses received |
| Selected parent after operator block | LuLu log explicitly reports blocked under the lifetime rule |
| Live child | Blocked under the parent's rule, confirmed in LuLu log |
| Live grandchild | Blocked under the parent's rule, confirmed in LuLu log |
| Unrelated executable under passive allow/no-create mode | HTTP response received |
| Detached descendant after intermediate parent exited, selected root still alive | Reparented to PID 1; HTTP response received |

The first unrelated check accidentally ran before passive mode was re-enabled,
so it generated an alert/timed out. That result was discarded. The check was
repeated after verifying passive allow/no-create settings, and succeeded.

The disposable root was stopped at completion. Its lifetime rule should expire.
The agent made no direct preference/rule writes. The operator may uninstall LuLu
using its status-bar **Uninstall** action; no other network/security extension
should be removed as part of this experiment.

**Conclusion:** native socket filtering and ordinary descendant tree rules work.
This process-tree rule did not contain the reparented descendant in this test.
The result is consistent with LuLu's documented-in-source ancestry limitation:

https://github.com/objective-see/LuLu/blob/v4.5.7/LuLu/Extension/Rules.m#L798-L801

It is not proof that every LuLu configuration has the same outcome; this test
specifically checks an instance-scoped parent tree block while unmatched traffic
is allowed. Global deny rules would change the test and affect unrelated apps.
Greywall's current best-effort ancestry prototype has a similar known gap and
must not be treated as sealed containment.

## Safe reproduction (operator interaction required)

Use the official signed LuLu release and approve its extension/filter through
macOS. Initially enable passive mode: allow new connections, do not create rules.
Do not globally delete system/Apple/installed-application rules.

```sh
cd /path/to/greywall/experiments/macos-network-filter
bash lulu-test.sh build
bash lulu-test.sh baseline
bash lulu-test.sh start
```

- Executables are freshly compiled ARM-only under `.build/lulu-test/bin`.
- Only harmless raw-socket HTTP GETs to **1.1.1.1:80** (Cloudflare's public address).
  No DNS lookups, proxy variables, credentials, repository contents or stage/cloud
  services. An HTTP response, including a redirect, proves a request/response.
- LuLu's initial `allowLocalHost` setting is normally true, so a loopback test
  could conceal whether the parent-tree rule actually filtered a connection.
- Baseline creates no rule under passive allow/no-create settings.
- `start` launches an idle root; it sends no request before `trigger`.

Briefly disable passive mode, then:

```sh
bash lulu-test.sh trigger
```

Respond to ONLY the `gw-lulu-parent` alert: **Process + Kids**, **process lifetime**,
**Block**. There is a 90-second timeout for that first request; correlate its
result with LuLu diagnostics. If the alert never appears, don't create a broader
rule to compensate.

Re-enable passive **allow unmatched / don't create rules**, verify it in LuLu,
then:

```sh
bash lulu-test.sh unrelated
bash lulu-test.sh descendants
bash lulu-test.sh status
bash lulu-test.sh detached
bash lulu-test.sh status
```

The parent remains alive. `descendants` runs a child that runs a grandchild;
`detached` forks an intermediate that forks a new descendant, then exits before
that descendant connects. The descendant uses a distinct executable, avoiding a
parent executable's own direct rule masking the ancestry check. It does not
need to outlive the selected root to exercise the intermediate-exit gap.

New requests use bounded timeouts. A socket failure alone is NOT proof of LuLu
blocking: correlate with the provider's actual parent-rule block records.
Read-only diagnostic command:

```sh
/usr/bin/log show --last 5m --style compact \
  --predicate 'subsystem == "com.objective-see.lulu" AND eventMessage CONTAINS "gw-lulu-"'
```

Finish explicitly:

```sh
bash lulu-test.sh stop
bash lulu-test.sh status
```

The script verifies the recorded PID is still its exact executable/command
before sending signals, avoiding accidental signaling of a reused unrelated PID.
A signal queued during a request is handled after that bounded attempt finishes.
Do not leave the test root or temporary test rules in use as a production firewall.
