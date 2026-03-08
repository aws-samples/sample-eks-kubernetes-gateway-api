# Application Services

This document describes the six application services, the BFF pattern, SigV4 request signing, and the end to end data flow.

## Service Overview

| Service | Cluster | Framework | Port | Code | Purpose |
|---------|---------|-----------|------|------|---------|
| Frontend | Edge | [React](https://react.dev) + [Vite](https://vitejs.dev) + [Tailwind](https://tailwindcss.com) | 8080 (nginx, internal) / 80 (Service) | `app/frontend/` | Product catalog UI, cart, architecture diagram |
| BFF | Edge | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/bff/` | Orchestrates backend calls with SigV4 signing |
| Catalog | Backend A | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/catalog/` | Static product catalog (10 unicorn products) |
| Pricing | Backend A | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/pricing/` | Product pricing data |
| Cart | Backend B | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/cart/` | In memory shopping cart with checkout; calls Payments via VPC Lattice |
| Payments | Edge | [FastAPI](https://fastapi.tiangolo.com) (Python) | 8000 | `app/payments/` | Payment processing (returns transaction IDs) |

## Frontend (`app/frontend/`)

The frontend is a [React](https://react.dev) single page app built with [Vite](https://vitejs.dev) and styled with [Tailwind CSS](https://tailwindcss.com). It uses [Framer Motion](https://www.framer.com/motion/) for animations.

Key features:
- **Product grid**: Merges catalog and pricing data to display products with prices and add to cart functionality
- **Cart view**: Shows cart contents with checkout
- **Payment confirmation**: After checkout, displays a confirmation showing two hop VPC Lattice headers (cart as hop 1, payments as hop 2)
- **Architecture diagram**: Live SVG visualization showing VPC Lattice infrastructure, conditionally rendered based on health check status (green/red indicators)
- **Health polling**: Calls `/api/health` every 5 seconds to update the architecture diagram

The frontend is served by [nginx](https://nginx.org), which also reverse proxies `/api/*` requests to the BFF service on port 8000.

## BFF (`app/bff/`)

The BFF is the central orchestration layer. It sits in the edge cluster and handles all communication with the backend services.

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

SigV4 signing requires `x-amz-content-sha256: UNSIGNED-PAYLOAD` and `payload_signing_enabled = False` for VPC Lattice requests.

The BFF pod gets credentials automatically via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html). The `bff-service-account` is associated with an IAM role that has `vpc-lattice-svcs:Invoke` permission.

### HTTP Client Lifecycle

The BFF uses a single shared [httpx.AsyncClient](https://www.python-httpx.org/async/) for all outbound requests (both API calls and health checks), created at application startup via FastAPI's [lifespan](https://fastapi.tiangolo.com/advanced/events/) context manager.

Creating the client once at startup allows httpx to maintain a connection pool. Subsequent requests to the same VPC Lattice host reuse existing TCP connections (HTTP keep alive), eliminating the overhead of a new TCP handshake (and TLS handshake in HTTPS mode) on every API call. Connection pooling keeps warm TLS connections to VPC Lattice services.

Health checks use a per request timeout of 5 seconds. There is no separate health client; the same shared client handles both API calls and health checks.

### Routing to Backend Services

The BFF uses three environment variables for service discovery:

- `ITEMS_SERVICE_URL` points to `https://items.<private-zone>` (Catalog + Pricing via header based routing)
- `CART_SERVICE_URL` points to `https://cart.<private-zone>` (Cart)
- `PAYMENTS_SERVICE_URL` points to `https://payments.<private-zone>` (Payments)

For the shared items service, the BFF adds an `x-service` header to differentiate between catalog and pricing:

```python
# Catalog request
headers = sign_request("GET", items_url + "/catalog", {"x-service": "catalog"})

# Pricing request
headers = sign_request("GET", items_url + "/pricing", {"x-service": "pricing"})
```

The VPC Lattice [HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/) on Backend A matches this header and routes to the correct Kubernetes service.

### API Endpoints

| Endpoint | Method | Backend | Description |
|----------|--------|---------|-------------|
| `/api/health` | GET | All four services | Concurrent health checks against catalog, pricing, cart, and payments; returns reachability status |
| `/api/catalog` | GET | Catalog (Backend A) | Returns product catalog |
| `/api/pricing` | GET | Pricing (Backend A) | Returns product pricing |
| `/api/cart` | GET | Cart (Backend B) | Returns cart contents |
| `/api/cart` | POST | Cart (Backend B) | Adds item to cart |
| `/api/cart` | DELETE | Cart (Backend B) | Clears the cart |
| `/api/cart/checkout` | POST | Cart (Backend B) | Initiates checkout; Cart calls Payments via VPC Lattice |

Every response wraps the backend data in a `BFFResponse` that includes `data`, `lattice_headers`, and `timestamp`.



## Catalog Service (`app/catalog/`)

Serves a static catalog of 10 unicorn products (Rainbow Sparkle, Midnight Star, Golden Blaze, etc.) with SKU, name, and stock information. Endpoints:

- `GET /catalog`: Returns the full product list
- `GET /health`: Returns `{"status": "ok"}`

## Pricing Service (`app/pricing/`)

Serves pricing data for the product catalog. Endpoints:

- `GET /pricing`: Returns prices keyed by SKU
- `GET /health`: Returns `{"status": "ok"}`

## Cart Service (`app/cart/`)

An in memory shopping cart with checkout capability. Stores items in a Python list (single global cart, no sessions, kept simple for this example).

The Cart service is unique in this architecture because it is both a VPC Lattice service (serving requests from the BFF) and a VPC Lattice consumer (calling Payments during checkout). The Backend B VPC is associated with the service network to enable this.

### Checkout and SigV4 signing

When the BFF calls the cart checkout endpoint, the Cart service initiates a payment by calling the Payments service directly via VPC Lattice. The Cart pod signs these requests using its own EKS Pod Identity credentials with the same botocore `SigV4Auth` approach used by the BFF:

```python
credentials = BotocoreSession().get_credentials()
request = AWSRequest(method="POST", url=payments_url, data=payload, headers=headers)
SigV4Auth(credentials, "vpc-lattice-svcs", region).add_auth(request)
```

The `cart-service-account` is associated with an IAM role that has `vpc-lattice-svcs:Invoke` permission.

### Endpoints

- `GET /cart`: Returns items, total, and count
- `POST /cart`: Adds an item (sku, name, price)
- `DELETE /cart`: Clears all items
- `POST /cart/checkout`: Initiates checkout, calls Payments via VPC Lattice, returns payment confirmation
- `GET /health`: Returns `{"status": "ok"}`

Every response includes `lattice_headers: dict(request.headers)` so the frontend can display the VPC Lattice metadata that arrived with the request.

## Payments Service (`app/payments/`)

Processes payment requests. Runs on the edge cluster and is published as a VPC Lattice service. Generates a UUID based transaction ID and returns a confirmation. Endpoints:

- `POST /payments`: Accepts `{items, total}`, returns transaction details
- `GET /health`: Returns `{"status": "ok"}`

## End to end data flow

### Browse flow

When a user loads the product page:

```
Browser
  → GET /api/catalog + GET /api/pricing
    → nginx reverse proxy
      → BFF (port 8000)
        → SigV4 sign with x-service: catalog header
          → HTTPS to items.<domain>/catalog (VPC Lattice)
            → Backend A: Catalog pod
        → SigV4 sign with x-service: pricing header
          → HTTPS to items.<domain>/pricing (VPC Lattice)
            → Backend A: Pricing pod
      ← BFF merges responses
    ← JSON to browser
  ← Frontend renders product grid with prices
```

### Add to cart flow

When a user clicks "Add to Cart":

```
Browser
  → POST /api/cart {sku, name, price}
    → nginx reverse proxy
      → BFF (port 8000)
        → SigV4 sign request
          → HTTPS to cart.<domain>/cart (VPC Lattice)
            → Backend B: Cart pod
              → Adds item to in memory list
            ← Returns {status: "added", count: N}
          ← VPC Lattice adds response headers
        ← BFF wraps in BFFResponse
      ← JSON to browser
    ← UI updates cart count
```

### Checkout flow (two hop)

When a user clicks "Checkout," the request chains through two VPC Lattice hops:

```
Browser
  → POST /api/cart/checkout
    → nginx reverse proxy
      → BFF (port 8000)
        → SigV4 sign request (BFF credentials)
          → HTTPS to cart.<domain>/cart/checkout (VPC Lattice, hop 1)
            → Backend B: Cart pod
              → SigV4 sign request (Cart credentials)
                → HTTPS to payments.<domain>/payments (VPC Lattice, hop 2)
                  → Edge: Payments pod
                    → Generates transaction ID
                  ← Returns payment confirmation
                ← Cart receives payment result
              ← Returns checkout result with payment details
            ← VPC Lattice adds response headers (hop 1)
          ← BFF wraps in BFFResponse
        ← JSON to browser
      ← Frontend shows payment confirmation with both hop headers
```

### Health check flow

The BFF polls all four services (catalog, pricing, cart, and payments) every 5 seconds using concurrent async requests via [asyncio.gather](https://docs.python.org/3/library/asyncio-task.html#asyncio.gather). Health checks use the shared httpx client with a per request timeout of 5 seconds. The combined status drives the live architecture diagram on the frontend.

## Why this architecture?

- **BFF pattern**: Isolates the SigV4 signing complexity from the frontend. The React app makes simple fetch calls; the BFF handles AWS auth.
- **Shared items service**: Demonstrates header based routing in VPC Lattice with one VPC Lattice service, two backends (catalog and pricing), and reduced cost.
- **Two hop checkout**: Shows service to service communication over VPC Lattice, where Cart (Backend B) calls Payments (Edge) with its own SigV4 credentials.
- **Payments on Edge**: Demonstrates that a single cluster can both consume and publish VPC Lattice services.
- **VPC Lattice headers in responses**: Make the example educational so you can see the actual VPC Lattice metadata (source VPC, identity, etc.) flowing through the system.
