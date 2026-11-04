FROM debian:trixie-slim

# Samba from trixie-backports: a release that is still maintained upstream
# https://wiki.samba.org/index.php/Samba_Release_Planning
RUN echo 'deb http://deb.debian.org/debian trixie-backports main' > /etc/apt/sources.list.d/backports.list \
    && apt-get update \
    && apt-get install --no-install-recommends -y -t trixie-backports \
        samba-ad-dc samba-ad-provision winbind libnss-winbind krb5-user tdb-tools smbclient python3-setproctitle \
        bind9 bind9-utils bind9-dnsutils chrony rsync acl attr gettext-base tini \
    && rm -rf /var/lib/apt/lists/* \
    # Samba writes this file at provision/join, with the DLZ module matching the installed BIND
    && echo 'include "/var/lib/samba/bind-dns/named.conf";' >> /etc/bind/named.conf.local

COPY templates/ /templates/
COPY --chmod=755 entrypoint.sh sync-sysvol.sh backup.sh /usr/local/bin/

VOLUME /etc/samba /var/lib/samba

ENTRYPOINT ["tini", "--", "entrypoint.sh"]

# Fails if samba is down or any replication link is failing
HEALTHCHECK --interval=5m --timeout=30s --start-period=15m \
    CMD samba-tool drs showrepl --summary
