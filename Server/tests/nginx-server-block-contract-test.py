import os
import subprocess
import tempfile
from pathlib import Path


CHECKER = Path("Server/operations/verify-nginx-server-block-contract.py").resolve()


class Fixture:
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
        self.sensitive.write_text("# fixture\n", encoding="utf-8")
        self.legacy.write_text("# fixture\n", encoding="utf-8")
        self.site_config.write_text(self.valid_config(), encoding="utf-8")
        self.enabled_entry.symlink_to(self.site_config)

    def valid_config(self) -> str:
        return (
            "# server { server_name www.shuzijun.com.cn; }\n"
            "server{\n"
            "  listen 127.0.0.1:443 ssl;\n"
            "  server_name \"www.shuzijun.com.cn\";\n"
            f"  root \"{self.site_root}\";\n"
            "  set $quoted \"# location ^~ /images/ { include fake; }\";\n"
            "  set $variable ${contract_value};\n"
            f"  include {self.sensitive};\n"
            f"  include {self.legacy};\n"
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }\n"
            "}\n"
            "server {\n"
            "  listen [::]:443 ssl http2;\n"
            "  server_name img.shuzijun.com.cn;\n"
            f"  root {self.site_root};\n"
            f"  include {self.sensitive};\n"
            f"  include {self.legacy};\n"
            "  location = /health { return 204; }\n"
            "}\n"
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
        assert old in content
        self.site_config.write_text(content.replace(old, new, 1), encoding="utf-8")


def assert_rejected(fixture: Fixture, expected: str) -> None:
    result = fixture.run()
    assert result.returncode != 0, result.stdout
    assert expected in result.stderr, result.stderr


def run_case(mutator, expected: str) -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-semantic-") as temp_dir:
        fixture = Fixture(Path(temp_dir).resolve())
        mutator(fixture)
        assert_rejected(fixture, expected)


def run_accepted_case(mutator) -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-semantic-") as temp_dir:
        fixture = Fixture(Path(temp_dir).resolve())
        mutator(fixture)
        result = fixture.run()
        assert result.returncode == 0, result.stderr


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="yishu-nginx-semantic-") as temp_dir:
        fixture = Fixture(Path(temp_dir).resolve())
        result = fixture.run()
        assert result.returncode == 0, result.stderr
        assert "nginx-server-block-contract: passed" in result.stdout

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

    run_case(drifted_enabled, "does not activate the canonical site config")

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
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location ^~ /wp-content/ { return 404; }",
        ),
        "^~ location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location ^~ /ordinary-assets/ { try_files $uri =404; }",
        ),
        "^~ location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location = /wp-content/mu-plugins/x.php { return 200; }",
        ),
        "exact location that bypasses sensitive regex rules",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location = /wp-config.php { return 200; }",
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
            lambda fixture, uri=sensitive_uri: fixture.replace(
                "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
                f"  location = {uri} {{ return 200; }}",
            ),
            "exact location that bypasses sensitive regex rules",
        )
    run_accepted_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location = /favicon.ico { return 204; }\n"
            "  location = /robots.txt { return 204; }",
        )
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location /images/ { alias /tmp/old-images/; }",
        ),
        "inline legacy /images location",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  location ~ ^/health/[0-9]{1,5}$ { return 204; }",
            "  location ~* ^/images/.*\\.php$ { return 404; }",
        ),
        "inline legacy /images location",
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

    run_case(duplicate_host, "must appear in exactly one enabled server block")
    run_case(
        lambda fixture: fixture.replace(
            "  listen 127.0.0.1:443 ssl;", "  listen 127.0.0.1:443;"
        ),
        "must have a direct 443 ssl listener",
    )
    run_case(
        lambda fixture: fixture.replace(
            "  listen 127.0.0.1:443 ssl;", "  listen [::]:4430 ssl;"
        ),
        "must have a direct 443 ssl listener",
    )
    run_case(
        lambda fixture: fixture.replace(
            f"  root \"{fixture.site_root}\";", "  root /tmp/unreviewed;"
        ),
        "root is not the reviewed site root",
    )

    def writable_snippet(fixture: Fixture) -> None:
        fixture.sensitive.chmod(0o666)

    run_case(writable_snippet, "sensitive-file snippet is group/other writable")

    print("nginx-server-block-contract-test: passed")


if __name__ == "__main__":
    main()
