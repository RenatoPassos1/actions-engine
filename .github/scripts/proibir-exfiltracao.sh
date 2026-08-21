#!/usr/bin/env bash
#
# LEI: nada neste repositorio pode fazer credencial virar saida.
#
# Este repositorio e PUBLICO de proposito, porque minuto de Actions em repo
# publico e ilimitado. A contrapartida e absoluta: log de run e artefato de
# repo publico sao LEITURA ABERTA (o log dispensa ate estar logado), e bot de
# varredura de segredo le os dois o dia inteiro.
#
# POR QUE ISTO EXISTE, e por que scanner nenhum resolvia
# Em 25/06/2026 o workflow `extract-env.yml` entrou aqui e rodou duas vezes.
# Ele fazia `cat .env.production > env.txt`, `cat env.txt` (imprimindo no log
# publico) e subia o arquivo como artefato `env-production`, 2.224 bytes, com
# SUPABASE_SERVICE_ROLE_KEY, STRIPE_SECRET_KEY, BREVO_*, CRON_SECRET,
# IP_HASH_SALT e mais 15 chaves. Ficou baixavel por 48 dias.
#
# O repositorio JA TINHA secret scanning e push protection ligados, e as duas
# passaram batido, porque elas procuram segredo ESCRITO NO COMMIT. Aqui nao
# havia segredo nenhum no arquivo: havia um comando que ia buscar o segredo em
# tempo de execucao. Nenhum scanner de conteudo pega isso, hoje ou nunca.
#
# Por isso a trava e sobre o PADRAO DO COMANDO, e nao sobre o valor.
#
# Roda em push e em pull_request. Falhar aqui nao e obstaculo: e a unica coisa
# entre uma linha distraida e uma credencial publica.
set -uo pipefail

FALHAS=0
ALVOS=()

# Arquivos que valem inspecao: workflow, script e composicao.
#
# A propria trava fica de fora, e nao por conveniencia: ela precisa CITAR os
# padroes proibidos para poder procura-los, entao ela sempre casaria consigo
# mesma. Na primeira versao ela se acusou na linha da regex de `env`.
EU="$(basename "${BASH_SOURCE[0]}")"
while IFS= read -r f; do
  [ "$(basename "$f")" = "$EU" ] && continue
  ALVOS+=("$f")
done < <(
  find . -type f \
    \( -path "./.github/workflows/*" -o -name "*.sh" -o -name "*.bash" \) \
    -not -path "./.git/*" -not -path "*/node_modules/*" 2>/dev/null | sort
)

# --------------------------------------------------------------------------
# LINHA NOVA REPROVA; LINHA ANTIGA SO AVISA.
#
# Isto nao e frouxidao, e a diferenca entre uma lei que entra em vigor hoje e
# uma que alguem apaga na primeira sexta-feira. Medido ao ligar esta trava no
# repositorio real: 25 acusacoes ja existentes, espalhadas por workflows de
# SEIS projetos diferentes, a maioria do mesmo `echo "${{ secrets.X }}" |
# base64 -d > ~/.ssh/chave` copiado de um para o outro. Reprovar tudo de uma
# vez travaria o deploy de todo mundo, e o desfecho previsivel seria remover a
# trava, nao consertar os 25.
#
# Entao: o que o diff INTRODUZ reprova. O passivo aparece como aviso, com
# contagem, e some a medida que cada workflow for tocado.
#
# `DIFF_BASE` vem do workflow: a base do PR, ou o commit anterior no push.
# Sem ela (execucao local, ou historico raso), NAO ha como saber o que e novo,
# e ai tudo reprova. E o lado seguro do erro: a trava nunca deixa passar por
# nao saber.
NOVAS=""
DIFF_OK=0
if [ -n "${DIFF_BASE:-}" ] && git rev-parse --verify "${DIFF_BASE}" >/dev/null 2>&1 &&
   git merge-base "${DIFF_BASE}" HEAD >/dev/null 2>&1; then
  DIFF_OK=1
  NOVAS="$(
    git diff --unified=0 "${DIFF_BASE}...HEAD" 2>/dev/null |
    awk '
      /^\+\+\+ b\// { arquivo = substr($0, 7); next }
      /^@@ / {
        # @@ -a,b +c,d @@  ->  as linhas adicionadas comecam em c
        match($0, /\+[0-9]+(,[0-9]+)?/)
        campo = substr($0, RSTART + 1, RLENGTH - 1)
        split(campo, p, ",")
        inicio = p[1] + 0
        qtd = (p[2] == "" ? 1 : p[2] + 0)
        for (i = 0; i < qtd; i++) print "./" arquivo ":" (inicio + i)
      }
    '
  )"
