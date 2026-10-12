#!/usr/bin/env bash
# Congelamento do coordenador e NOTICIA; coordenador ACTIVO inalcancavel REPROVA.
#
# ============================================================================
# O INVARIANTE, em duas metades que se protegem uma da outra
# ============================================================================
#
#     FROZEN_COORDINATOR_FAILS_CI = 0
#     UNREACHABLE_ACTIVE_COORDINATOR_STILL_FAILS = 1
#
# A segunda metade e a que impede o conserto da primeira de virar falso verde.
# Sem ela, "deixar de reprovar quando nao consigo acordar o coordenador" passa
# nos testes e apaga o alarme que o defeito de 29/08 deixou aqui.
#
# ============================================================================
# O CASO MEDIDO, 12/10/2026
# ============================================================================
#
# O `leiloai-coordenador-fila.yml` foi posto em `disabled_manually` as
# 02:39:47Z, para o congelamento do integrador ser mecanismo e nao declaracao.
# `gh workflow run` num workflow desactivado falha; as tres tentativas falham;
# este passo fazia `exit 1`; e a corrida concluia `failure` com o veredito
# VERDE ja publicado no SHA. Quatro corridas seguidas, de 02:57Z a 03:57Z.
#
# E o dano nao e cosmetico: no caminho VERMELHO este bloco nem corre, porque
# ele vive dentro de `if [ "$ESTADO" = "success" ]`. Logo a conclusao da
# corrida era `failure` nos DOIS casos e deixou de distinguir reprovacao real
# de coordenador desligado. Sinal que vale o mesmo em todos os estados nao
# carrega informacao, e `BLIND_CI_RERUNS=0` depende de alguem poder ler o
# estado verdadeiro para nao pedir rerun as cegas.
#
# ============================================================================
# POR QUE ESTE TESTE CORRE O BLOCO EM VEZ DE LER O TEXTO DELE
# ============================================================================
#
# O irmao `testar-guarda-status-ci-publico.sh` confere TEXTO de YAML, e para o
# que ele guarda (a condicao `if` de um job) isso basta. Aqui o invariante e
# COMPORTAMENTO: `exit 1` num ramo e `exit 0` noutro. Uma trava textual diria
# que a condicao existe sem nunca provar qual ramo corre, e esta casa ja pagou
# `casos=23 passaram=15` por um teste cujo veredito vinha de outra expressao.
#
# Entao o bloco real e EXTRAIDO do YAML por MARCADOR explicito e CORRIDO com
# dubles de `gh`. Marcador, e nao proximidade: ancora por proximidade migra
# calada quando alguem insere uma linha no meio.
#
# `sleep` e neutralizado por funcao: o laco dorme 5 s e depois 10 s por caso, e
# este teste nao mede tempo nenhum. Fica declarado para ninguem ler o silencio
# como prova de que a espera existe.
#
# NAO HA SEGREDO AQUI: o `TOKEN_DISPARO` do caso e uma string de teste, e o
# duble de `gh` nao fala com a rede. Este repositorio e PUBLICO, e o log dele
# e leitura aberta.
#
# exit 0 = as duas metades valem, e os dois mutantes morrem.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$AQUI/../workflows/leiloai-ci-publico.yml"
[ -f "$WF" ] || { echo "workflow nao encontrado: $WF"; exit 2; }

