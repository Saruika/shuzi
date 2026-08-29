import base64
import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
import time
from contextlib import closing
from pathlib import Path

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field, field_validator
from starlette.responses import JSONResponse

INTERNAL_TOKEN = os.environ.get("YISHU_PUSH_INTERNAL_TOKEN", "")
DATABASE_PATH = Path(os.environ.get("YISHU_PUSH_DATABASE", "/var/lib/yishu-push/devices.sqlite3"))
APNS_KEY_PATH = Path(os.environ.get("YISHU_APNS_KEY_PATH", "/etc/yishu/apns/AuthKey.p8"))
APNS_KEY_ID = os.environ.get("YISHU_APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("YISHU_APNS_TEAM_ID", "")
APNS_TOPIC = os.environ.get("YISHU_APNS_TOPIC", "cn.com.shuzijun.yishu")
DEVICE_KEY_TEXT = os.environ.get("YISHU_PUSH_DEVICE_KEY", "")

TOKEN_PATTERN = re.compile(r"^[0-9a-f]{64,200}$")
EVENT_ID_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{3,160}$")
ALLOWED_KINDS = {"douyin", "xiaohongshu", "live"}
ALLOWED_HOSTS = {
    "douyin.com",
    "www.douyin.com",
    "v.douyin.com",
    "live.douyin.com",
    "iesdouyin.com",
    "www.iesdouyin.com",
    "xiaohongshu.com",
    "www.xiaohongshu.com",
    "xhslink.com",
    "www.xhslink.com",
}


def decode_device_key() -> bytes:
    try:
        key = base64.urlsafe_b64decode(DEVICE_KEY_TEXT.encode("ascii"))
    except Exception:
        key = b""
    return key if len(key) == 32 else b""


DEVICE_KEY = decode_device_key()
JWT_LOCK = threading.Lock()
JWT_CACHE: tuple[str, int] | None = None


class Preferences(BaseModel):
    newWorks: bool = True
    live: bool = True


class DeviceRequest(BaseModel):
    token: str = Field(min_length=64, max_length=200)
    environment: str
    preferences: Preferences

    @field_validator("token")
    @classmethod
    def validate_token(cls, value: str) -> str:
        value = value.lower()
        if not TOKEN_PATTERN.fullmatch(value):
            raise ValueError("Invalid device token")
        return value

    @field_validator("environment")
    @classmethod
    def validate_environment(cls, value: str) -> str:
        if value not in {"sandbox", "production"}:
            raise ValueError("Invalid APNs environment")
        return value


class EventRequest(BaseModel):
    eventID: str = Field(min_length=3, max_length=160)
    kind: str
    title: str = Field(min_length=1, max_length=80)
    body: str = Field(min_length=1, max_length=300)
    url: str = Field(min_length=8, max_length=1000)

    @field_validator("eventID")
    @classmethod
    def validate_event_id(cls, value: str) -> str:
        if not EVENT_ID_PATTERN.fullmatch(value):
            raise ValueError("Invalid event ID")
        return value

    @field_validator("kind")
    @classmethod
    def validate_kind(cls, value: str) -> str:
        if value not in ALLOWED_KINDS:
            raise ValueError("Invalid event kind")
        return value

    @field_validator("url")
    @classmethod
    def validate_url(cls, value: str) -> str:
        parsed = httpx.URL(value)
        if parsed.scheme != "https" or parsed.host not in ALLOWED_HOSTS:
            raise ValueError("Untrusted event URL")
        return value


def configuration_ready() -> bool:
    return (
        len(INTERNAL_TOKEN) >= 32
        and len(DEVICE_KEY) == 32
        and bool(APNS_KEY_ID)
        and bool(APNS_TEAM_ID)
        and bool(APNS_TOPIC)
        and APNS_KEY_PATH.is_file()
    )


def connect() -> sqlite3.Connection:
    DATABASE_PATH.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    connection = sqlite3.connect(DATABASE_PATH, timeout=10)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA journal_mode=WAL")
    connection.execute("PRAGMA foreign_keys=ON")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS devices (
            token_hash TEXT PRIMARY KEY,
            token_cipher BLOB NOT NULL,
            nonce BLOB NOT NULL,
            environment TEXT NOT NULL CHECK(environment IN ('sandbox', 'production')),
            wants_works INTEGER NOT NULL,
            wants_live INTEGER NOT NULL,
            active INTEGER NOT NULL DEFAULT 1,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """
    )
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS events (
            event_id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            delivered INTEGER NOT NULL DEFAULT 0,
            failed INTEGER NOT NULL DEFAULT 0
        )
        """
    )
    connection.commit()
    return connection


def require_internal_token(value: str) -> None:
    if len(INTERNAL_TOKEN) < 32 or not hmac.compare_digest(value, INTERNAL_TOKEN):
        raise HTTPException(status_code=401, detail="Unauthorized")


def token_hash(token: str) -> str:
    return hmac.new(DEVICE_KEY, token.encode("ascii"), hashlib.sha256).hexdigest()


def encrypt_token(token: str) -> tuple[bytes, bytes]:
    nonce = secrets.token_bytes(12)
    cipher = AESGCM(DEVICE_KEY).encrypt(nonce, token.encode("ascii"), APNS_TOPIC.encode("utf-8"))
    return cipher, nonce


def decrypt_token(cipher: bytes, nonce: bytes) -> str:
    plain = AESGCM(DEVICE_KEY).decrypt(nonce, cipher, APNS_TOPIC.encode("utf-8"))
    return plain.decode("ascii")


def base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def apns_jwt() -> str:
    global JWT_CACHE
    now = int(time.time())
    with JWT_LOCK:
        if JWT_CACHE and now - JWT_CACHE[1] < 45 * 60:
            return JWT_CACHE[0]
        private_key = serialization.load_pem_private_key(APNS_KEY_PATH.read_bytes(), password=None)
        if not isinstance(private_key, ec.EllipticCurvePrivateKey):
            raise RuntimeError("APNs key is not an EC private key")
        header = base64url(json.dumps({"alg": "ES256", "kid": APNS_KEY_ID}, separators=(",", ":")).encode())
        claims = base64url(json.dumps({"iss": APNS_TEAM_ID, "iat": now}, separators=(",", ":")).encode())
        signing_input = f"{header}.{claims}".encode("ascii")
        der = private_key.sign(signing_input, ec.ECDSA(hashes.SHA256()))
        r, s = decode_dss_signature(der)
        signature = base64url(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        token = f"{header}.{claims}.{signature}"
        JWT_CACHE = (token, now)
        return token


def deactivate(connection: sqlite3.Connection, row: sqlite3.Row) -> None:
    connection.execute("UPDATE devices SET active = 0, updated_at = ? WHERE token_hash = ?", (int(time.time()), row["token_hash"]))


async def deliver_event(event: EventRequest) -> tuple[int, int]:
    preference_column = "wants_live" if event.kind == "live" else "wants_works"
    payload = {
        "aps": {
            "alert": {"title": event.title, "body": event.body[:180]},
            "sound": "default",
        },
        "kind": event.kind,
        "eventID": event.eventID,
        "url": event.url,
    }
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    if len(encoded) > 4096:
        raise RuntimeError("APNs payload is too large")

    auth = apns_jwt()
    with closing(connect()) as connection:
        rows = connection.execute(
            f"SELECT * FROM devices WHERE active = 1 AND {preference_column} = 1 LIMIT 10000"
        ).fetchall()

    async def send(row: sqlite3.Row, client: httpx.AsyncClient) -> tuple[bool, bool]:
        try:
            token = decrypt_token(row["token_cipher"], row["nonce"])
            host = "api.sandbox.push.apple.com" if row["environment"] == "sandbox" else "api.push.apple.com"
            response = await client.post(
                f"https://{host}/3/device/{token}",
                content=encoded,
                headers={
                    "authorization": f"bearer {auth}",
                    "apns-topic": APNS_TOPIC,
                    "apns-push-type": "alert",
                    "apns-priority": "10",
                    "apns-expiration": "0",
                    "content-type": "application/json",
                },
            )
            if response.status_code == 200:
                return True, False
            reason = ""
            try:
                reason = response.json().get("reason", "")
            except Exception:
                pass
            invalid = response.status_code == 410 or reason in {
                "BadDeviceToken",
                "DeviceTokenNotForTopic",
                "Unregistered",
            }
            return False, invalid
        except Exception:
            return False, False

    results: list[tuple[bool, bool]] = []
    limits = httpx.Limits(max_connections=50, max_keepalive_connections=20)
    async with httpx.AsyncClient(http2=True, timeout=12, follow_redirects=False, limits=limits) as client:
        for offset in range(0, len(rows), 100):
            batch = rows[offset : offset + 100]
            results.extend(await asyncio.gather(*(send(row, client) for row in batch)))

    delivered = sum(1 for success, _ in results if success)
    failed = len(results) - delivered
    with closing(connect()) as connection:
        for row, (_, invalid) in zip(rows, results):
            if invalid:
                deactivate(connection, row)
        connection.execute(
            "UPDATE events SET delivered = ?, failed = ? WHERE event_id = ?",
            (delivered, failed, event.eventID),
        )
        connection.commit()
    return delivered, failed


app = FastAPI(title="Yishu push provider", docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def bound_request_size(request: Request, call_next):
    content_length = request.headers.get("content-length")
    try:
        too_large = content_length is not None and int(content_length) > 16_384
    except ValueError:
        too_large = True
    if too_large:
        return JSONResponse({"detail": "Request too large"}, status_code=413)
    return await call_next(request)


@app.get("/healthz")
def health() -> dict[str, object]:
    active = 0
    if len(DEVICE_KEY) == 32:
        with closing(connect()) as connection:
            active = connection.execute("SELECT COUNT(*) FROM devices WHERE active = 1").fetchone()[0]
    return {"ok": configuration_ready(), "activeDevices": active}


@app.post("/v1/devices")
def register_device(
    payload: DeviceRequest,
    x_yishu_internal_token: str = Header(default=""),
) -> dict[str, bool]:
    require_internal_token(x_yishu_internal_token)
    if not configuration_ready():
        raise HTTPException(status_code=503, detail="Push provider is not configured")
    cipher, nonce = encrypt_token(payload.token)
    now = int(time.time())
    with closing(connect()) as connection:
        connection.execute(
            """
            INSERT INTO devices (
                token_hash, token_cipher, nonce, environment, wants_works,
                wants_live, active, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT(token_hash) DO UPDATE SET
                token_cipher = excluded.token_cipher,
                nonce = excluded.nonce,
                environment = excluded.environment,
                wants_works = excluded.wants_works,
                wants_live = excluded.wants_live,
                active = 1,
                updated_at = excluded.updated_at
            """,
            (
                token_hash(payload.token),
                cipher,
                nonce,
                payload.environment,
                int(payload.preferences.newWorks),
                int(payload.preferences.live),
                now,
                now,
            ),
        )
        connection.commit()
    return {"registered": True}


@app.post("/v1/events")
async def publish_event(
    payload: EventRequest,
    x_yishu_internal_token: str = Header(default=""),
) -> dict[str, object]:
    require_internal_token(x_yishu_internal_token)
    if not configuration_ready():
        raise HTTPException(status_code=503, detail="Push provider is not configured")
    with closing(connect()) as connection:
        cursor = connection.execute(
            "INSERT OR IGNORE INTO events (event_id, kind, created_at) VALUES (?, ?, ?)",
            (payload.eventID, payload.kind, int(time.time())),
        )
        connection.commit()
        if cursor.rowcount == 0:
            return {"accepted": True, "duplicate": True, "delivered": 0, "failed": 0}
    delivered, failed = await deliver_event(payload)
    return {
        "accepted": True,
        "duplicate": False,
        "delivered": delivered,
        "failed": failed,
    }
