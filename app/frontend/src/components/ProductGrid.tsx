import { useState } from "react";
import type { Product, LatticeHeaders } from "../types";
import HeadersModal from "./HeadersModal";

interface Props {
  products: Product[];
  latticeHeaders: LatticeHeaders | null;
  onAddToCart: (product: Product) => void;
  adding: string | null;
}

export default function ProductGrid({ products, latticeHeaders, onAddToCart, adding }: Props) {
  const [showHeaders, setShowHeaders] = useState(false);
  return (
    <>
      <div className="grid grid-cols-2 gap-2 flex-1 auto-rows-fr min-h-0">
        {products.map((p) => (
          <div key={p.sku} className="rounded-lg border border-slate-700 bg-slate-900/60 px-3 py-1.5 flex flex-col justify-center overflow-hidden gap-0.5">
            <div className="flex items-center gap-1.5">
              <span>🦄</span>
              <span className="text-sm font-semibold text-slate-200 truncate">{p.name}</span>
            </div>
            <div className="flex items-center justify-between">
              <span className="text-sm font-bold text-emerald-400">${p.price.toFixed(2)}</span>
              <button onClick={() => onAddToCart(p)} disabled={adding === p.sku}
                className="px-3 py-0.5 rounded bg-emerald-600 hover:bg-emerald-500 disabled:bg-slate-700 text-xs font-medium transition-colors">
                {adding === p.sku ? "..." : "Add"}
              </button>
            </div>
          </div>
        ))}
      </div>
      {latticeHeaders && Object.keys(latticeHeaders.headers).length > 0 && (
        <button onClick={() => setShowHeaders(true)}
          className="shrink-0 mt-2 w-full py-1.5 rounded border border-purple-500/30 text-xs text-purple-300 hover:bg-purple-500/10 transition-colors">
          View VPC Lattice Headers
        </button>
      )}
      {showHeaders && latticeHeaders && (
        <HeadersModal headers={latticeHeaders.headers} onClose={() => setShowHeaders(false)} />
      )}
    </>
  );
}
