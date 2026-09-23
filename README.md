# Prompt Receipt (CLI: `ailogger`)

Prompt Receipt is an open-source, on-device logger that records every LLM API call a machine makes — which app made it, the provider, the model, exact tokens, cost, latency, and the prompt and reply with secrets redacted — without changing any code. It runs as a local proxy, stores everything in SQLite on your own disk, and sends nothing anywhere.

```
$ ailogger tail
time      app     provider   model             in     out  cache_r  cache_w  cost     status  latency
18:46:47  claude  anthropic  claude-haiku-4-5  898    11   0        0        $0.0010  200     1.1s
18:46:48  claude  anthropic  claude-opus-5     2      4    10126    20756    $0.1349  200     2.3s
```

That second row is one `ok` typed into Claude Code on 2026-09-23: two tokens in, four out, 10,126 cache-read and 20,756 cache-write, **13.49 cents**. The request on the wire was 87,838 bytes.

**Who it's for.**

- **Developers** who want to know what a coding agent actually costs per call, and what it sends.
- **Team leads** who need spend per person, per model and per app without asking anyone to change their tools.
- **Security and compliance** teams who need a record of what leaves developer laptops and reaches AI providers, kept on the endpoint.

**Install** (Linux and macOS; Windows is coming):

```bash
curl -fsSL https://raw.githubusercontent.com/robertatkinson3570/promptreceipt/main/install.sh | bash
ailogger status
```

Log out and back in afterwards so every app picks up the proxy environment variables. To remove it: `ailogger env uninstall && ailogger ca uninstall && rm -rf ~/.local/share/ailogger ~/.config/ailogger ~/.local/bin/ailogger`.

**How it works.** Apps talk to an explicit HTTP proxy on `127.0.0.1:8228`. Hosts on a watch list of AI providers are terminated with a root certificate that exists only on your machine and is name-constrained to those hosts; every other host is a blind tunnel that is never decrypted. Request and response bodies are copied, not altered — nothing is added to your requests. Secrets are redacted before anything touches disk.

**What it costs.** The agent and the local dashboard are free and Apache-2.0, unlimited, with no account. Paid tiers (Team $10, Compliance $20 per seat per month, Enterprise custom) buy the multi-machine console, which is in early access.

**Where the data goes.** A local SQLite spool and a JSONL file under your home directory. No telemetry, no update check, no account, no network destination other than the provider your app was already calling.

- Website: <https://promptreceipt.com>
- Security model: [docs/security.md](docs/security.md) · Install options: [docs/install.md](docs/install.md) · FAQ: [docs/faq.md](docs/faq.md)

---

## What it captures

`exact` means the token counts come from the provider's own usage block in the response, not from a tokenizer estimate. Cost is computed only for exact events.

| Tool or provider | Host intercepted | Tokens |
|---|---|---|
| Claude Code, Anthropic SDK, `curl` | `api.anthropic.com` | exact |
| OpenAI SDK, `curl` | `api.openai.com` | exact |
| Codex CLI (API-key mode) | `api.openai.com` | exact |
| Codex CLI (ChatGPT login) | `chatgpt.com/backend-api/codex` | exact |
| Google Gemini API | `generativelanguage.googleapis.com` | exact |
| Gemini CLI (API-key mode) | `generativelanguage.googleapis.com` | exact |
| Gemini CLI (Google login) | `cloudcode-pa.googleapis.com` | metadata only |
| OpenRouter | `openrouter.ai` | exact |
| Ollama (local models) | `localhost:11434` | exact |
| Groq, Mistral, DeepSeek, xAI | `api.groq.com`, `api.mistral.ai`, `api.deepseek.com`, `api.x.ai` | event only, no model or tokens |
| Browser chat (claude.ai, chatgpt.com) | — | coming, and will be marked *estimated* |
| Windows | — | coming |

Any process that honours `HTTPS_PROXY` is covered, which includes the coding CLIs (`claude`, `codex`, `gemini`, `opencode`, `cursor-agent`, `aider`), SDK and `curl` calls, and Chromium-based desktop apps. Rows whose tokens were estimated rather than reported carry an `estimated` badge, so a partly guessed total never looks exact.

## How it works

```
app --HTTPS_PROXY--> ailogger :8228 --+-- watched AI host: TLS terminated with the local CA,
                                      |   bodies copied and parsed, event written, then
                                      |   re-encrypted to the real provider
                                      +-- everything else: CONNECT tunnel, opaque
```

