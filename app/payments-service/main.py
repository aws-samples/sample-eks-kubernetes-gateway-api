"""Payments Service — processes payment for cart items.

Runs in EKS, accessed via VPC Lattice.
"""

import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from pydantic import BaseModel

app = FastAPI(title="Payments Service")


class PaymentRequest(BaseModel):
    items: list[dict]
    total: float


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
