#!/usr/bin/env bash
#
# Testes do seletor da fila (`leiloai-fila-selecionar.sh`) e das regras do
# `leiloai-coordenador-fila.yml` que dependem dele.
#
# Roda sem rede e sem credencial: um repositorio git DE MENTIRA, com 200
# branches ja mergeados e 3 entregas vivas, reproduz a forma medida em
# 13/09/2026 no repositorio real (202 pontas com ref de fila, 197 ja na base).
#
# CONTROLE NEGATIVO EMBUTIDO. `SELETOR=antigo` troca o seletor pela regra de
# ate 13/09 ("as 80 primeiras em ordem de SHA"), e os testes de inanicao
# PRECISAM reprovar com ela. O proprio script roda as duas passadas e reprova
# se a antiga passar, porque teste que passa com o defeito nao testa nada.
#
#   bash .github/scripts/testar-fila-selecionar.sh           # as duas passadas
#   SELETOR=antigo bash .github/scripts/testar-fila-selecionar.sh --uma
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
WF="${WF_SOB_TESTE:-$RAIZ/.github/workflows/leiloai-coordenador-fila.yml}"
# shellcheck source=leiloai-fila-selecionar.sh
. "$AQUI/leiloai-fila-selecionar.sh"
set +e

SELETOR="${SELETOR:-novo}"
ORCAMENTO=80

if [ "${1:-}" != "--uma" ]; then
  echo "=== passada 1: seletor NOVO, tudo precisa passar ==="
  SELETOR=novo bash "$0" --uma; novo=$?
  echo
  echo "=== passada 2: CONTROLE NEGATIVO, seletor ANTIGO, a inanicao precisa reprovar ==="
  # O workflow sob teste, na passada antiga, e uma MUTACAO do atual com as
  # regras que os testes estaticos protegem desfeitas: laco das primeiras 80,
  # squash, sem conferir a ponta, elegibilidade lendo o CI da ponta do PR, e
  # contents: write. Mutacao, e nao o arquivo de ontem, para o controle
  # continuar valendo depois do merge.
  MUT="$(mktemp)"
  sed -e 's/bash "\$SEL" fora_da_base/bash "$SEL" primeiras_80/' \
      -e 's/--merge --match-head-commit "\$sha"/--squash/' \
      -e 's/"\$cabeca" != "\$sha"/"$cabeca" = "nunca"/' \
      -e 's/select(.fila != null and .fila.state == "success")/select(.fila != null and .fila.state == "success" and .ci == "ci\/actions-engine")/' \
      -e 's/^  contents: read/  contents: write/' \
      -e 's/^          TETO_COMPARACOES=80$/          TETO_COMPARACOES=80\n          echo "teto atingido; pontas restantes NAO foram avaliadas"/' \
      "$RAIZ/.github/workflows/leiloai-coordenador-fila.yml" > "$MUT"
  SELETOR=antigo WF_SOB_TESTE="$MUT" bash "$0" --uma > "$MUT.saida" 2>&1; antigo=$?
  grep -E "^(PASSOU|REPROVOU)" "$MUT.saida"
  PASSARAM_NO_ANTIGO=$(grep -c "^PASSOU" "$MUT.saida")
  rm -f "$MUT" "$MUT.saida"
  echo
  if [ "$novo" -ne 0 ]; then
    echo "RESULTADO: REPROVOU, o seletor novo falhou em $novo teste(s)"; exit 1
  fi
  # So o teste de intersecao pontas x fila pode passar no antigo: aquela regra
  # nao mudou. Qualquer outro PASSOU no antigo e teste que nao enxerga o defeito.
  if [ "$antigo" -eq 0 ] || [ "$PASSARAM_NO_ANTIGO" -ne 1 ]; then
    echo "RESULTADO: REPROVOU, $PASSARAM_NO_ANTIGO teste(s) passaram no controle negativo (esperado: so o da intersecao)"; exit 1
  fi
  echo "RESULTADO: PASSOU (novo passa em tudo; antigo reprova em $antigo teste(s))"
  exit 0
fi

