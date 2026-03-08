"""BFF Service — FastAPI Backend-for-Frontend.

Orchestrates calls to Catalog, Pricing, and Cart services via VPC Lattice.
All outbound requests to VPC Lattice are signed with SigV4 for IAM authentication.

Service routing:
  - Catalog and Pricing share a VPC Lattice Gateway on Backend-A with header-based routing.
    The BFF sends requests to items.<domain> with an x-service header (catalog or pricing).
  - Cart is a separate VPC Lattice service on Backend-B.
  - Payments runs on the same cluster (Edge) and is called intra-cluster by the Cart
    service during checkout. The BFF never calls Payments directly.

Architecture note:
  Browser → nginx (frontend) → BFF → VPC Lattice → Catalog / Pricing / Cart
  The BFF is the only component on the Edge cluster that holds AWS credentials
  (via EKS Pod Identity) for calling VPC Lattice services.

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

from models import AddToCartRequest, BFFResponse, CheckoutResponse, HealthStatus, LatticeHeaders

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

ITEMS_SERVICE_URL = os.environ.get("ITEMS_SERVICE_URL", "https://items.lattice.internal")
CART_SERVICE_URL = os.environ.get("CART_SERVICE_URL", "https://cart.lattice.internal")
PAYMENTS_SERVICE_URL = os.environ.get("PAYMENTS_SERVICE_URL", "https://payments.lattice.internal")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "10"))
HEALTH_TIMEOUT = float(os.environ.get("HEALTH_TIMEOUT", "5"))
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")

# Single botocore session reused across all requests.
_botocore_session = BotocoreSession()

# Shared HTTP clients — set during lifespan startup.
_http_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage the lifecycle of shared HTTP clients."""
    global _http_client
    _http_client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    logger.info("HTTP client initialised (timeout=%.1fs, health_timeout=%.1fs)", REQUEST_TIMEOUT, HEALTH_TIMEOUT)
    yield
    await _http_client.aclose()
    logger.info("HTTP client closed")


app = FastAPI(title="E-Commerce Platform BFF", lifespan=lifespan)


def _sign_request(method: str, url: str, headers: dict | None = None, data: str | None = None) -> dict:
    """Sign an HTTP request with AWS SigV4 for VPC Lattice IAM authentication.

    VPC Lattice does not support payload signing, so we must include
    x-amz-content-sha256: UNSIGNED-PAYLOAD and disable payload signing.
    See: https://docs.aws.amazon.com/vpc-lattice/latest/ug/sigv4-authenticated-requests.html
    """
    headers = dict(headers or {})
    headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
    aws_request = AWSRequest(method=method, url=url, headers=headers, data=data or "")
    aws_request.context["payload_signing_enabled"] = False
    credentials = _botocore_session.get_credentials()
    SigV4Auth(credentials, "vpc-lattice-svcs", AWS_REGION).add_auth(aws_request)
    return dict(aws_request.headers)


async def _lattice_request(method: str, url: str, json_body: str | None = None, extra_headers: dict | None = None) -> dict:
    """Make a SigV4-signed request to a VPC Lattice service."""
    headers = {}
    if json_body:
        headers["Content-Type"] = "application/json"
    if extra_headers:
        headers.update(extra_headers)
    signed_headers = _sign_request(method, url, headers, json_body)
    resp = await _http_client.request(method, url, content=json_body, headers=signed_headers)
    resp.raise_for_status()
    return resp.json()


async def _check_service(url: str, extra_headers: dict | None = None) -> str:
    """Check if a VPC Lattice service is reachable."""
    try:
        headers = dict(extra_headers or {})
        signed = _sign_request("GET", url, headers)
        resp = await _http_client.get(url, headers=signed, timeout=HEALTH_TIMEOUT)
        return "reachable" if resp.status_code == 200 else "unreachable"
    except Exception:
        return "unreachable"


# ── Health ───────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    catalog_url = f"{ITEMS_SERVICE_URL}/health"
    pricing_url = f"{ITEMS_SERVICE_URL}/health"
    cart_url = f"{CART_SERVICE_URL}/health"
    payments_url = f"{PAYMENTS_SERVICE_URL}/health"

    results = await asyncio.gather(
        _check_service(catalog_url, {"x-service": "catalog"}),
        _check_service(pricing_url, {"x-service": "pricing"}),
        _check_service(cart_url),
        _check_service(payments_url),
        return_exceptions=True,
    )

    return HealthStatus(
        catalog_service=results[0] if isinstance(results[0], str) else "unreachable",
        pricing_service=results[1] if isinstance(results[1], str) else "unreachable",
        cart_service=results[2] if isinstance(results[2], str) else "unreachable",
        payments_service=results[3] if isinstance(results[3], str) else "unreachable",
    )


# ── Catalog ──────────────────────────────────────────────────────────────────

@app.get("/api/catalog")
async def get_catalog():
    try:
        data = await _lattice_request("GET", f"{ITEMS_SERVICE_URL}/catalog", extra_headers={"x-service": "catalog"})
        return data
    except Exception as e:
        logger.error("Catalog request failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)


# ── Pricing ──────────────────────────────────────────────────────────────────

@app.get("/api/pricing")
async def get_pricing():
    try:
        data = await _lattice_request("GET", f"{ITEMS_SERVICE_URL}/pricing", extra_headers={"x-service": "pricing"})
        return data
    except Exception as e:
        logger.error("Pricing request failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)


# ── Cart ─────────────────────────────────────────────────────────────────────

@app.get("/api/cart")
async def get_cart():
    try:
        data = await _lattice_request("GET", f"{CART_SERVICE_URL}/cart")
        return data
    except Exception as e:
        logger.error("Cart GET failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)


@app.post("/api/cart")
async def add_to_cart(item: AddToCartRequest):
    try:
        import json
        body = json.dumps(item.model_dump())
        data = await _lattice_request("POST", f"{CART_SERVICE_URL}/cart", body)
        return data
    except Exception as e:
        logger.error("Cart POST failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)


@app.delete("/api/cart")
async def clear_cart():
    try:
        data = await _lattice_request("DELETE", f"{CART_SERVICE_URL}/cart")
        return data
    except Exception as e:
        logger.error("Cart DELETE failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)


# ── Checkout ─────────────────────────────────────────────────────────────────

@app.post("/api/checkout")
async def checkout():
    """Trigger checkout via the Cart service.

    The Cart service on Backend-B handles the full checkout flow:
    it reads the cart, calls Payments on the Edge cluster through VPC Lattice,
    clears the cart on success, and returns the result with Lattice headers
    from both hops (cart + payments).
    """
    try:
        data = await _lattice_request("POST", f"{CART_SERVICE_URL}/cart/checkout")
        return data
    except Exception as e:
        logger.error("Checkout failed: %s", e)
        return JSONResponse({"error": str(e)}, status_code=502)
