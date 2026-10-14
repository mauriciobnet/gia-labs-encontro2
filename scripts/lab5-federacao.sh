#!/usr/bin/env bash
# Validação automática do Lab 5: cria realm "acme", federa o OpenLDAP no Keycloak,
# sincroniza usuários e testa login de um usuário do LDAP via token OIDC.
# A federação fala com o diretório por StartTLS e confere o certificado dele com a CA da
# ACME, a mesma que o Lab 4 emitiu (no Encontro 2, a preparação do encontro a recria).
# Também registra o Grafana como client OIDC: é por ele que a Ana cadastra o segundo fator.
# Roda DENTRO do toolbox:  docker compose exec toolbox bash /work/scripts/lab5-federacao.sh
set -euo pipefail
PORTA=${GIA_PORT:-18080}
KC=http://keycloak.localhost:$PORTA
REALM=acme
LDAP_URL="ldap://openldap:389"
CA=/work/pki/ca/acme-ca.crt
CONFIANCA=/work/pki/confianca

echo "== Keycloak no ar =="
# Logo depois de um 'docker compose restart keycloak' ele leva de 30 a 90 segundos para responder.
# A pergunta é o documento de descoberta, conferido pelo conteúdo: enquanto o Keycloak está fora,
# o Traefik manda keycloak.localhost para o painel, e um "responde alguma coisa" enganaria. Foi o
# que aconteceu no ensaio de 06/10: a espera passou na hora e o token veio do painel, com 501.
for i in $(seq 1 75); do
  curl -fsS "$KC/realms/master/.well-known/openid-configuration" 2>/dev/null | jq -e '.issuer' >/dev/null 2>&1 && break
  [ "$i" -eq 75 ] && { echo "ERRO: o Keycloak não respondeu em 2 minutos e meio (docker compose ps keycloak)"; exit 1; }
  sleep 2
done
echo "ok"

