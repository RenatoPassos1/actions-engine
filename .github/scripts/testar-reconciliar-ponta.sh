#!/usr/bin/env bash
#
# Testes da reconciliacao da ponta (`leiloai-reconciliar-ponta.sh`) e das
# regras do `leiloai-coordenador-fila.yml` que dependem dela.
#
# Roda sem rede e sem credencial: a decisao e funcao pura dos quatro fatos, e
# os fatos sao colhidos pelo workflow, nao por este arquivo.
#
# CONTROLE NEGATIVO EMBUTIDO. `REGRA=ingenua` troca a decisao pela regra que
# uma correcao apressada escreveria ("nao tem ref de aprovacao? dispara o CI"),
# e os testes que protegem contra disparo redundante PRECISAM reprovar com ela.
# O script roda as duas passadas e reprova se a ingenua passar, porque teste
# que passa com o defeito nao testa nada.
#
#   bash .github/scripts/testar-reconciliar-ponta.sh          # as duas passadas
#   REGRA=ingenua bash .github/scripts/testar-reconciliar-ponta.sh --uma
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../.." && pwd)"
WF="${WF_SOB_TESTE:-$RAIZ/.github/workflows/leiloai-coordenador-fila.yml}"
# shellcheck source=leiloai-reconciliar-ponta.sh
. "$AQUI/leiloai-reconciliar-ponta.sh"
set +e

REGRA="${REGRA:-real}"

if [ "${1:-}" != "--uma" ]; then
  echo "=== passada 1: regra REAL, tudo precisa passar ==="
  REGRA=real bash "$0" --uma; real=$?
  echo
  echo "=== passada 2: CONTROLE NEGATIVO, regra INGENUA, o disparo redundante precisa reprovar ==="
  # O workflow sob teste, na passada ingenua, e uma MUTACAO do atual com as
  # regras que os testes estaticos protegem desfeitas: passo que roda em
  # qualquer gatilho, sem separacao de token e sem o modulo puro. Mutacao, e
  # nao o arquivo de ontem, para o controle continuar valendo depois do merge.
  MUT="$(mktemp)"
  sed -e "s/^          (github.event_name == 'schedule' ||\$/          (github.event_name != 'nunca' ||/" \
      -e 's/^          PUBLIC_TOKEN: \${{ github.token }}$/          PUBLIC_TOKEN: ${{ secrets.LEILOAI_STATUS_PAT }}/' \
      -e 's#^          \. \.github/scripts/leiloai-reconciliar-ponta\.sh$#          DECISAO=nunca_pedido#' \
      "$RAIZ/.github/workflows/leiloai-coordenador-fila.yml" > "$MUT"
  REGRA=ingenua WF_SOB_TESTE="$MUT" bash "$0" --uma > "$MUT.saida" 2>&1; ingenua=$?
  grep -E "^(PASSOU|REPROVOU)" "$MUT.saida"
  PASSARAM_NA_INGENUA=$(grep -c "^PASSOU" "$MUT.saida")
  rm -f "$MUT" "$MUT.saida"
  echo
  if [ "$real" -ne 0 ]; then
    echo "RESULTADO: REPROVOU, a regra real falhou em $real teste(s)"; exit 1
  fi
  # Na ingenua podem passar EXATAMENTE quatro, e cada um por um motivo que nao
  # e o defeito: os dois casos de ponta ja aprovada (a regra ingenua tambem sai
  # calada ali), o caso "ninguem pediu" (unico em que ela acerta por acidente,
  # porque e o unico estado que de fato pede CI) e o teste de que o passo 4
  # continua intacto (a mutacao nao o toca). Numero exato, e nao teto: se um
  # quinto passar, e porque um teste parou de enxergar o defeito.
  if [ "$ingenua" -eq 0 ] || [ "$PASSARAM_NA_INGENUA" -ne 4 ]; then
    echo "RESULTADO: REPROVOU, $PASSARAM_NA_INGENUA teste(s) passaram no controle negativo (esperado: exatamente 4)"; exit 1
  fi
  echo "RESULTADO: PASSOU (real passa em tudo; ingenua reprova em $ingenua teste(s))"
  exit 0
