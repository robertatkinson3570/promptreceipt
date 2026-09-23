# Installing Prompt Receipt

Prompt Receipt (CLI: `ailogger`) runs on Linux and macOS. Windows is planned with the Enterprise tier.

> Release binaries are published on this repository's Releases page. Until the first tagged release is up, the installer needs a source checkout (see "From source" below).

## The one-liner

```bash
curl -fsSL https://raw.githubusercontent.com/robertatkinson3570/promptreceipt/main/install.sh | bash
ailogger status
```

This installs `~/.local/bin/ailogger`, generates and trusts the local root CA, writes the proxy environment variables, and enables the user service (systemd on Linux, launchd on macOS).

**Log out and back in afterwards**, or run `systemctl --user import-environment` (plus `hyprctl reload` under Hyprland), so every application sees the new environment variables. Applications started before that keep their old environment and will not be logged.

Before it extracts anything, the script downloads the release's `checksums.txt` and checks the archive against it with `sha256sum -c`, or `shasum -a 256` where that is missing; a mismatch aborts the install. If `cosign` is on `PATH` it also verifies the keyless signature over `checksums.txt`; otherwise it says so and continues on the checksum alone.

If you would rather read it first — and you should, since it installs a root certificate:

```bash
curl -fsSL https://raw.githubusercontent.com/robertatkinson3570/promptreceipt/main/install.sh -o install.sh
less install.sh
bash install.sh
```

### Variables the installer honours

| Variable | Effect |
|---|---|
| `AILOGGER_VERSION=v1.2.3` | pin a release tag instead of taking the latest |
| `BIN_DIR=/usr/local/bin` | install the binary somewhere other than `~/.local/bin` |
| `AILOGGER_REPO=owner/repo` | fetch releases from a different repository |
| `AILOGGER_BASE_URL=…` | replace the release download URL entirely |

## From a release archive

