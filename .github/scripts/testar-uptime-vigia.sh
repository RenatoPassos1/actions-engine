#!/usr/bin/env bash
# ============================================================================
# PROVA DAS TRES TRANSICOES DO VIGIA, SEM DERRUBAR PRODUCAO
# ============================================================================
#
# O alvo e um servidor HTTP local que este teste controla. Nada aqui toca
# leiloai.com nem a API do GitHub: o lado do GitHub vira um diario em ficheiro
# (`UPTIME_SEM_GITHUB=1`), e e o diario que o teste afere.
#
# Alerta sem controlo positivo e a doenca que motivou este trabalho: em
# 21/10/2026 o alerta de disco detectou 1436 vezes e NUNCA entregou, porque o
# envio dependia de um token que nao existia. Um teste que so confirmasse
# "detectou" teria passado naquele dia. Por isso o que se afere aqui e a
# ENTREGA (abriu, comentou, fechou), e nao a deteccao.
#
# COMO SE SIMULA "FORA DO AR": apontando o alvo para uma porta onde nada
# escuta, e nao matando o processo. A primeira versao matava o servidor com
# `kill`, e no Windows do dono isso nao matava nada: as sondagens seguiam a
# responder 200, nenhuma falha era contada, e a afirmacao "duas falhas ainda
# nao abrem" passava por NAO TER HAVIDO FALHA NENHUMA. Uma afirmacao que passa
# por vacuidade e pior que uma que reprova.
#
# As quatro perguntas:
#
#   1. SAUDAVEL  -> nao abre nada. Monitor que alerta a toa e desligado pelo
#                   dono em uma semana, e ai nao alerta mais nunca.
#   2. FALHA     -> abre DEPOIS do debounce, e nao na primeira sondagem.
#   3. REPETE    -> continua fora e NAO abre um segundo incidente (dedup).
#   4. VOLTA     -> fecha o incidente depois do debounce (recuperacao).
#
# Mais tres controlos do detector, que o codigo HTTP sozinho nao pega:
#
#   5. 200 com pagina de erro reprova (`proibe`).
#   6. 200 sem o conteudo essencial reprova (`exige`).
#   7. e a pagina boa volta a ser aprovada, para o detector nao reprovar tudo.
# ============================================================================
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VIGIA="$AQUI/leiloai-uptime-vigia.sh"
TMP="$(mktemp -d)"
PORTA="${UPTIME_PORTA_TESTE:-8099}"
PORTA_MORTA="${UPTIME_PORTA_MORTA:-8098}"
# No runner e `python3`. Na maquina Windows do dono, `python3` e um alias de
# OUTRO pacote MSIX e nao serve: ali se roda com UPTIME_PYTHON=python.
PY_BIN="${UPTIME_PYTHON:-python3}"
# 1 (padrao) = o lado do GitHub vira diario em ficheiro, e o teste nao toca a
# API. 0 = ENSAIO DE VERDADE: o mesmo roteiro, mas abrindo e fechando uma issue
# real com o token do workflow. Existe porque a doenca que motivou este
# trabalho foi um alerta que detectava e NAO entregava, cinco meses seguidos:
# so o ensaio com o token real prova a entrega. Deixa como prova uma issue
# `[uptime] ensaio fora do ar` aberta e fechada dentro da mesma corrida.
SEM_GH="${UPTIME_SEM_GITHUB:-1}"
SRV_PID=""
FALHAS=0

limpar() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2> /dev/null
  rm -rf "$TMP" 2> /dev/null
  return 0
}
trap limpar EXIT

afirma() {
  local rotulo="$1" esperado="$2" obtido="$3"
  if [ "$esperado" = "$obtido" ]; then
    echo "  [ok]    $rotulo"
  else
    echo "  [FALHA] $rotulo: esperado <$esperado>, obtido <$obtido>"
    FALHAS=$((FALHAS + 1))
  fi
}

