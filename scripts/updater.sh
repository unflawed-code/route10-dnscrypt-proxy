#!/bin/ash

# Keep this script buffered in memory to safely allow self-overwrite during update.
{
set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "$(basename "$SELF_DIR")" = "scripts" ]; then
    REMOTE_DIR="$(dirname "$SELF_DIR")"
else
    REMOTE_DIR="$SELF_DIR"
fi

LOG_FILE="/var/log/dnscrypt-proxy-updater.log"
GITHUB_REPO="unflawed-code/route10-dnscrypt-proxy"
LATEST_RELEASE_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
WEB_LATEST_URL="https://github.com/${GITHUB_REPO}/releases/latest"
RELEASE_DOWNLOAD_BASE="https://github.com/${GITHUB_REPO}/releases/download"
RELEASE_ASSET_PREFIX="route10-dnscrypt-proxy"
RELEASE_PUBKEY_REL="conf/release-pub.pem"
VENDOR_VERIFIER_REL="lib/vendor/route10-signature.sh"
INSTALL_VERSION_FILE="${REMOTE_DIR}/.installed-version"
SELF_SHELL="/bin/ash"
[ -x "$SELF_SHELL" ] || SELF_SHELL="/bin/sh"
ORIGINAL_ARGS="$*"

UPDATE_SUCCESS=0
UPDATE_TMP_DIR=""
UPDATE_BACKUP_DIR=""
APPLY_STARTED=0
PARITY_VERSION=""

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] updater: $*" | tee -a "$LOG_FILE"
}

