# CloudAtlas — Runbook de produção

Como subir, operar e reconstruir a produção do zero. Arquitetura: **uma VM Azure** rodando
Docker Compose (Caddy → frontends/backend → Postgres/Redis), com deploy via GitHub Actions.

| Domínio | Destino |
|---|---|
| `cloudatlas.app.br`, `www.` | Landing page (Caddy serve estático) |
| `hub.cloudatlas.app.br` | Aplicação (frontend + `/api`) |
| `desk.cloudatlas.app.br` | Portal de helpdesk |

## 1. Provisionar a VM

Na sua máquina, com `az login` feito:

```bash
bash infra/scripts/provision-azure-vm.sh
```

Cria resource group, VM Ubuntu 22.04 (`Standard_B2ms`, 8 GB), IP estático, portas 80/443 e uma
chave SSH **dedicada** (`~/.ssh/cloudatlas_deploy`). Depois roda `bootstrap-vm.sh` na VM:
Docker, swap, ufw, fail2ban, atualizações automáticas, clone do repositório em
`/app/cloudatlas` e geração do `infra/.env` com segredos aleatórios (não são exibidos).

Variáveis úteis: `VM_SIZE`, `LOCATION`, `RESOURCE_GROUP`, `YES=1` (pula a confirmação).

## 2. DNS

Registros **A** para o IP exibido no final do script:
`cloudatlas.app.br`, `www`, `hub`, `desk`. Confira com `dig +short hub.cloudatlas.app.br`.
O Caddy só emite os certificados HTTPS depois que o DNS propagou.

## 3. Configurar o `infra/.env` na VM

```bash
ssh -i ~/.ssh/cloudatlas_deploy cloudatlas@<IP>
nano /app/cloudatlas/infra/.env
```

1. **Guarde uma cópia da `ENCRYPTION_KEY` fora da VM** (gerenciador de senhas). Sem ela, as
   credenciais cloud criptografadas no banco ficam ilegíveis, inclusive nos backups.
2. Preencha as credenciais OAuth (Google/GitHub/Microsoft). Os redirect URIs devem apontar
   para `https://hub.cloudatlas.app.br/auth/<provider>/callback`.
3. Backup: preencha `BACKUP_AZURE_*` (seção 7).

## 4. GitHub: secrets e aprovação

Settings → Secrets and variables → Actions:

| Secret | Valor |
|---|---|
| `SSH_HOST` | IP da VM |
| `SSH_USER` | `cloudatlas` |
| `SSH_PRIVATE_KEY` | conteúdo de `~/.ssh/cloudatlas_deploy` |
| `DEPLOY_PATH` | `/app/cloudatlas` |

Settings → Environments → **New environment** `production` → *Required reviewers*: adicione você.
Recomendado: branch protection em `main` exigindo os jobs `backend-tests`, `migrations`,
`frontend-build` e `docker-build`.

## 5. Primeiro start

```bash
cd /app/cloudatlas
docker compose -f infra/docker-compose.prod.yml up -d --build
docker compose -f infra/docker-compose.prod.yml ps
curl -s https://hub.cloudatlas.app.br/health
```

As migrations rodam sozinhas no entrypoint do backend. A partir daí, todo push na `main` passa
pelo CI, espera a aprovação no Environment `production` e faz o deploy.

## 6. Primeiro acesso (sem SMTP)

O SMTP não está configurado, então:

- **Entre por SSO** (Google/GitHub/Microsoft): contas SSO já nascem verificadas.
- Cadastro por e-mail e senha fica bloqueado até verificar o e-mail. O link aparece nos logs:
  `docker logs cloudatlas-backend 2>&1 | grep -i "verification link"`.
- Não ative MFA por e-mail: o código não seria entregue.
- Convites de membros geram link copiável na tela de Organização.

## 7. Monitoramento e backup

Prometheus (9090), Grafana (3001) e Flower (5555) escutam só em `127.0.0.1` da VM. Acesse por túnel:

```bash
ssh -i ~/.ssh/cloudatlas_deploy -L 3001:localhost:3001 -L 5555:localhost:5555 cloudatlas@<IP>
# Grafana: http://localhost:3001   Flower: http://localhost:5555
# usuário/senha em infra/.env (GRAFANA_*, FLOWER_*)
```

**Backup diário do Postgres (03:00 UTC) no Azure Blob** — criar o storage uma vez:

```bash
az storage account create -n <nome-unico> -g cloudatlas-rg -l brazilsouth \
  --sku Standard_LRS --allow-blob-public-access false --min-tls-version TLS1_2
az storage container create --account-name <nome-unico> -n cloudatlas-backups --auth-mode login
az storage account keys list -g cloudatlas-rg -n <nome-unico> --query '[0].value' -o tsv
```

Preencha `BACKUP_AZURE_STORAGE_ACCOUNT` e `BACKUP_AZURE_STORAGE_KEY` no `.env` e rode
`docker compose -f infra/docker-compose.prod.yml up -d backup`.

Teste agora, não numa emergência:

```bash
docker exec cloudatlas-backup pg-backup          # gera um backup na hora
docker exec -it cloudatlas-backup pg-restore     # lista os backups; passe o nome para restaurar
```

## 7.1 Acesso ao banco e logs

```bash
docker compose -f infra/docker-compose.prod.yml logs -f backend
docker exec -it cloudatlas-postgres psql -U cloudatlas cloudatlas_db
```

## 8. Rollback

- **Automático:** se o healthcheck falhar após o deploy, a esteira volta para o commit anterior.
- **Manual:** `git checkout <sha> && docker compose -f infra/docker-compose.prod.yml up -d --build`.
- O rollback reverte **código, não schema**. Se o deploy aplicou uma migration destrutiva,
  restaure o backup do banco.

## 9. Reconstruir tudo

A VM é descartável; o que importa é o **banco** (backup no Blob) e a **`ENCRYPTION_KEY`**.
Refaça as seções 1 a 5 e, antes do primeiro `up`, restaure o banco com `pg-restore` usando a
mesma `ENCRYPTION_KEY` de antes (copie-a para o novo `infra/.env`).

## Limitações conhecidas

- **Ponto único de falha:** uma VM. Fora do ar até recriar. Aceito enquanto o produto é pequeno.
- **Deploy com breve indisponibilidade** durante o `up --build`.
- **AbacatePay desativado:** sem a chave, o backend devolve cobrança *mock*. Não ofereça planos
  pagos até integrar de fato.
- **SMTP desativado:** sem e-mails de verificação, convite, MFA e alertas.
- Imagens de monitoramento usam a tag `latest`; fixe versões quando estabilizar.