passou=0; falhou=0
ok()  { echo "  [ok]    $1"; passou=$((passou + 1)); }
nok() { echo "  [FALHA] $1"; falhou=$((falhou + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# 1. EXTRACCAO, e ela tem de PROVAR que trouxe algo. Bloco vazio aprovaria
#    todos os casos por vacuidade, que e o modo mais comum de estas travas
#    falharem sem ninguem notar.
tr -d '\r' < "$WF" \
  | sed -n '/# >>> BLOCO-ACORDAR-COORDENADOR/,/# <<< BLOCO-ACORDAR-COORDENADOR/p' \
  > "$TMP/bloco.raw"
n_bloco=$(grep -c "" "$TMP/bloco.raw" || true)
if [ "${n_bloco:-0}" -lt 20 ]; then
  echo "EXTRACCAO CURTA OU VAZIA: linhas=${n_bloco:-0}. Os marcadores ainda existem no YAML?"
  exit 2
fi
echo "METRICA congelamento bloco-linhas=$n_bloco"

# 2. O duble de `gh`, em dois eixos: o `state` que a API devolve (vazio quer
#    dizer que a LEITURA falha) e o codigo de saida do `workflow run`.
duble() { # $1=dir  $2=state (vazio: api falha)  $3=rc do workflow run
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<DUBLE
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then
  [ -n "$2" ] || exit 7
  echo "$2"
  exit 0
fi
if [ "\$1" = "workflow" ]; then
  exit $3
fi
exit 0
DUBLE
  chmod +x "$1/bin/gh"
}

# 3. Monta o script corrivel a partir do bloco extraido do YAML real.
monta() { # $1=destino  $2=ESTADO  $3=mutacao sed (vazio: nenhuma)
  {
    echo "set -euo pipefail"
    echo "sleep() { :; }"
    echo "ESTADO=$2"
    echo "SHA=0000000000000000000000000000000000000000"
    echo "TOKEN_DISPARO=valor-de-teste-sem-segredo"
    if [ -n "$3" ]; then
      sed 's|[$][{][{] github.repository [}][}]|dono/repo|g' "$TMP/bloco.raw" | sed "$3"
    else
      sed 's|[$][{][{] github.repository [}][}]|dono/repo|g' "$TMP/bloco.raw"
    fi
  } > "$1"
}

corre() { # $1=rotulo $2=state $3=rc_run $4=ESTADO $5=mutacao
  local d="$TMP/$1"
  mkdir -p "$d"
  duble "$d" "$2" "$3"
  monta "$d/s.sh" "$4" "$5"
  ( PATH="$d/bin:$PATH"; bash "$d/s.sh" ) > "$d/out" 2>&1
  echo "$?" > "$d/rc"
}

echo "== as duas metades do invariante =="

# CASO A: congelado e inalcancavel -> NOTICIA, e nao falha.
corre a disabled_manually 1 success ""
rc=$(cat "$TMP/a/rc")
if [ "$rc" = "0" ] && grep -q "::notice::" "$TMP/a/out" && ! grep -q "::error::" "$TMP/a/out"; then
  ok "congelado e inalcancavel: rc=0, com ::notice:: e SEM ::error::"
else
  nok "congelado reprovou (rc=$rc) ou nao avisou: $(tr '\n' '|' < "$TMP/a/out" | cut -c1-160)"
fi
if grep -q "disabled_manually" "$TMP/a/out" && grep -q "motivo_e_autor" "$TMP/a/out"; then
  ok "o aviso nomeia o ESTADO e aponta onde se le o motivo e o autor"
else
  nok "o aviso nao nomeia o estado nem aponta onde esta o motivo"
fi

# CASO B: A METADE QUE PROTEGE 29/08. Activo e inalcancavel REPROVA.
corre b active 1 success ""
rc=$(cat "$TMP/b/rc")
if [ "$rc" != "0" ] && grep -q "::error::" "$TMP/b/out"; then
  ok "ACTIVO e inalcancavel: rc=$rc com ::error::, logo o defeito de 29/08 segue travado"
else
  nok "activo e inalcancavel NAO reprovou (rc=$rc): isto seria um falso verde"
fi

# CASO C: o caminho feliz continua feliz.
corre c active 0 success ""
rc=$(cat "$TMP/c/rc")
if [ "$rc" = "0" ] && grep -q "coordenador da fila acordado" "$TMP/c/out"; then
  ok "activo e alcancavel: acorda e passa"
else
  nok "o caminho feliz quebrou (rc=$rc)"
fi

# CASO D: LER FALHOU NAO E ESTAR DESLIGADO.
corre d "" 1 success ""
rc=$(cat "$TMP/d/rc")
if [ "$rc" != "0" ]; then
  ok "API ilegivel: rc=$rc, porque ausencia de prova nao e prova de ausencia"
else
  nok "API ilegivel virou isencao: qualquer falha de rede calaria o alarme"
fi

# CASO E: CONTROLE. O veredito vermelho nem chega a este bloco.
corre e active 1 failure ""
rc=$(cat "$TMP/e/rc")
if [ "$rc" = "0" ] && ! grep -q "::error::" "$TMP/e/out" && ! grep -q "::notice::" "$TMP/e/out"; then
  ok "CONTROLE: ESTADO=failure nao tenta acordar nada e nao reprova aqui"
else
  nok "o ramo vermelho mexeu no coordenador (rc=$rc)"
fi

echo "== os mutantes: trava que nunca fica vermelha nao protege nada =="

# MUTANTE 1: a isencao vira INCONDICIONAL (a condicao do ramo activo passa a
#            `false`), logo nada mais e tentado. O caso B tem de deixar de
#            reprovar, senao o caso B nao tem dentes.
#
#            E ELE CORRE COM `active` DE PROPOSITO. A primeira versao deste
#            mutante apagava a condicao e corria com `disabled_manually`, onde
#            ela ja era verdadeira: o mutante nao mudava nada e o teste
#            acusava-me de testar a condicao errada. Mutante tem de morrer no
#            LUGAR CERTO, e o lugar e a populacao onde a condicao decide.
corre m1 active 1 success 's/\[ "\$estado_coordenador" != "disabled_manually" \]/false/'
rc=$(cat "$TMP/m1/rc")
if [ "$rc" = "0" ]; then
  ok "MUTANTE isencao-incondicional: o caso B deixaria de reprovar, logo ele tem dentes"
else
  nok "o mutante 1 nao mudou nada (rc=$rc): a condicao que eu testo nao e a que decide"
fi

# MUTANTE 2: o estado congelado deixa de ser reconhecido. O caso A tem de
#            voltar a reprovar.
corre m2 disabled_manually 1 success 's/"disabled_manually"/"nunca-este-valor"/g'
rc=$(cat "$TMP/m2/rc")
if [ "$rc" != "0" ]; then
  ok "MUTANTE sem-reconhecer-congelado: volta a reprovar, logo o caso A tem dentes"
else
  nok "o mutante 2 nao mudou nada (rc=$rc): o caso A passaria mesmo sem a isencao"
fi

echo ""
echo "RESULTADO: casos=$((passou + falhou)) passaram=$passou falharam=$falhou"
[ "$falhou" -eq 0 ]