get_dnscrypt_core_version() {
    [ -f "${REMOTE_DIR}/conf/setup.toml" ] || return 0
    awk '
        /^\[dnscrypt\]/ { in_dnscrypt = 1; next }
        /^\[/ { in_dnscrypt = 0 }
        in_dnscrypt && /^version[[:space:]]*=/ {
            print $3
            exit
        }
    ' "${REMOTE_DIR}/conf/setup.toml" 2>/dev/null | tr -d '\r" '
}

get_uci_installed_version() {
    command -v uci >/dev/null 2>&1 || return 0
    uci -q get dnscrypt-proxy.system.version 2>/dev/null | tr -d '\r[:space:]'
}

set_uci_installed_version() {
    local script_version="$1"
    local core_version

    command -v uci >/dev/null 2>&1 || return 0
    [ -f "/etc/config/dnscrypt-proxy" ] || touch "/etc/config/dnscrypt-proxy"
    if ! uci -q get dnscrypt-proxy.system >/dev/null 2>&1; then
        uci set dnscrypt-proxy.system=system
    fi

    uci set dnscrypt-proxy.system.version="$script_version"
    core_version="$(get_dnscrypt_core_version)"
    [ -n "$core_version" ] && uci set dnscrypt-proxy.system.dnscrypt="$core_version"
    uci commit dnscrypt-proxy >/dev/null 2>&1 || true
}

get_local_version() {
    local version
    if [ -f "$INSTALL_VERSION_FILE" ]; then
        version="$(sed -n '1p' "$INSTALL_VERSION_FILE" | tr -d '\r[:space:]')"
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    fi
    version=$(sed -n 's/^VERSION="\(.*\)"/\1/p' "${REMOTE_DIR}/setup.sh" | head -n 1 | tr -d '\r')
    [ -n "$version" ] || version="v0.0.0"
    echo "$version"
}

reconcile_version_parity() {
    local local_version="$1"
    local uci_version

    PARITY_VERSION="$local_version"
    uci_version="$(get_uci_installed_version)"
    if [ -z "$uci_version" ]; then
        printf '%s\n' "$PARITY_VERSION" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
        set_uci_installed_version "$PARITY_VERSION"
        return 0
    fi

    if [ "$uci_version" = "$PARITY_VERSION" ]; then
        return 0
    fi

    # Keep the newer one, then enforce parity across file + UCI.
    if version_gt "$uci_version" "$PARITY_VERSION"; then
        log "Version parity mismatch (file=${PARITY_VERSION}, uci=${uci_version}). Trusting UCI value."
        PARITY_VERSION="$uci_version"
        printf '%s\n' "$PARITY_VERSION" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
        return 0
    fi

    log "Version parity mismatch (file=${PARITY_VERSION}, uci=${uci_version}). Updating UCI to file version."
    set_uci_installed_version "$PARITY_VERSION"
}

fetch_url() {
    local url="$1"
    # TLS is never disabled: the signature is the trust anchor, but an
    # unvalidated transport should not be an accepted fallback.
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        return 1
    fi
}

download_file() {
    local url="$1"
    local dest="$2"

    rm -f "$dest"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$dest" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$url" -O "$dest" || return 1
    else
        log "ERROR: Neither curl nor wget is available."
        return 1
    fi

    [ -s "$dest" ]
}

validate_release_tag() {
    local tag="$1"

    [ -n "$tag" ] || return 1
    # The tag is interpolated into URLs and into setup.sh, so accept only the
    # vMAJOR.MINOR.PATCH[-suffix] shape this project publishes.
    printf '%s' "$tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+([._-][A-Za-z0-9.]+)?$' || return 1
    case "$tag" in
        *..*|*/*) return 1 ;;
    esac
    return 0
}

verify_release_signature() {
    local archive="$1"
    local signature="$2"
    local pubkey="$3"
    local vendor_dir="${UPDATE_VERIFY_VENDOR_DIR:-${REMOTE_DIR}/lib/vendor}"
    local verifier="${vendor_dir}/route10-signature.sh"
    local out

    if [ ! -f "$verifier" ]; then
        log "ERROR: Vendored signature verifier missing (${VENDOR_VERIFIER_REL}). Refusing update."
        return 1
    fi

    # shellcheck source=/dev/null
    . "$verifier"
    if ! command -v update_verify_signature >/dev/null 2>&1; then
        log "ERROR: Signature verifier did not define update_verify_signature. Refusing update."
        return 1
    fi

    if ! out=$(update_verify_signature "$archive" "$signature" "$pubkey"); then
        log "ERROR: Release signature verification failed: ${out}"
        return 1
    fi
    log "Release signature verified: ${out}"
    return 0
}

stage_trust_anchor() {
    local archive="$1"
    local stage_dir="${UPDATE_TMP_DIR}/trust-anchor"
    local key_member
    local verifier_member

    log "WARNING: No local trust anchor (${RELEASE_PUBKEY_REL}); bootstrapping it from this release."
    log "WARNING: The key is pinned on this device from this update onwards; every later release must match it."

    key_member="$(tar -tzf "$archive" 2>/dev/null | grep -m1 "/${RELEASE_PUBKEY_REL}\$" || true)"
    verifier_member="$(tar -tzf "$archive" 2>/dev/null | grep -m1 "/${VENDOR_VERIFIER_REL}\$" || true)"
    [ -n "$key_member" ] && [ -n "$verifier_member" ] || return 1

    rm -rf "$stage_dir"
    mkdir -p "$stage_dir" || return 1
    # Unpack only the anchor and the verifier: the rest of the archive stays
    # compressed until the signature over it has been checked.
    tar -xzf "$archive" -C "$stage_dir" "$key_member" "$verifier_member" || return 1

    [ -s "${stage_dir}/${key_member}" ] || return 1
    cp -f "${stage_dir}/${key_member}" "${UPDATE_TMP_DIR}/release-pub.pem" || return 1
    UPDATE_VERIFY_VENDOR_DIR="$(dirname "${stage_dir}/${verifier_member}")"
}

extract_first_tag() {
    tr '{' '\n' | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}

get_latest_version_tag() {
    local tag=""

    # Method 1: GitHub API (Primary)
    tag=$(fetch_url "$LATEST_RELEASE_URL" | extract_first_tag || true)

    # Method 2: Fallback to Redirect (No API rate limits)
    if [ -z "$tag" ]; then
        if command -v curl >/dev/null 2>&1; then
            tag=$(curl -sIL "$WEB_LATEST_URL" | grep -i "^location:" | sed -n 's/.*\/tag\(s\)\?\/\([^[:space:]\r]*\).*/\2/p' | tail -n 1)
        elif command -v wget >/dev/null 2>&1; then
            tag=$(wget --no-check-certificate -S --spider "$WEB_LATEST_URL" 2>&1 | grep -i "Location:" | sed -n 's/.*\/tag\(s\)\?\/\([^[:space:]\r]*\).*/\2/p' | tail -n 1)
        fi
    fi

    [ -n "$tag" ] || return 1
    echo "$tag" | tr -d '\r'
}

get_prerelease_info() {
    local ver="$1"
    local pri=3
    local val=0

    if echo "$ver" | grep -q "-"; then
        if echo "$ver" | grep -iq "rc"; then
            pri=2
            val=$(echo "$ver" | sed -n 's/.*[Rr][Cc]//p' | tr -dc '0-9')
        elif echo "$ver" | grep -iq "beta"; then
            pri=1
            val=$(echo "$ver" | sed -n 's/.*[Bb][Ee][Tt][Aa]//p' | tr -dc '0-9')
        else
            pri=0
            val=$(echo "$ver" | sed 's/.*-//' | tr -dc '0-9')
        fi
    fi
    echo "${pri} ${val:-0}"
}

version_gt() {
    # Strip everything after '-' to handle rc/beta versions correctly in integer comparisons
    local v1=$(echo "$1" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')
    local v2=$(echo "$2" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')
    
    local i=1
    while [ $i -le 3 ]; do
        local p1=$(echo "$v1" | cut -d. -f$i); [ -z "$p1" ] && p1=0
        local p2=$(echo "$v2" | cut -d. -f$i); [ -z "$p2" ] && p2=0
        if [ "$p1" -gt "$p2" ]; then return 0; fi
        if [ "$p1" -lt "$p2" ]; then return 1; fi
        i=$((i+1))
    done

    # Compare pre-release priority and value
    local info1=$(get_prerelease_info "$1")
    local info2=$(get_prerelease_info "$2")
    
    local pri1=$(echo "$info1" | cut -d' ' -f1)
    local val1=$(echo "$info1" | cut -d' ' -f2)
    local pri2=$(echo "$info2" | cut -d' ' -f1)
    local val2=$(echo "$info2" | cut -d' ' -f2)

    if [ "$pri1" -gt "$pri2" ]; then return 0; fi
    if [ "$pri1" -lt "$pri2" ]; then return 1; fi
    if [ "$val1" -gt "$val2" ]; then return 0; fi

    return 1
}

rollback_update() {
    local backup_dir="$1"
    log "CRITICAL: Update failed. Starting rollback."
    [ -d "$backup_dir" ] || { log "ERROR: Rollback failed - backup missing."; return 1; }

    rm -rf "${REMOTE_DIR:?}/"*
    cp -rf "${backup_dir}/"* "$REMOTE_DIR/"
    ensure_script_permissions "$REMOTE_DIR"
    /bin/ash "${REMOTE_DIR}/setup.sh" --non-interactive --keep-binary || log "WARNING: Rollback setup also failed."
    log "Rollback complete."
}

cleanup_trap() {
    # Only roll back when the live tree was actually being rewritten; a failed
    # download or signature check must never touch the running install.
    if [ "$UPDATE_SUCCESS" -eq 0 ] && [ "$APPLY_STARTED" -eq 1 ] && [ -n "$UPDATE_BACKUP_DIR" ]; then
        rollback_update "$UPDATE_BACKUP_DIR" || true
    fi
    if [ -n "$UPDATE_TMP_DIR" ]; then
        rm -rf "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR" 2>/dev/null || true
    fi
}

ensure_script_permissions() {
    local target_dir="$1"
    [ -d "$target_dir" ] || return 0

    find "$target_dir" -type f -name '*.sh' | while IFS= read -r script; do
        [ -f "$script" ] || continue
        if [ ! -x "$script" ]; then
            chmod 700 "$script"
            log "Repaired execute permission on $script"
        fi
    done
}

perform_update() {
    local latest_tag="$1"
    local asset_name
    local release_url
    local archive_path
    local signature_path
    local extracted_root
    local keep_file
    local keep_target

    if ! validate_release_tag "$latest_tag"; then
        log "ERROR: Refusing unexpected release tag '${latest_tag}'."
        return 1
    fi

    asset_name="${RELEASE_ASSET_PREFIX}-${latest_tag}.tar.gz"
    release_url="${RELEASE_DOWNLOAD_BASE}/${latest_tag}"

    UPDATE_TMP_DIR="/tmp/dnscrypt-proxy-update"
    UPDATE_BACKUP_DIR="/tmp/dnscrypt-proxy-backup"
    archive_path="${UPDATE_TMP_DIR}/update.tar.gz"
    signature_path="${archive_path}.sig"

    rm -rf "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR"
    mkdir -p "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR"

    log "Creating backup at $UPDATE_BACKUP_DIR"
    cp -rf "${REMOTE_DIR}/"* "$UPDATE_BACKUP_DIR/"

    trap cleanup_trap EXIT

    # Signed release asset, not the unsigned source tarball at
    # archive/refs/tags/ - the signature only exists for what CI built.
    log "Downloading ${release_url}/${asset_name}"
    download_file "${release_url}/${asset_name}" "$archive_path" || {
        log "ERROR: Download failed: ${asset_name}. Refusing update."
        return 1
    }

    log "Downloading ${asset_name}.sig"
    download_file "${release_url}/${asset_name}.sig" "$signature_path" || {
        log "ERROR: Download failed: ${asset_name}.sig. Refusing update."
        return 1
    }

    if [ -s "${REMOTE_DIR}/${RELEASE_PUBKEY_REL}" ]; then
        cp -f "${REMOTE_DIR}/${RELEASE_PUBKEY_REL}" "${UPDATE_TMP_DIR}/release-pub.pem" || return 1
    elif ! stage_trust_anchor "$archive_path"; then
        # The anchor cannot travel over the channel it protects, so a device
        # that has never held it pins one once, from a release it verifies with
        # that same key before the live tree is touched. Refusing outright is
        # the only alternative, and it leaves such a device unable to update.
        log "ERROR: Release public key missing (${RELEASE_PUBKEY_REL}) and absent from the release. Refusing update."
        return 1
    fi

    # Fail closed, and only once the archive bytes are proven: nothing has been
    # extracted or written into the live tree at this point.
    verify_release_signature "$archive_path" "$signature_path" "${UPDATE_TMP_DIR}/release-pub.pem" || return 1

    log "Extracting update archive"
    tar -xzf "$archive_path" -C "$UPDATE_TMP_DIR" || return 1
    extracted_root="$(ls -d "${UPDATE_TMP_DIR}/${GITHUB_REPO##*/}"* 2>/dev/null | head -n 1)"
    [ -d "$extracted_root" ] || return 1

    # --- Self-Update Check ---
    # Detect if the updater itself has changed in the downloaded version.
    # If so, replace the current script and restart using 'exec' so 
    # the new logic is used for the application phase.
    local new_updater="${extracted_root}/scripts/updater.sh"
    [ ! -f "$new_updater" ] && new_updater="${extracted_root}/updater.sh"
    
    if [ -f "$new_updater" ] && ! cmp -s "$0" "$new_updater" 2>/dev/null; then
        log "New updater logic detected. Self-updating before proceeding..."
        cp -f "$new_updater" "$0"
        chmod 700 "$0"
        log "Restarting updater to use the latest application logic..."
        if [ -n "$ORIGINAL_ARGS" ]; then
            exec "$SELF_SHELL" "$0" $ORIGINAL_ARGS
        else
            exec "$SELF_SHELL" "$0"
        fi
    fi

    # Determine if the dnscrypt core version has changed
    local old_core_ver
    local new_core_ver
    old_core_ver=$(get_dnscrypt_core_version)
    new_core_ver=""
    if [ -f "${extracted_root}/conf/setup.toml" ]; then
        new_core_ver=$(awk '
            /^\[dnscrypt\]/ { in_dnscrypt = 1; next }
            /^\[/ { in_dnscrypt = 0 }
            in_dnscrypt && /^version[[:space:]]*=/ {
                print $3
                exit
            }
        ' "${extracted_root}/conf/setup.toml" 2>/dev/null | tr -d '\r" ')
    fi

    local keep_binary=1
    if [ -n "$old_core_ver" ] && [ -n "$new_core_ver" ] && [ "$old_core_ver" != "$new_core_ver" ]; then
        log "DNSCrypt core version upgrade detected: ${old_core_ver} -> ${new_core_ver}. Will download new binary."
        keep_binary=0
    fi

    # Preserve local custom overrides, and local binary if it hasn't changed.
    # The trusted public key is restored after the copy: if a release could
    # replace it, an attacker could ship their own key and archive.
    local keep_files="conf/setup-custom.toml conf/dnscrypt-proxy-custom.toml conf/custom.toml ${RELEASE_PUBKEY_REL}"
    if [ "$keep_binary" -eq 1 ]; then
        keep_files="${keep_files} dnscrypt-proxy"
    fi

    for keep_file in $keep_files; do
        if [ -f "${REMOTE_DIR}/${keep_file}" ]; then
            keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
            mkdir -p "$(dirname "$keep_target")"
            cp -f "${REMOTE_DIR}/${keep_file}" "$keep_target"
        fi
    done

    log "Applying update files to ${REMOTE_DIR}"
    APPLY_STARTED=1
    cp -rf "${extracted_root}/"* "$REMOTE_DIR/"

    for keep_file in $keep_files; do
        keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
        if [ -f "$keep_target" ]; then
            mkdir -p "$(dirname "${REMOTE_DIR}/${keep_file}")"
            cp -f "$keep_target" "${REMOTE_DIR}/${keep_file}"
        fi
    done

    # --- Force setup.sh code version to match the tag name ---
    if [ -f "${REMOTE_DIR}/setup.sh" ]; then
        sed -i "s|^VERSION=.*|VERSION=\"$latest_tag\"|" "${REMOTE_DIR}/setup.sh"
        log "Forced local version string in setup.sh to '$latest_tag' to match tag."
    fi

    ensure_script_permissions "$REMOTE_DIR"

    log "Running setup.sh in non-interactive mode"
    # Pipe an explicit "no" in case the fetched release contains an older interactive setup.sh.
    local setup_args="--non-interactive"
    if [ "$keep_binary" -eq 1 ]; then
        setup_args="${setup_args} --keep-binary"
    fi
    printf 'n\n' | /bin/ash "${REMOTE_DIR}/setup.sh" $setup_args || return 1

    log "Restarting DNSCrypt service with new scripts"
    /bin/ash "${REMOTE_DIR}/proxy.sh" start -f || return 1

    printf '%s\n' "$latest_tag" > "$INSTALL_VERSION_FILE" 2>/dev/null || true
    set_uci_installed_version "$latest_tag"
    UPDATE_SUCCESS=1
    log "Update to ${latest_tag} completed successfully."
    return 0
}

check_and_update() {
    local force="${1:-0}"
    local local_version
    local latest_tag

    local_version="$(get_local_version)"
    reconcile_version_parity "$local_version"
    local_version="$PARITY_VERSION"
    latest_tag="$(get_latest_version_tag)" || {
        log "ERROR: Unable to fetch latest release tag."
        return 1
    }

    if ! validate_release_tag "$latest_tag"; then
        log "ERROR: Unexpected release tag '${latest_tag}'. Refusing update."
        return 1
    fi

    if version_gt "$latest_tag" "$local_version" || [ "$force" = "1" ]; then
        [ "$force" = "1" ] && log "Force update requested." || log "New release available (${local_version} -> ${latest_tag})."
        perform_update "$latest_tag"
    else
        log "No updates found."
    fi
}

# Allow tests to source the helpers without starting an update.
if [ "${UPDATER_LIB_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

cmd="${1:-check}"
case "$cmd" in
    check) check_and_update 0 ;;
    force) check_and_update 1 ;;
    *)
        echo "Usage: $0 {check|force}"
        exit 1
        ;;
esac

} # End buffered block
