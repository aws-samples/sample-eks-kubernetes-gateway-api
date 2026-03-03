# Troubleshooting Guide

This guide covers common issues you might encounter when setting up Gateway API with AWS Load Balancer Controller and VPC Lattice. I hit most of these myself when building this for the first time!

## Table of Contents

- [Pod Issues](#pod-issues)
- [Gateway and Route Issues](#gateway-and-route-issues)
- [Security Group Issues](#security-group-issues)
- [Certificate Issues](#certificate-issues)
- [Useful Commands](#useful-commands)

---

## Pod Issues

### Pod in CrashLoopBackOff

**Symptoms:**
```bash
$ kubectl get pods -n eks-gateway-demo
NAME                        READY   STATUS             RESTARTS   AGE
shop-7d8f9c5b6d-abc12       0/1     CrashLoopBackOff   5          3m
```

**What this means:** Your pod is starting, crashing, restarting, and repeating this cycle.

**Common causes and fixes:**

#### 1. Wrong container image or command

Check the pod logs:
```bash
kubectl logs shop-7d8f9c5b6d-abc12 -n eks-gateway-demo
```

If you see "exec format error" or "not found", check your deployment YAML:
- Is the image name correct?
- Are the args/command correct?

#### 2. Missing environment variables or secrets

Describe the pod to see events:
```bash
kubectl describe pod shop-7d8f9c5b6d-abc12 -n eks-gateway-demo
```

Look for events like:
- `Error: secret "my-secret" not found`
- `Error: configmap "my-config" not found`

**Fix:** Create the missing secret or configmap, or remove the reference if not needed.

#### 3. Wrong service account or IAM permissions

Check if the pod is trying to access AWS services:
```bash
kubectl logs shop-7d8f9c5b6d-abc12 -n eks-gateway-demo | grep -i "access denied\|unauthorized"
```

**Fix:** Verify the service account has the correct IAM role annotation:
```bash
kubectl get sa -n eks-gateway-demo gateway-api-controller -o yaml | grep eks.amazonaws.com/role-arn
```

### Pod Stuck in Pending

**Symptoms:**
```bash
$ kubectl get pods -n eks-gateway-demo
NAME                        READY   STATUS    RESTARTS   AGE
shop-7d8f9c5b6d-abc12       0/1     Pending   0          5m
```

**What this means:** Kubernetes can't schedule your pod onto a node.

**Check why:**
```bash
kubectl describe pod shop-7d8f9c5b6d-abc12 -n eks-gateway-demo
```

**Common causes:**

#### 1. No nodes available (EKS Auto Mode)
In EKS Auto Mode, nodes are created automatically. Wait a few minutes for nodes to provision.

Check node status:
```bash
kubectl get nodes
```

#### 2. Insufficient resources
The pod requests more CPU/memory than available.

**Fix:** Either:
- Reduce resource requests in your deployment
- Add more nodes (or wait for EKS Auto Mode to scale)

#### 3. Node selector or affinity issues
Check if your pod has node selectors that don't match any nodes:
```bash
kubectl get pod shop-7d8f9c5b6d-abc12 -n eks-gateway-demo -o yaml | grep -A 5 nodeSelector
```

### Pod Not Starting (ContainerCreating)

**Symptoms:**
```bash
$ kubectl get pods -n eks-gateway-demo
NAME                        READY   STATUS              RESTARTS   AGE
shop-7d8f9c5b6d-abc12       0/1     ContainerCreating   0          2m
```

**Check events:**
```bash
kubectl describe pod shop-7d8f9c5b6d-abc12 -n eks-gateway-demo
```

**Common causes:**
- Mounting volumes that don't exist
- Security group blocking pod networking
- CNI plugin issues

---

## Gateway and Route Issues

### Gateway Not Programmed

**Symptoms:**
```bash
$ kubectl get gateway shop-gateway -n eks-gateway-demo
NAME            CLASS      ADDRESS   PROGRAMMED   AGE
shop-gateway    aws-alb              False        5m
```

**What this means:** The controller hasn't successfully created the load balancer yet.

**Check the status:**
```bash
kubectl describe gateway shop-gateway -n eks-gateway-demo
```

Look at the `Status` section for error messages.

**Common causes:**

#### 1. Controller not running

Check if the AWS Load Balancer Controller is running:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Should show:
```
NAME                                            READY   STATUS    RESTARTS   AGE
aws-load-balancer-controller-5d7f9c8b6d-abc12  1/1     Running   0          10m
```

If not running, check controller logs:
```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

#### 2. IAM permissions missing

The controller needs permissions to create load balancers. Check the service account:
```bash
kubectl get sa -n kube-system aws-load-balancer-controller -o yaml
```

Should have annotation:
```yaml
annotations:
  eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/AmazonEKSLoadBalancerControllerRole
```

#### 3. Subnet tags missing

For ALB, subnets need specific tags. Check your VPC subnets have:
- Public subnets: `kubernetes.io/role/elb=1`
- Private subnets: `kubernetes.io/role/internal-elb=1`

#### 4. Wrong GatewayClass

Make sure your Gateway references the correct GatewayClass:
```bash
kubectl get gatewayclass
```

Should show:
```
NAME       CONTROLLER                  ACCEPTED   AGE
aws-alb    eks.amazonaws.com/alb       True       10m
```

### HTTPRoute Not Accepted

**Symptoms:**
```bash
$ kubectl get httproute shop-route -n eks-gateway-demo
NAME          HOSTNAMES                    AGE
shop-route    ["shop.api.example.com"]     5m
```

Check status:
```bash
kubectl describe httproute shop-route -n eks-gateway-demo
```

**Common causes:**

#### 1. Gateway doesn't exist or wrong name

The HTTPRoute's `parentRefs` must match an existing Gateway:
```yaml
spec:
  parentRefs:
    - name: shop-gateway  # Must match Gateway name
      sectionName: https  # Must match listener name
```

#### 2. Hostname mismatch

If your Gateway has a hostname, the HTTPRoute must match:
```yaml
# Gateway
listeners:
  - hostname: shop.api.example.com

# HTTPRoute must match
hostnames:
  - shop.api.example.com
```

#### 3. Backend service doesn't exist

Check if the service exists:
```bash
kubectl get svc shop -n eks-gateway-demo
```

---

## Security Group Issues

### VPC Lattice Traffic Not Working

**Symptoms:** Gateway and Route are programmed, but traffic doesn't reach pods.

**Cause:** Security groups not allowing VPC Lattice traffic.

**Fix:** Add VPC Lattice prefix lists to your node security group:

```bash
# Get your cluster security group
CLUSTER_SG=$(aws eks describe-cluster --name edge-eks --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text)

# Get VPC Lattice prefix list
PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.us-west-2.vpc-lattice'].PrefixListId" \
  --output text)

# Allow traffic from VPC Lattice
aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1"
```

### ALB Health Checks Failing

**Symptoms:** ALB created but targets unhealthy.

**Check target group health:**
```bash
# Get the ALB ARN from Gateway status
kubectl get gateway shop-gateway -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}'

# Check target groups in AWS Console or CLI
aws elbv2 describe-target-health --target-group-arn <target-group-arn>
```

**Common causes:**
- Security group not allowing ALB to reach pods
- Pods not listening on the correct port
- Health check path doesn't exist

---

## Certificate Issues

### Certificate Not Found

**Symptoms:**
```
Error: Certificate not found in ACM
```

**Check if certificate exists:**
```bash
aws acm list-certificates --region us-west-2
```

**For private certificates:**
Make sure you're using ACM Private CA and the certificate is issued.

**Fix:** Either:
1. Create the certificate in ACM
2. Update the Gateway to reference the correct certificate ARN
3. Use automatic certificate discovery by hostname

### Wrong Certificate ARN

If you're specifying a certificate ARN directly, make sure it's in the correct format:
```
arn:aws:acm:us-west-2:123456789012:certificate/12345678-1234-1234-1234-123456789012
```

---

## Useful Commands

### Check Everything in a Namespace

```bash
# Get all resources
kubectl get all -n eks-gateway-demo

# Get Gateway API resources
kubectl get gateway,httproute,gatewayclass -n eks-gateway-demo
```

### Check Pod Status and Logs

```bash
# List all pods
kubectl get pods -A

# Get pods in specific namespace
kubectl get pods -n eks-gateway-demo

# Describe a pod (shows events)
kubectl describe pod <pod-name> -n eks-gateway-demo

# Get pod logs
kubectl logs <pod-name> -n eks-gateway-demo

# Follow logs in real-time
kubectl logs -f <pod-name> -n eks-gateway-demo

# Get logs from previous container (if crashed)
kubectl logs <pod-name> -n eks-gateway-demo --previous
```

### Check Gateway Status

```bash
# List all gateways
kubectl get gateway -A

# Get detailed gateway info
kubectl describe gateway <gateway-name> -n eks-gateway-demo

# Get gateway status in YAML
kubectl get gateway <gateway-name> -n eks-gateway-demo -o yaml

# Check if gateway is programmed
kubectl get gateway <gateway-name> -n eks-gateway-demo -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}'
```

### Check HTTPRoute Status

```bash
# List all routes
kubectl get httproute -A

# Describe route
kubectl describe httproute <route-name> -n eks-gateway-demo

# Check if route is accepted
kubectl get httproute <route-name> -n eks-gateway-demo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'
```

### Check Controller Logs

```bash
# AWS Load Balancer Controller
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# VPC Lattice Controller
kubectl logs -n aws-application-networking-system -l app.kubernetes.io/name=gateway-api-controller

# Follow logs
kubectl logs -f -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

### Check Events

```bash
# All events in namespace
kubectl get events -n eks-gateway-demo --sort-by='.lastTimestamp'

# Watch events in real-time
kubectl get events -n eks-gateway-demo --watch

# Events for specific resource
kubectl describe <resource-type> <resource-name> -n eks-gateway-demo
```

### Debug DNS Resolution

```bash
# Run a debug pod
kubectl run -it --rm debug --image=busybox --restart=Never -- sh

# Inside the pod, test DNS
nslookup payments.api.example.com
wget -O- http://payments.api.example.com
```

### Check Service Endpoints

```bash
# List services
kubectl get svc -n eks-gateway-demo

# Check if service has endpoints
kubectl get endpoints -n eks-gateway-demo

# Describe service
kubectl describe svc <service-name> -n eks-gateway-demo
```

---

## Still Stuck?

If you're still having issues:

1. **Check the controller logs** - Most issues show up there
2. **Look at events** - `kubectl get events` often reveals the problem
3. **Verify IAM permissions** - Many issues are permission-related
4. **Check security groups** - Network connectivity issues are common
5. **Review the docs**:
   - [AWS LBC Troubleshooting](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/troubleshooting/)
   - [VPC Lattice Controller FAQ](https://www.gateway-api-controller.eks.aws.dev/latest/faq/)

Remember: Everyone feels like a noob when learning new tech. The key is knowing how to debug! 🚀
