from pydantic import BaseModel


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
