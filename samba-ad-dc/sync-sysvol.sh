#!/bin/sh
# Pulls SysVol from the first DC (PDC emulator). Extra arguments go to rsync, e.g. --dry-run.
# https://wiki.samba.org/index.php/Rsync_based_SysVol_replication_workaround

set -eu

exec rsync -XAavz --delete-after --password-file=/etc/samba/rsyncd.secret "$@" \
    "rsync://${RSYNC_SYSVOL_USER:-sysvol-replication}@${PDC_IP}/SysVol/" /var/lib/samba/sysvol/
