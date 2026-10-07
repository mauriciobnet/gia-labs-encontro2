#!/usr/bin/env bash
# Preparação do Encontro 2: o ponto de partida dos Labs 5 a 7.
#
# O Encontro 2 roda num projeto Docker próprio, que começa limpo. É de propósito: assim nada
# do que você fez no Encontro 1 é tocado, e todo mundo parte do mesmo lugar. Os Labs 5 a 7
# herdam do Encontro 1 só o que está abaixo, e este script monta tudo em menos de um minuto:
#
#   1. a CA da ACME e o certificado do diretório, os mesmos que o Lab 4 emitiu;
#   2. o TLS ligado no OpenLDAP, na mesma porta 389, pela configuração em tempo de execução;
#   3. a CA entre os certificados confiáveis do Keycloak (pasta pki/confianca);
#   4. o Grafana falando com o diretório por StartTLS, com o mapeamento de grupos do Lab 3.
#
# Ele não repete a aula do Lab 4 (as capturas de rede antes e depois): só deixa o terreno
# pronto. Roda DENTRO do toolbox e pode ser executado de novo quantas vezes for preciso.
#
#   docker compose exec -T toolbox bash /work/scripts/preparar-encontro2.sh
#
# Depois, no seu terminal, na pasta do repositório, reinicie o Keycloak e o Grafana: os dois
# só leem os certificados e a configuração do diretório quando sobem.
#
#   docker compose restart keycloak grafana
set -uo pipefail

OUT=/work/out; mkdir -p "$OUT" 2>/dev/null || OUT=/tmp
BASE="dc=acme,dc=edu,dc=br"
ANA="uid=ana.souza,ou=people,$BASE"
SENHA='Senha@123'
CA=/work/pki/ca/acme-ca.crt
CONFIANCA=/work/pki/confianca/acme-ca.crt
TOML=/work/grafana/ldap.toml
FAILS=0

# A evidência desta etapa é o que pinta a "Preparação" de verde no painel. Ela não vai para o
# Moodle: quem vai são as dos Labs 5, 6 e 7.
EV_ITENS="/tmp/gia-itens-$$.tsv"; : > "$EV_ITENS"
ev_item() { printf '%s\t%s\t%s\n' "$1" "$(printf '%s' "$2" | tr '\t\n' '  ')" "$(printf '%s' "${3:-}" | tr '\t\n' '  ')" >> "$EV_ITENS"; }
say() { printf '\n== %s ==\n' "$*"; }
ok()  { printf '\e[32m[ OK ]\e[0m %s\n' "$*"; }
ko()  { printf '\e[31m[FALHA]\e[0m %s\n' "$*"; ev_item falha "$*"; FAILS=$((FAILS+1)); }

# ---------------------------------------------------------------------------
say "1. diretório no ar"
NO_AR=0
for i in $(seq 1 30); do
  if ldapsearch -x -H ldap://openldap -D "cn=admin,$BASE" -w admin -b "$BASE" -s base dn >/dev/null 2>&1; then
    NO_AR=1; break
  fi
  sleep 2
done
if [ "$NO_AR" -eq 1 ]; then
  ok "OpenLDAP respondendo em ldap://openldap:389"
else
  ko "o OpenLDAP não respondeu em 1 minuto. Confira no seu terminal: docker compose ps openldap"
  echo; echo "Sem o diretório não há o que preparar. Suba a stack com docker compose up -d --build --wait e rode de novo."
  exit 1
fi

# ---------------------------------------------------------------------------
say "2. a CA da ACME e o certificado do diretório"
bash /work/scripts/gerar-pki.sh > "$OUT/preparo-pki.txt" 2>&1
if [ -s "$CA" ] && [ -s /work/pki/ldap/ldap.crt ] && openssl verify -CAfile "$CA" /work/pki/ldap/ldap.crt >/dev/null 2>&1; then
  SAN=$(openssl x509 -in /work/pki/ldap/ldap.crt -noout -ext subjectAltName 2>/dev/null | tail -1 | tr -s ' ')
  ok "certificado do diretório emitido pela CA da ACME ($SAN)"
  ev_item ok "CA da ACME e certificado do diretório" "$(openssl x509 -in "$CA" -noout -subject | sed 's/^subject=//')"
