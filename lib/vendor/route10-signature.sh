#!/bin/sh
# route10-update-verifier - detached-signature verification for release updates.
#
# verifier-version: 1.0.0
#
# Source this file, then call update_verify_signature. It has no dependencies
# beyond openssl and a POSIX shell (BusyBox ash on OpenWrt is fine).
#
# Vendored copies are pinned by digest: edit this file here, not in a consumer
# repository, and let the consumer's CI reject a hand-modified copy.

# Verify the detached signature $2 over artifact $1 with public key $3.
#
# This is the authoritative integrity check: the signing key never exists in
# the repository or on GitHub, so a compromised repository can publish a new
# artifact, SHA256SUMS and provenance, but cannot produce a valid signature.
update_verify_signature() {
    local archive="$1"
    local sig="$2"
    local pubkey="$3"
    local out

    [ -s "$archive" ] || { echo "artifact is missing or empty"; return 1; }
    [ -s "$sig" ] || { echo "release signature is missing or empty"; return 1; }
    [ -s "$pubkey" ] || { echo "release public key is missing or empty"; return 1; }
    command -v openssl >/dev/null 2>&1 || { echo "openssl is required to verify the release signature"; return 1; }

    if ! out=$(openssl dgst -sha256 -verify "$pubkey" -signature "$sig" "$archive" 2>&1); then
        echo "release signature does not match the artifact: $(printf '%s' "$out" | tr '\n\t' '  ' | cut -c1-200)"
        return 1
    fi

    echo "signature verified"
}
