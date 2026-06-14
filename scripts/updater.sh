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
INSTALL_VERSION_FILE="${REMOTE_DIR}/.installed-version"
SELF_SHELL="/bin/ash"
[ -x "$SELF_SHELL" ] || SELF_SHELL="/bin/sh"
ORIGINAL_ARGS="$*"

UPDATE_SUCCESS=0
UPDATE_TMP_DIR=""
UPDATE_BACKUP_DIR=""
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
    if command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -qO- "$url"
    elif command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url"
    else
        return 1
    fi
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
    if [ "$UPDATE_SUCCESS" -eq 0 ] && [ -n "$UPDATE_BACKUP_DIR" ]; then
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
    local archive_url="https://github.com/${GITHUB_REPO}/archive/refs/tags/${latest_tag}.tar.gz"
    local archive_path
    local extracted_root
    local keep_file
    local keep_target

    UPDATE_TMP_DIR="/tmp/dnscrypt-proxy-update"
    UPDATE_BACKUP_DIR="/tmp/dnscrypt-proxy-backup"
    archive_path="${UPDATE_TMP_DIR}/update.tar.gz"

    rm -rf "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR"
    mkdir -p "$UPDATE_TMP_DIR" "$UPDATE_BACKUP_DIR"

    log "Creating backup at $UPDATE_BACKUP_DIR"
    cp -rf "${REMOTE_DIR}/"* "$UPDATE_BACKUP_DIR/"

    trap cleanup_trap EXIT

    log "Downloading ${archive_url}"
    if command -v curl >/dev/null 2>&1; then
        curl -sL "$archive_url" -o "$archive_path" || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget --no-check-certificate -q "$archive_url" -O "$archive_path" || return 1
    else
        log "ERROR: Neither curl nor wget is available."
        return 1
    fi

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
    local keep_files="conf/setup-custom.toml conf/dnscrypt-proxy-custom.toml conf/custom.toml"
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

    if version_gt "$latest_tag" "$local_version" || [ "$force" = "1" ]; then
        [ "$force" = "1" ] && log "Force update requested." || log "New release available (${local_version} -> ${latest_tag})."
        perform_update "$latest_tag"
    else
        log "No updates found."
    fi
}

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