fi

if [ "$DIFF_OK" = "1" ]; then
  echo "Base do diff: ${DIFF_BASE} ($(printf '%s\n' "$NOVAS" | grep -c . ) linha(s) nova(s)). Linha nova reprova; passivo avisa."
else
  echo "MODO ESTRITO: sem base de diff utilizavel${DIFF_BASE:+ (${DIFF_BASE})}, entao TUDO reprova."
  echo "Se isto e um run de CI, o checkout precisa de fetch-depth: 0."
fi
echo

acusar() {
  local arquivo="$1" linha="$2" regra="$3" trecho="$4"
  # `printf %s` na comparacao evita casar "arq:1" com "arq:12".
  if [ "$DIFF_OK" = "1" ] && ! printf '%s\n' "$NOVAS" | grep -qxF "${arquivo}:${linha}"; then
    echo "::warning file=${arquivo},line=${linha}::[passivo, nao introduzido neste diff] ${regra}"
    echo "  AVISO ${arquivo}:${linha}"
    echo "    ${trecho}"
    echo "    -> ${regra}"
    echo
    return 0
  fi
  echo "::error file=${arquivo},line=${linha}::${regra}"
  echo "  ${arquivo}:${linha}"
  echo "    ${trecho}"
  echo "    -> ${regra}"
  echo
  FALHAS=$((FALHAS + 1))
}

# --------------------------------------------------------------------------
# 1. Imprimir arquivo de credencial. O `cat` de um .env vai inteiro para o log.
# --------------------------------------------------------------------------
RE_LER_ENV='(cat|less|more|head|tail|base64|xxd|od)[[:space:]]+[^|;&]*(\.env|env\.txt|credenciais|\.pem|id_[re][sd]|\.p12|serviceaccount)'

# --------------------------------------------------------------------------
# 2. Despejar o ambiente. `env`, `printenv` e `docker exec ... env` levam
#    TODA variavel de uma vez, e um `grep` depois nao salva: o mascaramento do
#    GitHub so cobre valor registrado como secret DESTE repo, entao chave que
#    veio do servidor sai em texto claro.
# --------------------------------------------------------------------------
#
#    Esta e a UNICA regra que roda sem `-i`, e o motivo e concreto: com
#    `-i`, a linha `- name: Upload Env` de um passo casa com o comando `env` e
#    a trava acusa o proprio titulo do passo. Comando de shell e minusculo, e
#    trava que grita no lugar errado e trava que alguem desliga.
RE_DESPEJAR_ENV='(^|[[:space:]`(|;&])(printenv|env)([[:space:]]*$|[[:space:]]*\||[[:space:]]*>)|docker[[:space:]]+exec[^|]*[[:space:]]env([[:space:]]|$|\|)'

