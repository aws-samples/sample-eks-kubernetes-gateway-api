import { useState } from "react";
import type { Product, LatticeHeaders } from "../types";
import HeadersModal from "./HeadersModal";

interface Props {
  products: Product[];
  catalogHeaders: LatticeHeaders | null;
  pricingHeaders: LatticeHeaders | null;
  onAddToCart: (product: Product) => void;
  adding: string | null;
}

export default function ProductGrid({ products, catalogHeaders, pricingHeaders, onAddToCart, adding }: Props) {
  const [showHeaders, setShowHeaders] = useState<"catalog" | "pricing" | null>(null);
  return (
    <>
      <div className="grid grid-cols-2 gap-2 flex-1 auto-rows-fr min-h-0">
        {products.map((p) => (
          <div key={p.sku} className="rounded-lg border border-slate-700 bg-slate-900/60 px-3 py-1.5 flex flex-col justify-center overflow-hidden gap-0.5">
            <div className="flex items-center gap-1.5">
              <span>🦄</span>
              <span className="text-sm font-semibold text-slate-200 truncate">{p.name}</span>
            </div>
            <p className="text-[10px] text-slate-500 truncate">{p.description}</p>
            <div className="flex items-center justify-between">
              <span className="text-sm font-bold text-emerald-400">{p.price != null ? `$${p.price.toFixed(2)}` : "—"}</span>
              <button onClick={() => onAddToCart(p)} disabled={adding === p.sku || p.price == null}
                className="px-3 py-0.5 rounded bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 text-xs font-medium transition-colors">
                {adding === p.sku ? "..." : "Add"}
              </button>
            </div>
          </div>
        ))}
      </div>
      <div className="shrink-0 mt-2 flex gap-2">
        {catalogHeaders && Object.keys(catalogHeaders).length > 0 && (
          <button onClick={() => setShowHeaders("catalog")}
            className="flex-1 py-1.5 rounded border border-purple-500/30 text-xs text-purple-300 hover:bg-purple-500/10 transition-colors">
            Catalog VPC Lattice headers
          </button>
        )}
        {pricingHeaders && Object.keys(pricingHeaders).length > 0 && (
          <button onClick={() => setShowHeaders("pricing")}
            className="flex-1 py-1.5 rounded border border-blue-500/30 text-xs text-blue-300 hover:bg-blue-500/10 transition-colors">
            Pricing VPC Lattice headers
          </button>
        )}
      </div>
      {showHeaders === "catalog" && catalogHeaders && (
        <HeadersModal headers={catalogHeaders} onClose={() => setShowHeaders(null)} title="Catalog VPC Lattice headers — BFF → Items VPC Lattice service" />
      )}
      {showHeaders === "pricing" && pricingHeaders && (
        <HeadersModal headers={pricingHeaders} onClose={() => setShowHeaders(null)} title="Pricing VPC Lattice headers — BFF → Items VPC Lattice service" />
      )}
    </>
  );
}
