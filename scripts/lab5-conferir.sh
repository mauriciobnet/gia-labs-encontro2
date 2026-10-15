#!/usr/bin/env bash
# Passo 19 do Lab 5: confere o laboratório, grava a evidência e tira o OTP da Ana.
# Na pasta do repositório:
#   docker compose exec -T toolbox bash /work/scripts/lab5-conferir.sh
#
# A evidência do Lab 5 nasce aqui, e não na montagem (mudança de 15/10/2026). Antes, o
# lab5-federacao.sh gravava a evidência logo no início, e o painel dava o lab por concluído sem
# nada do que o aluno faz no console. Esta conferência soma o que a montagem verificou ao que só
# o aluno faz:
#   passo 7      a detecção de força bruta (Lockout temporarily, 3 falhas);
#   passo 8      a política de senha (mínimo de 12, Not username, Not email);
#   passos 9-11  o bloqueio do bruno.lima, registrado pelo lab5-desbloquear.sh;
#   passos 12-16 o TOTP cadastrado pela Ana, com o rótulo que ela deu.
# Por último, e só se tudo passou, apaga o OTP da Ana: os comandos de terminal dos Labs 6 e 7
# entram como ana.souza só com a senha (password grant), e com o segundo fator o Keycloak os
# recusa. O cadastro fica registrado em /work/out/lab5-otp.json, para a conferência poder rodar
# de novo depois do OTP apagado.
set -euo pipefail
source /work/scripts/lib.sh
MONTAGEM_CMD="docker compose exec -T toolbox bash /work/scripts/lab5-federacao.sh"

[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: o Keycloak não emitiu o token de administrador (ele está no ar?)"; exit 1; }

say "a montagem (antes do passo 1)"
conf_montagem 5 "$MONTAGEM_CMD"

REALM_JSON=$(kc_get "" 2>/dev/null) || REALM_JSON=""
if [ -z "$REALM_JSON" ]; then
  conf_falha "o realm $REALM não respondeu: rode a montagem antes do passo 1" "$MONTAGEM_CMD"
  REALM_JSON='{}'
fi

say "passo 7: a defesa contra força bruta"
read -r PROT PERM FATOR ESPERA <<< "$(jq -r '[.bruteForceProtected, .permanentLockout, .failureFactor, .waitIncrementSeconds] | map(tostring) | join(" ")' <<< "$REALM_JSON")"
VISTO="bruteForceProtected=$PROT permanentLockout=$PERM failureFactor=$FATOR waitIncrementSeconds=$ESPERA"
if [ "$PROT" != "true" ]; then
  conf_falha "refaça o passo 7: a detecção de força bruta está desligada (Brute Force Mode)" "$VISTO"
elif [ "$PERM" = "true" ]; then
  conf_falha "refaça o passo 7: o modo é de bloqueio permanente; escolha Lockout temporarily" "$VISTO"
elif [ "$FATOR" != "3" ]; then
  conf_falha "refaça o passo 7: Max login failures tem que ser 3" "$VISTO"
else
  conf_ok "passo 7: detecção de força bruta em Lockout temporarily, com 3 falhas" "$VISTO"
fi

say "passo 8: a política de senha"
POL=$(jq -r '.passwordPolicy // ""' <<< "$REALM_JSON")
MIN=$(grep -o 'length([0-9]*)' <<< "$POL" | grep -o '[0-9][0-9]*' | head -1 || true)
FALTA=""
[ -n "$MIN" ] && [ "$MIN" -ge 12 ] || FALTA="$FALTA Minimum length (12),"
grep -q 'notUsername' <<< "$POL" || FALTA="$FALTA Not username,"
grep -q 'notEmail' <<< "$POL" || FALTA="$FALTA Not email,"
if [ -n "$FALTA" ]; then
  conf_falha "refaça o passo 8: falta na política de senha:${FALTA%,}" "${POL:-(nenhuma política salva)}"
else
  conf_ok "passo 8: política de senha com mínimo de $MIN, Not username e Not email" "$POL"
fi

say "passos 9 a 11: o bloqueio do bruno.lima"
BLOQ="$OUT/lab5-bloqueio.json"
if [ -s "$BLOQ" ] && jq -e '.disabled == true' "$BLOQ" >/dev/null 2>&1; then
  conf_ok "passos 9 a 11: o bruno.lima foi bloqueado pela força bruta e desbloqueado pela API" \
    "$(jq -r '"numFailures=\(.numFailures), bloqueio visto em \(.quando)"' "$BLOQ")"
else
  conf_falha "refaça o passo 9 e, logo depois, o 11: o bloqueio do bruno.lima não foi registrado" \
    "o passo 11 registra o bloqueio quando o encontra ativo, e ele dura 1 minuto"
fi

say "passos 12 a 16: o segundo fator da Ana"
ID_ANA=$(kc_get "/users?username=ana.souza&exact=true" 2>/dev/null | jq -r '.[0].id // empty') || ID_ANA=""
OTPS='[]'
if [ -n "$ID_ANA" ]; then
  OTPS=$(kc_get "/users/$ID_ANA/credentials" 2>/dev/null | jq -c '[.[] | select(.type=="otp")]') || OTPS='[]'
fi
REG="$OUT/lab5-otp.json"
if [ "$(jq 'length' <<< "$OTPS")" -gt 0 ]; then
  jq -c --arg q "$(date -Iseconds)" \
    '{quando: $q, credenciais: [.[] | {rotulo: (.userLabel // ""), criada: (((.createdDate // 0) / 1000) | floor | todate)}]}' \
    <<< "$OTPS" > "$REG"
fi
if [ -s "$REG" ]; then
  conf_ok "passos 12 a 16: a ana.souza cadastrou o TOTP entrando pelo Grafana" \
    "$(jq -r '[.credenciais[] | "rótulo \"\(.rotulo)\", criada em \(.criada)"] | join("; ")' "$REG")"
