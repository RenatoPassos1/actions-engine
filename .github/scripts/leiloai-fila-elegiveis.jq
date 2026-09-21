# LeiloAI: QUEM DA FILA PODE SER MERGEADO NESTA RODADA.
#
# Chamado pelo `leiloai-coordenador-fila.yml` com `jq -s -f`. Filtro PURO:
# recebe os vereditos ja colhidos, um registro por ponta,
#
#   {"numero": 924|null, "sha": "<40 hex>",
#    "fila": {"state", "created_at"} | null,   # status coordenacao/fila
#    "ci":   {"state", "created_at"} | null}   # status ci/actions-engine
#
# e devolve UMA decisao, com os dois lados da mesma regra:
#
#   {"elegiveis": [registro...],               # em ordem de finish
#    "barrados":  [{"numero", "sha", "motivo"}...]}
#
# O log de "BARRADO" sai daqui e nao de um segundo filtro no workflow: duas
# expressoes que decidem a mesma coisa divergem, e ja divergiram neste projeto.
#
# ============================================================================
# O DEFEITO QUE ISTO CONSERTA, MEDIDO EM 21/09/2026
# ============================================================================
#
# Os 11 merges de 09:35 a 10:29Z (#923 a #933) foram todos deste workflow, e
# em TODOS o SHA julgado estava com o CI RODANDO no instante do merge: o
# `ci/actions-engine/pendente` ja publicado, o veredito so depois. 7 dos 11
# vereditos sairam `failure`, e a integracao ficou vermelha por mais de uma
# hora, travando o deploy de todo mundo.
#
# A regra antiga era so `select(.fila.state == "success")`, e o contrato do
# workflow dizia, com todas as letras, "NAO consulta ci/actions-engine da
# ponta do PR". O coordenador local (`agentctl coordenar`, mesma fila) ja
# exigia CI verde: as duas metades da mesma ferramenta discordavam.
#
# ============================================================================
# FAIL-CLOSED: SO `success` NOS DOIS STATUS PASSA
# ============================================================================
#
# Status AUSENTE nao e verde: pode ser CI nunca pedido ou leitura que falhou,
# e nos dois casos ninguem provou nada sobre o SHA. `pending`, `failure`,
# `error` e qualquer estado que o GitHub passe a devolver com outro nome
# tambem barram. O CI e o do MESMO SHA que a fila julgou: o merge sai com
# `--match-head-commit` nesse SHA, entao o commit que entra e exatamente o
# que o CI aprovou.

def motivo:
  if (.fila == null) or (.fila.state != "success") then
    "sem veredito de fila neste SHA"
  elif .ci == null then
    "CI ausente neste SHA (nunca pedido ou leitura falhou): aguardando"
  elif .ci.state == "pending" then
    "CI em execucao neste SHA: aguardando"
  elif (.ci.state == "failure") or (.ci.state == "error") then
    "CI vermelho neste SHA (\(.ci.state)): novo finish depois do conserto"
  elif .ci.state == "success" then
    null
  else
    "CI em estado desconhecido neste SHA (\(.ci.state)): barrado"
  end;

{
  elegiveis: ([ .[] | select(motivo == null) ] | sort_by(.fila.created_at)),
  barrados:  [ .[] | motivo as $m | select($m != null)
               | {numero, sha, motivo: $m} ]
}