fi

FALHAS=0
passou()   { echo "PASSOU    $1"; }
reprovou() { echo "REPROVOU  $1"; FALHAS=$((FALHAS + 1)); }

# --------------------------------------------------------------------------
# DECISAO SOB TESTE, nas duas versoes.
# --------------------------------------------------------------------------
decidir() {
  if [ "$REGRA" = ingenua ]; then
    # A correcao apressada: "a ponta nao tem ref de aprovacao, entao pede o
    # CI". E o que o passo faria sem os outros tres fatos, e e o laco que ja
    # saturou o `ghrunner` duas vezes neste projeto.
    if [ "$2" = sim ]; then echo aprovado; else echo nunca_pedido; fi
    return 0
  fi
  decidir_reconciliacao "$@"
}

# esperar ROTULO ESPERADO JA REF VEREDITO PENDENTE
esperar() {
  local rotulo="$1" esperado="$2"; shift 2
  local veio; veio=$(decidir "$@")
  if [ "$veio" = "$esperado" ]; then
    passou "$rotulo (ja=$1 ref=$2 veredito=$3 pendente=$4 -> $veio)"
  else
    reprovou "$rotulo: esperado $esperado, veio $veio (ja=$1 ref=$2 veredito=$3 pendente=$4)"
  fi
}

# --------------------------------------------------------------------------
# 1. ponta com ci-aprovado -> nenhum dispatch
# --------------------------------------------------------------------------
esperar "APPROVED_HEAD_REDUNDANT_DISPATCH: ponta ja aprovada nao pede nada" \
        aprovado nao sim ausente ausente
esperar "aprovada continua aprovada mesmo com veredito e pendente na mao" \
        aprovado nao sim success completed

# --------------------------------------------------------------------------
# 2. sem ref, ci/actions-engine=success -> so ci-aprovado
# --------------------------------------------------------------------------
esperar "CI_SUCCESS_MISSING_REF_RECOVERED: verde sem ref pede a aprovacao" \
        aprovar nao nao success ausente

# --------------------------------------------------------------------------
# 3. sem ref, ci/actions-engine=failure -> nenhum dispatch automatico
# --------------------------------------------------------------------------
esperar "FAILED_SHA_AUTO_RETRY: failure nao reexecuta sozinho" \
        veredito_terminal_nao_success nao nao failure ausente
esperar "FAILED_SHA_AUTO_RETRY: error tambem nao reexecuta sozinho" \
        veredito_terminal_nao_success nao nao error ausente

# --------------------------------------------------------------------------
# 4 e 5. sem veredito, pendente com run vivo -> nenhum dispatch
# --------------------------------------------------------------------------
for estado in queued in_progress waiting requested pending; do
  esperar "IN_FLIGHT_HEAD_REDUNDANT_DISPATCH: run $estado nao vira disparo" \
          em_voo nao nao ausente "$estado"
done
esperar "veredito pending (contexto do veredito) ainda consulta o em voo" \
        em_voo nao nao pending in_progress

# --------------------------------------------------------------------------
# 6. pendente aponta para run completed mas sem veredito -> dispara ci-publico
# --------------------------------------------------------------------------
esperar "CI_DIED_WITHOUT_VERDICT_RECOVERED: pediu e morreu volta a pedir" \
        morreu_sem_veredito nao nao ausente completed

# --------------------------------------------------------------------------
# 7. sem pendente e sem veredito -> dispara ci-publico
# --------------------------------------------------------------------------
esperar "CI_NOT_REQUESTED_RECOVERED: ninguem pediu, entao peca" \
        nunca_pedido nao nao ausente ausente

# --------------------------------------------------------------------------
# 8. o passo 4 acabou de disparar para esta ponta -> nao duplica
# --------------------------------------------------------------------------
# Este e o caso que a API NAO responde: entre o `gh workflow run` do passo 4 e
# o `pendente` daquele run existe uma janela de segundos em que o GitHub diz
# "ninguem pediu". Quem sabe do pedido e este workflow.
esperar "passo 4 disparou agora e o pendente ainda nao existe: nao duplica" \
        ja_disparado sim nao ausente ausente
