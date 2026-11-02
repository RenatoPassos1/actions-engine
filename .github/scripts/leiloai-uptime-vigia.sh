#!/usr/bin/env bash
# ============================================================================
# VIGIA EXTERNO DO HTTP PUBLICO DO LEILOAI
# ============================================================================
#
# POR QUE UM LACO LONGO, E NAO UM CRON DE 5 EM 5 MINUTOS
#
# O workflow declarava `cron: */5`, ou seja 288 corridas por dia. MEDIDO em
# 02/11/2026, sobre as 200 corridas mais recentes (25/09 a 02/11):
#
#     corridas por dia .......... 3 a 8
#     intervalo MEDIANO ......... 275 min  (4h35)
#     maior intervalo ........... 617 min  (10h17, em 02/11)
#
# E nao e defeito deste workflow. Os vizinhos deste mesmo repositorio, com
# crons declarados diferentes, caem todos no mesmo lugar:
#
#     leiloai-indexnow-hourly   declara `0 * * * *`   mediano 283 min
#     leiloai-cron-monitor      declara `*/30`        mediano 284 min
#     leiloai-uptime-check      declara `*/5`         mediano 275 min
#
# Tres cadencias declaradas diferentes e UMA cadencia real. O `cron` declarado
# nao governa nada aqui: o agendador do GitHub entrega ~5 eventos por dia a
# este repositorio, que tem 40 workflows com `schedule:`. Pedir mais vezes nao
# traz mais vezes.
#
# A consequencia medida: o banco de producao morreu em 21/10/2026 00:45 UTC e a
# primeira issue de incidente saiu em 23/10 05:42. Com janela cega de ate 10h,
# "monitor de 5 minutos" era so o que estava escrito no ficheiro.
#
# Entao este script NAO depende da frequencia do agendador. Ele roda UM laco
# longo (ate ~5h30, abaixo do tecto de 6h do job) sondando de 2 em 2 minutos. O
# `concurrency` do workflow com `cancel-in-progress: false` faz a corrida
# seguinte ficar NA FILA ate esta acabar, e assumir em seguida. Ou seja: o
# agendador so precisa acertar uma vez a cada 5h30, e isso ele faz.
#
# ============================================================================
# O QUE E "FORA DO AR" AQUI
# ============================================================================
#
# Codigo HTTP sozinho nao serve. A home ja serviu 200 com "Algo deu errado
# desta vez" no lugar do conteudo. Cada alvo declara, em
# `leiloai-uptime-alvos.tsv`, o codigo esperado, uma substring que TEM de
# aparecer e uma que NAO pode aparecer. Alvo 3xx confere o inicio do Location,
# e nao o corpo.
#
# DEBOUNCE: um alvo precisa falhar 3 sondagens seguidas (~6 min) para virar
# alerta, e passar 3 seguidas para virar recuperacao. O cabecalho antigo deste
# workflow prometia "2 checks consecutivos" e o codigo abria issue na PRIMEIRA
# falha; a promessa estava no comentario e nao no codigo.
#
# DEDUP: no maximo UMA issue aberta por alvo, reaproveitada. Enquanto o alvo
# segue fora, comenta no maximo 1x por hora.
#
# RECUPERACAO: ao voltar, comenta e FECHA a issue. Sem isto o quadro fica
# vermelho para sempre e deixa de ser sinal: em 02/11/2026 havia 15 issues
# `incident` abertas, de 16, 20 e 23/10, todas ja resolvidas havia dias.
#
# ============================================================================
# O QUE ESTE SCRIPT NUNCA IMPRIME
# ============================================================================
#
# Este repositorio e PUBLICO: log e artefato sao leitura aberta. O corpo da
# resposta, o Location e os cabecalhos NUNCA sao impressos nem postados. Sai
# apenas: slug, codigo HTTP de tres digitos e um motivo escolhido de uma lista
# fixa daqui. Quem responde a requisicao nao escolhe nenhum texto que saia no
# log ou na issue.
# ============================================================================
set -uo pipefail

MODO="${1:-vigia}"
MINUTOS="${UPTIME_MINUTOS:-330}"
INTERVALO="${UPTIME_INTERVALO:-120}"
DEBOUNCE="${UPTIME_DEBOUNCE:-3}"
INTERVALO_COMENTARIO="${UPTIME_INTERVALO_COMENTARIO:-3600}"
AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALVOS_ARQ="${UPTIME_ALVOS:-$AQUI/leiloai-uptime-alvos.tsv}"
REPO="${UPTIME_REPO:-${GITHUB_REPOSITORY:-}}"
# Em teste, o lado do GitHub vira um diario em ficheiro: a logica de debounce,
# dedup e recuperacao fica exercitavel sem token e sem issue de verdade.
SEM_GITHUB="${UPTIME_SEM_GITHUB:-0}"
DIARIO="${UPTIME_DIARIO:-}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