# --------------------------------------------------------------------------
# 3. Subir credencial como artefato. Artefato de repo publico e baixavel por
#    qualquer conta do GitHub, e sobrevive 90 dias por padrao.
# --------------------------------------------------------------------------
#
#    So `path:`, e nunca `name:`. Com `name:` a regra acusava `- name: Cleanup
#    .env` (titulo de passo) e ate `FROM_NAME: ${{ secrets.NL_FROM_NAME }}`
#    (mapeamento de env), que sao inofensivos. E `secret` saiu da lista de
#    nomes de arquivo porque casava com a palavra `secrets.` de qualquer
#    expressao. Medido: 16 acusacoes, 9 delas falsas, antes deste corte.
RE_ARTEFATO='^[[:space:]]*path:[[:space:]]*["'"'"']?[^"'"'"'$]*(\.env|env\.txt|env-production|credenciais|\.pem|id_rsa)'

# --------------------------------------------------------------------------
# 4. Segredo interpolado DENTRO de string de comando remoto. `ssh host "echo
#    $SECRET"` resolve o valor no runner e manda o comando pronto: a chave
#    aparece no `ps` da maquina remota e em qualquer log de shell dela.
#    A forma segura e mandar por stdin ou por variavel de ambiente do ssh.
#
#    O `ssh` tem de ser COMANDO, e nao pedaco de nome. Sem o delimitador da
#    frente, a linha correta `SSH_KEY_B64: ${{ secrets.<PROJETO>_ORACLE_SSH_KEY }}`
#    (que e exatamente a forma segura, passando por `env:` do passo) seria
#    acusada, e a trava estaria ensinando o oposto do que quer.
# --------------------------------------------------------------------------
RE_SEGREDO_EM_SSH='(^|[[:space:]|;&(])(ssh|scp)[[:space:]][^#]*\$\{\{[[:space:]]*secrets\.'

# --------------------------------------------------------------------------
# 5. Ecoar segredo direto. Inclui `echo ${{ secrets.X }}` e a transformacao
#    que quebra o mascaramento: base64/rev/cut de um segredo sai limpo no log,
#    porque o GitHub so mascara a string exata que registrou.
# --------------------------------------------------------------------------
RE_ECOAR_SEGREDO='(echo|printf)[^#]*\$\{\{[[:space:]]*secrets\.'

#    Variante que escapou da regra de cima na primeira versao desta trava, e
#    que e o `inject-keys.yml` real: o segredo chega no passo por `env:` (certo)
#    e depois vira `$GROQ_API_KEY` DENTRO da string aspada do ssh. O shell do
#    runner expande antes de mandar, entao o comando que chega na VPS ja tem a
#    chave em texto, visivel no `ps` de la. Nao ha `${{ secrets }}` na linha,
#    entao so o NOME da variavel denuncia.
#    O `[^|]*$` no fim poupa `echo "$TOKEN" | comando`, que nao imprime nada.
RE_ECOAR_VAR_SEGREDA='(echo|printf)[^#|]*\$\{?[A-Za-z_]*(KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL)[^|]*$'
RE_TRANSFORMAR_SEGREDO='\$\{\{[[:space:]]*secrets\.[A-Za-z0-9_]+[[:space:]]*\}\}[[:space:]]*\|[[:space:]]*(base64|rev|cut|xxd|od|tr)'

# --------------------------------------------------------------------------
# 6. Rastro de shell num passo que tem segredo. `set -x` imprime cada comando
#    JA EXPANDIDO.
# --------------------------------------------------------------------------
RE_RASTRO='^[[:space:]]*set[[:space:]]+-[a-z]*x'

# --------------------------------------------------------------------------
# 7. Remote com credencial embutida.
# --------------------------------------------------------------------------
RE_REMOTE_COM_TOKEN='https://[^[:space:]@/]*(token|pat|ghp_|github_pat|\$\{)[^[:space:]@]*@github\.com'

# --------------------------------------------------------------------------
# 9. `pull_request_target`. Ele roda com os secrets do repositorio e com
#    permissao de escrita; junto de um checkout do HEAD do PR, e o caminho
#    classico de escalada em repositorio publico.
#
#    Medido em 20/08/2026: este repositorio tem ZERO ocorrencias, e essa e uma
#    propriedade a preservar, nao um acaso a redescobrir.
# --------------------------------------------------------------------------
RE_PR_TARGET='^[[:space:]]*pull_request_target[[:space:]]*:'

