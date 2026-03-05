import { motion } from "framer-motion";
import type { ServiceResponse } from "../types";

interface Props {
  title: string;
  data: ServiceResponse;
  color: "emerald" | "blue" | "purple";
}

const borderColors = {
  emerald: "border-emerald-500/30",
  blue: "border-blue-500/30",
  purple: "border-purple-500/30",
};

export default function ServicePanel({ title, data, color }: Props) {
  return (
    <motion.div
      initial={{ opacity: 0, y: 10 }}
      animate={{ opacity: 1, y: 0 }}
      className={`rounded-lg border ${borderColors[color]} bg-slate-900/60 p-4 space-y-3`}
    >
      <h3 className="text-sm font-semibold text-slate-300">{title}</h3>

      {/* Response data */}
      <pre className="text-xs text-slate-400 bg-slate-950/50 rounded p-3 overflow-x-auto">
        {JSON.stringify(data.data, null, 2)}
      </pre>

      {/* Lattice headers */}
      {data.lattice_headers?.headers && Object.keys(data.lattice_headers.headers).length > 0 && (
        <details className="text-xs">
          <summary className="text-slate-500 cursor-pointer hover:text-slate-400">
            VPC Lattice Headers
          </summary>
          <pre className="mt-2 text-slate-500 bg-slate-950/50 rounded p-2 overflow-x-auto">
            {JSON.stringify(data.lattice_headers.headers, null, 2)}
          </pre>
        </details>
      )}

      <p className="text-xs text-slate-600">{data.timestamp}</p>
    </motion.div>
  );
}
