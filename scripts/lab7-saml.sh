#!/usr/bin/env bash
# Lab 7 · Federação: Keycloak (realm acme) como SP/broker de um IdP SAML externo (SimpleSAMLphp = "parceiro")
# + desafio: brokering OIDC com um 2º realm ("universidade") no mesmo Keycloak.
# Pré-requisitos: lab5-federacao.sh e lab6-sso.sh; serviço 'idp' no ar (--profile lab7).
# Caminho OPCIONAL: não grava evidência (desde 15/10/2026). A entrega do Lab 7 é a do caminho
# padrão, gravada pela conferência do fim do roteiro (lab7-conferir.sh). Antes, este script
# gravava no mesmo arquivo e podia trocar uma evidência boa por uma falha.
set -euo pipefail
source /work/scripts/lib.sh
LAB_NUM=""   # nem quando para no meio
IDP_URL=$(u idp)
IDP_META="$IDP_URL/simplesaml/saml2/idp/metadata.php"

say "metadados do IdP externo (SimpleSAMLphp)"
for i in $(seq 1 20); do curl -fsS -m 5 "$IDP_META" -o "$OUT/idp-metadata.xml" 2>/dev/null && break; sleep 3; done
[ -s "$OUT/idp-metadata.xml" ] || { ko "não obtive $IDP_META"; exit 1; }
IDP_ENTITY=$(python3 - "$OUT/idp-metadata.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
t=ET.parse(sys.argv[1]).getroot(); print(t.attrib.get('entityID'))
EOF
)
IDP_CERT=$(python3 - "$OUT/idp-metadata.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns={'ds':'http://www.w3.org/2000/09/xmldsig#'}
c=ET.parse(sys.argv[1]).getroot().find('.//ds:X509Certificate',ns); print(''.join(c.text.split()))
EOF
)
SSO=$(python3 - "$OUT/idp-metadata.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns={'md':'urn:oasis:names:tc:SAML:2.0:metadata'}
r=ET.parse(sys.argv[1]).getroot()
for e in r.findall('.//md:SingleSignOnService',ns):
    if e.attrib['Binding'].endswith('HTTP-POST') or e.attrib['Binding'].endswith('HTTP-Redirect'): print(e.attrib['Location']); break
EOF
)
SLO=$(python3 - "$OUT/idp-metadata.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
ns={'md':'urn:oasis:names:tc:SAML:2.0:metadata'}
r=ET.parse(sys.argv[1]).getroot(); e=r.find('.//md:SingleLogoutService',ns); print(e.attrib['Location'] if e is not None else '')
EOF
)
echo "entityID=$IDP_ENTITY"; echo "SSO=$SSO"; echo "SLO=$SLO"; echo "cert=${IDP_CERT:0:40}..."
[ -n "$IDP_CERT" ] && ok "certificado de assinatura extraído dos metadados" || ko "sem certificado nos metadados"

say "user profile do realm: firstName/lastName opcionais (o IdP externo não envia nome; evita a tela 'review profile' no 1º login)"
kc_get "/users/profile" | jq '(.attributes[] | select(.name=="firstName" or .name=="lastName")) |= del(.required)' > "$OUT/profile.json"
kc_put "/users/profile" "$(cat "$OUT/profile.json")" >/dev/null && echo "perfil atualizado"

say "identity provider 'parceiro-saml' no realm acme"
if kc_get "/identity-provider/instances/parceiro-saml" >/dev/null 2>&1; then echo "já existe"; else
kc_post "/identity-provider/instances" "$(jq -n --arg cert "$IDP_CERT" --arg sso "$SSO" --arg slo "$SLO" --arg ent "$IDP_ENTITY" --arg kc "$KC" '{
  alias:"parceiro-saml", displayName:"Parceiro (SAML)", providerId:"saml", enabled:true, trustEmail:true,
  firstBrokerLoginFlowAlias:"first broker login", hideOnLogin:false,
  config:{
    entityId:($kc+"/realms/acme"),
    idpEntityId:$ent, singleSignOnServiceUrl:$sso, singleLogoutServiceUrl:$slo,
    nameIDPolicyFormat:"urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified",
    principalType:"ATTRIBUTE", principalAttribute:"uid",
    postBindingResponse:"true", postBindingAuthnRequest:"true", postBindingLogout:"true",
    wantAuthnRequestsSigned:"false", wantAssertionsSigned:"false", validateSignature:"true", signingCertificate:$cert,
    syncMode:"IMPORT", backchannelSupported:"false"}}')" >/dev/null
