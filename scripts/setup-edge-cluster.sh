#!/bin/bash
set -e

# Setup Edge Cluster with AWS Load Balancer Controller
# This script automates Part 1 of the tutorial

echo "=== Edge Cluster Setup Script ==="
echo ""

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "aws CLI required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm required but not installed. Aborting." >&2; exit 1; }
command -v eksctl >/dev/null 2>&1 || { echo "eksctl required but not installed. Aborting." >&2; exit 1; }

# Configuration
export AWS_REGION=${AWS_REGION:-us-west-2}
export CLUSTER_NAME=${CLUSTER_NAME:-edge-eks}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Configuration:"
echo "  Region: $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  Account: $AWS_ACCOUNT_ID"
echo ""

# Create cluster
read -p "Create new EKS cluster? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Creating EKS cluster..."
    eksctl create cluster \
      --name $CLUSTER_NAME \
      --region $AWS_REGION \
      --auto-mode
fi

# Configure kubectl
echo "Configuring kubectl..."
aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME

# Install Gateway API CRDs
echo "Installing Gateway API CRDs..."
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

# Install AWS LBC CRDs
echo "Installing AWS Load Balancer Controller CRDs..."
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml

# Create IAM policy
echo "Creating IAM policy..."
curl -so iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json 2>/dev/null || echo "Policy already exists"

# Associate OIDC provider
echo "Associating IAM OIDC provider..."
eksctl utils associate-iam-oidc-provider \
  --region $AWS_REGION \
  --cluster $CLUSTER_NAME \
  --approve

# Create service account
echo "Creating service account with IAM role..."
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --region $AWS_REGION \
  --namespace kube-system \
  --name aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole-${CLUSTER_NAME} \
  --attach-policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve \
  --override-existing-serviceaccounts

# Get VPC ID
echo "Getting VPC ID..."
export VPC_ID=$(aws eks describe-cluster \
  --region $AWS_REGION \
  --name $CLUSTER_NAME \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)
echo "VPC ID: $VPC_ID"

# Install AWS Load Balancer Controller
echo "Installing AWS Load Balancer Controller..."
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set region=$AWS_REGION \
  --set vpcId=$VPC_ID \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set controllerConfig.featureGates="ALBGatewayAPI=true,NLBGatewayAPI=true"

# Wait for controller
echo "Waiting for controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/aws-load-balancer-controller -n kube-system

# Create namespace
echo "Creating namespace..."
kubectl create namespace eks-gateway-demo --dry-run=client -o yaml | kubectl apply -f -

# Deploy manifests
echo "Deploying shop application..."
kubectl apply -f manifests/edge-cluster/

# Wait for Gateway
echo "Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed --timeout=300s gateway/shop-gateway -n eks-gateway-demo

# Get ALB hostname
ALB_HOSTNAME=$(kubectl get gateway shop-gateway -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}')

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "ALB Hostname: $ALB_HOSTNAME"
echo ""
echo "Test with:"
echo "  curl -k https://$ALB_HOSTNAME -H \"Host: shop.api.example.com\""
echo ""
