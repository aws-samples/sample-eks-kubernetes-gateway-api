"""BFF Service — FastAPI Backend-for-Frontend.

Orchestrates calls to Cart, Payments, and Inventory services via VPC Lattice.
All requests are signed with SigV4 for VPC Lattice IAM authentication.

Cart and Inventory share a single VPC Lattice service ("items") and are
differentiated by the x-service header. Payments is a separate service.

Architecture note:
  Browser → nginx (frontend) → BFF → VPC Lattice → Cart / Inventory / Payments
  The BFF is the only component that holds AWS credentials (via EKS Pod Identity).
  It signs every outbound request with SigV4 so the browser never touches AWS auth.

HTTP client lifecycle:
  A single httpx.AsyncClient is created at application startup via FastAPI's
  lifespan context manager and reused for all requests. This allows the client
  to maintain a connection pool — subsequent requests to the same VPC Lattice
  host reuse existing TCP connections (HTTP keep-alive), avoiding the overhead
  of a new TCP handshake (and TLS handshake in HTTPS mode) on every API call.
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session as BotocoreSession
from fastapi import FastAPI
from fastapi.responses import JSONResponse

from models import AddToCartRequest, BFFResponse, HealthStatus, LatticeHeaders, PaymentRequest

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

ITEMS_SERVICE_URL = os.environ.get("ITEMS_SERVICE_URL", "https://items.lattice.internal")
PAYMENTS_SERVICE_URL = os.environ.get("PAYMENTS_SERVICE_URL", "https://payments.lattice.internal")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "10"))
HEALTH_TIMEOUT = float(os.environ.get("HEALTH_TIMEOUT", "3"))
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")

# Single botocore session reused across all requests — avoids re-reading credentials on every call.
_botocore_session = BotocoreSession()

# Shared HTTP client — set during lifespan startup, used by all endpoint handlers.
_http_client: httpx.AsyncClient | None = None
_health_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage the lifecycle of shared HTTP clients.

    Creating clients here (rather than per-request) allows httpx to maintain
    a connection pool. Connections to VPC Lattice are reused across requests,
    eliminating repeated TCP and TLS handshake overhead.
    """
    global _http_client, _health_client
    _http_client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    _health_client = httpx.AsyncClient(timeout=HEALTH_TIMEOUT)
    logger.info("HTTP clients initialised (timeout=%.1fs, health_timeout=%.1fs)", REQUEST_TIMEOUT, HEALTH_TIMEOUT)
    yield
    await _http_client.aclose()
    await _health_client.aclose()
    logger.info("HTTP clients closed")


app = FastAPI(title="E-Commerce Platform BFF", lifespan=lifespan)


def _sign_request(method: str, url: str, headers: dict | None = None, data: str | None = None) -> dict:
    """Sign an HTTP request with AWS SigV4 for VPC Lattice IAM authentication.

    VPC Lattice requires the 'vpc-lattice-svcs' service name in the signature.
    Credentials are obtained automatically from the EKS Pod Identity token
    mounted at /var/run/secrets/pods.eks.amazonaws.com/serviceaccount/.
    """
    if headers is None:
        headers = {}
    # UNSIGNED-PAYLOAD avoids hashing the body, which is acceptable for VPC Lattice
    # and avoids issues with streaming or large payloads.
    headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
    request = AWSRequest(method=method, url=url, headers=headers, data=data or "")
    request.context["payload_signing_enabled"] = False
    credentials = _botocore_session.get_credentials()
    SigV4Auth(credentials, "vpc-lattice-svcs", AWS_REGION).add_auth(request)
    signed = dict(request.headers)
    # Remove 'host' — the downstream HTTP client sets this from the URL.
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
        resp = await _http_client.get(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        logger.error("Inventory service unreachable at %s", full_url)
        return JSONResponse(status_code=503, content={"error": "Inventory unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Inventory returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


# ── Cart ─────────────────────────────────────────────────────────────────────

@app.get("/api/cart")
async def get_cart():
    # x-service header routes this request to the cart backend via VPC Lattice header-based routing
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("GET", full_url, {"x-service": "cart"})
        resp = await _http_client.get(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        logger.error("Cart service unreachable at %s", full_url)
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Cart returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


@app.post("/api/cart")
async def add_to_cart(item: AddToCartRequest):
    """Add an item to the cart. Validates the request body before forwarding to the cart service."""
    payload = item.model_dump_json().encode()
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("POST", full_url, {"x-service": "cart", "Content-Type": "application/json"}, item.model_dump_json())
        resp = await _http_client.post(full_url, content=payload, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        logger.error("Cart service unreachable at %s", full_url)
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    return JSONResponse(status_code=resp.status_code, content=resp.json())


@app.delete("/api/cart")
async def clear_cart():
    full_url = f"{ITEMS_SERVICE_URL}/cart"
    try:
        headers = _sign_request("DELETE", full_url, {"x-service": "cart"})
        resp = await _http_client.delete(full_url, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        logger.error("Cart service unreachable at %s", full_url)
        return JSONResponse(status_code=503, content={"error": "Cart unreachable"})
    return JSONResponse(status_code=resp.status_code, content=resp.json())


# ── Payments ─────────────────────────────────────────────────────────────────

@app.post("/api/payments")
async def process_payment(payment: PaymentRequest):
    """Process a payment. Validates the request body before forwarding to the payments service."""
    payload = payment.model_dump_json().encode()
    full_url = f"{PAYMENTS_SERVICE_URL}/payments"
    try:
        headers = _sign_request("POST", full_url, {"Content-Type": "application/json"}, payment.model_dump_json())
        resp = await _http_client.post(full_url, content=payload, headers=headers)
    except (httpx.ConnectError, httpx.TimeoutException):
        logger.error("Payments service unreachable at %s", full_url)
        return JSONResponse(status_code=503, content={"error": "Payments unreachable"})
    if resp.status_code != 200:
        return JSONResponse(status_code=resp.status_code, content={"error": f"Payments returned {resp.status_code}"})
    body = resp.json()
    return BFFResponse(data=body.get("data", {}), lattice_headers=_build_lattice_headers(body.get("lattice_headers")), timestamp=datetime.now(timezone.utc).isoformat())


# ── Health ───────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    async def check_items(service_name: str) -> str:
        full_url = f"{ITEMS_SERVICE_URL}/health"
        try:
            headers = _sign_request("GET", full_url, {"x-service": service_name})
            resp = await _health_client.get(full_url, headers=headers)
            return "reachable" if resp.status_code == 200 else "unreachable"
        except (httpx.ConnectError, httpx.TimeoutException):
            return "unreachable"

    async def check(url: str, path: str) -> str:
        try:
            headers = _sign_request("GET", f"{url}{path}")
            resp = await _health_client.get(f"{url}{path}", headers=headers)
            return "reachable" if resp.status_code == 200 else "unreachable"
        except (httpx.ConnectError, httpx.TimeoutException):
            return "unreachable"

    cart_status, inventory_status, payments_status = await asyncio.gather(
        check_items("cart"), check_items("inventory"), check(PAYMENTS_SERVICE_URL, "/health"),
    )
    return HealthStatus(cart_service=cart_status, payments_service=payments_status, inventory_service=inventory_status)