echo "criado"
fi
say "mappers de atributos SAML -> usuário"
for m in email; do
  if ! kc_get "/identity-provider/instances/parceiro-saml/mappers" | jq -e ".[] | select(.name==\"$m\")" >/dev/null; then
    kc_post "/identity-provider/instances/parceiro-saml/mappers" "{\"name\":\"$m\",\"identityProviderAlias\":\"parceiro-saml\",\"identityProviderMapper\":\"saml-user-attribute-idp-mapper\",\"config\":{\"attribute.name\":\"$m\",\"attribute.friendly.name\":\"$m\",\"user.attribute\":\"$m\",\"syncMode\":\"INHERIT\"}}" >/dev/null
    echo "mapper $m criado"; fi
done
if ! kc_get "/identity-provider/instances/parceiro-saml/mappers" | jq -e '.[] | select(.name=="grupo-parceiros")' >/dev/null; then
  # todo usuário federado do parceiro entra no grupo /parceiros (criado se não existir)
  [ -z "$(group_id parceiros)" ] && kc_post "/groups" '{"name":"parceiros"}' >/dev/null
  kc_post "/identity-provider/instances/parceiro-saml/mappers" '{"name":"grupo-parceiros","identityProviderAlias":"parceiro-saml","identityProviderMapper":"saml-advanced-group-idp-mapper","config":{"group":"/parceiros","attributes":"[]","are.attribute.values.regex":"false","syncMode":"INHERIT"}}' >/dev/null
  echo "mapper grupo-parceiros criado"
fi

say "metadados SP do Keycloak (para o parceiro cadastrar)"
curl -fsS "$KC/realms/$REALM/broker/parceiro-saml/endpoint/descriptor" -o "$OUT/keycloak-sp-metadata.xml" && ok "SP metadata em $OUT/keycloak-sp-metadata.xml" || ko "sem SP metadata"
grep -o 'entityID="[^"]*"' "$OUT/keycloak-sp-metadata.xml" | head -1

say "teste: kc_idp_hint=parceiro-saml deve gerar AuthnRequest (POST binding) para o IdP externo"
# O client 'grafana' exige PKCE (o lab6 configura pkce.code.challenge.method=S256). Sem
# mandar code_challenge, o Keycloak recusa a requisição inteira com "Missing parameter:
# code_challenge_method" e devolve um redirect de erro: nenhuma tela de login chega a ser
# montada, nenhum AuthnRequest é gerado, e os três testes abaixo falham sem que exista
# defeito nenhum na federação. Geramos um par PKCE de verdade, como um client faria.
# Tira as tags e devolve o título da página mais qualquer trecho que cheire a erro. Imprimir
# os primeiros 400 caracteres não servia: o começo da página do Keycloak é script e tema, e a
# explicação fica lá no meio.
texto_kc() {
  local t m
  t=$(sed -e 's/<script[^>]*>/ /g' -e 's/<[^>]*>/ /g' "$1" 2>/dev/null | tr -s ' \n\t' ' ')
  printf 'título: %s\n' "$(printf '%s' "$t" | cut -c1-70)"
  m=$(printf '%s' "$t" | grep -o -i -E '[^ ]{0,40}(error|erro|invalid|inválid|expired|expirou|unexpected|not found)[^.]{0,90}' | head -3 || true)
  if [ -n "$m" ]; then printf '%s\n' "$m" | sed 's/^/mensagem: /'
  else printf 'mensagem: nenhum trecho de erro na página; ela é a tela de login normal (veja %s)\n' "$1"; fi
}