FALHAS=0
passou()   { echo "PASSOU    $1"; }
reprovou() { echo "REPROVOU  $1"; FALHAS=$((FALHAS + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --------------------------------------------------------------------------
# SELECAO SOB TESTE: o que o workflow faz entre "pontas com ref de fila" e
# "candidatas desta rodada", nas duas versoes.
# --------------------------------------------------------------------------
# selecionar GITDIR BASE RODADA < COM_VEREDITO > CANDIDATAS
selecionar() {
  local gitdir="$1" base="$2" rodada="$3"
  if [ "$SELETOR" = antigo ]; then
    # Ate 13/09/2026: as ORCAMENTO primeiras em ordem de SHA, cada uma
    # comparada com a base; o resto nunca era olhado.
    local gastos=0 sha
    while read -r sha; do
      [ -n "$sha" ] || continue
      [ "$gastos" -ge "$ORCAMENTO" ] && break
      gastos=$((gastos + 1))
      git -C "$gitdir" merge-base --is-ancestor "$sha" "$base" 2>/dev/null || printf '%s\n' "$sha"
    done
    echo "$gastos" > "$TMP/comparacoes-caras.txt"
  else
    # Git local: nenhuma chamada de API por SHA.
    echo 0 > "$TMP/comparacoes-caras.txt"
    fora_da_base "$gitdir" "$base" 3>/dev/null | sort -u | janela "$ORCAMENTO" "$rodada"
  fi
}

# janela_sob_teste ORCAMENTO RODADA < LISTA
janela_sob_teste() {
  if [ "$SELETOR" = antigo ]; then head -n "$1"; else janela "$1" "$2"; fi
}

# --------------------------------------------------------------------------
# FIXTURE: base com 200 merges historicos + 3 entregas vivas
# --------------------------------------------------------------------------
G="$TMP/repo"
git init -q "$G"
git -C "$G" config user.email teste@exemplo.invalid
git -C "$G" config user.name teste
ARV=$(git -C "$G" hash-object -t tree -w --stdin < /dev/null 2>/dev/null || git -C "$G" mktree < /dev/null)
export GIT_AUTHOR_DATE="2026-09-13T00:00:00Z" GIT_COMMITTER_DATE="2026-09-13T00:00:00Z"
RAIZ_C=$(echo raiz | git -C "$G" commit-tree "$ARV")
base="$RAIZ_C"
: > "$TMP/historicas.txt"
for i in $(seq 1 200); do
  b=$(echo "historica $i" | git -C "$G" commit-tree "$ARV" -p "$RAIZ_C")
  base=$(echo "merge $i" | git -C "$G" commit-tree "$ARV" -p "$base" -p "$b")
  printf '%s\n' "$b" >> "$TMP/historicas.txt"
done
BASE="$base"

# Entregas vivas com SHA que ordena DEPOIS de quase todas as historicas,
# como as das posicoes 101 a 149 medidas no repositorio real. O prefixo e
# forcado variando a mensagem, para o teste nao depender da sorte do hash.
nova_viva() {
  local rotulo="$1" n=0 c
  while :; do
    c=$(echo "viva $rotulo $n" | git -C "$G" commit-tree "$ARV" -p "$BASE")
    case "$c" in f[89a-f]*) printf '%s\n' "$c"; return ;; esac
    n=$((n + 1))
  done
}
V1=$(nova_viva um); V2=$(nova_viva dois); V3=$(nova_viva tres)
printf '%s\n%s\n%s\n' "$V1" "$V2" "$V3" | sort > "$TMP/vivas.txt"

# Branch sem ref de fila (nunca passou pelo finish) e uma entrega cuja branch
# andou depois do finish: A tem ref, a ponta B nao.
SEM_REF=$(echo "sem finish" | git -C "$G" commit-tree "$ARV" -p "$BASE")
ANDOU_A=$(echo "finish A" | git -C "$G" commit-tree "$ARV" -p "$BASE")
ANDOU_B=$(echo "depois do finish" | git -C "$G" commit-tree "$ARV" -p "$ANDOU_A")

cat "$TMP/historicas.txt" "$TMP/vivas.txt" > "$TMP/pontas.txt"
printf '%s\n%s\n' "$SEM_REF" "$ANDOU_B" >> "$TMP/pontas.txt"
# Refs de fila: todas as historicas, as vivas, A (mas nao B), e 1.800 SHAs
# de finish antigos que nao sao ponta de nada, como os 2.023 refs reais.
{ cat "$TMP/historicas.txt" "$TMP/vivas.txt"; printf '%s\n' "$ANDOU_A"
  for i in $(seq 1 1800); do printf '%040x\n' "$i"; done; } > "$TMP/fila.txt"

pontas_com_veredito "$TMP/pontas.txt" "$TMP/fila.txt" > "$TMP/com.txt"
N_COM=$(grep -c . "$TMP/com.txt")
POS_MIN=$(grep -n -F -f "$TMP/vivas.txt" "$TMP/com.txt" | cut -d: -f1 | sort -n | head -1)

echo "fixture: pontas_com_ref=$N_COM historicas=200 vivas=3 primeira_viva_na_posicao=$POS_MIN orcamento=$ORCAMENTO seletor=$SELETOR"

# --------------------------------------------------------------------------
# 1. test_queue_ref_maps_to_exact_sha / test_branch_tip_advance_does_not_mutate_delivery
# --------------------------------------------------------------------------
if [ "$N_COM" -eq 203 ] && ! grep -qx "$SEM_REF" "$TMP/com.txt" \
   && ! grep -qx "$ANDOU_B" "$TMP/com.txt" && ! grep -qx "$ANDOU_A" "$TMP/com.txt"; then
  passou "ref de fila casa SHA exato: branch sem finish fica fora, e a ponta que andou depois do finish nao herda o veredito"
else
  reprovou "intersecao pontas x fila: esperado 203 e sem SEM_REF/ANDOU_A/ANDOU_B, veio $N_COM"
fi

# --------------------------------------------------------------------------
# 2. test_more_candidates_than_budget + test_candidate_beyond_first_window
# --------------------------------------------------------------------------
if [ "$POS_MIN" -le "$ORCAMENTO" ]; then
  reprovou "fixture invalida: a primeira viva esta na posicao $POS_MIN, dentro do orcamento, e o teste nao provaria nada"
fi
selecionar "$G" "$BASE" 1 < "$TMP/com.txt" | sort -u > "$TMP/rodada1.txt"
achadas=$(comm -12 "$TMP/rodada1.txt" "$TMP/vivas.txt" | grep -c .)
if [ "$achadas" -eq 3 ]; then
  passou "203 pontas com ref e orcamento 80: as 3 vivas (a partir da posicao $POS_MIN) sao candidatas ja na rodada 1"
else
  reprovou "entrega viva alem da posicao 80 invisivel: achou $achadas de 3 na rodada 1"
fi

# --------------------------------------------------------------------------
# 3. test_historical_branch_without_active_delivery_not_expensive_candidate
#    test_terminal_delivery_filtered_before_compare
# --------------------------------------------------------------------------
examinadas=$(grep -c . "$TMP/rodada1.txt")
caras=$(cat "$TMP/comparacoes-caras.txt")
if [ "$examinadas" -eq 3 ] && [ "$caras" -eq 0 ]; then
  passou "as 200 historicas ja na base nao gastam orcamento: 0 comparacoes por API, 3 candidatas"
else
  reprovou "historico consumiu orcamento: $caras comparacao(oes) por API e $examinadas candidata(s) para 3 vivas"
fi

# --------------------------------------------------------------------------
# 4. test_unready_first_window_does_not_starve_later_delivery (HEAD_OF_SCAN)
#    201 candidatas vivas, as 80 primeiras nunca ficam prontas, a 81a fica.
# --------------------------------------------------------------------------
for i in $(seq 1 201); do printf 'c%03d\n' "$i"; done > "$TMP/201.txt"
PRONTA=c081
achou_em=0
for r in 1 2 3 4 5 6; do
  if janela_sob_teste "$ORCAMENTO" "$r" < "$TMP/201.txt" | grep -qx "$PRONTA"; then achou_em=$r; break; fi
done
limite=$(rodadas_para_cobrir 201 "$ORCAMENTO")
if [ "$achou_em" -ge 1 ] && [ "$achou_em" -le "$limite" ]; then
  passou "80 primeiras nao prontas nao escondem a 81a: examinada na rodada $achou_em (limite ceil(201/80)=$limite)"
else
  reprovou "inanicao pela cabeca da lista: a 81a nao foi examinada em 6 rodadas"
fi

# --------------------------------------------------------------------------
# 5. test_every_candidate_examined_within_bounded_rounds
# --------------------------------------------------------------------------
: > "$TMP/cobertas.txt"
for r in $(seq 1 "$limite"); do janela_sob_teste "$ORCAMENTO" "$r" < "$TMP/201.txt" >> "$TMP/cobertas.txt"; done
cobertas=$(sort -u "$TMP/cobertas.txt" | grep -c .)
if [ "$cobertas" -eq 201 ]; then
  passou "as 201 candidatas sao todas examinadas em ceil(201/80)=$limite rodadas consecutivas"
else
  reprovou "cobertura: so $cobertas de 201 examinadas em $limite rodadas"
fi

# Garantia vale com orcamento que nao divide N e a partir de qualquer rodada.
ok=1
for b in 1 7 50 80 200 201 500; do
  for inicio in 1 13 1000; do
    lim=$(rodadas_para_cobrir 201 "$b"); : > "$TMP/c.txt"
    for r in $(seq "$inicio" $((inicio + lim - 1))); do janela_sob_teste "$b" "$r" < "$TMP/201.txt" >> "$TMP/c.txt"; done
    [ "$(sort -u "$TMP/c.txt" | grep -c .)" -eq 201 ] || { ok=0; echo "  orcamento=$b inicio=$inicio nao cobriu"; }
    [ "$(janela_sob_teste "$b" "$inicio" < "$TMP/201.txt" | grep -c .)" -eq $(( b < 201 ? b : 201 )) ] || { ok=0; echo "  orcamento=$b devolveu tamanho errado"; }
  done
done
if [ "$ok" -eq 1 ]; then
  passou "cobertura em ceil(N/B) rodadas para B em {1,7,50,80,200,201,500} e inicio em {1,13,1000}, sempre com B itens (ou N)"
else
  reprovou "a janela nao cobre N em ceil(N/B) rodadas para algum orcamento"
fi

# --------------------------------------------------------------------------
# 6. desconhecida nao vira candidata por omissao
# --------------------------------------------------------------------------
if [ "$SELETOR" = novo ]; then
  printf '%s\n%040x\n' "$V1" 999999 | fora_da_base "$G" "$BASE" 3> "$TMP/desc.txt" > "$TMP/fora.txt"
  if grep -qx "$V1" "$TMP/fora.txt" && [ "$(grep -c . "$TMP/fora.txt")" -eq 1 ] \
     && [ "$(grep -c . "$TMP/desc.txt")" -eq 1 ]; then
    passou "SHA que o git local nao conhece vai para desconhecidas, e nao para candidatas"
  else
    reprovou "SHA desconhecido tratado como candidata ou perdido sem aviso"
  fi
  if printf 'lixo\n' | janela 0 1 >/dev/null 2>&1; then
    reprovou "janela aceitou orcamento 0"
  else
    passou "janela recusa orcamento invalido"
  fi
fi

# --------------------------------------------------------------------------
# 7. O WORKFLOW USA O SELETOR, E NAO MUDOU O QUE NAO ERA PARA MUDAR.
#    Leitura do arquivo sem comentarios, ancorada em estrutura.
# --------------------------------------------------------------------------
sem_comentario() { sed -E 's/^[[:space:]]*#.*$//' "$WF"; }
CODIGO="$(sem_comentario)"

if printf '%s' "$CODIGO" | grep -q 'bash "\$SEL" fora_da_base' \
   && printf '%s' "$CODIGO" | grep -q 'bash "\$SEL" janela "\$TETO_COMPARACOES" "\$RODADA"' \
   && printf '%s' "$CODIGO" | grep -q 'RODADA: \${{ github.run_number }}'; then
  passou "workflow: o corte B usa fora_da_base e a janela gira por github.run_number"
else
  reprovou "workflow: o levantamento nao passa pelo seletor"
fi

if printf '%s' "$CODIGO" | grep -q 'pontas restantes NAO foram avaliadas'; then
  reprovou "workflow: o laco antigo de 'as primeiras 80' continua no arquivo"
else
  passou "workflow: o laco que parava nas primeiras 80 saiu"
fi

# test_existing_merge_semantics_preserved: merge commit, nunca squash; e a
# ponta julgada e a que entra.
if printf '%s' "$CODIGO" | grep -qE 'gh pr merge "\$numero" --repo RenatoPassos1/leilao-watch --merge --match-head-commit "\$sha"' \
   && ! printf '%s' "$CODIGO" | grep -qE 'gh pr merge.*--(squash|rebase)' \
   && printf '%s' "$CODIGO" | grep -q '"\$cabeca" != "\$sha"'; then
  passou "workflow: merge continua merge commit, e so entra a ponta que passou pelo finish (QUEUED_SHA_IMMUTABLE)"
else
  reprovou "workflow: merge sem --merge, com squash/rebase, ou sem conferir a ponta"
fi

# test_pr_head_ci_state_and_merge_sha_ci_state_are_not_conflated
if printf '%s' "$CODIGO" | grep -q 'select(.fila != null and .fila.state == "success")' \
   && ! printf '%s' "$CODIGO" | grep -q 'ci/actions-engine' \
   && printf '%s' "$CODIGO" | grep -q 'SHA: \${{ steps.mergear.outputs.sha_mergeado }}'; then
  passou "workflow: elegibilidade continua sendo coordenacao/fila da ENTREGA, e o CI disparado e o do MERGE commit"
else
  reprovou "workflow: a elegibilidade passou a ler outro status, ou o CI deixou de ir para o merge commit"
fi

# test_deploy_approval_semantics_preserved: este workflow nao cria ref de
# aprovacao nem de fila (quem cria e o ci-aprovado e o finish).
if ! printf '%s' "$CODIGO" | grep -qE 'refs/(ci-aprovado|fila-coordenacao)/[^*]*(push|update-ref|git/refs)' \
   && ! printf '%s' "$CODIGO" | grep -qE 'git (push|update-ref)' \
   && printf '%s' "$CODIGO" | grep -qE '^  contents: read'; then
  passou "workflow: continua sem escrever ref de aprovacao ou de fila, com contents: read"
else
  reprovou "workflow: passou a escrever ref ou ganhou permissao de escrita em contents"
fi

echo
echo "falhas: $FALHAS (seletor=$SELETOR)"
exit "$FALHAS"
