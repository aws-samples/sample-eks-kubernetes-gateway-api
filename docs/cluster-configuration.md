# Cluster Configuration

This document explains how the three EKS clusters are configured and why each decision was made.

## EKS Auto Mode

All three clusters run [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html) (Kubernetes 1.35). Auto Mode simplifies operations by:

- Automatically provisioning and scaling nodes based on pod requirements
- Managing the node lifecycle (patching, draining, replacing)
- Providing built in support for EBS storage and elastic load balancing

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

All container images are built for `linux/arm64` to match. Graviton instances offer better price performance for this workload profile.

## Pod Identity

`k8s/cluster-config/aws-lbc-sa.yaml`, `k8s/cluster-config/aws-application-networking-sa.yaml`, `k8s/cluster-config/external-dns-sa.yaml`

All AWS permissions are granted via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html), not [IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html) (IAM Roles for Service Accounts). Pod Identity is simpler with no OIDC provider setup and no annotation based role mapping. The trust policy uses a straightforward `pods.eks.amazonaws.com` service principal:

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
| [AWS LBC](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) | Edge | `kube-system` | `aws-load-balancer-controller` |
| BFF (SigV4) | Edge | `default` | `bff-service-account` |
| Cart (SigV4) | Backend B | `default` | `cart-service-account` |
| [Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/) | Edge, Backend A, Backend B | `aws-application-networking-system` | `gateway-api-controller` |
| [ExternalDNS](https://github.com/kubernetes-sigs/external-dns) | All three | `external-dns` | `external-dns` |

## Controller installs

### Edge Cluster

The edge cluster gets four controllers:

**[AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)** (Helm release `aws-lb-controller`, chart `eks/aws-load-balancer-controller`):
- Installed in `kube-system` with `serviceAccount.create=false` (the SA is pre created for Pod Identity)
- Feature gate `ALBGatewayAPI=true` enables Gateway API support
- `vpcId` and `region` are set explicitly (required for EKS Auto Mode where IMDS may not be reachable)
- This is a self managed install (the EKS Auto Mode built in LBC does not support Gateway API at the time of writing)

```bash
helm upgrade --install aws-lb-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName="<cluster-name>" \
  --set region="<region>" \
  --set vpcId="<vpc-id>" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "controllerConfig.featureGates.ALBGatewayAPI=true"
```

**ExternalDNS (public zone)** (Helm release `external-dns-public`, chart `external-dns/external-dns`):
- Scoped to the public hosted zone via `--zone-id-filter`
- Uses annotation filter `external-dns/zone=public` to only process HTTPRoutes annotated with `external-dns/zone: public`
- Watches only `gateway-httproute` sources
- Creates A/AAAA alias records for the ALB
- Uses `upsert-only` policy (never deletes records automatically)

**ExternalDNS (private zone)** (Helm release `external-dns-private`, chart `external-dns/external-dns`):
- Scoped to the private hosted zone via `--zone-id-filter`
- Uses annotation filter `external-dns/zone=private` to only process HTTPRoutes annotated with `external-dns/zone: private`
- Watches only `gateway-httproute` sources
- Creates CNAME records pointing VPC Lattice service hostnames (e.g. Payments) to their Lattice DNS names
- Uses `upsert-only` policy

Running two ExternalDNS instances on the edge cluster is necessary because the edge cluster publishes both an ALB (public DNS) and a VPC Lattice service (private DNS). The annotation filter ensures each instance only manages records in its intended zone.

**[VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/)** (Helm release `amazon-vpclattice-controller`, chart distributed as an OCI artifact from `public.ecr.aws`):
- Same configuration as the backend clusters (see below)
- Enables the edge cluster to publish the Payments service as a VPC Lattice service
- `defaultServiceNetwork` is set to the Terraform created service network name
- `clusterVpcId` is set to the edge VPC ID

### Backend Clusters (A and B)

Each backend cluster gets two controllers:

**[VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/)** (Helm release `amazon-vpclattice-controller`, chart distributed as an OCI artifact from `public.ecr.aws`):
- Installed in `aws-application-networking-system` with `serviceAccount.create=false`
- `defaultServiceNetwork` is set to the Terraform created service network name
- `clusterVpcId` is set to the respective backend VPC ID
- Version v2.0.1

```bash
helm upgrade --install amazon-vpclattice-controller \
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
- Uses annotation filter `external-dns/zone=private`
- Creates CNAME records pointing service hostnames to VPC Lattice DNS names
- Same `upsert-only` policy

### Why annotation based zone filtering matters

The edge cluster runs two ExternalDNS instances that must write to different hosted zones. Without annotation filtering, both instances would attempt to process all HTTPRoutes, potentially creating records in the wrong zone. The `external-dns/zone` annotation on each HTTPRoute acts as a selector: the public instance only processes routes annotated with `external-dns/zone: public`, and the private instance only processes routes annotated with `external-dns/zone: private`. This is good practice regardless of whether the domain names match between zones.

## Gateway API CRDs

The clusters use different Gateway API CRD channels because each controller has different requirements:

- **Edge**: [Experimental channel](https://gateway-api.sigs.k8s.io/guides/#install-experimental-channel) (v1.2.1) plus [AWS LBC specific CRDs](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/) (LoadBalancerConfiguration, TargetGroupConfiguration). The edge cluster uses the experimental channel because it runs both the AWS LBC and the VPC Lattice controller, and the VPC Lattice controller depends on resources only available in the experimental channel.
- **Backends**: [Experimental channel](https://gateway-api.sigs.k8s.io/guides/#install-experimental-channel) (v1.2.1). The VPC Lattice controller depends on resources that haven't graduated to the standard channel yet, specifically the policy attachment types (`TargetGroupPolicy`, `IAMAuthPolicy`, `AccessLogPolicy`) and `TLSRoute`. These are only available in the experimental channel.

## Shared IAM Roles

To reduce IAM complexity, some roles are shared across clusters:

- **EKS cluster role**: One role for all three cluster control planes
- **EKS node role**: One role for all Auto Mode worker nodes
- **Gateway API Controller role**: One role used by all three clusters
- **ExternalDNS role**: One role with permissions on both hosted zones, used by all three clusters

Per cluster roles exist only where the permissions differ: the AWS LBC role (edge only), the BFF pod role (edge only, for `vpc-lattice-svcs:Invoke`), and the Cart pod role (Backend B only, for `vpc-lattice-svcs:Invoke`).

## EKS Control Plane Logging

All three clusters have `enabled_cluster_log_types` configured to send the following log streams to CloudWatch:

```hcl
enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```

This enables full visibility into API server activity, authentication events, and control plane component behaviour, which is essential for security incident investigation. Logs are sent to the `/aws/eks/<cluster-name>/cluster` log group in CloudWatch.

## Container Security Hardening

All application containers are configured with a hardened `securityContext` at the container level:

```yaml
securityContext:
  allowPrivilegeEscalation: false   # prevents setuid/setgid escalation
  readOnlyRootFilesystem: true      # prevents writing to container filesystem
  capabilities:
    drop: ["ALL"]                   # drops all Linux capabilities
  seccompProfile:
    type: RuntimeDefault            # applies the container runtime's default seccomp filter
```

Since `readOnlyRootFilesystem: true` prevents writes to the container filesystem, services that need temporary write access use in memory `emptyDir` volumes:

- **Python services** (bff, catalog, pricing, cart, payments): `/tmp` mounted as tmpfs for uvicorn and Python runtime temp files
- **Frontend** (nginx): `/tmp`, `/var/cache/nginx`, and `/var/run` mounted as tmpfs

The Cart service has additional dependencies (botocore and httpx) for SigV4 signing and HTTP calls to the Payments service via VPC Lattice. These are the same libraries used by the BFF.

CPU limits are intentionally not set on any container. Fractional CPU limits (e.g. `250m`) cause kernel throttling even when the node has spare capacity, introducing latency spikes. CPU requests are set for scheduling purposes; Karpenter uses them to bin pack pods onto nodes. Memory limits are retained to prevent OOM conditions.
