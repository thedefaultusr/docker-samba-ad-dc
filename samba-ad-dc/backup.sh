#!/bin/sh
# Online backup of the whole domain into /var/lib/samba/backups, using this DC's machine account.
# Restore it with MODE=restore. https://wiki.samba.org/index.php/Back_up_and_Restoring_a_Samba_AD_DC

set -eu

mkdir -p /var/lib/samba/backups
chmod 700 /var/lib/samba/backups # backups contain every password hash in the domain
exec samba-tool domain backup online --targetdir=/var/lib/samba/backups --server=127.0.0.1 -P "$@"
