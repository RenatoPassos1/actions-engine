#!/usr/bin/env bash
# A guarda que impede o job `status` de publicar veredito sem medicao continua no lugar?
#
# ============================================================================
# O INVARIANTE
# ============================================================================
#
# COMPUTE_SKIPPED_CAN_APPROVE_SHA = 0. Um run do `leiloai-ci-publico.yml` que
# PULA o job `compute` nao pode terminar publicando `ci/actions-engine` no SHA.
#
# Hoje isso vale, mas por uma coincidencia feliz entre DUAS condicoes `if`
# escritas em lugares diferentes do YAML:
#
#   compute:  if: needs.resolver.outputs.precisa == 'true'
#   status:   if: always() && needs.resolver.outputs.precisa == 'true'
#
# O `resolver` devolve `precisa=false` quando o SHA JA tem veredito. Nesse caso
# `compute` e pulado, e, como o `status` exige a MESMA guarda, ele tambem e
# pulado: nenhum veredito novo e escrito. Correto.
#
# ============================================================================
# O RISCO QUE ESTA TRAVA COBRE
# ============================================================================
#
# Alguem relaxa o `if` do `status` para so `always()` ("quero sempre reportar",
# parece inofensivo) e remove a metade `needs.resolver.outputs.precisa`. A
# partir dai um run com `compute` pulado passa a rodar o `status`. E `always()`
# com `needs: compute` pulado avalia `needs.compute.result` como `skipped`, que
# o proprio `status` traduz em `ESTADO=failure` e PUBLICA. Ou seja: um SHA que
# ja estava `success` vira `failure`, o `puxar-deploy.sh` recusa a ponta, e a
# conta chega ~35 min depois pelo cron, sem erro em lugar nenhum.
#
# ============================================================================
# POR QUE O TESTE LE O PROPRIO YAML, E DERIVA A GUARDA DO `compute`
# ============================================================================
#
# Reescrever a guarda aqui criaria duas copias da mesma regra, e a copia velha
# aprovaria o que a nova recusa sem ninguem notar (mesmo defeito que o
# `testar-entrada-ci-publico.sh`, irmao deste arquivo, ja evita para o regex de
# SHA). Entao a guarda exigida do `status` e EXTRAIDA do `if` do `compute`: se
# um dia o output for renomeado nos dois lugares, o teste segue junto; se so o
# `status` for afrouxado, ele reprova aqui, dizendo o que sumiu.
#
# CONTROLE POSITIVO OBRIGATORIO: uma trava sobre texto de YAML pode nascer
# decorativa (nunca ficar vermelha). Por isso, alem de conferir o arquivo real,
# este script constroi um mutante em que o `if` do `status` vira so `always()`
# e EXIGE que a mesma conferencia reprove esse mutante. Sem o mutante reprovado,
# o script falha, porque uma trava que nunca fica vermelha nao protege nada.
#
# exit 0 = a guarda esta no lugar e a trava sabe ficar vermelha.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$AQUI/../workflows/leiloai-ci-publico.yml"
[ -f "$WF" ] || { echo "workflow nao encontrado: $WF"; exit 2; }

passou=0; falhou=0
ok()  { echo "  [ok]    $1"; passou=$((passou + 1)); }
nok() { echo "  [FALHA] $1"; falhou=$((falhou + 1)); }

# Extrai o `if:` de NIVEL DE JOB (indentacao de 4 espacos) de um job nomeado.
# So o `if` do job casa: o de step fica a 6 ou 8 espacos, e o `resolver` tem um
# `if` de step (`if: steps.alvo.outputs.precisa == 'true'`) que nao pode ser
# confundido com guarda de job.
if_do_job() {
  local job="$1" wf="$2"
  awk -v job="$job" '
    /^  [A-Za-z][A-Za-z0-9_-]*:/ { dentro = ($0 ~ "^  " job ":") }
    dentro && /^    if:/ {
      sub(/^    if:[[:space:]]*/, "")
      print
      exit
    }
  ' "$wf"
}

