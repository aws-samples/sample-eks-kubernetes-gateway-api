"""Pricing Service — serves product prices by SKU.

Runs in EKS on Backend-A alongside the Catalog service, accessed via VPC Lattice.
Host-based routing on the same VPC Lattice Gateway differentiates catalog and pricing traffic.
"""

import logging
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

app = FastAPI(title="Pricing Service")

PRICES = {
    "UNI-001": 49.99,
    "UNI-002": 59.99,
    "UNI-003": 79.99,
    "UNI-004": 44.99,
    "UNI-005": 89.99,
    "UNI-006": 54.99,
    "UNI-007": 69.99,
    "UNI-008": 64.99,
    "UNI-009": 39.99,
    "UNI-010": 74.99,
}


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/pricing")
async def get_all_prices(request: Request):
    return {
        "data": {"prices": [{"sku": sku, "price": price} for sku, price in PRICES.items()]},
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/pricing/{sku}")
async def get_price(sku: str, request: Request):
    price = PRICES.get(sku)
    if price is None:
        raise HTTPException(status_code=404, detail=f"SKU {sku} not found")
    return {
        "data": {"sku": sku, "price": price},
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
