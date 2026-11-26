#!/bin/sh
# Hermetic tests for release signature verification.
#
#   sh tests/test_signature_verify.sh
#
# Covers the pinned digest of the vendored verifier, the accept/reject matrix
# for update_verify_signature, and the updater's fail-closed helpers. Generates
# throwaway keys in a temp directory; needs no network.

set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t r10sig)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

say_pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
say_fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

assert_ok() {
    msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then say_pass "$msg"; else say_fail "$msg"; fi
}

assert_fail() {
    msg="$1"
    shift
    if "$@" >/dev/null 2>&1; then say_fail "$msg"; else say_pass "$msg"; fi
}

echo "=== route10-dnscrypt-proxy: release signature verification ==="

# The vendored copy must be the pinned one, not a hand-edited version.
assert_ok "vendored verifier matches its pinned digest" \
    sh -c "cd '${ROOT}/lib/vendor' && sha256sum -c route10-signature.sh.sha256"

assert_ok "shipped release public key is a valid PEM key" \
    sh -c "openssl pkey -pubin -in '${ROOT}/conf/release-pub.pem' -noout"

if ! command -v openssl >/dev/null 2>&1; then
    echo "[SKIP] openssl not available; signature matrix not exercised."
    echo "-----------------------------"
    echo "Passed: $PASS"
    echo "Failed: $FAIL"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# shellcheck source=/dev/null
. "${ROOT}/lib/vendor/route10-signature.sh"

key="$TMP_DIR/key.pem"
pub="$TMP_DIR/pub.pem"
other_key="$TMP_DIR/other.pem"
other_pub="$TMP_DIR/other-pub.pem"
artifact="$TMP_DIR/route10-dnscrypt-proxy-v9.9.9.tar.gz"

openssl ecparam -name prime256v1 -genkey -noout -out "$key" 2>/dev/null
openssl ec -in "$key" -pubout -out "$pub" 2>/dev/null
openssl ecparam -name prime256v1 -genkey -noout -out "$other_key" 2>/dev/null
openssl ec -in "$other_key" -pubout -out "$other_pub" 2>/dev/null
printf 'release payload\n' > "$artifact"
openssl dgst -sha256 -sign "$key" -out "${artifact}.sig" "$artifact" 2>/dev/null

assert_ok "valid signature accepted" \
    update_verify_signature "$artifact" "${artifact}.sig" "$pub"

printf 'tampered\n' >> "$artifact"
assert_fail "signature over a modified archive rejected" \
    update_verify_signature "$artifact" "${artifact}.sig" "$pub"

printf 'release payload\n' > "$artifact"
assert_fail "signature from a different key rejected" \
    update_verify_signature "$artifact" "${artifact}.sig" "$other_pub"

assert_fail "missing signature rejected" \
    update_verify_signature "$artifact" "$TMP_DIR/absent.sig" "$pub"

: > "$TMP_DIR/empty.sig"
assert_fail "empty signature rejected" \
    update_verify_signature "$artifact" "$TMP_DIR/empty.sig" "$pub"

assert_fail "missing public key rejected" \
    update_verify_signature "$artifact" "${artifact}.sig" "$TMP_DIR/absent.pem"

printf 'not a key\n' > "$TMP_DIR/garbage.pem"
assert_fail "malformed public key rejected" \
    update_verify_signature "$artifact" "${artifact}.sig" "$TMP_DIR/garbage.pem"

# --- updater wiring -------------------------------------------------------
# The updater is sourced with UPDATER_LIB_ONLY=1 so only helpers are defined.

tag_case() {
    tag="$1"
    want="$2"
    desc="$3"
    if (
        set +e
        UPDATER_LIB_ONLY=1
        export UPDATER_LIB_ONLY
        . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
        validate_release_tag "$tag"
    ); then
        got=accept
    else
        got=reject
    fi
    if [ "$got" = "$want" ]; then say_pass "$desc"; else say_fail "$desc (got $got)"; fi
}

tag_case "v3.4.0" accept "release tag v3.4.0 accepted"
tag_case "v3.4.0-rc1" accept "release tag v3.4.0-rc1 accepted"
tag_case "main" reject "branch name rejected as a release tag"
tag_case "../../refs/heads/main" reject "path traversal rejected as a release tag"
tag_case "v3.4.0;reboot" reject "shell metacharacters rejected as a release tag"
tag_case "" reject "empty release tag rejected"

# A missing vendored verifier must abort the update rather than skip the check.
empty_remote="$TMP_DIR/remote-no-vendor"
mkdir -p "$empty_remote"
printf 'key\n' > "$TMP_DIR/dummy-pub.pem"

if (
    set +e
    UPDATER_LIB_ONLY=1
    export UPDATER_LIB_ONLY
    . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
    LOG_FILE="$TMP_DIR/updater.log"
    REMOTE_DIR="$empty_remote"
    verify_release_signature "$artifact" "${artifact}.sig" "$TMP_DIR/dummy-pub.pem"
); then
    say_fail "updater refuses update when the vendored verifier is missing"
