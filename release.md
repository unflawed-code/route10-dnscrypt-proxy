# Release History

## v3.3.0 - (2026-07-27)

This release upgrades upstream dependencies (DNSCrypt-Proxy to `2.1.18` and UPX to `5.2.0`), updates default resolver configuration to Quad9, and improves TOML layer merging robustness under Windows/CRLF line endings.

### What's New & Enhancements

#### 🚀 Upstream Dependency Upgrades
- **DNSCrypt-Proxy**: Upgraded target engine version to `2.1.18` in configuration and scripts.
- **UPX**: Upgraded binary compression tool version to `5.2.0` in setup configuration and scripts.

#### ⚙️ Default Resolver & TOML Merge Improvements
- **Quad9 Default Resolvers**: Set default `server_names` in `dnscrypt-proxy.toml` to `quad9-dnscrypt-ip4-filter-pri` and `quad9-dnscrypt-ip6-filter-pri`.
- **Robust TOML Layer Merging**: Improved TOML section/key merging in setup and start scripts to handle carriage returns (`\r`) and support alphanumeric keys, avoiding duplicate key errors under CRLF line endings.
- **GitHub Actions & Supply Chain**: Enabled Dependabot grouping for GitHub Actions workflows and updated release artifact generation workflows.

---

## v3.1.0 - (2026-06-14)

This release upgrades the core DNSCrypt-Proxy engine to `2.1.16` and introduces critical bug fixes for the auto-updater and boot-time NTP clock synchronization.

### What's New & Enhancements

#### 🚀 DNSCrypt-Proxy v2.1.16 Engine Upgrade
- Upgraded target version to `2.1.16` in configuration and scripts.
- Core improvements in DNSCrypt-Proxy v2.1.16 include:
  - Hot-reloading of configurations without restarting the daemon.
  - Interactive live monitoring web dashboard.
  - Bug fixes for ODoH key refresh and HTTP transport connection reuse.

#### 🕒 NTP Boot-Time Lock Resolution
- Resolved the boot-time NTP/DNS deadlock in `scripts/start.sh`:
  - If the router clock is not sane on boot (e.g. 1970) and `dnsmasq` is configured for DNSCrypt only, the script temporarily disables the DNSCrypt-only block and restores standard WAN DNS upstreams.
  - This allows the NTP client to resolve NTP server domain names and sync the system clock.
  - Once the clock is synchronized and sane, the script starts DNSCrypt-Proxy, validates resolution, and performs the permanent cutover back to DNSCrypt.

#### 🛡️ Robust Auto-Updater & Safe Self-Overwrite
- Refactored `scripts/updater.sh` to mirror the robust self-updating architecture from `route10-suricata-runner`:
  - **Self-Overwriting Safety**: Automatically detects if the updater script itself has changed in the downloaded version, replacing itself on disk and restarting execution using `exec` to prevent shell parsing corruption.
  - **Smart Binary Retention**: Compares core DNSCrypt versions in `setup.toml` between local and remote states. If the core version is unchanged, it skips binary download/compression to conserve bandwidth. If the core version has upgraded, it automatically pulls and UPX-compresses the new binary.
  - **Fallback Version Parsing**: Dynamically updates the `VERSION` string in `setup.sh` on the router to match the tag name during upgrades.
  - **Semver Tag Checking**: Implemented robust version priority checks supporting `-rc` and `beta` pre-release tags.

#### 🛠️ Active Binary Version Verification
- Updated `setup.sh` to parse and verify the version of any local `dnscrypt-proxy` executable using `--version` instead of blindly skipping downloads in non-interactive mode.

---

## v2.0.0 - Stable Release (2026-04-03)

This release introduces a structural refactor for long-term maintainability, a new orchestrator wrapper, stronger boot/cron migration behavior, and safer update/version lifecycle management.

### Highlights

- **New Orchestrator (`proxy.sh`)**:
  - Added a single command wrapper for service operations:
    - `proxy.sh start`
    - `proxy.sh updater [check|force]`
    - `proxy.sh update-filters [-f]`
    - `proxy.sh uninstall [--force]`
  - Cron and boot hooks now target `proxy.sh` instead of direct script paths.

- **Script Layout Migration (`scripts/`)**:
  - Moved operational scripts into `scripts/`:
    - `scripts/start.sh`
    - `scripts/updater.sh`
    - `scripts/update-filters.sh`
    - `scripts/uninstall.sh`
  - Updated all internal callers and path resolution to work from the new location.

- **Configuration Layout Migration (`conf/`)**:
  - Moved TOML/TXT/logrotate assets into `conf/`:
    - `conf/setup.toml`
    - `conf/setup-custom.toml`
    - `conf/dnscrypt-proxy.toml`
    - `conf/dnscrypt-proxy-custom.toml`
    - `conf/custom.toml`
    - `conf/whitelist.txt`
    - `conf/dnscrypt-proxy.logrotate`
  - Updated setup, runtime merge logic, updater, and uninstall scripts to read from `conf/`.

- **Boot/Cron Canonicalization in Setup**:
  - `setup.sh` now actively removes legacy boot and cron entries and rewrites them to canonical `proxy.sh` entries every run.
  - This prevents stale historical paths from surviving upgrades.

- **Updater Hardening**:
  - Added robust version parity logic between local state and UCI.
  - Added installed-version tracking via `.installed-version` to prevent repeat updates when already current.
  - Added UCI registration updates during setup/update (`dnscrypt-proxy.system.version`, `dnscrypt-proxy.system.dnscrypt`).

- **Filter Update Behavior Improvements**:
  - `update-filters.sh` now treats missing `blocked_names` sources as a valid disabled mode instead of an error.
  - When sources are disabled, runtime config is rebuilt so stale `[blocked_names]` state is removed cleanly.

### Compatibility Notes

- Existing installs are auto-migrated by running `setup.sh` once.
- Existing users should rerun `setup.sh` before rebooting so old boot hooks are migrated safely:
  - `/cfg/dnscrypt-proxy/setup.sh --non-interactive --keep-binary`
- The canonical boot command is now:
  - `/cfg/dnscrypt-proxy/proxy.sh start >/var/log/dnscrypt-proxy-boot.log 2>&1 &`
- The canonical cron commands are now:
  - `35 4 * * * /bin/ash /cfg/dnscrypt-proxy/proxy.sh updater check >/dev/null 2>&1`
  - `0 4 * * * /bin/ash /cfg/dnscrypt-proxy/proxy.sh update-filters -f >/dev/null 2>&1`
