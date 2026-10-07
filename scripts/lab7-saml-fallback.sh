#!/usr/bin/env bash
# Lab 7, caminho alternativo (fallback multi-arch): o "parceiro" SAML implementado no PRÓPRIO Keycloak.
#
# Por quê: a imagem kristophjunge/test-saml-idp:1.15 é de 2018 e só existe para linux/amd64
# (manifest único, sem lista de plataformas). Em Mac com Apple Silicon ela só roda sob emulação
# (Rosetta/QEMU) : quando roda. Este script entrega o MESMO exercício de federação SAML usando
# um segundo realm do Keycloak como IdP externo, e o Keycloak é multi-arch (amd64 + arm64).
#
# O que faz:
#   1. cria o realm "parceiro" com o usuário parceiro.user / Senha@123;
#   2. cria nesse realm um client SAML cujo clientId é o entityID do SP (o realm acme),
#      com o ACS apontando para o endpoint do broker $KC_BASE/realms/acme/broker/parceiro-kc/endpoint;
#   3. cadastra em "acme" um segundo identity provider SAML chamado "parceiro-kc", importando
#      os metadados de $KC_BASE/realms/parceiro/protocol/saml/descriptor;
#   4. cria o realm "universidade" (usuária maria.prof / Senha@123) e o cadastra em "acme" como
#      identity provider OIDC: o brokering OIDC dos passos 10 e 11 do roteiro, que não depende
#      do SimpleSAMLphp. É o mesmo bloco do lab7-saml.sh.
#
# Idempotente: pode rodar quantas vezes quiser.
# Pré-requisitos: lab5-federacao.sh e lab6-sso.sh (realm acme + client grafana).
set -euo pipefail
source /work/scripts/lib.sh
# O lib.sh já sabe a porta publicada; nada aqui pode ter URL com porta fixa, senão
# o issuer e os redirect_uri do Keycloak deixam de bater.
KC_BASE=$(u keycloak)
GRAFANA=$(u grafana)

P_REALM=parceiro
ALIAS=parceiro-kc
SP_ENTITY="$KC/realms/$REALM"                       # quem o broker do acme diz ser (Issuer do AuthnRequest)
ACS="$KC/realms/$REALM/broker/$ALIAS/endpoint"      # para onde a SAMLResponse volta
P_DESCRIPTOR="$KC/realms/$P_REALM/protocol/saml/descriptor"

say "realm '$P_REALM' (fará o papel de IdP SAML do parceiro)"
if curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$KC/admin/realms/$P_REALM" | grep -q 404; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms" \
    -d "{\"realm\":\"$P_REALM\",\"enabled\":true,\"displayName\":\"Parceiro (Keycloak como IdP SAML)\"}" >/dev/null
  echo "realm $P_REALM criado"
else echo "realm $P_REALM já existe"; fi

say "usuário parceiro.user no realm $P_REALM"
if ! curl -fsS "${auth[@]}" "$KC/admin/realms/$P_REALM/users?username=parceiro.user&exact=true" | jq -e '.[0]' >/dev/null; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$P_REALM/users" -d '{
    "username":"parceiro.user","enabled":true,"emailVerified":true,
    "email":"parceiro.user@parceiro.example.com","firstName":"Parceiro","lastName":"Usuario",
    "credentials":[{"type":"password","value":"Senha@123","temporary":false}]}' >/dev/null
  echo "usuário parceiro.user criado (senha Senha@123)"
else echo "usuário parceiro.user já existe"; fi

say "client SAML no realm $P_REALM (o SP é o realm acme)"
P_CID=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$P_REALM/clients?clientId=$(printf '%s' "$SP_ENTITY" | jq -sRr @uri)" | jq -r '.[0].id // empty')
CLIENT_JSON=$(jq -n --arg cid "$SP_ENTITY" --arg acs "$ACS" '{
  clientId:$cid, name:"SP: realm acme", protocol:"saml", enabled:true,
  redirectUris:[($acs + "*")], baseUrl:$acs,
  frontchannelLogout:true,
  attributes:{
    "saml.assertion.signature":"true",         # assina a Assertion
    "saml.server.signature":"true",            # assina também a Response
    "saml.signature.algorithm":"RSA_SHA256",   # SHA-256 (o JDK do Keycloak recusa SHA-1)
    "saml.client.signature":"false",           # não exige AuthnRequest assinado
    "saml.force.post.binding":"true",
    "saml.authnstatement":"true",
    "saml_name_id_format":"username",          # NameID = username -> o broker usa principalType=SUBJECT
    "saml_force_name_id_format":"true",        # IGNORA o NameIDPolicy pedido pelo SP (ver comentário abaixo)
    "saml_assertion_consumer_url_post":$acs,
    "saml_single_logout_service_url_post":$acs
  }}')
