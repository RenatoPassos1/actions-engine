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
    -not -path "./.git/*" 2>/dev/null | sort
)

acusar() {
  local arquivo="$1" linha="$2" regra="$3" trecho="$4"
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
RE_ARTEFATO='(path|name):[[:space:]]*["'"'"']?[^"'"'"']*(\.env|env\.txt|env-production|credenciais|secret|\.pem|id_rsa)'

# --------------------------------------------------------------------------
# 4. Segredo interpolado DENTRO de string de comando remoto. `ssh host "echo
#    $SECRET"` resolve o valor no runner e manda o comando pronto: a chave
#    aparece no `ps` da maquina remota e em qualquer log de shell dela.
#    A forma segura e mandar por stdin ou por variavel de ambiente do ssh.
#
#    O `ssh` tem de ser COMANDO, e nao pedaco de nome. Sem o delimitador da
#    frente, a linha correta `SSH_KEY_B64: ${{ secrets.ORACLE_SSH_KEY }}`
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
} > "$RELATORIO"
cat "$RELATORIO"
FALHAS=$(grep -c "^::error" "$RELATORIO" 2>/dev/null || echo 0)

# --------------------------------------------------------------------------
# 8. Arquivo de credencial COMMITADO. Responde direto a "nenhum agente pode
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
  find . -type f \
    \( -name ".env" -o -name ".env.*" -o -iname "*credenciais*" -o -iname "*credentials*" \
       -o -name "*.pem" -o -name "id_rsa" -o -name "id_ed25519" -o -name "*.p12" \
       -o -name "*.pfx" -o -iname "serviceaccount*.json" \) \
    -not -path "./.git/*" 2>/dev/null | sort
)

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
