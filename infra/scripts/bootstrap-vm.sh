#!/usr/bin/env bash
# =============================================================================
# CloudAtlas — Bootstrap da VM (roda DENTRO da VM, como root)
#   sudo DEPLOY_USER=cloudatlas bash bootstrap-vm.sh
#
# Idempotente: pode ser executado de novo sem sobrescrever o infra/.env
# existente nem o clone do repositório.
# Não sobe os containers: isso é feito só depois do DNS apontar para a VM.
# =============================================================================
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/HigorHenrique4tech/CloudAtlas.git}"
BRANCH="${BRANCH:-main}"
DEPLOY_USER="${DEPLOY_USER:-cloudatlas}"
DEPLOY_PATH="${DEPLOY_PATH:-/app/cloudatlas}"
SWAP_GB="${SWAP_GB:-4}"

[ "$(id -u)" -eq 0 ] || { echo "Rode como root (sudo)."; exit 1; }
id "$DEPLOY_USER" >/dev/null 2>&1 || { echo "Usuário $DEPLOY_USER não existe."; exit 1; }

export DEBIAN_FRONTEND=noninteractive

echo "==> Pacotes base"
apt-get update -y
apt-get install -y ca-certificates curl git openssl ufw fail2ban unattended-upgrades

echo "==> Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
usermod -aG docker "$DEPLOY_USER"
systemctl enable --now docker

echo "==> Swap (${SWAP_GB} GB)"
if ! swapon --show | grep -q .; then
  fallocate -l "${SWAP_GB}G" /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

echo "==> Firewall (ufw) e fail2ban"
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
systemctl enable --now fail2ban
systemctl enable --now unattended-upgrades

echo "==> Repositório em $DEPLOY_PATH"
mkdir -p "$(dirname "$DEPLOY_PATH")"
chown "$DEPLOY_USER":"$DEPLOY_USER" "$(dirname "$DEPLOY_PATH")"
if [ ! -d "$DEPLOY_PATH/.git" ]; then
  sudo -u "$DEPLOY_USER" git clone --branch "$BRANCH" "$REPO_URL" "$DEPLOY_PATH"
else
  echo "    já clonado, mantendo."
fi

echo "==> infra/.env"
ENV_FILE="$DEPLOY_PATH/infra/.env"
if [ -f "$ENV_FILE" ]; then
  echo "    $ENV_FILE já existe, não será sobrescrito."
else
  umask 077
  cat > "$ENV_FILE" <<EOF
# Gerado por bootstrap-vm.sh em $(date -u +%Y-%m-%dT%H:%MZ). Nunca commitar.

# ── Banco ────────────────────────────────────────────────────────────────────
POSTGRES_USER=cloudatlas
POSTGRES_PASSWORD=$(openssl rand -hex 24)
POSTGRES_DB=cloudatlas_db

# ── App ──────────────────────────────────────────────────────────────────────
SECRET_KEY=$(openssl rand -hex 32)
# Chave Fernet das credenciais cloud. SEM ELA os dados criptografados no banco
# ficam ilegíveis: guarde uma cópia fora da VM (gerenciador de senhas).
ENCRYPTION_KEY=$(openssl rand 32 | base64 | tr '+/' '-_')
FRONTEND_URL=https://hub.cloudatlas.app.br
DESK_URL=https://desk.cloudatlas.app.br
LOG_LEVEL=INFO

# ── Monitoramento (acessível só via túnel SSH) ───────────────────────────────
GRAFANA_USER=admin
GRAFANA_PASSWORD=$(openssl rand -hex 16)
FLOWER_USER=admin
FLOWER_PASSWORD=$(openssl rand -hex 16)

# ── SSO (preencher) ──────────────────────────────────────────────────────────
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GITHUB_CLIENT_ID=
GITHUB_CLIENT_SECRET=
MICROSOFT_CLIENT_ID=
MICROSOFT_CLIENT_SECRET=
MICROSOFT_TENANT_ID=common

# ── SMTP (vazio: e-mails não são enviados; links aparecem nos logs) ──────────
SMTP_HOST=
SMTP_PORT=587
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=

# ── Pagamentos (vazio: AbacatePay desativado) ────────────────────────────────
ABACATEPAY_API_KEY=
ABACATEPAY_WEBHOOK_SECRET=

# ── Backup do Postgres no Azure Blob (preencher após criar o storage) ────────
BACKUP_AZURE_STORAGE_ACCOUNT=
BACKUP_AZURE_STORAGE_KEY=
BACKUP_AZURE_CONTAINER=cloudatlas-backups
BACKUP_RETENTION_DAYS=30
EOF
  chown "$DEPLOY_USER":"$DEPLOY_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    criado com segredos gerados (valores NÃO são exibidos)."
fi

echo
echo "Bootstrap concluído. Containers ainda NÃO foram iniciados."