# Colapsa espacos em um so e apara as bordas.
norm() { printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -E 's/^ +| +$//g'; }

# Extrai a guarda `needs.resolver.outputs.<nome> == <literal>` de uma expressao.
# Aceita aspas simples ou duplas no literal, e espaco variavel em volta do `==`.
extrair_guarda() {
  printf '%s' "$1" \
    | grep -oE "needs\.resolver\.outputs\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*==[[:space:]]*('[^']*'|\"[^\"]*\")" \
    | head -1
}

# Devolve: 0 se o `if` do status CONTEM a guarda que o compute usa; 1 se NAO
# contem; 2 se a premissa quebrou (nao da para medir).
guarda_de_status_presente() {
  local wf="$1" cif sif guarda
  cif="$(if_do_job compute "$wf")"
  sif="$(if_do_job status  "$wf")"
  [ -n "$cif" ] || { echo "    (nao achei o if do job compute)"; return 2; }
  [ -n "$sif" ] || { echo "    (nao achei o if do job status)";  return 2; }
  guarda="$(norm "$(extrair_guarda "$cif")")"
  [ -n "$guarda" ] || { echo "    (compute nao expoe guarda needs.resolver.outputs.*; premissa quebrada)"; return 2; }
  if printf '%s' "$(norm "$sif")" | grep -qF "$guarda"; then
    return 0
  fi
  return 1
}

echo "=== o que o YAML declara hoje ==="
COMPUTE_IF="$(if_do_job compute "$WF")"
STATUS_IF="$(if_do_job status  "$WF")"
GUARDA="$(norm "$(extrair_guarda "$COMPUTE_IF")")"

[ -n "$COMPUTE_IF" ] && ok "if do job compute: $(norm "$COMPUTE_IF")" \
                     || nok "nao achei o if do job compute no workflow"
[ -n "$STATUS_IF" ]  && ok "if do job status:  $(norm "$STATUS_IF")" \
                     || nok "nao achei o if do job status no workflow"
[ -n "$GUARDA" ]     && ok "guarda derivada do compute: $GUARDA" \
                     || nok "compute nao expoe needs.resolver.outputs.*; premissa do teste quebrou"

echo "=== a asercao central: status carrega a mesma guarda ==="
guarda_de_status_presente "$WF"; rc=$?
case "$rc" in
  0) ok "o if do job status inclui a guarda do compute ($GUARDA)" ;;
  1) nok "o if do job status NAO inclui '$GUARDA': um run com compute pulado publicaria veredito" ;;
  *) nok "nao consegui medir a guarda do status (premissa quebrada)" ;;
esac

echo "=== controle positivo: a trava sabe ficar vermelha? ==="
MUT="$(mktemp)"
trap 'rm -f "$MUT"' EXIT
# Mutante: troca SO o if de nivel de job do `status` por `always()`.
awk '
  /^  [A-Za-z][A-Za-z0-9_-]*:/ { dentro = ($0 ~ /^  status:/) }
  dentro && /^    if:/ && !feito { print "    if: always()"; feito=1; next }
  { print }
' "$WF" > "$MUT"

if [ "$(norm "$(if_do_job status "$MUT")")" = "always()" ]; then
  ok "mutante construido: if do status virou 'always()'"
else
  nok "nao consegui mutar o if do status; sem mutante nao ha controle positivo"
fi

guarda_de_status_presente "$MUT"; rc=$?
case "$rc" in
  1) ok "a trava reprova o mutante (guarda ausente do status), como deve" ;;
  0) nok "a trava PASSOU no mutante: ela e decorativa, nao detecta o afrouxamento" ;;
  *) nok "a conferencia quebrou no mutante; controle positivo invalido" ;;
esac

echo
echo "  passou: $passou    falhou: $falhou"
[ "$falhou" -eq 0 ]
