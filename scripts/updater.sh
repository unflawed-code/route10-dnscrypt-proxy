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
            gsub(/"/, "", $3)
            print $3
            exit
        }
    ' "${REMOTE_DIR}/conf/setup.toml" 2>/dev/null | tr -d '\r'
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

get_latest_version_tag() {
    local tag=""

    if command -v wget >/dev/null 2>&1; then
        tag=$(wget --no-check-certificate -qO- "$LATEST_RELEASE_URL" | sed -n 's/.*"tag_name": "\(.*\)".*/\1/p' | head -n 1)
    elif command -v curl >/dev/null 2>&1; then
        tag=$(curl -s "$LATEST_RELEASE_URL" | sed -n 's/.*"tag_name": "\(.*\)".*/\1/p' | head -n 1)
    fi

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

version_gt() {
    # Strip everything after '-' to handle rc versions correctly in integer comparisons
    local v1
    local v2
    local i
    local p1
    local p2
    v1=$(echo "$1" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')
    v2=$(echo "$2" | sed 's/^v//' | cut -d- -f1 | tr -d '\r')

    # If numeric parts match exactly, check if one is an RC and the other is stable
    if [ "$v1" = "$v2" ]; then
        # If GitHub ($1) is stable and local ($2) is rc, GitHub is greater
        if echo "$1" | grep -qv "-" && echo "$2" | grep -q "-"; then
            return 0
        fi
        # If both are rc tags, compare rc numbers
        if echo "$1" | grep -q "-" && echo "$2" | grep -q "-"; then
            local rc1
            local rc2
            rc1=$(echo "$1" | sed 's/.*-rc//' | tr -dc '0-9')
            rc2=$(echo "$2" | sed 's/.*-rc//' | tr -dc '0-9')
            if [ "${rc1:-0}" -gt "${rc2:-0}" ]; then return 0; fi
        fi
        return 1
    fi

    i=1
    while [ $i -le 3 ]; do
        p1=$(echo "$v1" | cut -d. -f$i)
        p2=$(echo "$v2" | cut -d. -f$i)
        [ -n "$p1" ] || p1=0
        [ -n "$p2" ] || p2=0
        if [ "$p1" -gt "$p2" ]; then return 0; fi
        if [ "$p1" -lt "$p2" ]; then return 1; fi
        i=$((i + 1))
    done
    return 1
}

rollback_update() {
    local backup_dir="$1"
    log "CRITICAL: Update failed. Starting rollback."
    [ -d "$backup_dir" ] || { log "ERROR: Rollback failed - backup missing."; return 1; }

    rm -rf "${REMOTE_DIR:?}/"*
    cp -rf "${backup_dir}/"* "$REMOTE_DIR/"
    ensure_script_permissions "$REMOTE_DIR"
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

    # Preserve local custom overrides and local binary from the current install.
    for keep_file in conf/setup-custom.toml conf/dnscrypt-proxy-custom.toml conf/custom.toml dnscrypt-proxy; do
        if [ -f "${REMOTE_DIR}/${keep_file}" ]; then
            keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
            mkdir -p "$(dirname "$keep_target")"
            cp -f "${REMOTE_DIR}/${keep_file}" "$keep_target"
        fi
    done

    log "Applying update files to ${REMOTE_DIR}"
    cp -rf "${extracted_root}/"* "$REMOTE_DIR/"

    for keep_file in conf/setup-custom.toml conf/dnscrypt-proxy-custom.toml conf/custom.toml dnscrypt-proxy; do
        keep_target="${UPDATE_TMP_DIR}/${keep_file}.keep"
        if [ -f "$keep_target" ]; then
            mkdir -p "$(dirname "${REMOTE_DIR}/${keep_file}")"
            cp -f "$keep_target" "${REMOTE_DIR}/${keep_file}"
        fi
    done

    ensure_script_permissions "$REMOTE_DIR"

    log "Running setup.sh in non-interactive mode"
    # Pipe an explicit "no" in case the fetched release contains an older interactive setup.sh.
    printf 'n\n' | /bin/ash "${REMOTE_DIR}/setup.sh" --non-interactive --keep-binary || return 1

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
