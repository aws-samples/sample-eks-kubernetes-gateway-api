# Architecture Overview

This document describes the infrastructure layout and the reasoning behind each design decision.

## Three clusters, three VPCs

This sample uses three EKS clusters, each in its own VPC:

| Cluster | VPC | Hosts | Purpose |
|---------|-----|-------|---------|
| Edge | `edge-vpc` (10.0.0.0/16) | Frontend + BFF (the "Shop" app) + Payments | Internet facing entry point with ALB; also publishes Payments as a VPC Lattice service |
| Backend A | `backend-a-vpc` (10.0.0.0/16) | Catalog + Pricing services | Shared "items" domain with header based routing |
| Backend B | `backend-b-vpc` (10.0.0.0/16) | Cart service | Cart with checkout flow; consumes Payments via VPC Lattice |

Each VPC has public and private subnets across two availability zones, with NAT gateways for outbound internet access from private subnets. The VPCs are not peered; all cross VPC communication flows through VPC Lattice.

The edge cluster runs both the AWS Load Balancer Controller (for the internet facing ALB) and the VPC Lattice Gateway API Controller (for publishing Payments as a Lattice service). Backend A and Backend B each run only the VPC Lattice controller.

## VPC Lattice service network

A single VPC Lattice service network connects the three VPCs. Three VPC Lattice services are published on the network:

- **Items service** (Backend A): A single VPC Lattice service with header based routing. Requests with `x-service: catalog` route to the Catalog deployment; requests with `x-service: pricing` route to the Pricing deployment.
- **Cart service** (Backend B): A separate VPC Lattice service for the Cart deployment.
- **Payments service** (Edge): A separate VPC Lattice service for the Payments deployment, published from the edge cluster.

### VPC associations

- **Edge VPC to service network**: Created by Terraform. Allows the BFF pods to consume all three VPC Lattice services (resolve DNS and send traffic).
- **Backend B VPC to service network**: Created by Terraform. Allows the Cart pods to consume the Payments service during the checkout flow.
- **Backend A VPC**: Not associated with the service network. Backend A only serves traffic; it does not call other Lattice services. This is enforced via a `VpcAssociationPolicy` with `associateWithVpc: false`.

### Service associations

- **Items service to service network**: Created by the Gateway API Controller when the HTTPRoute is applied on Backend A.
- **Cart service to service network**: Created by the Gateway API Controller when the HTTPRoute is applied on Backend B.
- **Payments service to service network**: Created by the Gateway API Controller when the HTTPRoute is applied on the Edge cluster.

### Authentication

The service network is configured with [AWS IAM authentication](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) (`auth_type = AWS_IAM`). Every request must be signed with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html); unauthenticated requests are rejected before they reach any service.

Two pods sign requests to VPC Lattice:

- **BFF pod** (edge cluster): Signs requests to Catalog, Pricing, Cart, and Payments (health checks only). Credentials obtained via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html).
- **Cart pod** (Backend B cluster): Signs requests to Payments during the checkout flow. Also uses EKS Pod Identity credentials.

Both use botocore's `SigV4Auth` with the service name `vpc-lattice-svcs`, and both set `x-amz-content-sha256: UNSIGNED-PAYLOAD` with `payload_signing_enabled = False`.

## DNS Architecture

Two Route 53 hosted zones handle DNS:

- **Public hosted zone**: Contains A/AAAA alias records pointing `frontend.<domain>` to the ALB. Only created when `alb_protocol = HTTPS`; in HTTP mode there is no custom domain and ExternalDNS has nothing to register.
- **Private hosted zone**: Associated with the edge VPC and the Backend B VPC. Contains CNAME records pointing `items.<domain>`, `cart.<domain>`, and `payments.<domain>` to their VPC Lattice service DNS names.

### ExternalDNS on the edge cluster

The edge cluster runs two ExternalDNS instances, each scoped by an annotation filter:

- **external-dns-public**: Watches HTTPRoutes annotated with `external-dns/zone: public`. Creates A/AAAA alias records in the public hosted zone for the ALB.
- **external-dns-private**: Watches HTTPRoutes annotated with `external-dns/zone: private`. Creates CNAME records in the private hosted zone for VPC Lattice services published from the edge cluster (Payments).

Backend A and Backend B each run a single ExternalDNS instance scoped to the private hosted zone, creating CNAME records for their respective VPC Lattice services.

This annotation based filtering ensures each ExternalDNS instance only writes to its intended zone, even when both zones share the same domain name.

## Security layers

### WAF

