import type { CatalogResponse, PricingResponse, CartResponse, CheckoutResponse, HealthResponse } from "./types";

export class ApiError extends Error {
  constructor(message: string, public status: number) {
    super(message);
    this.name = "ApiError";
  }
}

async function fetchJSON<T>(path: string, init?: RequestInit): Promise<T> {
  const resp = await fetch(path, init);
  if (!resp.ok) {
    const body = await resp.json().catch(() => ({}));
    throw new ApiError(body.error ?? `Request failed (${resp.status})`, resp.status);
  }
  return resp.json();
}

export const fetchCatalog = () => fetchJSON<CatalogResponse>("/api/catalog");
export const fetchPricing = () => fetchJSON<PricingResponse>("/api/pricing");
export const fetchCart = () => fetchJSON<CartResponse>("/api/cart");
export const fetchHealth = () => fetchJSON<HealthResponse>("/api/health");

export function addToCart(sku: string, name: string, price: number) {
  return fetchJSON<{ status: string; count: number }>("/api/cart", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ sku, name, price }),
  });
}

export function clearCart() {
  return fetchJSON<{ status: string; count: number }>("/api/cart", { method: "DELETE" });
}

export function checkout() {
  return fetchJSON<CheckoutResponse>("/api/checkout", { method: "POST" });
}
