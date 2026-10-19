#!/usr/bin/env bash
# =============================================================================
# CloudAtlas — Provisiona a VM de produção no Azure
#
# Rode na SUA máquina, uma única vez, com o az CLI instalado e `az login` feito.
#   bash infra/scripts/provision-azure-vm.sh
#
# O que faz: resource group, VM Ubuntu 22.04 com IP estático, portas 80/443,
# chave SSH dedicada ao deploy e execução do bootstrap-vm.sh dentro da VM.
# Cria recursos pagos: o script mostra a assinatura e pede confirmação.
#
# Todas as variáveis abaixo podem ser sobrescritas pelo ambiente.
# =============================================================================
set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-cloudatlas-rg}"
LOCATION="${LOCATION:-brazilsouth}"
VM_NAME="${VM_NAME:-cloudatlas-vm}"
VM_SIZE="${VM_SIZE:-Standard_B2ms}"      # 2 vCPU, 8 GB RAM
VM_USER="${VM_USER:-cloudatlas}"
OS_DISK_GB="${OS_DISK_GB:-64}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/cloudatlas_deploy}"   # chave dedicada, não reaproveita a pessoal

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v az >/dev/null || { echo "az CLI não encontrado."; exit 1; }
az account show >/dev/null 2>&1 || { echo "Faça 'az login' antes de rodar."; exit 1; }

echo "Assinatura : $(az account show --query name -o tsv) ($(az account show --query id -o tsv))"
echo "Criará     : grupo $RESOURCE_GROUP, VM $VM_NAME ($VM_SIZE) em $LOCATION, disco ${OS_DISK_GB} GB"
if [ "${YES:-0}" != "1" ]; then
  read -r -p "Continuar? [s/N] " ans
  [[ "$ans" =~ ^[sSyY]$ ]] || { echo "Cancelado."; exit 1; }
fi

# ── Chave SSH dedicada ───────────────────────────────────────────────────────
if [ ! -f "$SSH_KEY" ]; then
  echo "==> Gerando chave SSH dedicada: $SSH_KEY"
  ssh-keygen -t ed25519 -N "" -C "cloudatlas-deploy" -f "$SSH_KEY"
fi

echo "==> [1/5] Resource group"
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo "==> [2/5] VM (IP público estático)"
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --image Ubuntu2204 \
  --size "$VM_SIZE" \
  --os-disk-size-gb "$OS_DISK_GB" \
  --admin-username "$VM_USER" \
  --authentication-type ssh \
  --ssh-key-values "${SSH_KEY}.pub" \
  --public-ip-sku Standard \
  --public-ip-address-allocation static \
  --output none

VM_IP=$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" --query publicIps -o tsv)
echo "    IP: $VM_IP"

echo "==> [3/5] Liberando 80 e 443 no NSG (22 já vem liberado; ssh só com chave)"
az vm open-port --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --port 80,443 --priority 1010 --output none

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

echo "==> [4/5] Aguardando SSH"
for i in $(seq 1 30); do
  ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" true 2>/dev/null && break
  [ "$i" = 30 ] && { echo "SSH não respondeu a tempo."; exit 1; }
  sleep 5
done

echo "==> [5/5] Executando bootstrap dentro da VM"
scp "${SSH_OPTS[@]}" "$SCRIPT_DIR/bootstrap-vm.sh" "$VM_USER@$VM_IP:/tmp/bootstrap-vm.sh"
ssh "${SSH_OPTS[@]}" "$VM_USER@$VM_IP" "sudo DEPLOY_USER=$VM_USER bash /tmp/bootstrap-vm.sh"

cat <<EOF

============================================================
 VM provisionada
============================================================
 IP público : $VM_IP
 SSH        : ssh -i $SSH_KEY $VM_USER@$VM_IP

 Próximos passos (detalhes em infra/RUNBOOK.md):
  1. DNS — registros A apontando para $VM_IP:
       cloudatlas.app.br, www, hub, desk
  2. Secrets do GitHub (Settings > Secrets > Actions):
       SSH_HOST=$VM_IP   SSH_USER=$VM_USER
       SSH_PRIVATE_KEY=<conteúdo de $SSH_KEY>
       DEPLOY_PATH=/app/cloudatlas
  3. Preencha OAuth em /app/cloudatlas/infra/.env (na VM) e faça backup
     da ENCRYPTION_KEY gerada.
  4. Primeiro start (só depois do DNS propagar):
       cd /app/cloudatlas && docker compose -f infra/docker-compose.prod.yml up -d --build
============================================================
EOF
