#!/usr/bin/env bash
# Entrypoint for the Linux box.
#
# Creates the Samba user from a file-based secret (never an environment
# variable, following the pattern established in Tasks 02 and 03), starts smbd,
# and then hands over to the container command.

set -euo pipefail

SECRET_FILE="${SMB_PASSWORD_FILE:-/run/secrets/smb_password}"
SMB_USER="${SMB_USER:-smbuser}"

log() { printf '%s [entrypoint] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

if [ ! -r "$SECRET_FILE" ]; then
    echo "FATAL: SMB password secret not readable at $SECRET_FILE" >&2
    exit 1
fi
PASSWORD="$(tr -d '\r\n' < "$SECRET_FILE")"

# A Samba account needs a matching POSIX account to map to.
if ! id "$SMB_USER" > /dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SMB_USER"
    log "created POSIX user $SMB_USER"
fi

mkdir -p /srv/share
chown -R "$SMB_USER":"$SMB_USER" /srv/share
chmod 0775 /srv/share

# smbpasswd reads the password twice from stdin. This is the one place the
# value is handled, and it is never echoed or placed on a command line where
# `ps` would expose it.
printf '%s\n%s\n' "$PASSWORD" "$PASSWORD" | smbpasswd -s -a "$SMB_USER" > /dev/null
smbpasswd -e "$SMB_USER" > /dev/null
log "samba user $SMB_USER configured (password not logged)"
unset PASSWORD

# Seed a file so a Windows client mapping the share sees something immediately.
if [ ! -f /srv/share/README-from-linux.txt ]; then
    {
        echo "This file was created on the LINUX side and is served over SMB3."
        echo "Host      : $(hostname)"
        echo "Created   : $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Share     : //\$(hostname)/task01 -> /srv/share"
    } > /srv/share/README-from-linux.txt
    chown "$SMB_USER":"$SMB_USER" /srv/share/README-from-linux.txt
fi

testparm -s > /dev/null 2>&1 && log "smb.conf validates"

log "starting smbd"
smbd --foreground --no-process-group --debuglevel=1 &
SMBD_PID=$!
sleep 2

if kill -0 "$SMBD_PID" 2>/dev/null; then
    log "smbd running (pid $SMBD_PID), listening on 445"
else
    echo "FATAL: smbd failed to start" >&2
    exit 1
fi

# node_exporter, on the machine it monitors, so it shares this mount namespace
# and can see the CIFS and XFS mounts made here.
# The textfile collector carries the SMB-specific series from /proc/fs/cifs.
# node_exporter's filesystem collector sees a CIFS mount as size/free/readonly,
# which cannot show a session that is reconnecting on every operation.
mkdir -p /var/lib/node_exporter/textfile
INTERVAL=5 /usr/local/bin/cifs-metrics.sh /var/lib/node_exporter/textfile \
    >> /var/log/task01/cifs-metrics.log 2>&1 &
log "cifs metrics exporter running (pid $!)"

log "starting node_exporter on :9100"
# The diskstats device-exclude DEFAULT is
#   ^(z?ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\d+n\d+p)\d+$
# which drops loop devices entirely. The XFS filesystem under test IS on a
# loop device, so with the default every disk metric for it is missing while
# the exporter itself looks perfectly healthy - no error, just absent series.
/usr/local/bin/node_exporter \
    --collector.filesystem.mount-points-exclude='^/(dev|proc|sys|run/credentials/.+)($|/)' \
    --collector.diskstats \
    --collector.diskstats.device-exclude='^(z?ram|fd)[0-9]+$' \
    --collector.textfile \
    --collector.textfile.directory=/var/lib/node_exporter/textfile \
    --web.listen-address=:9100 \
    > /var/log/task01/node_exporter.log 2>&1 &
NE_PID=$!
sleep 2
if kill -0 "$NE_PID" 2>/dev/null; then
    log "node_exporter running (pid $NE_PID)"
else
    echo "WARNING: node_exporter failed to start" >&2
    tail -5 /var/log/task01/node_exporter.log >&2 || true
fi

log "protocol floor: $(testparm -s --parameter-name='server min protocol' 2>/dev/null | tail -1)"
log "encryption    : $(testparm -s --parameter-name='smb encrypt' 2>/dev/null | tail -1)"

exec "$@"
