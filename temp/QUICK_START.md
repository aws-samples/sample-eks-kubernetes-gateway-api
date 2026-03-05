# Quick Start Guide

Get up and running in 15 minutes!

## Prerequisites

```bash
# Verify tools
aws --version      # Need 2.x+
kubectl version    # Need 1.28+
helm version       # Need 3.x+
eksctl version     # Need 0.150.0+
```

## Option 1: Automated Setup (Recommended)

### Edge Cluster
```bash
export AWS_REGION=us-west-2
./scripts/setup-edge-cluster.sh
```

### Apps Clusters
```bash
./scripts/setup-apps-cluster.sh apps-a-eks payments
./scripts/setup-apps-cluster.sh apps-b-eks inventory
```

### Test
```bash
# Get ALB hostname
ALB=$(kubectl get gateway shop-gateway -n eks-gateway-demo -o jsonpath='{.status.addresses[0].value}')

# Test
curl -k https://$ALB -H "Host: shop.api.example.com"
```

## Option 2: Manual Setup

Follow the detailed tutorials:
1. [Part 1: Edge Cluster](docs/PART1-EDGE-CLUSTER.md)
2. [Part 2: Apps Clusters](docs/PART2-APPS-CLUSTERS.md)
3. [Part 3: Integration](docs/PART3-INTEGRATION.md)

## Cleanup

```bash
./scripts/cleanup.sh
```

## Troubleshooting

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for common issues.

## Architecture

```
Internet → ALB → shop (edge-eks)
              ↓
              ├─→ payments (apps-a-eks) via VPC Lattice
              └─→ inventory (apps-b-eks) via VPC Lattice
```

## Key Commands

```bash
# Check Gateway status
kubectl get gateway -n eks-gateway-demo

# Check HTTPRoute status
kubectl get httproute -n eks-gateway-demo

# View logs
kubectl logs -f deployment/shop -n eks-gateway-demo

# Test from within cluster
kubectl exec -it deployment/shop -n eks-gateway-demo -- sh
```

## Need Help?

- 📖 [Full Documentation](README.md)
- 🔧 [Troubleshooting Guide](TROUBLESHOOTING.md)
- 📝 [Detailed Tutorials](docs/)
