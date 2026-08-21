#!/usr/bin/env bash
# A validacao de entrada do CI publico do LeilôAI aguenta entrada hostil?
#
# ============================================================================
# POR QUE ISTO EXISTE
# ============================================================================
#
# `leiloai-ci-publico.yml` recebe dois valores de fora (`sha` e `mode`) e, com
# eles, faz checkout de um repositorio PRIVADO e executa o codigo que vier.
# Se a validacao afrouxar, o input deixa de escolher "qual commit" e passa a
# escolher "o que roda".
#
# A secao 47 do plano de migracao exige provar que entrada invalida e recusada,
# e a 43 exige que so SHA de 40 hex e modo de lista fechada passem.
#
# ============================================================================
# O TESTE LE A EXPRESSAO DO PROPRIO WORKFLOW
# ============================================================================
#
# Reescrever o regex aqui criaria duas copias da mesma regra, e a copia velha
# aprovaria o que a nova recusa (ou o contrario) sem ninguem notar. Este
# projeto ja pagou por isso em outro lugar, com dois parsers publicando
# regras diferentes para o mesmo dado.
#
# Entao o regex e EXTRAIDO do YAML. Se alguem afrouxar a validacao la, o teste
# passa a usar a versao afrouxada e os casos hostis reprovam aqui.
#
# exit 0 = tudo recusado/aceito como deveria.
set -uo pipefail

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$AQUI/../workflows/leiloai-ci-publico.yml"
[ -f "$WF" ] || { echo "workflow nao encontrado: $WF"; exit 2; }

passou=0; falhou=0
ok()  { echo "  [ok]    $1"; passou=$((passou + 1)); }
nok() { echo "  [FALHA] $1"; falhou=$((falhou + 1)); }

# ------------------------------------------------ o regex vem do arquivo
# A busca e pela LINHA que valida o SHA (`printf '%s' "$SHA" | grep -qE ...`),
# e o regex sai dela, qualquer que ele seja. Assim, afrouxar a validacao no
# workflow nao esconde nada: o teste passa a usar a versao afrouxada e os
# casos hostis abaixo reprovam, dizendo exatamente o que passou a ser aceito.
RE_SHA=$(grep -E 'printf .%s. "\$SHA".*grep -qE' "$WF" | head -1 | sed -E "s/.*grep -qE '([^']*)'.*/\1/")
if [ -z "$RE_SHA" ]; then
  echo "  [FALHA] nao achei a linha que valida o SHA no workflow."
  echo "          Procurei por: printf '%s' \"\$SHA\" | grep -qE '<regex>'"
  echo "          Se a validacao mudou de forma, este teste precisa mudar junto,"
  echo "          e reprovar aqui e melhor do que aprovar sem ter conferido."
  exit 1
fi
ok "regex de SHA extraido do workflow: $RE_SHA"

MODOS=$(grep -oE '^\s+full\|quick\)' "$WF" | head -1)
[ -n "$MODOS" ] && ok "lista fechada de modos encontrada no workflow" \
                || nok "nao achei a lista fechada de modos (full|quick)"

validar() {
  local sha="$1" modo="$2"
  case "${modo:-full}" in full|quick) ;; *) return 1 ;; esac
  [ -z "$sha" ] && return 0
  printf '%s' "$sha" | grep -qE "$RE_SHA" || return 1
  return 0
}

caso() {
  local d="$1" esp="$2" s="$3" m="$4" r
  if validar "$s" "$m"; then r=ACEITA; else r=RECUSA; fi
  [ "$r" = "$esp" ] && ok "$d -> $r" || nok "$d -> esperava $esp, veio $r"
}

echo "=== SHA ==="
caso "vazio (usa o HEAD do branch)"      ACEITA "" full
caso "40 hex minusculos"                 ACEITA "0123456789abcdef0123456789abcdef01234567" full
caso "curto demais"                      RECUSA "0123456" full
caso "com maiuscula"                     RECUSA "0123456789ABCDEF0123456789abcdef01234567" full
caso "41 caracteres"                     RECUSA "0123456789abcdef0123456789abcdef012345678" full
caso "travessia de caminho"              RECUSA "../../etc/passwd" full
caso "ponto-e-virgula (encadeia comando)" RECUSA "abc;rm -rf /" full
caso "substituicao de comando"           RECUSA '$(id)' full
caso "aspas e pipe"                      RECUSA '"|cat /etc/shadow' full
caso "nome de branch em vez de SHA"      RECUSA "feat/landing" full
caso "SHA de 40 com caractere fora do hex" RECUSA "0123456789abcdef0123456789abcdef0123456z" full

echo "=== modo ==="
caso "full"                              ACEITA "" full
caso "quick"                             ACEITA "" quick
caso "vazio (default full)"              ACEITA "" ""
caso "inventado"                         RECUSA "" turbo
caso "com injecao"                       RECUSA "" 'full; curl evil'

echo "=== o que NAO pode existir como input ==="
for proibido in url path command script repository owner repo; do
  if awk '/workflow_dispatch:/,/^  push:/' "$WF" | grep -qE "^      ${proibido}:"; then
    nok "input '$proibido' declarado: quem dispara passaria a escolher o que roda"
  else
    ok "sem input '$proibido'"
  fi
done

echo
echo "  passou: $passou    falhou: $falhou"
[ "$falhou" -eq 0 ]
