import { useState } from "react";
import { motion } from "framer-motion";
import { ALBIcon, EKSIcon, VPCLatticeIcon, VPCIcon, WAFIcon } from "./AwsIcons";

export interface ArchitectureDiagramProps {
  catalogReachable: boolean;
  pricingReachable: boolean;
  cartReachable: boolean;
  paymentsReachable: boolean;
  activeView: "shop" | "cart" | "confirmation";
}

const GREEN = "#22c55e";
const PURPLE = "#8C4FFF";

function ConnectionLine({ x1, y1, x2, y2, color, animated = false }: {
  x1: number; y1: number; x2: number; y2: number; color: string; animated?: boolean;
}) {
  const dx = x2 - x1, dy = y2 - y1;
  const path = `M${x1},${y1} C${x1+dx*0.1},${y1+dy*0.5} ${x2-dx*0.1},${y2-dy*0.5} ${x2},${y2}`;
  return (
    <g>
      <path d={path} fill="none" stroke={color} strokeWidth={4} opacity={0.15} filter="url(#glow)" />
      <motion.path d={path} fill="none" stroke={color} strokeWidth={2} strokeLinecap="round"
        animate={animated ? { strokeDashoffset: [0,-20], opacity: [0.6,1,0.6] } : { opacity: 0.8 }}
        transition={animated ? { strokeDashoffset: { duration: 0.6, repeat: Infinity, ease: "linear" }, opacity: { duration: 1.5, repeat: Infinity } } : {}}
        strokeDasharray={animated ? "8 12" : "none"} />
      {animated && <circle r={3.5} fill={color} filter="url(#glow)"><animateMotion dur="1.4s" repeatCount="indefinite" path={path} /></circle>}
    </g>
  );
}

function ServiceNode({ x, y, icon, label }: { x: number; y: number; icon: React.ReactNode; label: string }) {
  return (
    <g>
      <foreignObject x={x-14} y={y-14} width={28} height={28}><div className="flex items-center justify-center">{icon}</div></foreignObject>
      <rect x={x-label.length*3} y={y+14} width={label.length*6} height={12} rx={2} fill="#0f172a" fillOpacity={0.9} />
      <text x={x} y={y+23} textAnchor="middle" fill="#e2e8f0" fontSize={9} fontWeight={600}>{label}</text>
    </g>
  );
}

function AccountBox({ x, y, width, height, label, children }: {
  x: number; y: number; width: number; height: number; label: string; children: React.ReactNode;
}) {
  return (
    <g>
      <rect x={x} y={y} width={width} height={height} rx={5} fill="rgba(255,255,255,0.02)" stroke="#475569" strokeWidth={1} strokeDasharray="8 4" />
      <rect x={x+4} y={y-7} width={label.length*6+12} height={14} rx={3} fill="#1e293b" stroke="#475569" strokeWidth={1} />
      <text x={x+10} y={y+3} fill="#94a3b8" fontSize={8} fontWeight={600}>{label}</text>
      {children}
    </g>
  );
}

function VPCBox({ x, y, width, height, name, children }: {
  x: number; y: number; width: number; height: number; name: string; children: React.ReactNode;
}) {
  return (
    <g>
      <rect x={x} y={y} width={width} height={height} rx={5} fill="rgba(140,79,255,0.06)" stroke={PURPLE} strokeWidth={1.5} strokeDasharray="6 3" />
      <foreignObject x={x+3} y={y+2} width={16} height={16}><div className="flex items-center justify-center"><VPCIcon size={14} /></div></foreignObject>
      <text x={x+20} y={y+12} fill="#c4b5fd" fontSize={8} fontWeight={600}>{name}</text>
      {children}
    </g>
  );
}


