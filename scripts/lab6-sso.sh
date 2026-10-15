#!/usr/bin/env bash
# Montagem do Lab 6 · SSO com OIDC (roda ANTES do passo 1): registra o oauth2-proxy (app.localhost)
# como client do realm acme, cria o client scope "groups" (claim com os grupos do LDAP), o liga aos
# clients que já existiam (o grafana e o toolbox-cli nascem no Lab 5) e liga o registro dos eventos
# de login e logout do realm. A evidência do lab não sai daqui: sai da conferência do fim do
# roteiro (lab6-conferir.sh), que lê desses eventos o que o aluno fez no navegador.
# Pré-requisito: Lab 5 concluído (a conferência do passo 19 apaga o OTP da Ana).
# Na pasta do repositório:  docker compose exec -T toolbox bash /work/scripts/lab6-sso.sh
set -euo pipefail
source /work/scripts/lib.sh

say "client scope 'groups' (claim groups em id/access/userinfo, padrão para todos os clients)"
GS_ID=$(kc_get "/client-scopes" | jq -r '.[] | select(.name=="groups") | .id')
if [ -z "$GS_ID" ]; then
  kc_post "/client-scopes" '{"name":"groups","protocol":"openid-connect","attributes":{"include.in.token.scope":"true","display.on.consent.screen":"false"}}' >/dev/null
  GS_ID=$(kc_get "/client-scopes" | jq -r '.[] | select(.name=="groups") | .id')
  kc_post "/client-scopes/$GS_ID/protocol-mappers/models" '{
    "name":"groups","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper",
    "config":{"claim.name":"groups","full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true"}}' >/dev/null
  echo "scope groups criado: $GS_ID"
else echo "scope groups já existe: $GS_ID"; fi
kc_put "/default-default-client-scopes/$GS_ID" '' >/dev/null 2>&1 || true

say "client grafana (confidencial, authorization code + PKCE)"
kc_ensure_client '{"clientId":"grafana","name":"Grafana","protocol":"openid-connect","publicClient":false,
  "secret":"grafana-secret","standardFlowEnabled":true,"directAccessGrantsEnabled":false,
  "redirectUris":["http://grafana.localhost'"$SUF"'/login/generic_oauth"],"webOrigins":["http://grafana.localhost'"$SUF"'"],
  "attributes":{"post.logout.redirect.uris":"http://grafana.localhost'"$SUF"'/login","pkce.code.challenge.method":"S256"}}' >/dev/null

say "client app-acme (oauth2-proxy protegendo app.localhost)"
kc_ensure_client '{"clientId":"app-acme","name":"App legada (oauth2-proxy)","protocol":"openid-connect","publicClient":false,
  "secret":"app-secret","standardFlowEnabled":true,"directAccessGrantsEnabled":false,
  "redirectUris":["http://app.localhost'"$SUF"'/oauth2/callback"],"webOrigins":["http://app.localhost'"$SUF"'"],
  "attributes":{"post.logout.redirect.uris":"http://app.localhost'"$SUF"'/*","pkce.code.challenge.method":"S256"}}' >/dev/null

say "audience mapper do app-acme (o access token do Keycloak vem com aud=[account])"
# Sem isto o oauth2-proxy devolve HTTP 500 no /oauth2/callback:
#   audience from claim aud with value [account] does not match with any of allowed audiences map[app-acme:{}]
# O Keycloak só põe em "aud" os clients para os quais o usuário tem client roles, e o
# oauth2-proxy v7.8 exige o próprio client_id ali. O teste do Lab 6 NÃO pega isso, porque
# ele para no primeiro redirect e nunca chega ao callback: por isso a asserção no fim.
APP_CID=$(kc_client_id app-acme)
if ! kc_get "/clients/$APP_CID/protocol-mappers/models" | jq -e '.[] | select(.name=="audience-app-acme")' >/dev/null; then
  kc_post "/clients/$APP_CID/protocol-mappers/models" '{"name":"audience-app-acme","protocol":"openid-connect",
    "protocolMapper":"oidc-audience-mapper",
    "config":{"included.client.audience":"app-acme","access.token.claim":"true","id.token.claim":"true",
              "introspection.token.claim":"true"}}' >/dev/null
  echo "audience mapper criado"
