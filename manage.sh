#!/usr/bin/env bash
# =============================================================================
#
#  manage.sh — Unified deployment & lifecycle management
#
#  Single entry-point for the EKS Gateway API sample. Provisions infrastructure,
#  builds container images, configures three EKS clusters, and deploys all
#  application workloads including VPC Lattice connectivity.
#
#  Usage:
#    ./manage.sh deploy            # Full deploy (infra → images → clusters → apps → networking)
#    ./manage.sh deploy-infra      # Deploy up to infrastructure (steps 1-3)
#    ./manage.sh deploy-clusters   # Deploy up to cluster config (steps 1-4)
#    ./manage.sh deploy-apps       # Deploy up to applications (steps 1-5)
#    ./manage.sh teardown          # Full teardown (reverse order)
#
#  Environment variables (all optional — sensible defaults provided):
#    AWS_REGION       — Target region          (default: read from terraform.tfvars)
#    PROJECT_PREFIX   — Resource name prefix   (default: eks-gateway-demo)
#
# =============================================================================
set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}"
INFRA_DIR="${PROJECT_DIR}/infra"
K8S_DIR="${PROJECT_DIR}/k8s"
APP_DIR="${PROJECT_DIR}/app"
TFVARS="${INFRA_DIR}/terraform.tfvars"

# ─── Read config from terraform.tfvars ───────────────────────────────────────
read_tfvar() { grep "^${1}" "${TFVARS}" | sed 's/.*= *"\(.*\)"/\1/' ; }

AWS_REGION="${AWS_REGION:-$(read_tfvar aws_region)}"
PROJECT_PREFIX="${PROJECT_PREFIX:-eks-gateway-demo}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

FRONTEND_CLUSTER="${PROJECT_PREFIX}-frontend-cluster"
BACKEND_A_CLUSTER="${PROJECT_PREFIX}-backend-a-cluster"
BACKEND_B_CLUSTER="${PROJECT_PREFIX}-backend-b-cluster"

PRIVATE_ZONE="$(read_tfvar private_hosted_zone_name)"
ALB_PROTOCOL="$(read_tfvar alb_protocol)"
ALB_CERTIFICATE_ARN="$(read_tfvar alb_certificate_arn)"
VPCLATTICE_PROTOCOL="$(read_tfvar vpclattice_protocol | tr '[:upper:]' '[:lower:]')"
VPCLATTICE_CERTIFICATE_ARN="$(read_tfvar vpclattice_certificate_arn)"
FRONTEND_DOMAIN="$(read_tfvar frontend_domain_name)"

ACTION="${1:-}"

# ─── Output helpers ──────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[1;36m'
MAGENTA='\033[1;35m'; BOLD='\033[1m'; DIM='\033[0;37m'; RESET='\033[0m'

banner()  { echo -e "\n${CYAN}══════════════════════════════════════════════════════════════${RESET}"; echo -e "${CYAN}  $1${RESET}"; echo -e "${CYAN}══════════════════════════════════════════════════════════════${RESET}\n"; }
step()    { echo -e "${YELLOW}▸ $1${RESET}"; }
info()    { echo -e "  ${DIM}$1${RESET}"; }
success() { echo -e "  ${GREEN}✔ $1${RESET}"; }
warn()    { echo -e "  ${MAGENTA}⚠ $1${RESET}"; }
fail()    { echo -e "  ${RED}✖ $1${RESET}"; }

# ─── Prerequisite checks ────────────────────────────────────────────────────
check_prerequisites() {
  local missing=0
  for cmd in aws terraform kubectl helm docker; do
    if ! command -v "$cmd" &>/dev/null; then
      fail "Required tool not found: ${cmd}"
      missing=1
    fi
  done
  if [ "$missing" -eq 1 ]; then
    echo -e "\n${RED}Install missing tools before continuing.${RESET}"
    exit 1
  fi
}

# ─── Kubectl context helper ─────────────────────────────────────────────────
use_cluster() {
  local cluster="$1"
  step "Switching kubectl context → ${cluster}"
  aws eks update-kubeconfig --region "${AWS_REGION}" --name "${cluster}" --quiet 2>/dev/null \
    || aws eks update-kubeconfig --region "${AWS_REGION}" --name "${cluster}"
  success "Context set to ${cluster}"
}


# =============================================================================
#
#  DEPLOY STEPS
#
#  Each step is an independent function so future commands can call them
#  individually (e.g. ./scripts/manage.sh deploy-apps).
#
# =============================================================================

# ─── Step 1: ECR Repositories (Terraform targeted apply) ────────────────────
deploy_ecr() {
  banner "STEP 1 / 6 — Create ECR Repositories"

  step "Initializing Terraform..."
  terraform -chdir="${INFRA_DIR}" init -input=false -no-color | tail -1
  success "Terraform initialized"

  step "Creating ECR repositories (targeted apply)..."
  terraform -chdir="${INFRA_DIR}" apply -auto-approve -input=false \
    -target=aws_ecr_repository.frontend \
    -target=aws_ecr_repository.bff \
    -target=aws_ecr_repository.cart_service \
    -target=aws_ecr_repository.inventory_service \
    -target=aws_ecr_repository.payments_service \
    | grep -E '(Apply complete|aws_ecr_repository)' || true
  success "ECR repositories ready"
}