esperar "passo 4 disparou agora e o run ja aparece: continua nao duplicando" \
        ja_disparado sim nao ausente queued

# --------------------------------------------------------------------------
# Entrada invalida recusa, e recusar e NAO disparar.
# --------------------------------------------------------------------------
if [ "$REGRA" = real ]; then
  for entrada in "sim nao inventado ausente" "nao talvez ausente ausente" \
                 "nao nao ausente estado_novo_do_github" "nao nao ausente url_invalida"; do
    # shellcheck disable=SC2086
    veio=$(decidir_reconciliacao $entrada); rc=$?
    if [ "$veio" = entrada_invalida ] && [ "$rc" -eq 2 ]; then
      passou "entrada invalida recusa sem disparar ($entrada)"
    else
      reprovou "entrada invalida virou '$veio' com codigo $rc ($entrada)"
    fi
  done

  # --------------------------------------------------------------------------
  # target_url e DADO, e so vira id de run se casar inteiro.
  # --------------------------------------------------------------------------
  ok=1
  id=$(extrair_run_id "https://github.com/RenatoPassos1/actions-engine/actions/runs/35127518539" RenatoPassos1/actions-engine) \
    || ok=0
  [ "$id" = 35127518539 ] || ok=0
  for ruim in "https://github.com/OUTRO/repo/actions/runs/1" \
              "https://evil.example/RenatoPassos1/actions-engine/actions/runs/1" \
              "https://github.com/RenatoPassos1/actions-engine/actions/runs/1/../../2" \
              "https://github.com/RenatoPassos1/actions-engine/actions/runs/abc" \
              "https://github.com/RenatoPassos1/actions-engine/actions/runs/" \
              ""; do
    if extrair_run_id "$ruim" RenatoPassos1/actions-engine >/dev/null 2>&1; then
      ok=0; echo "  aceitou target_url que devia recusar: $ruim"
    fi
  done
  if [ "$ok" -eq 1 ]; then
    passou "target_url so vira run id quando casa inteiro, no repositorio certo"
  else
    reprovou "extrair_run_id aceitou URL de outro host/repositorio ou id nao numerico"
  fi
fi

# --------------------------------------------------------------------------
# O PASSO INTEIRO, E NAO SO A DECISAO: os dez casos contados em DISPAROS.
# --------------------------------------------------------------------------
# A funcao pura diz a palavra certa; isto prova que o bloco `run:` colhe os
# quatro fatos e converte a palavra em ACAO, que e o que produz (ou nao)
# chamada de API. O `gh` e de mentira, entao nao ha rede nem credencial:
# cada cenario diz o que a API responderia, e o registro conta o que o passo
# tentou disparar. Gate medido aqui, e nao prometido: disparo redundante e
# um numero, e o numero e zero.
#
# So na passada REAL. O controle negativo existe para provar que os testes de
# DECISAO enxergam o defeito; a mutacao daquela passada arranca o modulo puro
# do workflow, e ai o bloco cai no ramo "nao sei classificar" e nao dispara
# nada, o que faria metade destes casos passar por um motivo que nao e o
# certo. Teste que passa pelo motivo errado e ruido.
if [ "$REGRA" = real ]; then
  T="$(mktemp -d)"
  # O bloco `run:` do passo, extraido do proprio arquivo sob teste: se alguem
  # reescrever o passo, e o novo texto que roda aqui.
  awk '
    /^      - name: Reconciliar a ponta de feat\/landing com a aprovacao$/ { achou=1 }
    achou && /^        run: \|$/ { dentro=1; next }
    dentro {
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      if ($0 !~ /^          /) { exit }
      sub(/^          /, ""); print
    }
  ' "$WF" | sed 's#\${{ github.repository }}#RenatoPassos1/actions-engine#g' > "$T/passo.sh"

  if [ "$(grep -c . "$T/passo.sh")" -lt 40 ]; then
    reprovou "nao consegui extrair o bloco run do passo de reconciliacao ($(grep -c . "$T/passo.sh") linha(s))"
  else
    mkdir -p "$T/bin"
    cat > "$T/bin/gh" <<'FAKEGH'
