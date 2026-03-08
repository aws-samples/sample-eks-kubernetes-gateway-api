from pydantic import BaseModel, field_validator


class LatticeHeaders(BaseModel):
    headers: dict = {}


class DownstreamLatticeHeaders(BaseModel):
    payments: LatticeHeaders | None = None


class BFFResponse(BaseModel):
    data: dict
    lattice_headers: LatticeHeaders
    timestamp: str


class CheckoutResponse(BaseModel):
    data: dict
    lattice_headers: LatticeHeaders
    downstream_lattice_headers: DownstreamLatticeHeaders | None = None
    timestamp: str


class HealthStatus(BaseModel):
    catalog_service: str
    pricing_service: str
    cart_service: str
    payments_service: str


# ── Request models for BFF proxy endpoints ───────────────────────────────────

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
