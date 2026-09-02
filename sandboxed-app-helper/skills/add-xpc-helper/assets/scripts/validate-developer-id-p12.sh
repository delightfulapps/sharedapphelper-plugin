#!/bin/bash
#
# validate-developer-id-p12.sh — Check a Developer ID Application .p12 before uploading it as a CI
# secret.
#
# The usual mistake is exporting the certificate without its private key, which produces a file that
# imports cleanly and then fails to sign anything — a failure that only shows up minutes into a CI
# run. This checks both halves are present, reports the expiry, and can print the base64 secret value.
#
# Usage:
#   scripts/validate-developer-id-p12.sh cert.p12 [--emit-base64]
#
set -euo pipefail

P12="${1:-}"
if [[ -z "$P12" || ! -f "$P12" ]]; then
  echo "usage: $0 <path-to.p12> [--emit-base64]" >&2
  exit 2
fi

# Prefer Homebrew's OpenSSL 3: LibreSSL (the system default on macOS) rejects the modern PKCS#12
# encryption Keychain Access now produces.
OPENSSL=openssl
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl; do
  [[ -x "$candidate" ]] && OPENSSL="$candidate" && break
done
echo "==> Using $($OPENSSL version)"

read -r -s -p "Password for $P12: " P12_PASSWORD
echo

DUMP=$(mktemp)
trap 'rm -f "$DUMP"' EXIT

if ! "$OPENSSL" pkcs12 -in "$P12" -nodes -passin pass:"$P12_PASSWORD" > "$DUMP" 2>/dev/null; then
  echo "error: couldn't read $P12 — wrong password, or not a PKCS#12 file." >&2
  exit 1
fi

if ! grep -q "BEGIN PRIVATE KEY\|BEGIN ENCRYPTED PRIVATE KEY\|BEGIN RSA PRIVATE KEY" "$DUMP"; then
  echo "error: no private key in $P12." >&2
  echo "       In Keychain Access, expand the certificate and select BOTH it and its private key" >&2
  echo "       before exporting." >&2
  exit 1
fi
echo "==> Private key: present"

SUBJECT=$("$OPENSSL" x509 -in "$DUMP" -noout -subject 2>/dev/null || true)
if ! grep -q "Developer ID Application" <<< "$SUBJECT"; then
  echo "error: the certificate is not a 'Developer ID Application' certificate:" >&2
  echo "       $SUBJECT" >&2
  echo "       An App Store or Apple Development certificate cannot notarize a helper." >&2
  exit 1
fi
echo "==> Certificate: $SUBJECT"
echo "==> Expires:     $("$OPENSSL" x509 -in "$DUMP" -noout -enddate | cut -d= -f2)"

if [[ "${2:-}" == "--emit-base64" ]]; then
  echo
  echo "==> Base64 value for the CI secret:"
  base64 < "$P12"
fi

echo
echo "==> Valid. Upload the base64 value as DEVELOPER_ID_CERT_P12_BASE64 and the password as"
echo "    DEVELOPER_ID_CERT_PASSWORD."
