"""Payments Service — processes payment for cart items.

Runs in EKS on the Edge cluster, published as a VPC Lattice service.
Called by the Cart service (Backend-B) during checkout via VPC Lattice with SigV4.

IMPORTANT — Sample simplification:
  Payment processing is simulated — no real payment gateway is called.
  The service generates a random transaction ID and always returns "completed".
"""

import logging
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from pydantic import BaseModel, field_validator

logger = logging.getLogger(__name__)
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")

app = FastAPI(title="Payments Service")


class PaymentRequest(BaseModel):
    items: list[dict]
    total: float

    @field_validator("items")
    @classmethod
    def items_must_not_be_empty(cls, v: list) -> list:
        if not v:
            raise ValueError("items must not be empty")
        return v

    @field_validator("total")
    @classmethod
    def total_must_be_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("total must be greater than zero")
        return round(v, 2)


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/payments")
async def process_payment(payment: PaymentRequest, request: Request):
    return {
        "data": {
            "transaction_id": f"txn-{uuid.uuid4().hex[:12]}",
            "status": "completed",
            "amount": payment.total,
            "currency": "USD",
            "items_count": len(payment.items),
        },
        "lattice_headers": dict(request.headers),
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