# ─── Step 2: Build & push container images ───────────────────────────────────
deploy_images() {
  banner "STEP 2 / 6 — Build & Push Container Images"

  step "Authenticating Docker to ECR (${AWS_REGION})..."
  aws ecr get-login-password --region "${AWS_REGION}" | \
    docker login --username AWS --password-stdin "${ECR_BASE}" 2>/dev/null
  success "Docker authenticated"

  local services=("frontend" "bff" "cart-service" "inventory-service" "payments-service")
  for svc in "${services[@]}"; do
    step "Building & pushing ${svc} (linux/arm64)..."
    docker build --platform linux/arm64 -q \
      -t "${ECR_BASE}/${PROJECT_PREFIX}/${svc}:latest" \
      "${APP_DIR}/${svc}"
    docker push "${ECR_BASE}/${PROJECT_PREFIX}/${svc}:latest" | tail -1
    success "${svc} image pushed"
  done
}

# ─── Step 3: Full Terraform apply (VPCs, EKS, IAM, VPC Lattice network) ─────
deploy_infra() {
  banner "STEP 3 / 6 — Deploy Infrastructure (Terraform)"

  step "Applying full Terraform configuration..."
  info "This creates VPCs, EKS clusters, IAM roles, VPC Lattice service network,"
  info "WAF WebACL, Route 53 zones, and Pod Identity associations."
  info "Estimated time: 15-20 minutes."
  echo ""
  terraform -chdir="${INFRA_DIR}" apply -auto-approve -input=false
  success "Infrastructure deployed"

  # Cache Terraform outputs for later steps
  step "Reading Terraform outputs..."
  TF_SERVICE_NETWORK_NAME=$(terraform -chdir="${INFRA_DIR}" output -raw vpc_lattice_service_network_name)
  TF_PRIVATE_HZ_ID=$(terraform -chdir="${INFRA_DIR}" output -raw private_hosted_zone_id)
  TF_ITEMS_LOG_GROUP_ARN=$(terraform -chdir="${INFRA_DIR}" output -raw items_service_log_group_arn)
  TF_PAYMENTS_LOG_GROUP_ARN=$(terraform -chdir="${INFRA_DIR}" output -raw payments_service_log_group_arn)
  TF_WAF_ACL_ARN=$(terraform -chdir="${INFRA_DIR}" output -raw frontend_waf_acl_arn)
  TF_BACKEND_A_VPC_ID=$(terraform -chdir="${INFRA_DIR}" output -raw backend_a_vpc_id)
  TF_BACKEND_B_VPC_ID=$(terraform -chdir="${INFRA_DIR}" output -raw backend_b_vpc_id)
  success "Outputs cached"
}

# ─── Step 4: Configure all three EKS clusters ───────────────────────────────
deploy_cluster_config() {
  banner "STEP 4 / 6 — Configure EKS Clusters"

  # Ensure TF outputs are available (in case this step runs standalone)
  load_tf_outputs

  # ── Backend A ──────────────────────────────────────────────────────────────
  use_cluster "${BACKEND_A_CLUSTER}"

  step "Applying Graviton NodePool..."
  kubectl apply -f "${K8S_DIR}/cluster-config/nodepool-graviton.yaml"
  success "NodePool applied"

  step "Installing Gateway API CRDs (experimental)..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml 2>/dev/null
  success "Gateway API CRDs installed"

  step "Creating service account for Gateway API Controller..."
  kubectl create namespace aws-application-networking-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${K8S_DIR}/cluster-config/aws-application-networking-sa.yaml"
  success "Service account ready"

  step "Installing Gateway API Controller for VPC Lattice (Helm)..."
  aws ecr-public get-login-password --region us-east-1 2>/dev/null | \
    helm registry login --username AWS --password-stdin public.ecr.aws 2>/dev/null || true
  helm upgrade --install gateway-api-controller \
    oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
    --version=v2.0.1 \
    --namespace aws-application-networking-system \
    --set=serviceAccount.create=false \
    --set=awsRegion="${AWS_REGION}" \
    --set=awsAccountId="${ACCOUNT_ID}" \
    --set=clusterVpcId="${TF_BACKEND_A_VPC_ID}" \
    --set=clusterName="${BACKEND_A_CLUSTER}" \
    --set=defaultServiceNetwork="${TF_SERVICE_NETWORK_NAME}" \
    --set=log.level=info \
    --wait --timeout=10m 2>&1 | tail -3
  success "Gateway API Controller running on Backend A"

  step "Creating VPC Lattice GatewayClass..."
  kubectl apply -f "${K8S_DIR}/cluster-config/gatewayclass-vpc-lattice.yaml"
  success "GatewayClass amazon-vpc-lattice created"

  step "Installing ExternalDNS (private zone)..."
  install_external_dns "${TF_PRIVATE_HZ_ID}" "private"
  success "ExternalDNS running on Backend A"

  # ── Backend B ──────────────────────────────────────────────────────────────
  use_cluster "${BACKEND_B_CLUSTER}"

  step "Applying Graviton NodePool..."
  kubectl apply -f "${K8S_DIR}/cluster-config/nodepool-graviton.yaml"
  success "NodePool applied"

  step "Installing Gateway API CRDs (experimental)..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/experimental-install.yaml 2>/dev/null
  success "Gateway API CRDs installed"

  step "Creating service account for Gateway API Controller..."
  kubectl create namespace aws-application-networking-system --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${K8S_DIR}/cluster-config/aws-application-networking-sa.yaml"
  success "Service account ready"

  step "Installing Gateway API Controller for VPC Lattice (Helm)..."
  helm upgrade --install gateway-api-controller \
    oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
    --version=v2.0.1 \
    --namespace aws-application-networking-system \
    --set=serviceAccount.create=false \
    --set=awsRegion="${AWS_REGION}" \
    --set=awsAccountId="${ACCOUNT_ID}" \
    --set=clusterVpcId="${TF_BACKEND_B_VPC_ID}" \
    --set=clusterName="${BACKEND_B_CLUSTER}" \
    --set=defaultServiceNetwork="${TF_SERVICE_NETWORK_NAME}" \
    --set=log.level=info \
    --wait --timeout=10m 2>&1 | tail -3
  success "Gateway API Controller running on Backend B"

  step "Creating VPC Lattice GatewayClass..."
  kubectl apply -f "${K8S_DIR}/cluster-config/gatewayclass-vpc-lattice.yaml"
  success "GatewayClass amazon-vpc-lattice created"

  step "Installing ExternalDNS (private zone)..."
  install_external_dns "${TF_PRIVATE_HZ_ID}" "private"
  success "ExternalDNS running on Backend B"

  # ── Frontend ───────────────────────────────────────────────────────────────
  use_cluster "${FRONTEND_CLUSTER}"

  step "Applying Graviton NodePool..."
  kubectl apply -f "${K8S_DIR}/cluster-config/nodepool-graviton.yaml"
  success "NodePool applied"

  step "Installing Gateway API CRDs (standard + ALB)..."
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml 2>/dev/null
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/refs/heads/main/config/crd/gateway/gateway-crds.yaml 2>/dev/null
  success "Gateway API CRDs installed"

  step "Creating service account for AWS Load Balancer Controller..."
  kubectl apply -f "${K8S_DIR}/cluster-config/aws-lbc-sa.yaml"
  success "Service account ready"

  step "Installing AWS Load Balancer Controller (Gateway API mode)..."
  FRONTEND_VPC_ID=$(aws eks describe-cluster --region "${AWS_REGION}" --name "${FRONTEND_CLUSTER}" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text)
  helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
  helm repo update 2>/dev/null
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    --set clusterName="${FRONTEND_CLUSTER}" \
    --set region="${AWS_REGION}" \
    --set vpcId="${FRONTEND_VPC_ID}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "controllerConfig.featureGates.ALBGatewayAPI=true" \
    --wait --timeout=10m 2>&1 | tail -3
  success "AWS Load Balancer Controller running (Gateway API enabled)"

  step "Creating ALB GatewayClass..."
  kubectl apply -f "${K8S_DIR}/cluster-config/gatewayclass-alb.yaml"
  success "GatewayClass aws-alb created"

  step "Installing ExternalDNS (public zone)..."
  install_external_dns "$(read_tfvar public_hosted_zone_id)" "public"
  success "ExternalDNS running on Frontend"
}


