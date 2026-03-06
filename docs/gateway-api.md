# Gateway API Controllers

This document explains how the two [Gateway API](https://gateway-api.sigs.k8s.io/) controllers work, what AWS resources each Kubernetes manifest creates, and why the configuration is structured the way it is.

## The Gateway API Model

[Gateway API](https://gateway-api.sigs.k8s.io/) is a Kubernetes-native networking API designed to replace Ingress. It uses a layered resource model where each layer has a clear owner and responsibility:

- **[GatewayClass](https://gateway-api.sigs.k8s.io/api-types/gatewayclass/)**: A cluster-scoped resource that names a controller implementation. Think of it like a StorageClass; it declares "this controller handles Gateways of this type." Typically created once by a cluster operator.
- **[Gateway](https://gateway-api.sigs.k8s.io/api-types/gateway/)**: Declares a piece of network infrastructure and its listeners. The controller watching the GatewayClass provisions the actual AWS resource (an ALB, a VPC Lattice service) when a Gateway is created.
- **[HTTPRoute](https://gateway-api.sigs.k8s.io/api-types/httproute/)**: Defines routing rules and attaches to a Gateway via `parentRefs`. Application teams own this resource; they describe how traffic should be routed to their services without knowing anything about the underlying infrastructure.

The separation is intentional: infrastructure teams manage GatewayClass and Gateway, application teams manage HTTPRoute. The same HTTPRoute spec works regardless of whether the Gateway is backed by an ALB or a VPC Lattice service.

### API versions

You'll notice two different API groups in the manifests:

- `gateway.networking.k8s.io/v1`: The upstream [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/) group. Resources like `GatewayClass`, `Gateway`, and `HTTPRoute` graduated to `v1` (GA) in Gateway API v1.0 and are stable.
- `gateway.k8s.aws/v1beta1`: The AWS LBC's own extension group for AWS-specific resources (`LoadBalancerConfiguration`, `TargetGroupConfiguration`). Still in beta as the LBC's Gateway API implementation evolves.
- `application-networking.k8s.aws/v1alpha1`: The VPC Lattice controller's extension group (`IAMAuthPolicy`, `TargetGroupPolicy`, `VpcAssociationPolicy`, `AccessLogPolicy`). Alpha because the VPC Lattice controller is newer and these CRDs are still maturing.

The rule of thumb: upstream Gateway API resources are `v1`, AWS-specific extensions are `v1beta1` or `v1alpha1` depending on how mature that controller's implementation is.

## Frontend Cluster: AWS Load Balancer Controller

The frontend cluster uses the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) to provision an internet-facing ALB. The LBC watches for `Gateway` resources referencing the `aws-alb` GatewayClass and translates them into ALB API calls.

### GatewayClass

`k8s/cluster-config/gatewayclass-alb.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: aws-alb
spec:
  controllerName: gateway.k8s.aws/alb
```

The `controllerName` field is how Kubernetes knows which controller to notify. The LBC registers itself as the handler for `gateway.k8s.aws/alb` at startup. Any `Gateway` that references `gatewayClassName: aws-alb` will be picked up by the LBC.

### Gateway and LoadBalancerConfiguration

`k8s/applications/frontend/alb-gateway-https.yaml` (HTTPS mode) or `k8s/applications/frontend/alb-gateway-http.yaml` (HTTP mode)

> **HTTPS is recommended for production environments.** HTTP mode is provided for convenience when evaluating the sample without a custom domain or certificate. In HTTP mode, traffic between the client and the ALB is unencrypted and the frontend is accessed via the raw ALB DNS name.

The `alb_protocol` variable in `infra/terraform.tfvars` controls which manifest the deployment script applies. Both variants always include WAF; the only differences are the listener configuration and the HTTPRoute hostname.

**HTTPS mode** (`alb-gateway-https.yaml`): the `LoadBalancerConfiguration` includes the ACM certificate on the HTTPS listener, the `Gateway` declares only the HTTPS (443) listener, and the `HTTPRoute` matches the custom domain name:

When the LBC sees a `Gateway`, it calls the [Elastic Load Balancing API](https://docs.aws.amazon.com/elasticloadbalancing/latest/APIReference/Welcome.html) to create an ALB. The `Gateway` spec declares the listeners:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: frontend-gateway
spec:
  gatewayClassName: aws-alb
  infrastructure:
    parametersRef:
      group: gateway.k8s.aws
      kind: LoadBalancerConfiguration
      name: frontend-alb-config
  listeners:
    - name: http
      protocol: HTTP
      port: 80
    - name: https
      protocol: HTTPS
      port: 443
```

AWS-specific settings that have no equivalent in the upstream Gateway API spec are configured via a `LoadBalancerConfiguration` resource, referenced from `infrastructure.parametersRef`. The LBC merges both: the `Gateway` declares what listeners exist, the `LoadBalancerConfiguration` declares how to configure the AWS-specific aspects of those listeners:

```yaml
apiVersion: gateway.k8s.aws/v1beta1
kind: LoadBalancerConfiguration
metadata:
  name: frontend-alb-config
spec:
  scheme: internet-facing
  wafV2:
    webACL: "<WAF_ACL_ARN>"
  listenerConfigurations:
    - protocolPort: HTTPS:443
      defaultCertificate: "<CERTIFICATE_ARN>"
```

What the LBC creates in AWS when this is applied:

- An internet-facing [Application Load Balancer](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/introduction.html) in the public subnets of the frontend VPC
- An HTTP listener on port 80
- An HTTPS listener on port 443 with the specified ACM certificate
- The [AWS WAF WebACL](https://docs.aws.amazon.com/waf/latest/developerguide/web-acl.html) associated with the ALB
- A DNS address populated in `gateway.status.addresses`, which ExternalDNS uses to create the Route 53 A/AAAA records

HTTP mode (`alb-gateway-http.yaml`): the `LoadBalancerConfiguration` includes only the WAF association (no `listenerConfigurations`), the `Gateway` declares only the HTTP (80) listener, and the `HTTPRoute` has no `hostnames` field so it matches all traffic. ExternalDNS has nothing to register since there is no custom domain; the user accesses the frontend via the raw ALB DNS name printed by the deployment script.

### HTTPRoute and TargetGroupConfiguration

`k8s/applications/frontend/alb-gateway.yaml`

The `HTTPRoute` defines the routing rules and creates the ALB target group:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: frontend-route
spec:
  hostnames:
    - "frontend.app.example.com"
  parentRefs:
    - name: frontend-gateway
      sectionName: https
  rules:
    - backendRefs:
        - name: frontend-service
          port: 80
```

The `parentRefs` field attaches this route to the `https` listener of `frontend-gateway`. The LBC creates an ALB listener rule that matches the hostname and forwards to a target group backed by the `frontend-service` endpoints.

A `TargetGroupConfiguration` sets the target type to `ip`, which is required for EKS Auto Mode pods (the LBC registers pod IPs directly rather than node IPs):

```yaml
apiVersion: gateway.k8s.aws/v1beta1
kind: TargetGroupConfiguration
metadata:
  name: frontend-tgc
spec:
  targetReference:
    kind: Service
    name: frontend-service
  defaultConfiguration:
    targetType: ip
```

## Backend Clusters: VPC Lattice Gateway API Controller

The backend clusters use the [Amazon VPC Lattice Gateway API Controller](https://www.gateway-api-controller.eks.aws.dev/) to create [VPC Lattice](https://aws.amazon.com/vpc/lattice/) services. The controller watches for `Gateway` and `HTTPRoute` resources referencing the `amazon-vpc-lattice` GatewayClass and translates them into VPC Lattice API calls.

### GatewayClass

`k8s/cluster-config/gatewayclass-vpc-lattice.yaml`

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: amazon-vpc-lattice
spec:
  controllerName: application-networking.k8s.aws/gateway-api-controller
```

### Gateway

`k8s/applications/cart-inventory-services/vpc-lattice-https.yaml` (HTTPS mode) or `k8s/applications/cart-inventory-services/vpc-lattice-http.yaml` (HTTP mode), and the equivalent files under `k8s/applications/payments-service/`

> **HTTPS is recommended for production environments.** HTTP mode is provided for convenience when evaluating the sample without certificates. The custom domain name is always used regardless of protocol; it is what enables the BFF to resolve the service via the private hosted zone.

The `vpclattice_protocol` variable in `infra/terraform.tfvars` controls which manifest the deployment script applies. Both variants include the `VpcAssociationPolicy`, `IAMAuthPolicy`, `TargetGroupPolicy`, and `AccessLogPolicy`; the only differences are the Gateway listener and the HTTPRoute `sectionName`.

**HTTPS mode** (`vpc-lattice-https.yaml`): the Gateway declares an HTTPS:443 listener with TLS termination using the ACM certificate passed via the `application-networking.k8s.aws/certificate-arn` listener option, and the HTTPRoute references `sectionName: https`.

**HTTP mode** (`vpc-lattice-http.yaml`): the Gateway declares an HTTP:80 listener with no TLS block, and the HTTPRoute references `sectionName: http`. No certificate is required.

When the controller sees a `Gateway`, it creates a [VPC Lattice service](https://docs.aws.amazon.com/vpc-lattice/latest/ug/services.html) and associates it with the service network. The Gateway name is used as the VPC Lattice service name, and the controller is installed with `--set=defaultServiceNetwork=<name>` so it knows which service network to associate with:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: <service-network-name>
spec:
  gatewayClassName: amazon-vpc-lattice
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        options:
          application-networking.k8s.aws/certificate-arn: "<CERTIFICATE_ARN>"
```

The `application-networking.k8s.aws/certificate-arn` annotation under `tls.options` is how the VPC Lattice controller receives the ACM certificate ARN. There is no equivalent of `LoadBalancerConfiguration` here, so controller-specific settings are passed as listener options.

What the controller creates in AWS when this is applied:

- A [VPC Lattice service](https://docs.aws.amazon.com/vpc-lattice/latest/ug/services.html) with an HTTPS:443 listener
- A [service-to-service-network association](https://docs.aws.amazon.com/vpc-lattice/latest/ug/service-network-associations.html) linking the service to the configured service network
- A VPC Lattice DNS name populated in `gateway.status.addresses`

### VpcAssociationPolicy: preventing unwanted VPC associations

`k8s/applications/cart-inventory-services/vpc-lattice-https.yaml` and `k8s/applications/payments-service/vpc-lattice-https.yaml` (and their `-http.yaml` equivalents)

By default, the controller also creates a [VPC-to-service-network association](https://docs.aws.amazon.com/vpc-lattice/latest/ug/service-network-associations.html) for the cluster's VPC. This is needed when the cluster consumes services from the network, but the backend clusters only serve traffic; they don't call other Lattice services.

A [`VpcAssociationPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/vpc-association-policy/) with `associateWithVpc: false` prevents this:

```yaml
apiVersion: application-networking.k8s.aws/v1alpha1
kind: VpcAssociationPolicy
metadata:
  name: disable-vpc-association
spec:
  targetRef:
    group: "gateway.networking.k8s.io"
    kind: Gateway
    name: <service-network-name>
  associateWithVpc: false
```

### HTTPRoute and target groups

`k8s/applications/cart-inventory-services/vpc-lattice-https.yaml` (items) and `k8s/applications/payments-service/vpc-lattice-https.yaml` (payments), and their `-http.yaml` equivalents

When the controller sees an `HTTPRoute`, it creates a [VPC Lattice target group](https://docs.aws.amazon.com/vpc-lattice/latest/ug/target-groups.html) for each `backendRef` and registers the pod IPs as targets. It also creates the listener rules on the VPC Lattice service.

The items service uses header-based routing to serve both cart and inventory from a single VPC Lattice service, reducing cost while keeping the backends independently deployable:

```yaml
spec:
  rules:
    - matches:
        - headers:
            - name: x-service
              value: cart
      backendRefs:
        - name: cart-service
          port: 8000
    - matches:
        - headers:
            - name: x-service
              value: inventory
      backendRefs:
        - name: inventory-service
          port: 8000
```

What the controller creates in AWS for this HTTPRoute:

- Two [VPC Lattice target groups](https://docs.aws.amazon.com/vpc-lattice/latest/ug/target-groups.html) (one for cart, one for inventory) with pod IPs registered as targets
- Two listener rules on the VPC Lattice service: `x-service: cart` forwards to the cart target group, `x-service: inventory` forwards to the inventory target group
- The VPC Lattice service ARN is written back to the HTTPRoute as an annotation (`application-networking.k8s.aws/lattice-service-arn`), which ExternalDNS uses to create the Route 53 CNAME record

The BFF adds the `x-service` header to each request before signing it with [SigV4](https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html).

### IAMAuthPolicy

`k8s/applications/cart-inventory-services/vpc-lattice-https.yaml` and `k8s/applications/payments-service/vpc-lattice-https.yaml` (and their `-http.yaml` equivalents)

Each HTTPRoute has an [`IAMAuthPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/iam-auth-policy/) that enforces [VPC Lattice IAM authentication](https://docs.aws.amazon.com/vpc-lattice/latest/ug/auth-policies.html) at the route level. The controller applies this as an auth policy on the VPC Lattice service:

```yaml
apiVersion: application-networking.k8s.aws/v1alpha1
kind: IAMAuthPolicy
metadata:
  name: items-service-auth
spec:
  targetRef:
    group: "gateway.networking.k8s.io"
    kind: HTTPRoute
    name: items-service-route
  policy: |
    {
      "Version": "2012-10-17",
      "Statement": [{
        "Effect": "Allow",
        "Principal": "*",
        "Resource": "*",
        "Condition": {
          "StringNotEqualsIgnoreCase": {
            "aws:PrincipalType": "anonymous"
          }
        },
        "Action": "*"
      }]
    }
```

This ensures only pods with valid AWS credentials (obtained via [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html)) can reach the backend services. Unsigned requests are rejected by VPC Lattice before reaching any target.

### TargetGroupPolicy and AccessLogPolicy

`k8s/applications/cart-inventory-services/vpc-lattice-https.yaml` and `k8s/applications/payments-service/vpc-lattice-https.yaml` (and their `-http.yaml` equivalents)

A [`TargetGroupPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/target-group-policy/) configures the health check settings on the VPC Lattice target group. Without this, VPC Lattice uses its default health check configuration, which may not match the service's actual health endpoint:

```yaml
apiVersion: application-networking.k8s.aws/v1alpha1
kind: TargetGroupPolicy
metadata:
  name: cart-service-tgp
spec:
  targetRef:
    kind: Service
    name: cart-service
  healthCheck:
    enabled: true
    path: "/health"
    port: 8000
    protocol: HTTP
```

An [`AccessLogPolicy`](https://www.gateway-api-controller.eks.aws.dev/latest/api-types/access-log-policy/) configures VPC Lattice to send access logs to a destination of your choice, enabling visibility into every request that flows through the service. VPC Lattice supports three log destinations:

- [Amazon CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/WhatIsCloudWatchLogs.html): use a log group ARN (`arn:aws:logs:...`)
- [Amazon S3](https://aws.amazon.com/s3/): use a bucket ARN (`arn:aws:s3:...`)
- [Amazon Kinesis Data Firehose](https://aws.amazon.com/kinesis/data-firehose/): use a delivery stream ARN (`arn:aws:firehose:...`)

This sample uses CloudWatch Logs. The `destinationArn` in the policy determines which destination receives the logs:

```yaml
apiVersion: application-networking.k8s.aws/v1alpha1
kind: AccessLogPolicy
metadata:
  name: items-service-access-logs
spec:
  destinationArn: "<CLOUDWATCH_LOG_GROUP_ARN>"
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: items-service-route
```

## Same API, different infrastructure

The frontend cluster's `HTTPRoute` and the backend clusters' `HTTPRoute` resources look nearly identical. The difference is the `GatewayClass`: one triggers the LBC to create an ALB with listener rules and target groups, the other triggers the VPC Lattice controller to create a Lattice service with listener rules and target groups. Application teams write the same routing rules regardless of the underlying infrastructure.
