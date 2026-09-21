#!/usr/bin/env bash
#
# LeiloAI: O QUE FAZER QUANDO A PONTA DE feat/landing NAO TEM APROVACAO.
#
# Chamado pelo `leiloai-coordenador-fila.yml`. Funcoes PURAS: recebem fatos ja
# colhidos e devolvem UMA decisao. Nao falam com rede, nao leem credencial e
# nao disparam nada. Quem busca o fato e quem age e o workflow; este arquivo so
# decide, para a decisao poder ser testada sem GitHub nenhum.
#
# ============================================================================
# O DEFEITO QUE ISTO CONSERTA, MEDIDO EM 16/09/2026
# ============================================================================
#
# O passo "Acordar o CI publico para a ponta recem-mergeada" tem a condicao
# `steps.mergear.outputs.sha_mergeado != ''`, e ela esta CERTA: e o caminho
# rapido logo apos um merge feito pelo proprio coordenador. O que faltava era
# cobertura para o resto, porque a ponta de `feat/landing` tambem anda por
# merge de outra sessao, e nesses ciclos ninguem pede o CI.
#
# Medido no dia inteiro de 16/09/2026:
#
#   pontas novas em feat/landing (first-parent) ...... 41
#   com refs/ci-aprovado/<sha> no actions-engine ..... 33
#   disparos de ci-publico por github-actions[bot] ... 23   (o passo 4)
#   disparos de ci-publico por RenatoPassos1 ......... 74   (a mao)
#   disparos de ci-publico por schedule ..............  3   (o cron */5)
#   rodadas do coordenador por schedule ..............  2   (o cron 23 * * *)
#
# Ou seja: quem sustentava o pipeline eram os 74 disparos manuais. O cron do
# `ci-publico` ja implementa por dentro a reconciliacao da ponta (le
# `branches/feat/landing`, sai calado se o SHA ja tem veredito), mas o GitHub
# entregou 3 dos 288 agendamentos declarados. O mecanismo estava certo e a
# ENTREGA dele nao acontece. Este arquivo poe a mesma reconciliacao no
# coordenador, que e dispatchado ~100 vezes por dia pelo `agentctl finish` e
# portanto tem a cadencia que o cron nao tem.
#
# ============================================================================
# CINCO ESTADOS, E NENHUM DELES E "NAO SEI, DISPARA"
# ============================================================================
#
# A ausencia de aprovacao colapsa estados que pedem acoes DIFERENTES. Tratar
# todos como "dispara o CI" e exatamente o laco que satura o `ghrunner`, e ele
# ja custou caro duas vezes neste projeto. Entao:
#
#   APROVADO ............ ha refs/ci-aprovado/<ponta>            -> nada
#   JA_DISPARADO ........ o passo 4 acabou de pedir ESTA ponta   -> nada
#   CI VERDE SEM REF .... veredito success, falta so a aprovacao -> ci-aprovado
#   CI REPROVADO ........ veredito failure/error                 -> NADA, avisa
#   EM VOO .............. ha pendente e o run esta vivo          -> nada
#   PEDIU E MORREU ...... ha pendente e o run acabou sem veredito-> ci-publico
#   NUNCA PEDIDO ........ nem veredito nem pendente              -> ci-publico
#
# UM DISPARO POR PONTA, NUNCA POR COMMIT. O ref de aprovacao e a deduplicacao
# duravel: assim que ele nasce, toda rodada seguinte cai em APROVADO e nao
# dispara mais nada. Entre o pedido e o ref, quem deduplica e o `pendente`.
#
# CI REPROVADO NAO REEXECUTA SOZINHO. Um commit vermelho remedido em laco e
# laco infinito com build de 14 minutos cada volta. Quem decide reexecutar e
# quem olhou o vermelho, com `-f forcar=true`. Commit novo resolve sozinho,
# porque a ponta muda e a pergunta passa a ser sobre outro SHA.
#
# ============================================================================
# ENTRADA INVALIDA RECUSA, E NAO CHUTA
# ============================================================================
#
# Todo argumento e allowlist estrita. Valor fora da lista devolve
# `entrada_invalida` e codigo 2, e o workflow trata isso como "nao disparar e
# reclamar alto". Um estado de run que o GitHub passe a devolver com outro nome
# vira ruido visivel, e nao um disparo as cegas a cada dez minutos.
#
# Uso:
#   . .github/scripts/leiloai-reconciliar-ponta.sh
#   decidir_reconciliacao <ja_disparou> <ref_aprovado> <veredito> <pendente>
#   extrair_run_id <target_url> <owner/repo>