# ─── Step 5: Deploy applications ─────────────────────────────────────────────
deploy_apps() {
  banner "STEP 5 / 6 — Deploy Applications"

  load_tf_outputs

  # ── Backend A: Cart + Inventory ────────────────────────────────────────────
  use_cluster "${BACKEND_A_CLUSTER}"

  step "Deploying Cart Service..."
  kubectl apply -f "${K8S_DIR}/applications/cart-inventory-services/cart-service.yaml"
  sed "s|<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com|${ECR_BASE}|g" \
    "${K8S_DIR}/applications/cart-inventory-services/cart-deployment.yaml" | kubectl apply -f -
  success "Cart Service deployed"

  step "Deploying Inventory Service..."
  kubectl apply -f "${K8S_DIR}/applications/cart-inventory-services/inventory-service.yaml"
  sed "s|<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com|${ECR_BASE}|g" \
    "${K8S_DIR}/applications/cart-inventory-services/inventory-deployment.yaml" | kubectl apply -f -
  success "Inventory Service deployed"

  step "Waiting for pods on Backend A..."
  kubectl wait --for=condition=Ready pod -l app=cart-service --timeout=120s 2>/dev/null || warn "Cart pods not ready yet (may need more time for nodes)"
  kubectl wait --for=condition=Ready pod -l app=inventory-service --timeout=120s 2>/dev/null || warn "Inventory pods not ready yet"
  kubectl get pods
  echo ""

  # ── Backend B: Payments ────────────────────────────────────────────────────
  use_cluster "${BACKEND_B_CLUSTER}"

  step "Deploying Payments Service..."
  kubectl apply -f "${K8S_DIR}/applications/payments-service/service.yaml"
  sed "s|<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com|${ECR_BASE}|g" \
    "${K8S_DIR}/applications/payments-service/deployment.yaml" | kubectl apply -f -
  success "Payments Service deployed"

  step "Waiting for pods on Backend B..."
  kubectl wait --for=condition=Ready pod -l app=payments-service --timeout=120s 2>/dev/null || warn "Payments pods not ready yet"
  kubectl get pods
  echo ""

  # ── Frontend: Frontend + BFF ───────────────────────────────────────────────
  use_cluster "${FRONTEND_CLUSTER}"

  step "Deploying Frontend..."
  kubectl apply -f "${K8S_DIR}/applications/frontend/service.yaml"
  sed "s|<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com|${ECR_BASE}|g" \
    "${K8S_DIR}/applications/frontend/deployment.yaml" | kubectl apply -f -
  success "Frontend deployed"

  step "Deploying BFF..."
  kubectl apply -f "${K8S_DIR}/applications/bff/serviceaccount.yaml"
  kubectl apply -f "${K8S_DIR}/applications/bff/service.yaml"
  sed -e "s|<ACCOUNT_ID>.dkr.ecr.<REGION>.amazonaws.com|${ECR_BASE}|g" \
      -e "s|<PRIVATE_ZONE>|${PRIVATE_ZONE}|g" \
      -e "s|<VPCLATTICE_PROTOCOL>|${VPCLATTICE_PROTOCOL}|g" \
      -e "s|<AWS_REGION>|${AWS_REGION}|g" \
    "${K8S_DIR}/applications/bff/deployment.yaml" | kubectl apply -f -
  success "BFF deployed"

  step "Waiting for pods on Frontend cluster..."
  kubectl wait --for=condition=Ready pod -l app=frontend --timeout=120s 2>/dev/null || warn "Frontend pods not ready yet"
  kubectl wait --for=condition=Ready pod -l app=bff --timeout=120s 2>/dev/null || warn "BFF pods not ready yet"
  kubectl get pods
}

