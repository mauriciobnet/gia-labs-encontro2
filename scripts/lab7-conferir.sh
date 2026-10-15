#!/usr/bin/env bash
# Fim do Lab 7: confere o laboratório e grava a evidência. Na pasta do repositório:
#   docker compose exec -T toolbox bash /work/scripts/lab7-conferir.sh
#
# A evidência do Lab 7 nasce aqui, e não na montagem (mudança de 15/10/2026): antes, o
# lab7-saml-fallback.sh a gravava logo no início, e o painel dava o lab por concluído sem o aluno
# abrir o navegador. O que só o aluno faz no Lab 7 são os dois logins federados, e cada um deixa
# no realm acme um usuário ligado ao provedor de onde ele veio (Users > ... > Identity provider
# links). O script de montagem não faz esses logins: ele só guarda a SAMLResponse do parceiro, sem
# entregá-la à ACME. Então:
#   passos 3 a 5    parceiro.user existe no realm acme, ligado ao IdP SAML parceiro-kc;
#   passos 10 e 11  maria.prof existe no realm acme, ligada ao IdP OIDC universidade.
# O SimpleSAMLphp (parceiro-saml, lab7-saml.sh) é opcional e fica fora da conferência.
set -euo pipefail
source /work/scripts/lib.sh
MONTAGEM_CMD="docker compose exec -T toolbox bash /work/scripts/lab7-saml-fallback.sh"

[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: o Keycloak não emitiu o token de administrador (ele está no ar?)"; exit 1; }

say "a montagem (antes do passo 1)"
conf_montagem 7 "$MONTAGEM_CMD"

federado() { # usuario idp passos rotulo
  local id link
  id=$(kc_get "/users?username=$1&exact=true" 2>/dev/null | jq -r '.[0].id // empty') || id=""
  if [ -z "$id" ]; then
    conf_falha "refaça os passos $3: a conta $1 ainda não entrou na ACME pelo $4" "nenhum usuário $1 no realm $REALM"
    return 0
  fi
  link=$(kc_get "/users/$id/federated-identity" 2>/dev/null \
    | jq -r --arg i "$2" '.[] | select(.identityProvider == $i) | .userName') || link=""
  if [ -n "$link" ]; then
    conf_ok "passos $3: a conta $1 entrou na ACME pelo $4" \
      "usuário $1 no realm $REALM, ligado a \"$link\" no provedor $2; criado em $(kc_get "/users/$id" | jq -r '(.createdTimestamp // 0) / 1000 | floor | todate')"
  else
    conf_falha "refaça os passos $3: a conta $1 existe no realm $REALM, mas sem vínculo com o provedor $2" \
      "vínculos: $(kc_get "/users/$id/federated-identity" | jq -r '[.[].identityProvider] | join(", ") | if . == "" then "nenhum" else . end')"
  fi
}

say "passos 3 a 5: o parceiro, por SAML"
federado parceiro.user parceiro-kc "3 a 5" "IdP SAML do parceiro (botão Parceiro (SAML via Keycloak))"

say "passos 10 e 11: a universidade, por OIDC"
federado maria.prof universidade "10 e 11" "IdP OIDC da universidade (botão Universidade (OIDC))"

echo
conf_gravar 7
if [ "$FAILS" -eq 0 ]; then echo "LAB7 OK"
else echo "LAB7 FALHOU ($FAILS)"; exit 1; fi