- **Explicit proxy.** `ailogger env install` writes `HTTPS_PROXY`, `HTTP_PROXY`, `NO_PROXY`, `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE` and `CURL_CA_BUNDLE`. No kernel module, no system-wide redirection, no code change in any app.
- **Watch list.** Only the provider hosts above are decrypted. Everything else — your bank, your registry, your VPN — is relayed byte for byte with no certificate minted and no event written. Add your own hosts with `watch_hosts` in the config.
- **Name-constrained certificate.** The root CA is generated on your machine, RSA-4096, key mode 0600, and carries a critical X.509 name constraint (RFC 5280): it can only sign leaves for the watch-list names and their subdomains, plus loopback IPs (`127.0.0.0/8`, `::1`). A leaf for any other name or IP fails verification even if the root key leaked. `ailogger ca install` refuses to install a root without that constraint. Leaf certificates are ECDSA P-256, minted in memory, valid 24 hours, never written to disk.
- **Observe only.** Bodies are teed into a bounded copy and parsed in a separate goroutine. The client receives the upstream stream unchanged. Nothing is added to your requests — no `stream_options`, no `include_usage`, no extra tokens. A parser that panics or stalls cannot stall, alter or fail your call.
- **Process attribution.** The client's loopback socket is mapped back to the owning PID (`/proc/net/tcp` on Linux, `lsof` on macOS) to fill `app`, `app_path`, `app_pid` and `os_user`. That is how a row says `claude` rather than `node`.
- **Redaction before disk.** Anthropic, OpenAI, AWS and Azure keys, GitHub tokens, private keys, JWTs, Luhn-checked card numbers and US SSNs are replaced before the first write. Email addresses are flagged in `policy_hits` and left intact.

## Where your data lives

| Path | What |
|---|---|
| `~/.local/share/ailogger/spool.db` | SQLite spool: every event, and content records when `content: true` |
| `~/.local/share/ailogger/events.jsonl` | JSONL sink, rotated at `jsonl_max_mb`, `jsonl_keep` files retained |
| `~/.local/share/ailogger/ca/ca.key` | the root CA private key, mode 0600 in a 0700 directory |
| `~/.config/ailogger/config.yaml` | configuration; a missing file means defaults |

Default retention is 30 days (`local_retention_days`). Delivered rows older than that are deleted with SQLite `secure_delete` and a vacuum, so the file actually shrinks; rows no sink ever took are dropped at three times that age anyway, so an unwritable sink cannot keep prompts on disk forever. Set `content: false` to keep every number and store no prompt or response at all.

Size: roughly **1 KB per call** with metadata only, and closer to **90 KB** for one Claude Code turn with content on, because the whole conversation and every tool result go in the request.

Run `ailogger run` and a dashboard is served on `http://127.0.0.1:8229` — loopback only, behind a random per-run token printed by `ailogger status`. It shows totals by day, provider, model and app; an events list with filters; and a per-event detail page with the redacted request and response.

## Security

Seven guarantees, each enforced in code:

1. **Loopback only.** The proxy and the dashboard bind a loopback address; a non-loopback `listen` is a configuration error, not a warning. On Linux the proxy also checks the peer uid of every connection and refuses any account but your own.
2. **Only watch-listed hosts are decrypted.** Every other host is a blind TCP tunnel: no certificate minted, no bytes read, no event written.
3. **The certificate can only vouch for AI hosts.** Critical name constraint on the root, verified by `ailogger ca status`.
4. **Observe only, byte for byte.** Bodies are copied, never modified. Tests assert the upstream received exactly the bytes the client sent.
5. **Redaction before disk.** Detectors run before the first write; `content: false` drops prompts entirely.
6. **No telemetry.** No account, no phone-home, no update check. The installer contacts GitHub once, at install time.
7. **Reversible install.** Every trust-store change is recorded in an install log and `ailogger ca uninstall` reverts exactly those steps in reverse order.

An independent read-only audit on 2026-09-23 found it secure for its stated threat model — a single-user workstation where the owner installs it on purpose — and raised two high, four medium and seven low findings; the two high and all four medium findings are fixed. Read [docs/security.md](docs/security.md) for the threat model, the audit summary, what it does **not** see, and an honest SOC 2 mapping.

Releases are built with `-trimpath` and commit timestamps, ship a CycloneDX SBOM per archive, and `checksums.txt` is signed keylessly with cosign through GitHub's OIDC identity. The installer verifies the checksum before it extracts anything and aborts on a mismatch.

Footprint: 15 MB binary, about 18 MB resident and 0% CPU while idle.

## Pricing

| Tier | Price | What you get |
|---|---|---|
| **Free** | $0, forever | The agent and the local dashboard. Unlimited calls, unlimited machines you own, no account, Apache-2.0. |
| **Team** | $10 per seat / month | Console across machines, fleet spend by person, model and app, 90-day retention, email support. |
| **Compliance** | $20 per seat / month | Everything in Team plus policy push, redaction rules, SIEM export (Sentinel, Splunk, webhook), SSO, self-hosted option, 1-year retention. |
| **Enterprise** | Custom | Windows and MDM packaging, system-service mode, SLA, invoicing. |

The console is **early access** and prices may change before general availability. A seat is a person, not a machine. The free tier needs no card and no sign-up: it is the binary in this repository's releases. See <https://promptreceipt.com/pricing>.

## FAQ

### Does it add tokens or change my requests?

