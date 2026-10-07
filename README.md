# GIA: laboratórios do Encontro 2

Gerenciamento de Identidade e Acesso (GIA), Pós-Graduação EAD em Segurança Cibernética, CESC/UTFPR.
Prof. Maurício Barfknecht.

Este repositório traz a stack de laboratório do **Encontro 2**, com os **laboratórios 5 a 7**. Cada
encontro tem o seu repositório e o seu projeto Docker. O do Encontro 1 continua na pasta `gia-labs`,
com tudo o que você fez lá: nada aqui mexe nele.

Tudo roda na sua máquina, em containers, com ferramentas open source. Nada é enviado para lugar
nenhum: as evidências que você entrega no Moodle são arquivos gerados aqui dentro.

## O que você precisa

Quem fez o Encontro 1 já tem tudo. Quem está chegando agora instala o Docker pelo
**[INSTALACAO.md](INSTALACAO.md)** antes da aula.

- **Docker** com o plugin Compose v2. Confira com `docker compose version`.
- **8 GB de RAM** na máquina, com pelo menos **4 GB alocados ao Docker**.
- Chrome ou Firefox (o Safari não abre os endereços `*.localhost` do laboratório).

## Vindo do Encontro 1: pare aquela stack, sem apagar nada

As duas stacks usam a mesma porta, a 18080, então só uma fica no ar por vez. Na pasta do Encontro 1:

```bash
cd ~/gia-labs
docker compose --profile lab3 --profile tools stop
```

O `stop` só desliga os containers. O diretório, o GLPI, as evidências e todo o resto do Encontro 1
continuam guardados nos volumes daquele projeto. **Não use `down -v` naquela pasta:** o `-v` apaga os
volumes, e com eles o seu Encontro 1.

## Começando o Encontro 2

No Windows, tudo aqui é digitado no **terminal do Ubuntu** (WSL), e não no PowerShell, no Prompt de
Comando ou no Git Bash.

```bash
cd ~
git clone https://github.com/mauriciobnet/gia-labs-encontro2.git
cd gia-labs-encontro2
docker compose up -d --build --wait
```

Registre seu nome e o e-mail do seu cadastro no Moodle. A identificação mora num volume do projeto, e
este projeto é novo: a do Encontro 1 ficou lá.

```bash
docker compose exec -T toolbox python3 /work/scripts/evidencia.py aluno --nome "Seu Nome" --email "seu.email@example.com"
```

### A preparação: o ponto de partida dos Labs 5 a 7

Este projeto começa limpo, para que todo mundo parta do mesmo lugar. Do Encontro 1, os laboratórios
de agora precisam de três coisas, e a preparação monta as três em menos de um minuto:

- a CA da ACME e o certificado do diretório, os mesmos que o Lab 4 emitiu;
- o TLS ligado no OpenLDAP, na mesma porta 389;
- a CA entre os certificados confiáveis do Keycloak, e o Grafana falando com o diretório por
  StartTLS, com o mapeamento de grupos do Lab 3.

```bash
docker compose exec -T toolbox bash /work/scripts/preparar-encontro2.sh
docker compose restart keycloak grafana
```

O restart é necessário porque o Keycloak e o Grafana só leem certificados e a configuração do
diretório quando sobem. A preparação grava um arquivo de evidência que serve só ao painel: ele não
vai para o Moodle.

Depois abra o **painel** em <http://localhost:18080>. Quando os serviços ficarem verdes, a etapa
"Preparação" aparece concluída e o Lab 5 fica liberado. Os Labs 1 a 4 aparecem na trilha como
"encontro anterior", só para consulta: a entrega deles foi feita no repositório do Encontro 1.

## Os laboratórios deste encontro

Cada laboratório tem um **roteiro ilustrado** em `tutorial/`, com a captura de cada tela da execução
de referência. Abra pelo painel ou direto no arquivo: são páginas que funcionam sozinhas, sem rede.

Nos roteiros, cada comando diz onde roda. Os marcados **terminal · dentro do toolbox** rodam no
container `toolbox`. Para entrar nele, na pasta `gia-labs-encontro2`:

```bash
docker compose exec toolbox bash
```

O prompt muda e os comandos passam a rodar lá dentro. Para voltar ao seu terminal, `exit`.

### Lab 5: Federar o diretório no Keycloak

```bash
docker compose exec toolbox bash /work/scripts/lab5-federacao.sh
```

Roteiro: [`tutorial/lab5/index.html`](tutorial/lab5/index.html)

### Lab 6: SSO com OIDC

```bash
docker compose --profile lab6 up -d --wait
docker compose exec toolbox bash /work/scripts/lab6-sso.sh
```

Roteiro: [`tutorial/lab6/index.html`](tutorial/lab6/index.html)

