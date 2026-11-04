#!/bin/bash
# Renders the configs, provisions, joins or restores the domain on first start, then runs
# chronyd, named, rsyncd (first DC only) and samba, and stops them all when one exits.
#
# Follows https://wiki.samba.org/index.php/Setting_up_Samba_as_an_Active_Directory_Domain_Controller,
# https://wiki.samba.org/index.php/Joining_a_Samba_DC_to_an_Existing_Active_Directory
# and https://wiki.samba.org/index.php/Back_up_and_Restoring_a_Samba_AD_DC

set -euo pipefail

log() { echo "entrypoint: $*"; }
die() { echo "entrypoint: $*" >&2; exit 1; }

# --- Settings ---------------------------------------------------------------

: "${MODE:?must be provision, join or restore}" "${REALM:?}" "${DOMAIN:?}" "${HOST_IP:?}"
: "${DNS_FORWARDER:?}" "${DNS_CLIENT_SUBNET:?}" "${NTP_CLIENT_SUBNET:?}" "${RSYNC_SYSVOL_PASSWORD:?}"
case "$MODE" in
    provision | restore) : "${RSYNC_SYSVOL_ALLOW_HOSTS:?}" ;; # the first DC
    join) : "${PDC_IP:?}" ;;
    *) die "MODE must be provision, join or restore, got '$MODE'" ;;
esac

SITE="${SITE:-Default-First-Site-Name}"
DOMAIN_USER="${DOMAIN_USER:-Administrator}"
export RSYNC_SYSVOL_USER="${RSYNC_SYSVOL_USER:-sysvol-replication}"
export HOST_NAME DNS_DOMAIN
HOST_NAME=$(hostname)
HOST_NAME=${HOST_NAME%%.*}
DNS_DOMAIN=${REALM,,}

# --- Configs (rendered on every start) ---------------------------------------

render() { envsubst < "/templates/$1" > "$2"; }

render hosts /etc/hosts
render krb5.conf /etc/krb5.conf
render chrony.conf /etc/chrony/chrony.conf
render named.conf.options /etc/bind/named.conf.options

if [ "$MODE" != join ]; then
    render rsyncd.conf /etc/rsyncd.conf
    printf '%s:%s\n' "$RSYNC_SYSVOL_USER" "$RSYNC_SYSVOL_PASSWORD" > /etc/samba/rsyncd.secret
else
    printf '%s\n' "$RSYNC_SYSVOL_PASSWORD" > /etc/samba/rsyncd.secret
fi
chmod 600 /etc/samba/rsyncd.secret # rsync refuses secret files readable by others

# --- Provision, join or restore (first start only) --------------------------

incomplete=/etc/samba/.setup-incomplete # not in /var/lib/samba, which a restore needs empty
[ -e "$incomplete" ] && die "A previous provision, join or restore did not finish. Empty /var/lib/samba and /etc/samba and start again" \
    "(if the join itself succeeded, first remove this DC from the domain on another DC with" \
    "'samba-tool domain demote --remove-other-dead-server=$HOST_NAME')."

