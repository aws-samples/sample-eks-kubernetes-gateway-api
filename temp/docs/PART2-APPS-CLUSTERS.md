# Part 2: Setting Up Apps Clusters with VPC Lattice

In [Part 1](./PART1-EDGE-CLUSTER.md), we set up the edge cluster with an ALB for internet traffic. Now we're going to set up two internal clusters that will host our payments and inventory services, and connect them using VPC Lattice.

This is where things get interesting - we're using the **same Gateway API resources** but with a different controller that creates VPC Lattice services instead of load balancers!

## What We're Building

```
Apps-A EKS (payments.api.example.com)  ←→  VPC Lattice Service Network
Apps-B EKS (inventory.api.example.com) ←→  VPC Lattice Service Network
```

Both services will be accessible via VPC Lattice, which provides service-to-service connectivity across VPCs and clusters without needing VPC peering or Transit Gateway.

## Prerequisites

- Completed [Part 1](./PART1-EDGE-CLUSTER.md)
- Two additional EKS clusters (or create them now)
- Same tools installed (kubectl, helm, aws CLI, etc.)

## Step 1: Create Apps-A Cluster

If you don't have a cluster yet:

```bash
export AWS_REGION=us-west-2
export CLUSTER_NAME=apps-a-eks

eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --auto-mode
```

Configure kubectl:

```bash
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
```

Verify:

```bash
kubectl get pods -A
```

## Step 2: Install Gateway API CRDs

Same as Part 1:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml
```

## Step 3: Set Up IAM Permissions for VPC Lattice Controller

The VPC Lattice controller needs different permissions than the ALB controller.

### Download the policy

```bash
curl https://raw.githubusercontent.com/aws/aws-application-networking-k8s/main/files/controller-installation/recommended-inline-policy.json -o vpc-lattice-policy.json
```

### Create the IAM policy

```bash
aws iam create-policy \
  --policy-name VPCLatticeControllerIAMPolicy \
  --policy-document file://vpc-lattice-policy.json
```

Save the policy ARN!

### Create namespace

```bash
kubectl create namespace aws-application-networking-system
```

### Create service account with IAM role

I'm using **Pod Identity** (recommended for EKS Auto Mode):

```bash
# Create the service account
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gateway-api-controller
  namespace: aws-application-networking-system
EOF
```

### Create IAM role with trust policy

```bash
cat > eks-pod-identity-trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
EOF

aws iam create-role \
  --role-name VPCLatticeControllerIAMRole-${CLUSTER_NAME} \
  --assume-role-policy-document file://eks-pod-identity-trust-policy.json

aws iam attach-role-policy \
  --role-name VPCLatticeControllerIAMRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::<YOUR_ACCOUNT_ID>:policy/VPCLatticeControllerIAMPolicy
```

### Create Pod Identity association

```bash
aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --role-arn arn:aws:iam::<YOUR_ACCOUNT_ID>:role/VPCLatticeControllerIAMRole-${CLUSTER_NAME} \
  --namespace aws-application-networking-system \
  --service-account gateway-api-controller
```

## Step 4: Configure Security Groups for VPC Lattice

This is **critical** - I spent an hour debugging why traffic wasn't working before I realized I forgot this step!

VPC Lattice uses managed prefix lists. We need to allow traffic from these prefix lists to reach our pods.

```bash
# Get cluster security group
CLUSTER_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

echo "Cluster SG: $CLUSTER_SG"

# Get VPC Lattice IPv4 prefix list
PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.${AWS_REGION}.vpc-lattice'].PrefixListId" \
  --output text)

echo "Prefix List: $PREFIX_LIST_ID"

# Allow traffic from VPC Lattice
aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1"

