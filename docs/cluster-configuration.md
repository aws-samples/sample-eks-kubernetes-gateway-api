# Cluster Configuration

This document explains how the three EKS clusters are configured and why each decision was made.

## EKS Auto Mode

All three clusters run [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) (Kubernetes 1.35). Auto Mode simplifies operations by:

- Automatically provisioning and scaling nodes based on pod requirements
- Managing the node lifecycle (patching, draining, replacing)
- Providing built-in support for EBS storage and elastic load balancing

The clusters are created by Terraform with `compute_config.enabled = true` and `node_pools = ["general-purpose"]`.

## Graviton NodePools

`k8s/cluster-config/nodepool-graviton.yaml`

A custom [Karpenter](https://karpenter.sh) `NodePool` is applied to each cluster to run workloads on [AWS Graviton](https://aws.amazon.com/ec2/graviton/) (arm64) instances:

```yaml
apiVersion: karpenter.sh/v1
kind: NodePool
metadata:
  name: graviton
spec:
  template:
    spec:
      requirements:
        - key: kubernetes.io/arch
          operator: In
          values: ["arm64"]
        - key: karpenter.sh/capacity-type
          operator: In
          values: ["on-demand"]
  disruption:
    consolidationPolicy: WhenEmptyOrUnderutilized
    consolidateAfter: 30s
```

All container images are built for `linux/arm64` to match. Graviton instances offer better price-performance for this workload profile.

## Pod Identity

`k8s/cluster-config/aws-lbc-sa.yaml`, `k8s/cluster-config/aws-application-networking-sa.yaml`, `k8s/cluster-config/external-dns-sa.yaml`

All AWS permissions are granted via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html), not [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) (IAM Roles for Service Accounts). Pod Identity is simpler with no OIDC provider setup and no annotation-based role mapping. The trust policy uses a straightforward `pods.eks.amazonaws.com` service principal:

```json
{
  "Effect": "Allow",
  "Principal": { "Service": "pods.eks.amazonaws.com" },
  "Action": ["sts:AssumeRole", "sts:TagSession"]
}
```

Terraform creates the Pod Identity associations for each role:

| Role | Cluster | Namespace | Service Account |
|------|---------|-----------|-----------------|
| [AWS LBC](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) | Frontend | `kube-system` | `aws-load-balancer-controller` |
| BFF (SigV4) | Frontend | `default` | `bff-service-account` |
| [Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/) | Backend-A, Backend-B | `aws-application-networking-system` | `gateway-api-controller` |
| [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | All three | `external-dns` | `external-dns` |

## Controller installs

### Frontend Cluster

The frontend cluster gets two controllers:

**[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)** (Helm chart `eks/aws-load-balancer-controller`):
- Installed in `kube-system` with `serviceAccount.create=false` (the SA is pre-created for Pod Identity)
- Feature gate `ALBGatewayAPI=true` enables Gateway API support
- `vpcId` and `region` are set explicitly (required for EKS Auto Mode where IMDS may not be reachable)
- This is a self-managed install — the EKS Auto Mode built-in LBC does not support Gateway API at the time of writing

```bash
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="<cluster-name>" \
  --set region="<region>" \
  --set vpcId="<vpc-id>" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "controllerConfig.featureGates.ALBGatewayAPI=true"
```

**[ExternalDNS](https://github.com/kubernetes-sigs/external-dns)** (Helm chart `external-dns/external-dns`):
- Scoped to the public hosted zone via `--aws-zone-type=public` and `--zone-id-filter`
- Watches only `gateway-httproute` sources
- Creates A/AAAA alias records for the ALB
- Uses `upsert-only` policy (never deletes records automatically)

### Backend Clusters (A and B)

Each backend cluster gets two controllers:

**[VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/)** (Helm chart distributed as an OCI artifact from `public.ecr.aws`):
- Installed in `aws-application-networking-system` with `serviceAccount.create=false`
- `defaultServiceNetwork` is set to the Terraform-created service network name
- `clusterVpcId` is set to the respective backend VPC ID
- Version v2.0.1

```bash
helm upgrade --install gateway-api-controller \
  oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
  --version=v2.0.1 \
  --namespace aws-application-networking-system \
  --set serviceAccount.create=false \
  --set awsRegion="<region>" \
  --set awsAccountId="<account-id>" \
  --set clusterVpcId="<vpc-id>" \
  --set clusterName="<cluster-name>" \
  --set defaultServiceNetwork="<service-network-name>"
```

**[ExternalDNS](https://github.com/kubernetes-sigs/external-dns)** (same Helm chart):
- Scoped to the private hosted zone via `--aws-zone-type=private` and `--zone-id-filter`
- Creates CNAME records pointing service hostnames to VPC Lattice DNS names
- Same `upsert-only` policy

### Why zone scoping matters

If the private zone uses the same domain name as the public zone, ExternalDNS instances without zone scoping would write to both zones: the backend instances would create VPC Lattice CNAMEs in the public zone, and the frontend instance would create ALB records in the private zone. The combination of `--aws-zone-type` and `--zone-id-filter` ensures each instance only manages its intended zone. This is good practice regardless of whether the domain names match.

## Gateway API CRDs

The clusters use different Gateway API CRD channels because each controller has different requirements:

- **Frontend**: [Standard channel](https://gateway-api.sigs.k8s.io/guides/#install-standard-channel) (v1.3.0) plus [AWS LBC-specific CRDs](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/) (LoadBalancerConfiguration, TargetGroupConfiguration). The AWS LBC only needs GA-stable resources, so the standard channel is the right fit.
- **Backends**: [Experimental channel](https://gateway-api.sigs.k8s.io/guides/#install-experimental-channel) (v1.2.1). The VPC Lattice controller depends on resources that haven't graduated to the standard channel yet, specifically the policy attachment types (`TargetGroupPolicy`, `IAMAuthPolicy`, `AccessLogPolicy`) and `TLSRoute`. These are only available in the experimental channel.

## Shared IAM Roles

To reduce IAM complexity, some roles are shared across clusters:

- **EKS cluster role**: One role for all three cluster control planes
- **EKS node role**: One role for all Auto Mode worker nodes
- **Gateway API Controller role**: One role used by both backend clusters
- **ExternalDNS role**: One role with permissions on both hosted zones, used by all three clusters

Per-cluster roles exist only where the permissions differ: the AWS LBC role (frontend only) and the BFF pod role (frontend only, for `vpc-lattice-svcs:Invoke`).
