# Prompt Receipt FAQ

Every answer begins with a direct one-sentence answer. Prompt Receipt is the product; `ailogger` is the command.

## The basics

### What is Prompt Receipt?

Prompt Receipt is an open-source, on-device logger that records every LLM API call a machine makes — the app, the provider, the model, exact tokens, cost, latency and the prompt and reply with secrets redacted — without changing any code. It runs as a local HTTP proxy on `127.0.0.1:8228`, writes to a SQLite database in your home directory, and serves a dashboard on `127.0.0.1:8229`.

### What does it record for each call?

One flat record per call: a time-ordered event id, the timestamp, the machine and OS user, the app name, path and PID, the surface (`cli`, `desktop`, `api`, `local`), the provider, the endpoint host and path with the query string stripped, the model as normalised and as the wire spelled it, input, output, cache-read and cache-write tokens, whether those tokens are exact or absent, cost in USD, latency, HTTP status, whether it streamed, the stop reason, which redaction rules matched, and the agent, parser and price-table versions. The prompt and response are a separate linked record so they can be switched off on their own.

### Why is it called a receipt?

Because a receipt is an itemised record of something you already paid for. One `ok` typed into Claude Code on 2026-09-23 cost 13.49 cents — 2 tokens in, 4 out, 10,126 cache-read, 20,756 cache-write on claude-opus-5 — and the request was 87,838 bytes on the wire. Without a record, that is invisible.

### Who is it for?

Developers who want to know what a coding agent costs per call and what it sends, team leads who need spend per person and per app without asking anyone to change their tools, and security teams who need a record of what reaches AI providers from developer machines and want it to stay on the endpoint.

### Is the agent really free?

Yes, and Apache-2.0. The agent and the local dashboard are free for unlimited calls on unlimited machines you own, with no account and no card. The paid tiers buy the console that collects several machines into one place, which is in early access.

## Safety and correctness

### Does it add tokens or change my requests?

No. Request and response bodies are teed into a bounded copy and parsed in a separate goroutine; the bytes that reach the provider are exactly the bytes your app sent, and the test suite asserts that, including for an oversized body. Prompt Receipt never sets `stream_options`, `include_usage` or any other flag, makes no LLM calls of its own, and contacts no host your application did not ask for.

### Does anything leave my machine?

No. There is no account, no telemetry, no update check and no network destination other than the provider your app was already talking to. The install script contacts GitHub once, at install time, to fetch a release.

### Does it see or store my API keys?

It sees them in transit, as any proxy does, and it does not store them: provider keys are one of the built-in redaction detectors and are replaced before the first write. Request headers are not stored at all, and you keep using your own keys with your own SDKs — nothing is re-keyed or proxied through a third party.

### Does it slow down my calls?

Not measurably in normal use: parsing runs on a copy, off the path the response takes back to your app, so it adds no round trip and cannot block the stream. There is a local TLS handshake between your app and the proxy on top of the real one to the provider. No published benchmark exists yet; the agent uses about 18 MB resident and 0% CPU while idle, and the binary is 15 MB.

### What happens if the agent stops or crashes?

Applications that have the proxy environment variables set cannot reach the network until it starts again, because they are configured to go through it. That is the honest cost of an explicit proxy. Run `ailogger env uninstall` before removing the agent and traffic goes direct again. Events already in the spool are not lost: sinks drain from SQLite and mark delivery, so a sink that is down loses nothing.

### Are the token counts exact or estimated?

Exact for every provider with a parser, because they come from the provider's own usage block in the response rather than from a tokenizer. `token_source` is `exact` in that case and `none` when the provider reported nothing, and cost is computed only for exact events. When browser chat capture arrives, its counts will be estimates and every such row will carry an `estimated` badge so a partly guessed total never looks exact.

## Coverage

### Which tools and providers does it cover?

Anthropic, OpenAI, Google Gemini, OpenRouter and Ollama have native parsers with exact tokens; Groq, Mistral, DeepSeek and xAI are recorded as events with no model or tokens yet. On the tool side that covers Claude Code, Codex CLI in both API-key and ChatGPT-login modes, Gemini CLI in API-key mode, and any SDK or `curl` call. Any process that honours `HTTPS_PROXY` is in scope.

### Does it work with Claude Code?

Yes, with exact provider-reported tokens, cost, cache-read and cache-write counts, and the full request and response. Claude Code is the case it was built for: the rows say `claude` because the call is attributed to the process that made it.

### Does it work with Cursor?

Partly. The `cursor-agent` CLI is covered when it honours the proxy environment variables, but calls that Cursor routes through its own backend go to a host that is not on the watch list, so they are tunnelled untouched and produce no event. You can add hosts with `watch_hosts` and re-mint the root.

