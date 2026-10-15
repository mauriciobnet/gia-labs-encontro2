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

Ainda antes da aula, baixe as imagens do Lab 6, para não depender da rede da sala:

```bash
docker compose --profile lab6 pull --ignore-buildable
```

O `--ignore-buildable` pula as imagens que o Compose constrói na sua máquina, como a do `toolbox`:
elas não existem em registro nenhum, e o `pull` não deve procurá-las lá.

Depois abra o **painel** em <http://localhost:18080>. Quando os serviços ficarem verdes, a etapa
"Preparação" aparece concluída e o Lab 5 fica liberado. Os Labs 1 a 4 aparecem na trilha como
"encontro anterior", só para consulta: a entrega deles foi feita no repositório do Encontro 1.

## Os laboratórios deste encontro

Cada laboratório tem um **roteiro ilustrado** em `tutorial/`, com a captura de cada tela da execução
de referência. Abra pelo painel ou direto no arquivo: são páginas que funcionam sozinhas, sem rede.

Cada laboratório começa por uma **montagem**, antes do passo 1, e termina numa **conferência**, que
vê o que você fez no console e no navegador e grava a evidência. A montagem sozinha não conclui o
lab: no painel, ele só fica verde depois da conferência.

Neste encontro, todo comando dos roteiros roda no **terminal do seu computador, na pasta `gia-labs-encontro2`**,
e cada caixa diz isso (*terminal · na pasta gia-labs-encontro2/*). O que precisa do container `toolbox` entra
nele sozinho, pelo `docker compose exec -T toolbox`: um script, pelo caminho dele, e um comando solto,
entre duas linhas `TOOLBOX`. Copie a caixa inteira, pelo botão **copiar**. Se quiser explorar por
dentro, `docker compose exec toolbox bash` abre um terminal no toolbox, e `exit` volta.

### Lab 5: Federar o diretório no Keycloak

Antes do passo 1, a montagem do laboratório:

```bash
docker compose exec -T toolbox bash /work/scripts/lab5-federacao.sh
```

No fim do roteiro, a conferência, que grava a evidência:

```bash
docker compose exec -T toolbox bash /work/scripts/lab5-conferir.sh
```

Roteiro: [`tutorial/lab5/index.html`](tutorial/lab5/index.html)

### Lab 6: SSO com OIDC

Antes do passo 1, a montagem do laboratório:

```bash
docker compose --profile lab6 up -d --wait
docker compose exec -T toolbox bash /work/scripts/lab6-sso.sh
```

No fim do roteiro, a conferência, que grava a evidência:

```bash
docker compose exec -T toolbox bash /work/scripts/lab6-conferir.sh
```

Roteiro: [`tutorial/lab6/index.html`](tutorial/lab6/index.html)

### Lab 7: Federação SAML e brokering

Antes do passo 1, a montagem do laboratório:

```bash
docker compose exec -T toolbox bash /work/scripts/lab7-saml-fallback.sh
```

No fim do roteiro, a conferência, que grava a evidência:

```bash
docker compose exec -T toolbox bash /work/scripts/lab7-conferir.sh
```

Roteiro: [`tutorial/lab7/index.html`](tutorial/lab7/index.html)

No Lab 5, a conferência do passo 19 apaga o OTP da Ana por último: os comandos de terminal dos Labs
6 e 7 entram só com a senha, e com o segundo fator cadastrado o Keycloak os recusa.

O Lab 7 tem um caminho opcional, com o SimpleSAMLphp no papel de IdP SAML externo. A imagem dele só
existe para amd64: em Mac com Apple Silicon, fique no caminho padrão acima.

```bash
docker compose --profile lab7 up -d --wait
docker compose exec -T toolbox bash /work/scripts/lab7-saml.sh
```

Na tela de login do realm `acme` aparece então o botão "Parceiro (SAML)", que leva ao SimpleSAMLphp
(usuário `user1`, senha `user1pass`). O `lab7-saml.sh` não grava evidência: a entrega do Lab 7 é a
da conferência do caminho padrão.

O roteiro é o guia de bancada. A teoria que explica cada passo está na apostila do encontro, no
Moodle.

## Entregando no Moodle

Os Labs 5, 6 e 7 terminam numa conferência, que soma o que a montagem verificou ao que você fez e
grava um arquivo `evidencia-labN.json` com o que foi verificado **na sua máquina**: seu nome, seu
e-mail, o identificador da sua instalação, os horários e o que cada verificação observou. Baixe pelo
botão "evidência" da etapa no painel e suba na tarefa correspondente.

Se a conferência mostrar uma linha `[FALHA]`, a linha diz qual passo refazer: refaça e rode a
conferência de novo, que o arquivo é gravado outra vez.

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

**O Lab 5 continua "disponível" no painel depois da montagem.** Normal: ele só fica verde na
conferência do passo 19, depois do que você fizer no console.

**O Lab 6 diz que a ana.souza ainda tem o OTP do Lab 5.** Faltou a conferência do Lab 5 (passo 19),
que apaga o OTP por último, e só quando tudo o mais passou. Rode-a, refaça o que ela apontar e rode
a montagem do Lab 6 de novo. Os comandos de terminal entram com a senha só, e com o segundo fator
cadastrado o Keycloak os recusa.

**`curl: could not resolve host` no seu terminal.** Os nomes `*.localhost` são resolvidos pelo
**navegador**, e nem sempre pelo resolvedor do sistema. Por isso os comandos dos roteiros entram no
container `toolbox`, pelo `docker compose exec -T toolbox`, e o `curl` roda lá dentro. Se você
digitou só o `curl`, sem a primeira linha da caixa, copie a caixa inteira.

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
| SimpleSAMLphp (Lab 7, opcional) | `user1`, `user2` | `user1pass`, `user2pass` |
| LDAP (administrador) | `cn=admin,dc=acme,dc=edu,dc=br` | `admin` |
| LDAP (configuração do servidor) | `cn=admin,cn=config` | `config` |
| LDAP Account Manager | `cn=admin` | `admin` |
| Keycloak (console) | `admin` | `admin` |
| Grafana (conta local) | `admin` | `admin` |

## O que não está aqui

As apostilas e os slides ficam no Moodle. E as ferramentas de manutenção da stack, que são do
professor.
