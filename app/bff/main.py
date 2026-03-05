"""BFF Service — FastAPI Backend-for-Frontend.

Orchestrates calls to Cart, Payments, and Inventory services via VPC Lattice.
All requests are signed with SigV4 for VPC Lattice IAM authentication.

Cart and Inventory share a single VPC Lattice service ("items") and are
differentiated by the x-service header. Payments is a separate service.
"""

import json
import os
from datetime import datetime, timezone

import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session as BotocoreSession
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from models import BFFResponse, HealthStatus, LatticeHeaders

app = FastAPI(title="E-Commerce Platform BFF")

ITEMS_SERVICE_URL = os.environ.get("ITEMS_SERVICE_URL", "https://items.lattice.internal")
PAYMENTS_SERVICE_URL = os.environ.get("PAYMENTS_SERVICE_URL", "https://payments.lattice.internal")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "10"))
HEALTH_TIMEOUT = float(os.environ.get("HEALTH_TIMEOUT", "3"))
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")

_botocore_session = BotocoreSession()


def _sign_request(method: str, url: str, headers: dict | None = None, data: str | None = None) -> dict:
    if headers is None:
        headers = {}
    headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
    request = AWSRequest(method=method, url=url, headers=headers, data=data or "")
    request.context["payload_signing_enabled"] = False
    credentials = _botocore_session.get_credentials()
    SigV4Auth(credentials, "vpc-lattice-svcs", AWS_REGION).add_auth(request)
    signed = dict(request.headers)
    signed.pop("host", None)
    signed.pop("Host", None)
    return signed


def _build_lattice_headers(raw: dict | None) -> LatticeHeaders:
    return LatticeHeaders(headers=raw or {})


# ── Inventory ────────────────────────────────────────────────────────────────

@app.get("/api/inventory")
async def get_inventory():
    full_url = f"{ITEMS_SERVICE_URL}/inventory"
    try:
        headers = _sign_request("GET", full_url, {"x-service": "inventory"})
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as c:
            resp = await c.get(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        return JSONResponse(status_code=503, content={"error": "Inventory unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Inventory returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


# ── Cart ─────────────────────────────────────────────────────────────────────

@app.get("/api/cart")
async def get_cart():
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("GET", full_url, {"x-service": "cart"})
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as c:
            resp = await c.get(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Cart returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


@app.post("/api/cart")
async def add_to_cart(request: Request):
    req_body = await request.body()
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("POST", full_url, {"x-service": "cart", "Content-Type": "application/json"}, req_body.decode())
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as c:
            resp = await c.post(full_url, content=req_body, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    return JSONResponse(status_code=resp.status_code, content=resp.json())


@app.delete("/api/cart")
async def clear_cart():
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("DELETE", full_url, {"x-service": "cart"})
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as c:
            resp = await c.delete(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    return JSONResponse(status_code=resp.status_code, content=resp.json())


# ── Payments ─────────────────────────────────────────────────────────────────

@app.post("/api/payments")
async def process_payment(request: Request):
    req_body = await request.body()
    full_url = f"{PAYMENTS_SERVICE_URL}/payments"
    try:
        headers = _sign_request("POST", full_url, {"Content-Type": "application/json"}, req_body.decode())
        async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as c:
            resp = await c.post(full_url, content=req_body, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        return JSONResponse(status_code=503, content={"error": "Payments unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Payments returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


# ── Health ───────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    import asyncio

    async def check_items(service_name: str) -> str:
        full_url = f"{ITEMS_SERVICE_URL}/health"
        try:
            headers = _sign_request("GET", full_url, {"x-service": service_name})
            async with httpx.AsyncClient(timeout=HEALTH_TIMEOUT) as c:
                resp = await c.get(full_url, headers=headers)
                return "reachable" if resp.status_code == 200 else "unreachable"
        except (httpx.ConnectError, httpx.TimeoutException):
            return "unreachable"

    async def check(url: str, path: str) -> str:
        try:
            headers = _sign_request("GET", f"{url}{path}")
            async with httpx.AsyncClient(timeout=HEALTH_TIMEOUT) as c:
                resp = await c.get(f"{url}{path}", headers=headers)
                return "reachable" if resp.status_code == 200 else "unreachable"
        except (httpx.ConnectError, httpx.TimeoutException):
            return "unreachable"

    cart_status, inventory_status, payments_status = await asyncio.gather(
        check_items("cart"), check_items("inventory"), check(PAYMENTS_SERVICE_URL, "/health"),
    )
    return HealthStatus(cart_service=cart_status, payments_service=payments_status, inventory_service=inventory_status)
