#!/usr/bin/env bash
# Veredito do canal `ops/divida-operacional`.
#
# POR QUE ISTO E UM SCRIPT, E NAO TRES LINHAS DENTRO DO YAML
#
# Logica de decisao escondida num `run:` nao tem como ser exercitada: ninguem
# consegue provar que ela reprova quando deve, nem matar um mutante que a
# afrouxe. Aqui ela entra, sai, e tem
# `.github/scripts/testar-veredito-divida.sh` a cobrir as duas direccoes.
#
# CONTRATO
#   entrada: $1 = quantas dividas operacionais   $2 = a medicao aconteceu?
#   saida:   uma linha `estado=<success|failure>` e `motivo=<texto>`
#   codigo:  0 SEMPRE. Quem reprova e o STATUS publicado, nunca o job.
#
# O codigo de saida e 0 ate quando o veredito e `failure`, e isso e desenho
# medido, nao descuido: o avaliador da aprovacao (`scripts/avaliar-checks.mjs`
# do repo privado) reprova se QUALQUER job nao obrigatorio estiver vermelho,
# mas entre os commit statuses so exige `ci/actions-engine`. Logo um job
# vermelho bloquearia o deploy, e o deploy e quem aplica a migration que PAGA
# a divida. O veredito mora no status para ser visivel sem fechar esse ciclo.
set -euo pipefail

n="${1:-}"
lida="${2:-false}"

# AUSENTE NAO E ZERO. Sem medicao, o veredito e vermelho e diz porque. Ler
# ausencia como zero seria aprovar por vacuidade justamente no caso em que
# nada foi conferido.
if [ "$lida" != "true" ]; then
  echo "estado=failure"
  echo "motivo=divida nao medida nesta corrida (ausente nao e zero)"
  exit 0
fi

# Numero que nao e numero tambem nao e zero.
if ! printf '%s' "$n" | grep -qE '^-?[0-9]+$'; then
  echo "estado=failure"
  echo "motivo=contagem ilegivel: '$n'"
  exit 0
fi

if [ "$n" -lt 0 ]; then
  echo "estado=failure"
  echo "motivo=contagem negativa ($n), que so acontece se a medicao falhou"
  exit 0
fi

if [ "$n" -gt 0 ]; then
  echo "estado=failure"
  echo "motivo=$n achado(s) operacional(is) na linha-de-base"
  exit 0
fi

echo "estado=success"
echo "motivo=sem divida operacional na linha-de-base"
