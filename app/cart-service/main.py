"""Cart Service — in-memory shopping cart.

Runs in EKS, accessed via VPC Lattice.

IMPORTANT — Sample simplification:
  The cart is stored as a module-level Python list. This means:
  - All users share the same cart (no session isolation)
  - State is lost on pod restart
  - Concurrent requests can cause race conditions
  In production, replace with a per-session store (e.g. Redis, DynamoDB).
"""

import logging
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from pydantic import BaseModel

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

app = FastAPI(title="Cart Service")

# Single shared cart — intentionally simple for this sample.
# See module docstring for production considerations.
cart_items: list[dict] = []


class AddItemRequest(BaseModel):
    sku: str
    name: str
    price: float


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