No. Request and response bodies are teed into a copy and parsed separately; the bytes that reach the provider are exactly the bytes your app sent, and tests assert that. Prompt Receipt never sets `stream_options`, `include_usage` or any other flag, and it makes no LLM calls of its own.

### Can employees disable it?

Today, yes. The agent runs as the user, capture depends on the proxy environment variables, and anyone who can edit their own shell profile can stop being logged. There is no tamper-evidence and no heartbeat yet, so a gap in the data does not announce itself. Enforced system-level capture with heartbeat and gap detection is planned for the Enterprise tier.

### How big does the data get?

About 1 KB per call with metadata only, and about 90 KB for a single Claude Code turn with prompts and replies stored, because the entire conversation and every tool result are resent each turn. A heavy day of agent coding is therefore tens of megabytes with content on and a rounding error with it off. Default retention is 30 days and old rows are actually deleted.

### Is it SOC 2 compliant?

No, and no tool can be: SOC 2 certifies your organisation, not a binary. What Prompt Receipt gives you to point at today is a per-call record with app, user, model, exact tokens, cost and status; redaction before storage; enforced local retention; and signed releases with an SBOM. What it does not yet give you is tamper-evident evidence, access control and an access log over prompt content, or proof that capture was running — those need the console. The honest per-criterion table is in [docs/security.md](docs/security.md).

### Does anything leave my machine?

No. There is no account, no telemetry, no update check and no network destination other than the provider your app was already talking to. The install script contacts GitHub once to download the release.

### Do I have to change my code or my API keys?

No. Prompt Receipt sets proxy environment variables; your apps keep their own keys, their own base URLs and their own SDKs. It never sees or stores your API keys — provider keys are redacted out of any captured content.

### What happens to my traffic if the agent stops?

Apps that have the proxy variables set will fail to reach the network until it starts again, because they are configured to go through it. Run `ailogger env uninstall` before removing the agent, and traffic goes direct again.

### Which hosts does it decrypt?

Only the AI provider hosts on the watch list, listed in the table above. Everything else is a CONNECT tunnel that is never decrypted and produces no event. You can add hosts with `watch_hosts`, after which you must re-mint the root so the name constraint covers them.

### Does it work with Claude Code, Codex and Gemini CLI?

Yes, with exact provider-reported tokens for Claude Code, Codex CLI in both API-key and ChatGPT-login modes, and Gemini CLI in API-key mode. Gemini CLI signed in with a Google account is currently metadata only.

### Can I export the data?

Yes. `ailogger export --since 24h --out events.jsonl` writes matching events and their content as JSONL, and a JSONL sink writes continuously as calls happen. The schema is flat and loads into Postgres, Splunk, Elastic or Azure Log Analytics without remapping.

### Is the source open?

The agent is Apache-2.0. This repository holds the documentation, the install script and the release binaries; the source repository is being prepared for publication and the paid console is licensed separately.

### Does it support Windows?

Not yet. Linux and macOS today; Windows is planned with the Enterprise tier. The macOS paths are written but have not yet been exercised on a Mac — see [docs/install.md](docs/install.md).

## Comparison

| | Prompt Receipt | Helicone | LiteLLM proxy | Langfuse |
|---|---|---|---|---|
| Where calls are logged | your own machine | hosted, or self-hosted | wherever you run the gateway | hosted, or self-hosted |
| Code or config change | none — environment variables only | change the base URL | change the base URL and route through the gateway | add the SDK or a wrapper |
| Works with closed-source CLIs you did not write | yes | only if they let you set a base URL | only if they let you set a base URL | no |
| Says which local app and PID made the call | yes | no | no | no |
| Tokens | exact, from the provider's usage block | exact | exact | exact |
| Account required | none | yes for the hosted product | none for self-hosting | yes for the hosted product |
| Licence | Apache-2.0 agent | open core | open source | open core |

Where they win: Helicone and Langfuse are full hosted analytics platforms with dashboards, evaluations, prompt management and team history built for production applications. LiteLLM is a real gateway — routing, fallbacks, rate limits and key management across a hundred providers — which Prompt Receipt does not do at all. Prompt Receipt is a narrower thing: it watches a laptop, attributes calls to the program that made them, and keeps the data on that laptop. Use it when you cannot or will not modify the application, or when the data must not leave the endpoint.

## Links

- [promptreceipt.com](https://promptreceipt.com) — overview
- [promptreceipt.com/demo](https://promptreceipt.com/demo) — the real dashboard, with screenshots
- [promptreceipt.com/security](https://promptreceipt.com/security) — threat model and audit
- [promptreceipt.com/install](https://promptreceipt.com/install) — install and uninstall
- [promptreceipt.com/pricing](https://promptreceipt.com/pricing) — tiers and FAQ
- [promptreceipt.com/teams](https://promptreceipt.com/teams) — the console, early access
- [promptreceipt.com/docs](https://promptreceipt.com/docs) — documentation

## Licence

Apache-2.0 for the agent — see [LICENSE](LICENSE). The console is licensed separately.