# --------------------------------------------------------------------------
# 10. Input publico que escolhe O QUE roda. `workflow_dispatch` e
#     `repository_dispatch` sao acionaveis por quem tem escrita aqui, e um
#     input `repository`, `path`, `command`, `script` ou `url` transforma o
#     workflow num executor generico. O contrato seguro e SHA de 40 hex mais
#     um modo de lista fechada.
# --------------------------------------------------------------------------
RE_INPUT_ARBITRARIO='^[[:space:]]+(repository|repo|path|command|cmd|script|url|target_repo)[[:space:]]*:[[:space:]]*$'

# Uma passada de `grep` por REGRA, e nao por linha. A versao por linha gastava
# oito processos a cada linha lida, e num workflow de 400 linhas isso passava de
# dois minutos so aqui. Trava lenta atrasa todo mundo e vira candidata a ser
# removida "so por enquanto".
varrer() {
  local sensivel="$1" regex="$2" motivo="$3"
  local flags="-nE"
  [ "$sensivel" = "ignorar-caixa" ] && flags="-nEi"
  # shellcheck disable=SC2086
  grep $flags -- "$regex" "${ALVOS[@]}" 2>/dev/null | while IFS= read -r achado; do
    local arquivo linha conteudo
    arquivo="${achado%%:*}"
    linha="${achado#*:}"; linha="${linha%%:*}"
    conteudo="${achado#*:*:}"
    # Comentario nao executa.
    case "$(printf '%s' "$conteudo" | sed 's/^[[:space:]]*//')" in \#*) continue;; esac
    # Excecao EXPLICITA e auditavel, na propria linha.
    #
    # Existe porque ha caso legitimo que casa com as regras: gravar a chave
    # SSH em ~/.ssh/oracle_key e `printf "$SSH_KEY_B64" > arquivo`, e o nome
    # da variavel tem "KEY". Sem uma saida, o proximo a esbarrar nisso apaga a
    # trava inteira "so por enquanto", e ela nunca volta. Com a saida, a
    # excecao fica escrita, com motivo, e aparece no diff de quem revisar.
    case "$conteudo" in *"trava-exfiltracao: permitido"*) continue;; esac
    acusar "$arquivo" "$linha" "$motivo" "$(printf '%s' "$conteudo" | cut -c1-120)"
  done
}

