import os
import subprocess
import tempfile
from pathlib import Path


CHECKER = Path("Server/operations/verify-nginx-server-block-contract.py").resolve()
SENSITIVE_SOURCE = Path(
    "Server/nginx/shuzijun-sensitive-files-deny.conf"
).resolve()
LEGACY_SOURCE = Path("Server/nginx/shuzijun-legacy-images-alias.conf").resolve()


class Fixture:
    HEALTH = '  location ~ "^/health/[0-9]{1,5}$" { return 204; }\n'
    STATIC_PATTERN = (
        r"\.(?:jpg|jpeg|png|gif|webp|avif|ico|css|js|svg|woff|woff2)$"
    )

    def __init__(self, root: Path) -> None:
        self.root = root
        self.site_root = root / "site"
        self.site_root.mkdir()
        self.sites_available = root / "sites-available"
        self.sites_available.mkdir()
        self.sites_enabled = root / "sites-enabled"
        self.sites_enabled.mkdir()
        self.snippets = root / "snippets"
        self.snippets.mkdir()
        self.site_config = self.sites_available / "shuzijun-ssl.conf"
        self.enabled_entry = self.sites_enabled / "shuzijun-ssl.conf"
        self.sensitive = self.snippets / "shuzijun-sensitive-files-deny.conf"
        self.legacy = self.snippets / "shuzijun-legacy-images-alias.conf"
        self.security = self.snippets / "shuzijun-security.conf"
        self.fastcgi_php = self.snippets / "fastcgi-php.conf"
        self.fastcgi_conf = root / "fastcgi.conf"

        self.sensitive.write_text(
            SENSITIVE_SOURCE.read_text(encoding="utf-8"), encoding="utf-8"
        )
        self.legacy.write_text(
            LEGACY_SOURCE.read_text(encoding="utf-8"), encoding="utf-8"
        )
        self.security.write_text(
            "add_header X-Content-Type-Options nosniff always;\n"
            "add_header X-Frame-Options DENY always;\n"
            "add_header Referrer-Policy no-referrer always;\n"
            "add_header Permissions-Policy camera=() always;\n"
            "add_header Cross-Origin-Opener-Policy same-origin always;\n"
            "add_header Cross-Origin-Resource-Policy same-origin always;\n"
            "add_header X-Permitted-Cross-Domain-Policies none always;\n",
            encoding="utf-8",
        )
        self.fastcgi_php.write_text(
            'fastcgi_split_path_info "^(.+?\\.php)(/.*)$";\n'
            "try_files $fastcgi_script_name =404;\n"
            "set $path_info $fastcgi_path_info;\n"
            "fastcgi_param PATH_INFO $path_info;\n"
            "fastcgi_index index.php;\n"
            "include fastcgi.conf;\n",
            encoding="utf-8",
        )
        self.fastcgi_conf.write_text(
            "fastcgi_param QUERY_STRING $query_string;\n"
            "fastcgi_param REQUEST_METHOD $request_method;\n"
            "fastcgi_param CONTENT_TYPE $content_type;\n"
            "fastcgi_param CONTENT_LENGTH $content_length;\n"
            "fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;\n"
            "fastcgi_param SCRIPT_NAME $fastcgi_script_name;\n"
            "fastcgi_param REQUEST_URI $request_uri;\n"
            "fastcgi_param DOCUMENT_URI $document_uri;\n"
            "fastcgi_param DOCUMENT_ROOT $document_root;\n"
            "fastcgi_param SERVER_PROTOCOL $server_protocol;\n"
            "fastcgi_param REQUEST_SCHEME $scheme;\n"
            "fastcgi_param HTTPS $https if_not_empty;\n"
            "fastcgi_param GATEWAY_INTERFACE CGI/1.1;\n"
            "fastcgi_param SERVER_SOFTWARE nginx/$nginx_version;\n"
            "fastcgi_param REMOTE_ADDR $remote_addr;\n"
            "fastcgi_param REMOTE_PORT $remote_port;\n"
            "fastcgi_param REMOTE_USER $remote_user;\n"
            "fastcgi_param SERVER_ADDR $server_addr;\n"
            "fastcgi_param SERVER_PORT $server_port;\n"
            "fastcgi_param SERVER_NAME $server_name;\n"
            "fastcgi_param REDIRECT_STATUS 200;\n",
            encoding="utf-8",
        )
        self.site_config.write_text(self.valid_config(), encoding="utf-8")
        self.enabled_entry.symlink_to(self.site_config)

    def valid_config(self) -> str:
        www_php = (
            "  location ~ \\.php$ {\n"
            "    include snippets/fastcgi-php.conf;\n"
            "    fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;\n"
            "  }\n"
        )
        return (
            "# Real deployments have a port-80 redirect block for each host.\n"
            "server {\n"
            "  listen 80;\n"
            "  listen [::]:80;\n"
            "  server_name www.shuzijun.com.cn;\n"
            "  location ^~ /.well-known/acme-challenge/ { return 404; }\n"
            "  return 301 https://$host$request_uri;\n"
            "}\n"
            "server {\n"
            "  listen 80;\n"
            "  server_name img.shuzijun.com.cn;\n"
            "  return 301 https://$host$request_uri;\n"
            "}\n"
            "server {\n"
            "  listen 127.0.0.1:443 ssl;\n"
            "  listen [::]:443 ssl http2;\n"
            "  server_name \"www.shuzijun.com.cn\";\n"
            f"  root \"{self.site_root}\";\n"
            "  set $quoted \"# location ^~ /images/ { include fake; }\";\n"
            "  set $variable ${contract_value};\n"
            f"  include {self.security};\n"
            f"  include {self.sensitive};\n"
            f"  include {self.legacy};\n"
            "  location = /favicon.ico { alias /var/www/favicon.ico; }\n"
            "  location = /wp-login.php {\n"
            "    include snippets/fastcgi-php.conf;\n"
            "    fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;\n"
            "  }\n"
            "  location /wp-json/shuzijun/v1/ { proxy_pass http://account-api; }\n"
            "  location / { try_files $uri $uri/ /index.php?$args; }\n"
            "  location ~* /(?:uploads|files)/.*\\.php$ { return 404; }\n"
            + www_php
            + "  location ~* \\.m3u8$ { try_files $uri =404; }\n"
            "  location ~* \\.(?:ts|mp4|m4v|webm)$ { try_files $uri =404; }\n"
            f"  location ~* {self.STATIC_PATTERN} {{ try_files $uri =404; }}\n"
            "  location ~ /\\. { deny all; }\n"
            + self.HEALTH
            + "}\n"
            "server {\n"
            "  listen 443 ssl;\n"
            "  server_name img.shuzijun.com.cn;\n"
            f"  root {self.site_root};\n"
            f"  include {self.security};\n"
            f"  include {self.sensitive};\n"
            f"  include {self.legacy};\n"
            f"  location ~* {self.STATIC_PATTERN} {{ try_files $uri =404; }}\n"
            "  location / { try_files $uri =404; }\n"
            "  location ~ \\.php$ { return 404; }\n"
            "  location ~ /\\. { deny all; }\n"
            + self.HEALTH
            + "}\n"
        )

    def command(self) -> list[str]:
        owner = f"{os.getuid()}:{os.getgid()}"
        return [
            "python3",
            str(CHECKER),
            "--site-root",
            str(self.site_root),
            "--site-config",
            str(self.site_config),
            "--enabled-entry",
            str(self.enabled_entry),
            "--sensitive-snippet",
            str(self.sensitive),
            "--legacy-snippet",
            str(self.legacy),
            "--config-owner",
            owner,
            "--site-root-owner",
            owner,
        ]

    def run(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(self.command(), capture_output=True, text=True)

    def replace(self, old: str, new: str) -> None:
        content = self.site_config.read_text(encoding="utf-8")
        assert old in content, old
        self.site_config.write_text(content.replace(old, new, 1), encoding="utf-8")

    def replace_health(self, replacement: str) -> None:
        self.replace(self.HEALTH, replacement.rstrip("\n") + "\n")

    def generic_php_block(self) -> str:
        return (
            "  location ~ \\.php$ {\n"
            "    include snippets/fastcgi-php.conf;\n"
            "    fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;\n"
            "  }\n"
        )


def assert_rejected(fixture: Fixture, expected: str) -> None:
    result = fixture.run()
    assert result.returncode != 0, result.stdout
    assert expected in result.stderr, result.stderr


def run_case(mutator, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-semantic-") as temp_dir:
        fixture = Fixture(Path(temp_dir).resolve())
        mutator(fixture)
        assert_rejected(fixture, expected)


def run_accepted_case(mutator=lambda fixture: None) -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-semantic-") as temp_dir:
        fixture = Fixture(Path(temp_dir).resolve())
        mutator(fixture)
        result = fixture.run()
        assert result.returncode == 0, result.stderr


def add_www_include(fixture: Fixture, include_path: str) -> None:
    location = "  location /wp-json/shuzijun/v1/ { proxy_pass http://account-api; }\n"
    fixture.replace(location, f"  include {include_path};\n" + location)


def main() -> None:
    # Positive fixture mirrors the real primary/backup shape: duplicate host
    # names on port 80, one TLS server per host, normal server/snippet includes,
    # and the Debian fastcgi-php.conf -> fastcgi.conf include chain.
    run_accepted_case()

    run_case(
        lambda fixture: fixture.enabled_entry.unlink(),
        "canonical sites-enabled entry is missing",
    )

    def regular_enabled(fixture: Fixture) -> None:
        fixture.enabled_entry.unlink()
        fixture.enabled_entry.write_text(
            fixture.site_config.read_text(encoding="utf-8"), encoding="utf-8"
        )

    run_case(regular_enabled, "must be a symlink to sites-available")

    def drifted_enabled(fixture: Fixture) -> None:
        drift = fixture.sites_available / "drifted.conf"
        drift.write_text(fixture.valid_config(), encoding="utf-8")
        fixture.enabled_entry.unlink()
        fixture.enabled_entry.symlink_to(drift)

    run_case(drifted_enabled, "does not directly target the canonical site config")

    def indirect_enabled_target(fixture: Fixture) -> None:
        intermediary = fixture.sites_available / "intermediary.conf"
        intermediary.symlink_to(fixture.site_config)
        fixture.enabled_entry.unlink()
        fixture.enabled_entry.symlink_to(intermediary)

    run_case(
        indirect_enabled_target,
        "does not directly target the canonical site config",
    )

    def extra_enabled(fixture: Fixture) -> None:
        (fixture.sites_enabled / "extra.conf").write_text("# drift\n", encoding="utf-8")

    run_case(extra_enabled, "sites-enabled must contain only the canonical")

    def external_enabled_symlink(fixture: Fixture) -> None:
        (fixture.sites_enabled / "external.conf").symlink_to(
            "/tmp/unreviewed-nginx.conf"
        )

    run_case(external_enabled_symlink, "sites-enabled must contain only the canonical")

    def hardlinked_site_config(fixture: Fixture) -> None:
        os.link(fixture.site_config, fixture.root / "site-config-hardlink.conf")

    run_case(hardlinked_site_config, "canonical site config must not be hard-linked")

    run_case(
        lambda fixture: fixture.replace(
            f"  include {fixture.sensitive};\n",
            "  location /nested {\n"
            f"    include {fixture.sensitive};\n"
            "  }\n",
        ),
        "exactly once as a direct server child",
    )
    run_case(
        lambda fixture: fixture.replace(
            f"  include {fixture.sensitive};\n",
            "  location /before-security { return 204; }\n"
            f"  include {fixture.sensitive};\n",
        ),
        "security includes must precede every location",
    )
    run_case(
        lambda fixture: fixture.replace(
            f"  include {fixture.sensitive};\n",
            f"  include {fixture.sensitive};\n"
            f"  include {fixture.sensitive};\n",
        ),
        "exactly once as a direct server child",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location ^~ /wp-content/ { return 404; }"
        ),
        "^~ location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location ^~ /ordinary-assets/ { try_files $uri =404; }"
        ),
        "^~ location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location = /wp-content/mu-plugins/x.php { return 200; }"
        ),
        "exact location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location = /wp-config.php { return 200; }"
        ),
        "exact location that bypasses sensitive regex rules",
    )
    for sensitive_uri in (
        "/composer.json",
        "/exports/database.sql",
        "/private/CREDENTIALS-prod.JSON",
        "/mu-plugins/file.php.bak",
        "/assets/.svn",
    ):
        run_case(
            lambda fixture, uri=sensitive_uri: fixture.replace_health(
                f"  location = {uri} {{ return 200; }}"
            ),
            "exact location that bypasses sensitive regex rules",
        )
    run_accepted_case(
        lambda fixture: fixture.replace_health(
            "  location = /robots.txt { return 204; }"
        )
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location /images/ { alias /tmp/old-images/; }"
        ),
        "inline legacy /images location",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location ~* ^/[i]mages/.*\\.php$ { return 404; }"
        ),
        "regex location outside the reviewed allowlist",
    )

    def legacy_disk_entry(fixture: Fixture) -> None:
        (fixture.site_root / "images").mkdir()

    run_case(legacy_disk_entry, "legacy document-root images entry still exists")

    def duplicate_host(fixture: Fixture) -> None:
        content = fixture.site_config.read_text(encoding="utf-8")
        fixture.site_config.write_text(
            content
            + "server { listen 443 ssl; server_name www.shuzijun.com.cn; "
            + f"root {fixture.site_root}; }}\n",
            encoding="utf-8",
        )

    run_case(duplicate_host, "exactly one enabled TLS server block")

    def top_level_hidden_duplicate(fixture: Fixture) -> None:
        hidden = fixture.snippets / "top-level-duplicate.conf"
        hidden.write_text(
            "server { listen 443 ssl; server_name www.shuzijun.com.cn; "
            f"root {fixture.site_root}; }}\n",
            encoding="utf-8",
        )
        content = fixture.site_config.read_text(encoding="utf-8")
        fixture.site_config.write_text(
            f"include {fixture.snippets}/top-level-*.conf;\n" + content,
            encoding="utf-8",
        )

    run_case(top_level_hidden_duplicate, "exactly one enabled TLS server block")

    def remove_www_tls(fixture: Fixture) -> None:
        fixture.replace("  listen 127.0.0.1:443 ssl;", "  listen 127.0.0.1:443;")
        fixture.replace("  listen [::]:443 ssl http2;", "  listen [::]:443;")

    run_case(remove_www_tls, "exactly one enabled TLS server block")

    def move_www_off_443(fixture: Fixture) -> None:
        fixture.replace(
            "  listen 127.0.0.1:443 ssl;", "  listen 127.0.0.1:4430 ssl;"
        )
        fixture.replace(
            "  listen [::]:443 ssl http2;", "  listen [::]:4430 ssl;"
        )

    run_case(move_www_off_443, "exactly one enabled TLS server block")
    run_case(
        lambda fixture: fixture.replace(
            f'  root "{fixture.site_root}";', "  root /tmp/unreviewed;"
        ),
        "root is not the reviewed site root",
    )

    def quoted_root_escape(fixture: Fixture) -> None:
        escaped = str(fixture.site_root).replace("/", r"\/")
        fixture.replace(
            f'  root "{fixture.site_root}";', f'  root "{escaped}";'
        )

    run_case(quoted_root_escape, "root must be a fixed absolute path")

    def quoted_include_escape(fixture: Fixture) -> None:
        escaped = str(fixture.sensitive).replace("/", r"\/")
        fixture.replace(
            f"  include {fixture.sensitive};", f'  include "{escaped}";'
        )

    run_case(quoted_include_escape, "dynamic or escaped Nginx include path")

    run_case(
        lambda fixture: fixture.replace_health(
            "  location /outer {\n"
            "    location ~* /(?:uploads|files)/.*\\.php$ { return 404; }\n"
            "  }"
        ),
        "contains a nested location",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  error_page 404 = @fallback;\n"
            "  location @fallback { return 200; }"
        ),
        "rewrite/error-page routing",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  rewrite ^ /index.php last;"
        ),
        "rewrite/error-page routing",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location @fallback { return 404; }"
        ),
        "unreviewed named location",
    )
    run_case(
        lambda fixture: fixture.replace_health(
            "  location ~* ^/unreviewed/.*$ { return 404; }"
        ),
        "regex location outside the reviewed allowlist",
    )
    run_case(
        lambda fixture: fixture.replace(
            f"  location ~* {fixture.STATIC_PATTERN} {{ try_files $uri =404; }}",
            f"  location ~* {fixture.STATIC_PATTERN} {{ alias /tmp/assets/; }}",
        ),
        "reviewed static regex handler drifted",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ /\\. { deny all; }",
            "  location ~ /\\. { allow all; deny all; }",
        ),
        "reviewed dotfile regex handler drifted",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ /\\. { deny all; }",
            "  location ~ /\\. { satisfy any; deny all; }",
        ),
        "reviewed dotfile regex handler drifted",
    )

    def sensitive_drift(fixture: Fixture) -> None:
        content = fixture.sensitive.read_text(encoding="utf-8")
        fixture.sensitive.write_text(
            content.replace("return 404;", "return 403;", 1), encoding="utf-8"
        )

    run_case(sensitive_drift, "sensitive snippet semantic content drifted")

    def legacy_drift(fixture: Fixture) -> None:
        content = fixture.legacy.read_text(encoding="utf-8")
        fixture.legacy.write_text(
            content.replace("return 308 /images/;", "return 302 /images/;", 1),
            encoding="utf-8",
        )

    run_case(legacy_drift, "legacy snippet semantic content drifted")

    def hidden_backup_priority(fixture: Fixture) -> None:
        proxy = fixture.snippets / "account-api-backup-proxy.conf"
        proxy.write_text(
            "location ^~ /wp-json/shuzijun/v1/ { proxy_pass http://origin; }\n",
            encoding="utf-8",
        )
        add_www_include(fixture, str(proxy))

    run_case(hidden_backup_priority, "^~ location that bypasses sensitive regex rules")

    def migrated_backup_prefix(fixture: Fixture) -> None:
        proxy = fixture.snippets / "account-api-backup-proxy.conf"
        proxy.write_text(
            "location /wp-json/shuzijun/v1/ { proxy_pass http://origin; }\n",
            encoding="utf-8",
        )
        direct = "  location /wp-json/shuzijun/v1/ { proxy_pass http://account-api; }\n"
        fixture.replace(
            direct,
            f"  include {fixture.snippets / 'account-api-*.conf'};\n",
        )

    run_accepted_case(migrated_backup_prefix)

    def recursively_hidden_rewrite(fixture: Fixture) -> None:
        inner = fixture.snippets / "inner-routing.conf"
        inner.write_text("rewrite ^ /index.php last;\n", encoding="utf-8")
        outer = fixture.snippets / "outer-routing.conf"
        outer.write_text(f"include {inner};\n", encoding="utf-8")
        add_www_include(fixture, str(outer))

    run_case(recursively_hidden_rewrite, "rewrite/error-page routing")

    def hidden_root(fixture: Fixture) -> None:
        included = fixture.snippets / "hidden-root.conf"
        included.write_text("root /tmp/unreviewed;\n", encoding="utf-8")
        add_www_include(fixture, str(included))

    run_case(hidden_root, "must have exactly one direct root directive")

    def indirect_reviewed_snippet(fixture: Fixture) -> None:
        wrapper = fixture.snippets / "security-wrapper.conf"
        wrapper.write_text(f"include {fixture.sensitive};\n", encoding="utf-8")
        fixture.replace(
            f"  include {fixture.sensitive};\n", f"  include {wrapper};\n"
        )

    run_case(indirect_reviewed_snippet, "must explicitly include sensitive-file")

    def dynamic_include(fixture: Fixture) -> None:
        add_www_include(fixture, "$dynamic_snippet")

    run_case(dynamic_include, "dynamic or escaped Nginx include path")

    def escaping_include(fixture: Fixture) -> None:
        add_www_include(fixture, "/etc/passwd")

    run_case(escaping_include, "Nginx include escapes the reviewed root")

    def recursive_cycle(fixture: Fixture) -> None:
        first = fixture.snippets / "cycle-first.conf"
        second = fixture.snippets / "cycle-second.conf"
        first.write_text(f"include {second};\n", encoding="utf-8")
        second.write_text(f"include {first};\n", encoding="utf-8")
        add_www_include(fixture, str(first))

    run_case(recursive_cycle, "recursive Nginx include cycle")

    def unreadable_include(fixture: Fixture) -> None:
        included = fixture.snippets / "unreadable.conf"
        included.write_text("location /safe { return 204; }\n", encoding="utf-8")
        included.chmod(0)
        add_www_include(fixture, str(included))

    run_case(unreadable_include, "included Nginx file is not owner-readable")

    def writable_recursive_include(fixture: Fixture) -> None:
        included = fixture.snippets / "writable.conf"
        included.write_text("location /safe { return 204; }\n", encoding="utf-8")
        included.chmod(0o666)
        add_www_include(fixture, str(included))

    run_case(writable_recursive_include, "included Nginx file is group/other writable")

    def symlink_recursive_include(fixture: Fixture) -> None:
        target = fixture.snippets / "symlink-target.conf"
        target.write_text("location /safe { return 204; }\n", encoding="utf-8")
        linked = fixture.snippets / "symlink-include.conf"
        linked.symlink_to(target)
        add_www_include(fixture, str(linked))

    run_case(symlink_recursive_include, "must be a regular non-symlink file")

    def hardlink_recursive_include(fixture: Fixture) -> None:
        target = fixture.snippets / "hardlink-target.conf"
        target.write_text("location /safe { return 204; }\n", encoding="utf-8")
        linked = fixture.snippets / "hardlink-include.conf"
        os.link(target, linked)
        add_www_include(fixture, str(linked))

    run_case(hardlink_recursive_include, "included Nginx file must not be hard-linked")

    def writable_include_directory(fixture: Fixture) -> None:
        nested = fixture.snippets / "nested"
        nested.mkdir()
        nested.chmod(0o777)
        included = nested / "route.conf"
        included.write_text("location /safe { return 204; }\n", encoding="utf-8")
        add_www_include(fixture, str(included))

    run_case(writable_include_directory, "included config directory is group/other writable")

    def writable_snippet(fixture: Fixture) -> None:
        fixture.sensitive.chmod(0o666)

    run_case(writable_snippet, "sensitive-file snippet is group/other writable")

    def writable_snippet_directory(fixture: Fixture) -> None:
        fixture.snippets.chmod(0o777)

    run_case(writable_snippet_directory, "snippet directory is group/other writable")

    def php_parameter_override(fixture: Fixture, directive: str) -> None:
        original = fixture.generic_php_block()
        changed = original.replace(
            "    fastcgi_pass", f"    {directive}\n    fastcgi_pass"
        )
        fixture.replace(original, changed)

    for directive in (
        "fastcgi_param SCRIPT_FILENAME /tmp/attacker.php;",
        "fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;",
        "fastcgi_param DOCUMENT_ROOT /tmp;",
        "fastcgi_param PATH_TRANSLATED /tmp/attacker.php;",
        "fastcgi_param SCRIPT_NAME /attacker.php;",
        "fastcgi_param PATH_INFO /attacker;",
    ):
        run_case(
            lambda fixture, value=directive: php_parameter_override(fixture, value),
            "reviewed PHP execution target parameters drifted",
        )

    def recursive_php_override(fixture: Fixture) -> None:
        attack = fixture.snippets / "php-override.conf"
        attack.write_text(
            "fastcgi_param SCRIPT_FILENAME /tmp/attacker.php;\n",
            encoding="utf-8",
        )
        original = fixture.generic_php_block()
        changed = original.replace(
            "    fastcgi_pass", f"    include {attack};\n    fastcgi_pass"
        )
        fixture.replace(original, changed)

    run_case(
        recursive_php_override,
        "reviewed PHP execution target parameters drifted",
    )

    def exact_php_override(fixture: Fixture) -> None:
        marker = "    fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;\n"
        fixture.replace(
            marker,
            "    fastcgi_param SCRIPT_FILENAME /tmp/attacker.php;\n" + marker,
        )

    run_case(
        exact_php_override,
        "reviewed PHP execution target parameters drifted",
    )

    def rewrite_in_security_snippet(fixture: Fixture) -> None:
        with fixture.security.open("a", encoding="utf-8") as handle:
            handle.write("rewrite ^ /index.php last;\n")

    run_case(rewrite_in_security_snippet, "rewrite/error-page routing")

    print("nginx-server-block-contract-test: passed")


if __name__ == "__main__":
    main()
