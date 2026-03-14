# Actions Engine

Repositório **público** centralizado para rodar GitHub Actions de todos os projetos privados.

> Repos públicos têm Actions **ilimitados e gratuitos**. Este repo contém apenas os workflows YAML — nenhum código-fonte é exposto.

## Arquitetura

```
┌─────────────────────────────────────────────────────┐
│  actions-engine (PÚBLICO)                           │
│  Contém apenas workflows .yml                       │
│                                                     │
│  ┌─────────────────┐  ┌──────────────────────────┐  │
│  │ Checkout repo   │→ │ Roda pipeline/scripts    │  │
│  │ privado via PAT │  │ do repo privado          │  │
│  └─────────────────┘  └──────────┬───────────────┘  │
│                                  │                  │
│                    ┌─────────────▼──────────────┐   │
│                    │ Commita + Push no repo     │   │
│                    │ privado + Deploy Hostinger │   │
│                    └───────────────────────────-┘   │
└─────────────────────────────────────────────────────┘
```

## Workflows

| Workflow | Projeto | Frequência | O que faz |
|---|---|---|---|
| `satoshis-house-content.yml` | satoshi-s-house | A cada hora (24x/dia) | Gera 2 notícias crypto, builda HTML, commita e faz deploy SSH |
| `satoshis-house-reports.yml` | satoshi-s-house | Semanal (sex) + Mensal | Gera relatórios de mercado, commita e faz deploy FTP |
| `satoshis-house-newsletter.yml` | satoshi-s-house | Sex 18h + Seg 9h BRT | Envia newsletter por email |
| `site-noticias-bot.yml` | site-noticias-bot | 3x/dia (8h, 12h, 18h BRT) | Atualiza feed de notícias Vektor, deploy FTP |
| `vektor-consultoria.yml` | vektor-consultoria + VEKTOR-WEB-BACKUP | Seg (revops) + 3x/dia (articles) | Gera artigos RevOps e páginas de notícias |

## Deploys on-push (continuam nos repos privados)

Estes workflows são leves e rodam apenas no push — ficam nos repos privados:

| Repo | Workflow | Trigger |
|---|---|---|
| satoshi-s-house | `deploy.yml` | Push em `public_html/**` |
| vektor-web-site | `deploy.yml` | Push em `public_html/**` |
| vektor-consultoria | `deploy-hostinger.yml` | Push em `public_html/**` |
| fides-protocol | `deploy.yml` | Push em main |
| neuro-via | `deploy.yml` | Push em main |
| game-subway | `deploy-frontend.yml` | Push em `packages/frontend/**` |
| tudo-venda | `deploy-frontend.yml` | Push em `frontend/**` |

## Secrets necessários

### Gerais
| Secret | Descrição |
|---|---|
| `REPO_PAT` | Personal Access Token com permissão `repo` para clonar repos privados |

### API Keys (compartilhadas)
`GEMINI_API_KEY`, `GROQ_API_KEY`, `XAI_API_KEY`, `LLAMA_API_KEY`, `MISTRAL_API_KEY`, `OPENAI_API_KEY`, `DEEPSEEK_API_KEY`, `CMC_API_KEY`, `REVOPS_OPENAI_KEY`

### Satoshi's House — SSH Deploy
`SH_SSH_HOST`, `SH_SSH_USER`, `SH_SSH_PASS`, `SH_SSH_PORT`

### Satoshi's House — FTP Deploy
`SH_FTP_HOST`, `SH_FTP_USER`, `SH_FTP_PASS`

### Satoshi's House — Newsletter
`NL_API_URL`, `NL_API_KEY`, `NL_SMTP_HOST`, `NL_SMTP_PORT`, `NL_SMTP_USER`, `NL_SMTP_PASS`, `NL_FROM_EMAIL`, `NL_FROM_NAME`, `NL_SITE_URL`

### Notícias Bot — FTP Deploy
`NB_FTP_HOST`, `NB_FTP_USER`, `NB_FTP_PASS`, `NB_REMOTE_DIR`

### Vektor — FTP Deploy
`VK_FTP_HOST`, `VK_FTP_USER`, `VK_FTP_PASS`

## Segurança

- Nenhum código-fonte é armazenado neste repo
- Todos os secrets ficam protegidos no GitHub Secrets
- O PAT deve ter escopo mínimo: apenas `repo`
- Revogue e regenere o PAT periodicamente