agora() { date -u +%s; }
carimbo() { date -u +%Y-%m-%dT%H:%M:%SZ; }
diz() { echo "[$(carimbo)] $*"; }

# --- sondagem -------------------------------------------------------------
# Devolve "ok|<cod>|" ou "falha|<cod>|<motivo>". O motivo vem desta funcao,
# nunca da resposta.
sondar() {
  local url="$1" esperado="$2" exige="$3" proibe="$4"
  local corpo="$TMP/corpo" cabec="$TMP/cabec" cod loc
  : > "$corpo"
  : > "$cabec"
  cod=$(curl -sS -o "$corpo" -D "$cabec" -w '%{http_code}' \
        --max-time 20 --connect-timeout 10 \
        -A 'LeiloAI-Uptime/2.0 (+https://leiloai.com)' \
        "$url" 2>/dev/null)
  case "${cod:-}" in
    [0-9][0-9][0-9]) ;;
    *) cod="000" ;;
  esac

  if [ "$cod" = "000" ]; then
    echo "falha|000|sem resposta: tempo esgotado, DNS ou conexao recusada"
    return
  fi
  if [ "$cod" != "$esperado" ]; then
    echo "falha|$cod|HTTP inesperado, esperado $esperado"
    return
  fi
  if [ "$exige" != "-" ]; then
    case "$esperado" in
      3??)
        loc=$(grep -i '^location:' "$cabec" | tail -1 | tr -d '\r' \
              | sed 's/^[Ll]ocation:[[:space:]]*//')
        case "$loc" in
          "$exige"*) : ;;
          *) echo "falha|$cod|redirect para destino diferente do esperado"; return ;;
        esac
        ;;
      *)
        if ! grep -qF -- "$exige" "$corpo"; then
          echo "falha|$cod|conteudo essencial ausente na resposta"
          return
        fi
        ;;
    esac
  fi
  if [ "$proibe" != "-" ] && grep -qF -- "$proibe" "$corpo"; then
    echo "falha|$cod|pagina de erro servida com HTTP $cod"
    return
  fi
  echo "ok|$cod|"
}

# --- lado do GitHub -------------------------------------------------------
titulo_de() { echo "[uptime] $1 fora do ar"; }

registrar() {
  [ -n "$DIARIO" ] && echo "$1" >> "$DIARIO"
  return 0
}

# Imprime o numero da issue aberta daquele alvo, ou nada.
numero_da_issue() {
  local titulo="$1"
  if [ "$SEM_GITHUB" = "1" ]; then
    [ -n "$DIARIO" ] || return 0
    local abriu fechou
    # `grep -c` imprime 0 E devolve 1 quando nao casa. Com `|| echo 0` a
    # variavel ficava "0\n0", o `-gt` seguinte dava erro de sintaxe, a funcao
    # devolvia vazio e isso quer dizer "nao ha incidente aberto": o dedup
    # desligava exatamente no caso que existe para cobrir. O `head -1` fecha.
    abriu=$(grep -c -x -F "ABRIU|$titulo" "$DIARIO" 2>/dev/null | head -1)
    fechou=$(grep -c -x -F "FECHOU|$titulo" "$DIARIO" 2>/dev/null | head -1)
    [ "$abriu" -gt "$fechou" ] && echo 1
    return 0
  fi
  gh issue list --repo "$REPO" --label leiloai-uptime --state open --limit 100 \
     --json number,title --jq ".[] | select(.title == \$t) | .number" \
     --arg t "$titulo" 2>/dev/null | head -1
}

