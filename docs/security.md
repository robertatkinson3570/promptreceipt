# Security model

Prompt Receipt (CLI: `ailogger`) terminates TLS for a small list of AI provider hosts on your own machine so it can read the token counts the provider reports. That is a serious thing to put on a laptop, so this page states exactly what it does, what it cannot do, what an audit found, and what it does not see.

## Threat model

**What it is built for:** a single-user workstation where the owner installs it on purpose and wants a record of the AI calls that machine makes.

**What it assumes:** that the person running it controls the account it runs under. Anyone who can already run code as you can read your files, and no local logger changes that.

**What it is not built for, yet:** a shared multi-user machine, or an environment where the person being logged is assumed to be working around the logging. On Linux the proxy refuses connections from any account but its own; on macOS that peer-uid check is not implemented yet, so another local account could relay traffic through the proxy port. Tamper-evidence, heartbeats and gap detection do not exist in the agent and are planned for the console.

## Seven guarantees

1. **Loopback only.** The proxy (`127.0.0.1:8228`) and the dashboard (`127.0.0.1:8229`) bind loopback addresses. A non-loopback `listen` value is a configuration error and the agent refuses to start, rather than a warning. On Linux the proxy reads the peer uid of every connection and returns `403` to any other account.
2. **Only watch-listed hosts are decrypted.** A `CONNECT` to a host on the AI-provider watch list is terminated and parsed. Every other host is a blind TCP tunnel: no certificate is minted, no bytes are read, no event is written. Your bank, your package registry and your VPN are relayed byte for byte.
3. **The certificate can only vouch for AI hosts.** The local root carries a critical X.509 name constraint (RFC 5280) permitting the watch-list DNS names and their subdomains, plus loopback IP ranges (`127.0.0.0/8`, `::1/128`) and excluding every other IP range. A leaf for anything else fails verification in any conforming client even if the root key leaked. `ailogger ca install` refuses to install a root without the constraint, and `ailogger ca status` prints what the installed root may sign for.
4. **Observe only, byte for byte.** Bodies are teed into a bounded copy and parsed in a separate goroutine; the client receives the upstream stream unchanged. Nothing is added to your requests — no `stream_options`, no `include_usage`, no extra tokens, no altered body. Tests assert the upstream received exactly the bytes that were sent, including for an oversized body. A parser that panics or stalls cannot stall, alter or fail your call.
5. **Redaction before disk.** Detectors for Anthropic, OpenAI, AWS and Azure keys, GitHub tokens, private keys, JWTs, Luhn-checked card numbers and US SSNs run before the first write, replacing the span with `[REDACTED:<detector>]`. Email addresses are flagged in `policy_hits` and left intact. `content: false` stores every number and no prompt or response at all. The request on the wire is never altered by redaction — only the stored copy.
6. **No telemetry.** No account, no phone-home, no update check, no LLM calls of its own, and no connection to any host the client did not ask for. The install script contacts GitHub once, at install time, to fetch a release.
7. **Reversible install.** Every trust-store change is recorded in an install log, and `ailogger ca uninstall` reverts exactly those steps in reverse order — certificate database entries, the system anchor, the Firefox enterprise policy (merged into an existing one, with the original backed up and restored). `ailogger env install` writes only its own files and marked `# >>> ailogger >>>` blocks, which `ailogger env uninstall` removes.

## Keys and certificates

| Item | Detail |
|---|---|
| Root key | RSA-4096, generated on the machine, mode 0600 in a 0700 directory, valid 5 years, never leaves the machine |
| Root constraints | critical name constraint, `MaxPathLen` zero, random serials |
| Leaf certificates | ECDSA P-256, minted in memory, valid exactly 24 hours (backdated 5 minutes for clock skew), re-minted an hour before expiry, never written to disk |
| Minted for | the `CONNECT` host only; a mismatched SNI is refused |

Trust store changes without `--system` cover Chromium/NSS and every tool that reads `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE` or `CURL_CA_BUNDLE`. Firefox reads none of those and needs `ailogger ca install --system`, which writes an enterprise policy. `--system` trusts your root for every account on the machine and prints a warning; use it on a single-user machine only. `ca install` refuses to run under `sudo` — it calls `sudo` itself for the two steps that need it.

Because `SSL_CERT_FILE`, `REQUESTS_CA_BUNDLE` and `CURL_CA_BUNDLE` replace the trust store rather than extend it, they point at a bundle of the system roots plus the local root. The running agent rewrites that bundle at start and every 10 minutes whenever the system store is newer, so a root your OS distrusts stops being trusted by those tools within minutes. The agent itself never uses the bundle: it clears those variables for its own process and verifies upstreams against the live system store.

## Data at rest

- Events and content records go to a local SQLite spool first, always; sinks drain it and mark delivery, so a sink that is down loses nothing.
- Retention defaults to 30 days. Delivered rows older than that are pruned, the database runs with `secure_delete` and is vacuumed after each prune, so pruned content is not left in free pages. Rows that no sink ever accepted are dropped at three times the retention age anyway (with a warning), so an unwritable sink cannot keep prompts on disk indefinitely.
- The JSONL sink rotates at a configured size and keeps a configured number of rotated files.
- Files are mode 0600. There is no encryption at rest in the agent; the disk encryption on the machine is what protects the spool when the machine is off.
- Captured bytes flow only through a JSON decoder, SSE splitting, RE2 regular expressions, parameterised SQLite statements, the 0600 JSONL file and Go's `html/template`. Nothing in the captured content is interpreted or executed.