# O `while` acima roda em subshell por causa do pipe, entao o contador nao
# sobrevive a ele. Juntamos tudo num arquivo e contamos no fim.
RELATORIO="$(mktemp)"
trap 'rm -f "$RELATORIO"' EXIT
{
  varrer ignorar-caixa "$RE_LER_ENV" "imprime arquivo de credencial: o conteudo inteiro vai para o log publico"
  varrer respeitar-caixa "$RE_DESPEJAR_ENV" "despeja o ambiente: grep depois nao salva, o mascaramento so cobre secret deste repo"
  varrer ignorar-caixa "$RE_ARTEFATO" "sobe credencial como artefato: baixavel por qualquer conta do GitHub por 90 dias"
  varrer ignorar-caixa "$RE_SEGREDO_EM_SSH" "segredo interpolado em comando remoto: aparece no ps da maquina destino"
  varrer ignorar-caixa "$RE_ECOAR_SEGREDO" "ecoa segredo: use env do passo, e nunca imprima"
  varrer respeitar-caixa "$RE_ECOAR_VAR_SEGREDA" "expande variavel de segredo num echo: dentro de string de ssh ela chega em texto no ps da maquina remota. Mande por stdin (heredoc), nao pela linha de comando"
  varrer ignorar-caixa "$RE_TRANSFORMAR_SEGREDO" "transforma segredo (base64/rev/cut): a saida transformada NAO e mascarada"
  varrer respeitar-caixa "$RE_RASTRO" "set -x imprime cada comando ja expandido, inclusive os que carregam segredo"
  varrer ignorar-caixa "$RE_REMOTE_COM_TOKEN" "remote com credencial na URL: qualquer git remote -v imprime inteiro"
  varrer respeitar-caixa "$RE_PR_TARGET" "pull_request_target: roda com secrets do repositorio e, junto de checkout do HEAD do PR, e o caminho classico de escalada. Este repositorio tem ZERO ocorrencias e a meta e continuar assim"
  varrer respeitar-caixa "$RE_INPUT_ARBITRARIO" "input publico de texto livre (repository/path/command/script/url): quem dispara passa a escolher o que roda. Aceite so SHA de 40 hex e modo allowlisted"
} > "$RELATORIO"
cat "$RELATORIO"
FALHAS=$(grep -c "^::error" "$RELATORIO" 2>/dev/null); FALHAS=${FALHAS:-0}
AVISOS=$(grep -c "^::warning" "$RELATORIO" 2>/dev/null); AVISOS=${AVISOS:-0}
if [ "$AVISOS" -gt 0 ]; then
  echo "----------------------------------------------------------------"
  echo "PASSIVO: ${AVISOS} ocorrencia(s) que ja existiam antes deste diff."
  echo "Nao reprovam agora, e nao sao aceitaveis: conserte cada uma quando"
  echo "tocar no workflow dela. Nenhuma linha NOVA passa."
fi

# --------------------------------------------------------------------------
# 8. Arquivo de credencial COMMITADO.
#
#    `node_modules` fica de fora do `find`, e nao por conveniencia: o pacote
#    `ssh2` traz `test/fixtures/id_rsa` e dois `.pem` de teste, e uma arvore
#    local com dependencias instaladas fazia esta trava reprovar com tres
#    erros que nao existem no repositorio (medido em 20/08/2026, `git ls-files`
#    devolve zero para esses caminhos). Trava que reprova na maquina de quem
#    trabalha, por lixo de vendor, e trava que a pessoa aprende a ignorar. Responde direto a "nenhum agente pode
#    deployar um doc com credenciais": aqui nao entra, nem por engano.
# --------------------------------------------------------------------------
while IFS= read -r f; do
  base="$(basename "$f")"
  case "$base" in
    *.example|*.sample|*.template|*.md) continue;;
  esac
  echo "::error file=${f}::arquivo de credencial commitado em repositorio PUBLICO"
  echo "  ${f}"
  echo "    -> arquivo de credencial nao entra neste repositorio. Use secrets do GitHub."
  echo
  FALHAS=$((FALHAS + 1))
done < <(
  # QUEM RESPONDE E O GIT, e nao o `find`, porque a regra e sobre arquivo
  # COMMITADO. Medido em 20/08/2026: numa arvore de trabalho com dependencias
  # instaladas, o `find` acusava tres arquivos do pacote `ssh2`
  # (`test/fixtures/id_rsa` e dois `.pem`), que o `git ls-files` nao lista
  # porque eles nunca entraram no repositorio. Trava que reprova por lixo de
  # vendor na maquina de quem trabalha e trava que a pessoa aprende a ignorar.
  #
  # O `find` fica como reserva para execucao fora de repositorio git, e ali
  # ele exclui `node_modules` pelo mesmo motivo.
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files -- \
      '.env' '.env.*' '*credenciais*' '*credentials*' '*.pem' 'id_rsa' \
      'id_ed25519' '*.p12' '*.pfx' 'serviceaccount*.json' 2>/dev/null | sort
  else
    find . -type f \
      \( -name ".env" -o -name ".env.*" -o -iname "*credenciais*" -o -iname "*credentials*" \
         -o -name "*.pem" -o -name "id_rsa" -o -name "id_ed25519" -o -name "*.p12" \
         -o -name "*.pfx" -o -iname "serviceaccount*.json" \) \
      -not -path "./.git/*" -not -path "*/node_modules/*" 2>/dev/null | sort
  fi
)