# ─── Step 6: Networking — ALB Gateway + VPC Lattice services ─────────────────
deploy_networking() {
  banner "STEP 6 / 6 — Configure Networking (ALB Gateway + VPC Lattice)"

  load_tf_outputs

  # ── Frontend: ALB Gateway ──────────────────────────────────────────────────
  use_cluster "${FRONTEND_CLUSTER}"

  if [ "${ALB_PROTOCOL}" = "HTTPS" ]; then
    step "Deploying ALB Gateway (internet-facing, HTTPS)..."
    sed -e "s|<ALB_CERTIFICATE_ARN>|${ALB_CERTIFICATE_ARN}|g" \
        -e "s|<WAF_ACL_ARN>|${TF_WAF_ACL_ARN}|g" \
        -e "s|<FRONTEND_DOMAIN_NAME>|${FRONTEND_DOMAIN}|g" \
      "${K8S_DIR}/applications/frontend/alb-gateway-https.yaml" | kubectl apply -f -
  else
    warn "ALB protocol is HTTP. Traffic between client and ALB will be unencrypted."
    warn "HTTPS is recommended for production environments."
    step "Deploying ALB Gateway (internet-facing, HTTP)..."
    sed -e "s|<WAF_ACL_ARN>|${TF_WAF_ACL_ARN}|g" \
      "${K8S_DIR}/applications/frontend/alb-gateway-http.yaml" | kubectl apply -f -
  fi
  success "ALB Gateway resources applied"

  step "Waiting for ALB to be provisioned (up to 5 min)..."
  kubectl wait --for=condition=Programmed --timeout=300s gateway/frontend-gateway 2>/dev/null \
    || warn "Gateway not yet Programmed — check: kubectl describe gateway frontend-gateway"

  ALB_HOSTNAME=$(kubectl get gateway frontend-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  if [ -n "${ALB_HOSTNAME}" ]; then
    success "ALB ready: ${ALB_HOSTNAME}"
  fi
  if [ "${ALB_PROTOCOL}" = "HTTPS" ]; then
    info "ExternalDNS will create the public DNS record for ${FRONTEND_DOMAIN}"
  else
    info "Access the frontend at: http://${ALB_HOSTNAME}"
  fi

  # ── Backend A: VPC Lattice for Items (cart + inventory) ────────────────────
  use_cluster "${BACKEND_A_CLUSTER}"

  step "Deploying VPC Lattice resources for Items service (cart + inventory)..."
  if [ "${VPCLATTICE_PROTOCOL}" = "HTTPS" ]; then
    sed -e "s|<VPCLATTICE_CERTIFICATE_ARN>|${VPCLATTICE_CERTIFICATE_ARN}|g" \
        -e "s|<ITEMS_HOSTNAME>|items.${PRIVATE_ZONE}|g" \
        -e "s|<SERVICE_NETWORK_NAME>|${TF_SERVICE_NETWORK_NAME}|g" \
        -e "s|<ITEMS_LOG_GROUP_ARN>|${TF_ITEMS_LOG_GROUP_ARN}|g" \
      "${K8S_DIR}/applications/cart-inventory-services/vpc-lattice-https.yaml" | kubectl apply -f -
  else
    warn "VPC Lattice protocol is HTTP. Traffic between BFF and backend services will be unencrypted."
    warn "HTTPS is recommended for production environments."
    sed -e "s|<ITEMS_HOSTNAME>|items.${PRIVATE_ZONE}|g" \
        -e "s|<SERVICE_NETWORK_NAME>|${TF_SERVICE_NETWORK_NAME}|g" \
        -e "s|<ITEMS_LOG_GROUP_ARN>|${TF_ITEMS_LOG_GROUP_ARN}|g" \
      "${K8S_DIR}/applications/cart-inventory-services/vpc-lattice-http.yaml" | kubectl apply -f -
  fi
  success "Items VPC Lattice resources applied"

  step "Waiting for Items VPC Lattice service (up to 5 min)..."
  wait_for_lattice_service "items-service-route"
  info "ExternalDNS will create the DNS record for items.${PRIVATE_ZONE}"

  # ── Backend B: VPC Lattice for Payments ────────────────────────────────────
  use_cluster "${BACKEND_B_CLUSTER}"

  step "Deploying VPC Lattice resources for Payments service..."
  if [ "${VPCLATTICE_PROTOCOL}" = "HTTPS" ]; then
    sed -e "s|<VPCLATTICE_CERTIFICATE_ARN>|${VPCLATTICE_CERTIFICATE_ARN}|g" \
        -e "s|<PAYMENTS_HOSTNAME>|payments.${PRIVATE_ZONE}|g" \
        -e "s|<SERVICE_NETWORK_NAME>|${TF_SERVICE_NETWORK_NAME}|g" \
        -e "s|<PAYMENTS_LOG_GROUP_ARN>|${TF_PAYMENTS_LOG_GROUP_ARN}|g" \
      "${K8S_DIR}/applications/payments-service/vpc-lattice-https.yaml" | kubectl apply -f -
  else
    sed -e "s|<PAYMENTS_HOSTNAME>|payments.${PRIVATE_ZONE}|g" \
        -e "s|<SERVICE_NETWORK_NAME>|${TF_SERVICE_NETWORK_NAME}|g" \
        -e "s|<PAYMENTS_LOG_GROUP_ARN>|${TF_PAYMENTS_LOG_GROUP_ARN}|g" \
      "${K8S_DIR}/applications/payments-service/vpc-lattice-http.yaml" | kubectl apply -f -
  fi
  success "Payments VPC Lattice resources applied"

  step "Waiting for Payments VPC Lattice service (up to 5 min)..."
  wait_for_lattice_service "payments-service-route"
  info "ExternalDNS will create the DNS record for payments.${PRIVATE_ZONE}"

  # ── Restart BFF to pick up DNS ─────────────────────────────────────────────
  use_cluster "${FRONTEND_CLUSTER}"
  step "Restarting BFF to pick up new VPC Lattice DNS entries..."
  kubectl rollout restart deployment/bff
  kubectl rollout status deployment/bff --timeout=60s 2>/dev/null || true
  success "BFF restarted"
}


# =============================================================================
#
#  TEARDOWN STEPS (reverse order)
#
# =============================================================================

teardown_networking() {
  banner "TEARDOWN 1 / 4 — Remove Networking (VPC Lattice + ALB Gateway)"

  local did_something=false

  # ── Remove VPC Lattice k8s resources ───────────────────────────────────────
  if cluster_exists "${BACKEND_A_CLUSTER}"; then
    step "Removing Items VPC Lattice resources (Backend A)..."
    use_cluster "${BACKEND_A_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/vpc-lattice-https.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/vpc-lattice-http.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    success "Items VPC Lattice resources removed"
    did_something=true
  else
    info "Cluster ${BACKEND_A_CLUSTER} not found — skipping Items VPC Lattice cleanup"
  fi

  if cluster_exists "${BACKEND_B_CLUSTER}"; then
    step "Removing Payments VPC Lattice resources (Backend B)..."
    use_cluster "${BACKEND_B_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/payments-service/vpc-lattice-https.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/payments-service/vpc-lattice-http.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    success "Payments VPC Lattice resources removed"
    did_something=true
  else
    info "Cluster ${BACKEND_B_CLUSTER} not found — skipping Payments VPC Lattice cleanup"
  fi

  # ── Remove ALB Gateway ─────────────────────────────────────────────────────
  if cluster_exists "${FRONTEND_CLUSTER}"; then
    step "Removing ALB Gateway (Frontend)..."
    use_cluster "${FRONTEND_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/frontend/alb-gateway-https.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/frontend/alb-gateway-http.yaml" --ignore-not-found --timeout=120s 2>/dev/null || true
    success "ALB Gateway removed"
    did_something=true
  else
    info "Cluster ${FRONTEND_CLUSTER} not found — skipping ALB Gateway cleanup"
  fi

  if [ "${did_something}" = true ]; then
    info "Waiting 30s for load balancer and VPC Lattice resource cleanup..."
    sleep 30
  fi
}


teardown_apps() {
  banner "TEARDOWN 2 / 4 — Remove Applications"

  if cluster_exists "${FRONTEND_CLUSTER}"; then
    step "Removing apps from Frontend cluster..."
    use_cluster "${FRONTEND_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/bff/" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/frontend/service.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/frontend/deployment.yaml" --ignore-not-found 2>/dev/null || true
    success "Frontend apps removed"
  else
    info "Cluster ${FRONTEND_CLUSTER} not found — skipping Frontend app cleanup"
  fi

  if cluster_exists "${BACKEND_A_CLUSTER}"; then
    step "Removing apps from Backend A cluster..."
    use_cluster "${BACKEND_A_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/cart-service.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/cart-deployment.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/inventory-service.yaml" --ignore-not-found 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/applications/cart-inventory-services/inventory-deployment.yaml" --ignore-not-found 2>/dev/null || true
    success "Backend A apps removed"
  else
    info "Cluster ${BACKEND_A_CLUSTER} not found — skipping Backend A app cleanup"
  fi

  if cluster_exists "${BACKEND_B_CLUSTER}"; then
    step "Removing apps from Backend B cluster..."
    use_cluster "${BACKEND_B_CLUSTER}"
    kubectl delete -f "${K8S_DIR}/applications/payments-service/" --ignore-not-found 2>/dev/null || true
    success "Backend B apps removed"
  else
    info "Cluster ${BACKEND_B_CLUSTER} not found — skipping Backend B app cleanup"
  fi
}

teardown_cluster_config() {
  banner "TEARDOWN 3 / 4 — Remove Cluster Configuration"

  load_tf_outputs_safe

  # ── Frontend ───────────────────────────────────────────────────────────────
  if cluster_exists "${FRONTEND_CLUSTER}"; then
    step "Removing controllers from Frontend cluster..."
    use_cluster "${FRONTEND_CLUSTER}"
    helm uninstall external-dns -n external-dns 2>/dev/null || true
    helm uninstall aws-load-balancer-controller -n kube-system 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/cluster-config/gatewayclass-alb.yaml" --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/cluster-config/aws-lbc-sa.yaml" --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl delete namespace external-dns --ignore-not-found --timeout=60s 2>/dev/null || true
    success "Frontend controllers removed"
  else
    info "Cluster ${FRONTEND_CLUSTER} not found — skipping Frontend controller cleanup"
  fi

  # ── Backend A ──────────────────────────────────────────────────────────────
  if cluster_exists "${BACKEND_A_CLUSTER}"; then
    step "Removing controllers from Backend A cluster..."
    use_cluster "${BACKEND_A_CLUSTER}"
    helm uninstall external-dns -n external-dns 2>/dev/null || true
    helm uninstall gateway-api-controller -n aws-application-networking-system 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/cluster-config/gatewayclass-vpc-lattice.yaml" --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl delete namespace aws-application-networking-system --ignore-not-found --timeout=60s 2>/dev/null || true
    kubectl delete namespace external-dns --ignore-not-found --timeout=60s 2>/dev/null || true
    success "Backend A controllers removed"
  else
    info "Cluster ${BACKEND_A_CLUSTER} not found — skipping Backend A controller cleanup"
  fi

  # ── Backend B ──────────────────────────────────────────────────────────────
  if cluster_exists "${BACKEND_B_CLUSTER}"; then
    step "Removing controllers from Backend B cluster..."
    use_cluster "${BACKEND_B_CLUSTER}"
    helm uninstall external-dns -n external-dns 2>/dev/null || true
    helm uninstall gateway-api-controller -n aws-application-networking-system 2>/dev/null || true
    kubectl delete -f "${K8S_DIR}/cluster-config/gatewayclass-vpc-lattice.yaml" --ignore-not-found --timeout=30s 2>/dev/null || true
    kubectl delete namespace aws-application-networking-system --ignore-not-found --timeout=60s 2>/dev/null || true
    kubectl delete namespace external-dns --ignore-not-found --timeout=60s 2>/dev/null || true
    success "Backend B controllers removed"
  else
    info "Cluster ${BACKEND_B_CLUSTER} not found — skipping Backend B controller cleanup"
  fi

  # ── Clean up DNS records left behind by ExternalDNS ────────────────────────
  # ExternalDNS creates TXT ownership records alongside the actual records.
  # Once ExternalDNS is gone, these orphaned records must be removed manually
  # so Terraform can cleanly destroy the hosted zones.
  step "Cleaning up ExternalDNS-managed DNS records..."
  cleanup_externaldns_records
  success "DNS records cleaned up"
}

teardown_infra() {
  banner "TEARDOWN 4 / 4 — Destroy Terraform Infrastructure"

  if [ ! -f "${INFRA_DIR}/terraform.tfstate" ] && [ ! -d "${INFRA_DIR}/.terraform" ]; then
    info "No Terraform state found — infrastructure already destroyed or never created"
    return
  fi

  # Check if there are any resources in state
  local resource_count
  resource_count=$(terraform -chdir="${INFRA_DIR}" state list 2>/dev/null | wc -l | tr -d ' ')
  if [ "${resource_count}" -eq 0 ]; then
    info "Terraform state is empty — nothing to destroy"
    return
  fi

  step "Destroying all Terraform-managed resources (${resource_count} resources)..."
  info "This removes VPCs, EKS clusters, IAM roles, ECR repos, VPC Lattice"
  info "service network, WAF, and Route 53 zones."
  info "Estimated time: 15-20 minutes."
  echo ""
  terraform -chdir="${INFRA_DIR}" destroy -auto-approve -input=false
  success "All infrastructure destroyed"
}


# =============================================================================
#
#  SHARED HELPERS
#
# =============================================================================

# Check if an EKS cluster exists (returns 0 if yes, 1 if no)
cluster_exists() {
  local cluster="$1"
  aws eks describe-cluster --region "${AWS_REGION}" --name "${cluster}" &>/dev/null
}

# Load Terraform outputs into variables (fails if infra not deployed)
load_tf_outputs() {
  TF_SERVICE_NETWORK_NAME="${TF_SERVICE_NETWORK_NAME:-$(terraform -chdir="${INFRA_DIR}" output -raw vpc_lattice_service_network_name)}"
  TF_PRIVATE_HZ_ID="${TF_PRIVATE_HZ_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw private_hosted_zone_id)}"
  TF_ITEMS_LOG_GROUP_ARN="${TF_ITEMS_LOG_GROUP_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw items_service_log_group_arn)}"
  TF_PAYMENTS_LOG_GROUP_ARN="${TF_PAYMENTS_LOG_GROUP_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw payments_service_log_group_arn)}"
  TF_WAF_ACL_ARN="${TF_WAF_ACL_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw frontend_waf_acl_arn)}"
  TF_BACKEND_A_VPC_ID="${TF_BACKEND_A_VPC_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw backend_a_vpc_id)}"
  TF_BACKEND_B_VPC_ID="${TF_BACKEND_B_VPC_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw backend_b_vpc_id)}"
}

# Load Terraform outputs silently (for teardown — infra may already be gone)
load_tf_outputs_safe() {
  TF_SERVICE_NETWORK_NAME="${TF_SERVICE_NETWORK_NAME:-$(terraform -chdir="${INFRA_DIR}" output -raw vpc_lattice_service_network_name 2>/dev/null || true)}"
  TF_PRIVATE_HZ_ID="${TF_PRIVATE_HZ_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw private_hosted_zone_id 2>/dev/null || true)}"
  TF_ITEMS_LOG_GROUP_ARN="${TF_ITEMS_LOG_GROUP_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw items_service_log_group_arn 2>/dev/null || true)}"
  TF_PAYMENTS_LOG_GROUP_ARN="${TF_PAYMENTS_LOG_GROUP_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw payments_service_log_group_arn 2>/dev/null || true)}"
  TF_WAF_ACL_ARN="${TF_WAF_ACL_ARN:-$(terraform -chdir="${INFRA_DIR}" output -raw frontend_waf_acl_arn 2>/dev/null || true)}"
  TF_BACKEND_A_VPC_ID="${TF_BACKEND_A_VPC_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw backend_a_vpc_id 2>/dev/null || true)}"
  TF_BACKEND_B_VPC_ID="${TF_BACKEND_B_VPC_ID:-$(terraform -chdir="${INFRA_DIR}" output -raw backend_b_vpc_id 2>/dev/null || true)}"
}

# Wait for a VPC Lattice service to be created (ARN annotation on the HTTPRoute)
wait_for_lattice_service() {
  local route_name="$1"
  local lattice_arn=""

  for i in $(seq 1 30); do
    lattice_arn=$(kubectl get httproute "${route_name}" \
      -o jsonpath='{.metadata.annotations.application-networking\.k8s\.aws/lattice-service-arn}' 2>/dev/null || true)
    if [ -n "${lattice_arn}" ]; then
      success "VPC Lattice service created: ${lattice_arn}"
      return
    fi
    info "Waiting for VPC Lattice service... (${i}/30)"
    sleep 10
  done

  warn "VPC Lattice service not ready after 5 min — check: kubectl describe httproute ${route_name}"
}


# Clean up all DNS records created by ExternalDNS in both hosted zones.
# ExternalDNS creates:
#   - Private zone: CNAME records (VPC Lattice) + TXT ownership records
#   - Public zone:  A/AAAA alias records (ALB) + TXT ownership records
# After ExternalDNS is uninstalled these become orphans and block zone deletion.
# Each zone is only cleaned when the corresponding protocol mode was active.
cleanup_externaldns_records() {
  local owner_id="${PROJECT_PREFIX}"

  # ── Private hosted zone (VPC Lattice CNAMEs + TXT) ─────────────────────────
  # ExternalDNS on the backend clusters only runs when vpclattice_protocol is
  # set (it always runs, but only creates records when services are deployed).
  # The private zone always exists, so always attempt cleanup.
  if [ -n "${TF_PRIVATE_HZ_ID:-}" ]; then
    info "Cleaning private hosted zone (${PRIVATE_ZONE})..."
    delete_records_from_zone "${TF_PRIVATE_HZ_ID}" "${owner_id}"
  fi

  # ── Public hosted zone (ALB A/AAAA aliases + TXT) ──────────────────────────
  # ExternalDNS on the frontend cluster only creates records when
  # alb_protocol = HTTPS (HTTP mode has no custom domain to register).
  if [ "${ALB_PROTOCOL}" = "HTTPS" ]; then
    local public_hz_id
    public_hz_id="$(read_tfvar public_hosted_zone_id)"
    if [ -n "${public_hz_id:-}" ]; then
      info "Cleaning public hosted zone (${public_hz_id})..."
      delete_records_from_zone "${public_hz_id}" "${owner_id}"
    fi
  else
    info "ALB protocol is HTTP — no public hosted zone records to clean up"
  fi
}

# Delete ExternalDNS-managed records from a single hosted zone.
# Identifies records by the TXT ownership prefix that ExternalDNS writes.
# Deletes: TXT records containing the owner ID, plus any A/AAAA/CNAME records
# whose name has a matching TXT ownership record.
delete_records_from_zone() {
  local zone_id="$1"
  local owner_id="$2"

  # Fetch all record sets as JSON
  local records_json
  records_json=$(aws route53 list-resource-record-sets --hosted-zone-id "${zone_id}" \
    --output json 2>/dev/null || true)
  if [ -z "${records_json}" ]; then
    info "Could not list records for zone ${zone_id} (skipped)"
    return
  fi

  # Build a batch of changes: delete TXT records that contain the ExternalDNS
  # owner string, and any A/AAAA/CNAME records at the same name.
  local changes
  changes=$(echo "${records_json}" | python3 -c "
import json, sys, re

data = json.load(sys.stdin)
records = data.get('ResourceRecordSets', [])
owner = '${owner_id}'

# ExternalDNS TXT registry uses type-prefixed names for ownership records:
#   A record at 'foo.example.com.'     → TXT at 'a-foo.example.com.'
#   AAAA record at 'foo.example.com.'  → TXT at 'aaaa-foo.example.com.'
#   CNAME record at 'foo.example.com.' → TXT at 'cname-foo.example.com.'
# It also creates a plain TXT at the same name for the heritage marker.

# Step 1: Find all TXT records that belong to this ExternalDNS owner
txt_records = []
txt_names = set()
for r in records:
    if r['Type'] == 'TXT':
        values = ''.join(v['Value'] for rr in r.get('ResourceRecords', []) for v in [rr])
        if f'external-dns/owner={owner}' in values:
            txt_records.append(r)
            txt_names.add(r['Name'])

# Step 2: Derive the actual record names from the prefixed TXT names
# e.g. 'a-foo.example.com.' → 'foo.example.com.'
actual_names = set()
for name in txt_names:
    for prefix in ('a-', 'aaaa-', 'cname-'):
        if name.startswith(prefix):
            actual_names.add(name[len(prefix):])
    # Also add the name itself (heritage TXT records use the bare name)
    actual_names.add(name)

# Step 3: Collect all records to delete
changes = []
for r in txt_records:
    changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})

for r in records:
    if r['Name'] in actual_names and r['Type'] in ('A', 'AAAA', 'CNAME'):
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})

