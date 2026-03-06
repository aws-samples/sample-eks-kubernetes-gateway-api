from pydantic import BaseModel, field_validator


class LatticeHeaders(BaseModel):
    headers: dict = {}


class BFFResponse(BaseModel):
    data: dict
    lattice_headers: LatticeHeaders
    timestamp: str


class HealthStatus(BaseModel):
    cart_service: str
    payments_service: str
    inventory_service: str


# ── Request models for BFF proxy endpoints ───────────────────────────────────
# These mirror the backend service models and validate incoming requests at the
# BFF boundary before they are signed with SigV4 and forwarded to VPC Lattice.

class AddToCartRequest(BaseModel):
    """Mirrors cart-service AddItemRequest."""
    sku: str
    name: str
    price: float

    @field_validator("price")
    @classmethod
    def price_must_be_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("price must be greater than zero")
        return round(v, 2)


class PaymentRequest(BaseModel):
    """Mirrors payments-service PaymentRequest."""
    items: list[dict]
    total: float

    @field_validator("total")
    @classmethod
    def total_must_be_positive(cls, v: float) -> float:
        if v <= 0:
            raise ValueError("total must be greater than zero")
        return round(v, 2)
