# Architecture Overview

This document describes the infrastructure layout and the reasoning behind each design decision.

## Three clusters, three VPCs

This sample uses three EKS clusters, each in its own VPC:

| Cluster | VPC | Hosts | Purpose |
|---------|-----|-------|---------|
| Frontend | `frontend-vpc` (10.0.0.0/16) | React frontend + BFF | Internet-facing entry point |
| Backend-A | `backend-a-vpc` (10.0.0.0/16) | Cart + Inventory services | Shared "items" domain |
| Backend-B | `backend-b-vpc` (10.0.0.0/16) | Payments service | Isolated payment processing |

Each VPC has public and private subnets across two availability zones, with NAT gateways for outbound internet access from private subnets. The VPCs are not peered; all cross-VPC communication flows through VPC Lattice.

## VPC Lattice service network

A single VPC Lattice service network connects the three VPCs. The key associations:

- **Frontend VPC to service network** (VPC association): Created by Terraform in the VPC module. This allows the BFF pods to consume VPC Lattice services (resolve DNS and send traffic).
- **Items service to service network** (service association): Created by the Gateway API Controller when the HTTPRoute is applied on Backend-A.
- **Payments service to service network** (service association): Created by the Gateway API Controller when the HTTPRoute is applied on Backend-B.

### Authentication

The service network is configured with [AWS IAM authentication](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) (`auth_type = AWS_IAM`). Every request must be signed with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html); unauthenticated requests are rejected before they reach any service.

The backend VPCs are intentionally not associated with the service network. They only serve traffic (targets registered by IP) and don't consume services from it. This is enforced via a `VpcAssociationPolicy` with `associateWithVpc: false` on each backend cluster. See [Gateway API Controllers](gateway-api.md) for details.

## DNS Architecture

Two Route 53 hosted zones handle DNS:

- **Public hosted zone**: Managed by ExternalDNS on the frontend cluster. Contains A/AAAA alias records pointing `frontend.<domain>` to the ALB. Only created when `alb_protocol = HTTPS` — in HTTP mode there is no custom domain and ExternalDNS has nothing to register.
- **Private hosted zone**: Associated with the frontend VPC. Managed by ExternalDNS on the backend clusters. Contains CNAME records pointing `items.<domain>` and `payments.<domain>` to their VPC Lattice service DNS names.

If you configure the private zone with the same domain name as the public zone, ExternalDNS instances must be scoped using `--aws-zone-type` (public vs private) and `--zone-id-filter` to ensure each instance only writes to its intended zone. If you use different domain names for each zone, this scoping is still recommended as a best practice to avoid unintended record creation.

## Security layers

### WAF

An AWS WAFv2 WebACL is attached to the frontend ALB with three rule groups. WAF is always enabled regardless of whether `alb_protocol` is `HTTP` or `HTTPS`:

1. **AWS Managed Rules: Core Rule Set** (XSS, SQLi protection)
2. **AWS Managed Rules: Known Bad Inputs** (Log4j, request smuggling)
3. **Rate limiting** (10,000 requests per IP)

The WAF ARN is injected into the ALB Gateway manifest via a `LoadBalancerConfiguration` resource.

### IAM Authentication on VPC Lattice

The service network uses `AWS_IAM` auth, which means every request must be signed with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html) using the `vpc-lattice-svcs` service name. Unsigned requests are rejected at the service network level before reaching any target.

The BFF pod signs requests using credentials obtained automatically via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html), with no long-lived keys and no IRSA OIDC setup required. The `bff-service-account` is associated with an IAM role that has `vpc-lattice-svcs:Invoke` permission.

Each VPC Lattice HTTPRoute has an [`IAMAuthPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/iam-auth-policy/) that allows any authenticated (non-anonymous) principal:

```json
{
  "Effect": "Allow",
  "Principal": "*",
  "Action": "*",
  "Resource": "*",
  "Condition": {
    "StringNotEqualsIgnoreCase": {
      "aws:PrincipalType": "anonymous"
    }
  }
}
```

This policy is intentionally broad for a sample; it allows any IAM principal with valid credentials to call the service. [VPC Lattice auth policies](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) support much more granular conditions: you can restrict by principal ARN (e.g. only a specific IAM role), by source VPC, by request path, or by any combination of IAM condition keys. Before using this pattern in production, we recommend reviewing the [auth policy reference](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) and the [IAMAuthPolicy CRD documentation](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/iam-auth-policy/) to apply the least-privilege policy appropriate for your use case.

## Infrastructure as Code

All infrastructure is managed by Terraform in the `infra/` directory:

| File | Resources |
|------|-----------|
| `providers.tf` | AWS provider, Terraform version constraints |
| `variables.tf` | Input variables (region, certificate, domain, prefix) |
| `frontend.tf` | Frontend VPC, EKS cluster, ECR repos (frontend + BFF), WAF WebACL |
| `backend_a.tf` | Backend-A VPC, EKS cluster, ECR repos (cart + inventory), CloudWatch log groups |
| `backend_b.tf` | Backend-B VPC, EKS cluster, ECR repos (payments), CloudWatch log groups |
| `networking.tf` | VPC Lattice service network, Route 53 private hosted zone |
| `iam.tf` | All IAM roles, policies, and Pod Identity associations |
| `data.tf` | Shared data sources (caller identity, VPC Lattice prefix list) |
| `outputs.tf` | Values consumed by the deployment script |

The Terraform code uses two community modules from the [aws-ia](https://registry.terraform.io/namespaces/aws-ia) namespace:

| Module | Used for |
|--------|----------|
| [aws-ia/vpc/aws](https://registry.terraform.io/modules/aws-ia/vpc/aws/latest) | VPC creation with public/private subnets, NAT gateways, and native VPC Lattice service network association support |
| [aws-ia/amazon-vpc-lattice-module/aws](https://registry.terraform.io/modules/aws-ia/amazon-vpc-lattice-module/aws/latest) | VPC Lattice service network with IAM auth policy and CloudWatch access log configuration |

## Deployment Flow

The `manage.sh` script orchestrates the full lifecycle in six steps:

1. **ECR Repositories**: Targeted Terraform apply to create the five ECR repos
2. **Container Images**: Build and push all five services (arm64 for Graviton)
3. **Infrastructure**: Full Terraform apply (VPCs, EKS clusters, IAM, VPC Lattice network, WAF, Route 53)
4. **Cluster Configuration**: Graviton NodePools, Gateway API CRDs, controllers (AWS LBC on frontend, VPC Lattice controller on backends), ExternalDNS on all three clusters
5. **Applications**: Deploy services to their respective clusters
6. **Networking**: Apply ALB Gateway on frontend, VPC Lattice resources on backends

Teardown reverses the order, with existence checks at each step so it's safe to run regardless of deployment state.