if changes:
    print(json.dumps({'Changes': changes}))
else:
    print('')
" 2>/dev/null || true)

  if [ -n "${changes}" ]; then
    local count
    count=$(echo "${changes}" | python3 -c "import json,sys; print(len(json.load(sys.stdin)['Changes']))" 2>/dev/null || echo "?")
    info "Deleting ${count} ExternalDNS-managed record(s) from zone ${zone_id}..."
    aws route53 change-resource-record-sets --hosted-zone-id "${zone_id}" \
      --change-batch "${changes}" 2>/dev/null \
      || warn "Some records could not be deleted from zone ${zone_id}"
  else
    info "No ExternalDNS-managed records found in zone ${zone_id}"
  fi
}

# Install ExternalDNS via Helm on the current cluster context
# Usage: install_external_dns <zone_id> <zone_type>
#   zone_id   — Route 53 hosted zone ID to manage
#   zone_type — "public" or "private" (maps to --aws-zone-type)
install_external_dns() {
  local zone_id="$1"
  local zone_type="$2"
  kubectl create namespace external-dns --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "${K8S_DIR}/cluster-config/external-dns-sa.yaml"
  helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ 2>/dev/null || true
  helm repo update 2>/dev/null
  helm upgrade --install external-dns external-dns/external-dns \
    --namespace external-dns \
    --set provider.name=aws \
    --set "sources={gateway-httproute}" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=external-dns \
    --set policy=upsert-only \
    --set registry=txt \
    --set txtOwnerId="${PROJECT_PREFIX}" \
    --set "extraArgs.aws-zone-type=${zone_type}" \
    --set "extraArgs.zone-id-filter=${zone_id}" \
    --wait --timeout=5m 2>&1 | tail -3
}

