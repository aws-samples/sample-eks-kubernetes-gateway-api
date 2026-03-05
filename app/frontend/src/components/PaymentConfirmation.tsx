import { useState } from "react";
import type { PaymentConfirmation as PaymentData } from "../types";
import HeadersModal from "./HeadersModal";

interface Props {
  payment: PaymentData;
  onBackToShop: () => void;
}

export default function PaymentConfirmationView({ payment, onBackToShop }: Props) {
  const [showHeaders, setShowHeaders] = useState(false);
  const d = payment.data;

  return (
    <>
      <div className="flex flex-col items-center justify-center flex-1 gap-4">
        <div className="text-5xl">✅</div>
        <h2 className="text-xl font-bold text-white">Payment Successful</h2>

        <div className="w-full max-w-sm rounded-lg border border-slate-700 bg-slate-900/60 p-4 space-y-3">
          <div className="flex justify-between text-sm">
            <span className="text-slate-400">Transaction ID</span>
            <span className="text-slate-200 font-mono text-xs">{d.transaction_id}</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-slate-400">Status</span>
            <span className="text-emerald-400 font-semibold capitalize">{d.status}</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-slate-400">Items</span>
            <span className="text-slate-200">{d.items_count}</span>
          </div>
          <div className="flex justify-between text-sm border-t border-slate-700 pt-2">
            <span className="text-slate-300 font-semibold">Amount Charged</span>
            <span className="text-lg font-bold text-white">${d.amount.toFixed(2)} {d.currency}</span>
          </div>
        </div>

        <button onClick={onBackToShop}
          className="px-6 py-2 rounded-lg bg-emerald-600 hover:bg-emerald-500 text-sm font-medium transition-colors">
          🦄 Back to Shop
        </button>

        {payment.lattice_headers && Object.keys(payment.lattice_headers.headers).length > 0 && (
          <button onClick={() => setShowHeaders(true)}
            className="py-1.5 px-4 rounded border border-purple-500/30 text-xs text-purple-300 hover:bg-purple-500/10 transition-colors">
            View VPC Lattice Headers
          </button>
        )}
      </div>

      {showHeaders && payment.lattice_headers && (
        <HeadersModal headers={payment.lattice_headers.headers} onClose={() => setShowHeaders(false)} />
      )}
    </>
  );
}
