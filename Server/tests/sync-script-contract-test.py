import ast
import hashlib
import os
import subprocess
import tempfile
from pathlib import Path


RECEIVER = Path("Server/operations/apply-shuzijun-sync")
SENDER = Path("Server/operations/sync-to-backup")
VERIFIER = Path("Server/operations/verify-webroot-security")
SENSITIVE_DENY = Path("Server/nginx/shuzijun-sensitive-files-deny.conf")
LEGACY_IMAGES = Path("Server/nginx/shuzijun-legacy-images-alias.conf")
NGINX_ROUTING_SMOKE = Path("Server/tests/nginx-sensitive-routing-smoke.sh")
NGINX_README = Path("Server/nginx/README.md")
NGINX_CONTRACT = Path("Server/operations/verify-nginx-server-block-contract.py")
AUTHORITY_VERIFIER = Path("Server/operations/verify-account-authority-role.py")
SSH_GATE = Path("Server/operations/shuzijun-sync-ssh-gate")
SUDOERS = Path("Server/operations/shuzijun-sync-transport.sudoers")
SSHD_MATCH = Path("Server/operations/shuzijun-sync-transport.sshd")


def line_number(lines: list[str], fragment: str, start: int = 0) -> int:
    for index in range(start, len(lines)):
        line = lines[index]
        if fragment in line:
            return index
    raise AssertionError(f"missing required operation: {fragment}")


def verify_filters(text: str) -> None:
    for required in (
        "--exclude='*.[pP][hH][pP]*'",
        "--exclude='*.php?*'",
        "--exclude='*.php.*'",
        "--exclude='*.bak*'",
        "--exclude='*.before-*'",
        "--exclude='.env*'",
        "--exclude='*.sql*'",
        "--exclude='*.key'",
        "--exclude='*.p8'",
        "--exclude='*.P8'",
        "--exclude='*.zip'",
        "--exclude='/mu-plugins/shuzijun-app-content.php'",
        "--exclude='/mu-plugins/composer.json'",
        "--exclude='/mu-plugins/composer.lock'",
        "--exclude='/mu-plugins/vendor/'",
    ):
        assert required in text, f"missing sync exclusion: {required}"
    uploads_dir = text.index("--include='/uploads/'")
    uploads_tree = text.index("--include='/uploads/***'", uploads_dir)
    deny_rest = text.index("--exclude='*'", uploads_tree)
    assert uploads_dir < uploads_tree < deny_rest
    assert text.count("--include='/uploads/'") == 1
    assert text.count("--include='/uploads/***'") == 1
    assert text.count("--exclude='*'") == 1


def python_heredocs(text: str) -> list[str]:
    """Return every single-quoted PY heredoc body for syntax validation."""
    lines = text.splitlines()
    payloads: list[str] = []
    index = 0
    while index < len(lines):
        if "<<'PY'" not in lines[index]:
            index += 1
            continue
        start = index + 1
        while start < len(lines) and lines[start].lstrip().startswith("|"):
            start += 1
        end = start
        while end < len(lines) and lines[end] != "PY":
            end += 1
        assert end < len(lines), "unterminated Python heredoc"
        payloads.append("\n".join(lines[start:end]) + "\n")
        index = end + 1
    return payloads


def verify_nginx_snippet_contract(
    sensitive_deny_text: str,
    legacy_images_text: str,
    wp_content_php_rule: str,
) -> None:
    """Keep upload and Nginx snippet assertions independent of the fixed checker path."""
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    assert wp_content_php_rule in sensitive_deny_text
    assert "location ~* ^/images/.*\\.php(?:$|/) {" in sensitive_deny_text
    assert "wp-content/uploads/hero-images/$1;" in legacy_images_text
    for executable_pattern in (
        "-iname '*.php*'",
        "-iname '*.phtml*'",
        "-iname '*.phar*'",
        "-iname '.htaccess'",
        "-iname '.user.ini'",
        "-iname '*.sh'",
        "-iname '*.py'",
    ):
        assert executable_pattern in verifier_text
    assert "executable or config payload remains in uploads" in verifier_text


