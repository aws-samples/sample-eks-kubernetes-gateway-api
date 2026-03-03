#!/bin/bash
set -e

# Cleanup Script - Remove all resources created by this demo

echo "=== Cleanup Script ==="
echo ""
echo "This will delete:"
echo "  - All Kubernetes resources in eks-gateway-demo namespace"
echo "  - Gateway API resources"
echo "  - Optionally: EKS clusters"
echo ""

export AWS_REGION=${AWS_REGION:-us-west-2}

read -p "Continue with cleanup? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup cancelled"
    exit 0
fi

# Function to cleanup a cluster
cleanup_cluster() {
    local CLUSTER_NAME=$1
    echo ""
    echo "Cleaning up cluster: $CLUSTER_NAME"
    
    # Check if cluster exists
    if ! aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION >/dev/null 2>&1; then
        echo "Cluster $CLUSTER_NAME not found, skipping..."
        return
    fi
    
    # Configure kubectl
    aws eks update-kubeconfig --region $AWS_REGION --name $CLUSTER_NAME
    
    # Delete namespace (this will delete all resources in it)
    echo "Deleting eks-gateway-demo namespace..."
    kubectl delete namespace eks-gateway-demo --ignore-not-found=true --timeout=120s
    
    # Delete Gateway API CRDs (optional, may affect other workloads)
    # kubectl delete -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml --ignore-not-found=true
    
    echo "Cluster $CLUSTER_NAME cleaned up"
}

# Cleanup edge cluster
cleanup_cluster "edge-eks"

# Cleanup apps-a cluster
cleanup_cluster "apps-a-eks"

# Cleanup apps-b cluster
cleanup_cluster "apps-b-eks"

# Ask about deleting clusters
echo ""
read -p "Delete EKS clusters? This will take 10-15 minutes per cluster. (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Deleting clusters..."
    
    eksctl delete cluster --name edge-eks --region $AWS_REGION --wait &
    PID1=$!
    
    eksctl delete cluster --name apps-a-eks --region $AWS_REGION --wait &
    PID2=$!
    
    eksctl delete cluster --name apps-b-eks --region $AWS_REGION --wait &
    PID3=$!
    
    echo "Waiting for clusters to be deleted (this may take 10-15 minutes)..."
    wait $PID1 $PID2 $PID3
    
    echo "All clusters deleted"
fi

# Ask about IAM resources
echo ""
read -p "Delete IAM roles and policies? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    
    # Detach and delete ALB controller resources
    echo "Cleaning up ALB controller IAM resources..."
    aws iam detach-role-policy \
      --role-name AmazonEKSLoadBalancerControllerRole-edge-eks \
      --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true
    
    aws iam delete-role --role-name AmazonEKSLoadBalancerControllerRole-edge-eks 2>/dev/null || true
    
    aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy 2>/dev/null || true
    
    # Detach and delete VPC Lattice controller resources
    echo "Cleaning up VPC Lattice controller IAM resources..."
    for CLUSTER in apps-a-eks apps-b-eks; do
        aws iam detach-role-policy \
          --role-name VPCLatticeControllerIAMRole-${CLUSTER} \
          --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/VPCLatticeControllerIAMPolicy 2>/dev/null || true
        
        aws iam delete-role --role-name VPCLatticeControllerIAMRole-${CLUSTER} 2>/dev/null || true
    done
    
    aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/VPCLatticeControllerIAMPolicy 2>/dev/null || true
    
    echo "IAM resources cleaned up"
fi

# Cleanup local files
echo ""
read -p "Delete local temporary files? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -f iam_policy.json vpc-lattice-policy.json eks-pod-identity-trust-policy.json
    echo "Local files cleaned up"
fi

echo ""
echo "=== Cleanup Complete! ==="
echo ""
echo "Note: VPC Lattice service networks and services are automatically"
echo "deleted when Gateway resources are removed."
echo ""
