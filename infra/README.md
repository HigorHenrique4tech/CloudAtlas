# CloudAtlas — Infraestrutura

## Estrutura

```
infra/
├── docker/
│   ├── backend.prod.Dockerfile      # Backend: multi-stage, gunicorn, non-root user
│   ├── frontend.prod.Dockerfile     # Frontend: multi-stage, npm build → nginx
│   └── nginx.conf                   # SPA routing, gzip, proxy /api → backend
├── monitoring/
│   ├── prometheus.yml               # Scrape config (backend:8000/metrics)
│   └── grafana/
│       ├── provisioning/            # Auto-provisiona datasource + dashboard
│       └── dashboards/
│           └── cloudatlas.json      # Dashboard pré-pronto
├── docker-compose.prod.yml          # Produção: postgres + backend + frontend + prometheus + grafana
└── README.md                        # Este arquivo

.github/workflows/
└── ci.yml                           # CI + CD (deploy-prod com aprovação e rollback)
```

---

## Rodar em Produção (local)

### Pré-requisitos
- Docker e Docker Compose instalados
- Arquivo `.env` na raiz do projeto com todas as variáveis

### Subir

```bash
cd infra
docker compose -f docker-compose.prod.yml up -d --build
```

### Acessar

| Serviço | URL |
|---------|-----|
| Frontend | http://localhost |
| Backend API | http://localhost/api/v1 (via nginx proxy) |
| API Docs | http://localhost:8000/docs (direto no backend) |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3001 |

### Credenciais Grafana

- **User:** `admin` (ou `GRAFANA_USER` do .env)
- **Password:** `admin` (ou `GRAFANA_PASSWORD` do .env)
- Dashboard pré-carregado: **CloudAtlas - API Monitoring**

### Parar

```bash
docker compose -f docker-compose.prod.yml down
```

Para limpar volumes (dados):
```bash
docker compose -f docker-compose.prod.yml down -v
```

---

## Diferenças Dev vs Prod

| Aspecto | Dev (`docker-compose.yml`) | Prod (`docker-compose.prod.yml`) |
|---------|---------------------------|----------------------------------|
| Backend | uvicorn --reload, volume mount | gunicorn 4 workers, imagem otimizada |
| Frontend | Vite dev server (HMR) | nginx servindo build estático |
| Logging | Texto simples | JSON estruturado |
| Métricas | Não | Prometheus + Grafana |
| Portas | 3000 (frontend), 8000 (backend) | 80 (nginx), 9090, 3001 |
| Debug | True | False |
| User | root | appuser (UID 1000) |

---

## CI/CD — GitHub Actions

Um único workflow, `.github/workflows/ci.yml`:

| Job | Quando | Bloqueante |
|-----|--------|:----------:|
| `backend-tests` (pytest) | PR e push em `dev`/`main` | ✅ |
| `migrations` (alembic em Postgres limpo) | idem | ✅ |
| `frontend-build` (vite) | idem | ✅ |
| `docker-build` (imagem do backend) | idem | ✅ |
| `frontend-quality` (eslint + vitest) | idem | ❌ (informativo) |
| `deploy-prod` | só push em `main` | exige aprovação manual |

`deploy-prod` roda no Environment `production`: após a aprovação faz SSH na VM,
`git pull` + `docker compose up -d --build`, valida `/health` e, se falhar, volta
para o commit anterior. O rollback reverte o **código**, não o banco.

Secrets (Settings → Secrets → Actions): `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`,
`DEPLOY_PATH` (opcional `SSH_PORT`). Variável opcional: `HEALTH_URL`.

Provisionamento da VM do zero, DNS, secrets, acesso ao monitoramento e backup:
veja o **[RUNBOOK.md](RUNBOOK.md)**.

---

## Monitoring — Endpoints

| Endpoint | Descrição |
|----------|-----------|
| `GET /health` | Health check com verificação de DB |
| `GET /metrics` | Métricas Prometheus (request rate, latency, errors) |
| `GET /` | Health check simples |

### Métricas Disponíveis

- `http_requests_total` — Total de requests por método/endpoint/status
- `http_request_duration_seconds` — Histograma de latência
- `http_requests_in_progress` — Requests ativos no momento
- `http_request_size_bytes` — Tamanho dos requests
- `http_response_size_bytes` — Tamanho das respostas
