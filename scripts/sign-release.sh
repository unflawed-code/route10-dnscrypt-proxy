#!/bin/sh
# Sign a release archive with the offline release signing key.
#
#   ./scripts/sign-release.sh route10-dnscrypt-proxy-v3.4.0.tar.gz
#
# Writes <archive>.sig next to the archive. Publish it as a release asset:
#
#   gh release upload v3.4.0 route10-dnscrypt-proxy-v3.4.0.tar.gz.sig
#
# The private key is read from $RELEASE_SIGNING_KEY (default:
# .release-keys/release-signing-key.pem). It must never be committed, copied to
# a device, or stored in CI - keeping it off GitHub is the entire point.
#
# The signature is checked against conf/release-pub.pem before this script
# exits, so a wrong signing key fails here instead of on every router.

set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ $# -lt 1 ]; then
    echo "Usage: $0 <archive> [key-file]" >&2
    exit 1
fi

archive="$1"
[ -f "$archive" ] || { echo "ERROR: no such file: $archive" >&2; exit 1; }

key="${2:-${RELEASE_SIGNING_KEY:-${ROOT}/.release-keys/release-signing-key.pem}}"
[ -f "$key" ] || { echo "ERROR: signing key not found: $key" >&2; exit 1; }

pubkey="${RELEASE_PUBLIC_KEY:-${ROOT}/conf/release-pub.pem}"
[ -f "$pubkey" ] || { echo "ERROR: public key not found: $pubkey" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || { echo "ERROR: openssl is required" >&2; exit 1; }

openssl dgst -sha256 -sign "$key" -out "${archive}.sig" "$archive" || {
    echo "ERROR: signing failed" >&2
    exit 1
}

if ! openssl dgst -sha256 -verify "$pubkey" -signature "${archive}.sig" "$archive" >/dev/null 2>&1; then
    rm -f "${archive}.sig"
    echo "ERROR: signature does not verify against ${pubkey}; wrong signing key?" >&2
    exit 1
fi

echo "Signed and verified: ${archive}.sig"