if [ -z "$P_CID" ]; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$P_REALM/clients" -d "$CLIENT_JSON" >/dev/null
  P_CID=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$P_REALM/clients?clientId=$(printf '%s' "$SP_ENTITY" | jq -sRr @uri)" | jq -r '.[0].id')
  echo "client SAML criado ($P_CID) clientId=$SP_ENTITY"
else
  curl -fsS -X PUT "${auth[@]}" "$KC/admin/realms/$P_REALM/clients/$P_CID" -d "$(echo "$CLIENT_JSON" | jq --arg id "$P_CID" '. + {id:$id}')" >/dev/null
  echo "client SAML já existia ($P_CID); configuração reaplicada"
fi

say "mappers do client: manda email/nome como atributos SAML"
add_mapper() { # nome property attributeName
  if ! curl -fsS "${auth[@]}" "$KC/admin/realms/$P_REALM/clients/$P_CID/protocol-mappers/models" | jq -e ".[] | select(.name==\"$1\")" >/dev/null; then
    curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$P_REALM/clients/$P_CID/protocol-mappers/models" -d "$(jq -n --arg n "$1" --arg p "$2" --arg a "$3" '{
      name:$n, protocol:"saml", protocolMapper:"saml-user-property-mapper",
      config:{"user.attribute":$p,"attribute.name":$a,"friendly.name":$a,
              "attribute.nameformat":"Basic"}}')" >/dev/null
    echo "  mapper $1 criado"
  else echo "  mapper $1 já existe"; fi
}
add_mapper email     email     email
add_mapper firstName firstName firstName
add_mapper lastName  lastName  lastName

say "metadados SAML do realm $P_REALM (o que o acme vai importar)"
curl -fsS "$P_DESCRIPTOR" -o "$OUT/parceiro-kc-metadata.xml"
python3 - "$OUT/parceiro-kc-metadata.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns={'md':'urn:oasis:names:tc:SAML:2.0:metadata'}
r=ET.parse(sys.argv[1]).getroot()
print("  entityID:", r.attrib.get('entityID'))
for e in r.findall('.//md:SingleSignOnService',ns): print("  SSO:", e.attrib['Binding'].split(':')[-1], e.attrib['Location'])
EOF
ok "descriptor em $OUT/parceiro-kc-metadata.xml"

say "identity provider '$ALIAS' no realm $REALM (importando os metadados pela URL)"
# import-config: o Keycloak baixa e traduz os metadados sozinho : é o que a tela "Import from URL" faz.
IMPORTED=$(kc_post "/identity-provider/import-config" "{\"fromUrl\":\"$P_DESCRIPTOR\",\"providerId\":\"saml\"}")
echo "  config importada: $(echo "$IMPORTED" | jq -c '{singleSignOnServiceUrl, idpEntityId, validateSignature}')"
IDP_JSON=$(echo "$IMPORTED" | jq --arg ent "$SP_ENTITY" --arg alias "$ALIAS" '{
  alias:$alias, displayName:"Parceiro (SAML via Keycloak)", providerId:"saml", enabled:true, trustEmail:true,
  firstBrokerLoginFlowAlias:"first broker login", hideOnLogin:false,
  config:(. + {entityId:$ent, principalType:"SUBJECT",
               # O import-config traz nameIDPolicyFormat=persistent. Com isso o realm parceiro
               # devolve NameID="G-<uuid>" e o usuário nasceria em acme como "g-<uuid>" em vez
               # de "parceiro.user". Pedimos "unspecified" e, no client, forçamos o formato
               # username (saml_force_name_id_format=true) : cinto e suspensório.
               nameIDPolicyFormat:"urn:oasis:names:tc:SAML:2.0:nameid-format:unspecified",
               postBindingResponse:"true",
               postBindingAuthnRequest:"true", wantAuthnRequestsSigned:"false",
               validateSignature:"true", syncMode:"IMPORT", backchannelSupported:"false"})}')
if kc_get "/identity-provider/instances/$ALIAS" >/dev/null 2>&1; then
  kc_put "/identity-provider/instances/$ALIAS" "$IDP_JSON" >/dev/null; echo "  IdP $ALIAS atualizado"
else
  kc_post "/identity-provider/instances" "$IDP_JSON" >/dev/null; echo "  IdP $ALIAS criado"
fi