#!/usr/bin/env bash
# gh de mentira. Responde pelo cenario nas variaveis CEN_*, e anota em
# $REGISTRO cada workflow que o passo tentou disparar.
sub="$1"; shift
case "$sub" in
  api)
    case "$1" in
      */branches/feat/landing) printf '%s' "$CEN_PONTA" ;;
      */git/ref/ci-aprovado/*)
        [ "$CEN_REF" = sim ] || exit 1
        printf 'refs/ci-aprovado/%s' "$CEN_PONTA" ;;
      */commits/*/status)
        if printf '%s' "$*" | grep -q '/pendente'; then printf '%s' "$CEN_URL"
        else printf '%s' "$CEN_VEREDITO"; fi ;;
      */actions/runs/*) printf '%s' "$CEN_RUN" ;;
      *) exit 1 ;;
    esac ;;
  workflow) shift; echo "$1" >> "$REGISTRO" ;;
esac
FAKEGH
    chmod +x "$T/bin/gh"

    # cenario ROTULO ESPERADO_DECISAO ESPERADO_DISPARO REF VEREDITO URL RUN JA
    cenario() {
      local rotulo="$1" dec_esp="$2" disp_esp="$3"
      local ponta=be30d5fc3bd7b65713c850c48b7df5f8a430eeb1
      local saida veio disparos
      saida=$(
        PATH="$T/bin:$PATH" \
        CEN_PONTA="$ponta" CEN_REF="$4" CEN_VEREDITO="$5" CEN_URL="$6" CEN_RUN="$7" \
        SHA_MERGEADO="$8" STATUS_PAT=pat-de-mentira PUBLIC_TOKEN=token-de-mentira \
        REGISTRO="$T/disparos.txt" GITHUB_STEP_SUMMARY="$T/resumo.md" \
        bash -c ': > "$REGISTRO"; bash "$0"' "$T/passo.sh" 2>&1
      )
      veio=$(printf '%s' "$saida" | grep -o 'decisao=[a-z_]*' | head -1)
      veio="${veio#decisao=}"
      disparos=$(tr '\n' ' ' < "$T/disparos.txt"); disparos="${disparos% }"
      if [ "$veio" = "$dec_esp" ] && [ "$disparos" = "$disp_esp" ]; then
        passou "passo inteiro: $rotulo -> $veio, disparos=[$disparos]"
      else
        reprovou "passo inteiro: $rotulo esperava $dec_esp/[$disp_esp], veio $veio/[$disparos]"
      fi
    }

    URL_OK="https://github.com/RenatoPassos1/actions-engine/actions/runs/35127518539"
    cenario "1 ponta ja aprovada"            aprovado                     ""                        sim ausente ""        ""          ""
    cenario "2 verde sem ref"                aprovar                      leiloai-ci-aprovado.yml   nao success ""        ""          ""
    cenario "3 veredito failure"             veredito_terminal_nao_success ""                       nao failure ""        ""          ""
    cenario "3b veredito error"              veredito_terminal_nao_success ""                       nao error   ""        ""          ""
    cenario "4 pendente in_progress"         em_voo                       ""                        nao ausente "$URL_OK" in_progress ""
    cenario "5 pendente queued"              em_voo                       ""                        nao ausente "$URL_OK" queued      ""
    cenario "6 pendente completed sem veredito" morreu_sem_veredito       leiloai-ci-publico.yml    nao ausente "$URL_OK" completed   ""
    cenario "7 sem pendente e sem veredito"  nunca_pedido                 leiloai-ci-publico.yml    nao ausente ""        ""          ""
    cenario "8 passo 4 ja disparou a ponta"  ja_disparado                 ""                        nao ausente ""        ""          be30d5fc3bd7b65713c850c48b7df5f8a430eeb1
    cenario "target_url de outro host"       entrada_invalida             ""                        nao ausente "https://exemplo.invalid/x/actions/runs/1" "" ""
    cenario "estado de run que o GitHub nao devolvia" entrada_invalida    ""                        nao ausente "$URL_OK" estado_novo ""
  fi
  rm -rf "$T"
fi

# --------------------------------------------------------------------------
# 9 e 10. O GATILHO: o passo so age em schedule e em dispatch modo=executar.
#    Leitura do arquivo sem comentarios, ancorada em estrutura.
# --------------------------------------------------------------------------
sem_comentario() { sed -E 's/^[[:space:]]*#.*$//' "$WF"; }
CODIGO="$(sem_comentario)"

if printf '%s' "$CODIGO" | grep -q "github.event_name == 'schedule' ||" \
   && printf '%s' "$CODIGO" | grep -q "github.event_name == 'workflow_dispatch' && inputs.modo == 'executar'"; then
  passou "gatilho: reconciliacao so em schedule ou dispatch modo=executar (zero efeito em push e em conferir)"
else
  reprovou "gatilho: o passo de reconciliacao roda fora de schedule/executar, entao push e conferir passam a ter efeito colateral"
fi

# --------------------------------------------------------------------------
# EXISTING_POST_MERGE_WAKE_UNCHANGED: o passo 4 nao foi tocado.
# --------------------------------------------------------------------------
if printf '%s' "$CODIGO" | grep -q "if: steps.mergear.outputs.sha_mergeado != ''" \
   && printf '%s' "$CODIGO" | grep -q 'SHA: \${{ steps.mergear.outputs.sha_mergeado }}'; then
  passou "o caminho rapido pos-merge continua com a condicao original"
else
  reprovou "a condicao do passo 4 mudou, e ela estava certa"
fi

# --------------------------------------------------------------------------
# A decisao mora no modulo puro, e os dois tokens continuam separados.
# --------------------------------------------------------------------------
if printf '%s' "$CODIGO" | grep -q '\. \.github/scripts/leiloai-reconciliar-ponta\.sh' \
   && printf '%s' "$CODIGO" | grep -q 'decidir_reconciliacao "\$JA" "\$APROVADO" "\$VEREDITO" "\$PENDENTE"'; then
  passou "a decisao vem do modulo puro, e nao de um if solto dentro do run"
else
  reprovou "a decisao voltou para dentro do bloco run, onde nao se testa"
fi

# O padrao do PAT mora numa VARIAVEL e a busca usa herestring, sem `printf`.
# Nao e estilo: `.github/scripts/proibir-exfiltracao.sh` reprova qualquer linha
# em que `echo`/`printf` e `${{ secrets.` aparecem juntos, e ela esta certa em
# reprovar, porque le o PADRAO do comando e nao o valor. Aqui a string e so um
# alvo de busca, mas trava que abre excecao por intencao declarada deixa de ser
# trava. Entao quem muda de forma e o codigo, e nao a trava.
PADRAO_PAT='STATUS_PAT: ${{ secrets.LEILOAI_STATUS_PAT }}'
if grep -qF "$PADRAO_PAT" <<< "$CODIGO" \
   && printf '%s' "$CODIGO" | grep -q 'PUBLIC_TOKEN: \${{ github.token }}' \
   && printf '%s' "$CODIGO" | grep -q 'GH_TOKEN="\$STATUS_PAT" gh api "repos/\$REPO_PRIVADO/branches/\$BASE"' \
   && printf '%s' "$CODIGO" | grep -q 'GH_TOKEN="\$PUBLIC_TOKEN" gh workflow run leiloai-ci-publico.yml' \
   && ! printf '%s' "$CODIGO" | grep -qE 'https://[^[:space:]]*\$(STATUS_PAT|PUBLIC_TOKEN|\{GH_TOKEN)'; then
  passou "tokens separados: o PAT so le o privado, o github.token so dispara aqui, e nenhum entra em URL"
else
  reprovou "os tokens se misturaram, ou algum foi para dentro de uma URL"
fi

echo
echo "falhas: $FALHAS (regra=$REGRA)"
exit "$FALHAS"