def main() -> None:
    receiver_text = RECEIVER.read_text(encoding="utf-8")
    sender_text = SENDER.read_text(encoding="utf-8")
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    sensitive_deny_text = SENSITIVE_DENY.read_text(encoding="utf-8")
    legacy_images_text = LEGACY_IMAGES.read_text(encoding="utf-8")
    nginx_routing_smoke_text = NGINX_ROUTING_SMOKE.read_text(encoding="utf-8")
    nginx_readme_text = NGINX_README.read_text(encoding="utf-8")
    gate_text = SSH_GATE.read_text(encoding="utf-8")
    sudoers_text = SUDOERS.read_text(encoding="utf-8")
    sshd_match_text = SSHD_MATCH.read_text(encoding="utf-8")
    lines = receiver_text.splitlines()
    authority_verifier_sha256 = hashlib.sha256(AUTHORITY_VERIFIER.read_bytes()).hexdigest()

    assert lines[:2] == ["#!/bin/bash", "set -euo pipefail"]
    assert "PATH=/usr/sbin:/usr/bin:/sbin:/bin" in lines
    assert "unset CDPATH ENV BASH_ENV PYTHONPATH PYTHONHOME || true" in lines
    assert 'SITE=/var/www/html/shuzijun.com.cn' in lines
    assert 'CLAIM_ROOT=/var/lib/shuzijun-sync/incoming' in lines
    assert 'STATE_ROOT=/var/lib/shuzijun-sync/state' in lines
    assert 'LAST_ACCEPTED_GENERATION="$STATE_ROOT/highest-accepted-generation"' in lines
    assert 'SELF=/usr/local/sbin/apply-shuzijun-sync' in lines
    assert "STAGE=" not in receiver_text
    assert "/tmp/shuzijun-stage" not in receiver_text

    authority_lock = line_number(lines, 'exec 8<"$SITE"')
    authority_flock = line_number(lines, "flock -n 8", authority_lock)
    standby_preflight = line_number(lines, "verify_authority_role standby", authority_flock)
    self_gate = line_number(lines, 'test "$0" = "$SELF"', standby_preflight)
    attest_exit = line_number(lines, '"$1" == --attest', self_gate)
    protocol_exit = line_number(lines, '"$1" == --protocol', attest_exit)
    ingest_mode = line_number(lines, '"$1" == --ingest', protocol_exit)
    preflight = line_number(lines, '"$VERIFY" "$SITE"', ingest_mode)
    pre_smoke = line_number(lines, "probe_standby_api", preflight)
    signer_preflight = line_number(lines, "validate_allowed_signers", pre_smoke)
    state_root_preflight = line_number(lines, "validate_sync_state_roots", signer_preflight)
    claim = line_number(
        lines, 'CLAIM=$(mktemp -d "$CLAIM_ROOT/batch.XXXXXX")', state_root_preflight
    )
    bounded_control = line_number(lines, 'read_control_frame "$CLAIM"', claim)
    signed_control = line_number(lines, 'verify_control_signature "$CLAIM"', bounded_control)
    signed_payload = line_number(lines, 'GENERATION=$(ingest_signed_payload "$CLAIM")', signed_control)
    replay_gate = line_number(lines, 'accept_generation "$GENERATION"', signed_payload)
    backup = line_number(lines, 'wp db export "$DEST/wordpress.sql"')
    backup_sync = line_number(lines, 'sync -f "$DEST"', backup)
    file_sync = line_number(lines, "rsync -a --delete --no-owner")
    database_import = line_number(lines, 'wp db import "$SQL"')
    schema_update = line_number(lines, "wp core update-db")
    cache_flush = line_number(lines, "wp cache flush --allow-root")
    standby_restart_gate = line_number(lines, "verify_authority_role standby", cache_flush)
    immutable_root = line_number(lines, 'install -d -o root -g www-data -m 755 "$wp_content"')
    ownership_safe_sync = line_number(lines, "rsync -a --delete --no-owner --no-group --chmod=D755,F644")
    code_hardening = line_number(lines, '! -name uploads ! -name cache')
    runtime_ownership = line_number(lines, 'chown -R www-data:www-data "$runtime_path"')
    nginx_check = line_number(lines, "nginx -t")
    service_restart = line_number(lines, "systemctl restart php8.3-fpm")
    post_smoke = line_number(lines, "if ! probe_standby_api", service_restart)

    assert authority_lock < authority_flock < standby_preflight < self_gate < attest_exit
    assert attest_exit < protocol_exit < ingest_mode < preflight < pre_smoke
    assert pre_smoke < signer_preflight < state_root_preflight < claim
    assert claim < bounded_control < signed_control
    assert signed_control < signed_payload < replay_gate < backup
    assert replay_gate < backup < backup_sync < immutable_root < file_sync
    assert file_sync == ownership_safe_sync < code_hardening < runtime_ownership
    assert runtime_ownership < database_import
    assert database_import < schema_update < cache_flush
    assert cache_flush < standby_restart_gate < nginx_check < service_restart < post_smoke
    assert "--allow-root" in lines[cache_flush]
    assert any("cache=flushed" in line for line in lines)
    assert receiver_text.count('"$VERIFY" "$SITE"') >= 2
    assert receiver_text.count("verify_authority_role standby") == 2
    sender_lines = sender_text.splitlines()
    sender_lock = line_number(sender_lines, 'exec 8<"$SITE"')
    sender_flock = line_number(sender_lines, "flock -n 8", sender_lock)
    sender_role = line_number(sender_lines, "verify_authority_role authority", sender_flock)
    receiver_hash_gate = line_number(sender_lines, "receiver_attestation=", sender_role)
    receiver_protocol_gate = line_number(sender_lines, "receiver_protocol=", receiver_hash_gate)
    generation_root_gate = line_number(
        sender_lines, "validate_generation_state_root", receiver_protocol_gate
    )
    generation_issue = line_number(
        sender_lines, "GENERATION=$(issue_generation)", generation_root_gate
    )
    sender_temp = line_number(sender_lines, "TMP=$(mktemp -d)", generation_issue)
    sender_export = line_number(sender_lines, "wp db export", sender_temp)
    sender_media_stage = line_number(sender_lines, "rsync -a --delete --delete-excluded", sender_export)
    sender_sign = line_number(sender_lines, "ssh-keygen -Y sign", sender_media_stage)
    receiver_apply = line_number(sender_lines, '"sudo $REMOTE_RECEIVER --ingest"', sender_sign)
    assert sender_lock < sender_flock < sender_role < receiver_hash_gate
    assert receiver_hash_gate < receiver_protocol_gate < generation_root_gate
    assert generation_root_gate < generation_issue < sender_temp
    assert sender_temp < sender_export < sender_media_stage < sender_sign < receiver_apply
    receiver_sha256 = hashlib.sha256(RECEIVER.read_bytes()).hexdigest()
    assert f"REMOTE_RECEIVER_SHA256={receiver_sha256}" in sender_text
    receiver_protocol = next(
        line.removeprefix("SYNC_PROTOCOL=")
        for line in receiver_text.splitlines()
        if line.startswith("SYNC_PROTOCOL=")
    )
    sender_protocol = next(
        line.removeprefix("SYNC_PROTOCOL=")
        for line in sender_text.splitlines()
        if line.startswith("SYNC_PROTOCOL=")
    )
    assert receiver_protocol == sender_protocol == "shuzijun-sync-receiver-v3-signed-uploads-only"
    assert 'test "$receiver_protocol" = "$SYNC_PROTOCOL"' in sender_text
    for sync_text in (receiver_text, sender_text):
        assert f"AUTHORITY_VERIFY_SHA256={authority_verifier_sha256}" in sync_text
        assert 'sha256sum "$verifier_fd_path"' in sync_text
        assert '"$AUTHORITY_VERIFY_SHA256"' in sync_text
        assert "for authority_verify_parent in /usr /usr/local /usr/local/sbin" in sync_text
        assert "authority_verify_parent_mode" in sync_text
        assert "/usr/bin/python3 -I \"$verifier_fd_path\"" in sync_text
    assert 'gunzip -c "$DATABASE" > "$SQL"' in receiver_text
    assert "ubuntu@" not in sender_text
    assert "shuzijun-sync-transport" in sender_text
    assert "/tmp/shuzijun-stage" not in sender_text
    assert "rsync -e" not in sender_text
    assert '"sudo $REMOTE_RECEIVER --ingest"' in sender_text
    assert "ssh-keygen -Y verify" in receiver_text
    assert "SYNC_ALLOWED_SIGNERS=/etc/shuzijun/sync-signers" in receiver_text
    for signer_guard in (
        "test \"$(stat -c '%u:%g:%a' \"$parent\")\" = '0:0:755'",
        "test \"$(stat -c '%u:%g:%h:%a' \"$SYNC_ALLOWED_SIGNERS\")\" = '0:0:1:644'",
        "-I shuzijun-sync",
        "-n shuzijun-sync",
    ):
        assert signer_guard in receiver_text
    assert 'for state_directory in "$SYNC_ROOT" "$CLAIM_ROOT" "$STATE_ROOT"' in receiver_text
    assert 'test "$(stat -c \'%u:%g:%a\' "$state_directory")" = \'0:0:700\'' in receiver_text
    assert "for parent in /var /var/lib" in receiver_text
    assert "for parent in /var /var/lib" in sender_text
    assert "shuzijun-sync-manifest.json" in receiver_text
    for manifest_guard in (
        'set(document) != {"files", "generation", "version"}',
        'document["version"] != 2',
        "canonical != raw",
        "MAX_FILES = 100_000",
        "MAX_FILE_BYTES = 8 * 1024 * 1024 * 1024",
        "MAX_BATCH_BYTES = 64 * 1024 * 1024 * 1024",
        "MIN_FREE_RESERVE = 1024 * 1024 * 1024",
        'relative == "shuzijun-sync.sql.gz"',
        'relative.startswith("wp-content/uploads/")',
        '".php" in name',
        "metadata.st_nlink != 1",
        "if os.read(0, 1)",
    ):
        assert manifest_guard in receiver_text
    for replay_guard in (
        "candidate <= current",
        'prefix=".highest-accepted."',
        "os.replace(temp_path, state_path)",
        "os.fsync(directory)",
    ):
        assert replay_guard in receiver_text
    for sender_generation_guard in (
        'GENERATION_ROOT=/var/lib/shuzijun-sync',
        'GENERATION_STATE="$GENERATION_ROOT/highest-issued-generation"',
        'prefix=".highest-issued."',
        "os.replace(temp_path, state_path)",
        'document = {"files": files, "generation": generation, "version": 2}',
    ):
        assert sender_generation_guard in sender_text
    assert 'receive("shuzijun-sync-manifest.json", 32 * 1024 * 1024)' in receiver_text
    assert 'receive("shuzijun-sync-manifest.json.sig", 64 * 1024)' in receiver_text
    assert 'verify_control_signature "$CLAIM"' in receiver_text
    assert receiver_text.index('verify_control_signature "$CLAIM"') < receiver_text.index(
        'GENERATION=$(ingest_signed_payload "$CLAIM")'
    )
    assert "ssh-keygen -Y sign -q" in sender_text
    assert "-n shuzijun-sync" in sender_text
    assert receiver_text.count("rest_route=%2Fshuzijun%2Fv1%2Fapp-content") == 2
    assert "yishu_account_authority_unavailable" in receiver_text
    for isolation_guard in (
        "systemctl mask --now php8.3-fpm",
        "systemctl stop php8.3-fpm",
        "LoadState --value",
        "ActiveState --value",
        "SubState --value",
        '"$enabled_state" == masked',
        "systemctl is-active --quiet php8.3-fpm",
    ):
        assert isolation_guard in receiver_text
    isolate_body = receiver_text[
        receiver_text.index("isolate_failed_fpm()") : receiver_text.index(
            "# Share the site-directory", receiver_text.index("isolate_failed_fpm()")
        )
    ]
    assert "|| true" not in isolate_body
    assert 'chown www-data:www-data "$wp_content"' not in receiver_text
    assert "--delete-excluded" in sender_text
    verify_filters(sender_text)
    receiver_rsync_start = receiver_text.index(
        "rsync -a --delete --no-owner --no-group --chmod=D755,F644"
    )
    receiver_rsync_end = receiver_text.index(
        '"$CLAIM/wp-content/uploads/" "$SITE/wp-content/uploads/"',
        receiver_rsync_start,
    )
    assert '"${RSYNC_FILTERS[@]}"' not in receiver_text
    assert '"$CLAIM/wp-content/" "$SITE/wp-content/"' not in receiver_text
    assert receiver_rsync_start < receiver_rsync_end
    sender_rsync_start = sender_text.index("rsync -a --delete --delete-excluded")
    sender_rsync_end = sender_text.index('"$SITE/wp-content/"', sender_rsync_start)
    assert '"${RSYNC_FILTERS[@]}"' in sender_text[sender_rsync_start:sender_rsync_end]
    assert "stat -c '%a %U:%G' \"$wp_content\"" in verifier_text
    assert "'755 root:www-data'" in verifier_text
    assert '-path "$wp_content/uploads"' in verifier_text
    assert '-path "$wp_content/cache"' in verifier_text
    assert "-type l -print -quit" in verifier_text
    assert "-iname '*.php' ! -name '*.php'" in verifier_text
    assert 'uploads_root="$site_root/wp-content/uploads"' in verifier_text
    assert "-iname '*.php*'" in verifier_text
    assert "executable or config payload remains in uploads" in verifier_text
    assert gate_text.startswith("#!/bin/sh\nset -eu\n")
    assert gate_text.count("exec /usr/bin/sudo -n /usr/local/sbin/apply-shuzijun-sync") == 3
    assert "SSH_ORIGINAL_COMMAND" in gate_text
    assert "command denied" in gate_text
    assert os.stat(SSH_GATE).st_mode & 0o777 == 0o755
    assert sudoers_text == (
        "Cmnd_Alias SHUZIJUN_SYNC_RECEIVER = "
        "/usr/local/sbin/apply-shuzijun-sync --attest, "
        "/usr/local/sbin/apply-shuzijun-sync --protocol, "
        "/usr/local/sbin/apply-shuzijun-sync --ingest\n"
        "shuzijun-sync-transport ALL=(root:root) NOPASSWD: "
        "SHUZIJUN_SYNC_RECEIVER\n"
    )
    assert "NOPASSWD: ALL" not in sudoers_text
    assert sshd_match_text.startswith("Match User shuzijun-sync-transport\n")
    assert "    AuthenticationMethods publickey\n" in sshd_match_text
    assert "    ForceCommand /usr/local/sbin/shuzijun-sync-ssh-gate\n" in sshd_match_text
    assert sshd_match_text.endswith("\nMatch all\n")
    for script_text in (receiver_text, sender_text):
        payloads = python_heredocs(script_text)
        assert payloads
        for payload in payloads:
            ast.parse(payload)
    assert "shuzijun-legacy-images-alias.conf" in verifier_text
    wp_content_php_rule = "location ~* ^/wp-content/.*\\.php(?:$|/) {"
    assert wp_content_php_rule in sensitive_deny_text
    assert wp_content_php_rule in verifier_text
    assert "wp-content/(?:uploads|cache)" not in sensitive_deny_text
    assert "^/images/.*\\.php" in sensitive_deny_text
    assert "location ~* ^/images/" in legacy_images_text
    assert "wp-content/uploads/hero-images/$1" in legacy_images_text
    assert "location /images/" in legacy_images_text
    assert "location ^~ /images/" not in legacy_images_text
    for required_probe in (
        "/wp-content/mu-plugins/shuzijun-app-content.php",
        "/wp-content/mu-plugins/shuzijun-app-content.PHP",
        "/wp-content/mu-plugins/shuzijun-app-content.php/path-info",
        "/wp-content/mu-plugins/shuzijun-app-content%2ephp",
        "/wp-json/shuzijun/v1/app-content",
        "/index.php?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
        "/?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
    ):
        assert required_probe in nginx_routing_smoke_text
    assert nginx_routing_smoke_text.count('assert_status 404 "/wp-content/') >= 4
    assert nginx_routing_smoke_text.count("assert_secure_api_error") >= 4
    assert "fan_session_required" in nginx_routing_smoke_text
    assert "yishu_account_authority_unavailable" in nginx_routing_smoke_text
    assert 'origin_role=${2:-www}' in nginx_routing_smoke_text
    assert 'node_role=${3:-}' in nginx_routing_smoke_text
    assert '"$origin_role" == www' in nginx_routing_smoke_text
    assert "https://img.shuzijun.com.cn img standby" in nginx_readme_text
    assert "https://www.shuzijun.com.cn www authority" in nginx_readme_text
    assert "https://www.shuzijun.com.cn www standby" in nginx_readme_text
    verify_nginx_snippet_contract(
        sensitive_deny_text,
        legacy_images_text,
        wp_content_php_rule,
    )

    print("sync-script-contract-test: passed")


if __name__ == "__main__":
    main()