An AWS WAFv2 WebACL is attached to the frontend ALB with three rule groups. WAF is always enabled regardless of whether `alb_protocol` is `HTTP` or `HTTPS`:

1. **AWS Managed Rules: Core Rule Set** (XSS, SQLi protection)
2. **AWS Managed Rules: Known Bad Inputs** (Log4j, request smuggling)
3. **Rate limiting** (10,000 requests per IP)

The WAF ARN is injected into the ALB Gateway manifest via a `LoadBalancerConfiguration` resource.

### IAM Authentication on VPC Lattice

The service network uses `AWS_IAM` auth, which means every request must be signed with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html) using the `vpc-lattice-svcs` service name. Unsigned requests are rejected at the service network level before reaching any target.

The BFF pod and the Cart pod both sign requests using credentials obtained automatically via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html), with no long lived keys and no IRSA OIDC setup required. The `bff-service-account` (edge cluster) and `cart-service-account` (Backend B cluster) are each associated with an IAM role that has `vpc-lattice-svcs:Invoke` permission.

Each VPC Lattice HTTPRoute has an [`IAMAuthPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/iam-auth-policy/) that allows any authenticated (non anonymous) principal:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": "*",
    "Action": "*",
    "Resource": "*",
    "Condition": {
      "StringNotEqualsIgnoreCase": {
        "aws:PrincipalType": "anonymous"
      }
    }
  }]
}
```

This policy is intentionally broad for a sample; it allows any IAM principal with valid credentials to call the service. [VPC Lattice auth policies](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) support much more granular conditions: you can restrict by principal ARN (e.g. only a specific IAM role), by source VPC, by request path, or by any combination of IAM condition keys. Before using this pattern in production, we recommend reviewing the [auth policy reference](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) and the [IAMAuthPolicy CRD documentation](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/iam-auth-policy/) to apply the least privilege policy appropriate for your use case.

## Infrastructure as Code

All infrastructure is managed by Terraform in the `infra/` directory:

| File | Resources |
|------|-----------|
| `providers.tf` | AWS provider, Terraform version constraints |
| `variables.tf` | Input variables (region, certificate, domain, prefix) |
| `edge.tf` | Edge VPC, EKS cluster, ECR repos (frontend, bff, payments), WAF WebACL, Payments CloudWatch log group, VPC Lattice controller Pod Identity |
| `backend_a.tf` | Backend A VPC, EKS cluster, ECR repos (catalog, pricing), Items CloudWatch log group |
| `backend_b.tf` | Backend B VPC (with VPC Lattice service network association), EKS cluster, ECR repo (cart), Cart CloudWatch log group, Cart Pod Identity |
| `networking.tf` | VPC Lattice service network, Route 53 private hosted zone |
| `iam.tf` | All IAM roles, policies, and Pod Identity associations (including cart_pod role with `vpc-lattice-svcs:Invoke`) |
| `data.tf` | Shared data sources (caller identity, VPC Lattice prefix list) |
| `outputs.tf` | Values consumed by the deployment script |

The Terraform code uses two community modules from the [aws-ia](https://registry.terraform.io/namespaces/aws-ia) namespace:

| Module | Used for |
|--------|----------|
| [aws-ia/vpc/aws](https://registry.terraform.io/modules/aws-ia/vpc/aws/latest) | VPC creation with public/private subnets, NAT gateways, and native VPC Lattice service network association support |
| [aws-ia/amazon-vpc-lattice-module/aws](https://registry.terraform.io/modules/aws-ia/amazon-vpc-lattice-module/aws/latest) | VPC Lattice service network with IAM auth policy and CloudWatch access log configuration |

## Deployment Flow

The `manage.sh` script orchestrates the full lifecycle in six steps:

1. **ECR Repositories**: Targeted Terraform apply to create the six ECR repos (frontend, bff, catalog, pricing, cart, payments)
2. **Container Images**: Build and push all six services (arm64 for Graviton)
3. **Infrastructure**: Full Terraform apply (VPCs, EKS clusters, IAM, VPC Lattice network, WAF, Route 53)
4. **Cluster Configuration**: Graviton NodePools, Gateway API CRDs, controllers (AWS LBC and VPC Lattice controller on edge, VPC Lattice controller on backends), ExternalDNS (two instances on edge, one on each backend)
5. **Applications**: Deploy services to their respective clusters (frontend, BFF, and payments on edge; catalog and pricing on Backend A; cart on Backend B)
6. **Networking**: Apply ALB Gateway on edge, VPC Lattice resources on all three clusters (items on Backend A, cart on Backend B, payments on edge)

Teardown reverses the order, with existence checks at each step so it's safe to run regardless of deployment state.
