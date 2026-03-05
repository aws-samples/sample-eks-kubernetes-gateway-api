// Official AWS Architecture Icons — sourced from the AWS Icon Package
// https://aws.amazon.com/architecture/icons/

interface IconProps {
  size?: number;
  className?: string;
}

export function CloudFrontIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Arch_Amazon-CloudFront_64.svg" width={size} height={size} alt="Amazon CloudFront" className={className} />;
}

export function WAFIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Arch_AWS-WAF_64.svg" width={size} height={size} alt="AWS WAF" className={className} />;
}

export function ALBIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Arch_Elastic-Load-Balancing_64.svg" width={size} height={size} alt="Elastic Load Balancing" className={className} />;
}

export function EKSIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Arch_Amazon-Elastic-Kubernetes-Service_64.svg" width={size} height={size} alt="Amazon EKS" className={className} />;
}

export function VPCLatticeIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Arch_Amazon-VPC-Lattice_64.svg" width={size} height={size} alt="Amazon VPC Lattice" className={className} />;
}

export function VPCIcon({ size = 40, className }: IconProps) {
  return <img src="/aws-icons/Virtual-private-cloud-VPC_32.svg" width={size} height={size} alt="Amazon VPC" className={className} />;
}