abrir_ou_comentar() {
  local slug="$1" url="$2" cod="$3" motivo="$4"
  local titulo n corpo ultimo agora_s
  titulo="$(titulo_de "$slug")"
  n="$(numero_da_issue "$titulo")"
  if [ -n "$n" ]; then
    ultimo=$(cat "$ESTADO/$slug.comentou" 2>/dev/null || echo 0)
    agora_s=$(agora)
    if [ $((agora_s - ultimo)) -lt "$INTERVALO_COMENTARIO" ]; then
      diz "  (incidente de $slug ja aberto e comentado ha pouco; nao repito)"
      return 0
    fi
    echo "$agora_s" > "$ESTADO/$slug.comentou"
    diz "  COMENTA no incidente aberto de $slug"
    registrar "COMENTOU|$titulo"
    [ "$SEM_GITHUB" = "1" ] && return 0
    gh issue comment "$n" --repo "$REPO" \
       --body "Continua fora. HTTP $cod. $motivo. $(carimbo)" > /dev/null
    return 0
  fi
  corpo="$(printf '%s\n' \
    "O alvo \`$slug\` ($url) falhou $DEBOUNCE sondagens seguidas." \
    "" \
    "HTTP: $cod" \
    "Motivo: $motivo" \
    "Detectado em: $(carimbo)" \
    "" \
    "Esta issue fecha sozinha quando o alvo voltar e passar $DEBOUNCE sondagens seguidas.")"
  echo "$(agora)" > "$ESTADO/$slug.comentou"
  diz "  ABRE incidente para $slug"
  registrar "ABRIU|$titulo"
  [ "$SEM_GITHUB" = "1" ] && return 0
  gh issue create --repo "$REPO" --title "$titulo" \
     --label incident --label leiloai-uptime --body "$corpo" > /dev/null
}

fechar_incidente() {
  local slug="$1" titulo n
  titulo="$(titulo_de "$slug")"
  n="$(numero_da_issue "$titulo")"
  [ -z "$n" ] && return 0
  diz "  FECHA incidente de $slug (recuperado)"
  registrar "FECHOU|$titulo"
  rm -f "$ESTADO/$slug.comentou"
  [ "$SEM_GITHUB" = "1" ] && return 0
  gh issue close "$n" --repo "$REPO" \
     --comment "Recuperado: $DEBOUNCE sondagens seguidas no estado esperado. $(carimbo)" > /dev/null
}

# --- estado do debounce ---------------------------------------------------
#
# EM FICHEIRO, e nao em variavel do processo. Duas razoes, e a segunda e a que
# importa: (1) o laco longo pode ser interrompido e retomado sem perder a
# contagem; (2) o teste consegue exercitar a MESMA logica chamando o modo
# `rodada` varias vezes. Com a contagem em memoria, cada chamada do teste
# comecava do zero e o debounce nunca era atravessado: o teste passava sem
# nunca ter exercitado o caminho que roda em producao. Medido ao escrever este
# teste, em 02/11/2026: o cenario de falha mostrava "1/3" tres vezes seguidas.
ESTADO="${UPTIME_ESTADO:-$TMP/estado}"
mkdir -p "$ESTADO"

ler_contador() { cat "$ESTADO/$1.$2" 2> /dev/null || echo 0; }
gravar_contador() { echo "$3" > "$ESTADO/$1.$2"; }

ler_alvos() { grep -v '^#' "$ALVOS_ARQ" | grep -v '^[[:space:]]*$'; }

uma_rodada() {
  local slug url esperado exige proibe r estado cod motivo n_falhas n_oks alerta
  while IFS=$'\t' read -r slug url esperado exige proibe; do
    [ -z "${slug:-}" ] && continue
    r="$(sondar "$url" "$esperado" "${exige:--}" "${proibe:--}")"
    estado="${r%%|*}"
    r="${r#*|}"
    cod="${r%%|*}"
    motivo="${r#*|}"
    alerta="$(ler_contador "$slug" alerta)"
    if [ "$estado" = "ok" ]; then
      n_oks=$(( $(ler_contador "$slug" oks) + 1 ))
      gravar_contador "$slug" oks "$n_oks"
      gravar_contador "$slug" falhas 0
      diz "ok    $slug [$cod]"
      if [ "$alerta" = "1" ] && [ "$n_oks" -ge "$DEBOUNCE" ]; then
        fechar_incidente "$slug"
        gravar_contador "$slug" alerta 0
      fi
    else
      n_falhas=$(( $(ler_contador "$slug" falhas) + 1 ))
      gravar_contador "$slug" falhas "$n_falhas"
      gravar_contador "$slug" oks 0
      diz "FALHA $slug [$cod] $n_falhas/$DEBOUNCE: $motivo"
      if [ "$n_falhas" -ge "$DEBOUNCE" ]; then
        abrir_ou_comentar "$slug" "$url" "$cod" "$motivo"
        gravar_contador "$slug" alerta 1
      fi
    fi
  done < <(ler_alvos)
}

case "$MODO" in
  vigia)
    [ -s "$ALVOS_ARQ" ] || { echo "ALVOS VAZIOS em $ALVOS_ARQ"; exit 2; }
    n_alvos=$(ler_alvos | wc -l)
    # ANTIVACUIDADE: varredura que nao acha alvo aprova para sempre.
    [ "$n_alvos" -ge 3 ] || { echo "ANTIVACUIDADE: so $n_alvos alvos em $ALVOS_ARQ"; exit 2; }
    diz "vigia: $n_alvos alvos, $MINUTOS min, sondagem a cada ${INTERVALO}s, debounce $DEBOUNCE"
    fim=$(( $(agora) + MINUTOS * 60 ))
    rodadas=0
    while [ "$(agora)" -lt "$fim" ]; do
      uma_rodada
      rodadas=$((rodadas + 1))
      [ "$(agora)" -ge "$fim" ] && break
      sleep "$INTERVALO"
    done
    diz "fim do laco: $rodadas rodadas"
    ;;
  rodada)
    uma_rodada
    ;;
  *)
    echo "modo desconhecido: $MODO (use vigia ou rodada)"
    exit 2
    ;;
esac
