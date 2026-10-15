#!/usr/bin/env bash
# Passo 11 do Lab 5: mostra, pela API do Keycloak, o estado de força bruta do bruno.lima e o
# desbloqueia. Na pasta do repositório:
#   docker compose exec -T toolbox bash /work/scripts/lab5-desbloquear.sh
#
# Por que é um script, e não um comando solto no roteiro (achados do professor, 15/10/2026):
#   1. o comando solto precisava do lib.sh, que só existe dentro do toolbox, e quem o rodava no
#      terminal da máquina via "kc_get: command not found";
#   2. ele dizia "desbloqueado" mesmo quando o DELETE falhava: o curl -s termina com 0 num 401,
#      e o "&& echo" imprimia do mesmo jeito;
#   3. com o ID vazio, a URL virava .../brute-force/users/, vizinha da rota que limpa as falhas de
#      TODOS os usuários.
# Aqui o usuário tem que existir, o DELETE só é feito com bloqueio ativo, o curl falha com o erro
# HTTP e o desbloqueio é conferido antes de ser anunciado. O bloqueio visto fica registrado em
# /work/out/lab5-bloqueio.json: é dele que a conferência do passo 19 tira a prova dos passos 9 a 11.
set -euo pipefail
source /work/scripts/lib.sh
LAB_NUM=""   # este script não grava evidência, nem quando para no meio
USUARIO=${1:-bruno.lima}
BASE="/admin/realms/$REALM/attack-detection/brute-force/users"

[ -n "$ADMIN_TOKEN" ] || { echo "ERRO: o Keycloak não emitiu o token de administrador (ele está no ar?)"; exit 1; }
ID=$(kc_get "/users?username=$USUARIO&exact=true" | jq -r '.[0].id // empty')
[ -n "$ID" ] || { echo "ERRO: o usuário $USUARIO não existe no realm $REALM. A montagem do Lab 5 rodou?"; exit 1; }

echo "GET $BASE/$ID"
ESTADO=$(kc_get "/attack-detection/brute-force/users/$ID")
jq . <<< "$ESTADO"

if [ "$(jq -r '.disabled' <<< "$ESTADO")" != "true" ]; then
  echo
  echo "O $USUARIO NÃO está bloqueado agora (disabled=false): o bloqueio de 1 minuto já expirou,"
  echo "ou o passo 9 não chegou a bloquear. Repita o passo 9 e rode este comando logo em seguida."
  exit 1
fi

jq --arg u "$USUARIO" --arg q "$(date -Iseconds)" '{usuario: $u, quando: $q} + .' <<< "$ESTADO" > "$OUT/lab5-bloqueio.json"

echo
echo "DELETE $BASE/$ID"
curl -fsS -X DELETE "${auth[@]}" "$KC$BASE/$ID"
if [ "$(kc_get "/attack-detection/brute-force/users/$ID" | jq -r '.disabled')" = "false" ]; then
  echo "desbloqueado"
else
  echo "ERRO: o $USUARIO continua bloqueado depois do DELETE"
  exit 1
fi
