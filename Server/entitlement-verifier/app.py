import hmac
import os
import time
from pathlib import Path

from appstoreserverlibrary.models.Environment import Environment
from appstoreserverlibrary.signed_data_verifier import (
    SignedDataVerifier,
    VerificationException,
)
from fastapi import FastAPI, Header, HTTPException, Request
from pydantic import BaseModel, Field
from starlette.responses import JSONResponse

BUNDLE_ID = os.environ.get("YISHU_BUNDLE_ID", "cn.com.shuzijun.yishu")
PRODUCT_ID = os.environ.get(
    "YISHU_PRODUCT_ID",
    "cn.com.shuzijun.yishu.photos.monthly",
)
INTERNAL_TOKEN = os.environ.get("YISHU_INTERNAL_TOKEN", "")
APP_APPLE_ID_TEXT = os.environ.get("YISHU_APP_APPLE_ID", "")
ROOT_CERTIFICATE_DIRECTORY = Path(
    os.environ.get("YISHU_APPLE_ROOT_CERT_DIR", "/etc/yishu/apple-roots")
)
ENABLE_ONLINE_CHECKS = os.environ.get(
    "YISHU_ENABLE_ONLINE_CHECKS", "true"
).lower() in {"1", "true", "yes"}


class VerificationRequest(BaseModel):
    transactionJWS: str = Field(min_length=100, max_length=16_384)


def load_root_certificates() -> list[bytes]:
    certificates = []
    for path in sorted(ROOT_CERTIFICATE_DIRECTORY.glob("*.cer")):
        data = path.read_bytes()
        if data:
            certificates.append(data)
    if not certificates:
        raise RuntimeError("No Apple root certificates are configured")
    return certificates


def build_verifiers() -> list[SignedDataVerifier]:
    if not INTERNAL_TOKEN or len(INTERNAL_TOKEN) < 32:
        raise RuntimeError("YISHU_INTERNAL_TOKEN must contain at least 32 characters")
    app_apple_id = int(APP_APPLE_ID_TEXT) if APP_APPLE_ID_TEXT else None
    roots = load_root_certificates()
    verifiers = [
        SignedDataVerifier(
            roots,
            ENABLE_ONLINE_CHECKS,
            Environment.SANDBOX,
            BUNDLE_ID,
        )
    ]
    if app_apple_id is not None:
        verifiers.insert(
            0,
            SignedDataVerifier(
                roots,
                ENABLE_ONLINE_CHECKS,
                Environment.PRODUCTION,
                BUNDLE_ID,
                app_apple_id,
            ),
        )
    return verifiers


VERIFIERS = build_verifiers()
app = FastAPI(
    title="Yishu entitlement verifier",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


@app.middleware("http")
async def bound_request_size(request: Request, call_next):
    content_length = request.headers.get("content-length")
    try:
        too_large = content_length is not None and int(content_length) > 24_000
    except ValueError:
        too_large = True
    if too_large:
        return JSONResponse({"detail": "Request too large"}, status_code=413)
    return await call_next(request)


@app.get("/healthz")
def health() -> dict[str, bool]:
    return {"ok": True}


@app.post("/v1/verify")
def verify(
    payload: VerificationRequest,
    x_yishu_internal_token: str = Header(default=""),
) -> dict[str, object]:
    if not hmac.compare_digest(x_yishu_internal_token, INTERNAL_TOKEN):
        raise HTTPException(status_code=401, detail="Unauthorized")

    decoded = None
    for verifier in VERIFIERS:
        try:
            decoded = verifier.verify_and_decode_signed_transaction(
                payload.transactionJWS
            )
            break
        except VerificationException:
            decoded = None
    if decoded is None:
        raise HTTPException(status_code=401, detail="Invalid transaction")

    now_milliseconds = int(time.time() * 1000)
    active = (
        decoded.bundleId == BUNDLE_ID
        and decoded.productId == PRODUCT_ID
        and decoded.revocationDate is None
        and decoded.isUpgraded is not True
        and decoded.expiresDate is not None
        and decoded.expiresDate > now_milliseconds
    )
    return {
        "active": active,
        "environment": decoded.rawEnvironment,
        "expiresAt": decoded.expiresDate,
    }