## What it does not see

- **Apps that ignore the proxy environment variables.** There is no system-wide interception on either platform yet. An application with a hardcoded direct connection produces no event.
- **WebSocket and other upgraded streams.** They are relayed raw and produce no event.
- **Browser chat sessions** (claude.ai, chatgpt.com web UI). Those parsers are not written yet, and when they are their tokens will be estimates, badged as such.
- **Gemini CLI signed in with a Google account**, which is metadata only today.
- **Providers with no parser yet** (Groq, Mistral, DeepSeek, xAI): an event is recorded with the host and status, but no model and no tokens.

Anything the agent cannot see is an evidence gap, not a silent success. Say so in your own control documentation.

## Audit summary

An independent read-only audit was performed on 2026-09-23 against the M1 agent.

**Tooling:** `go vet` clean; the test suite passes across 22 packages; `govulncheck` reports no vulnerabilities; `gosec` produced 74 findings, all hygiene (unhandled `Close` errors, expected `$HOME` reads, verified-safe template and SQL sites).

**Verdict:** secure for the stated threat model. Loopback enforced in code rather than advised; root key 0600 in a 0700 directory; only watch-listed hosts decrypted; request bodies teed and never modified; no network calls of its own; captured content never interpreted or executed; the dashboard escapes output, uses parameterised SQL and checks the `Host` header.

**Findings and status:**

| Severity | Finding | Status |
|---|---|---|
| High | `ca install --system` overwrote an existing Firefox enterprise policy and `ca uninstall` deleted it | fixed — merged, backed up, restored on revert, skipped on invalid JSON |
| High | Release supply chain: `curl \| bash` with no checksum or signature verification, no SBOM, no reproducible flags | fixed — checksum and cosign verification in the installer, signing, CycloneDX SBOM, `-trimpath`, release workflow, SHA-pinned actions |
| Medium | Name constraint covered DNS names only, so a leaked root key could still mint trusted leaves for IP literals | fixed — permitted loopback IP ranges, every other IP range excluded, non-loopback IPs refused |
| Medium | The CA bundle was a frozen snapshot, so roots the OS distrusted stayed trusted in `curl`, Python and Rust tooling | fixed — the bundle is rewritten at start and on system-store change, and the agent no longer inherits it |
| Medium | No authentication on either loopback listener, so any local account could read prompts or relay traffic | fixed on Linux — peer-uid check on the proxy, per-run token on the dashboard, warning on `--system`. macOS peer-uid check is still open and documented above |
| Medium | Retention covered the spool only; JSONL and exports grew forever and a prune could never fire | fixed — `secure_delete`, vacuum after prune, JSONL rotation, forced prune at three times retention |
| Low | SNI chose the minted name rather than the `CONNECT` host | fixed |
| Low | Leaf lifetime was 26 hours while the documentation said 24 | fixed — exactly 24 hours |
| Low | `ca uninstall` did not refuse to run as root | fixed |
| Low | A Gemini model name was parsed from a path that still carried the API key query string | fixed — query stripped first |
| Low | Forwarded request headers are normalised (hop-by-hop, `Accept-Encoding`, default `User-Agent`); bodies untouched | open — documentation wording only |
| Low | The dashboard sets no Content-Security-Policy or `X-Content-Type-Options` | open |
| Low | SQLite and upstream error strings are echoed to the local client | open |

## Release integrity

Releases are built with `-trimpath` and commit timestamps as static, cgo-free binaries, ship a CycloneDX SBOM per archive, and their `checksums.txt` is signed keylessly with cosign through GitHub's OIDC identity. The install script downloads `checksums.txt` and verifies the archive before extracting anything; a mismatch aborts. If `cosign` is on `PATH` it also verifies the signature over `checksums.txt`; otherwise it says so and continues on the checksum alone. See [install.md](install.md) for the manual verification commands.

## SOC 2

SOC 2 certifies your organisation, not a binary, so nothing here makes you compliant. This is what Prompt Receipt gives you to point at, and what it does not.

| Criterion | What it provides today | What is missing |
|---|---|---|
| CC6 — logical access | Loopback enforced in code; CA key 0600 in a 0700 directory; peer-uid check on the proxy (Linux); per-run token on the dashboard; `sudo` used for two steps only and refused as root | No role-based access control over prompt content; `--system` trusts one user's root machine-wide |
| CC7 — monitoring | Every call becomes an event with app, PID, OS user, model, exact tokens, cost, HTTP status and latency; spool-first at-least-once delivery; agent, parser and price-table versions stamped on every row | Evidence is user-editable with no hash chain; the agent id is self-asserted; capture is voluntary; no heartbeat or gap detection |
| CC8 — change management | CI runs vet, race tests and cross-builds; few, current dependencies; `govulncheck` clean; signed releases, SBOM, checksum verification, reproducible build flags, SHA-pinned actions | — |
| C1 — confidentiality | Redaction before write; a switch to store no content at all; 0600 files; secrets not logged; request headers never stored; `secure_delete` and vacuum on prune | No encryption at rest; no access log over stored prompts |
| P — privacy | Metadata-only mode; the redaction policy version recorded on every content row | No install-time user notice; no view audit trail; no per-app opt-out; email addresses are flagged rather than redacted by default |

The gaps marked above are what the multi-machine console (early access) is being built to close: an immutable store, heartbeats and gap detection, SSO and roles, an access log over prompt content, and enforced retention.

## Reporting a vulnerability

Open a GitHub issue for anything already public. For anything that should not be public first, email `hello@promptreceipt.com`.