# Cabeçalhos de navegador: o Keycloak troca de comportamento conforme o Accept, e sem isso
# algumas etapas do fluxo respondem JSON em vez da página que o fluxo espera.
NAV=(-H 'Accept: text/html,application/xhtml+xml' -H 'User-Agent: Mozilla/5.0 (X11; Linux x86_64) GIA-lab/1.0')

# Percorre o fluxo de autorização carregando os cookies À MÃO.
#
# Por que à mão, e não com o pote de cookies do curl: o Keycloak marca os cookies de sessão
# como Secure, e o curl, corretamente, se recusa a mandar cookie Secure por http. O laboratório
# roda em http. Resultado: o segundo salto do fluxo chegava sem sessão e o Keycloak respondia
# "the session has expired; it may have been deleted or cookies are disabled in your browser",
# que foi exatamente a mensagem que apareceu quando este teste passou a imprimir a página.
# O navegador não tem esse problema porque trata localhost como origem segura; o curl não faz
# essa exceção. Reenviar o cabeçalho Cookie explicitamente é o que um navegador faria.
fluxo() { # url html hdr  -> deixa o corpo em $html e os cabeçalhos do 2º salto em $hdr
  local url="$1" html="$2" hdr="$3" h1 dest
  h1=$(mktemp)
  curl -s -o /dev/null -D "$h1" "${NAV[@]}" "$url"
  BISCOITOS=$(grep -i '^set-cookie:' "$h1" | sed 's/^[Ss]et-[Cc]ookie: *//' | cut -d';' -f1 | paste -sd'; ' -)
  dest=$(grep -i '^location:' "$h1" | tail -1 | sed 's/^[Ll]ocation: *//' | tr -d '\r')
  PRIMEIRO_SALTO="$dest"
  rm -f "$h1"
  if [ -z "$dest" ]; then
    curl -s "${NAV[@]}" "$url" -o "$html" -D "$hdr"     # não houve redirect: a resposta é a página
  else
    curl -sL "${NAV[@]}" -H "Cookie: $BISCOITOS" "$dest" -o "$html" -D "$hdr"
  fi
}

PKCE_VERIF=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')
PKCE_CHAL=$(printf '%s' "$PKCE_VERIF" | openssl dgst -binary -sha256 | base64 | tr '+/' '-_' | tr -d '=')
AUTH="$KC/realms/$REALM/protocol/openid-connect/auth?client_id=grafana&redirect_uri=http%3A%2F%2Fgrafana.localhost%3A$PORTA%2Flogin%2Fgeneric_oauth&response_type=code&scope=openid&state=teste&code_challenge=$PKCE_CHAL&code_challenge_method=S256&kc_idp_hint=parceiro-saml"
# Guardamos o CORPO e a CADEIA de redirects. O Keycloak não vai direto para o IdP: ele passa
# pelo próprio endpoint de broker (/realms/acme/broker/parceiro-saml/login) e só depois emite o
# AuthnRequest. E o AuthnRequest pode sair de dois jeitos: dentro de um formulário que se
# autoenvia (binding POST) ou como parâmetro na URL (binding Redirect). Olhar só o corpo, como
# antes, dava falha nos casos em que a federação estava funcionando pelo outro binding.
fluxo "$AUTH" "$OUT/authn.html" "$OUT/authn-hdr.txt"
CADEIA=$(printf 'Location: %s\n%s\n' "$PRIMEIRO_SALTO" "$(grep -i '^location:' "$OUT/authn-hdr.txt" | tr -d '\r')")
if { grep -q 'SAMLRequest' "$OUT/authn.html" || printf '%s' "$CADEIA" | grep -q 'SAMLRequest'; } \
   && { grep -q "idp.localhost:$PORTA/simplesaml" "$OUT/authn.html" || printf '%s' "$CADEIA" | grep -q "idp.localhost:$PORTA/simplesaml"; }; then
  BIND=POST; grep -q 'SAMLRequest' "$OUT/authn.html" || BIND=Redirect
  ok "Keycloak montou o AuthnRequest para o IdP externo (binding $BIND)"
  ev_item ok "AuthnRequest SAML" "binding $BIND, destino $SSO"
  SR=$(grep -o 'name="SAMLRequest" value="[^"]*"' "$OUT/authn.html" | sed 's/.*value="//;s/"$//' | python3 -c 'import sys,html;print(html.unescape(sys.stdin.read().strip()))')
  echo "$SR" | base64 -d 2>/dev/null | python3 -c 'import sys,zlib