servir() {
  mkdir -p "$TMP/www"
  printf '%s\n' "$1" > "$TMP/www/index.html"
  if [ -z "$SRV_PID" ]; then
    # `exec`: sem ele, `$!` e o subshell e o python fica orfao na porta.
    ( cd "$TMP/www" && exec "$PY_BIN" -m http.server "$PORTA" > /dev/null 2>&1 ) &
    SRV_PID=$!
  fi
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORTA/" && return 0
    sleep 0.3
  done
  echo "nao consegui subir o servidor de teste na porta $PORTA"
  exit 2
}

# Escreve a tabela de alvos. $3 e a porta: a viva serve conteudo, a morta
# recusa conexao, que e como este teste simula queda.
alvos() {
  local exige="$1" proibe="$2" porta="$3"
  printf '%s\n' "# slug	url	http	exige	proibe" > "$TMP/alvos.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' ensaio "http://127.0.0.1:$porta/" 200 "$exige" "$proibe" >> "$TMP/alvos.tsv"
  # ANTIVACUIDADE do proprio vigia: ele recusa menos de 3 alvos, entao o teste
  # precisa de tres. Os dois de enchimento apontam sempre para a porta viva.
  printf '%s\t%s\t%s\t%s\t%s\n' enchimento1 "http://127.0.0.1:$PORTA/" 200 - - >> "$TMP/alvos.tsv"
  printf '%s\t%s\t%s\t%s\t%s\n' enchimento2 "http://127.0.0.1:$PORTA/" 200 - - >> "$TMP/alvos.tsv"
}

rodar() {
  local vezes="$1" i
  for i in $(seq 1 "$vezes"); do
    UPTIME_SEM_GITHUB="$SEM_GH" \
    UPTIME_DIARIO="$TMP/diario" \
    UPTIME_ALVOS="$TMP/alvos.tsv" \
    UPTIME_ESTADO="$TMP/estado" \
    UPTIME_DEBOUNCE=3 \
    UPTIME_INTERVALO_COMENTARIO=0 \
    bash "$VIGIA" rodada >> "$TMP/saida" 2>&1
  done
}

# `grep -c` imprime 0 E devolve 1 quando nao casa, entao `|| echo 0` escrevia
# um SEGUNDO zero e a comparacao virava "0" contra "0\n0". O `head -1` fecha.
conta() { grep -c -x -F "$1" "$TMP/diario" 2> /dev/null | head -1; }

# Cada cenario comeca do zero: diario, contadores de debounce E, no ensaio com
# token real, a issue que o cenario anterior deixou aberta no GitHub.
#
# Sem esta ultima parte, os cenarios 5 e 6 reprovavam por motivo errado: o
# diario zerado dizia "nenhum incidente aberto", o GitHub dizia "ha um", e o
# vigia COMENTAVA em vez de abrir. Contagem de ABRIU=0 com o produto certo.
zerar() {
  : > "$TMP/diario"
  rm -rf "$TMP/estado"
  mkdir -p "$TMP/estado"
  [ "$SEM_GH" = "1" ] && return 0
  local n i
  for n in $(abertas_do_ensaio); do
    gh issue close "$n" --repo "${UPTIME_REPO:-$GITHUB_REPOSITORY}" \
       --comment "Fecho de limpeza entre cenarios do ensaio." > /dev/null 2>&1
  done
  # ESPERA ATE A API CONCORDAR. Fechar e pedir: a listagem ainda devolve a
  # issue por alguns segundos. Sem esta espera o cenario seguinte perguntava
  # "ha incidente aberto?", a API dizia que sim, e o vigia COMENTAVA em vez de
  # abrir: ABRIU=0 com o produto a fazer a coisa certa. Foi o unico caso que
  # sobrou reprovado no terceiro ensaio, e e defeito do ensaio, nao do vigia.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -z "$(abertas_do_ensaio)" ] && return 0
    sleep 2
  done
  echo "  [aviso] a API ainda lista a issue de ensaio como aberta apos 20 s"
  return 0
}

abertas_do_ensaio() {
  gh issue list --repo "${UPTIME_REPO:-$GITHUB_REPOSITORY}" \
     --label leiloai-uptime --state open --limit 50 --json number,title 2>/dev/null \
    | jq -r '.[] | select(.title == "[uptime] ensaio fora do ar") | .number'
}