say "mappers do IdP: email/firstName/lastName e grupo /parceiros"
# Diferente do SimpleSAMLphp (que não manda nome nenhum), este IdP manda os três atributos :
# então o usuário federado nasce COMPLETO em acme e a tela "Update Account Information" nem aparece.
for m in email firstName lastName; do
  if ! kc_get "/identity-provider/instances/$ALIAS/mappers" | jq -e ".[] | select(.name==\"$m\")" >/dev/null; then
    kc_post "/identity-provider/instances/$ALIAS/mappers" "{\"name\":\"$m\",\"identityProviderAlias\":\"$ALIAS\",\"identityProviderMapper\":\"saml-user-attribute-idp-mapper\",\"config\":{\"attribute.name\":\"$m\",\"attribute.friendly.name\":\"$m\",\"user.attribute\":\"$m\",\"syncMode\":\"INHERIT\"}}" >/dev/null
    echo "  mapper $m criado"
  fi
done
if ! kc_get "/identity-provider/instances/$ALIAS/mappers" | jq -e '.[] | select(.name=="grupo-parceiros")' >/dev/null; then
  [ -z "$(group_id parceiros)" ] && kc_post "/groups" '{"name":"parceiros"}' >/dev/null
  kc_post "/identity-provider/instances/$ALIAS/mappers" "{\"name\":\"grupo-parceiros\",\"identityProviderAlias\":\"$ALIAS\",\"identityProviderMapper\":\"saml-advanced-group-idp-mapper\",\"config\":{\"group\":\"/parceiros\",\"attributes\":\"[]\",\"are.attribute.values.regex\":\"false\",\"syncMode\":\"INHERIT\"}}" >/dev/null
  echo "  mapper grupo-parceiros criado"
fi

# ----------------------------------------------------------------- brokering OIDC
say "realm 'universidade' (IdP OIDC) e brokering em $REALM"
if curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$KC/admin/realms/universidade" | grep -q 404; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms" -d '{"realm":"universidade","enabled":true,"displayName":"Universidade Parceira"}' >/dev/null; echo "realm universidade criado"; fi
U_AUTH=("${auth[@]}")
if ! curl -fsS "${U_AUTH[@]}" "$KC/admin/realms/universidade/users?username=maria.prof&exact=true" | jq -e '.[0]' >/dev/null; then
  curl -fsS -X POST "${U_AUTH[@]}" "$KC/admin/realms/universidade/users" -d '{"username":"maria.prof","enabled":true,"email":"maria.prof@universidade.edu.br","emailVerified":true,"firstName":"Maria","lastName":"Professora","credentials":[{"type":"password","value":"Senha@123","temporary":false}]}' >/dev/null
  echo "usuária maria.prof criada"; fi
if ! curl -fsS "${U_AUTH[@]}" "$KC/admin/realms/universidade/clients?clientId=acme-broker" | jq -e '.[0]' >/dev/null; then
  curl -fsS -X POST "${U_AUTH[@]}" "$KC/admin/realms/universidade/clients" -d '{"clientId":"acme-broker","protocol":"openid-connect","publicClient":false,"secret":"acme-broker-secret","standardFlowEnabled":true,"redirectUris":["http://keycloak.localhost'"$SUF"'/realms/acme/broker/universidade/endpoint"]}' >/dev/null
  echo "client acme-broker criado no realm universidade"; fi
if ! kc_get "/identity-provider/instances/universidade" >/dev/null 2>&1; then
  kc_post "/identity-provider/instances" '{"alias":"universidade","displayName":"Universidade (OIDC)","providerId":"oidc","enabled":true,"trustEmail":true,"firstBrokerLoginFlowAlias":"first broker login",
    "config":{"clientId":"acme-broker","clientSecret":"acme-broker-secret","clientAuthMethod":"client_secret_post",
      "authorizationUrl":"http://keycloak.localhost'"$SUF"'/realms/universidade/protocol/openid-connect/auth",
      "tokenUrl":"http://keycloak.localhost'"$SUF"'/realms/universidade/protocol/openid-connect/token",
      "jwksUrl":"http://keycloak.localhost'"$SUF"'/realms/universidade/protocol/openid-connect/certs",
      "logoutUrl":"http://keycloak.localhost'"$SUF"'/realms/universidade/protocol/openid-connect/logout",
      "issuer":"http://keycloak.localhost'"$SUF"'/realms/universidade","useJwksUrl":"true","validateSignature":"true",
      "defaultScope":"openid profile email","pkceEnabled":"true","pkceMethod":"S256","syncMode":"IMPORT"}}' >/dev/null
  echo "IdP universidade criado em acme"; fi

