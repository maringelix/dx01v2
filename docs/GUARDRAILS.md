# Guardrails do dx01v2

Um guardrail é uma regra mais o mecanismo que a faz valer — automático sempre que possível. Este
documento lista as regras do repositório, onde cada uma é aplicada e o que elas não garantem.
Tipos: `bloqueante` (falha o harness/CI), `alerta` (notifica), `processo` (disciplina humana/agente).

## Regras

| ID | Regra | Por quê | Onde é aplicada | Tipo |
|---|---|---|---|---|
| SEC-01 | Nenhum segredo no repositório | repositório público; histórico é para sempre | `gitleaks` (harness, pre-commit) | bloqueante |
| SEC-02 | Sem identificadores reais: account ID só `123456789012`/`<ACCOUNT_ID>`, e-mails `example.com`, IPs privados ou RFC 5737 | evita expor contas e pessoas | check `policy-identifiers` | bloqueante |
| SEC-03 | Credenciais locais geradas em tempo de execução com valores aleatórios (`scripts/dev-env.sh`, `scripts/e2e-kind.sh`); `.env` ignorado pelo git; `.env.example` só com placeholders; nenhum `Secret` nos manifests | nada de senha padrão copiada para todo lado | `.gitignore`, `gitleaks`, `contract-app` | bloqueante |
| SEC-04 | GitHub → AWS só por OIDC (`dx01v2-gha-deploy`, `sub` do environment `lab`); `id-token: write` só no job de deploy, nunca no `ci.yml` | sem chaves estáticas; nenhum outro workflow obtém credenciais | `policy-workflows` | bloqueante |
| SEC-05 | Token de admin com 32+ caracteres, comparado em tempo constante (SHA-256 dos dois lados + `timingSafeEqual`); sem token configurado a rota responde 503 `admin_disabled` | nada de token curto nem comparação que vaza tempo | `api/src/config.ts`, testes `admin-auth`, `config`, `messages` | bloqueante |
| SEC-06 | Logs redigem `Authorization`, `Cookie` e campos `password`/`token` | segredos não vão parar em agregadores de log | `api/src/logger.ts` + teste `logger` | bloqueante |
| SUP-01 | Ferramentas do harness com versão e SHA256 fixados; divergência é erro fatal | cadeia de suprimentos | `scripts/install-tools.sh`, `tools/checksums.txt` | bloqueante |
| SUP-02 | Toda action fixada por SHA de 40 caracteres com comentário `# vX.Y.Z` | tags podem ser movidas | `policy-workflows` | bloqueante |
| SUP-03 | Toda imagem por digest (Dockerfiles, compose, manifests, CI, kind, devcontainer e features); nada de `:latest` | erro do v1: trivy `latest` malicioso em março de 2026 | `policy-images` | bloqueante |
| SUP-04 | npm com versões exatas em todos os `package.json` e `package-lock.json` em sincronia | erro do v1: lockfile do cliente fora de sincronia | `version-consistency`, `npm-ci` (`npm ci` sempre no modo estrito) | bloqueante |
| SUP-05 | trivy só via `scripts/install-tools.sh` (nunca `trivy-action`/`setup-trivy`, GHSA-69fq-xp46-6x23) | incidente de cadeia de suprimentos de março de 2026 | `policy-workflows` | bloqueante |
| SUP-06 | Imagens sem vulnerabilidades HIGH/CRITICAL com correção disponível | o que é publicado não carrega CVE conhecido e corrigível | `trivy-image:api`, `trivy-image:web` | bloqueante |
| SUP-07 | Versões coerentes entre arquivos: Node.js (`.nvmrc`, `engines`, imagem de build), digest do PostgreSQL (compose, CI, kind, harness), minor do Kubernetes (kind, kubectl, schemas) | uma atualização pela metade não passa | `version-consistency` | bloqueante |
| SUP-08 | Dependabot mensal (npm, docker, actions, pre-commit), minor+patch agrupados, majors separados | nada apodrece em silêncio | `.github/dependabot.yml` | alerta |
| K8S-01 | Manifests renderizados válidos com kubeconform estrito e schemas fixados por commit (Kubernetes 1.36 e CRD `ExternalSecret`) | manifest inválido não chega ao cluster | `kubeconform` | bloqueante |
| K8S-02 | Pods conforme Pod Security `restricted`: `runAsNonRoot`, uid numérico, seccomp `RuntimeDefault`, sem escalada de privilégio, `drop: [ALL]`, `readOnlyRootFilesystem`, sem token de service account, sem `hostPath`/host namespaces, requests e limite de memória | menor privilégio; o namespace do EKS impõe `restricted` | `contract-app`; no kind, o e2e prova que um pod privilegiado é rejeitado | bloqueante |
| K8S-03 | NetworkPolicies: nega tudo (entrada e saída) e libera só DNS, web → api:3000, api → PostgreSQL/RDS:5432, ALB → pods (CIDR da VPC) e métricas só do namespace `monitoring` | um pod comprometido não alcança o banco | `contract-app`; sondas do e2e no kind | bloqueante |
| K8S-04 | Overlays `aws*` só com os tipos que a Role `dx01v2-deployer` pode escrever; namespace e RBAC são do tx01v2 | o deploy roda com privilégio mínimo | `contract-app` | bloqueante |
| K8S-05 | `trivy config` sem achados HIGH/CRITICAL nos manifests renderizados e nos Dockerfiles | segurança da configuração | `trivy-config` | bloqueante |
| APP-01 | `trust proxy` é uma contagem de saltos (`TRUST_PROXY_HOPS`), nunca `true`; o rate limit usa `req.ip` | erro do v1: `X-Forwarded-For` falso furava o limite | `policy-app`; teste `rate-limit`; smoke (429 com XFF falso diferente a cada requisição) | bloqueante |
| APP-02 | Sem middleware de CORS (mesma origem) e sem escapar HTML antes de gravar; a UI renderiza texto como texto (sem `dangerouslySetInnerHTML`) | erro do v1: dados corrompidos pelo escape | `policy-app`; testes de integração e smoke (texto com `<b>` volta igual) | bloqueante |
| APP-03 | UI sem estilos nem scripts inline (CSP `script-src 'self'; style-src 'self'`) | a CSP estrita só funciona sem exceções | `policy-app`; smoke (página sem `<script>`/`style` inline) | bloqueante |
| APP-04 | Cabeçalhos de segurança em toda resposta do nginx, inclusive assets e erros (o snippet é incluído em cada `location`); HSTS só para requisições HTTPS; `server_tokens off` | erros do v1: cabeçalhos duplicados ou ausentes, HSTS em HTTP | `policy-app`; smoke | bloqueante |
| APP-05 | Erros sempre em JSON `{"error":{"code","message","requestId"}}`, sem detalhes internos: 400 validação e JSON inválido, 413, 404, 415, 429, 500, 503 | erro do v1: CORS, limite de corpo e JSON inválido viravam 500 | testes de integração; smoke | bloqueante |
| APP-06 | A API loga só pelo pino (JSON, com request ID em cada linha) | logs estruturados e redigidos | `policy-app` (nada de `console.*`); eslint `no-console` | bloqueante |
| APP-07 | O token de admin fica só em memória no navegador | nada de credencial em `localStorage`/cookie | `policy-app` | bloqueante |
| APP-08 | Imagem da API distroless, sem shell nem npm/npx/corepack; as duas imagens com uid:gid numérico não root e labels OCI `source`/`revision` | erro do v1: container como root, nginx + node no mesmo container | `policy-images`, `image-policy:api`, `image-policy:web`, `hadolint` | bloqueante |
| APP-09 | Cobertura mínima: API linhas >= 80 % e branches >= 70 %; web linhas >= 70 %; os testes exercitam o código real (a API contra um PostgreSQL de verdade; a página com `fetch` simulado só na fronteira de rede) | erro do v1: testes de mocks definidos no próprio teste, ~14 % de cobertura real | limites do vitest (`test:api`, `test:web`) | bloqueante |
| APP-10 | Migrações aplicadas nunca são editadas (checksum em `schema_migrations`); uma por transação, sob advisory lock | réplicas e initContainers concorrentes não corrompem o schema | `api/src/migrate.ts`; teste `migrations` | bloqueante |
| APP-11 | Contrato com o tx01v2 versionado; mudanças em PRs coordenados nos dois repositórios | os dois lados evoluem juntos | `docs/CONTRATO.md`, `contract-app` | processo |
| CUSTO-01 | Deploy na AWS só por `workflow_dispatch`, com environment `lab` (revisor obrigatório) | ações que custam exigem intenção | `policy-workflows` | bloqueante |
| CUSTO-02 | Rodada em nuvem termina no mesmo dia com o destroy do tx01v2 + `scripts/leftovers.sh` e um relatório `cloud_run_report` | o ALB e o cluster cobram por hora | `docs/RUNBOOK.md` | processo |
| CI-01 | O CI é o harness: as checagens vivem em `scripts/harness.sh` e os jobs só chamam `make <alvo>` | o que passa local passa no CI | revisão de PR; `ci.yml` | processo |
| CI-02 | Sem `continue-on-error: true`, `\|\| true`, `\|\| echo` em workflows | gates honestos | `policy-workflows` | bloqueante |
| CI-03 | `permissions: contents: read` no topo, `timeout-minutes`, `concurrency`, `ubuntu-24.04`, `persist-credentials: false` | menor privilégio e previsibilidade | `policy-workflows` | bloqueante |
| CI-04 | `HARNESS_STRICT=1` no CI: todo SKIP vira FAIL e as versões das ferramentas precisam bater | nada é pulado em silêncio | `ci.yml`, `scripts/harness.sh` | bloqueante |
| CI-05 | O job `e2e` testa exatamente as imagens que o job `images` construiu e escaneou (artefato) | o que vai para o cluster é o que passou no trivy | `ci.yml` | processo |
| CI-06 | CI semanal agendado (segunda 06:00 UTC) | detecta CVEs novos, ignores vencidos e URLs quebradas | `ci.yml` | alerta |
| MUD-01 | `main` protegido por ruleset: PR obrigatório, checks `static`, `test`, `images` e `e2e` estritos, sem force-push | toda mudança passa pelo harness | `.github/rulesets/main.json` + `scripts/repo-guardrails.sh` | bloqueante (depois de publicado) |
| MUD-02 | Ignore de scanner só com `statement` e `expired_at` em até ~7 meses | exceções revisadas | `trivyignore-policy` | bloqueante |
| MUD-03 | Conventional Commits; um assunto por PR; CHANGELOG `[Unreleased]` atualizado | histórico legível | template de PR | processo |
| DOC-01 | README e docs só afirmam o que é verificado, com os rótulos exatos; sem auto-elogios | erro do v1: README/SECURITY com afirmações falsas | `repo-structure` (rótulos, auto-elogios, tamanho do README); revisão | bloqueante |
| DOC-02 | Docs atualizadas na mesma mudança do código | docs não envelhecem | template de PR | processo |
| AGT-01 | Agentes de IA nunca executam ações que alteram a nuvem sem pedido humano explícito na tarefa | dinheiro e segurança | `AGENTS.md` | processo |
| AGT-02 | Agentes não enfraquecem gates, não baixam cobertura e não adicionam ignores sem justificativa e validade | o harness só vale se for respeitado | `AGENTS.md`; checks acima | processo |
| AGT-03 | Agentes param e perguntam nos casos listados em `AGENTS.md` | decisões caras são humanas | `AGENTS.md` | processo |