export default function ArchitectureDiagram({ catalogReachable, pricingReachable, cartReachable, paymentsReachable, activeView }: ArchitectureDiagramProps) {
  const [centralized, setCentralized] = useState(true);
  const itemsUp = catalogReachable || pricingReachable;

  // Traffic flow lines — only one set at a time based on active view
  const showItemsFlow = activeView === "shop" && itemsUp;
  const showCartFlow = activeView === "cart" && cartReachable;
  const showCheckoutFlow = activeView === "confirmation" && cartReachable;

  const W = 660, H = 520, CX = W / 2;
  const ALB_Y = 36, EKS_Y = 88, LATTICE_Y = 240;
  const SVC_Y = 310, TG_Y = 360;
  const X_LEFT = 155, X_RIGHT = 510;

  return (
    <div className="flex flex-col h-full w-full">
      <div className="flex items-center justify-between mb-2 px-1">
        <h3 className="text-sm font-semibold text-slate-400 uppercase tracking-wider">Architecture</h3>
        <button onClick={() => setCentralized(p => !p)}
          className="flex items-center gap-1.5 rounded-full border border-slate-600 bg-slate-800 px-3 py-1 text-xs text-slate-300 hover:bg-slate-700 transition-colors">
          <span className={centralized ? "text-purple-400 font-semibold" : "text-slate-500"}>Centralized</span>
          <span className="text-slate-600">/</span>
          <span className={!centralized ? "text-purple-400 font-semibold" : "text-slate-500"}>Decentralized</span>
        </button>
      </div>
      <svg viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="xMidYMid meet" className="w-full flex-1 min-h-0">
        <defs><filter id="glow"><feGaussianBlur stdDeviation="3" result="blur" /><feMerge><feMergeNode in="blur" /><feMergeNode in="SourceGraphic" /></feMerge></filter></defs>

        {/* ── Edge Account ─────────────────────────────────────────── */}
        <AccountBox x={CX-190} y={8} width={380} height={centralized ? 185 : 250} label="AWS Account — Edge">
          <VPCBox x={CX-175} y={18} width={350} height={130} name="Edge VPC">
            <ServiceNode x={CX-50} y={ALB_Y} icon={<ALBIcon size={22} />} label="ALB" />
            <ServiceNode x={CX+50} y={ALB_Y} icon={<WAFIcon size={22} />} label="AWS WAF" />
            <line x1={CX-28} y1={ALB_Y} x2={CX+28} y2={ALB_Y} stroke="#94a3b8" strokeWidth={1} strokeDasharray="3 2" />
            <g>
              <rect x={CX-150} y={EKS_Y-14} width={300} height={62} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={CX-146} y={EKS_Y-12} width={16} height={16}><div className="flex items-center justify-center"><EKSIcon size={14} /></div></foreignObject>
              <rect x={CX-129} y={EKS_Y-8} width={80} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={CX-128} y={EKS_Y-1} fill="#fdba74" fontSize={7} fontWeight={600}>Edge EKS Cluster</text>
              {/* Shop app group — bigger to avoid label overlap */}
              <rect x={CX-140} y={EKS_Y+3} width={165} height={26} rx={3} fill="rgba(34,197,94,0.06)" stroke="#22c55e" strokeWidth={0.8} strokeDasharray="4 2" />
              <text x={CX-136} y={EKS_Y+10} fill="#86efac" fontSize={5} fontWeight={600}>Shop</text>
              <rect x={CX-132} y={EKS_Y+13} width={70} height={14} rx={2} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.7} />
              <text x={CX-97} y={EKS_Y+23} textAnchor="middle" fill="#e2e8f0" fontSize={7}>🖥 Frontend</text>
              <rect x={CX-52} y={EKS_Y+13} width={60} height={14} rx={2} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.7} />
              <text x={CX-22} y={EKS_Y+23} textAnchor="middle" fill="#e2e8f0" fontSize={7}>⚡ BFF</text>
              {/* Payments */}
              <rect x={CX+35} y={EKS_Y+4} width={100} height={24} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.8} />
              <text x={CX+85} y={EKS_Y+20} textAnchor="middle" fill="#e2e8f0" fontSize={7}>💳 Payments</text>
            </g>
          </VPCBox>
          {/* Payments Lattice service indicator — fixed position outside VPC, inside Account box */}
          {paymentsReachable && (
            <g>
              <foreignObject x={CX+80} y={158} width={20} height={20}><div className="flex items-center justify-center"><VPCLatticeIcon size={18} /></div></foreignObject>
              <text x={CX+104} y={171} fill="#c4b5fd" fontSize={7} fontWeight={600}>VPC Lattice service</text>
            </g>
          )}
          {!centralized && (
            <g>
              <rect x={CX-175} y={LATTICE_Y-12} width={350} height={26} rx={5} fill="rgba(140,79,255,0.12)" stroke={PURPLE} strokeWidth={1.5} />
              <text x={CX} y={LATTICE_Y+5} textAnchor="middle" fill="#c4b5fd" fontSize={9} fontWeight={600}>VPC Lattice Service Network</text>
              <foreignObject x={CX+135} y={LATTICE_Y-9} width={28} height={22}><div className="flex items-center justify-center"><VPCLatticeIcon size={20} /></div></foreignObject>
            </g>
          )}
        </AccountBox>

        {/* ── Networking Account (centralized) ─────────────────────── */}
        {centralized && (
          <AccountBox x={CX-210} y={220} width={420} height={46} label="AWS Account — Networking">
            <rect x={CX-190} y={LATTICE_Y-12} width={380} height={26} rx={5} fill="rgba(140,79,255,0.12)" stroke={PURPLE} strokeWidth={1.5} />
            <text x={CX} y={LATTICE_Y+5} textAnchor="middle" fill="#c4b5fd" fontSize={9} fontWeight={600}>VPC Lattice Service Network</text>
            <foreignObject x={CX+150} y={LATTICE_Y-9} width={28} height={22}><div className="flex items-center justify-center"><VPCLatticeIcon size={20} /></div></foreignObject>
          </AccountBox>
        )}

        {/* ── Backend-A: Catalog + Pricing ──────────────────────────── */}
        <AccountBox x={5} y={288} width={300} height={155} label="AWS Account — Backend-A">
          {itemsUp && (
            <g>
              <foreignObject x={X_LEFT-10} y={SVC_Y-10} width={20} height={20}><div className="flex items-center justify-center"><VPCLatticeIcon size={18} /></div></foreignObject>
              <text x={X_LEFT+14} y={SVC_Y+4} fill="#c4b5fd" fontSize={7} fontWeight={600}>VPC Lattice service</text>
            </g>
          )}
          <VPCBox x={X_LEFT-130} y={SVC_Y+12} width={260} height={82} name="Backend-A VPC">
            <g>
              <rect x={X_LEFT-105} y={TG_Y-12} width={210} height={50} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={X_LEFT-101} y={TG_Y-10} width={14} height={14}><div className="flex items-center justify-center"><EKSIcon size={12} /></div></foreignObject>
              <rect x={X_LEFT-86} y={TG_Y-6} width={100} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={X_LEFT-85} y={TG_Y+1} fill="#fdba74" fontSize={7} fontWeight={600}>Backend-A EKS Cluster</text>
              <rect x={X_LEFT-90} y={TG_Y+6} width={90} height={18} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.7} />
              <text x={X_LEFT-45} y={TG_Y+18} textAnchor="middle" fill="#e2e8f0" fontSize={7}>📚 Catalog</text>
              <rect x={X_LEFT+10} y={TG_Y+6} width={90} height={18} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.7} />
              <text x={X_LEFT+55} y={TG_Y+18} textAnchor="middle" fill="#e2e8f0" fontSize={7}>💰 Pricing</text>
            </g>
          </VPCBox>
        </AccountBox>

        {/* ── Backend-B: Cart ──────────────────────────────────────── */}
        <AccountBox x={355} y={288} width={300} height={155} label="AWS Account — Backend-B">
          {cartReachable && (
            <g>
              <foreignObject x={X_RIGHT-10} y={SVC_Y-10} width={20} height={20}><div className="flex items-center justify-center"><VPCLatticeIcon size={18} /></div></foreignObject>
              <text x={X_RIGHT+14} y={SVC_Y+4} fill="#c4b5fd" fontSize={7} fontWeight={600}>VPC Lattice service</text>
            </g>
          )}
          <VPCBox x={X_RIGHT-120} y={SVC_Y+12} width={230} height={82} name="Backend-B VPC">
            <g>
              <rect x={X_RIGHT-95} y={TG_Y-12} width={180} height={50} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={X_RIGHT-91} y={TG_Y-10} width={14} height={14}><div className="flex items-center justify-center"><EKSIcon size={12} /></div></foreignObject>
              <rect x={X_RIGHT-76} y={TG_Y-6} width={100} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={X_RIGHT-75} y={TG_Y+1} fill="#fdba74" fontSize={7} fontWeight={600}>Backend-B EKS Cluster</text>
              <rect x={X_RIGHT-60} y={TG_Y+6} width={90} height={18} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.7} />
              <text x={X_RIGHT-15} y={TG_Y+18} textAnchor="middle" fill="#e2e8f0" fontSize={7}>🛒 Cart</text>
            </g>
          </VPCBox>
        </AccountBox>

        {/* ══ CONNECTIONS ══════════════════════════════════════════ */}

        {/* ALB → Frontend → BFF — always shown */}
        <ConnectionLine x1={CX-50} y1={ALB_Y+18} x2={CX-97} y2={EKS_Y+12} color={GREEN} />
        <ConnectionLine x1={CX-62} y1={EKS_Y+19} x2={CX-52} y2={EKS_Y+19} color={GREEN} />

        {/* Edge VPC association line — from VPC bottom to Lattice bar */}
        <line x1={CX-20} y1={148} x2={CX-20} y2={LATTICE_Y-12} stroke={PURPLE} strokeWidth={1.5} strokeDasharray="4 3" />
        <rect x={CX-60} y={190} width={80} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
        <text x={CX-20} y={199} textAnchor="middle" fill="#c4b5fd" fontSize={7} fontStyle="italic">VPC association</text>

        {/* Service association lines — purple, with labels, shown when reachable */}
        {itemsUp && (
          <g>
            <ConnectionLine x1={CX-100} y1={LATTICE_Y+14} x2={X_LEFT} y2={SVC_Y-10} color={PURPLE} />
            <rect x={(CX-100+X_LEFT)/2-42} y={(LATTICE_Y+14+SVC_Y-10)/2-6} width={84} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={(CX-100+X_LEFT)/2} y={(LATTICE_Y+14+SVC_Y-10)/2+3} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">service association</text>
          </g>
        )}
        {cartReachable && (
          <g>
            <ConnectionLine x1={CX+100} y1={LATTICE_Y+14} x2={X_RIGHT} y2={SVC_Y-10} color={PURPLE} />
            <rect x={(CX+100+X_RIGHT)/2-42} y={(LATTICE_Y+14+SVC_Y-10)/2-6} width={84} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={(CX+100+X_RIGHT)/2} y={(LATTICE_Y+14+SVC_Y-10)/2+3} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">service association</text>
          </g>
        )}
        {/* Payments service association — from Lattice bar up to Payments Lattice icon (fixed) */}
        {paymentsReachable && (
          <g>
            <ConnectionLine x1={CX+20} y1={LATTICE_Y-12} x2={CX+90} y2={178} color={PURPLE} />
            <rect x={CX+30} y={190} width={84} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={CX+72} y={199} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">service association</text>
          </g>
        )}

        {/* Backend-B VPC association — elbow connector: right from VPC, then up to service network */}
        {cartReachable && (
          <g>
            <path d={`M${X_RIGHT+110},${SVC_Y+53} L${X_RIGHT+130},${SVC_Y+53} L${X_RIGHT+130},${LATTICE_Y+1} L${centralized ? CX+190 : CX+175},${LATTICE_Y+1}`}
              fill="none" stroke={PURPLE} strokeWidth={1.5} strokeDasharray="4 3" />
            {/* Label on the horizontal segment near the service network */}
            <rect x={(X_RIGHT+130+(centralized ? CX+190 : CX+175))/2-34} y={LATTICE_Y-12} width={68} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={(X_RIGHT+130+(centralized ? CX+190 : CX+175))/2} y={LATTICE_Y-3} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">VPC association</text>
          </g>
        )}

        {/* Lattice service icon → microservice lines — purple, shown when reachable */}
        {catalogReachable && (
          <ConnectionLine x1={X_LEFT} y1={SVC_Y+10} x2={X_LEFT-45} y2={TG_Y+6} color={PURPLE} />
        )}
        {pricingReachable && (
          <ConnectionLine x1={X_LEFT} y1={SVC_Y+10} x2={X_LEFT+55} y2={TG_Y+6} color={PURPLE} />
        )}
        {cartReachable && (
          <ConnectionLine x1={X_RIGHT} y1={SVC_Y+10} x2={X_RIGHT-15} y2={TG_Y+6} color={PURPLE} />
        )}
        {/* Payments Lattice icon → Payments microservice */}
        {paymentsReachable && (
          <ConnectionLine x1={CX+90} y1={158} x2={CX+85} y2={EKS_Y+28} color={PURPLE} />
        )}

        {/* ── Traffic flow lines — direct end-to-end green, one set at a time ── */}

        {/* Shop view: BFF → Catalog and BFF → Pricing (direct lines through Lattice) */}
        {showItemsFlow && catalogReachable && (
          <ConnectionLine x1={CX-22} y1={EKS_Y+26} x2={X_LEFT-45} y2={TG_Y+6} color={GREEN} animated={true} />
        )}
        {showItemsFlow && pricingReachable && (
          <ConnectionLine x1={CX-22} y1={EKS_Y+26} x2={X_LEFT+55} y2={TG_Y+6} color={GREEN} animated={true} />
        )}

        {/* Cart view: BFF → Cart (direct line through Lattice) */}
        {showCartFlow && (
          <ConnectionLine x1={CX-22} y1={EKS_Y+26} x2={X_RIGHT-15} y2={TG_Y+6} color={GREEN} animated={true} />
        )}

        {/* Checkout confirmation: BFF → Cart + Cart → Payments (two-hop chain) */}
        {showCheckoutFlow && (
          <>
            <ConnectionLine x1={CX-22} y1={EKS_Y+26} x2={X_RIGHT-15} y2={TG_Y+6} color={GREEN} animated={true} />
            <ConnectionLine x1={X_RIGHT-15} y1={TG_Y+6} x2={CX+85} y2={EKS_Y+20} color={GREEN} animated={true} />
          </>
        )}
      </svg>
    </div>
  );
}