# ----------------------------------------------------------------- testes
declare -A CK
ck_reset() { CK=(); }
ck_header() { local k out=""; for k in "${!CK[@]}"; do out+="$k=${CK[$k]}; "; done; printf '%s' "$out"; }
follow() { # ver lab4-federacao.sh: curl não guarda cookie "Secure" vindo por http://
  local url="$1" out="$2" hop=0 hdr loc line
  while [ "$hop" -lt 10 ]; do
    hdr=$(curl -sS -D - -o "$out" -H "Cookie: $(ck_header)" "$url" | tr -d '\r')
    while IFS= read -r line; do
      line=${line#*: }; line=${line%%;*}
      [ -n "$line" ] && CK["${line%%=*}"]="${line#*=}"
    done < <(printf '%s\n' "$hdr" | grep -i '^set-cookie:')
    loc=$(printf '%s\n' "$hdr" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: *//' || true)
    [ -z "$loc" ] && { printf '%s' "$url"; return 0; }
    case "$loc" in http*) url="$loc" ;; /*) url="$KC$loc" ;; *) url="$KC/$loc" ;; esac
    hop=$((hop+1))
  done
  printf '%s' "$url"
}

say "teste: botão '$ALIAS' na tela de login do realm $REALM"
CV=$(head -c 48 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
CC=$(printf '%s' "$CV" | openssl dgst -binary -sha256 | base64 | tr '+/' '-_' | tr -d '=')
AUTH_URL="$KC/realms/$REALM/protocol/openid-connect/auth?client_id=grafana&redirect_uri=http%3A%2F%2Fgrafana.localhost:18080%2Flogin%2Fgeneric_oauth&response_type=code&scope=openid&state=teste&code_challenge=$CC&code_challenge_method=S256"
ck_reset; follow "$AUTH_URL" "$OUT/login-4b.html" >/dev/null
grep -q "social-$ALIAS" "$OUT/login-4b.html" && ok "botão 'Parceiro (SAML via Keycloak)' presente" || ko "botão do IdP $ALIAS não aparece no login"

say "teste: kc_idp_hint=$ALIAS gera AuthnRequest para o realm $P_REALM"
ck_reset; follow "$AUTH_URL&kc_idp_hint=$ALIAS" "$OUT/authn-4b.html" >/dev/null
if grep -q 'SAMLRequest' "$OUT/authn-4b.html" && grep -q "realms/$P_REALM/protocol/saml" "$OUT/authn-4b.html"; then
  ok "Keycloak montou o AuthnRequest para o realm $P_REALM"
  grep -o 'name="SAMLRequest" value="[^"]*"' "$OUT/authn-4b.html" | sed 's/.*value="//;s/"$//' \
    | python3 -c 'import sys,html,base64,re
b=base64.b64decode(html.unescape(sys.stdin.read().strip()))
print(re.sub(r"\s+"," ",b.decode(errors="ignore"))[:400])'
else ko "não encontrei o AuthnRequest para $P_REALM (veja $OUT/authn-4b.html)"; fi

say "a SAMLResponse do parceiro, guardada para o passo 6 do roteiro"
# Faz pelo terminal o que o navegador faz no passo 5: entrega o AuthnRequest ao parceiro, entra
# como parceiro.user e guarda a SAMLResponse que o IdP devolve, decodificada, em
# $OUT/saml-response-parceiro-kc.xml. Não é verificação do laboratório: se algo aqui falhar,
# sai um aviso e o resto segue (o login de verdade é o do navegador).
posta() { # url dados saida: POST e depois segue os redirects por GET, como o navegador
  local url="$1" dados="$2" out="$3" hdr="" loc="" line=""
  hdr=$(curl -sS -D - -o "$out" -H "Cookie: $(ck_header)" --data "$dados" "$url" | tr -d '\r')
  while IFS= read -r line; do
    line=${line#*: }; line=${line%%;*}
    [ -n "$line" ] && CK["${line%%=*}"]="${line#*=}"
  done < <(printf '%s\n' "$hdr" | grep -i '^set-cookie:' || true)
  loc=$(printf '%s\n' "$hdr" | grep -i '^location:' | head -1 | sed 's/^[Ll]ocation: *//' || true)
  [ -z "$loc" ] && { printf '%s' "$url"; return 0; }
  case "$loc" in http*) ;; /*) loc="$KC$loc" ;; *) loc="$KC/$loc" ;; esac
  follow "$loc" "$out"
}
formulario() { # arquivo.html id-do-form(ou vazio) -> "acao<TAB>campos-urlencoded"
  python3 - "$1" "${2:-}" <<'PY'
import sys, re, html, urllib.parse
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
fid = sys.argv[2]
tags = re.findall(r"<form\b[^>]*>", t, re.I)
tag = next((x for x in tags if fid and ('id="%s"' % fid) in x), tags[0] if tags else "")
m = re.search(r'action="([^"]*)"', tag)
campos = {html.unescape(a): html.unescape(b) for a, b in re.findall(r'name="([^"]+)"\s+value="([^"]*)"', t)}
print((html.unescape(m.group(1)) if m else "") + "\t" + urllib.parse.urlencode(campos))
PY
}
captura_saml() {
  local linha="" acao="" campos="" xml="$OUT/saml-response-$ALIAS.xml"
  [ -s "$OUT/authn-4b.html" ] || return 1
  # 1. o formulário automático que leva o SAMLRequest ao parceiro (binding HTTP-POST)
  linha=$(formulario "$OUT/authn-4b.html" ""); acao=${linha%%$'\t'*}; campos=${linha#*$'\t'}
  [ -n "$acao" ] || return 1
  posta "$acao" "$campos" "$OUT/saml-login.html" >/dev/null || return 1
  # 2. a tela de login do parceiro
  linha=$(formulario "$OUT/saml-login.html" "kc-form-login"); acao=${linha%%$'\t'*}
  [ -n "$acao" ] || return 1
  posta "$acao" "username=parceiro.user&password=Senha%40123&credentialId=" "$OUT/saml-resposta.html" >/dev/null || return 1
  # 3. o formulário automático que leva a SAMLResponse de volta ao broker da ACME
  grep -q 'name="SAMLResponse"' "$OUT/saml-resposta.html" || return 1
  python3 - "$OUT/saml-resposta.html" "$xml" <<'PY' || return 1
import sys, re, html, base64
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
v = re.search(r'name="SAMLResponse"\s+value="([^"]+)"', t).group(1)
open(sys.argv[2], "wb").write(base64.b64decode(html.unescape(v)))
PY
  [ -s "$xml" ] || return 1
  echo "   guardada em $xml ($(wc -c < "$xml") bytes)"
  grep -o 'SignatureMethod Algorithm="[^"]*"' "$xml" | head -1 | sed 's/^/   /' || true
}
ck_reset; follow "$AUTH_URL&kc_idp_hint=$ALIAS" "$OUT/authn-4b.html" >/dev/null || true
captura_saml || echo "   aviso: não consegui guardar a SAMLResponse pelo terminal; o passo 5 do roteiro, no navegador, não depende disto"

say "teste: kc_idp_hint=universidade leva ao IdP OIDC, com PKCE"
# O primeiro salto é o endpoint de broker do próprio Keycloak (/realms/acme/broker/universidade/login);
# o follow segue a cadeia inteira e devolve o último endereço, que tem de ser o login da universidade.
ck_reset; DESTINO_U=$(follow "$AUTH_URL&kc_idp_hint=universidade" "$OUT/broker-u.html")
if printf '%s' "$DESTINO_U" | grep -q "realms/universidade/protocol/openid-connect/auth"; then
  ok "kc_idp_hint=universidade chega no IdP OIDC (via endpoint de broker do Keycloak)"
  if printf '%s' "$DESTINO_U" | grep -q "code_challenge_method=S256"; then ok "broker OIDC usa PKCE"; else ko "broker OIDC sem PKCE"; fi
else ko "a cadeia de redirects não chegou no realm universidade (parou em: ${DESTINO_U:0:160})"; fi

say "resumo: identity providers do realm $REALM"
kc_get "/identity-provider/instances" | jq -r '.[] | "  \(.alias)\t\(.providerId)\t\(.displayName)"'

echo
echo "Login pelo navegador: $GRAFANA/login -> 'Sign in with Keycloak ACME'"
echo "                      -> botão 'Parceiro (SAML via Keycloak)' -> parceiro.user / Senha@123"
echo "                      -> botão 'Universidade (OIDC)'          -> maria.prof / Senha@123"
if [ "$FAILS" -eq 0 ]; then
  carimbar 7 "Lab 7: federação SAML (caminho alternativo, IdP no Keycloak)" "realm parceiro como IdP SAML e realm universidade como IdP OIDC" ok
  echo "LAB7 OK (pelo caminho alternativo)"
else
  carimbar 7 "Lab 7: federação SAML (caminho alternativo, IdP no Keycloak)" "$FAILS verificação(ões) falharam" falha
  echo "LAB7 (alternativo) FALHOU ($FAILS)"; exit 1
fi
