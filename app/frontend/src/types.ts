export type LatticeHeaders = Record<string, string>;

export interface DownstreamLatticeHeaders {
  payments?: LatticeHeaders;
}
export interface Product {
  sku: string;
  name: string;
  description: string;
  price?: number;
}

export interface CatalogProduct {
  sku: string;
  name: string;
  description: string;
}

export interface PriceEntry {
  sku: string;
  price: number;
}

export interface CartItem {
  sku: string;
  name: string;
  price: number;
}

export interface CatalogResponse {
  data: { products: CatalogProduct[] };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface PricingResponse {
  data: { prices: PriceEntry[] };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface CartResponse {
  data: { items: CartItem[]; total: number; count: number };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface CheckoutResponse {
  data: {
    transaction_id: string;
    status: string;
    amount: number;
    currency: string;
    items_count: number;
  };
  lattice_headers: LatticeHeaders;
  downstream_lattice_headers?: DownstreamLatticeHeaders;
  timestamp: string;
}

export interface HealthResponse {
  catalog_service: "reachable" | "unreachable";
  pricing_service: "reachable" | "unreachable";
  cart_service: "reachable" | "unreachable";
  payments_service: "reachable" | "unreachable";
}