else
  PEND=""
  [ -n "$ID_ANA" ] && PEND=$(kc_get "/users/$ID_ANA" 2>/dev/null | jq -r '(.requiredActions // []) | join(",")') || true
  if printf '%s' "$PEND" | grep -q CONFIGURE_TOTP; then
    conf_falha "faça os passos 13 a 16: o passo 12 pediu o OTP, mas a Ana ainda não entrou pelo Grafana para cadastrá-lo" "requiredActions=$PEND"
  else
    conf_falha "refaça os passos 12 a 16: a ana.souza não tem OTP cadastrado" "nenhuma credencial otp"
  fi
fi

if [ "$FAILS" -eq 0 ]; then
  say "passo 19: tirar o OTP da Ana antes do Lab 6"
  for c in $(jq -r '.[].id' <<< "$OTPS"); do
    curl -fsS -X DELETE "${auth[@]}" "$KC/admin/realms/$REALM/users/$ID_ANA/credentials/$c"
  done
  # Uma ação obrigatória de OTP pendente também barraria os comandos de terminal.
  U=$(kc_get "/users/$ID_ANA")
  if jq -e '(.requiredActions // []) | index("CONFIGURE_TOTP")' <<< "$U" >/dev/null; then
    kc_put "/users/$ID_ANA" "$(jq -c '.requiredActions = ((.requiredActions // []) - ["CONFIGURE_TOTP"])' <<< "$U")" >/dev/null
  fi
  RESTA=$(kc_get "/users/$ID_ANA/credentials" | jq '[.[] | select(.type=="otp")] | length')
  if [ "$RESTA" = "0" ]; then
    conf_ok "passo 19: OTP da ana.souza apagado; os comandos de terminal dos Labs 6 e 7 entram só com a senha" "credenciais otp restantes: 0"
  else
    conf_falha "o OTP da ana.souza não foi apagado: apague a linha Otp em Users > ana.souza > Credentials" "credenciais otp restantes: $RESTA"
  fi
else
  echo
  echo "Alguma conferência falhou acima: o OTP da Ana NÃO foi apagado. Refaça o passo indicado e rode"
  echo "esta conferência de novo."
fi

echo
conf_gravar 5
if [ "$FAILS" -eq 0 ]; then echo "LAB5 OK"
else echo "LAB5 FALHOU ($FAILS)"; exit 1; fi
