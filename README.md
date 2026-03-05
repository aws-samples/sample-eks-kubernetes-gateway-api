# Streamline Amazon EKS Application Networking with Gateway API

A hands-on sample showing how to use the Kubernetes Gateway API to handle both internet-facing traffic and cross-cluster service communication on [Amazon EKS](https://aws.amazon.com/eks/).

## What this sample shows

The [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) provides a unified, portable interface for managing traffic routing. This project demonstrates how two AWS controllers implement that same API for very different purposes:

- **North-South traffic.** The [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) implements the Gateway API to manage internet-facing [Elastic Load Balancers](https://aws.amazon.com/es/elasticloadbalancing/) for external ingress.
- **East-West traffic.** The [Amazon VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/) implements the same Gateway API to connect services across clusters and VPCs through [Amazon VPC Lattice](https://aws.amazon.com/vpc/lattice/), removing the need for a routable network between them.

The application is a three-EKS cluster e-commerce platform: a React frontend and a BFF service on the frontend cluster, cart and inventory services on Backend-A, and a payments service on Backend-B. Every user interaction flows through the full architecture, so you can observe the Gateway API machinery in action at each layer.

**During deployment** you can watch in the AWS Console as Kubernetes resources trigger real infrastructure changes: applying a `Gateway` manifest creates an ALB with listeners and target groups; applying a VPC Lattice `HTTPRoute` creates a VPC Lattice service, registers pod IPs as targets, and associates the service with the service network.

**Once deployed**, the frontend surfaces the VPC Lattice request headers on every API response. You can browse the product catalog, add items to cart, and process a payment while inspecting the Lattice metadata (source VPC, caller identity, request ID) flowing through each call. The live architecture diagram updates every 5 seconds to reflect actual service reachability.

## Architecture

```
                        Internet
                           │
                     ┌─────┴─────┐
                     │  AWS WAF  │
                     └─────┬─────┘
                           │
                     ┌─────┴─────┐
                     │    ALB    │  ← Gateway API (AWS LBC)
                     └─────┬─────┘
                           │
              ┌────────────┴────────────┐
              │   Frontend EKS Cluster   │
              │  ┌──────────┬─────────┐ │
              │  │ Frontend │   BFF   │ │
              │  └──────────┴────┬────┘ │
              └──────────────────┼──────┘
                                 │ SigV4-signed requests
                    ┌────────────┴────────────┐
                    │  VPC Lattice Service     │  ← Gateway API (VPC Lattice Controller)
                    │       Network            │
                    └──┬─────────────────┬─────┘
                       │                 │
          ┌────────────┴──────┐  ┌───────┴────────────┐
          │ Backend-A Cluster │  │ Backend-B Cluster   │
          │ ┌──────┬────────┐│  │ ┌────────────────┐  │
          │ │ Cart │Inventory││  │ │    Payments    │  │
          │ └──────┴────────┘│  │ └────────────────┘  │
          └───────────────────┘  └─────────────────────┘
```

## Prerequisites

### Tools

| Tool | Min. version | Download |
|------|-------------|---------|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) | v2.x | [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) |
| [Terraform](https://developer.hashicorp.com/terraform/install) | v1.5.0 | [Install guide](https://developer.hashicorp.com/terraform/install) |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | v1.28 | [Install guide](https://kubernetes.io/docs/tasks/tools/) |
| [Helm](https://helm.sh/docs/intro/install/) | v3.x | [Install guide](https://helm.sh/docs/intro/install/) |
| [Docker](https://docs.docker.com/get-started/get-docker/) | v24.x | [Install guide](https://docs.docker.com/get-started/get-docker/) |

### AWS Account

The following AWS resources are created by this sample. Ensure your account has sufficient service quotas and your IAM principal has permissions to create them.

| Service | Resources created |
|---------|------------------|
| Amazon VPC | 3 VPCs, public/private subnets, NAT gateways, internet gateways |
| Amazon EKS | 3 clusters (Auto Mode), IAM roles for control plane and nodes |
| Amazon ECR | 5 repositories (frontend, bff, cart-service, inventory-service, payments-service) |
| Amazon VPC Lattice | 1 service network, 2 services (items, payments), target groups, IAM auth policies |
| Elastic Load Balancing | 1 Application Load Balancer |
| AWS WAF | 1 WebACL with managed rule groups |
| AWS IAM | Cluster roles, node roles, Pod Identity roles and associations |
| Amazon Route 53 | 1 private hosted zone; records in your existing public hosted zone |
| Amazon CloudWatch | Log groups for VPC Lattice access logs |

### Required Configuration

Before deploying, you need two AWS resources that must exist in your account:

| Variable | Description | Why it's needed |
|----------|-------------|-----------------|
| `alb_protocol` | `HTTP` or `HTTPS` (default: `HTTPS`) | Controls whether the ALB listener uses HTTP or HTTPS. |
| `alb_certificate_arn` | ARN of an ACM certificate covering your domain. Required when `alb_protocol = HTTPS`. | The ALB HTTPS listener uses this certificate for TLS termination. Must be in the same region as the deployment and cover the frontend domain (e.g. `*.app.example.com` or `frontend.app.example.com`). |
| `vpclattice_protocol` | `HTTP` or `HTTPS` (default: `HTTPS`) | Controls whether the VPC Lattice service listeners use HTTP or HTTPS. The custom domain name is always used regardless of protocol. |
| `vpclattice_certificate_arn` | ARN of an ACM certificate for VPC Lattice service listeners. Required when `vpclattice_protocol = HTTPS`. | Used for TLS termination on the VPC Lattice backend listeners. Can be the same certificate as `alb_certificate_arn` if it covers both domains. |
| `public_hosted_zone_id` | Route 53 public hosted zone ID for your domain. Required when `alb_protocol = HTTPS`. | ExternalDNS writes the ALB's A/AAAA records here so the frontend domain resolves publicly. The zone must already exist; this sample does not create it. Not needed for HTTP mode since the user accesses the app via the raw ALB DNS name. |
| `frontend_domain_name` | Custom domain name for the frontend (e.g. `frontend.app.example.com`). Required when `alb_protocol = HTTPS`. | Used in the HTTPRoute hostname and by ExternalDNS to create the DNS record. Not needed for HTTP mode. |

> **HTTPS is recommended for production environments.** Both `alb_protocol` and `vpclattice_protocol` can be set independently. Setting either to `HTTP` means traffic on that path is unencrypted: `alb_protocol = HTTP` exposes the frontend over plain HTTP (no custom domain needed, user accesses via the raw ALB DNS name); `vpclattice_protocol = HTTP` means traffic between the BFF and the backend services is unencrypted. For a fully certificate-free test environment, set both to `HTTP` — no ACM certificates or custom domain are required, only `private_hosted_zone_name` for VPC Lattice service discovery.

## Quick deploy

If you want everything running with a single command:

### 1. Configure

Edit `infra/terraform.tfvars` with your values:

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
# Frontend cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-frontend-cluster
kubectl get pods   # frontend and bff pods should be Running

# Backend-A cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-a-cluster
kubectl get pods   # cart-service and inventory-service pods should be Running

# Backend-B cluster
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-b-cluster
kubectl get pods   # payments-service pods should be Running
```

See [Cluster Configuration](docs/cluster-configuration.md) for details on what gets installed on each cluster and why, and [Application Services](docs/application-services.md) for details on each service and the BFF pattern.

### Step 2: Create the ALB (north-south)

Switch to the frontend cluster and apply the ALB Gateway resources:

```bash
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-frontend-cluster

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

See [Gateway API Controllers](docs/gateway-api.md#frontend-cluster-aws-load-balancer-controller) for the full resource breakdown and manifest details.

### Step 3: Create the VPC Lattice services (east-west)

Switch to Backend-A and apply the items VPC Lattice resources:

```bash
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-a-cluster

kubectl apply -f k8s/applications/cart-inventory-services/vpc-lattice.yaml
```

Watch the HTTPRoute status:

```bash
kubectl get httproute items-service-route -w
# Wait for the application-networking.k8s.aws/lattice-service-arn annotation to appear
```

While that runs, open the AWS Console and observe:

- [VPC Lattice > Services](https://console.aws.amazon.com/vpc/home#Services): the items service appears and gets associated with the service network
- [VPC Lattice > Target Groups](https://console.aws.amazon.com/vpc/home#TargetGroups): two target groups are created (one for cart, one for inventory) with pod IPs registered
- [VPC Lattice > Services > Listeners](https://console.aws.amazon.com/vpc/home#Services): an HTTPS:443 listener with header-based routing rules (`x-service: cart` routes to the cart target group, `x-service: inventory` routes to the inventory target group)

Now do the same for Backend-B:

```bash
aws eks update-kubeconfig --region <region> --name eks-gateway-demo-backend-b-cluster

kubectl apply -f k8s/applications/payments-service/vpc-lattice.yaml

kubectl get httproute payments-service-route -w
# Wait for the lattice-service-arn annotation to appear
```

The VPC Lattice Gateway API Controller translated the same `Gateway` and `HTTPRoute` resources into a VPC Lattice service with no routable network required between the clusters.

ExternalDNS will create the private DNS records automatically within about 1 minute. You can verify:

```bash
# VPC Lattice CNAMEs in the private hosted zone
aws route53 list-resource-record-sets --hosted-zone-id <private-hz-id> \
  --query "ResourceRecordSets[?contains(Name,'items') || contains(Name,'payments')]"
```

Once the records exist, go back to the frontend. The architecture diagram will update as each service becomes reachable: cart and inventory turn green once the items service is ready on Backend-A, and payments turns green once Backend-B is done. You can now use the full application:

- **Browse the catalog**: the frontend calls the BFF, which calls the inventory service through VPC Lattice
- **Add items to cart**: each add triggers a SigV4-signed request to the cart service through the same VPC Lattice service, routed by the `x-service: cart` header
- **Process a payment**: the BFF calls the payments service on Backend-B through a separate VPC Lattice service

On every API response, click the service panel in the UI to see the raw VPC Lattice headers attached to the request: source VPC, caller identity ARN, request ID, and more. These headers are what VPC Lattice injects on every authenticated call, and they confirm the full path the request took through the architecture.

See [Gateway API Controllers](docs/gateway-api.md#backend-clusters-vpc-lattice-gateway-api-controller) for the full resource breakdown.

## Deep dives

| Topic | What you'll learn |
|-------|-------------------|
| [Architecture Overview](docs/architecture.md) | The full infrastructure layout: VPCs, clusters, VPC Lattice service network, WAF, Route 53, and the design decisions behind each component |
| [Gateway API Controllers](docs/gateway-api.md) | How the two controllers work, the Kubernetes resources they manage (GatewayClass, Gateway, HTTPRoute), VpcAssociationPolicy, IAMAuthPolicy, and header-based routing |
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
│   ├── cart-service/                  # FastAPI: in-memory shopping cart
│   ├── inventory-service/             # FastAPI: product catalog
│   └── payments-service/              # FastAPI: payment processing
└── docs/                              # Deep-dive documentation
```

## Related Resources

- [Kubernetes Gateway API Specification](https://gateway-api.sigs.k8s.io/)
- [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
- [Amazon VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/)
- [EKS Auto Mode](https://docs.aws.amazon.com/eks/latest/userguide/automode.html)
- [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)

## License

This sample code is made available under the MIT-0 license. See the LICENSE file.