else
  ko "a PKI não foi gerada: $(tail -3 "$OUT/preparo-pki.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
say "3. TLS no diretório, na mesma porta 389"
# Mesmo caminho do Lab 4: a configuração em tempo de execução (cn=config), e não a variável
# LDAP_TLS da imagem, que só valeria na primeira subida do container.
tls_atual() {
  ldapsearch -x -LLL -H ldap://openldap -D cn=admin,cn=config -w config -b cn=config -s base olcTLSCertificateFile 2>/dev/null \
    | sed -n 's/^olcTLSCertificateFile: //p'
}
if [ "$(tls_atual)" != "/certs/ldap.crt" ]; then
  ldapmodify -x -H ldap://openldap -D cn=admin,cn=config -w config -f /work/ldap/tls.ldif > "$OUT/preparo-tls.txt" 2>&1 || true
fi
if [ "$(tls_atual)" = "/certs/ldap.crt" ]; then
  ok "slapd apresentando o certificado (olcTLSCertificateFile = /certs/ldap.crt)"
else
  ko "a configuração TLS não pegou no cn=config: $(tail -2 "$OUT/preparo-tls.txt" 2>/dev/null | tr '\n' ' ')"
fi
if LDAPTLS_CACERT="$CA" ldapwhoami -x -ZZ -H ldap://openldap -D "$ANA" -w "$SENHA" >"$OUT/preparo-bind.txt" 2>&1 \
   && grep -q "uid=ana.souza" "$OUT/preparo-bind.txt"; then
  ok "bind de ana.souza por StartTLS, com o certificado conferido pela CA da ACME"
  ev_item ok "StartTLS no diretório" "ldapwhoami -ZZ como ana.souza na porta 389"
else
  ko "o bind por StartTLS falhou: $(head -2 "$OUT/preparo-bind.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
say "4. a CA entre os certificados confiáveis do Keycloak"
# O gerar-pki.sh já copia a CA para pki/confianca. A pasta só recebe certificados, nunca a
# chave privada: o Keycloak lê tudo o que estiver nela.
if [ -s "$CA" ] && ! cmp -s "$CA" "$CONFIANCA"; then
  mkdir -p "$(dirname "$CONFIANCA")"; cp -f "$CA" "$CONFIANCA"; chmod 644 "$CONFIANCA" 2>/dev/null || true
fi
if [ -s "$CONFIANCA" ] && cmp -s "$CA" "$CONFIANCA"; then
  ok "pki/confianca/acme-ca.crt igual à CA da ACME"
  ev_item ok "CA na truststore do Keycloak" "pki/confianca/acme-ca.crt"
else
  ko "a CA não está em pki/confianca; sem ela o Keycloak não confia no diretório"
fi

# ---------------------------------------------------------------------------
say "5. o Grafana falando com o diretório por StartTLS"
if [ ! -f "$TOML" ]; then
  ko "/work/grafana/ldap.toml não existe dentro do toolbox (a pasta grafana/ do repositório não está montada)"