else echo "audience mapper já existe"; fi

say "client toolbox-cli (público, direct grant: só para os testes de linha de comando do aluno)"
kc_ensure_client '{"clientId":"toolbox-cli","name":"Toolbox CLI","protocol":"openid-connect","publicClient":true,
  "standardFlowEnabled":false,"directAccessGrantsEnabled":true,"redirectUris":[]}' >/dev/null

say "claim groups também nos clients que nasceram no Lab 5"
# O "default-default-client-scopes" lá de cima só vale para client criado DEPOIS dele. O
# grafana e o toolbox-cli nascem no Lab 5, antes de o scope existir: sem esta ligação
# explícita, o token deles não traz a claim groups, a Ana continua Viewer no Grafana e o
# teste do token mais abaixo falha.
for c in grafana toolbox-cli app-acme; do
  CID=$(kc_client_id "$c")
  if [ -z "$CID" ]; then ko "o client $c não existe; rode o Lab 5 antes"; continue; fi
  if kc_get "/clients/$CID/default-client-scopes" | jq -e '.[] | select(.name=="groups")' >/dev/null; then
    echo "client $c já recebe a claim groups"
  else
    kc_put "/clients/$CID/default-client-scopes/$GS_ID" '' >/dev/null && echo "claim groups ligada no client $c"
  fi
done
GID_GRAFANA=$(kc_client_id grafana)
if [ -n "$GID_GRAFANA" ] && kc_get "/clients/$GID_GRAFANA/default-client-scopes" | jq -e '.[] | select(.name=="groups")' >/dev/null; then
  ok "o client grafana recebe a claim groups (é ela que decide o papel no Grafana)"
else
  ko "o client grafana não recebe a claim groups: a Ana entraria como Viewer"
fi

say "discovery OIDC do realm acme (o que Grafana e oauth2-proxy consomem)"
if curl -fsS "$KC/realms/$REALM/.well-known/openid-configuration" -o "$OUT/discovery.json" 2>/dev/null; then
  jq '{issuer, authorization_endpoint, token_endpoint, userinfo_endpoint, end_session_endpoint, jwks_uri}' "$OUT/discovery.json"
  ok "documento de descoberta do realm $REALM publicado"
else
  ko "o realm $REALM não publicou o documento de descoberta; rode o Lab 5 antes"
fi