Download the archive for your platform from the [Releases page](https://github.com/robertatkinson3570/promptreceipt/releases), verify it (below), then:

```bash
tar xzf ailogger_<version>_<os>_<arch>.tar.gz
install -m755 ailogger ~/.local/bin/ailogger
ailogger ca generate                    # create the local root CA
ailogger ca install                     # trust it for Chromium/NSS and the env-var tools
ailogger ca install --system            # also system trust store and Firefox policy (calls sudo)
ailogger env install                    # HTTPS_PROXY, SSL_CERT_FILE, NODE_EXTRA_CA_CERTS, …
ailogger status
```

Then enable it as a service. On Linux, copy the shipped `ailogger.service` into `~/.config/systemd/user/` and run `systemctl --user enable --now ailogger`. On macOS, copy the shipped `dev.ailogger.agent.plist` into `~/Library/LaunchAgents`, replacing `__HOME__` with your home directory first — launchd does not expand `~` — and load it with `launchctl`.

## Verifying a release

Every release is built by a GitHub Actions workflow with goreleaser (`-trimpath`, commit timestamps, static cgo-free binaries), ships a CycloneDX SBOM per archive (`*.cdx.json`, produced by syft), and signs `checksums.txt` keylessly with cosign through GitHub's OIDC identity. To verify by hand:

```bash
V=v1.2.3; A=ailogger_${V#v}_linux_amd64.tar.gz
B=https://github.com/robertatkinson3570/promptreceipt/releases/download/$V
curl -fsSLO $B/$A; curl -fsSLO $B/checksums.txt
curl -fsSLO $B/checksums.txt.sig; curl -fsSLO $B/checksums.txt.pem
cosign verify-blob \
  --certificate checksums.txt.pem --signature checksums.txt.sig \
  --certificate-identity-regexp '^https://github.com/robertatkinson3570/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum -c --ignore-missing checksums.txt   # macOS: shasum -a 256 -c --ignore-missing checksums.txt
```

The first command proves `checksums.txt` was produced by the release workflow; the second proves the archive you downloaded is the one it lists.

## From source

The agent is Apache-2.0 and the source repository is being prepared for publication. Once it is public, `go install <module>/cmd/ailogger@latest` will work and this page will name the module path.

From a checkout of the source, running `install.sh` next to the Go module builds the binary with your local toolchain (`CGO_ENABLED=0 go install ./cmd/ailogger`) and then performs the same CA, environment and service steps as the release path — the script takes the build branch automatically when it finds a `go.mod` beside it and `go` on `PATH`.

## Package managers

| Method | Status |
|---|---|
| Homebrew tap (`brew install`) | coming |
| Arch User Repository (`ailogger-bin`) | coming |
| mise (`mise use -g ailogger`) | coming |
| Docker image for the console | coming with the console |
| MSI and `.pkg` for managed fleets | Enterprise tier |

## After installing

```bash
ailogger status     # config path, data dir, CA fingerprint, proxy reachability, dashboard link, spool counts
ailogger tail       # follow calls as they happen
ailogger export --since 24h --out events.jsonl
```

`ailogger status` prints the dashboard URL with its per-run token: `http://127.0.0.1:8229/?t=<token>`. Opening it sets an `HttpOnly`, `SameSite=Strict` cookie and redirects to the page without the token.

Configuration lives at `~/.config/ailogger/config.yaml` (or `$XDG_CONFIG_HOME/ailogger/config.yaml`). A missing file means defaults:

```yaml
listen: 127.0.0.1:8228          # loopback only; anything else is a configuration error
ui: 127.0.0.1:8229              # local dashboard; empty disables it
data_dir: ~/.local/share/ailogger
watch_hosts: []                 # extra hosts to intercept, added to the built-in list
upstream_proxy: ""              # http://, https:// or socks5:// URL for intercepted hosts
content: true                   # record prompts and responses; false keeps metadata only
local_retention_days: 30        # delete delivered events older than this
sinks:
  jsonl: ~/.local/share/ailogger/events.jsonl   # empty disables the sink
  jsonl_max_mb: 100
  jsonl_keep: 5
```

After changing `watch_hosts`, re-mint the root so its name constraint covers the new hosts:

```bash
ailogger ca generate --force && ailogger ca install
```

## Firefox, Chromium and the trust store

Without `--system`, `ailogger ca install` covers Chromium and NSS-based browsers and every tool that reads `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE` or `CURL_CA_BUNDLE`. Firefox reads none of those: it needs `ailogger ca install --system`, which writes an enterprise policy. An existing policy file is merged into rather than replaced, with the original backed up and restored on uninstall.

Run `ca install` as your own user, never under `sudo` — it refuses, and calls `sudo` itself for the two privileged steps. System trust is supported on p11-kit distributions (Arch, Fedora); Debian and Ubuntu system trust is not supported yet.

`--system` trusts your root for every account on the machine. Use it on a single-user machine only.

## macOS caveat

The macOS paths are written but have not yet been exercised on a Mac: the keychain install and uninstall, `lsof`-based process attribution, and `launchctl setenv` for the environment variables. There is also no system-proxy capture, so only applications that honour the proxy environment variables are seen, and no peer-uid check on the proxy port.

## Uninstall

```bash
systemctl --user disable --now ailogger && rm ~/.config/systemd/user/ailogger.service  # Linux
launchctl unload ~/Library/LaunchAgents/dev.ailogger.agent.plist                       # macOS
rm ~/Library/LaunchAgents/dev.ailogger.agent.plist ~/Library/Logs/ailogger.log         # macOS
ailogger env uninstall     # removes the env files and the marked block from ~/.profile
ailogger ca uninstall      # reverts every trust-store change, in reverse order
rm -rf ~/.local/share/ailogger ~/.config/ailogger ~/.local/bin/ailogger
```

Run `ailogger env uninstall` **before** you delete the binary. Applications that still have `HTTPS_PROXY` pointing at a stopped agent cannot reach the network until the variables are gone.

`ca uninstall` reverts exactly the steps recorded in the install log — certificate database entries, the system anchor, the Firefox policy. `env uninstall` removes only its own files and the marked `# >>> ailogger >>>` blocks. After those two commands plus the `rm`, nothing of Prompt Receipt is left on the machine.

## Troubleshooting

**`ailogger status` says the proxy is unreachable.** The service is not running. `systemctl --user status ailogger`, or run `ailogger run` in a terminal and read the log.

**An application reports a certificate error.** It does not read any of the trust-store variables and was not covered by `ca install`. Firefox needs `--system`; Java, Go and some Rust tools carry their own stores and need the root added there by hand.

**Nothing appears in `ailogger tail`.** The application was started before `env install` and still has the old environment, or it ignores proxy variables entirely. Log out and back in, then start it again.

**Everything is slow or offline after stopping the agent.** The proxy variables are still set. Run `ailogger env uninstall` and open a new login session.
