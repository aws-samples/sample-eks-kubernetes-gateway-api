export interface LatticeHeaders {
  headers: Record<string, string>;
}

export interface Product {
  sku: string;
  name: string;
  price: number;
  stock: number;
}

export interface CartItem {
  sku: string;
  name: string;
  price: number;
}

export interface InventoryResponse {
  data: { products: Product[] };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface CartResponse {
  data: { items: CartItem[]; total: number; count: number };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface PaymentConfirmation {
  data: {
    transaction_id: string;
    status: string;
    amount: number;
    currency: string;
    items_count: number;
  };
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface ServiceResponse {
  data: Record<string, unknown>;
  lattice_headers: LatticeHeaders;
  timestamp: string;
}

export interface HealthResponse {
  cart_service: "reachable" | "unreachable";
  payments_service: "reachable" | "unreachable";
  inventory_service: "reachable" | "unreachable";
}