### What does it not see?

Applications that ignore the proxy environment variables, because there is no system-wide interception on either platform yet; WebSocket and other upgraded streams, which are relayed raw; browser chat sessions on claude.ai or chatgpt.com, whose parsers are not written; and Gemini CLI signed in with a Google account, which is metadata only. Treat each of those as an evidence gap and say so in your own documentation.

### Does it work with local models?

Yes, Ollama on `localhost:11434` is parsed through both its native `/api/chat` endpoint and its OpenAI-compatible `/v1` endpoint, with exact tokens. Cost is zero, but the token and latency numbers are real.

### Does it support Windows?

Not yet. Linux and macOS today; Windows is planned with the Enterprise tier, alongside MDM packaging and a system-service mode.

### Does macOS work?

The macOS code paths are written but have not yet been exercised on a Mac, so treat them as unverified: the keychain install and uninstall, `lsof`-based process attribution, and `launchctl setenv` for the environment variables. There is also no peer-uid check on the proxy port on macOS, so another local account on the same machine could relay traffic through it.

## Certificates and security

### Why does it install a root certificate?

Because the token counts it records are inside the provider's TLS-encrypted response, and there is no way to read them without terminating that connection. The alternative is to wrap every SDK in every application, which is exactly the code change Prompt Receipt exists to avoid.

### Can it decrypt my banking traffic?

No. Only hosts on the AI-provider watch list are terminated; everything else is a blind `CONNECT` tunnel where no certificate is minted, no bytes are read and no event is written. Beyond that policy, the root certificate itself carries a critical X.509 name constraint (RFC 5280) restricting it to the watch-list names and their subdomains plus loopback IPs, so it is not *permitted* to sign a certificate for your bank even if something tried.

### What happens if the root key leaks?

An attacker with the key could impersonate the AI provider hosts on the watch list, and nothing else. The name constraint is critical, so any conforming client rejects a leaf for any other DNS name or any non-loopback IP address, which is the difference between this and a general-purpose intercepting proxy. The key is RSA-4096, mode 0600 in a 0700 directory, generated on the machine and never transmitted; leaf certificates are minted in memory, valid 24 hours, and never written to disk.

### Has it been audited?

Yes, by an independent read-only audit on 2026-09-23, which found it secure for its stated threat model and raised two high, four medium and seven low findings. Both high findings and all four medium findings are fixed; three low findings remain open (header-normalisation wording, a missing Content-Security-Policy on the local dashboard, and error strings echoed to the local client). The full summary is in [security.md](security.md).

### Can I read the source before installing it?

The agent is Apache-2.0 and the source repository is being prepared for publication; this repository holds the documentation, the install script and the releases. Putting a root certificate on a laptop is only reasonable if the thing doing it can be read, which is why the agent is licensed that way and why releases ship a signed `checksums.txt` and a CycloneDX SBOM.

### How do I verify a download?

Download the archive, `checksums.txt`, `checksums.txt.sig` and `checksums.txt.pem` from the release, run `cosign verify-blob` against GitHub's OIDC issuer to prove the checksum file came from the release workflow, then `sha256sum -c` to prove the archive is the one it lists. The exact commands are in [install.md](install.md), and the install script does the checksum step itself before extracting anything.

## Data

### Where is my data stored?

In a SQLite spool and a JSONL file under `~/.local/share/ailogger`, mode 0600, and nowhere else on the free tier. With the console you point events at your own destination — your server, your Postgres, your Azure or Splunk tenant — and redaction still runs on the endpoint before anything is written or sent.

### How big does the data get?

About 1 KB per call with metadata only, and about 90 KB for one Claude Code turn with content stored, because the whole conversation and every tool result are resent in each request. A heavy day of agent coding is therefore tens of megabytes with content on and a rounding error with it off. Compression of stored content is coming.

### How long is it kept, and is it really deleted?

Thirty days by default, and yes: delivered rows past `local_retention_days` are pruned, the database runs with `secure_delete` and is vacuumed after each prune, so the content is not left behind in free pages and the file shrinks. Rows that no sink ever accepted are dropped at three times the retention age regardless, so a broken sink cannot keep prompts on disk indefinitely.

### Can I keep the numbers without storing prompts?

Yes, set `content: false` in the config. Every event — app, model, tokens, cost, latency, status — is still recorded, and no prompt or response is written at any point.

### What gets redacted?

Anthropic, OpenAI, AWS and Azure keys, GitHub tokens, private keys, JWTs, Luhn-checked card numbers and US SSNs are replaced with `[REDACTED:<detector>]` before the first write; email addresses are flagged in `policy_hits` and left intact. Redaction runs on the agent, on the stored copy only — the request that goes to the provider is never altered.

