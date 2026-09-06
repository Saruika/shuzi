#!/usr/bin/env bash
# Apply only the fixed review virtual host, serialized with site maintenance.
# Certificates and DNS are provisioned separately; no production vhost edits.
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'review-edge: root required' >&2; exit 1; }
[[ $# -eq 2 && ( $1 == challenge || $1 == https ) ]] || {
    echo 'usage: deploy-edge.sh challenge|https /absolute/review/assets' >&2; exit 1;
}
mode=$1
assets=$(realpath -e -- "$2")
target=/etc/nginx/sites-available/shuzijun-review.conf
enabled=/etc/nginx/sites-enabled/shuzijun-review.conf
challenge_root=/var/lib/shuzijun-review-acme
source_file=$assets/edge-$mode.conf
[[ -f $source_file && ! -L $source_file ]] || exit 1
[[ $(stat -c '%U:%G:%a' /var/lib/shuzijun-sync/site-operation.lock) == root:root:600 ]]
[[ ! -L /var/lib/shuzijun-sync/site-operation.lock ]]
exec 9<>/var/lib/shuzijun-sync/site-operation.lock
flock -w 30 -x 9

if [[ $mode == challenge ]]; then
    [[ ! -e $target && ! -L $target && ! -e $enabled && ! -L $enabled ]] || {
        echo 'review-edge: existing target; inspect rather than overwrite' >&2; exit 1;
    }
else
    [[ -f $target && ! -L $target && -L $enabled ]]
    [[ $(readlink -- "$enabled") == "$target" ]]
    [[ $(stat -c '%U:%G:%a' "$target") == root:root:644 ]]
    cmp --silent "$target" "$assets/edge-challenge.conf" || {
        echo 'review-edge: expected exact challenge predecessor' >&2; exit 1;
    }
    [[ $(openssl x509 -in /etc/letsencrypt/live/review.shuzijun.com.cn/fullchain.pem \
        -noout -checkhost review.shuzijun.com.cn) == 'Hostname review.shuzijun.com.cn does match certificate' ]]
    openssl x509 -in /etc/letsencrypt/live/review.shuzijun.com.cn/fullchain.pem \
        -noout -checkend 604800 >/dev/null
fi

backup=$(mktemp -d /var/backups/shuzijun-review-edge.XXXXXXXX)
chmod 0700 "$backup"
if [[ -e $target ]]; then cp --preserve=all -- "$target" "$backup/previous.conf"; fi
install -d -o root -g root -m 0755 "$challenge_root" "$challenge_root/.well-known" "$challenge_root/.well-known/acme-challenge"

committed=0
restore() {
    local result=$?
    trap - EXIT
    if [[ $committed -eq 0 ]]; then
        if [[ $mode == challenge ]]; then
            # Only artifacts created in this transaction; no recursive deletion.
            [[ ! -L $enabled ]] || unlink -- "$enabled"
            [[ ! -f $target ]] || mv -- "$target" "$backup/unaccepted.conf"
        else
            install -o root -g root -m 0644 "$backup/previous.conf" "$target"
        fi
        /usr/sbin/nginx -t && /usr/bin/systemctl reload nginx || true
        echo 'review-edge: rolled back virtual host; evidence retained in root-only backup' >&2
    fi
    exit "$result"
}
trap restore EXIT
install -o root -g root -m 0644 "$source_file" "$target"
if [[ $mode == challenge ]]; then ln -s -- "$target" "$enabled"; fi
/usr/sbin/nginx -t
/usr/bin/systemctl reload nginx
committed=1
echo "review-edge: $mode configured; endpoint acceptance still required"