d=sys.stdin.buffer.read()
try: x=zlib.decompress(d,-15).decode()
except Exception: x=d.decode(errors="ignore")
import re; print(re.sub(r"\s+"," ",x)[:600])'
else
  ko "não encontrei SAMLRequest nem idp.localhost na resposta (veja $OUT/authn.html)"
  echo "   cadeia de redirects que o Keycloak seguiu:"
  printf '%s\n' "${CADEIA:-   (nenhum redirect)}" | cut -c1-160 | sed 's/^/     /'
  # A cadeia sozinha não basta: quando ela para no endpoint de broker do próprio Keycloak, a
  # explicação está no TEXTO da página que ele devolveu, e não nos cabeçalhos.
  printf '   cookies que o Keycloak mandou no 1º salto: %s\n' "$(printf '%s' "${BISCOITOS:-nenhum}" | sed 's/=[^;]*/=.../g')"
  echo "   o que o Keycloak devolveu:"
  texto_kc "$OUT/authn.html" | sed 's/^/     /'
fi

say "teste: a página de login do realm acme oferece o IdP externo"
curl -sL "${NAV[@]}" "${AUTH/&kc_idp_hint=parceiro-saml/}" -o "$OUT/login.html"
grep -q 'parceiro-saml' "$OUT/login.html" && ok "botão 'Parceiro (SAML)' presente no login" || ko "botão do IdP não aparece no login"

# ---------------- Desafio: brokering OIDC com 2º realm ----------------
say "DESAFIO: realm 'universidade' (IdP OIDC) e brokering em acme"
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
# Mesma armadilha do teste SAML: o primeiro redirect é para o endpoint de broker do PRÓPRIO
# Keycloak (/realms/acme/broker/universidade/login), não para o IdP externo. Quem olha só o
# primeiro salto conclui que a federação está quebrada quando ela está certa. Seguimos a
# cadeia inteira e procuramos nela o destino e o PKCE.
fluxo "${AUTH/parceiro-saml/universidade}" "$OUT/broker.html" "$OUT/broker-hdr.txt"
CADEIA_U=$(printf 'Location: %s\n%s\n' "$PRIMEIRO_SALTO" "$(grep -i '^location:' "$OUT/broker-hdr.txt" | tr -d '\r')")
if printf '%s' "$CADEIA_U" | grep -q 'realms/universidade/protocol/openid-connect/auth'; then
  ok "kc_idp_hint=universidade chega no IdP OIDC (via endpoint de broker do Keycloak)"
else
  ko "a cadeia de redirects não chegou no realm universidade"
  printf '%s\n' "${CADEIA_U:-   (nenhum redirect)}" | cut -c1-160 | sed 's/^/     /'
  printf '   cookies que o Keycloak mandou no 1º salto: %s\n' "$(printf '%s' "${BISCOITOS:-nenhum}" | sed 's/=[^;]*/=.../g')"
  echo "   o que o Keycloak devolveu:"
  texto_kc "$OUT/broker.html" | sed 's/^/     /'
fi
if printf '%s' "$CADEIA_U" | grep -q 'code_challenge_method=S256'; then ok "broker OIDC usa PKCE"; else ko "broker OIDC sem PKCE na cadeia"; fi

EV_GRAVADA=1
if [ "$FAILS" -eq 0 ]; then echo "SIMPLESAMLPHP OK (caminho opcional; a evidência do Lab 7 continua sendo a da conferência)"
else echo "SIMPLESAMLPHP FALHOU ($FAILS) (caminho opcional; a evidência do Lab 7 não muda)"; exit 1; fi
