#!/usr/bin/env bash
# Installs the ailogger binary, the local CA, the proxy environment variables and
# the user service. Everything it does is reversible: see "Uninstall" in README.md.
set -euo pipefail

AILOGGER_REPO="${AILOGGER_REPO:-robertatkinson3570/promptreceipt}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
# The agent/ directory when run from a checkout. Under `curl ... | bash` there is
# no script file, so BASH_SOURCE is unset and here stays empty: the download
# branch below is the only one that can work then.
here=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]:-}" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64|amd64) arch=amd64 ;;
  arm64|aarch64) arch=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
case "$os" in
  linux|darwin) ;;
  *) echo "unsupported OS: $os" >&2; exit 1 ;;
esac

mkdir -p "$BIN_DIR"

if [ -n "$here" ] && [ -f "$here/go.mod" ] && command -v go >/dev/null 2>&1; then
  echo "building from $here"
  ( cd "$here" \
    && stamp="$(git describe --tags --always 2>/dev/null || echo dev)" \
    && CGO_ENABLED=0 GOBIN="$BIN_DIR" go install -ldflags "-X main.version=$stamp" ./cmd/ailogger )
else
  # AILOGGER_VERSION pins a release tag (default: latest). AILOGGER_BASE_URL
  # replaces the GitHub release URL (the test suite points it at a local fake).
  version="${AILOGGER_VERSION:-}"
  if [ -z "$version" ]; then
    version="$(curl -fsSL "https://api.github.com/repos/$AILOGGER_REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [ -n "$version" ] || { echo "could not determine the latest release of $AILOGGER_REPO" >&2; exit 1; }
  base="${AILOGGER_BASE_URL:-https://github.com/$AILOGGER_REPO/releases/download/$version}"
  archive="ailogger_${version#v}_${os}_${arch}.tar.gz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "downloading $base/$archive"
  curl -fsSL "$base/$archive" -o "$tmp/$archive"
  curl -fsSL "$base/checksums.txt" -o "$tmp/checksums.txt"

  # The archive must match the release's checksums.txt before anything is extracted.
  grep -E "[[:space:]]\*?$archive\$" "$tmp/checksums.txt" > "$tmp/expected.txt" \
    || { echo "checksum verification failed: checksums.txt does not list $archive" >&2; exit 1; }
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$tmp" && sha256sum -c --status expected.txt ) \
      || { echo "checksum verification failed for $archive; refusing to install" >&2; exit 1; }
  else
    ( cd "$tmp" && shasum -a 256 -c --status expected.txt ) \
      || { echo "checksum verification failed for $archive; refusing to install" >&2; exit 1; }
  fi
  echo "checksum verified"

  # checksums.txt itself is signed keyless by the release workflow; verify it when cosign is here.
  if command -v cosign >/dev/null 2>&1; then
    for f in checksums.txt.sig checksums.txt.pem; do
      curl -fsSL "$base/$f" -o "$tmp/$f" \
        || { echo "signature verification failed: could not fetch $base/$f (cosign is installed, so the release must be signed); refusing to install" >&2; exit 1; }
    done
    cosign verify-blob \
      --certificate "$tmp/checksums.txt.pem" \
      --signature "$tmp/checksums.txt.sig" \
      --certificate-identity-regexp "^https://github.com/$AILOGGER_REPO/" \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      "$tmp/checksums.txt" \
      || { echo "signature verification failed for checksums.txt; refusing to install" >&2; exit 1; }
    echo "signature verified"
  else
    echo "signature verification skipped: cosign is not on PATH (checksum verified only)"
  fi

  tar -xzf "$tmp/$archive" -C "$tmp"
  install -m 0755 "$tmp/ailogger" "$BIN_DIR/ailogger"
  here="$tmp" # packaging/ ships inside the archive
fi

ailogger="$BIN_DIR/ailogger"
"$ailogger" ca generate >/dev/null
"$ailogger" ca install
"$ailogger" env install

case "$os" in
  linux)
    unit_dir="$HOME/.config/systemd/user"
    mkdir -p "$unit_dir"
    cp "$here/packaging/ailogger.service" "$unit_dir/ailogger.service"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --user daemon-reload
      systemctl --user enable --now ailogger
    else
      echo "systemctl not found; start the agent yourself with: $ailogger run"
    fi
    ;;
  darwin)
    agent_dir="$HOME/Library/LaunchAgents"
    mkdir -p "$agent_dir" "$HOME/Library/Logs"
    sed "s|__HOME__|$HOME|g" "$here/packaging/dev.ailogger.agent.plist" > "$agent_dir/dev.ailogger.agent.plist"
    launchctl unload "$agent_dir/dev.ailogger.agent.plist" 2>/dev/null || true
    launchctl load "$agent_dir/dev.ailogger.agent.plist"
    ;;
esac

echo
"$ailogger" status
echo
echo "log out and back in (or: systemctl --user import-environment; hyprctl reload) so every app sees the proxy variables."
