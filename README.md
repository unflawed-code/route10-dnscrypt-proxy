# Route10 DNSCrypt-Proxy

A specialized deployment of DNSCrypt-proxy optimized for the Alta Labs Route10 router environment.

## Custom Features

- **Storage Optimized (UPX)**: Uses high-ratio compression to reduce the binary footprint from ~15MB to ~5MB, preserving space on the limited 25MB `/cfg` partition.
- **Persistent /cfg Integration**: Fully self-contained in `/cfg/dnscrypt-proxy` to ensure the installation survives system reboots and firmware updates.
- **Dynamic Configuration Overrides**: Core configuration files `setup.toml` and `dnscrypt-proxy.toml` support `setup-custom.toml` and `dnscrypt-proxy-custom.toml` to override values.
- **Automated Boot Integration**: Automatically injects a startup hook into `/cfg/post-cfg.sh` to manage the service lifecycle across reboots.
- **Robust DNS Cutover**: `start.sh` handles the complex handoff between `dnsmasq` and DNSCrypt, ensuring a switch only after an upstream connection is verified.
- **Flexible DNS Filtering**: Supports dynamic DNS filtering. Multiple URL sources (Hagezi, etc.) can be configured. These are merged into a single blocklist file.
- **Automated Filter Updates**: A dedicated `update-filters.sh` script installs a `crontab` entry to refresh and reload filters daily (defaults to 4:00 AM).

## Installation & Usage

Configuration files now live under `conf/`.

1. **Deploy**: Copy all files to `/cfg/dnscrypt-proxy/`.
2. **Permissions**: `chmod 700 /cfg/dnscrypt-proxy/*.sh /cfg/dnscrypt-proxy/scripts/*.sh`
3. **Install**: Run `/cfg/dnscrypt-proxy/setup.sh`.
   - This installs the binary and adds a commented boot hook to `/cfg/post-cfg.sh`.
4. **Start**: Run `/cfg/dnscrypt-proxy/proxy.sh start`.

## Router Integration Notes

- **`https-dns-proxy` handoff**: `start.sh` assumes DNSCrypt becomes the active upstream resolver. After DNSCrypt is verified, the script stops the `https-dns-proxy` service.
- **`dnsmasq` upstream cutover**: `start.sh` rewrites the `dnsmasq` upstream configuration so the router uses only `127.0.0.1#5059`.
- **WAN DNS disabled via `noresolv=1`**: the script sets `dhcp.@dnsmasq[0].noresolv='1'`, preventing parallel resolution through ISP/WAN-provided servers.
- **Rollback behavior**: if DNSCrypt cannot be validated, the script automatically restores the previous `dnsmasq` configuration to prevent internet loss.

## Configuration

| Base File | Override File | Purpose |
| :--- | :--- | :--- |
| `conf/setup.toml` | `conf/setup-custom.toml` | Versions, update schedule, blocklist sources, and storage paths. |
| `conf/dnscrypt-proxy.toml` | `conf/dnscrypt-proxy-custom.toml` | Standard dnscrypt-proxy settings. |

## CLI Reference

Both main scripts support a `-f` (force) flag for specific maintenance tasks:

### `proxy.sh start -f`

- **Action**: Force Restart.
- **Behavior**: Kills any existing `dnscrypt-proxy` processes, rebuilds the temporary runtime configuration from scratch (merging all active overrides), and performs a full service validation and `dnsmasq` cutover check.
- **Use Case**: Use this after making changes to any `.toml` file to ensure they are applied immediately.

### `proxy.sh update-filters -f`

- **Action**: Force Filter Refresh.
- **Behavior**: Bypasses the default 12-hour staleness check and immediately downloads fresh blocklists from the configured sources. It then signals `dnscrypt-proxy` (via `SIGHUP`) to reload the new filters.
- **Use Case**: Use this if you want to update your blocklists immediately without waiting for the next scheduled cron job.

## Maintenance

- **Service Status**: `ps w | grep [d]nscrypt-proxy`
- **Logs**: `/var/log/dnscrypt-proxy.log`
