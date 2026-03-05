# Part 1: Setting Up Edge Cluster with AWS Load Balancer Controller

This week, I decided to build a multi-cluster application networking setup using Kubernetes Gateway API. I wanted to see how AWS Load Balancer Controller and VPC Lattice could work together - one handling internet traffic, the other handling service-to-service communication.

Spoiler alert: I felt like a complete noob at times (I didn't even know how to check if pods were running in EKS Auto Mode!), but I learned a ton. This guide includes all the steps I took, the mistakes I made, and how I fixed them.

## What We're Building

In this part, we'll set up the **edge cluster** that receives internet traffic via an Application Load Balancer. This cluster will host our `shop.api.example.com` service.

```
Internet → ALB (HTTPS) → shop.api.example.com (edge-eks cluster)
```

Later, this shop service will call internal services via VPC Lattice, but let's start with getting the ALB working first.

## Prerequisites Check

Before we start, let's make sure you have everything installed. Run these commands:

```bash
# Check AWS CLI
aws --version
# Should show: aws-cli/2.x.x or later

# Check kubectl
kubectl version --client
# Should show: v1.28 or later

# Check helm
helm version
# Should show: v3.x or later

# Check eksctl
eksctl version
# Should show: 0.150.0 or later

# Check jq
jq --version
# Should show: jq-1.x or later
```

If any of these fail, install them first. Links are in the main README.

## Step 1: Create or Access Your EKS Cluster

I'm using **EKS Auto Mode** for this walkthrough. If you already have a cluster, skip to Step 2.

### Create a new cluster (optional)

```bash
# Set your region and cluster name
export AWS_REGION=us-west-2
export CLUSTER_NAME=edge-eks

# Create the cluster
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --auto-mode
```

This takes about 10-15 minutes. Grab a coffee ☕

### Configure kubectl access

```bash
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
```

### Verify access

```bash
kubectl get nodes
```

**What I saw:**
```
No resources found
```

**Wait, what?** I panicked for a second. Then I remembered - EKS Auto Mode creates nodes on-demand when you deploy workloads. So this is actually normal! 

Let's verify the cluster is healthy:

```bash
kubectl get pods -A
```

You should see system pods running in `kube-system` namespace.

## Step 2: Install Gateway API CRDs

Gateway API is a separate project from Kubernetes core, so we need to install the Custom Resource Definitions (CRDs) first.

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
```

**Expected output:**
```
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io created
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io created
...
```

Verify they're installed:

```bash
kubectl get crd | grep gateway
```

You should see `gatewayclasses`, `gateways`, `httproutes`, etc.

## Step 3: Install AWS Load Balancer Controller CRDs

The AWS LBC has its own CRDs for AWS-specific configurations:

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml
```

## Step 4: Set Up IAM Permissions

The controller needs AWS permissions to create load balancers. This was one of the trickier parts for me.

### Create the IAM policy

```bash
# Download the policy document
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Create the policy
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json
```

**Note:** If you get an error saying the policy already exists, that's fine! Just note the ARN from the error message or list it:

```bash
aws iam list-policies --query 'Policies[?PolicyName==`AWSLoadBalancerControllerIAMPolicy`].Arn' --output text
```

Save this ARN - you'll need it in the next step.

### Associate IAM OIDC provider

This allows Kubernetes service accounts to assume IAM roles:

```bash
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster $CLUSTER_NAME \
  --approve
```

### Create service account with IAM role

```bash
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} \
  --attach-policy-arn arn:aws:iam::<YOUR_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve
```

**Replace `<YOUR_ACCOUNT_ID>`** with your actual AWS account ID.

Verify the service account was created:

```bash
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml
```

Look for the annotation:
```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/AmazonEKSLoadBalancerControllerRole-edge-eks
```

## Step 5: Install AWS Load Balancer Controller

Now for the main event! We'll use Helm to install the controller.

### Get your VPC ID

For EKS Auto Mode (or any environment where IMDS might not be reachable), we need to explicitly set the VPC ID:

```bash
export VPC_ID=$(aws eks describe-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

echo $VPC_ID
```

### Install via Helm

```bash
# Add the EKS charts repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set controllerConfig.featureGates="ALBGatewayAPI=true,NLBGatewayAPI=true"
```

**The important part:** `controllerConfig.featureGates="ALBGatewayAPI=true"` - this enables Gateway API support!

### Verify the controller is running

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

**Expected output:**
```
NAME                                            READY   STATUS    RESTARTS   AGE
aws-load-balancer-controller-5d7f9c8b6d-abc12  1/1     Running   0          2m
```

**Troubleshooting:** If the pod is in `CrashLoopBackOff`, check the logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Common issues:
- IAM permissions not set correctly
- VPC ID not set (for EKS Auto Mode)
- Service account annotation missing

## Step 6: Create a Certificate in ACM

For HTTPS, we need a certificate. I'm using a private certificate from ACM Private CA for this demo.

**Note:** If you have a public domain, you can use a public certificate instead. The configuration is the same.

### Create a private certificate (if you don't have one)

```bash
# This assumes you have ACM Private CA set up
# If not, you can create a self-signed cert for testing

# For testing, create a self-signed cert
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout shop-tls.key \
  -out shop-tls.crt \
  -subj "/CN=shop.api.example.com"

# Import to ACM
aws acm import-certificate \
  --certificate fileb://shop-tls.crt \
  --private-key fileb://shop-tls.key \
  --region $AWS_REGION
```

**Save the certificate ARN** from the output - you'll need it!

## Step 7: Deploy the Shop Application

Create a namespace:

```bash
kubectl create namespace eks-gateway-demo
```

Apply the manifests:

```bash
kubectl apply -f manifests/edge-cluster/01-shop-deployment.yaml
kubectl apply -f manifests/edge-cluster/02-shop-service.yaml
```

**Check if pods are running:**

```bash
kubectl get pods -n eks-gateway-demo
```

**What I saw the first time:**
```
NAME                    READY   STATUS    RESTARTS   AGE
shop-7d8f9c5b6d-abc12   0/1     Pending   0          30s
```

**Pending?** Don't panic! In EKS Auto Mode, nodes are created on-demand. Wait a minute or two and check again:

```bash
kubectl get pods -n eks-gateway-demo -w
```

The `-w` flag watches for changes. You should see:
```
NAME                    READY   STATUS              RESTARTS   AGE
shop-7d8f9c5b6d-abc12   0/1     ContainerCreating   0          1m
shop-7d8f9c5b6d-abc12   1/1     Running             0          2m
```

**Pro tip:** If it stays in Pending for more than 5 minutes, check events:
```bash
kubectl describe pod shop-7d8f9c5b6d-abc12 -n eks-gateway-demo
```

## Step 8: Create Gateway API Resources

Now for the exciting part - creating the Gateway and HTTPRoute!

### Create GatewayClass

```bash
kubectl apply -f manifests/edge-cluster/03-alb-gatewayclass.yaml
```

Verify:
```bash
kubectl get gatewayclass
```

**Expected output:**
```
NAME      CONTROLLER              ACCEPTED   AGE
aws-alb   eks.amazonaws.com/alb   True       10s
```

**Important:** `ACCEPTED` should be `True`. If it's `False`, the controller isn't recognizing it.

### Create Gateway

First, we need to create a Kubernetes secret with our certificate:

```bash
# If you imported to ACM, the controller will auto-discover it by hostname
# But for this example, let's be explicit

kubectl create secret tls shop-tls-cert \
  --cert=shop-tls.crt \
  --key=shop-tls.key \
  -n eks-gateway-demo
```

Now create the Gateway:

```bash
kubectl apply -f manifests/edge-cluster/04-alb-gateway.yaml
```

**Check the status:**

```bash
kubectl get gateway shop-gateway -n eks-gateway-demo
```

**What you'll see initially:**
```
NAME            CLASS     ADDRESS   PROGRAMMED   AGE
shop-gateway    aws-alb             Unknown      10s
```

Wait a minute or two (ALB creation takes time), then check again:

```bash
kubectl get gateway shop-gateway -n eks-gateway-demo -w
```

**After a few minutes:**
```
NAME            CLASS     ADDRESS                                                                  PROGRAMMED   AGE
shop-gateway    aws-alb   k8s-eksgatewaydemo-shopgateway-abc123.us-west-2.elb.amazonaws.com      True         3m
```

**🎉 Success!** The `PROGRAMMED` status is `True` and you have an ALB DNS name!

**Troubleshooting:** If it stays `Unknown` or `False`:

```bash
kubectl describe gateway shop-gateway -n eks-gateway-demo
```

Look at the `Status` section for error messages. Common issues:
- Subnet tags missing (need `kubernetes.io/role/elb=1` on public subnets)
- IAM permissions missing
- Certificate not found

### Create HTTPRoute

```bash
kubectl apply -f manifests/edge-cluster/05-alb-httproute.yaml
```

**Check the status:**

```bash
kubectl get httproute shop-route -n eks-gateway-demo
```

**Describe it for details:**

```bash
kubectl describe httproute shop-route -n eks-gateway-demo
```

Look for:
```
Status:
  Parents:
    Conditions:
      Type:    Accepted
      Status:  True
```

## Step 9: Test It!

Get the ALB hostname:

```bash
ALB_HOSTNAME=$(kubectl get gateway shop-gateway -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}')
echo $ALB_HOSTNAME
```

Test with curl:

```bash
curl -k https://$ALB_HOSTNAME -H "Host: shop.api.example.com"
```

**Expected output:**
```
Hello from shop.api.example.com - I can call payments and inventory!
```

**🎉 It works!**

**Note:** We're using `-k` to skip certificate verification since we're using a self-signed cert. In production, use a proper certificate!

## What We Built

Let's recap what we just created:

1. **EKS Cluster** (edge-eks) with Auto Mode
2. **AWS Load Balancer Controller** with Gateway API support
3. **GatewayClass** defining ALB as the implementation
4. **Gateway** creating an actual Application Load Balancer
5. **HTTPRoute** routing traffic to our shop service
6. **Shop application** running in pods

The cool part? We used standard Kubernetes Gateway API resources, not AWS-specific annotations!

## Next Steps

In [Part 2](./PART2-APPS-CLUSTERS.md), we'll set up the internal services (payments and inventory) using VPC Lattice Gateway API Controller. Then in [Part 3](./PART3-INTEGRATION.md), we'll connect everything together so the shop service can call the internal services.

## Common Issues I Hit

### Issue 1: Pods stuck in Pending
**Solution:** Wait for EKS Auto Mode to create nodes. Takes 2-3 minutes.

### Issue 2: Gateway not programmed
**Solution:** Check subnet tags. Public subnets need `kubernetes.io/role/elb=1`.

### Issue 3: Controller in CrashLoopBackOff
**Solution:** Set `vpcId` explicitly in Helm values for EKS Auto Mode.

### Issue 4: Certificate not found
**Solution:** Make sure certificate is in the same region as your cluster.

## Useful Commands I Learned

```bash
# Watch pods until they're running
kubectl get pods -n eks-gateway-demo -w

# Check controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Get all Gateway API resources
kubectl get gateway,httproute,gatewayclass -A

# Describe for detailed status
kubectl describe gateway <name> -n <namespace>
```

Remember: Everyone feels like a noob when learning new tech. The key is knowing how to debug! 🚀

---

**Next:** [Part 2 - Setting Up Apps Clusters with VPC Lattice](./PART2-APPS-CLUSTERS.md)