## Exceções

Uma exceção é um ignore de scanner. Para adicionar uma:

1. Confirme que o achado é uma escolha deliberada do lab ou que não há como corrigi-lo agora (não um
   defeito a corrigir).
2. Adicione a entrada em `.trivyignore.yaml` com `id`, `paths` ou `purls` (o mais restrito possível),
   `statement` (por que é aceitável e o que compensa o risco) e `expired_at` em até ~7 meses.
3. Explique a exceção no PR. O check `trivyignore-policy` rejeita entradas sem justificativa, sem
   validade, vencidas ou longas demais; o trivy deixa de aplicar uma entrada vencida.

Exceções atuais (verificado em 2026-10-10): nenhuma. O gate das imagens usa `--ignore-unfixed`:
vulnerabilidades sem correção publicada e as de severidade LOW/MEDIUM não falham o build; o harness
imprime a contagem completa no resumo de `trivy-image:*` para acompanhamento.

## Limites (o que NÃO é garantido)

- Nada do v2 rodou na AWS: o deploy, o ExternalSecrets, o ALB, o WAF e o TLS com o RDS
  (`verify-full`) foram renderizados e validados, não exercitados.
- O e2e prova o enforcement de NetworkPolicy com o kindnet do kind (kube-network-policies), não com
  o VPC CNI do EKS; as regras por CIDR da VPC (ALB e RDS) só existem nos overlays `aws*`.
- O rate limit de escrita fica em memória por réplica da API: com N réplicas o limite efetivo chega a
  N vezes o configurado. Na AWS, o WAF do tx01v2 soma um limite por IP na borda.
- O token de admin é um segredo único e compartilhado (sem usuários, sem rotação automática); trocar
  o valor no Secrets Manager exige reiniciar os pods da API depois da sincronização do ESO.
- O smoke test pelo ALB lê o token de admin do Secret `app-secrets` (o deployer pode ler Secrets) e
  o mascara nos logs do GitHub Actions; quem pode disparar o deploy pode ver o token.
- `trivy --ignore-unfixed` não bloqueia CVEs sem correção; o agendamento semanal os reavalia.
- HSTS depende do `X-Forwarded-Proto: https` enviado pelo ALB; localmente não há TLS.
- Antes do primeiro commit, o `gitleaks` examina só os arquivos visíveis ao git (versionados e não
  ignorados); depois, todo o histórico.
- O bit executável dos scripts só é checado para arquivos já no índice do git.

## Como verificar

```bash
make tools                  # ferramentas fixadas em .tools/
HARNESS_STRICT=1 make verify
HARNESS_STRICT=1 make build
make e2e
scripts/harness.sh list     # todos os checks e estágios
```