else
    say_pass "updater refuses update when the vendored verifier is missing"
fi

# With the verifier present, the same call must verify the archive end to end.
vendored_remote="$TMP_DIR/remote-with-vendor"
mkdir -p "$vendored_remote/lib"
cp -R "${ROOT}/lib/vendor" "$vendored_remote/lib/vendor"

if (
    set +e
    UPDATER_LIB_ONLY=1
    export UPDATER_LIB_ONLY
    . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
    LOG_FILE="$TMP_DIR/updater.log"
    REMOTE_DIR="$vendored_remote"
    verify_release_signature "$artifact" "${artifact}.sig" "$pub"
); then
    say_pass "updater verifies a signed archive when the verifier is present"
else
    say_fail "updater verifies a signed archive when the verifier is present"
fi

if (
    set +e
    UPDATER_LIB_ONLY=1
    export UPDATER_LIB_ONLY
    . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
    LOG_FILE="$TMP_DIR/updater.log"
    REMOTE_DIR="$vendored_remote"
    verify_release_signature "$artifact" "${artifact}.sig" "$other_pub"
); then
    say_fail "updater rejects an archive signed by a different key"
else
    say_pass "updater rejects an archive signed by a different key"
fi

# A device with no local trust anchor bootstraps the verifier from the release,
# so the verifier location must be redirectable.
if (
    set +e
    UPDATER_LIB_ONLY=1
    export UPDATER_LIB_ONLY
    . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
    LOG_FILE="$TMP_DIR/updater.log"
    REMOTE_DIR="$empty_remote"
    UPDATE_VERIFY_VENDOR_DIR="${ROOT}/lib/vendor"
    export UPDATE_VERIFY_VENDOR_DIR
    verify_release_signature "$artifact" "${artifact}.sig" "$pub"
); then
    say_pass "updater verifies against an explicitly supplied verifier path"
else
    say_fail "updater verifies against an explicitly supplied verifier path"
fi

# --- trust-anchor bootstrap ----------------------------------------------
# First hardened update on a device that has never held the key.

anchor_src="$TMP_DIR/anchor-src/route10-dnscrypt-proxy-v9.9.9"
mkdir -p "$anchor_src/conf" "$anchor_src/lib/vendor" "$anchor_src/scripts"
cp "${ROOT}/conf/release-pub.pem" "$anchor_src/conf/release-pub.pem"
cp "${ROOT}/lib/vendor/route10-signature.sh" "$anchor_src/lib/vendor/route10-signature.sh"
printf 'payload\n' > "$anchor_src/scripts/start.sh"
tar -czf "$TMP_DIR/anchored.tar.gz" -C "$TMP_DIR/anchor-src" route10-dnscrypt-proxy-v9.9.9

mkdir -p "$TMP_DIR/keyless-src/route10-dnscrypt-proxy-v9.9.9/scripts"
printf 'payload\n' > "$TMP_DIR/keyless-src/route10-dnscrypt-proxy-v9.9.9/scripts/start.sh"
tar -czf "$TMP_DIR/keyless.tar.gz" -C "$TMP_DIR/keyless-src" route10-dnscrypt-proxy-v9.9.9

anchor_case() {
    archive="$1"
    want="$2"
    desc="$3"
    if (
        set +e
        UPDATER_LIB_ONLY=1
        export UPDATER_LIB_ONLY
        . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
        LOG_FILE="$TMP_DIR/updater.log"
        UPDATE_TMP_DIR="$TMP_DIR/stage"
        mkdir -p "$UPDATE_TMP_DIR"
        stage_trust_anchor "$archive"
    ); then
        got=accept
    else
        got=reject
    fi
    if [ "$got" = "$want" ]; then say_pass "$desc"; else say_fail "$desc (got $got)"; fi
}

anchor_case "$TMP_DIR/anchored.tar.gz" accept "anchor staging accepts a release that ships a key"
anchor_case "$TMP_DIR/keyless.tar.gz" reject "anchor staging refuses a release with no key"

# The staged key must be the one the signature is checked against, end to end.
if (
    set +e
    UPDATER_LIB_ONLY=1
    export UPDATER_LIB_ONLY
    . "${ROOT}/scripts/updater.sh" >/dev/null 2>&1 || exit 99
    LOG_FILE="$TMP_DIR/updater.log"
    UPDATE_TMP_DIR="$TMP_DIR/stage-e2e"
    mkdir -p "$UPDATE_TMP_DIR"
    stage_trust_anchor "$TMP_DIR/anchored.tar.gz" || exit 98
    REMOTE_DIR="$empty_remote"
    verify_release_signature "$artifact" "${artifact}.sig" "${UPDATE_TMP_DIR}/release-pub.pem"
); then
    say_fail "staged key from a different release rejects the archive"
else
    say_pass "staged key from a different release rejects the archive"
fi

echo "-----------------------------"
echo "Passed: $PASS"
echo "Failed: $FAIL"

[ "$FAIL" -eq 0 ] || exit 1
exit 0
