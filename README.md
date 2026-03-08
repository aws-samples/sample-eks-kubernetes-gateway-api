# Streamline Amazon EKS Application Networking with Gateway API

A hands-on sample showing how to use the Kubernetes Gateway API to handle both internet-facing traffic and cross-cluster service communication on [Amazon EKS](https://aws.amazon.com/eks/).

## What this sample shows

The [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) provides a unified, portable interface for managing traffic routing. This project demonstrates how two AWS controllers implement that same API for very different purposes:

- **North-South traffic.** The [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) implements the Gateway API to manage internet-facing [Elastic Load Balancers](https://aws.amazon.com/es/elasticloadbalancing/) for external ingress.
- **East-West traffic.** The [Amazon VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/) implements the same Gateway API to connect services across clusters and VPCs through [Amazon VPC Lattice](https://aws.amazon.com/vpc/lattice/), removing the need for a routable network between them.

The application is a three EKS cluster e-commerce platform: a React frontend, a BFF, and a Payments service on the edge cluster; Catalog and Pricing services on Backend A; and a Cart service on Backend B. **The edge cluster showcases both controllers running side by side**: the ALB controller serves the frontend to the internet, while the VPC Lattice controller publishes Payments as a Lattice service consumed by the Cart service on Backend B during checkout. Every user interaction flows through the full architecture, so you can observe the Gateway API machinery in action at each layer.

**During deployment** you can watch in the AWS Console as Kubernetes resources trigger real infrastructure changes: applying a `Gateway` manifest creates an ALB or a VPC Lattice service (depending on the GatewayClass); applying an `HTTPRoute` creates listener rules and target groups that route traffic to your pods.

**Once deployed**, the frontend surfaces the VPC Lattice request headers on every API response. You can browse the product catalog, add items to cart, and process a payment while inspecting the Lattice metadata (source VPC, caller identity, request ID) flowing through each call. The live architecture diagram updates every 5 seconds to reflect actual service reachability.

## Architecture

![Architecture Diagram](docs/architecture.png)

## Prerequisites

### Tools

| Tool | Min. version | Download |
|------|-------------|---------|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2.x | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| [Terraform](https://developer.hashicorp.com/terraform/install) | v1.9 | [Install guide](https://developer.hashicorp.com/terraform/install) |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.28 | [Install guide](https://kubernetes.io/docs/tasks/tools/) |
| [Helm](https://helm.sh/docs/intro/install/) | v3.x | [Install guide](https://helm.sh/docs/intro/install/) |
| [Docker](https://docs.docker.com/get-started/get-docker/) | v24.x | [Install guide](https://docs.docker.com/get-started/get-docker/) |

### AWS Account

The following AWS resources are created by this sample. Ensure your account has sufficient service quotas and your IAM principal has permissions to create them.

| Service | Resources created |
|---------|------------------|
| Amazon VPC | 3 VPCs, public/private subnets, NAT gateways, internet gateways |
| Amazon EKS | 3 clusters (Auto Mode), IAM roles for control plane and nodes |
| Amazon ECR | 6 repositories (frontend, bff, catalog, pricing, cart, payments) |
| Amazon VPC Lattice | 1 service network, 3 services (items, cart, payments), target groups, IAM auth policies |
| Elastic Load Balancing | 1 Application Load Balancer |
| AWS WAF | 1 WebACL with managed rule groups |
| AWS IAM | Cluster roles, node roles, Pod Identity roles and associations |
| Amazon Route 53 | 1 private hosted zone; records in your existing public hosted zone |
| Amazon CloudWatch | Log groups for VPC Lattice access logs |

### Required Configuration

Before deploying, copy `infra/terraform.tfvars.example` to `infra/terraform.tfvars` and fill in your values.

**Always required:**

| Variable | Description |
|----------|-------------|
| `aws_region` | AWS region for deployment |
| `private_hosted_zone_name` | Domain name for the Route 53 private hosted zone used for VPC Lattice service discovery. Always required because VPC Lattice services use custom domain names regardless of protocol. |

**Protocol selection (both default to `HTTPS`):**

| Variable | Values | Description |
|----------|--------|-------------|
| `alb_protocol` | `HTTP` or `HTTPS` | Protocol for the frontend ALB listener |
| `vpclattice_protocol` | `HTTP` or `HTTPS` | Protocol for the VPC Lattice service listeners |

**Required when `alb_protocol = HTTPS`:**

| Variable | Description |
|----------|-------------|
| `alb_certificate_arn` | ACM certificate ARN for the ALB HTTPS listener. Must be in the same region and cover the frontend domain (e.g. `*.app.example.com`). |
| `public_hosted_zone_id` | Route 53 public hosted zone ID. ExternalDNS writes the ALB's A/AAAA records here. The zone must already exist. |
| `frontend_domain_name` | Custom domain name for the frontend (e.g. `frontend.app.example.com`). |

**Required when `vpclattice_protocol = HTTPS`:**

| Variable | Description |
|----------|-------------|
| `vpclattice_certificate_arn` | ACM certificate ARN for VPC Lattice HTTPS listeners. Can be the same certificate as `alb_certificate_arn` if it covers both domains. |

> **HTTPS is recommended for production environments.** Both protocols can be set independently. For a fully certificate-free test environment, set both to `HTTP`; only `aws_region` and `private_hosted_zone_name` are required.

## Quick deploy

If you want everything running with a single command:

### 1. Configure

Edit `infra/terraform.tfvars` with your values (copy from `infra/terraform.tfvars.example`):

```hcl
aws_region                 = "eu-west-1"
alb_protocol               = "HTTPS"
alb_certificate_arn        = "arn:aws:acm:eu-west-1:123456789012:certificate/..."
vpclattice_protocol        = "HTTPS"
vpclattice_certificate_arn = "arn:aws:acm:eu-west-1:123456789012:certificate/..."
private_hosted_zone_name   = "app.example.com"
public_hosted_zone_id      = "Z04005..."
frontend_domain_name       = "frontend.app.example.com"
```

For a fully HTTP test environment (no certificates or custom domain required):

```hcl
aws_region               = "eu-west-1"
alb_protocol             = "HTTP"
vpclattice_protocol      = "HTTP"
private_hosted_zone_name = "app.example.com"
```

### 2. Deploy

```bash
./manage.sh deploy
```

Runs all six steps: ECR repos, container images, Terraform infrastructure, cluster configuration, application deployment, and networking. Takes roughly 25-30 minutes end to end.

### 3. Tear down

```bash
./manage.sh teardown
```

Reverses everything in order. Safe to run at any deployment stage.

---

## Recommended Deployment

The recommended path deploys everything up to the application services first, then walks you through the networking resources one step at a time so you can watch the ALB and VPC Lattice resources appear in the AWS Console as you apply each manifest.

### Step 1: Infrastructure, clusters, and application services

```bash
./manage.sh deploy-apps
```

This runs steps 1-5: ECR repos, container images, Terraform (VPCs, EKS clusters, IAM, VPC Lattice service network, WAF, Route 53), cluster configuration (Gateway API controllers, ExternalDNS), and all application services deployed to their respective clusters. At this point the services are running but not yet reachable since no ALB or VPC Lattice services exist yet.

Once complete, verify the services are up on each cluster:

```bash
# Edge cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-edge-cluster
kubectl get pods   # frontend, bff, and payments pods should be Running

# Backend A cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-a-cluster
kubectl get pods   # catalog and pricing pods should be Running

# Backend B cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-b-cluster
kubectl get pods   # cart pods should be Running
```

See [Cluster Configuration](docs/cluster-configuration.md) for details on what gets installed on each cluster and why, and [Application Services](docs/application-services.md) for details on each service and the BFF pattern.

### Step 2: Create the ALB (north-south)

Switch to the edge cluster and apply the ALB Gateway resources:

```bash
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-edge-cluster

kubectl apply -f k8s/applications/frontend/alb-gateway.yaml
```

Watch the Gateway status in Kubernetes:

```bash
kubectl get gateway frontend-gateway -w
# Wait for PROGRAMMED = True and an ADDRESS to appear
```

While that runs, open the AWS Console and observe the resources being created:

- [EC2 > Load Balancers](https://console.aws.amazon.com/ec2/home#LoadBalancers): the ALB appears with two listeners (HTTP:80, HTTPS:443)
- [EC2 > Target Groups](https://console.aws.amazon.com/ec2/home#TargetGroups): a target group is created and the frontend pod IPs are registered
- [WAF > Web ACLs](https://console.aws.amazon.com/wafv2/homev2/web-acls): the WebACL is associated with the ALB

The AWS Load Balancer Controller translated a `Gateway` and `HTTPRoute` into a fully configured ALB with listeners, target groups, WAF association, and certificate, all from standard Kubernetes objects.

Once the Gateway shows an address and the ALB is live, you can already open `https://<your-frontend-domain>` in a browser. The frontend will load and the architecture diagram will show the frontend service as reachable (green). The backend services will show as unreachable (red) since the VPC Lattice services don't exist yet. This is intentional: it lets you see the diagram update in real time as you complete the next steps.

See [Gateway API Controllers](docs/gateway-api.md#edge-cluster-aws-load-balancer-controller) for the full resource breakdown and manifest details.

### Step 3: Create the VPC Lattice services (east-west)

Switch to Backend A and apply the items VPC Lattice resources:

```bash
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-a-cluster

kubectl apply -f k8s/applications/items/vpc-lattice.yaml
```

Watch the HTTPRoute status:

```bash
kubectl get httproute items-route -w
# Wait for the application-networking.k8s.aws/lattice-service-arn annotation to appear
```

While that runs, open the AWS Console and observe:

- [VPC Lattice > Services](https://console.aws.amazon.com/vpc/home#Services): the items service appears and gets associated with the service network
- [VPC Lattice > Target Groups](https://console.aws.amazon.com/vpc/home#TargetGroups): two target groups are created (one for catalog, one for pricing) with pod IPs registered
- [VPC Lattice > Services > Listeners](https://console.aws.amazon.com/vpc/home#Services): an HTTPS:443 listener with header based routing rules (`x-service: catalog` routes to the catalog target group, `x-service: pricing` routes to the pricing target group)

Now do the same for Backend B (cart) and the edge cluster (payments):

```bash
# Backend B: Cart service
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-b-cluster
kubectl apply -f k8s/applications/cart/vpc-lattice.yaml
kubectl get httproute cart-route -w

# Edge: Payments service
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-edge-cluster
kubectl apply -f k8s/applications/payments/vpc-lattice.yaml
kubectl get httproute payments-route -w
```

The VPC Lattice Gateway API Controller translated the same `Gateway` and `HTTPRoute` resources into VPC Lattice services with no routable network required between the clusters.

ExternalDNS will create the private DNS records automatically within about 1 minute. You can verify:

```bash
# VPC Lattice CNAMEs in the private hosted zone
aws route53 list-resource-record-sets --hosted-zone-id <private-hz-id> \
  --query "ResourceRecordSets[?contains(Name,'items') || contains(Name,'cart') || contains(Name,'payments')]"
```

Once the records exist, go back to the frontend. The architecture diagram will update as each service becomes reachable: catalog and pricing turn green once the items service is ready on Backend A, cart turns green once Backend B is done, and payments turns green once the edge VPC Lattice service is ready. You can now use the full application:

- **Browse the catalog**: the frontend calls the BFF, which calls the catalog and pricing services through VPC Lattice with header based routing
- **Add items to cart**: each add triggers a SigV4 signed request to the cart service through VPC Lattice
- **Checkout**: the BFF calls the cart checkout endpoint through VPC Lattice, which in turn calls the payments service on the edge cluster through a second VPC Lattice hop

On every API response, click the VPC Lattice headers button to see the raw headers attached to the request: source VPC, caller identity ARN, request ID, and more. During checkout, you can see headers from both hops (cart and payments), showing how the caller identity changes between the BFF and the cart service.

See [Gateway API Controllers](docs/gateway-api.md#backend-clusters-vpc-lattice-gateway-api-controller) for the full resource breakdown.

## Deep dives

| Topic | What you'll learn |
|-------|-------------------|
| [Architecture Overview](docs/architecture.md) | The full infrastructure layout: VPCs, clusters, VPC Lattice service network, WAF, Route 53, and the design decisions behind each component |
| [Gateway API Controllers](docs/gateway-api.md) | How both controllers coexist on the edge cluster (ALB + VPC Lattice from the same API), the Kubernetes resources they manage, VpcAssociationPolicy, IAMAuthPolicy, and header based routing |
| [Cluster Configuration](docs/cluster-configuration.md) | EKS Auto Mode, Graviton NodePools, Pod Identity, Helm chart installs (AWS LBC, VPC Lattice controller, ExternalDNS), and zone-scoped DNS management |
| [Application Services](docs/application-services.md) | The frontend + BFF pattern, SigV4 request signing, the shared items service with header routing, and end-to-end data flow |

## Repository Structure

```
.
├── manage.sh                          # Unified deploy/teardown script
├── infra/                             # Terraform: VPCs, EKS, IAM, VPC Lattice, WAF, Route 53
├── k8s/
│   ├── cluster-config/                # NodePools, GatewayClasses, service accounts
│   └── applications/                  # Deployments, services, ALB Gateway, VPC Lattice configs
├── app/
│   ├── frontend/                      # React + Vite + Tailwind
│   ├── bff/                           # FastAPI: orchestrates calls with SigV4
│   ├── catalog/                       # FastAPI: product catalog data
│   ├── pricing/                       # FastAPI: product pricing data
│   ├── cart/                          # FastAPI: shopping cart with checkout via VPC Lattice
│   └── payments/                      # FastAPI: payment processing
└── docs/                              # Deep-dive documentation
```

## Related Resources

- [Kubernetes Gateway API Specification](https://gateway-api.sigs.k8s.io/)
- [AWS Load Balancer Gateway API Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/gateway/gateway/)
- [Amazon VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/)
- [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.
