#!/usr/bin/env bash
# Fim do Lab 6: confere o laboratório e grava a evidência. Na pasta do repositório:
#   docker compose exec -T toolbox bash /work/scripts/lab6-conferir.sh
#
# A evidência do Lab 6 nasce aqui, e não na montagem (mudança de 15/10/2026): antes, o lab6-sso.sh
# a gravava logo no início, e o painel dava o lab por concluído sem o aluno abrir o navegador.
# O que só o aluno faz no Lab 6 acontece no navegador, e a sessão some no logout do passo 9. O
# que sobra no servidor são os eventos do realm, que a montagem liga: um LOGIN por aplicação em
# que a Ana entrou e um LOGOUT. É deles que esta conferência tira a prova:
#   passos 1 a 3  LOGIN da ana.souza no client grafana (o Grafana pelo Keycloak);
#   passo 4       LOGIN da ana.souza no client app-acme (a segunda aplicação, sem senha: SSO);
#   passo 9       LOGOUT da ana.souza (o Grafana encerrando a sessão no Keycloak).
set -euo pipefail
source /work/scripts/lib.sh
MONTAGEM_CMD="docker compose exec -T toolbox bash /work/scripts/lab6-sso.sh"

[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: o Keycloak não emitiu o token de administrador (ele está no ar?)"; exit 1; }

say "a montagem (antes do passo 1)"
conf_montagem 6 "$MONTAGEM_CMD"

say "os eventos do realm"
if kc_get "/events/config" 2>/dev/null | jq -e '.eventsEnabled == true' >/dev/null 2>&1; then
  conf_ok "eventos do realm $REALM ligados (a montagem os liga antes do passo 1)" "Realm settings > Events"
else
  conf_falha "os eventos do realm $REALM estão desligados: rode a montagem de novo e refaça os passos 1 a 10" "$MONTAGEM_CMD"
fi

ID_ANA=$(kc_get "/users?username=ana.souza&exact=true" 2>/dev/null | jq -r '.[0].id // empty') || ID_ANA=""
EVENTOS='[]'
if [ -n "$ID_ANA" ]; then
  EVENTOS=$(kc_get "/events?user=$ID_ANA&max=2000" 2>/dev/null) || EVENTOS='[]'
fi
# quantos e o último, de um tipo e (opcionalmente) de um client
visto() { # tipo [client]
  jq -r --arg t "$1" --arg c "${2:-}" '[.[] | select(.type == $t and ($c == "" or .clientId == $c))]
    | if length == 0 then "nenhum"
      else "\(length) evento(s) \($t); o último em \((map(.time) | max / 1000 | floor | todate))" end' <<< "$EVENTOS"
}

say "passos 1 a 3: a Ana no Grafana, pelo Keycloak"
V=$(visto LOGIN grafana)
if [ "$V" != "nenhum" ]; then conf_ok "passos 1 a 3: a ana.souza entrou no Grafana pelo Keycloak (client grafana)" "$V"
else conf_falha "refaça os passos 1 a 3: não há login da ana.souza no client grafana desde a montagem" "LOGIN grafana: $V"; fi

say "passo 4: a segunda aplicação, sem senha (SSO)"
V=$(visto LOGIN app-acme)
if [ "$V" != "nenhum" ]; then conf_ok "passo 4: a mesma sessão abriu a aplicação do oauth2-proxy (client app-acme)" "$V"
else conf_falha "refaça o passo 4: não há login da ana.souza no client app-acme (http://app.localhost:$PORTA)" "LOGIN app-acme: $V"; fi

say "passo 9: o logout no Grafana"
V=$(visto LOGOUT)
if [ "$V" != "nenhum" ]; then conf_ok "passo 9: o logout no Grafana encerrou a sessão da ana.souza no Keycloak" "$V"
else conf_falha "refaça o passo 9: saia do Grafana pelo menu do avatar (Sign out) e, se o Keycloak perguntar, confirme" "LOGOUT: $V"; fi

echo
conf_gravar 6
if [ "$FAILS" -eq 0 ]; then echo "LAB6 OK"
else echo "LAB6 FALHOU ($FAILS)"; exit 1; fi