say "eventos de login e logout do realm (é deles que a conferência do fim do lab lê)"
# O Keycloak vem com o registro de eventos de usuário desligado (seção 4.8 da apostila). Sem ele,
# nada sobra no servidor do que o aluno fez no navegador: o logout do passo 9 encerra a sessão, e
# a conferência não teria como saber que houve SSO. Com ele, cada login (por aplicação) e cada
# logout viram uma linha em Realm settings > Events.
CFG=$(kc_get "/events/config")
kc_put "/events/config" "$(jq -c '.eventsEnabled = true
  | .enabledEventTypes = (((.enabledEventTypes // []) + ["LOGIN", "LOGIN_ERROR", "LOGOUT", "CODE_TO_TOKEN"]) | unique)' <<< "$CFG")" >/dev/null
if kc_get "/events/config" | jq -e '.eventsEnabled == true and (.enabledEventTypes | index("LOGIN")) != null and (.enabledEventTypes | index("LOGOUT")) != null' >/dev/null; then
  ok "eventos LOGIN e LOGOUT do realm $REALM sendo registrados (Realm settings > Events)"
else
  ko "o Keycloak não ligou o registro de eventos do realm $REALM"
fi

say "a Ana ainda tem o segundo fator do Lab 5?"
# O teste de token abaixo é um password grant, que não foi feito para segundo fator. Com o OTP
# do Lab 5 ainda cadastrado, o Keycloak recusa o token, e a falha pareceria ser deste lab.
ID_ANA=$(kc_get "/users?username=ana.souza&exact=true" | jq -r '.[0].id // empty')
if [ -n "$ID_ANA" ] && kc_get "/users/$ID_ANA/credentials" | jq -e '.[] | select(.type=="otp")' >/dev/null; then
  ko "a ana.souza ainda tem o OTP do Lab 5. Rode a conferência do Lab 5 (passo 19), que o apaga, ou apague a linha Otp em Users > ana.souza > Credentials, e rode este script de novo"
else
  echo "não: o terminal pode pedir token só com a senha"
fi

say "teste: token de ana.souza via toolbox-cli deve trazer groups=[ti] e preferred_username"
RESP=$(kc_user_token ana.souza 'Senha@123' toolbox-cli 2>/dev/null) || RESP=""
AT=$(printf '%s' "$RESP" | jq -r '.access_token // empty' 2>/dev/null || true)
if [ -z "$AT" ]; then
  ko "Keycloak não emitiu token para ana.souza no client toolbox-cli"
else
  jwt-decode -p "$AT" | jq '{iss, aud, azp, preferred_username, email, groups}'
  if jwt-decode -p "$AT" | jq -e '.groups | index("ti")' >/dev/null; then ok "claim groups contém ti"; else ko "claim groups sem ti"; fi
  if [ "$(jwt-decode -p "$AT" | jq -r .iss)" = "$KC/realms/$REALM" ]; then ok "issuer = $KC/realms/$REALM"; else ko "issuer inesperado"; fi
fi

say "teste: Grafana e app.localhost devem mandar o login para o Keycloak"
# "O Grafana responde 200" não prova SSO nenhum: a tela de login local devolve 200 mesmo com o
# OIDC desligado, e o teste passava sempre. O que prova é o botão do Keycloak levar para o
# Keycloak, com PKCE, que é exatamente o que se cobra do oauth2-proxy logo abaixo.
gloc=$(curl -s -o /dev/null -w '%{redirect_url}' "$(u grafana /login/generic_oauth)" || true)
if echo "$gloc" | grep -q "keycloak.localhost:$PORTA/realms/acme/protocol/openid-connect/auth"; then
  ok "Grafana manda o login para o Keycloak (authorization code)"
else ko "Grafana não redirecionou para o Keycloak: '$gloc'"; fi
if echo "$gloc" | grep -q "code_challenge_method=S256"; then ok "PKCE (S256) no redirect do Grafana"; else ko "Grafana sem PKCE no redirect"; fi

if kc_get "/clients/$APP_CID/protocol-mappers/models" | jq -e '.[] | select(.protocolMapper=="oidc-audience-mapper")' >/dev/null; then
  ok "app-acme tem audience mapper (o callback do oauth2-proxy exige aud=app-acme)"
else ko "app-acme SEM audience mapper: o oauth2-proxy devolverá 500 no /oauth2/callback"; fi
loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$(u app /)" || true)
if echo "$loc" | grep -q "keycloak.localhost:$PORTA/realms/acme/protocol/openid-connect/auth"; then ok "app.localhost:$PORTA redireciona para o Keycloak (authorization code)"
else ko "app.localhost:$PORTA não redirecionou para o Keycloak: '$loc'"; fi
if echo "$loc" | grep -q "code_challenge_method=S256"; then ok "PKCE (S256) presente no redirect do oauth2-proxy"; else ko "sem PKCE no redirect"; fi

say "teste: userinfo com o token de ana"
if [ -n "$AT" ] && curl -fsS -H "Authorization: Bearer $AT" "$KC/realms/$REALM/protocol/openid-connect/userinfo" -o "$OUT/userinfo.json" 2>/dev/null; then
  jq . "$OUT/userinfo.json"
  ok "userinfo respondeu para o token de ana"
else
  ko "userinfo não respondeu para o token de ana"
fi

# A montagem não grava a evidência do lab (mudança de 15/10/2026): guarda o que verificou para a
# conferência do fim do roteiro, que soma isto ao que o aluno fez no navegador. Se algo falhou,
# grava, como antes, para o painel mostrar onde parou.
if [ "$FAILS" -eq 0 ]; then
  montagem_pronta 6
  echo
  echo "LAB6 PRONTO: o cenário está montado. Siga o roteiro a partir do passo 1."
  echo "A evidência do Lab 6 sai da conferência, no fim do roteiro:"
  echo "  docker compose exec -T toolbox bash /work/scripts/lab6-conferir.sh"
else carimbar 6 "Lab 6: montagem" "$FAILS verificação(ões) falharam" falha; echo "LAB6 FALHOU ($FAILS)"; exit 1; fi