# --------------------------------------------------------------------------
# 11 a 14. CONFERENCIAS ESTRUTURAIS: nao cabem numa regex de uma linha.
#
# As quatro nascem da migracao do CI do LeiloAI para ca (20/08/2026). O que
# elas protegem: este repositorio e PUBLICO e passou a fazer checkout de um
# repositorio PRIVADO para compilar. Isso e seguro exatamente enquanto quatro
# propriedades valerem, e nenhuma delas e visivel numa linha isolada.
# --------------------------------------------------------------------------
estrutural() {
  local f linhas l
  for f in "${ALVOS[@]}"; do
    case "$f" in *.yml|*.yaml) ;; *) continue ;; esac

    # 11. Checkout de OUTRO repositorio (o privado) sem `persist-credentials:
    #     false`. O default do actions/checkout e `true`: o token vai para o
    #     `.git/config` do workspace, e qualquer passo seguinte que rode
    #     codigo do repositorio (npm ci, postinstall, next build) consegue
    #     le-lo. Com o PAT amplo do lado, isso abre 13 projetos.
    linhas=$(awk '
      /^[[:space:]]*-[[:space:]]+uses:[[:space:]]*actions\/checkout/ {
        inicio=NR; indent=match($0,/[^ ]/); dentro=1; temrepo=0; tempersist=0; next
      }
      dentro==1 {
        if ($0 ~ /^[[:space:]]*$/) next
        ind=match($0,/[^ ]/)
        if (ind <= indent) {
          if (temrepo && !tempersist) print inicio
          dentro=0
        } else {
          if ($0 ~ /repository:/) temrepo=1
          if ($0 ~ /persist-credentials:[[:space:]]*false/) tempersist=1
        }
      }
      END { if (dentro==1 && temrepo && !tempersist) print inicio }
    ' "$f")
    for l in $linhas; do
      acusar "$f" "$l" "checkout de outro repositorio sem persist-credentials: false. O token fica no .git/config e qualquer passo seguinte que execute codigo do repo o le" "$(sed -n "${l}p" "$f" | cut -c1-120)"
    done

    # 12. Workflow que faz checkout de repositorio privado E sobe artefato ou
    #     guarda cache. Artefato de repo publico e baixavel por qualquer conta
    #     do GitHub por 90 dias; cache chaveado por lockfile privado vive
    #     aqui, num repositorio publico. Codigo privado nao atravessa nenhum
    #     dos dois.
    if grep -qE 'repository:[[:space:]]*RenatoPassos1/' "$f"; then
      linhas=$(grep -nE 'uses:[[:space:]]*actions/(upload-artifact|cache)' "$f" | cut -d: -f1)
      for l in $linhas; do
        acusar "$f" "$l" "artefato ou cache num workflow que faz checkout de repositorio privado: codigo privado nao pode atravessar armazenamento de repositorio publico" "$(sed -n "${l}p" "$f" | cut -c1-120)"
      done
    fi

    # 15. Volta da chave SSH compartilhada de producao. Medido em 21/08/2026:
    #     `ORACLE_SSH_KEY` era UMA chave, sem restricao nenhuma no
    #     `authorized_keys`, usada por 21 workflows de 4 projetos diferentes,
    #     guardada nos secrets deste repositorio, que e publico. Ela dava
    #     `ubuntu` com sudo e grupo docker na VPS de producao.
    #
    #     O problema nao e uma chave existir: e a mesma chave servir todo
    #     mundo. Chave compartilhada nao se rotaciona, porque rotacionar
    #     significa parar quatro projetos ao mesmo tempo, entao ela envelhece
    #     para sempre. E um workflow que a vaze entrega os outros tres junto.
    #
    #     Cada projeto agora tem a sua, com
    #     `restrict,no-agent-forwarding,no-port-forwarding,no-X11-forwarding`.
    #     Provado nos dois sentidos naquele dia: com a chave nova o
    #     `ssh -R` responde "remote port forwarding failed", e com a antiga o
    #     tunel abria.
    linhas=$(grep -nE 'secrets\.ORACLE_SSH_KEY\b' "$f" | grep -vE 'for nome in' | cut -d: -f1)
    for l in $linhas; do
      acusar "$f" "$l" "chave SSH compartilhada de producao: use a chave dedicada do projeto (<PROJETO>_ORACLE_SSH_KEY). Uma chave para quatro projetos nunca e rotacionada, e quem a vazar entrega os outros tres" "$(sed -n "${l}p" "$f" | cut -c1-120)"
    done

    # 13. Workflow do LeiloAI usando o PAT multiprojeto. Medido em 20/08/2026:
    #     `REPO_PAT` alcanca 13 repositorios privados, e existe
    #     `LEILOAI_STATUS_PAT` dedicado. Uma falha no caminho do LeiloAI nao
    #     pode entregar os outros doze.
    case "$(basename "$f")" in
      leiloai-*)
        linhas=$(grep -nE 'secrets\.REPO_PAT\b' "$f" | cut -d: -f1)
        for l in $linhas; do
          acusar "$f" "$l" "workflow do LeiloAI usando o REPO_PAT multiprojeto (13 repositorios). Use LEILOAI_STATUS_PAT, que alcanca 1 repositorio sem admin" "$(sed -n "${l}p" "$f" | cut -c1-120)"
        done

        # 14. Action presa a TAG num workflow do LeiloAI. Tag e movel: quem
        #     controla o repositorio da action a reaponta quando quiser, e o
        #     step herda o novo codigo sem nenhum diff aqui.
        linhas=$(grep -nE 'uses:[[:space:]]*[a-zA-Z0-9_.-]+/[a-zA-Z0-9_./-]+@(v[0-9][^[:space:]]*|main|master)[[:space:]]*$' "$f" | cut -d: -f1)
        for l in $linhas; do
          acusar "$f" "$l" "action presa a tag movel: pine por SHA de commit. Tag pode ser reapontada por quem controla a action" "$(sed -n "${l}p" "$f" | cut -c1-120)"
        done
        ;;
    esac
  done
}

