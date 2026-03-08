"""Catalog Service — serves product catalog data (no prices).

Runs in EKS on Backend-A, accessed via VPC Lattice.
Prices are served by the separate Pricing service; the BFF merges both.
"""

import logging
from datetime import datetime, timezone

from fastapi import FastAPI, Request

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

app = FastAPI(title="Catalog Service")

CATALOG = [
    {"sku": "UNI-001", "name": "Rainbow Sparkle", "description": "A dazzling unicorn that leaves rainbow trails wherever it goes."},
    {"sku": "UNI-002", "name": "Midnight Star", "description": "A mysterious dark unicorn with a constellation-patterned coat."},
    {"sku": "UNI-003", "name": "Golden Blaze", "description": "A majestic golden unicorn with a fiery mane."},
    {"sku": "UNI-004", "name": "Crystal Frost", "description": "An ice-blue unicorn that sparkles like fresh snow."},
    {"sku": "UNI-005", "name": "Thunder Hoof", "description": "A powerful storm unicorn with crackling energy."},
    {"sku": "UNI-006", "name": "Velvet Dream", "description": "A gentle lavender unicorn with the softest coat."},
    {"sku": "UNI-007", "name": "Solar Flare", "description": "A radiant unicorn that glows with solar energy."},
    {"sku": "UNI-008", "name": "Mystic Shadow", "description": "A sleek charcoal unicorn that moves like smoke."},
    {"sku": "UNI-009", "name": "Pearl Whisper", "description": "A serene white unicorn with an iridescent horn."},
    {"sku": "UNI-010", "name": "Ember Wing", "description": "A fiery red unicorn with wing-shaped flame patterns."},
]


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/catalog")
async def get_catalog(request: Request):
    return {
        "data": {"products": CATALOG},
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