echo "== token de admin (master) =="
# A descoberta responde alguns segundos antes da API de administração: insiste um pouco.
ADMIN_TOKEN=""
for i in $(seq 1 15); do
  ADMIN_TOKEN=$(curl -fsS -X POST "$KC/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=admin -d password=admin 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null) || ADMIN_TOKEN=""
  [ -n "$ADMIN_TOKEN" ] && break
  sleep 2
done
[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: o Keycloak não emitiu o token de administrador (admin/admin no realm master)"; exit 1; }
auth=(-H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json")

echo "== realm $REALM =="
if curl -s -o /dev/null -w '%{http_code}' "${auth[@]}" "$KC/admin/realms/$REALM" | grep -q 404; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms" -d "{\"realm\":\"$REALM\",\"enabled\":true,\"displayName\":\"ACME Ensino\"}"
  echo "realm criado"
else echo "realm já existe"; fi
REALM_ID=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM" | jq -r .id)

echo "== a CA da ACME no truststore do Keycloak =="
# O Keycloak lê os certificados confiáveis da pasta pki/confianca (montada em
# /opt/keycloak/conf/truststores/acme) só quando sobe. A CA mora em pki/ca, junto com a chave
# privada dela; aqui vai só o certificado.
if [ ! -s "$CA" ]; then
  echo "ERRO: a CA da ACME (pki/ca/acme-ca.crt) não existe. Ela nasce na preparação do encontro."
  echo "       Rode antes, e depois reinicie o Keycloak e o Grafana:"
  echo "       docker compose exec -T toolbox bash /work/scripts/preparar-encontro2.sh"
  echo "       docker compose restart keycloak grafana"
  exit 1
fi
mkdir -p "$CONFIANCA"
if cmp -s "$CA" "$CONFIANCA/acme-ca.crt"; then
  echo "a CA já está em pki/confianca/acme-ca.crt"
else
  cp -f "$CA" "$CONFIANCA/acme-ca.crt"; chmod 644 "$CONFIANCA/acme-ca.crt"
  echo "CA copiada para pki/confianca/acme-ca.crt"
fi

echo "== teste: o Keycloak fala StartTLS com o diretório? =="
# É o mesmo teste do botão "Test authentication" do console: conecta, pede StartTLS, confere o
# certificado e faz o bind. Feito antes de gravar a federação, para o erro sair claro aqui.
TESTE_LDAP=$(jq -cn --arg url "$LDAP_URL" '{action:"testAuthentication", connectionUrl:$url,
  startTls:"true", useTruststoreSpi:"always", authType:"simple",
  bindDn:"cn=admin,dc=acme,dc=edu,dc=br", bindCredential:"admin", connectionTimeout:"10000"}')
RESP_TESTE="/tmp/gia-ldaptest-$$.json"
COD=$(curl -sS -o "$RESP_TESTE" -w '%{http_code}' -X POST "${auth[@]}" "$KC/admin/realms/$REALM/testLDAPConnection" -d "$TESTE_LDAP" || true)
if [ "$COD" = "204" ]; then
  echo "ok: StartTLS na porta 389, certificado do diretório conferido com a CA da ACME, bind aceito"
else
  echo "O Keycloak NÃO conseguiu falar StartTLS com o diretório (HTTP $COD: $(cat "$RESP_TESTE" 2>/dev/null))."
  echo
  echo "Causa mais comum: o Keycloak subiu antes de a CA estar em pki/confianca, e ele só lê os"
  echo "certificados confiáveis ao subir. No terminal do seu computador, na pasta do repositório:"
  echo "       docker compose restart keycloak grafana"
  echo "e rode este script de novo (ele espera o Keycloak voltar)."
  echo
  echo "Se você já reiniciou e o erro continua, o diretório pode estar sem TLS: rode a preparação de novo"
  echo "       docker compose exec -T toolbox bash /work/scripts/preparar-encontro2.sh"
  rm -f "$RESP_TESTE"
  exit 2
fi
rm -f "$RESP_TESTE"

echo "== user federation LDAP =="
existing=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" | jq -r '.[] | select(.name=="acme-ldap") | .id')
if [ -z "$existing" ]; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$REALM/components" -d @- <<EOF
{
  "name": "acme-ldap",
  "providerId": "ldap",
  "providerType": "org.keycloak.storage.UserStorageProvider",
  "parentId": "$REALM_ID",
  "config": {
    "enabled": ["true"],
    "vendor": ["other"],
    "connectionUrl": ["$LDAP_URL"],
    "startTls": ["true"],
    "useTruststoreSpi": ["always"],
    "connectionPooling": ["false"],
    "usersDn": ["ou=people,dc=acme,dc=edu,dc=br"],
    "bindDn": ["cn=admin,dc=acme,dc=edu,dc=br"],
    "bindCredential": ["admin"],
    "authType": ["simple"],
    "editMode": ["READ_ONLY"],
    "usernameLDAPAttribute": ["uid"],
    "rdnLDAPAttribute": ["uid"],
    "uuidLDAPAttribute": ["entryUUID"],
    "userObjectClasses": ["inetOrgPerson, organizationalPerson"],
    "searchScope": ["1"],
    "importEnabled": ["true"],
    "syncRegistrations": ["false"],
    "pagination": ["false"],
    "trustEmail": ["true"]
  }
}
EOF
  existing=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/components?type=org.keycloak.storage.UserStorageProvider" | jq -r '.[] | select(.name=="acme-ldap") | .id')
  echo "federação criada: $existing"
else
  echo "federação já existe: $existing"
  # Quem rodou uma versão anterior deste script tem a federação em texto claro: liga o StartTLS.
  # (O Keycloak recusa StartTLS com connection pooling ligado, por isso os dois mudam juntos.)
  ATUAL=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/components/$existing")
  if [ "$(jq -r '.config.startTls[0] // "false"' <<< "$ATUAL")" != "true" ]; then
    jq '.config.startTls=["true"] | .config.useTruststoreSpi=["always"] | .config.connectionPooling=["false"] | .config.bindCredential=["admin"]' <<< "$ATUAL" \
      | curl -fsS -X PUT "${auth[@]}" "$KC/admin/realms/$REALM/components/$existing" -d @-
    echo "StartTLS ligado na federação existente"
  fi
fi

echo "== mapper de grupos (groupOfNames) =="
if ! curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/components?parent=$existing" | jq -e '.[] | select(.name=="acme-groups")' >/dev/null; then
  curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$REALM/components" -d @- <<EOF
{
  "name": "acme-groups",
  "providerId": "group-ldap-mapper",
  "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
  "parentId": "$existing",
  "config": {
    "groups.dn": ["ou=groups,dc=acme,dc=edu,dc=br"],
    "group.name.ldap.attribute": ["cn"],
    "group.object.classes": ["groupOfNames"],
    "membership.ldap.attribute": ["member"],
    "membership.attribute.type": ["DN"],
    "membership.user.ldap.attribute": ["uid"],
    "mode": ["READ_ONLY"],
    "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
    "drop.non.existing.groups.during.sync": ["false"]
  }
}
EOF
  echo "mapper criado"
fi

echo "== mapper do primeiro nome (givenName) =="
# Ao criar uma federação de outro fornecedor que não o Active Directory, o Keycloak liga o
# "first name" ao cn, que na ACME é o nome completo. Com o sobrenome vindo do sn, a Ana aparecia
# como "Ana Souza Souza" no token e no Grafana. O primeiro nome mora no givenName. Isto vem
# antes da sincronização, para os usuários já entrarem com o nome certo.
MAPPER_NOME=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/components?parent=$existing" \
  | jq -c '[.[] | select(.providerId=="user-attribute-ldap-mapper" and .config["user.model.attribute"][0]=="firstName")][0] // empty')
if [ -z "$MAPPER_NOME" ]; then
  echo "AVISO: o mapper do primeiro nome não foi encontrado; os nomes podem sair repetidos"
elif [ "$(jq -r '.config["ldap.attribute"][0]' <<< "$MAPPER_NOME")" = "givenName" ]; then
  echo "o primeiro nome já vem do givenName"
else
  jq -c '.config["ldap.attribute"]=["givenName"]' <<< "$MAPPER_NOME" \
    | curl -fsS -X PUT "${auth[@]}" "$KC/admin/realms/$REALM/components/$(jq -r .id <<< "$MAPPER_NOME")" -d @-
  echo "primeiro nome agora vem do givenName (antes: $(jq -r '.config["ldap.attribute"][0]' <<< "$MAPPER_NOME"))"
fi

echo "== clients que o roteiro usa =="
# toolbox-cli: público, só com direct grant, para os comandos de terminal (força bruta, passo 9).
# É o password grant: a senha passa pelo client. Existe só como atalho de laboratório.
# grafana: confidencial, authorization code com PKCE. É por ele que a Ana entra no Grafana pelo
# Keycloak e cadastra o segundo fator (passos 13 a 16). O mesmo client serve ao Lab 6.
garante_client() {
  local cid; cid=$(jq -r .clientId <<< "$1")
  if [ -z "$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/clients?clientId=$cid" | jq -r '.[0].id // empty')" ]; then
    curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$REALM/clients" -d "$1" && echo "client $cid criado"
  else echo "client $cid já existe"; fi
}
garante_client '{"clientId":"toolbox-cli","name":"Toolbox CLI","protocol":"openid-connect","publicClient":true,
  "standardFlowEnabled":false,"directAccessGrantsEnabled":true,"redirectUris":[]}'
garante_client "{\"clientId\":\"grafana\",\"name\":\"Grafana\",\"protocol\":\"openid-connect\",\"publicClient\":false,
  \"secret\":\"grafana-secret\",\"standardFlowEnabled\":true,\"directAccessGrantsEnabled\":false,
  \"redirectUris\":[\"http://grafana.localhost:$PORTA/login/generic_oauth\"],\"webOrigins\":[\"http://grafana.localhost:$PORTA\"],
  \"attributes\":{\"post.logout.redirect.uris\":\"http://grafana.localhost:$PORTA/login\",\"pkce.code.challenge.method\":\"S256\"}}"

echo "== sincronização completa =="
curl -fsS -X POST "${auth[@]}" "$KC/admin/realms/$REALM/user-storage/$existing/sync?action=triggerFullSync" | jq -c .

echo "== usuários no realm =="
USUARIOS=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/users")
echo "$USUARIOS" | jq -r '.[] | "\(.username)  \(.firstName) \(.lastName)  \(.email)  federado=\(.federationLink != null)"'

# Quem roda este script de novo depois dos passos 12 a 16 já tem o segundo fator da Ana
# cadastrado. O teste abaixo é um password grant, que não foi feito para segundo fator: com o
# OTP da Ana ele seria recusado e o script morreria aqui. Nesse caso o teste usa a carla.dias.
TESTE=ana.souza
ID_ANA=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/users?username=ana.souza&exact=true" | jq -r '.[0].id // empty')
if [ -n "$ID_ANA" ] && curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/users/$ID_ANA/credentials" | jq -e '.[] | select(.type=="otp")' >/dev/null; then
  echo "(a ana.souza já tem segundo fator cadastrado: o teste de token pelo terminal usa a carla.dias)"
  TESTE=carla.dias
fi

echo "== login OIDC de usuário do LDAP ($TESTE) =="
# scope=openid é necessário para receber o id_token: no Keycloak >= 26 o client
# admin-cli emite "lightweight access token" (sem preferred_username/email/sub),
# então as claims de identidade só aparecem no id_token.
RESP=$(curl -fsS -X POST "$KC/realms/$REALM/protocol/openid-connect/token" \
  -d grant_type=password -d client_id=admin-cli -d scope=openid \
  -d "username=$TESTE" -d 'password=Senha@123')
TOK=$(echo "$RESP" | jq -r .access_token)
ID_TOK=$(echo "$RESP" | jq -r .id_token)
echo "--- access_token ---"; jwt-decode "$TOK"
echo "--- id_token ---";     jwt-decode "$ID_TOK"
jwt-decode -p "$ID_TOK" | jq -r '"iss=\(.iss) sub=\(.sub) user=\(.preferred_username) email=\(.email)"'

echo "== grupos de ana.souza =="
UID_=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/users?username=ana.souza&exact=true" | jq -r '.[0].id')
GRUPOS_ANA=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/users/$UID_/groups" | jq -r '.[].name')
echo "$GRUPOS_ANA"

# ---------------------------------------------------------------------------
# Evidência do lab: o arquivo que o aluno entrega no Moodle e que o painel lê.
# Como este script roda com 'set -e', chegar aqui já significa que tudo deu certo;
# o que interessa registrar é o que foi OBSERVADO, não que passou.
EV_ITENS="/tmp/gia-itens-$$.tsv"; : > "$EV_ITENS"
ev_item() { printf '%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" >> "$EV_ITENS"; }

ev_item ok "realm federado" "$REALM"
ev_item ok "conexão com o diretório" "$LDAP_URL com StartTLS, certificado conferido pela CA da ACME"
ev_item ok "issuer do realm" "$(jq -r .iss <<< "$(jwt-decode -p "$ID_TOK")")"
ev_item ok "usuários vindos do diretório" "$(echo "$USUARIOS" | jq -r '[.[] | select(.federationLink != null) | .username] | join(", ")')"
ev_item ok "identidade no id_token" "$(jwt-decode -p "$ID_TOK" | jq -r '"user=\(.preferred_username) email=\(.email) sub=\(.sub)"')"
ev_item ok "grupos de ana.souza no Keycloak" "$(echo "$GRUPOS_ANA" | paste -sd', ' -)"
GRAFANA_CLIENT=$(curl -fsS "${auth[@]}" "$KC/admin/realms/$REALM/clients?clientId=grafana" | jq -r '.[0] | "\(.clientId) confidencial=\(.publicClient | not) redirect=\(.redirectUris | join(","))"')
ev_item ok "aplicação registrada no realm" "$GRAFANA_CLIENT"

python3 /work/scripts/evidencia.py gravar --lab 5 \
  --titulo "Lab 5: federação do diretório no Keycloak" --itens "$EV_ITENS" || true
echo "LAB5 OK"
