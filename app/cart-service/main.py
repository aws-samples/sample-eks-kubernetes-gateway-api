"""Cart Service — in-memory shopping cart.

Runs in EKS, accessed via VPC Lattice.
Simple demo cart — single global cart (no sessions).
"""

from datetime import datetime, timezone

from fastapi import FastAPI, Request
from pydantic import BaseModel

app = FastAPI(title="Cart Service")

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
