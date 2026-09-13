#!/usr/bin/env bash
#
# LeiloAI: QUAIS ENTREGAS O COORDENADOR DA FILA OLHA EM CADA RODADA.
#
# Chamado pelo `leiloai-coordenador-fila.yml`. Funcoes PURAS: leem arquivo e
# git LOCAL, nao falam com rede nenhuma e nao leem credencial. Quem busca dado
# do repositorio privado e o workflow; este arquivo so decide.
#
# ============================================================================
# O DEFEITO QUE ISTO CONSERTA, MEDIDO EM 13/09/2026
# ============================================================================
#
# O modo branch montava a lista assim:
#
#   pontas de branch  INTERSECAO  refs/fila-coordenacao/*    (em ordem de SHA)
#   -> as 80 PRIMEIRAS, cada uma com uma chamada `compare/BASE...sha`
#   -> o resto: "teto atingido, pontas restantes NAO foram avaliadas"
#
# Medido no repositorio real: 412 branches, 2.023 refs de fila, 202 pontas na
# intersecao. Dessas 202, 197 ja estavam DENTRO de `feat/landing` (branch nao se
# apaga no merge e continua carregando o ref do `finish`). As 5 que ainda nao
# estavam ocupavam as posicoes 34, 101, 129, 140 e 149 da ordem por SHA. Com o
# teto de 80, quatro das cinco entregas vivas nunca eram comparadas, em rodada
# nenhuma, porque a ordem por SHA e FIXA: os mesmos 80 SHAs historicos gastavam
# o teto inteiro toda vez. Tres delas tinham PR aberto.
#
# Nao era atraso: era invisibilidade permanente para quem tivesse o SHA
# "grande", decidida pelo hexadecimal do commit.
#
# ============================================================================
# O CONSERTO, EM DUAS CAMADAS
# ============================================================================
#
# 1. ENTREGA JA INTEGRADA NAO GASTA ORCAMENTO. "Esta dentro da base" e fato
#    MONOTONO (feat/landing so anda para frente), e se responde com git local
#    em milissegundos, sem chamada de API: `fora_da_base` abaixo. As 197
#    historicas saem de graca e a lista de trabalho vira as 5 vivas. Isto
#    escala com 1.000 ou 10.000 branches historicos sem mudar o custo de API.
#
# 2. SE AINDA ASSIM HOUVER MAIS CANDIDATAS QUE ORCAMENTO, A JANELA GIRA.
#    `janela` escolhe B de N por rodada, deslocando o inicio em B a cada
#    rodada (o numero da rodada vem do `github.run_number`, contador duravel do
#    proprio GitHub, entao nao ha estado para guardar). Com a lista estavel,
#    TODA candidata e examinada em no maximo ceil(N/B) rodadas consecutivas, e
#    as primeiras B nao-prontas nao podem mais esconder a B+1-esima para
#    sempre. E tambem a rede do caminho de reserva, quando o fetch do git
#    falha e a comparacao volta a ser por API.
#
# O que NAO muda: a identidade da entrega continua sendo o SHA que passou pelo
# `finish`. Ponta que andou depois do `finish` nao tem ref de fila e nao entra.

set -euo pipefail

# pontas_com_veredito PONTAS FILA
#   PONTAS: um SHA de ponta de branch por linha (base, main e staging ja fora).
#   FILA:   um SHA por linha, os que passaram pelo `finish`.
#   Saida:  a intersecao, ordenada. Branch sem ref de fila nao e entrega.
pontas_com_veredito() {
  comm -12 <(sort -u "$1") <(sort -u "$2")
}

