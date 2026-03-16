# Actions Engine

Repositório centralizado de workflows GitHub Actions para CI/CD de projetos privados.

## Como funciona

- Os workflows (.yml) ficam neste repositório
- Cada workflow faz checkout do repositório privado correspondente via PAT
- Executa o pipeline (build, deploy, etc.) e envia o resultado ao destino

## Segurança

- Nenhum código-fonte é armazenado neste repo — apenas workflows
- Todos os secrets ficam protegidos no GitHub Secrets
- O PAT tem escopo mínimo necessário