### Can I export the data or send it to a SIEM?

Yes. `ailogger export --since 24h --out events.jsonl` writes matching events and their content records as JSONL, and the JSONL sink writes continuously. The schema is flat so it loads into Postgres, Splunk, Elastic or Azure Log Analytics without remapping; managed SIEM export with Sentinel, Splunk and webhook sinks is part of the Compliance tier.

## Teams, compliance and pricing

### Can employees disable it?

Today, yes. The agent runs as the user, capture depends on the proxy environment variables, and anyone who can edit their own shell profile can stop being logged. There is no tamper-evidence and no heartbeat yet, so a gap in the data does not announce itself. Enforced system-level capture with a service the user cannot stop, plus heartbeat and gap detection, is planned for the Enterprise tier. Do not sell it internally as something it is not.

### Is it SOC 2 compliant?

No, and no tool can be, because SOC 2 certifies your organisation rather than a binary. What Prompt Receipt gives you to point at today is a per-call record with app, user, model, exact tokens, cost and status, redaction before storage, enforced local retention, and signed releases with an SBOM. What it does not yet give you is tamper-evident evidence, access control and an access log over prompt content, or proof that capture was running. The per-criterion table is in [security.md](security.md).

### Does it help with GDPR?

It can help and it can also hurt, so decide deliberately. Stored prompts may contain personal data, which makes the spool a data store you are responsible for; `content: false`, the 30-day retention default and the built-in detectors are the controls. There is no user-notice screen, no view audit trail and no per-app opt-out in the agent today, and email addresses are flagged rather than redacted by default. This is not legal advice.

### What does it cost?

The agent and local dashboard are free forever. Team is $10 per seat per month for the console, fleet spend by person, model and app, 90-day retention and email support; Compliance is $20 per seat per month for everything in Team plus policy push, redaction rules, SIEM export, SSO, a self-hosted option and 1-year retention; Enterprise is custom, for Windows and MDM packaging, system-service mode, SLA and invoicing. The console is early access and prices may change before general availability.

### What counts as a seat?

A person whose machines report into the console. One person with a laptop and a desktop is one seat.

### Can I move from Free to Team later?

Yes. Enrolling an agent is one command and it keeps writing locally as well, nothing you captured before is lost, and nothing already on the machine is uploaded retroactively unless you ask for it.

## Comparisons and alternatives

### How is this different from Helicone, LiteLLM or Langfuse?

Those log calls made by an application you control, by changing a base URL or adding an SDK, usually to a server. Prompt Receipt logs calls made by a machine, including by closed-source tools you did not write and cannot modify, attributes each call to the local process and PID that made it, and keeps the data on that machine. They win on hosted analytics, evaluations, prompt management and, for LiteLLM, real gateway features like routing, fallbacks and key management across providers — none of which Prompt Receipt does.

### Why not just read the provider's usage dashboard?

Because a provider dashboard tells you the total, not which program on which machine spent it, and it cannot show you the prompt. Prompt Receipt splits the same spend by app, model, user and call, with the request and response attached.

### Why not a system-wide MITM proxy like mitmproxy?

You can, and people do; the differences are that a general-purpose intercepting proxy installs a root certificate that can vouch for every site on the internet, decrypts everything by default, and does not know what an LLM call is. Prompt Receipt decrypts a short list of AI hosts, cannot mint a certificate for anything else, and parses the calls into a cost and token schema.

## Running it

### How do I install and uninstall it?

Install with the one-liner in the [README](../README.md), then log out and back in so every application sees the proxy variables. Uninstall with `ailogger env uninstall`, `ailogger ca uninstall` and `rm -rf ~/.local/share/ailogger ~/.config/ailogger ~/.local/bin/ailogger`, in that order. Every trust-store change is recorded in an install log and reverted in reverse order, so nothing is left behind.

### Nothing is showing up in `ailogger tail`. Why?

Most often the application was started before `ailogger env install` ran and still has the old environment. Log out and back in, or run `systemctl --user import-environment`, and start the application again. Otherwise the application ignores proxy variables, or the host it talks to is not on the watch list.

### Can I watch extra hosts?

Yes, add them under `watch_hosts` in the config, then run `ailogger ca generate --force && ailogger ca install` so the root's name constraint covers them. Without re-minting, leaves for the new hosts fail verification — which is the constraint working as intended.

### Is there a UI?

Yes, a local dashboard on `http://127.0.0.1:8229`, loopback only and behind a random per-run token that `ailogger status` prints. It shows totals for today, 7 days or 30 days broken down by provider, model and app; an events list with filters for provider, app, model, status and policy hits; and a per-event detail page with every field and the redacted request and response.

### Who do I ask?

Open an issue on this repository, or email `hello@promptreceipt.com`.
