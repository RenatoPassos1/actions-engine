#!/usr/bin/env bash
#
# Testes da regra de elegibilidade do coordenador da fila
# (`leiloai-fila-elegiveis.jq`) e das partes do `leiloai-coordenador-fila.yml`
# que dependem dela.
#
# Sem rede e sem credencial: a regra e um filtro jq puro sobre vereditos ja
# colhidos, e aqui os vereditos sao montados a mao, inclusive um replay de um
# caso real de 21/09/2026.
#
# CONTROLE NEGATIVO EMBUTIDO. `REGRA=antiga` troca o filtro pela regra que
# vigorou ate 20/09/2026 ("so o veredito de fila decide") e muta o workflow de
# volta a ela. Os testes que protegem contra merge com CI pendente, vermelho ou
# ausente PRECISAM reprovar com ela; o script roda as duas passadas e reprova se
# a antiga passar onde nao devia.
#
#   bash .github/scripts/testar-fila-elegibilidade.sh          # as duas passadas
#   REGRA=antiga bash .github/scripts/testar-fila-elegibilidade.sh --uma
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
WF="${WF_SOB_TESTE:-$RAIZ/.github/workflows/leiloai-coordenador-fila.yml}"
FILTRO="${FILTRO_SOB_TESTE:-$AQUI/leiloai-fila-elegiveis.jq}"
REGRA="${REGRA:-nova}"

if [ "${1:-}" != "--uma" ]; then
  echo "=== passada 1: regra NOVA, tudo precisa passar ==="
  REGRA=nova bash "$0" --uma; nova=$?
  echo
  echo "=== passada 2: CONTROLE NEGATIVO, regra ANTIGA (so a fila decide) ==="
  T="$(mktemp -d)"
  # A regra que vigorou ate 20/09/2026, na forma de saida da nova, para os
  # testes lerem os dois do mesmo jeito.
  cat > "$T/antiga.jq" <<'JQ'
{ elegiveis: ([ .[] | select(.fila != null and .fila.state == "success") ]
              | sort_by(.fila.created_at)),
  barrados: [] }
JQ
  # O workflow de volta a regra antiga: decide sem o filtro que exige CI e nao
  # colhe o status de CI. Mutacao, e nao o arquivo de ontem, para o controle
  # continuar valendo depois do merge.
  sed -e 's#jq -s -f .github/scripts/leiloai-fila-elegiveis.jq#jq -s -f .github/scripts/regra-que-so-olha-a-fila.jq#' \
      -e 's#select(.context=="ci/actions-engine")#select(.context=="nao-colhido")#' \
      "$WF" > "$T/wf.yml"
  REGRA=antiga FILTRO_SOB_TESTE="$T/antiga.jq" WF_SOB_TESTE="$T/wf.yml" \
    bash "$0" --uma > "$T/saida" 2>&1; antiga=$?
  grep -E "^(PASSOU|REPROVOU)" "$T/saida"
  PASSARAM=$(grep -c "^PASSOU" "$T/saida")
  rm -rf "$T"
  echo
  if [ "$nova" -ne 0 ]; then
    echo "RESULTADO: REPROVOU, a regra nova falhou em $nova teste(s)"; exit 1
  fi
  # Na antiga passam EXATAMENTE quatro, e cada um porque as duas regras
  # concordam por construcao ali: CI verde elegivel, sem fila barrado, ordem
  # por finish, e leitura que falhou (sem fila) barrada. Numero exato, e nao
  # teto: se um quinto passar, um teste parou de enxergar o defeito.
  if [ "$antiga" -eq 0 ] || [ "$PASSARAM" -ne 4 ]; then
    echo "RESULTADO: REPROVOU, $PASSARAM teste(s) passaram no controle negativo (esperado: exatamente 4)"; exit 1
  fi
  echo "RESULTADO: PASSOU (nova passa em tudo; antiga reprova em $antiga teste(s))"
  exit 0
fi