else
  # O ligar-tls-grafana.py guarda uma cópia do arquivo original ao lado (ldap-sem-tls.toml), na
  # primeira vez. Aqui ela não serve para nada: o arquivo do pacote já vem com StartTLS. A cópia
  # só é apagada se nasceu agora; uma que já existia (a da stack do professor) fica onde está.
  COPIA=/work/grafana/ldap-sem-tls.toml
  TINHA_COPIA=0; [ -e "$COPIA" ] && TINHA_COPIA=1
  python3 /work/scripts/ligar-tls-grafana.py "$TOML" > "$OUT/preparo-grafana.txt" 2>&1 || true
  [ "$TINHA_COPIA" -eq 0 ] && rm -f "$COPIA" 2>/dev/null
  TLS_GRAFANA=$(python3 - "$TOML" <<'PY'
import re, sys
linhas = open(sys.argv[1], encoding="utf-8").read().split("\n")
v, dentro = {}, False
for l in linhas:
    t = l.strip()
    if t == "[[servers]]":
        dentro = True
        continue
    if dentro and t.startswith("["):
        break
    m = re.match(r"(use_ssl|start_tls|ssl_skip_verify)\s*=\s*(\w+)", t) if dentro else None
    if m:
        v[m.group(1)] = m.group(2)
print("use_ssl=%s start_tls=%s ssl_skip_verify=%s" % (v.get("use_ssl", "?"), v.get("start_tls", "?"), v.get("ssl_skip_verify", "?")))
PY
)
  if [ "$TLS_GRAFANA" = "use_ssl=true start_tls=true ssl_skip_verify=false" ]; then
    ok "ldap.toml do Grafana pede StartTLS com verificação ($TLS_GRAFANA)"
    ev_item ok "Grafana configurado para StartTLS" "$TLS_GRAFANA"
  else
    ko "o ldap.toml do Grafana não ficou com StartTLS ($TLS_GRAFANA)"
  fi
  if grep -q 'group_dn = "cn=ti,ou=groups' "$TOML"; then
    ok "mapeamento de grupos do Lab 3 presente (cn=ti vira Admin no login pelo diretório)"
  else
    ko "o ldap.toml do Grafana está sem o mapeamento de grupos (cn=ti)"
  fi
fi

# ---------------------------------------------------------------------------
say "6. identificação"
# Este projeto é novo, e o volume onde a identificação mora também. Sem ela, as evidências dos
# Labs 5 a 7 sairiam anônimas e não serviriam para o Moodle.
IDENT=$(python3 - "$OUT/aluno.json" <<'PY' 2>/dev/null
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    sys.exit(0)
if d.get("nome") and d.get("email"):
    print("%s · %s" % (d["nome"], d["email"]))
PY
)
if [ -n "$IDENT" ]; then
  ok "identificação registrada: $IDENT"
  ev_item ok "identificação" "$IDENT"
else
  ko "você ainda não se identificou neste projeto. Rode, com o e-mail do seu cadastro no Moodle:"
  echo '       docker compose exec -T toolbox python3 /work/scripts/evidencia.py aluno --nome "Seu Nome" --email "seu.email@example.com"'
  echo "       e depois rode a preparação de novo."
fi

# ---------------------------------------------------------------------------
say "resumo"
if [ "$FAILS" -eq 0 ]; then
  ev_item ok "resumo da preparação" "PKI, TLS no diretório, CA no Keycloak e Grafana com StartTLS"
  python3 /work/scripts/evidencia.py gravar --lab p --titulo "Preparação do Encontro 2" --itens "$EV_ITENS" >/dev/null 2>&1 || true
  rm -f "$EV_ITENS"
  echo "Ponto de partida pronto. Falta um passo, no seu terminal, na pasta do repositório:"
  echo
  echo "       docker compose restart keycloak grafana"
  echo
  echo "O Keycloak só lê os certificados confiáveis quando sobe, e o Grafana só lê o ldap.toml"
  echo "quando sobe. Depois do restart, espere o painel ficar verde e comece o Lab 5."
  echo "PREPARACAO OK"
  exit 0
fi
ev_item falha "resumo da preparação" "$FAILS verificação(ões) falharam"
python3 /work/scripts/evidencia.py gravar --lab p --titulo "Preparação do Encontro 2" --itens "$EV_ITENS" >/dev/null 2>&1 || true
rm -f "$EV_ITENS"
echo "A preparação parou com $FAILS problema(s). Leia as linhas [FALHA] acima, arrume e rode de novo."
echo "PREPARACAO FALHOU ($FAILS)"
exit 1