# ---------------------------------------------------------------------------
# decidir_reconciliacao JA_DISPAROU REF_APROVADO VEREDITO PENDENTE
#
#   JA_DISPAROU ... sim | nao        (o passo 4 disparou o CI para ESTA ponta)
#   REF_APROVADO .. sim | nao        (existe refs/ci-aprovado/<ponta>)
#   VEREDITO ...... ausente | pending | success | failure | error
#                                    (status `ci/actions-engine` mais recente)
#   PENDENTE ...... ausente | queued | in_progress | waiting | requested
#                   | pending | completed | url_invalida
#                                    (estado do run apontado pelo
#                                     `ci/actions-engine/pendente`)
#
# Imprime UMA palavra e devolve 0; entrada invalida imprime
# `entrada_invalida` e devolve 2.
# ---------------------------------------------------------------------------
decidir_reconciliacao() {
  local ja="${1:-}" ref="${2:-}" veredito="${3:-}" pendente="${4:-}"

  case "$ja" in sim|nao) ;; *) echo entrada_invalida; return 2 ;; esac
  case "$ref" in sim|nao) ;; *) echo entrada_invalida; return 2 ;; esac
  case "$veredito" in
    ausente|pending|success|failure|error) ;;
    *) echo entrada_invalida; return 2 ;;
  esac
  case "$pendente" in
    ausente|queued|in_progress|waiting|requested|pending|completed|url_invalida) ;;
    *) echo entrada_invalida; return 2 ;;
  esac

  # 1. O fato mais forte primeiro: aprovado e o fim da linha, aconteca o que
  #    tiver acontecido antes.
  if [ "$ref" = sim ]; then echo aprovado; return 0; fi

  # 2. O passo 4 acaba de pedir o CI para esta mesma ponta. O `pendente` dele
  #    ainda nao existe (o run leva segundos para comecar), entao perguntar ao
  #    GitHub aqui daria "nunca pedido" e pediria DE NOVO. Quem sabe que o
  #    pedido existe e este workflow, e nao a API.
  if [ "$ja" = sim ]; then echo ja_disparado; return 0; fi

  # 3. Veredito final manda, e `pending` no contexto do veredito nao e final
  #    (o pendente mora no contexto irmao; se aparecer aqui, ainda nao ha
  #    resposta).
  case "$veredito" in
    success) echo aprovar; return 0 ;;
    failure|error) echo veredito_terminal_nao_success; return 0 ;;
  esac

  # 4. Sem veredito: o pendente diz se alguem ja pediu, e se aquele pedido
  #    ainda esta de pe.
  case "$pendente" in
    queued|in_progress|waiting|requested|pending) echo em_voo; return 0 ;;
    completed) echo morreu_sem_veredito; return 0 ;;
    ausente) echo nunca_pedido; return 0 ;;
    url_invalida) echo entrada_invalida; return 2 ;;
  esac
}

# ---------------------------------------------------------------------------
# extrair_run_id TARGET_URL OWNER/REPO
#
# O `target_url` do status pendente vem de fora deste workflow, entao ele e
# DADO e nao endereco de confianca: so vira id de run se casar, inteiro, com
# o formato que o proprio `ci-publico` publica, e no repositorio esperado.
# Qualquer outra coisa devolve vazio e codigo 1, e quem chama trata como
# `url_invalida` (nao dispara).
# ---------------------------------------------------------------------------
extrair_run_id() {
  local url="${1:-}" repo="${2:-}" esperado
  esperado="https://github.com/${repo}/actions/runs/"
  case "$url" in
    "${esperado}"*) ;;
    *) return 1 ;;
  esac
  local id="${url#"$esperado"}"
  printf '%s' "$id" | grep -qE '^[0-9]{1,20}$' || return 1
  printf '%s' "$id"
}
