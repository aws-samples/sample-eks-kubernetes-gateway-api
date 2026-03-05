"""Inventory Service — serves a catalog of unicorn products.

Runs in EKS, accessed via VPC Lattice.
"""

from datetime import datetime, timezone

from fastapi import FastAPI, Request

app = FastAPI(title="Inventory Service")

CATALOG = [
    {"sku": "UNI-001", "name": "Rainbow Sparkle", "price": 49.99, "stock": 12},
    {"sku": "UNI-002", "name": "Midnight Star", "price": 59.99, "stock": 8},
    {"sku": "UNI-003", "name": "Golden Blaze", "price": 79.99, "stock": 5},
    {"sku": "UNI-004", "name": "Crystal Frost", "price": 44.99, "stock": 15},
    {"sku": "UNI-005", "name": "Thunder Hoof", "price": 89.99, "stock": 3},
    {"sku": "UNI-006", "name": "Velvet Dream", "price": 54.99, "stock": 10},
    {"sku": "UNI-007", "name": "Solar Flare", "price": 69.99, "stock": 7},
    {"sku": "UNI-008", "name": "Mystic Shadow", "price": 64.99, "stock": 6},
    {"sku": "UNI-009", "name": "Pearl Whisper", "price": 39.99, "stock": 20},
    {"sku": "UNI-010", "name": "Ember Wing", "price": 74.99, "stock": 4},
]


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/inventory")
async def get_inventory(request: Request):
    return {
        "data": {"products": CATALOG},
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
