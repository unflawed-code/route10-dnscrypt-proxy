# Route10 DNSCrypt-Proxy

A specialized deployment of DNSCrypt-proxy optimized for the Alta Labs Route10 router environment.

## Custom Features

- **Storage Optimized (UPX)**: Uses high-ratio compression to reduce the binary footprint from ~15MB to ~5MB, preserving space on the limited 25MB `/cfg` partition.
- **Persistent /cfg Integration**: Fully self-contained in `/cfg/dnscrypt-proxy` to ensure the installation survives system reboots and firmware updates.
- **Dynamic Runtime Merging**: The `start.sh` script automatically merges user-specific overrides from `custom.toml` into the base configuration at runtime. This allows for seamless configuration edits without reinstalling.
- **Automated Boot Integration**: Automatically injects a startup hook into `/cfg/post-cfg.sh` to manage the service lifecycle across reboots.
- **Dnsmasq Lifecycle Management**: `start.sh` handles the complex cutover between `https-dns-proxy` and `dnsmasq`, ensuring a robust transition to DNSCrypt only after an upstream connection is verified.
- **Legacy Compatibility Layer**: Specifically configured to work with the `dnscrypt-proxy 2.1.5` build, including manual handling of v2 resolver sources and legacy minisign keys.

## Installation & Usage

1. **Deploy**: Copy all files to `/cfg/dnscrypt-proxy/`.
2. **Install**: Run `/cfg/dnscrypt-proxy/setup.sh`.
   - This installs the binary, makes the scripts executable, and adds a commented boot hook entry to `/cfg/post-cfg.sh`.
   - The generated line is commented out by default. You must uncomment it if you want DNSCrypt to start automatically after boot.
   - The suggested boot entry is backgrounded and logs to `/var/log/dnscrypt-proxy-boot.log`:
     - `/cfg/dnscrypt-proxy/start.sh >/var/log/dnscrypt-proxy-boot.log 2>&1 &`
3. **Start**: Run `/cfg/dnscrypt-proxy/start.sh`.

## Router Integration Notes

- **`https-dns-proxy` handoff**: `start.sh` assumes DNSCrypt becomes the active upstream resolver. After DNSCrypt is verified, the script stops the `https-dns-proxy` service. If you currently enable `https-dns-proxy` from the Route10 UI, you should disable that feature to avoid conflicting DNS managers.
- **`dnsmasq` upstream cutover**: `start.sh` rewrites the main `dnsmasq` upstream configuration so the router uses only `127.0.0.1#5059`.
- **WAN DNS disabled via `noresolv=1`**: the script sets `dhcp.@dnsmasq[0].noresolv='1'`, which tells `dnsmasq` to stop reading WAN-provided resolvers from `/tmp/resolv.conf.d/resolv.conf.auto`.
- **Why this matters**: leaving WAN DNS enabled would allow parallel or fallback resolution outside DNSCrypt, which can reintroduce DNS leaks even if DNSCrypt itself is running correctly.
- **Rollback behavior**: if DNSCrypt cannot be validated, the script restores the previous `dnsmasq` upstream state instead of leaving the router with a broken DNS path.

## Configuration

- **Base Config**: `dnscrypt-proxy.toml` (Static defaults).
- **User Overrides**: `custom.toml` (Merged dynamically at start).

## Maintenance

- **Service Status**: `ps w | grep [d]nscrypt-proxy`
- **Logs**: `/var/log/dnscrypt-proxy.log`
- **Latency Monitoring**: Grep "rtt" in the log file to see real-time performance metrics for the active relays.
