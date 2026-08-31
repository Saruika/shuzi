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


def line_number(lines: list[str], fragment: str) -> int:
    for index, line in enumerate(lines):
        if fragment in line:
            return index
    raise AssertionError(f"missing required operation: {fragment}")


def verify_filters(text: str) -> None:
    for required in (
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
    ):
        assert required in text, f"missing sync exclusion: {required}"


def verify_nginx_snippet_contract(
    sensitive_deny_text: str,
    legacy_images_text: str,
    wp_content_php_rule: str,
) -> None:
    """Exercise the operational verifier with current and legacy snippets."""
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-contract-") as temp_dir:
        root = Path(temp_dir).resolve()
        site_root = root / "site"
        wp_content = site_root / "wp-content"
        wp_content.mkdir(parents=True)
        (site_root / "wp-config.php").touch()

        sites_available = root / "sites-available"
        sites_enabled = root / "sites-enabled"
        sites_available.mkdir()
        sites_enabled.mkdir()
        sensitive_deny = root / "shuzijun-sensitive-files-deny.conf"
        legacy_images = root / "shuzijun-legacy-images-alias.conf"
        nginx_site = sites_available / "site.conf"
        nginx_site.write_text(
            "server {\n"
            "    listen 443 ssl;\n"
            "    server_name www.shuzijun.com.cn;\n"
            f"    root {site_root};\n"
            f"    include {sensitive_deny};\n"
            f"    include {legacy_images};\n"
            "}\n"
            "server {\n"
            "    listen 443 ssl;\n"
            "    server_name img.shuzijun.com.cn;\n"
            f"    root {site_root};\n"
            f"    include {sensitive_deny};\n"
            f"    include {legacy_images};\n"
            "}\n",
            encoding="utf-8",
        )
        nginx_enabled = sites_enabled / "site.conf"
        nginx_enabled.symlink_to(nginx_site)
        sensitive_deny.write_text(sensitive_deny_text, encoding="utf-8")
        legacy_images.write_text(legacy_images_text, encoding="utf-8")

        fake_bin = root / "bin"
        fake_bin.mkdir()
        for name, body in {
            "find": "#!/bin/sh\nexit 0\n",
            "nginx": "#!/bin/sh\nexit 0\n",
            "stat": (
                "#!/bin/sh\n"
                "case \"$*\" in\n"
                "  *wp-config.php) printf '640 root:www-data\\n' ;;\n"
                "  *) printf '755 root:www-data\\n' ;;\n"
                "esac\n"
            ),
        }.items():
            executable = fake_bin / name
            executable.write_text(body, encoding="utf-8")
            executable.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = f"{fake_bin}:{env['PATH']}"
        command = [
            "bash",
            str(VERIFIER.resolve()),
            str(site_root),
            str(nginx_site),
            str(sensitive_deny),
            str(legacy_images),
            str(nginx_enabled),
            str(NGINX_CONTRACT.resolve()),
            f"{os.getuid()}:{os.getgid()}",
            f"{os.getuid()}:{os.getgid()}",
        ]
        current = subprocess.run(command, capture_output=True, text=True, env=env)
        assert current.returncode == 0, current.stderr

        legacy_rule = (
            "location ~* ^/wp-content/(?:uploads|cache)/.*\\.php(?:$|/) {"
        )
        legacy_text = sensitive_deny_text.replace(wp_content_php_rule, legacy_rule)
        assert legacy_text != sensitive_deny_text
        sensitive_deny.write_text(legacy_text, encoding="utf-8")
        legacy = subprocess.run(command, capture_output=True, text=True, env=env)
        assert legacy.returncode != 0
        assert "direct wp-content PHP deny rule is missing" in legacy.stderr


def main() -> None:
    receiver_text = RECEIVER.read_text(encoding="utf-8")
    sender_text = SENDER.read_text(encoding="utf-8")
    verifier_text = VERIFIER.read_text(encoding="utf-8")
    sensitive_deny_text = SENSITIVE_DENY.read_text(encoding="utf-8")
    legacy_images_text = LEGACY_IMAGES.read_text(encoding="utf-8")
    nginx_routing_smoke_text = NGINX_ROUTING_SMOKE.read_text(encoding="utf-8")
    nginx_readme_text = NGINX_README.read_text(encoding="utf-8")
    lines = receiver_text.splitlines()

    assert lines[:2] == ["#!/bin/bash", "set -euo pipefail"]
    assert 'SITE=/var/www/html/shuzijun.com.cn' in lines
    assert 'STAGE=/tmp/shuzijun-stage' in lines

    checksum = line_number(lines, 'sha256sum -c "$MANIFEST"')
    preflight = line_number(lines, '"$VERIFY" "$SITE"')
    backup = line_number(lines, 'wp db export "$DEST/wordpress.sql"')
    file_sync = line_number(lines, "rsync -a --delete")
    database_import = line_number(lines, 'wp db import "$STAGE/shuzijun-sync.sql"')
    schema_update = line_number(lines, "wp core update-db")
    cache_flush = line_number(lines, "wp cache flush --allow-root")
    immutable_root = line_number(lines, 'install -d -o root -g www-data -m 755 "$wp_content"')
    ownership_safe_sync = line_number(lines, "rsync -a --delete --no-owner --no-group --chmod=D755,F644")
    code_hardening = line_number(lines, '! -name uploads ! -name cache')
    runtime_ownership = line_number(lines, 'chown -R www-data:www-data "$runtime_path"')
    nginx_check = line_number(lines, "nginx -t")
    service_restart = line_number(lines, "systemctl restart php8.3-fpm")

    assert preflight < checksum < backup < immutable_root < file_sync
    assert file_sync == ownership_safe_sync < code_hardening < runtime_ownership
    assert runtime_ownership < database_import
    assert database_import < schema_update < cache_flush
    assert cache_flush < nginx_check < service_restart
    assert "--allow-root" in lines[cache_flush]
    assert any("cache=flushed" in line for line in lines)
    assert receiver_text.count('"$VERIFY" "$SITE"') >= 2
    assert 'chown www-data:www-data "$wp_content"' not in receiver_text
    assert "--delete-excluded" in sender_text
    verify_filters(receiver_text)
    verify_filters(sender_text)
    assert "stat -c '%a %U:%G' \"$wp_content\"" in verifier_text
    assert "'755 root:www-data'" in verifier_text
    assert '-path "$wp_content/uploads"' in verifier_text
    assert '-path "$wp_content/cache"' in verifier_text
    assert "-type l -print -quit" in verifier_text
    assert "-iname '*.php' ! -name '*.php'" in verifier_text
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
        "/index.php?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
        "/?rest_route=%2Fshuzijun%2Fv1%2Fapp-content",
    ):
        assert required_probe in nginx_routing_smoke_text
    assert nginx_routing_smoke_text.count('assert_status 404 "/wp-content/') >= 4
    assert nginx_routing_smoke_text.count("assert_secure_401") >= 3
    assert 'payload.get("code") == "fan_session_required"' in nginx_routing_smoke_text
    assert 'origin_role=${2:-www}' in nginx_routing_smoke_text
    assert '"$origin_role" == www' in nginx_routing_smoke_text
    assert "https://img.shuzijun.com.cn img" in nginx_readme_text
    verify_nginx_snippet_contract(
        sensitive_deny_text,
        legacy_images_text,
        wp_content_php_rule,
    )

    print("sync-script-contract-test: passed")


if __name__ == "__main__":
    main()
