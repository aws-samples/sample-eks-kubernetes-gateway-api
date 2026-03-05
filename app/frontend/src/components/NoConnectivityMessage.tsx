interface Props {
  service: string;
}

export default function NoConnectivityMessage({ service }: Props) {
  return (
    <div className="rounded-lg border border-red-500/20 bg-red-950/30 p-4">
      <p className="text-sm text-red-300">
        <span className="inline-block w-2 h-2 rounded-full bg-red-500 mr-2" />
        {service} Service is not reachable via VPC Lattice.
      </p>
    </div>
  );
}
