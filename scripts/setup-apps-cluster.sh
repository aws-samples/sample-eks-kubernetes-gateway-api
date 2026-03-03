#!/bin/bash
set -e

# Setup Apps Cluster with VPC Lattice Controller
# This script automates Part 2 of the tutorial

echo "=== Apps Cluster Setup Script ==="
echo ""

# Check prerequisites
command -v aws >/dev/null 2>&1 || { echo "aws CLI required but not installed. Aborting." >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl required but not installed. Aborting." >&2; exit 1; }
command -v helm >/dev/null 2>&1 || { echo "helm required but not installed. Aborting." >&2; exit 1; }
command -v eksctl >/dev/null 2>&1 || { echo "eksctl required but not installed. Aborting." >&2; exit 1; }

# Configuration
export AWS_REGION=${AWS_REGION:-us-west-2}
export CLUSTER_NAME=${1:-apps-a-eks}
export SERVICE_NAME=${2:-payments}
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Configuration:"
echo "  Region: $AWS_REGION"
echo "  Cluster: $CLUSTER_NAME"
echo "  Service: $SERVICE_NAME"
echo "  Account: $AWS_ACCOUNT_ID"
echo ""

# Determine manifest directory
if [[ $SERVICE_NAME == "payments" ]]; then
    MANIFEST_DIR="manifests/apps-a-cluster"
elif [[ $SERVICE_NAME == "inventory" ]]; then
    MANIFEST_DIR="manifests/apps-b-cluster"
else
    echo "Invalid service name. Use 'payments' or 'inventory'"
    exit 1
fi

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

# Download VPC Lattice policy
echo "Downloading VPC Lattice IAM policy..."
curl -so vpc-lattice-policy.json https://raw.githubusercontent.com/aws/aws-application-networking-k8s/main/files/controller-installation/recommended-inline-policy.json

# Create IAM policy
echo "Creating IAM policy..."
aws iam create-policy \
  --policy-name VPCLatticeControllerIAMPolicy \
  --policy-document file://vpc-lattice-policy.json 2>/dev/null || echo "Policy already exists"

# Create namespace
echo "Creating namespace..."
kubectl create namespace aws-application-networking-system --dry-run=client -o yaml | kubectl apply -f -

# Create service account
echo "Creating service account..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gateway-api-controller
  namespace: aws-application-networking-system
EOF

# Create IAM role with trust policy
echo "Creating IAM role..."
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
  --assume-role-policy-document file://eks-pod-identity-trust-policy.json 2>/dev/null || echo "Role already exists"

aws iam attach-role-policy \
  --role-name VPCLatticeControllerIAMRole-${CLUSTER_NAME} \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/VPCLatticeControllerIAMPolicy

# Create Pod Identity association
echo "Creating Pod Identity association..."
aws eks create-pod-identity-association \
  --cluster-name $CLUSTER_NAME \
  --role-arn arn:aws:iam::${AWS_ACCOUNT_ID}:role/VPCLatticeControllerIAMRole-${CLUSTER_NAME} \
  --namespace aws-application-networking-system \
  --service-account gateway-api-controller 2>/dev/null || echo "Association already exists"

# Configure security groups
echo "Configuring security groups for VPC Lattice..."
CLUSTER_SG=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' \
  --output text)

PREFIX_LIST_ID=$(aws ec2 describe-managed-prefix-lists \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.${AWS_REGION}.vpc-lattice'].PrefixListId" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID}}],IpProtocol=-1" 2>/dev/null || echo "IPv4 rule already exists"

PREFIX_LIST_ID_IPV6=$(aws ec2 describe-managed-prefix-lists \
  --query "PrefixLists[?PrefixListName=='com.amazonaws.${AWS_REGION}.ipv6.vpc-lattice'].PrefixListId" \
  --output text)

aws ec2 authorize-security-group-ingress \
  --group-id $CLUSTER_SG \
  --ip-permissions "PrefixListIds=[{PrefixListId=${PREFIX_LIST_ID_IPV6}}],IpProtocol=-1" 2>/dev/null || echo "IPv6 rule already exists"

# Install VPC Lattice Controller
echo "Installing VPC Lattice Gateway API Controller..."
aws ecr-public get-login-password --region us-east-1 | \
  helm registry login --username AWS --password-stdin public.ecr.aws

helm install gateway-api-controller \
  oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
  --version=v2.0.0 \
  --set=serviceAccount.create=false \
  --namespace aws-application-networking-system \
  --set=log.level=info

# Wait for controller
echo "Waiting for controller to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/gateway-api-controller -n aws-application-networking-system

# Create namespace
echo "Creating application namespace..."
kubectl create namespace eks-gateway-demo --dry-run=client -o yaml | kubectl apply -f -

# Deploy manifests
echo "Deploying $SERVICE_NAME application..."
kubectl apply -f $MANIFEST_DIR/

# Apply VPC association policy
echo "Applying VPC association policy..."
kubectl apply -f manifests/shared/vpc-association-policy.yaml

# Wait for Gateway
echo "Waiting for Gateway to be programmed..."
kubectl wait --for=condition=Programmed --timeout=300s gateway/${SERVICE_NAME}-gateway -n eks-gateway-demo

# Get Lattice DNS
LATTICE_DNS=$(kubectl get gateway ${SERVICE_NAME}-gateway -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}')

echo ""
echo "=== Setup Complete! ==="
echo ""
echo "VPC Lattice DNS: $LATTICE_DNS"
echo ""
echo "Test from within cluster:"
echo "  kubectl run -it --rm debug --image=busybox --restart=Never -n eks-gateway-demo -- wget -O- http://${SERVICE_NAME}.api.example.com"
echo ""
