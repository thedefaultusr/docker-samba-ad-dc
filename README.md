# docker-samba-ad-dc

An extremely opinionated Samba Active Directory Domain Controller Docker image, following the official
[Samba wiki](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller).

One container runs:

- **Samba AD DC** from Debian trixie-backports
- **BIND 9** with the `BIND9_DLZ` backend, forwarding everything else to your upstream DNS
- **chrony** serving signed NTP to domain members (it also sets the **host** clock)
- **rsync**, for one-way SysVol replication from the first DC to the others
  ([wiki workaround](https://wiki.samba.org/index.php/Rsync_based_SysVol_replication_workaround))

If any of these processes exits, the container stops and Docker restarts it.

## Requirements

- A Linux host with a static IP. The container uses host networking.
- Nothing else on the host listening on the DC ports (53, 88, 123, 135, 139, 389, 445, 464, 636, 873, 3268, 3269, ...).
  On Debian/Ubuntu, `systemd-resolved` often holds port 53.
- No time service on the host (`systemd-timesyncd`, `chrony`, `ntpd`), because chrony in the container sets the host clock.
- A hostname of at most 15 characters, and a realm you will never need to rename. Avoid `.local`.
- A local filesystem with xattr and ACL support (ext4, XFS, Btrfs) for `./data`. Network shares such as NFS or SMB won't work,
  and neither do Docker Desktop bind mounts on macOS.

## First DC

1. Adjust `hostname`, `dns_search` and the environment in [docker-compose.yml](docker-compose.yml).
   `DOMAIN_PASSWORD` becomes the Administrator password and must meet the AD complexity rules.
2. Start it:

   ```sh
   docker compose up -d && docker compose logs -f
   ```

3. **Once the domain is provisioned, delete the `DOMAIN_PASSWORD` line** and run `docker compose up -d` again.
   It is only used on the first start, and while it is set anyone with access to Docker can read it with
   `docker inspect`. The container logs a warning on every start until you remove it.

All state lives next to the compose file: `./data` (`/var/lib/samba`) and `./samba` (`/etc/samba`).
Later starts reuse it.

## Additional DCs

1. If the new DC should be in its own site, create the site on the first DC first:

   ```sh
   docker compose exec samba-ad-dc samba-tool sites create TEST-SITE -U Administrator
   ```

2. Make sure the first DC's `RSYNC_SYSVOL_ALLOW_HOSTS` includes the new DC's IP.

3. On the new host, adjust [docker-compose.join.yml](docker-compose.join.yml), using the same
   `RSYNC_SYSVOL_PASSWORD` as on the first DC, save it as `docker-compose.yml` and start it.

4. **Once the DC has joined, delete the `DOMAIN_PASSWORD` line** and run `docker compose up -d` again.

The first start copies the first DC's `idmap.ldb` (so built-in users and groups get the same IDs on every DC),
joins the domain, pulls SysVol from `PDC_IP` and resets the SysVol ACLs.
After that, SysVol is pulled every 10 minutes. Replication between sites follows the AD site link schedule
(3 hours by default), so changes can take that long to arrive.

If a provision, join or restore fails halfway, the container refuses to start until you empty `./data` and `./samba`.

## Configuration

| Variable | Used by | Description |
|---|---|---|
| `MODE` | both | `provision` (first DC), `join` (additional DC) or `restore` (see [Backup and restore](#backup-and-restore)) |
| `HOST_IP` | both | The host's LAN IP. Samba, BIND and chrony bind to it |
| `REALM` | both | AD DNS domain in upper case, e.g. `AD.EXAMPLE.COM` |
| `DOMAIN` | both | NetBIOS domain name, at most 15 characters, e.g. `EXAMPLE` |
| `SITE` | both | AD site. Defaults to `Default-First-Site-Name` |
| `DNS_FORWARDER` | both | Upstream DNS server for non-AD names |
| `DNS_CLIENT_SUBNET` | both | Clients allowed to query and recurse via BIND |
| `NTP_CLIENT_SUBNET` | both | Clients allowed to use chrony |
| `RSYNC_SYSVOL_ALLOW_HOSTS` | provision | DCs allowed to pull SysVol and `idmap.ldb` |
| `PDC_IP` | join | IP of the first DC (PDC emulator): join target and source of SysVol and `idmap.ldb` |
| `RSYNC_SYSVOL_PASSWORD` | both | Password for copying SysVol and `idmap.ldb` from the first DC. Must be the same on every DC |
| `RSYNC_SYSVOL_USER` | both | User name for the same. Defaults to `sysvol-replication` |
| `DOMAIN_PASSWORD` | both, **first start only** | Administrator password (provision) or `DOMAIN_USER`'s password (join). **Delete it after the first start** |
| `DOMAIN_USER` | join, first start only | A Domain Admins user for the join. Defaults to `Administrator` |

In compose files, write a `$` in a value as `$$`.

The image needs the `SYS_ADMIN` capability to store NT ACLs on SysVol and `SYS_TIME` for chrony.
Both compose files already include them.

## Checking the DC

These are the tests from the wiki:

```sh
docker compose exec samba-ad-dc smbclient -L localhost -N                 # lists netlogon and sysvol
docker compose exec samba-ad-dc smbclient //localhost/netlogon -UAdministrator -c ls
docker compose exec samba-ad-dc host -t SRV _ldap._tcp.ad.example.com.
docker compose exec samba-ad-dc host -t SRV _kerberos._udp.ad.example.com.
docker compose exec samba-ad-dc host -t A dc1.ad.example.com.
docker compose exec -it samba-ad-dc sh -c 'kinit administrator && klist'
docker compose exec samba-ad-dc samba-tool drs showrepl
```

The container's health check runs `samba-tool drs showrepl --summary`. It fails when Samba is down or when a
replication link is failing.

## Notes

- **Edit GPOs on the first DC only.** SysVol replication is one-way, so changes made on other DCs are overwritten.
- **rsync traffic is not encrypted.** The rsync daemon accepts only `RSYNC_SYSVOL_ALLOW_HOSTS`, but use a trusted network.
- **Reverse DNS zones are not created.** Create them with `samba-tool dns zonecreate`, as described in the
  [wiki](https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller).

## Backup and restore

Back up the domain regularly with `backup.sh`. It makes an online backup of the whole domain with
[`samba-tool domain backup`](https://wiki.samba.org/index.php/Back_up_and_Restoring_a_Samba_AD_DC), using the
DC's machine account, so it needs no password and the DC keeps running:

```sh
docker compose exec -T samba-ad-dc backup.sh
```

The file lands in `./data/backups/`, which only root can read: it contains every password hash in the domain.
Copy it off the host, e.g. from a daily cron job, and delete old ones.

A restore is for losing the whole domain. If only one of several DCs fails, don't restore it: remove it on a
remaining DC with `samba-tool domain demote --remove-other-dead-server=<name>` and join a fresh one.

To restore:

1. Stop all remaining DCs. Their data is replaced in step 4.
2. On a host with empty `./data` and `./samba`, use [docker-compose.yml](docker-compose.yml) with
   - `MODE: restore` instead of `provision`, and no `DOMAIN_PASSWORD` (passwords are those from the backup),
   - a `hostname` the domain has never had. The restore creates a new DC that takes over all roles.
   - the backup mounted at `/backup.tar.bz2`:

     ```yaml
         volumes:
           - ./data:/var/lib/samba
           - ./samba:/etc/samba
           - ./samba-backup-ad.example.com-2026-11-04T16-37-13.701850.tar.bz2:/backup.tar.bz2:ro
     ```

3. Start it. It becomes the first DC, so set the other DCs' `PDC_IP` to its IP.
   Once it runs, you can remove the backup mount.
4. Rejoin the other DCs with empty `./data` and `./samba`. They can reuse their old names.
