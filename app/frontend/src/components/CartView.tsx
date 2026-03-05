import { useState } from "react";
import type { CartItem, LatticeHeaders } from "../types";
import HeadersModal from "./HeadersModal";

interface Props {
  items: CartItem[];
  total: number;
  latticeHeaders: LatticeHeaders | null;
  onPay: () => void;
  onClear: () => void;
  paying: boolean;
}

export default function CartView({ items, total, latticeHeaders, onPay, onClear, paying }: Props) {
  const [showHeaders, setShowHeaders] = useState(false);

  if (items.length === 0) {
    return <p className="text-sm text-slate-500">Your cart is empty.</p>;
  }

  return (
    <>
      <div className="flex flex-col gap-2 flex-1 min-h-0">
        <div className="space-y-2 overflow-y-auto flex-1 min-h-0">
          {items.map((item, i) => (
            <div key={`${item.sku}-${i}`} className="flex items-center justify-between rounded border border-slate-700 bg-slate-900/60 px-3 py-2">
              <div className="flex items-center gap-2">
                <span>🦄</span>
                <div>
                  <p className="text-sm text-slate-200">{item.name}</p>
                  <p className="text-[10px] text-slate-500">{item.sku}</p>
                </div>
              </div>
              <span className="text-sm font-semibold text-emerald-400">${item.price.toFixed(2)}</span>
            </div>
          ))}
        </div>

        <div className="shrink-0 flex items-center justify-between border-t border-slate-700 pt-2">
          <span className="text-sm text-slate-300">Total ({items.length} items)</span>
          <span className="text-lg font-bold text-white">${total.toFixed(2)}</span>
        </div>

        <div className="shrink-0 flex gap-2">
          <button onClick={onPay} disabled={paying}
            className="flex-1 px-4 py-2 rounded-lg bg-blue-600 hover:bg-blue-500 disabled:bg-slate-700 text-sm font-medium transition-colors">
            {paying ? "Processing..." : "💳 Pay Now"}
          </button>
          <button onClick={onClear}
            className="px-4 py-2 rounded-lg border border-slate-600 hover:bg-slate-800 text-sm text-slate-400 transition-colors">
            Clear
          </button>
        </div>

        {latticeHeaders && Object.keys(latticeHeaders.headers).length > 0 && (
          <button onClick={() => setShowHeaders(true)}
            className="shrink-0 w-full py-1.5 rounded border border-purple-500/30 text-xs text-purple-300 hover:bg-purple-500/10 transition-colors">
            View VPC Lattice Headers
          </button>
        )}
      </div>

      {showHeaders && latticeHeaders && (
        <HeadersModal headers={latticeHeaders.headers} onClose={() => setShowHeaders(false)} />
      )}
    </>
  );
}