MARCA="MARCADOR-DE-ENSAIO-UPTIME"
PAGINA_BOA="<html><body>$MARCA</body></html>"
TITULO="ABRIU|[uptime] ensaio fora do ar"
TITULO_C="COMENTOU|[uptime] ensaio fora do ar"
TITULO_F="FECHOU|[uptime] ensaio fora do ar"

zerar
: > "$TMP/saida"
servir "$PAGINA_BOA"

echo "=== 0. ANTIVACUIDADE: a porta viva responde e a morta nao ==="
viva=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORTA/")
# Sem `|| echo`: o curl ja imprime `000` quando nao conecta, e o `||` somava um
# segundo `000` ao primeiro. Mesma armadilha do `grep -c` logo abaixo.
morta=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORTA_MORTA/" 2> /dev/null)
morta="${morta:-000}"
afirma "porta viva responde 200" "200" "$viva"
afirma "porta morta nao responde" "000" "$morta"

echo "=== 1. SAUDAVEL nao abre incidente ==="
alvos "$MARCA" "Algo deu errado" "$PORTA"
rodar 4
afirma "nenhum incidente aberto com o alvo saudavel" "0" "$(conta "$TITULO")"

echo "=== 2. FALHA abre, e so DEPOIS do debounce ==="
alvos "$MARCA" "Algo deu errado" "$PORTA_MORTA"
rodar 2
afirma "duas falhas ainda nao abrem (debounce 3)" "0" "$(conta "$TITULO")"
rodar 1
afirma "a terceira falha seguida abre o incidente" "1" "$(conta "$TITULO")"

echo "=== 3. CONTINUA FORA nao abre um segundo incidente ==="
rodar 3
afirma "dedup: continua com UM incidente aberto" "1" "$(conta "$TITULO")"
if [ "$(conta "$TITULO_C")" -lt 1 ]; then
  echo "  [FALHA] continua fora e nao comentou nenhuma vez"
  FALHAS=$((FALHAS + 1))
else
  echo "  [ok]    comentou no incidente aberto em vez de abrir outro"
fi

echo "=== 4. VOLTA fecha o incidente ==="
alvos "$MARCA" "Algo deu errado" "$PORTA"
rodar 2
afirma "duas voltas ainda nao fecham (debounce 3)" "0" "$(conta "$TITULO_F")"
rodar 1
afirma "a terceira volta seguida fecha o incidente" "1" "$(conta "$TITULO_F")"

echo "=== 5. CONTROLE: 200 com pagina de erro reprova ==="
zerar
servir "<html><body>$MARCA Algo deu errado desta vez</body></html>"
alvos "$MARCA" "Algo deu errado" "$PORTA"
rodar 3
afirma "200 servindo pagina de erro vira incidente" "1" "$(conta "$TITULO")"

echo "=== 6. CONTROLE: 200 sem o conteudo essencial reprova ==="
zerar
servir "<html><body>pagina sem o conteudo que importa</body></html>"
alvos "$MARCA" "Algo deu errado" "$PORTA"
rodar 3
afirma "200 sem o conteudo essencial vira incidente" "1" "$(conta "$TITULO")"

echo "=== 7. CONTROLE NEGATIVO DO CONTROLE: o detector volta a aprovar ==="
zerar
servir "$PAGINA_BOA"
alvos "$MARCA" "Algo deu errado" "$PORTA"
rodar 4
afirma "pagina boa continua sem abrir incidente" "0" "$(conta "$TITULO")"

echo
if [ "$FALHAS" -eq 0 ]; then
  echo "TESTE DO VIGIA: PASSOU (7 cenarios, 11 afirmacoes, SEM_GITHUB=$SEM_GH)"
  exit 0
fi
echo "TESTE DO VIGIA: $FALHAS afirmacao(oes) reprovada(s)"
echo "--- saida do vigia ---"
tail -60 "$TMP/saida"
exit 1
