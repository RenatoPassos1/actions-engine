# Convenções do repositório (Aider e afins)

> **Este arquivo existe em várias cópias de propósito.** Cada ferramenta de IA
> lê um nome diferente, e ponteiro para outro arquivo nem sempre é seguido. Por
> isso a lei está inteira aqui, e não como link. Ao alterá-la, altere em TODAS:
> `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`,
> `.cursorrules`, `.windsurfrules`, `CONVENTIONS.md`, `.junie/guidelines.md`.
>
> Vale para **todo agente**: Claude, Gemini, Antigravity, Codex, Copilot,
> Cursor, Windsurf, Aider, Junie, Devin, e o próximo que aparecer. Vale também
> para humano. Agente commita com a identidade git de quem o executa, então
> "quem foi" nunca distingue nada depois: a única defesa é a lei ser lida
> **antes**, e a trava rodar **em todo push**.

## LEI Nº 1: nenhuma credencial deste repositório pode virar saída

Este repositório é **público de propósito** (minuto de Actions ilimitado). Não
o torne privado. A contrapartida é absoluta:

- **log de run é leitura aberta**, sem nem estar logado;
- **artefato é baixável por qualquer conta do GitHub**, por 90 dias;
- robô de varredura de segredo lê os dois o dia inteiro.

Trate todo comando que roda aqui como se a saída fosse publicada num site.

### Proibido, sem exceção

1. `cat`/`head`/`base64` de arquivo de credencial (`.env`, `.pem`, `id_rsa`).
2. `env`, `printenv`, `docker exec ... env`. **Filtrar com `grep` depois não
   salva:** o mascaramento do GitHub só cobre valor registrado como secret
   **deste** repositório, então chave lida do servidor sai em texto claro.
3. `upload-artifact` de qualquer coisa com credencial dentro.
4. Segredo interpolado em comando remoto (`ssh host "echo $CHAVE > arq"`): o
   shell do runner expande antes de mandar, e a chave aparece no `ps` da
   máquina destino. Mande por **stdin (heredoc)**.
5. `echo`/`printf` de `${{ secrets.X }}`.
6. **Transformar** o segredo (`base64`, `rev`, `cut`, `tr`): a saída
   transformada **não é mascarada**, porque o mascaramento casa string exata.
7. `set -x` em passo com segredo: imprime cada comando já expandido.
8. Commitar arquivo de credencial, **inclusive doc de credenciais em markdown**.

### A forma certa

```yaml
- name: Fazer a coisa
  env:
    CHAVE: ${{ secrets.MINHA_CHAVE }}
  run: |
    ssh host 'bash -s' <<'REMOTO'
    # o valor viaja por stdin, nunca pela linha de comando
    REMOTO
```

### A trava, e a saída dela

`.github/scripts/proibir-exfiltracao.sh` roda em todo push e todo PR. Ela lê o
**padrão do comando**, não o valor.

Caso legítimo que casa com uma regra (gravar a chave SSH em `~/.ssh/` casa com
a nº 4, e é correto) se resolve com marcador **na própria linha**:

```bash
printf '%s\n' "$SSH_KEY_B64" > ~/.ssh/chave   # trava-exfiltracao: permitido grava em arquivo, nao na saida
```

**Não apague a trava e não afrouxe a regra para um passo passar.** Se precisou
disso, o passo está errado.

### Por que esta lei existe

Em **25/06/2026** o workflow `extract-env.yml` fez `cat .env.production`,
imprimiu no log e subiu o arquivo como artefato. Medido em 12/08/2026: os dois
artefatos ainda vivos, **2.224 bytes cada**, expirando só em 23/09, e os logs
respondendo HTTP 200. Foram **48 dias** com o `.env.production` de produção
baixável, contendo service role do banco, chave da Stripe, chaves da Brevo,
quatro segredos internos e o salt que desanonimiza IP.

O repositório **já tinha** secret scanning e push protection ligados, e as duas
passaram batido: elas procuram segredo **escrito no commit**, e ali não havia
segredo nenhum. Havia um comando que ia **buscar** o segredo em tempo de
execução. Nenhum scanner de conteúdo pega essa classe, hoje ou nunca.

## LEI Nº 2: workflow daqui entra na VPS, então ele é produção

A VPS Oracle hospeda LeilôAI, utilizaí, richesse e flashflow ao mesmo tempo.

- **Nunca** `docker image prune -af`, `docker builder prune -af`,
  `git reset --hard`, `git clean -fd` ou `git stash` num passo daqui: atingem
  **todos** os projetos e todas as sessões. Um `prune -af` deste repositório já
  apagou a imagem de rollback de outra sessão no meio de um deploy.
- **Nunca** editar arquivo rastreado na VPS por `sed -i`. Um workflow daqui
  injetou `ignoreBuildErrors` no `next.config.mjs` de hora em hora por semanas,
  e o efeito aparecia numa máquina onde nada local explicava a causa.
- Deploy do LeilôAI é o `scripts/deploy.sh` do repositório dele, que pega trava
  exclusiva. Não replique lógica de deploy aqui.

## LEI Nº 3: workflow que falha em laço não é inofensivo

O `leiloai-oracle-deploy.yml` falhou de hora em hora entre 09/08 e 12/08 porque
o cache do SHA implantado só era gravado **depois** do deploy bem-sucedido:
todo run via "New SHA detected" e refazia tudo, inclusive os `prune`.

Ao escrever workflow com cache de estado, grave o estado **antes** do passo que
pode falhar, ou o laço nunca fecha.