RELATORIO2="$(mktemp)"
trap 'rm -f "$RELATORIO" "$RELATORIO2"' EXIT
estrutural > "$RELATORIO2"
cat "$RELATORIO2"
ERROS2=$(grep -c "^::error" "$RELATORIO2" 2>/dev/null); FALHAS=$((FALHAS + ${ERROS2:-0}))
AVISOS2=$(grep -c "^::warning" "$RELATORIO2" 2>/dev/null); AVISOS2=${AVISOS2:-0}
if [ "$AVISOS2" -gt 0 ]; then
  echo "PASSIVO ESTRUTURAL: ${AVISOS2} ocorrencia(s) anteriores a este diff."
fi

echo "----------------------------------------------------------------"
if [ "$FALHAS" -gt 0 ]; then
  echo "REPROVADO: ${FALHAS} ocorrencia(s)."
  echo
  echo "Este repositorio e publico. Log de run e artefato daqui sao leitura"
  echo "aberta, e o log nem exige estar logado. Se o comando precisa mesmo do"
  echo "segredo, ele passa por 'env:' do passo e NUNCA vai para a saida."
  echo
  echo "Nao contorne esta trava. Ela existe porque em 25/06/2026 um workflow"
  echo "daqui publicou o .env.production inteiro de producao, e ficou 48 dias"
  echo "baixavel enquanto secret scanning e push protection estavam ligados e"
  echo "nao viram nada."
  exit 1
fi
echo "APROVADO: nenhum caminho de credencial para a saida em ${#ALVOS[@]} arquivo(s)."
