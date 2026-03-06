# Application Services

This document describes the five application services, the BFF pattern, SigV4 request signing, and the end-to-end data flow.

## Service Overview

| Service | Cluster | Framework | Port | Code | Purpose |
|---------|---------|-----------|------|------|---------|
| Frontend | Frontend | [React](https://react.dev) + [Vite](https://vitejs.dev) + [Tailwind](https://tailwindcss.com) | 8080 (nginx, internal) / 80 (Service) | `app/frontend/` | Product catalog UI, cart, architecture diagram |
| BFF | Frontend | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/bff/` | Orchestrates backend calls with SigV4 signing |
| Cart | Backend-A | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/cart-service/` | In-memory shopping cart |
| Inventory | Backend-A | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/inventory-service/` | Static product catalog (10 unicorn products) |
| Payments | Backend-B | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/payments-service/` | Payment processing (returns transaction IDs) |

## Frontend (`app/frontend/`)

The frontend is a [React](https://react.dev) single-page app built with [Vite](https://vitejs.dev) and styled with [Tailwind CSS](https://tailwindcss.com). It uses [Framer Motion](https://www.framer.com/motion/) for animations.

Key features:
- **Product grid**: Displays the inventory catalog with add-to-cart functionality
- **Cart view**: Shows cart contents with checkout
- **Architecture diagram**: Live SVG visualization showing service connectivity status (green/red indicators)
- **Health polling**: Calls `/api/health` every 5 seconds to update the architecture diagram
- **VPC Lattice headers**: Each API response includes the raw Lattice headers, viewable in a modal

The frontend is served by [nginx](https://nginx.org), which also reverse-proxies `/api/*` requests to the BFF service on port 8000.

## BFF (`app/bff/`)

The BFF is the central orchestration layer. It sits in the frontend cluster and handles all communication with the backend services.

### Why a BFF?

The backend services are behind [Amazon VPC Lattice](https://aws.amazon.com/vpc/lattice/) with IAM authentication. Browser requests can't sign with SigV4, so the BFF acts as a trusted intermediary that:

1. Receives plain HTTP requests from the frontend
2. Signs them with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html) using [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) credentials
3. Forwards them to VPC Lattice services
4. Returns the response (including VPC Lattice headers for debugging)

### SigV4 Request Signing

Every outbound request is signed using [botocore](https://botocore.amazonaws.com/v1/documentation/api/latest/index.html)'s `SigV4Auth` with the service name `vpc-lattice-svcs`:

```python
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.session import Session as BotocoreSession

credentials = BotocoreSession().get_credentials()
request = AWSRequest(method="GET", url=url, headers=headers)
SigV4Auth(credentials, "vpc-lattice-svcs", region).add_auth(request)
```

The BFF pod gets credentials automatically via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html). The `bff-service-account` is associated with an IAM role that has `vpc-lattice-svcs:Invoke` permission.

### HTTP Client Lifecycle

The BFF uses a single shared [httpx.AsyncClient](https://www.python-httpx.org/async/) for all outbound requests, created at application startup via FastAPI's [lifespan](https://fastapi.tiangolo.com/advanced/events/) context manager:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    global _http_client, _health_client
    _http_client = httpx.AsyncClient(timeout=REQUEST_TIMEOUT)
    _health_client = httpx.AsyncClient(timeout=HEALTH_TIMEOUT)
    yield
    await _http_client.aclose()
    await _health_client.aclose()
```

Creating the client once at startup allows httpx to maintain a connection pool. Subsequent requests to the same VPC Lattice host reuse existing TCP connections (HTTP keep-alive), eliminating the overhead of a new TCP handshake (and TLS handshake in HTTPS mode) on every API call. A separate `_health_client` is used for health checks since it has a shorter timeout (`HEALTH_TIMEOUT=3s`) than regular requests (`REQUEST_TIMEOUT=10s`).

### Request Validation

The BFF validates incoming request bodies before signing and forwarding them to backend services. `AddToCartRequest` and `PaymentRequest` Pydantic models are defined in `app/bff/models.py` and mirror the backend service models:

```python
class AddToCartRequest(BaseModel):
    sku: str
    name: str
    price: float

    @field_validator("price")
    def price_must_be_positive(cls, v): ...

class PaymentRequest(BaseModel):
    items: list[dict]
    total: float

    @field_validator("total")
    def total_must_be_positive(cls, v): ...
```

This means malformed or invalid payloads are rejected at the BFF boundary with a 422 response before any SigV4 signing or network call occurs.

### Routing to Backend Services

The BFF uses two environment variables for service discovery:

- `ITEMS_SERVICE_URL` points to `https://items.<private-zone>` (Cart + Inventory)
- `PAYMENTS_SERVICE_URL` points to `https://payments.<private-zone>` (Payments)

For the shared items service, the BFF adds an `x-service` header to differentiate between cart and inventory:

```python
# Cart request
headers = sign_request("GET", items_url + "/cart", {"x-service": "cart"})

# Inventory request
headers = sign_request("GET", items_url + "/inventory", {"x-service": "inventory"})
```

The VPC Lattice [HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/) on Backend-A matches this header and routes to the correct Kubernetes service.

### API Endpoints

| Endpoint | Method | Backend | Description |
|----------|--------|---------|-------------|
| `/api/health` | GET | All three | Concurrent health checks, returns reachability status |
| `/api/inventory` | GET | Inventory | Returns product catalog |
| `/api/cart` | GET | Cart | Returns cart contents |
| `/api/cart` | POST | Cart | Adds item to cart |
| `/api/cart` | DELETE | Cart | Clears the cart |
| `/api/payments` | POST | Payments | Processes payment for cart items |

Every response wraps the backend data in a `BFFResponse` that includes `data`, `lattice_headers`, and `timestamp`.

## Cart Service (`app/cart-service/`)

A minimal in-memory shopping cart. Stores items in a Python list (single global cart, no sessions, kept simple for this example). Endpoints:

- `GET /cart`: Returns items, total, and count
- `POST /cart`: Adds an item (sku, name, price)
- `DELETE /cart`: Clears all items
- `GET /health`: Returns `{"status": "ok"}`

Every response includes `lattice_headers: dict(request.headers)` so the frontend can display the VPC Lattice metadata that arrived with the request.

## Inventory Service (`app/inventory-service/`)

Serves a static catalog of 10 unicorn products (Rainbow Sparkle, Midnight Star, Golden Blaze, etc.) with SKU, name, price, and stock. Endpoints:

- `GET /inventory`: Returns the full product list
- `GET /health`: Returns `{"status": "ok"}`

## Payments Service (`app/payments-service/`)

Processes payment requests. Generates a UUID-based transaction ID and returns a confirmation. Endpoints:

- `POST /payments`: Accepts `{items, total}`, returns transaction details
- `GET /health`: Returns `{"status": "ok"}`

## End-to-end data flow

Here's what happens when a user clicks "Add to Cart" on the frontend:

```
Browser
  → POST /api/cart {sku, name, price}
    → nginx reverse proxy
      → BFF (port 8000)
        → SigV4 sign request with x-service: cart header
          → HTTPS to items.<domain>/cart (VPC Lattice)
            → VPC Lattice service network
              → HTTPRoute header match: x-service=cart
                → cart-service pod (Backend-A cluster)
                  → Adds item to in-memory list
                ← Returns {status: "added", count: N}
              ← VPC Lattice adds response headers
            ← HTTPS response
          ← BFF wraps in BFFResponse
        ← JSON to browser
      ← UI updates cart count
```

The health check flow is similar but concurrent. The BFF fires three async requests (cart, inventory, payments) in parallel using [asyncio.gather](https://docs.python.org/3/library/asyncio-task.html#asyncio.gather) and returns the combined status.

## Why this architecture?

- **BFF pattern**: Isolates the SigV4 signing complexity from the frontend. The React app makes simple fetch calls; the BFF handles AWS auth.
- **Shared items service**: Demonstrates header-based routing in VPC Lattice with one VPC Lattice service, two backends, and reduced cost.
- **Separate payments service**: Shows the standard one-service-per-Lattice-service pattern for comparison.
- **VPC Lattice headers in responses**: Make the example educational so you can see the actual VPC Lattice metadata (source VPC, identity, etc.) flowing through the system.