if [ ! -f /var/lib/samba/private/sam.ldb ]; then
    if [ "$MODE" = restore ]; then
        [ -f /backup.tar.bz2 ] || die "Mount the backup file at /backup.tar.bz2"
    else
        : "${DOMAIN_PASSWORD:?is required for the first start}"
    fi
    if [ "$MODE" = join ]; then
        # Fetched before the join, so a wrong rsync password or address fails early
        log "Fetching idmap.ldb from $PDC_IP"
        rsync --password-file=/etc/samba/rsyncd.secret \
            "rsync://$RSYNC_SYSVOL_USER@$PDC_IP/idmap/idmap.ldb" /tmp/idmap.ldb
    fi

    touch "$incomplete"
    rm -f /etc/samba/smb.conf

    case "$MODE" in
    provision)
        log "Provisioning domain $REALM"
        samba-tool domain provision --server-role=dc --realm="$REALM" --domain="$DOMAIN" --site="$SITE" \
            --use-rfc2307 --dns-backend=BIND9_DLZ \
            --option="interfaces=127.0.0.1 $HOST_IP" --option="bind interfaces only=yes" \
            --adminpass="$DOMAIN_PASSWORD"
        ;;
    join)
        log "Joining domain $REALM via $PDC_IP"
        samba-tool domain join "$REALM" DC --server="$PDC_IP" --site="$SITE" \
            --dns-backend=BIND9_DLZ --option='idmap_ldb:use rfc2307 = yes' \
            --option="interfaces=127.0.0.1 $HOST_IP" --option="bind interfaces only=yes" \
            -U "$DOMAIN_USER" --password="$DOMAIN_PASSWORD"

        # Same IDs for built-in users and groups on every DC
        mv /tmp/idmap.ldb /var/lib/samba/private/idmap.ldb
        chmod 600 /var/lib/samba/private/idmap.ldb
        net cache flush

        sync-sysvol.sh
        samba-tool ntacl sysvolreset
        ;;
    restore)
        # Creates a new DC (the name must be new to the domain) that takes over all FSMO roles
        log "Restoring domain $REALM from /backup.tar.bz2 as $HOST_NAME"
        samba-tool domain backup restore --backup-file=/backup.tar.bz2 --targetdir=/var/lib/samba \
            --newservername="$HOST_NAME" --host-ip="$HOST_IP" --site="$SITE"

        # Move the config and SysVol to where a provisioned DC has them, and listen on this host's IP
        mv /var/lib/samba/state/sysvol /var/lib/samba/sysvol
        sed -e 's#/var/lib/samba/state/sysvol#/var/lib/samba/sysvol#' \
            -e "s#^\([[:space:]]*interfaces = \).*#\1127.0.0.1 $HOST_IP#" \
            /var/lib/samba/etc/smb.conf > /etc/samba/smb.conf
        rm -r /var/lib/samba/etc

        # The backup has no BIND files
        samba_upgradedns --dns-backend=BIND9_DLZ
        samba-tool ntacl sysvolreset

        # The restore removed the old DCs' NS records and BIND won't load a zone without any,
        # so register this DC's DNS records through a temporary samba before BIND first starts.
        # Its own DNS update service is off, it would only fail without DNS.
        services=$(sed -n 's/^[[:space:]]*server services = //p' /etc/samba/smb.conf | sed 's/, *dnsupdate//')
        samba -i --option="server services=$services" >/dev/null &
        samba_pid=$!
        for _ in $(seq 60); do
            samba-tool dns serverinfo 127.0.0.1 -P >/dev/null 2>&1 && break
            sleep 2
        done
        samba_dnsupdate --use-samba-tool --all-names # --all-names: don't look up the records first, DNS is down
        kill "$samba_pid"
        wait "$samba_pid" || true
        ;;
    esac

    # chrony needs read access to Samba's NTP signing socket
    mkdir -p /var/lib/samba/ntp_signd
    chown root:_chrony /var/lib/samba/ntp_signd
    chmod 750 /var/lib/samba/ntp_signd

    rm "$incomplete"
else
    log "Domain controller already provisioned"
fi

if [ -n "${DOMAIN_PASSWORD:-}" ]; then
    echo "entrypoint: WARNING: DOMAIN_PASSWORD is only needed for the first start and is visible in" \
        "'docker inspect'. Remove it from your compose file and recreate the container." >&2
fi
# Keep passwords out of the daemons' environment (rsync reads /etc/samba/rsyncd.secret)
unset DOMAIN_PASSWORD RSYNC_SYSVOL_PASSWORD

# --- Run ---------------------------------------------------------------------

mkdir -p /run/named
chown bind:bind /run/named
rm -f /run/chrony/chronyd.pid # left over after a container restart
if [ "$MODE" != join ]; then
    mkdir -p /var/lib/samba/idmap-export # served by rsync to joining DCs
    chmod 700 /var/lib/samba/idmap-export
fi

pids=()
start() { "$@" & pids+=("$!"); }

start chronyd -d
start named -g -u bind -4
if [ "$MODE" != join ]; then
    start rsync --daemon --no-detach --log-file=/dev/stdout
else
    start bash -c 'while sleep 600; do sync-sysvol.sh || echo "sync-sysvol.sh failed" >&2; done'
fi
start samba -i

stop() {
    trap - TERM INT
    kill -TERM "${pids[@]}" 2>/dev/null || true
    wait
}
trap 'log "Stopping"; stop; exit 0' TERM INT

status=0
wait -n || status=$?
log "A service exited (status $status), stopping the others"
stop
exit 1