# fora_da_base GITDIR BASE_SHA < SHAS  > FORA   (e DESCONHECIDOS em fd 3)
#   Para cada SHA da entrada: se e ancestral de BASE_SHA, esta entregue e sai.
#   Se o objeto nao existe no git local (a ponta andou entre listar e buscar),
#   vai para o fd 3 como desconhecido: NAO vira "fora da base" por omissao,
#   porque na duvida a entrega fica de fora desta rodada e a proxima reavalia.
#
#   Custo: DUAS chamadas de git no total, e nao duas por SHA. `rev-list` da base
#   uma vez vira o conjunto dos entregues, e `cat-file --batch-check` confere a
#   existencia de todos de uma vez. Medido com 202 pontas: um laco de
#   `merge-base --is-ancestor` por SHA levava 23 s num runner de Windows.
fora_da_base() {
  local gitdir="$1" base="$2" tmp
  tmp="$(mktemp -d)"
  grep -E '^[0-9a-f]{40}$' | sort -u > "$tmp/entrada" || true
  # `GIT_NO_LAZY_FETCH=1` NAO E ENFEITE. O fetch do workflow e parcial
  # (`--filter=tree:0`), e num clone parcial o git BUSCA NA REDE, sozinho, o
  # objeto que nao tem. Medido: um SHA inexistente passado ao `cat-file` virou
  # `upload-pack: not our ref` vindo do GitHub, ou seja, uma requisicao ao
  # repositorio privado de dentro de uma funcao que se diz sem rede.
  GIT_NO_LAZY_FETCH=1 git -C "$gitdir" rev-list "$base" | sort -u > "$tmp/entregues"
  sed 's/$/^{commit}/' "$tmp/entrada" \
    | GIT_NO_LAZY_FETCH=1 git -C "$gitdir" cat-file --batch-check='%(objectname) %(objecttype)' > "$tmp/existencia"
  awk '$2 == "commit" { print $1 }' "$tmp/existencia" | sort -u > "$tmp/existentes"
  comm -23 "$tmp/entrada" "$tmp/existentes" >&3
  comm -23 "$tmp/existentes" "$tmp/entregues"
  rm -rf "$tmp"
}

# janela ORCAMENTO RODADA < LISTA  > ESCOLHIDOS
#   Cada linha e um item inteiro (so o SHA, ou "numero sha" no modo PR).
#   LISTA precisa vir ORDENADA (a mesma ordem entre rodadas e o que da a
#   garantia). Com N <= ORCAMENTO devolve tudo. Com N > ORCAMENTO devolve
#   ORCAMENTO itens a partir de ((RODADA-1) * ORCAMENTO) mod N, dando a volta
#   no fim. As rodadas 1..ceil(N/ORCAMENTO) cobrem os blocos 0, B, 2B, ... que
#   juntos sao a lista inteira.
janela() {
  local orcamento="$1" rodada="$2"
  case "$orcamento" in ''|*[!0-9]*) echo "janela: orcamento invalido" >&2; return 2 ;; esac
  case "$rodada" in ''|*[!0-9]*) echo "janela: rodada invalida" >&2; return 2 ;; esac
  [ "$orcamento" -ge 1 ] || { echo "janela: orcamento precisa ser >= 1" >&2; return 2; }
  [ "$rodada" -ge 1 ] || rodada=1
  awk -v b="$orcamento" -v r="$rodada" '
    NF { item[n++] = $0 }
    END {
      if (n == 0) exit 0
      if (n <= b) { for (i = 0; i < n; i++) print item[i]; exit 0 }
      inicio = ((r - 1) * b) % n
      for (k = 0; k < b; k++) print item[(inicio + k) % n]
    }'
}

# rodadas_para_cobrir N ORCAMENTO -> ceil(N/ORCAMENTO), no minimo 1
rodadas_para_cobrir() {
  local n="$1" b="$2"
  if [ "$n" -le "$b" ]; then echo 1; else echo $(( (n + b - 1) / b )); fi
}

# Chamado como comando: `bash leiloai-fila-selecionar.sh <funcao> args...`.
# Sourced (pelos testes), so define as funcoes.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    pontas_com_veredito|fora_da_base|janela|rodadas_para_cobrir) "$cmd" "$@" ;;
    *) echo "uso: $0 {pontas_com_veredito|fora_da_base|janela|rodadas_para_cobrir} ..." >&2; exit 2 ;;
  esac
fi
