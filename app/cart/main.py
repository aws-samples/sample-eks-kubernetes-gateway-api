"""Cart Service — in-memory shopping cart with checkout via VPC Lattice.

Runs in EKS on Backend-B, accessed via VPC Lattice.

The checkout endpoint calls the Payments service on the Edge cluster through
VPC Lattice, signing the request with SigV4. This demonstrates cross-cluster
service-to-service communication where a backend service is both a Lattice
producer (serving cart operations) and a Lattice consumer (calling payments).

IMPORTANT — Sample simplification:
  The cart is stored as a module-level Python list. This means:
  - All users share the same cart (no session isolation)
  - State is lost on pod restart
  - Concurrent requests can cause race conditions
  In production, replace with a per-session store (e.g. Redis, DynamoDB).
"""

import logging
import os
from contextlib import asynccontextmanager
from datetime import datetime, timezone

import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session as BotocoreSession
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

PAYMENTS_SERVICE_URL = os.environ.get("PAYMENTS_SERVICE_URL", "https://payments.lattice.internal")
AWS_REGION = os.environ.get("AWS_REGION", "eu-west-1")
REQUEST_TIMEOUT = float(os.environ.get("REQUEST_TIMEOUT", "10"))

_botocore_session = BotocoreSession()
_http_client: httpx.AsyncClient | None = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Manage the lifecycle of the shared HTTP client for outbound Lattice calls."""
    global _http_client
    _http_client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    logger.info("HTTP client initialised (timeout=%.1fs)", REQUEST_TIMEOUT)
    yield
    await _http_client.aclose()
    logger.info("HTTP client closed")


app = FastAPI(title="Cart Service", lifespan=lifespan)

# Single shared cart — intentionally simple for this sample.
cart_items: list[dict] = []


class AddItemRequest(BaseModel):
    sku: str
    name: str
    price: float


def _sign_request(method: str, url: str, headers: dict | None = None, data: str | None = None) -> dict:
    """Sign an HTTP request with AWS SigV4 for VPC Lattice IAM authentication.

    VPC Lattice does not support payload signing, so we must include
    x-amz-content-sha256: UNSIGNED-PAYLOAD and disable payload signing.
    """
    headers = dict(headers or {})
    headers["x-amz-content-sha256"] = "UNSIGNED-PAYLOAD"
    aws_request = AWSRequest(method=method, url=url, headers=headers, data=data or "")
    aws_request.context["payload_signing_enabled"] = False
    credentials = _botocore_session.get_credentials()
    SigV4Auth(credentials, "vpc-lattice-svcs", AWS_REGION).add_auth(aws_request)
    return dict(aws_request.headers)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/cart")
async def get_cart(request: Request):
    total = round(sum(item["price"] for item in cart_items), 2)
    return {
        "data": {"items": cart_items, "total": total, "count": len(cart_items)},
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.post("/cart")
async def add_to_cart(item: AddItemRequest):
    cart_items.append({"sku": item.sku, "name": item.name, "price": item.price})
    return {"status": "added", "count": len(cart_items)}


@app.delete("/cart")
async def clear_cart():
    cart_items.clear()
    return {"status": "cleared", "count": 0}


@app.post("/cart/checkout")
async def checkout(request: Request):
    """Checkout: call Payments service via VPC Lattice, then clear the cart.

    This endpoint demonstrates cross-cluster service-to-service communication.
    The cart service (Backend-B) calls the payments service (Edge) through
    VPC Lattice with SigV4 signing. The response includes Lattice headers
    from both hops so the frontend can display the full request chain.
    """
    if not cart_items:
        return JSONResponse({"error": "Cart is empty"}, status_code=400)

    total = round(sum(item["price"] for item in cart_items), 2)
    payload = {"items": list(cart_items), "total": total}

    import json
    body = json.dumps(payload)
    url = f"{PAYMENTS_SERVICE_URL}/payments"

    signed_headers = _sign_request("POST", url, {"Content-Type": "application/json"}, body)
    try:
        resp = await _http_client.post(url, content=body, headers=signed_headers)
        resp.raise_for_status()
        payments_response = resp.json()
    except Exception as e:
        logger.error("Payments call failed: %s", e)
        return JSONResponse({"error": f"Payment failed: {str(e)}"}, status_code=502)

    # Clear cart on successful payment
    cart_items.clear()

    return {
        "data": payments_response.get("data", {}),
        "lattice_headers": dict(request.headers),
        "downstream_lattice_headers": {
            "payments": payments_response.get("lattice_headers", {})
        },
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