# =============================================================================
#
#  MAIN — Command dispatcher
#
# =============================================================================

print_usage() {
  echo ""
  echo -e "${BOLD}Usage:${RESET}  ./manage.sh <command>"
  echo ""
  echo -e "${BOLD}Deploy commands:${RESET}"
  echo "  deploy              Full deployment (ECR → images → infra → clusters → apps → networking)"
  echo "  deploy-infra        Deploy up to infrastructure (steps 1-3: ECR + images + Terraform)"
  echo "  deploy-clusters     Deploy up to cluster config  (steps 1-4: + controllers & ExternalDNS)"
  echo "  deploy-apps         Deploy up to applications    (steps 1-5: + services on each cluster)"
  echo ""
  echo -e "${BOLD}Teardown commands:${RESET}"
  echo "  teardown            Full teardown (networking → apps → clusters → infra)"
  echo ""
  echo -e "${BOLD}Environment:${RESET}"
  echo "  AWS_REGION       Target AWS region       (default: from terraform.tfvars)"
  echo "  PROJECT_PREFIX   Resource name prefix     (default: eks-gateway-demo)"
  echo ""
}

# Helper: print deploy summary header
print_deploy_header() {
  echo -e "${DIM}  Region:   ${AWS_REGION}${RESET}"
  echo -e "${DIM}  Prefix:   ${PROJECT_PREFIX}${RESET}"
  echo -e "${DIM}  Account:  ${ACCOUNT_ID}${RESET}"
  echo -e "${DIM}  Domain:   ${FRONTEND_DOMAIN}${RESET}"
  echo ""
  check_prerequisites
}