### Lab 7: Federação SAML e brokering

```bash
docker compose exec toolbox bash /work/scripts/lab7-saml-fallback.sh
```

Roteiro: [`tutorial/lab7/index.html`](tutorial/lab7/index.html)

O Lab 7 tem um caminho opcional, com o SimpleSAMLphp no papel de IdP SAML externo. A imagem dele só
existe para amd64: em Mac com Apple Silicon, fique no caminho padrão acima.

```bash
docker compose --profile lab7 up -d --wait
docker compose exec toolbox bash /work/scripts/lab7-saml.sh
```

O roteiro é o guia de bancada. A teoria que explica cada passo está na apostila do encontro, no
Moodle.

## Entregando no Moodle

Os Labs 5, 6 e 7 terminam gravando um arquivo `evidencia-labN.json` com o que foi verificado **na
sua máquina**: seu nome, seu e-mail, o identificador da sua instalação, os horários e o que cada
teste observou. Baixe pelo botão "evidência" da etapa no painel e suba na tarefa correspondente.

Dois arquivos iguais se denunciam sozinhos, então não adianta pedir o do colega. E se um laboratório
parar no meio, a evidência é gravada mesmo assim, marcada como interrompida: entregue assim e diga
onde travou, que é melhor do que não entregar.

## Voltando ao Encontro 1

Se precisar abrir o Encontro 1 de novo, pare este e suba aquele:

```bash
cd ~/gia-labs-encontro2
docker compose --profile lab6 --profile lab7 --profile tools stop
cd ~/gia-labs
docker compose --profile lab3 up -d --wait
```

Para voltar para cá, o caminho inverso: `stop` lá e `docker compose up -d --wait` aqui (com
`--profile lab6` depois do Lab 6).

## Quando alguma coisa dá errado

**A porta 18080 já está ocupada.** O mais comum é a stack do Encontro 1 ainda estar no ar: pare como
na seção "Vindo do Encontro 1". Se não for isso, copie `env-exemplo.txt` para `.env`, troque o
`GIA_PORT` e suba de novo. Use a mesma porta nas URLs.

**O Lab 5 diz que o Keycloak não conseguiu falar StartTLS com o diretório.** Faltou o restart do fim da
preparação: `docker compose restart keycloak grafana`, e rode o Lab 5 de novo (ele espera o Keycloak
voltar).

**O Lab 6 diz que a ana.souza ainda tem o OTP do Lab 5.** Faltou o penúltimo passo do Lab 5: em
Users > ana.souza > Credentials, no console do Keycloak, apague a linha Otp e rode o Lab 6 de novo.
Os comandos de terminal entram com a senha só, e com o segundo fator cadastrado o Keycloak os recusa.

**`curl: could not resolve host` no seu terminal.** Normal. Os nomes `*.localhost` são resolvidos
pelo **navegador**, não pelo resolvedor do sistema no Windows e no macOS. Por isso todo comando dos
roteiros roda dentro do container `toolbox`.

**No Ubuntu do Windows: `The command 'docker' could not be found in this WSL 2 distro`, ou
`permission denied` ao rodar o `docker`.** Os dois têm conserto no [INSTALACAO.md](INSTALACAO.md),
seção do Windows.

**O painel diz que um serviço não responde logo depois do `up`.** O Keycloak leva de 30 a 90
segundos para ficar pronto, e o LAM uns 40. Espere e recarregue.

**Quero recomeçar o Encontro 2 do zero.** Nesta pasta, `docker compose --profile lab6 --profile lab7
--profile tools down -v` apaga só o projeto do Encontro 2: o Encontro 1 não é afetado. Depois suba de
novo, identifique-se e rode a preparação.

## Credenciais do cenário

São credenciais de laboratório, propositalmente fracas e públicas. Parte do exercício é reconhecer
tudo o que está errado nelas.

| Onde | Usuário | Senha |
|---|---|---|
| Pessoas da ACME (diretório e realm `acme`) | `ana.souza`, `bruno.lima` (grupo `ti`), `carla.dias` (grupo `professores`) | `Senha@123` |
| Parceiro e universidade (Lab 7) | `parceiro.user`, `maria.prof` | `Senha@123` |
| LDAP (administrador) | `cn=admin,dc=acme,dc=edu,dc=br` | `admin` |
| LDAP (configuração do servidor) | `cn=admin,cn=config` | `config` |
| LDAP Account Manager | `cn=admin` | `admin` |
| Keycloak (console) | `admin` | `admin` |
| Grafana (conta local) | `admin` | `admin` |

## O que não está aqui

As apostilas e os slides ficam no Moodle. E as ferramentas de manutenção da stack, que são do
professor.
