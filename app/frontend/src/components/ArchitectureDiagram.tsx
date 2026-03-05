import { useState } from "react";
import { motion } from "framer-motion";
import { ALBIcon, EKSIcon, VPCLatticeIcon, VPCIcon, WAFIcon } from "./AwsIcons";

export interface ArchitectureDiagramProps {
  cartReachable: boolean;
  paymentsReachable: boolean;
  inventoryReachable: boolean;
  activeService: string | null;
}

const GREEN = "#22c55e";
const RED = "#ef4444";
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

function TargetGroupBox({ x, y, label, emoji, reachable }: {
  x: number; y: number; label: string; emoji: string; reachable: boolean;
}) {
  const color = reachable ? GREEN : RED;
  return (
    <g>
      <rect x={x} y={y} width={90} height={22} rx={3} fill="rgba(255,255,255,0.05)" stroke={color} strokeWidth={1} />
      <circle cx={x+10} cy={y+11} r={3} fill={color} />
      <text x={x+18} y={y+15} fill="#e2e8f0" fontSize={7}>{emoji} {label}</text>
    </g>
  );
}

export default function ArchitectureDiagram({ cartReachable, paymentsReachable, inventoryReachable, activeService }: ArchitectureDiagramProps) {
  const [centralized, setCentralized] = useState(true);
  const itemsServiceUp = cartReachable || inventoryReachable;
  const anyServiceUp = itemsServiceUp || paymentsReachable;
  const itemsLoading = activeService === "cart" || activeService === "inventory";
  const paymentsLoading = activeService === "payments";
  const W = 660, H = 480, CX = W / 2;
  const ALB_Y = 36, EKS_Y = 92, LATTICE_Y = 220;
  const SVC_Y = 290, TG_Y = 340;
  const X_LEFT = 165, X_RIGHT = 500;

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

        {/* Frontend Account */}
        <AccountBox x={CX-170} y={8} width={340} height={centralized ? 140 : 230} label="AWS Account — Frontend">
          <VPCBox x={CX-155} y={18} width={310} height={120} name="Frontend VPC">
            <ServiceNode x={CX-40} y={ALB_Y} icon={<ALBIcon size={22} />} label="ALB" />
            <ServiceNode x={CX+50} y={ALB_Y} icon={<WAFIcon size={22} />} label="AWS WAF" />
            <line x1={CX-18} y1={ALB_Y} x2={CX+28} y2={ALB_Y} stroke="#94a3b8" strokeWidth={1} strokeDasharray="3 2" />
            <g>
              <rect x={CX-115} y={EKS_Y-14} width={230} height={40} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={CX-111} y={EKS_Y-12} width={16} height={16}><div className="flex items-center justify-center"><EKSIcon size={14} /></div></foreignObject>
              <rect x={CX-94} y={EKS_Y-8} width={90} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={CX-93} y={EKS_Y-1} fill="#fdba74" fontSize={7} fontWeight={600}>Frontend EKS Cluster</text>
              <rect x={CX-95} y={EKS_Y+4} width={85} height={16} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.8} />
              <text x={CX-52} y={EKS_Y+15} textAnchor="middle" fill="#e2e8f0" fontSize={7}>🖥 Frontend</text>
              <rect x={CX+10} y={EKS_Y+4} width={85} height={16} rx={3} fill="rgba(255,255,255,0.05)" stroke="#64748b" strokeWidth={0.8} />
              <text x={CX+52} y={EKS_Y+15} textAnchor="middle" fill="#e2e8f0" fontSize={7}>⚡ BFF Service</text>
            </g>
          </VPCBox>
          {!centralized && (
            <g>
              <rect x={CX-155} y={LATTICE_Y-12} width={310} height={26} rx={5} fill="rgba(140,79,255,0.12)" stroke={PURPLE} strokeWidth={1.5} />
              <text x={CX} y={LATTICE_Y+5} textAnchor="middle" fill="#c4b5fd" fontSize={9} fontWeight={600}>VPC Lattice Service Network</text>
              <foreignObject x={CX+115} y={LATTICE_Y-9} width={28} height={22}><div className="flex items-center justify-center"><VPCLatticeIcon size={20} /></div></foreignObject>
            </g>
          )}
        </AccountBox>

        {/* Networking Account */}
        {centralized && (
          <AccountBox x={CX-190} y={195} width={380} height={46} label="AWS Account — Networking">
            <rect x={CX-170} y={LATTICE_Y-12} width={340} height={26} rx={5} fill="rgba(140,79,255,0.12)" stroke={PURPLE} strokeWidth={1.5} />
            <text x={CX} y={LATTICE_Y+5} textAnchor="middle" fill="#c4b5fd" fontSize={9} fontWeight={600}>VPC Lattice Service Network</text>
            <foreignObject x={CX+130} y={LATTICE_Y-9} width={28} height={22}><div className="flex items-center justify-center"><VPCLatticeIcon size={20} /></div></foreignObject>
          </AccountBox>
        )}

        {/* Items Account — tight around content */}
        <AccountBox x={10} y={268} width={310} height={SVC_Y > 0 ? 145 : 145} label="AWS Account — Items">
          {itemsServiceUp && (
            <g>
              <foreignObject x={X_LEFT-10} y={SVC_Y-10} width={20} height={20}><div className="flex items-center justify-center"><VPCLatticeIcon size={18} /></div></foreignObject>
              <text x={X_LEFT+14} y={SVC_Y+4} fill="#c4b5fd" fontSize={7} fontWeight={600}>VPC Lattice Service</text>
            </g>
          )}
          <VPCBox x={X_LEFT-130} y={SVC_Y+12} width={260} height={82} name="Items VPC">
            <g>
              <rect x={X_LEFT-105} y={TG_Y-12} width={210} height={50} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={X_LEFT-101} y={TG_Y-10} width={14} height={14}><div className="flex items-center justify-center"><EKSIcon size={12} /></div></foreignObject>
              <rect x={X_LEFT-86} y={TG_Y-6} width={75} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={X_LEFT-85} y={TG_Y+1} fill="#fdba74" fontSize={7} fontWeight={600}>Items EKS Cluster</text>
              <TargetGroupBox x={X_LEFT-90} y={TG_Y+6} label="Cart TG" emoji="🛒" reachable={cartReachable} />
              <TargetGroupBox x={X_LEFT+10} y={TG_Y+6} label="Inventory TG" emoji="📦" reachable={inventoryReachable} />
            </g>
          </VPCBox>
        </AccountBox>

        {/* Payments Account — tight around content */}
        <AccountBox x={345} y={268} width={305} height={145} label="AWS Account — Payments">
          {paymentsReachable && (
            <g>
              <foreignObject x={X_RIGHT-10} y={SVC_Y-10} width={20} height={20}><div className="flex items-center justify-center"><VPCLatticeIcon size={18} /></div></foreignObject>
              <text x={X_RIGHT+14} y={SVC_Y+4} fill="#c4b5fd" fontSize={7} fontWeight={600}>VPC Lattice Service</text>
            </g>
          )}
          <VPCBox x={X_RIGHT-110} y={SVC_Y+12} width={220} height={82} name="Payments VPC">
            <g>
              <rect x={X_RIGHT-85} y={TG_Y-12} width={170} height={50} rx={4} fill="rgba(237,113,0,0.08)" stroke="#ED7100" strokeWidth={1} />
              <foreignObject x={X_RIGHT-81} y={TG_Y-10} width={14} height={14}><div className="flex items-center justify-center"><EKSIcon size={12} /></div></foreignObject>
              <rect x={X_RIGHT-66} y={TG_Y-6} width={90} height={10} rx={1} fill="#0f172a" fillOpacity={0.9} />
              <text x={X_RIGHT-65} y={TG_Y+1} fill="#fdba74" fontSize={7} fontWeight={600}>Payments EKS Cluster</text>
              <TargetGroupBox x={X_RIGHT-55} y={TG_Y+6} label="Payments TG" emoji="💳" reachable={paymentsReachable} />
            </g>
          </VPCBox>
        </AccountBox>

        {/* === CONNECTIONS === */}
        <ConnectionLine x1={CX-40} y1={ALB_Y+18} x2={CX-52} y2={EKS_Y+4} color={GREEN} />
        <ConnectionLine x1={CX-10} y1={EKS_Y+12} x2={CX+10} y2={EKS_Y+12} color={GREEN} />
        <line x1={CX} y1={140} x2={CX} y2={LATTICE_Y-12} stroke={PURPLE} strokeWidth={1.5} strokeDasharray="4 3" />
        <rect x={CX-80} y={165} width={72} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
        <text x={CX-44} y={174} textAnchor="middle" fill="#c4b5fd" fontSize={7} fontStyle="italic">VPC association</text>
        <ConnectionLine x1={CX+52} y1={EKS_Y+20} x2={CX+20} y2={LATTICE_Y-12} color={anyServiceUp ? GREEN : RED} />

        {/* Items path */}
        <ConnectionLine x1={CX-120} y1={LATTICE_Y+14} x2={X_LEFT} y2={SVC_Y-10} color={itemsServiceUp ? GREEN : RED} animated={itemsLoading} />
        {itemsServiceUp && (
          <g>
            <line x1={CX-50} y1={LATTICE_Y+14} x2={X_LEFT} y2={SVC_Y-10} stroke={PURPLE} strokeWidth={1.5} strokeDasharray="4 3" />
            <rect x={(CX-50+X_LEFT)/2-38} y={(LATTICE_Y+14+SVC_Y-10)/2-6} width={76} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={(CX-50+X_LEFT)/2} y={(LATTICE_Y+14+SVC_Y-10)/2+3} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">service association</text>
          </g>
        )}
        {cartReachable && (
          <ConnectionLine x1={X_LEFT} y1={SVC_Y+10} x2={X_LEFT-45} y2={TG_Y+6} color={GREEN} animated={activeService === "cart"} />
        )}
        {inventoryReachable && (
          <ConnectionLine x1={X_LEFT} y1={SVC_Y+10} x2={X_LEFT+55} y2={TG_Y+6} color={GREEN} animated={activeService === "inventory"} />
        )}

        {/* Payments path */}
        <ConnectionLine x1={CX+120} y1={LATTICE_Y+14} x2={X_RIGHT} y2={SVC_Y-10} color={paymentsReachable ? GREEN : RED} animated={paymentsLoading} />
        {paymentsReachable && (
          <g>
            <line x1={CX+50} y1={LATTICE_Y+14} x2={X_RIGHT} y2={SVC_Y-10} stroke={PURPLE} strokeWidth={1.5} strokeDasharray="4 3" />
            <rect x={(CX+50+X_RIGHT)/2-38} y={(LATTICE_Y+14+SVC_Y-10)/2-6} width={76} height={12} rx={2} fill="#0f172a" fillOpacity={0.95} />
            <text x={(CX+50+X_RIGHT)/2} y={(LATTICE_Y+14+SVC_Y-10)/2+3} textAnchor="middle" fill="#c4b5fd" fontSize={6} fontStyle="italic">service association</text>
            <ConnectionLine x1={X_RIGHT} y1={SVC_Y+10} x2={X_RIGHT-10} y2={TG_Y+6} color={GREEN} animated={paymentsLoading} />
          </g>
        )}
      </svg>
    </div>
  );
}