FALHAS=0
passou()   { echo "PASSOU    $1"; }
reprovou() { echo "REPROVOU  $1"; FALHAS=$((FALHAS + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FILA_OK='{"state":"success","created_at":"2026-09-21T09:00:00Z"}'

# registro NUMERO SHA FILA CI -> uma linha de vereditos.jsonl
registro() { printf '{"numero":%s,"sha":"%s","fila":%s,"ci":%s}\n' "$1" "$2" "$3" "$4"; }

# elegivel? SHA < vereditos  -> "sim" ou "nao"
elegivel() {
  jq -s -c -f "$FILTRO" | jq -r --arg s "$1" '[.elegiveis[].sha] | if index($s) != null then "sim" else "nao" end'
}

# esperar ROTULO ESPERADO(sim|nao) SHA < vereditos
esperar() {
  local rotulo="$1" esperado="$2" sha="$3" veio
  veio=$(elegivel "$sha")
  if [ "$veio" = "$esperado" ]; then passou "$rotulo -> elegivel=$veio"
  else reprovou "$rotulo: esperado elegivel=$esperado, veio $veio"; fi
}

# --------------------------------------------------------------------------
# Os quatro casos do gate, e os vizinhos
# --------------------------------------------------------------------------
esperar "CI_GREEN: fila e CI verdes no mesmo SHA permitem seguir" sim aaa \n  < <(registro 1 aaa "$FILA_OK" '{"state":"success","created_at":"2026-09-21T09:10:00Z"}')

esperar "CI_RUNNING: CI pendente NAO mergeia" nao bbb \n  < <(registro 2 bbb "$FILA_OK" '{"state":"pending","created_at":"2026-09-21T09:10:00Z"}')

esperar "CI_FAILED: CI vermelho (failure) NAO mergeia" nao ccc \n  < <(registro 3 ccc "$FILA_OK" '{"state":"failure","created_at":"2026-09-21T09:10:00Z"}')

esperar "CI_FAILED: CI em erro NAO mergeia" nao ddd \n  < <(registro 4 ddd "$FILA_OK" '{"state":"error","created_at":"2026-09-21T09:10:00Z"}')

esperar "CI_NOT_TRIGGERED: status AUSENTE nao e verde" nao eee \n  < <(registro 5 eee "$FILA_OK" 'null')

esperar "estado de CI que o GitHub passe a devolver com outro nome barra" nao fff \n  < <(registro 6 fff "$FILA_OK" '{"state":"cancelled","created_at":"2026-09-21T09:10:00Z"}')

esperar "sem veredito de fila, CI verde sozinho nao basta" nao ggg \n  < <(registro 7 ggg 'null' '{"state":"success","created_at":"2026-09-21T09:10:00Z"}')

# --------------------------------------------------------------------------
# Ordem: entre as elegiveis, quem passou primeiro pelo finish vai primeiro
# --------------------------------------------------------------------------
{ registro 10 novo '{"state":"success","created_at":"2026-09-21T10:00:00Z"}' '{"state":"success","created_at":"x"}'
  registro 11 velho '{"state":"success","created_at":"2026-09-21T08:00:00Z"}' '{"state":"success","created_at":"x"}'
} > "$TMP/ordem.jsonl"
ordem=$(jq -s -c -f "$FILTRO" "$TMP/ordem.jsonl" | jq -r '[.elegiveis[].sha] | join(",")')
if [ "$ordem" = "velho,novo" ]; then passou "ordem por finish entre as elegiveis ($ordem)"
else reprovou "ordem errada entre as elegiveis: veio '$ordem'"; fi

# --------------------------------------------------------------------------
# Leitura que falhou: o registro que o workflow monta a partir de `null`
# --------------------------------------------------------------------------
# A expressao sai do PROPRIO workflow, e nao de uma copia aqui: conferencia que
# reescreve a expressao da escrita confere a si mesma.
MONTA=$(grep -oE "'\{numero: \\\$n, sha: \\\$s, fila: \(\.fila // null\), ci: \(\.ci // null\)\}'" "$WF" | head -1 | sed "s/^'//; s/'$//")
if [ -z "$MONTA" ]; then
  # Na passada antiga a montagem existe igual; se sumir, o teste de estrutura
  # abaixo acusa. Aqui cai para a forma conhecida so para nao mascarar o resto.
  MONTA='{numero: $n, sha: $s, fila: (.fila // null), ci: (.ci // null)}'
fi
jq -c --argjson n 12 --arg s hhh "$MONTA" <<< 'null' > "$TMP/falha.jsonl"
esperar "leitura de status que falhou vira null nos dois e barra" nao hhh < "$TMP/falha.jsonl"

# --------------------------------------------------------------------------
# Replay de um caso real: PR #925, ponta e6cb0ac3, mergeado 09:53:43Z de
# 21/09/2026. Naquele instante `ci/actions-engine` NAO existia no SHA (so o
# contexto irmao `/pendente`); o veredito saiu `failure` as 10:11:06Z.
# --------------------------------------------------------------------------
esperar "replay #925 no instante do merge: CI ainda sem veredito, nao mergeia" nao e6cb0ac3 \n  < <(registro 925 e6cb0ac3 '{"state":"success","created_at":"2026-09-21T09:52:40Z"}' 'null')

# --------------------------------------------------------------------------
# O workflow usa a regra, e colhe o que ela precisa. Leitura sem comentarios.
# --------------------------------------------------------------------------
CODIGO="$(tr -d $'\r' < "$WF" | sed -E 's/^[[:space:]]*#.*$//')"

if printf '%s' "$CODIGO" | grep -q 'jq -s -f .github/scripts/leiloai-fila-elegiveis.jq fila/vereditos.jsonl' \
   && printf '%s' "$CODIGO" | grep -q "jq '.elegiveis' fila/decisao.json > fila/elegiveis.json" \
   && ! printf '%s' "$CODIGO" | grep -q 'select(.fila != null and .fila.state == "success")'; then
  passou "workflow: a decisao sai do filtro unico, e a regra antiga embutida nao existe mais"
else
  reprovou "workflow: a decisao nao passa pelo filtro, ou a regra antiga voltou embutida"
fi

if printf '%s' "$CODIGO" | grep -q 'select(.context=="ci/actions-engine")' \
   && printf '%s' "$CODIGO" | grep -q '\.github/scripts/leiloai-fila-elegiveis\.jq$'; then
  passou "workflow: colhe ci/actions-engine por SHA e o checkout traz o filtro"
else
  reprovou "workflow: nao colhe o CI da entrega, ou o checkout esparso nao traz o filtro"
fi

echo
echo "falhas: $FALHAS (regra=$REGRA)"
exit "$FALHAS"
