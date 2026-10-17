# R9 — dados, perda regional e volta à origem

Status: implementação em revisão; o job `continuity` publica as medições de cada commit.
Nada de v2 foi executado no AWS. Um resultado Docker não certifica SLA, latência,
replicação gerenciada nem promoção do RDS.

## Experimento reproduzível sem conta cloud

O `make continuity` exige as duas imagens já construídas pelo CI. É um ensaio pesado,
destinado ao Actions. Não compila uma imagem diferente daquela aprovada pelos scanners.

1. Cria A e B com redes de backend/frontend e discos independentes; nenhum banco
   expõe porta no host. Só a aplicação publica HTTP em loopback com porta aleatória.
2. Recupera um pacote de configuração e segredos efêmeros por checksum. Os IDs de
   imagem são conferidos; o pacote e as chaves privadas nunca entram em artifacts.
3. Usa PostgreSQL com TLS `verify-full`, CA efêmera e SAN `db`. A API monta apenas
   a CA pública. O banco e o frontend não compartilham rede diretamente.
4. Grava um marcador pela API através do nginx, para o banco e comprova falha
   de leitura. Reinicia o banco e exige recuperação pela mesma API, sem reiniciá-la.
5. Faz `pg_dump -Fc`, confere o catálogo e SHA256, grava uma transação posterior
   e exige que a tentativa de promoção com o primário vivo seja recusada.
6. Corrompe uma cópia do backup e exige rejeição antes de qualquer restore.
7. Interrompe todos os escritores de A, verifica o fencing e destrói seu disco.
   Restaura B a partir do backup íntegro e inicia a mesma versão da aplicação.
8. Exige o marcador anterior e a ausência da transação posterior ao backup. Mede
   RPO como o intervalo entre o início do backup consistente e a falha; RTO vai da
   falha até a aplicação B servir e confirmar os dados. Limites locais: 120 s/180 s.
9. Grava em B, produz novo backup, bloqueia B e reconstrói A num disco novo.
   A volta precisa preservar tanto os dados originais quanto os gravados em B,
   em até 180 s. B deve permanecer sem capacidade de escrita.

O relatório `continuity/continuity.json` contém checksums, IDs de imagem, RPO,
RTO, tempo de failback e a perda intencional de uma transação. Erros falham o job.
O cleanup verifica o rótulo exclusivo de execução antes de remover cada recurso.
Não usa volume, rede, contexto Kubernetes ou projeto Compose de outro trabalho.

## O que cada camada recupera

| Camada | Mecanismo | Evidência |
|---|---|---|
| Reconexão da API | pool descarta conexão quebrada e abre outra | interrupção do DB, mesmo container da API |
| Backup lógico da aplicação | `pg_dump`, catálogo e SHA256 | marcador preservado e corrupção recusada |
| Arquivo físico/WAL e PITR | exercício do `tx01v2` | base backup verificado, restore point, transação removida recuperada |
| PVC Kubernetes | Velero no `tx01v2` | em construção no PR coordenado, requer checksum após remover o PVC original |
| Perda de ambiente e failback | redes/discos A/B independentes | job `continuity`, fencing e dados novos preservados |
| Imagens e supply chain | artifact do próprio job `images`, release assinada no deploy | mesmos IDs em A e B, gates R7 |
| Banco e runtime gerenciados | perfil `dr` e runbook do `tx01v2` | Terraform mock/validação; não executado na cloud |

Em cloud, confirme o plano e a região do contrato antes de qualquer alteração.
Bloqueie GitOps/deploys e escritores antigos antes de promover a réplica; uma troca
de DNS sozinha não impede split brain. Execute o runbook do par, acompanhe o lag,
guarde evidência de RPO/RTO e só faça failback após reseed consistente da origem.
Se a origem não puder ser isolada, pare a promoção e escale ao operador.

Não copie o arquivo `.env` local para cloud. Segredos regionais ficam no Secret
Manager e workload identities da região. A promoção publica os digests já
assinados no registry da região recuperada; não deve reconstruir o código.

## Deploy e dados da região de recuperação

O contrato v7 seleciona EKS, registry, rede, WAF, certificado ACM e endpoint RDS
da região escolhida. `target=secondary` lê `/tx01v2/lab-dr/`, publica
`gitops/aws-dr` e usa `LAB_DR_REGION` (padrão us-west-2). Configure primeiro
o perfil DR e a plataforma do TX. O registry recebe os digests aprovados do release.

Secrets Manager replica usuário, senha e token **vigentes** com o mesmo nome
em outra região. O template do ESO altera somente DB_HOST para `db/endpoint`.
O deploy não lê valores de Secrets Manager. As 16 chaves SSM são lidas em lotes
de até dez, limite da API, e ausência/falha de qualquer lote bloqueia o deploy.

Após fencing e promoção autorizada, o smoke usa o IP do ALB secundário com o
hostname público e TLS verificado antes de qualquer mudança de DNS. Exige a
revisão publicada e uma escrita/leitura. Só depois ative o ExternalDNS secundário
no workflow TX (`activate_dns=true`); ele nasce com zero réplicas.