# Also add IPv6 prefix list
PREFIX_LIST_ID_IPV6=$(aws ec2 describe-managed-prefix-lists \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.${AWS_REGION}.ipv6.vpc-lattice'].PrefixListId" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID_IPV6}}],IpProtocol=-1"
```

**Pro tip:** If you get an error saying the rule already exists, that's fine! It means it's already configured.

## Step 5: Install VPC Lattice Gateway API Controller

Using Helm:

```bash
# Login to ECR
aws ecr-public get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin public.ecr.aws

# Install the controller
helm install gateway-api-controller \
  oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
  --version=v2.0.0 \
  --set=serviceAccount.create=false \
  --namespace aws-application-networking-system \
  --set=log.level=info
```

### Verify the controller is running

```bash
kubectl get pods -n aws-application-networking-system
```

**Expected output:**
```
NAME                                      READY   STATUS    RESTARTS   AGE
gateway-api-controller-5d7f9c8b6d-abc12  1/1     Running   0          1m
```

**Troubleshooting:** If it's in CrashLoopBackOff:

```bash
kubectl logs -n aws-application-networking-system -l app.kubernetes.io/name=gateway-api-controller
```

Common issues:
- IAM permissions not set correctly
- Pod Identity association missing
- Service account not created

## Step 6: Create the GatewayClass

```bash
kubectl apply -f manifests/apps-a-cluster/03-lattice-gatewayclass.yaml
```

Verify:

```bash
kubectl get gatewayclass
```

**Expected output:**
```
NAME                  CONTROLLER                                              ACCEPTED   AGE
amazon-vpc-lattice    application-networking.k8s.aws/gateway-api-controller   True       10s
```

## Step 7: Deploy the Payments Service

Create namespace:

```bash
kubectl create namespace eks-gateway-demo
```

Deploy the application:

```bash
kubectl apply -f manifests/apps-a-cluster/01-payments-deployment.yaml
kubectl apply -f manifests/apps-a-cluster/02-payments-service.yaml
```

**Check pods:**

```bash
kubectl get pods -n eks-gateway-demo -w
```

Wait for them to be `Running`.

## Step 8: Create Gateway and HTTPRoute

```bash
kubectl apply -f manifests/apps-a-cluster/04-lattice-gateway.yaml
kubectl apply -f manifests/apps-a-cluster/05-lattice-httproute.yaml
```

**Check Gateway status:**

```bash
kubectl get gateway payments-gateway -n eks-gateway-demo
```

**What you'll see:**
```
NAME                CLASS                ADDRESS                                                      PROGRAMMED   AGE
payments-gateway    amazon-vpc-lattice   payments-gateway-default-0a1b2c3d4e5f.7d67968.vpc-lattice-svcs.us-west-2.on.aws   True         2m
```

**🎉 Success!** The Gateway is programmed and you have a VPC Lattice service DNS name!

**Check HTTPRoute:**

```bash
kubectl describe httproute payments-route -n eks-gateway-demo
```

Look for `Accepted: True` in the status.

## Step 9: Associate VPC with Service Network

This is a **critical step** that I initially missed. The VPC needs to be associated with the VPC Lattice service network for traffic to flow.

Apply the VPC association policy:

```bash
kubectl apply -f manifests/shared/vpc-association-policy.yaml
```

**Note:** You may need to update the Gateway name in the policy to match your gateway.

## Step 10: Test the Payments Service

From within the cluster, test the service:

```bash
# Run a test pod
kubectl run -it --rm debug --image=busybox --restart=Never -n eks-gateway-demo -- sh

# Inside the pod
wget -O- http://payments.api.example.com
```

**Expected output:**
```
Hello from payments.api.example.com - Payment processed!
```

**If it doesn't work:**
1. Check security groups (Step 4)
2. Check VPC association policy
3. Check controller logs
4. See [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)

## Step 11: Repeat for Apps-B Cluster (Inventory)

Now do the same for the inventory service on apps-b-eks cluster:

```bash
# Switch to apps-b cluster
export CLUSTER_NAME=apps-b-eks
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Repeat steps 2-9 but use manifests/apps-b-cluster/ instead
```

The process is identical, just with different service names (inventory instead of payments).

## What We Built

Let's recap:

1. **Two EKS Clusters** (apps-a-eks, apps-b-eks)
2. **VPC Lattice Gateway API Controller** on each cluster
3. **GatewayClass** defining VPC Lattice as the implementation
4. **Gateway** creating VPC Lattice services
5. **HTTPRoute** routing traffic to our backend services
6. **VPC Lattice Service Network** connecting everything

The amazing part? We used the **same Gateway and HTTPRoute resources** as in Part 1, just with a different GatewayClass!

## Key Differences: ALB vs VPC Lattice

| Aspect | AWS LBC (ALB) | VPC Lattice |
|--------|---------------|-------------|
| **GatewayClass controller** | `eks.amazonaws.com/alb` | `application-networking.k8s.aws/gateway-api-controller` |
| **Creates** | Application Load Balancer | VPC Lattice Service |
| **Use case** | Internet ingress (north-south) | Service-to-service (east-west) |
| **DNS name** | ALB DNS (*.elb.amazonaws.com) | Lattice DNS (*.vpc-lattice-svcs.*.on.aws) |
| **Security groups** | ALB security groups | VPC Lattice prefix lists |
| **Certificate** | ACM certificate | Optional (can use HTTP) |

## Next Steps

In [Part 3](./PART3-INTEGRATION.md), we'll connect everything together:
- Configure the shop service to call payments and inventory
- Test end-to-end traffic flow
- Verify VPC Lattice access logs

## Common Issues I Hit

### Issue 1: Traffic not reaching pods
**Solution:** Add VPC Lattice prefix lists to security groups (Step 4).

### Issue 2: Gateway not programmed
**Solution:** Check IAM permissions and Pod Identity association.

### Issue 3: HTTPRoute not accepted
**Solution:** Make sure the Gateway exists and the service is running.

### Issue 4: DNS not resolving
**Solution:** VPC association policy might be missing or incorrect.

## Useful Commands

```bash
# Check VPC Lattice controller logs
kubectl logs -n aws-application-networking-system -l app.kubernetes.io/name=gateway-api-controller

# Get VPC Lattice service DNS name
kubectl get gateway <gateway-name> -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}'

# Check VPC association
kubectl get vpcassociationpolicy -n eks-gateway-demo

# Test from within cluster
kubectl run -it --rm debug --image=busybox --restart=Never -n eks-gateway-demo -- wget -O- http://payments.api.example.com
```

---

**Next:** [Part 3 - End-to-End Integration](./PART3-INTEGRATION.md)
