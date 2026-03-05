import { motion } from "framer-motion";

interface Props {
  headers: Record<string, string>;
  onClose: () => void;
}

function parseSubValues(value: string): { key: string; val: string }[] | null {
  if (!value.includes("=") || !value.includes(";")) return null;
  const parts = value.split(";").map(s => s.trim()).filter(Boolean);
  const parsed = parts.map(part => {
    const idx = part.indexOf("=");
    if (idx === -1) return null;
    return { key: part.slice(0, idx), val: part.slice(idx + 1) };
  });
  if (parsed.some(p => p === null)) return null;
  return parsed as { key: string; val: string }[];
}

export default function HeadersModal({ headers, onClose }: Props) {
  const entries = Object.entries(headers);
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm" onClick={onClose}>
      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        exit={{ opacity: 0, scale: 0.95 }}
        className="bg-slate-900 border border-slate-700 rounded-xl shadow-2xl w-[620px] max-h-[85vh] flex flex-col"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center justify-between px-5 py-3 border-b border-slate-700">
          <h3 className="text-sm font-semibold text-purple-300">VPC Lattice Headers</h3>
          <button onClick={onClose} className="text-slate-500 hover:text-slate-300 text-lg leading-none">&times;</button>
        </div>
        <div className="overflow-y-auto p-4">
          <table className="w-full text-xs">
            <thead>
              <tr className="border-b border-slate-700">
                <th className="text-left py-2 pr-4 text-slate-400 font-medium w-[180px]">Header</th>
                <th className="text-left py-2 text-slate-400 font-medium">Value</th>
              </tr>
            </thead>
            <tbody>
              {entries.map(([key, value]) => {
                const sub = parseSubValues(value);
                return (
                  <tr key={key} className="border-b border-slate-800 align-top">
                    <td className="py-2 pr-4 text-purple-300 font-mono whitespace-nowrap">{key}</td>
                    <td className="py-2">
                      {sub ? (
                        <table className="w-full">
                          <tbody>
                            {sub.map((s, i) => (
                              <tr key={i} className={i < sub.length - 1 ? "border-b border-slate-800/50" : ""}>
                                <td className="py-0.5 pr-2 text-slate-400 font-mono whitespace-nowrap text-[10px]">{s.key}</td>
                                <td className="py-0.5 text-slate-300 font-mono break-all text-[10px]">{s.val}</td>
                              </tr>
                            ))}
                          </tbody>
                        </table>
                      ) : (
                        <span className="text-slate-300 font-mono break-all">{value}</span>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      </motion.div>
    </div>
  );
}
