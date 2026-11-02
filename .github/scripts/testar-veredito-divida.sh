#!/usr/bin/env bash
# Provas do veredito da divida operacional, nas DUAS direccoes.
#
# Nao basta provar que fica verde hoje: um portao que nunca reprova e
# indistinguivel de portao desligado. Cada caso abaixo tem o seu par.
set -uo pipefail
AQUI="$(cd "$(dirname "$0")" && pwd)"
ALVO="${ALVO:-$AQUI/leiloai-veredito-divida.sh}"
passou=0; falhou=0

caso() {  # nome, n, lida, estado_esperado
  local nome="$1" n="$2" lida="$3" esperado="$4"
  local saida estado codigo
  saida="$(bash "$ALVO" "$n" "$lida")"; codigo=$?
  estado="$(printf '%s' "$saida" | grep -oE '^estado=.*' | cut -d= -f2)"
  if [ "$estado" = "$esperado" ] && [ "$codigo" -eq 0 ]; then
    echo "  ok   $nome"; passou=$((passou+1))
  else
    echo "  FAIL $nome: esperava estado=$esperado e codigo=0, veio estado=$estado codigo=$codigo"
    falhou=$((falhou+1))
  fi
}

echo "=== veredito da divida operacional ==="

# O PAR QUE IMPORTA: com divida reprova, sem divida passa. Um sem o outro nao
# prova nada.
caso "divida 3 REPROVA a linha-de-base"      3   true  failure
caso "divida 1 REPROVA a linha-de-base"      1   true  failure
caso "divida 0 PASSA"                        0   true  success

# AUSENTE NAO E ZERO.
caso "nao medida REPROVA"                    0   false failure
caso "nao medida REPROVA mesmo com n alto"   9   false failure
caso "sentinela -1 REPROVA"                 -1   true  failure

# Entrada corrompida nao vira aprovacao.
caso "contagem vazia REPROVA"               ""   true  failure
caso "contagem nao numerica REPROVA"      "zero" true  failure

# O JOB NUNCA FICA VERMELHO, e isso e exigencia medida, nao descuido: o
# avaliador da aprovacao reprova com qualquer job nao obrigatorio vermelho, e
# ai a divida bloquearia o deploy que a paga. Todos os casos acima ja exigem
# codigo 0, inclusive os `failure`.

echo
echo "passou: $passou   falhou: $falhou"
[ "$falhou" -eq 0 ]