case "${ACTION}" in
  deploy)
    banner "FULL DEPLOYMENT"
    print_deploy_header

    deploy_ecr
    deploy_images
    deploy_infra
    deploy_cluster_config
    deploy_apps
    deploy_networking

    banner "DEPLOYMENT COMPLETE 🎉"
    echo ""
    ALB_HOSTNAME=$(use_cluster "${FRONTEND_CLUSTER}" > /dev/null 2>&1 && \
      kubectl get gateway frontend-gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    if [ -n "${ALB_HOSTNAME}" ]; then
      info "Frontend ALB:  ${ALB_HOSTNAME}"
      info "Frontend URL:  https://${FRONTEND_DOMAIN}"
    fi
    info ""
    info "All three clusters are deployed and connected via VPC Lattice."
    info "Open the frontend URL to see the architecture in action."
    echo ""
    ;;

  deploy-infra)
    banner "DEPLOY — Infrastructure Only (Steps 1-3)"
    print_deploy_header

    deploy_ecr
    deploy_images
    deploy_infra

    banner "INFRASTRUCTURE DEPLOYED"
    info "ECR repos, container images, and all Terraform resources are ready."
    info ""
    info "Next steps:"
    info "  ./manage.sh deploy-clusters   # Configure EKS clusters (step 4)"
    info "  ./manage.sh deploy            # Or deploy everything at once"
    echo ""
    ;;

  deploy-clusters)
    banner "DEPLOY — Up to Cluster Configuration (Steps 1-4)"
    print_deploy_header

    deploy_ecr
    deploy_images
    deploy_infra
    deploy_cluster_config

    banner "CLUSTERS CONFIGURED"
    info "All three EKS clusters have controllers and ExternalDNS running."
    info ""
    info "Next steps:"
    info "  ./manage.sh deploy-apps   # Deploy applications (step 5)"
    info "  ./manage.sh deploy        # Or deploy everything at once"
    echo ""
    ;;

  deploy-apps)
    banner "DEPLOY — Up to Applications (Steps 1-5)"
    print_deploy_header

    deploy_ecr
    deploy_images
    deploy_infra
    deploy_cluster_config
    deploy_apps

    banner "APPLICATIONS DEPLOYED"
    info "All services are running. Networking (ALB + VPC Lattice) is not yet configured."
    info ""
    info "Next steps:"
    info "  ./manage.sh deploy   # Deploy networking (step 6) to complete the setup"
    echo ""
    ;;

  teardown)
    banner "FULL TEARDOWN"
    echo -e "${DIM}  Region:   ${AWS_REGION}${RESET}"
    echo -e "${DIM}  Prefix:   ${PROJECT_PREFIX}${RESET}"
    echo -e "${DIM}  Account:  ${ACCOUNT_ID}${RESET}"
    echo ""

    echo -e "${RED}This will destroy ALL resources created by this project.${RESET}"
    read -p "Are you sure? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      info "Teardown cancelled."
      exit 0
    fi

    teardown_networking
    teardown_apps
    teardown_cluster_config
    teardown_infra

    banner "TEARDOWN COMPLETE"
    info "All resources have been destroyed."
    echo ""
    ;;

  *)
    print_usage
    exit 1
    ;;
esac
