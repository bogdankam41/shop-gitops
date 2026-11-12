# lab-data — Vault → External Secrets → CloudNativePG

Лаба под self-hosted платформу данных: секреты живут в Vault, ESO доставляет их
в namespace, PostgreSQL работает на CloudNativePG с архивом WAL и бэкапами в S3
(SeaweedFS). Всё ставится через Argo CD (`argocd/vault.yaml`,
`external-secrets.yaml`, `cnpg.yaml`, `lab-data.yaml`), руками — только то, что
декларативно не делается: init/unseal Vault и учётка в SeaweedFS.

```
Vault (kv/lab-data/*) ──kubernetes auth (SA lab-data/eso-vault, aud=vault)──▶ ESO
   │ audit → stdout → Alloy → Loki                                          │
   ▼                                                                        ▼
                                              Secret pg-app / pg-reporting / s3-cnpg
                                                                            │
                         CNPG Cluster pg-lab (primary + replica, разные ноды)
                             │ WAL + base backups (Barman Cloud plugin)
                             ▼
                         SeaweedFS S3: s3://cnpg-backups (учётка только на бакет)
```

## Первый запуск

```sh
lab/vault-bootstrap.sh        # init (3 доли / порог 2) → unseal → kv, audit, k8s auth, policy, role → сид
lab/seaweedfs-identity.sh     # S3-учётка cnpg из Vault в s3.json SeaweedFS + бакет
```

Ключи распечатки и root token — только в `~/.config/vault-lab/init.json` (0600).
**После любого рестарта пода `vault-0` Vault запечатан**: `lab/vault-bootstrap.sh unseal`.

## Проверенные сценарии (2026-11-12)

| Сценарий | Как | Результат |
|---|---|---|
| Ротация пароля | `vault kv put kv/lab-data/pg-reporting …` | ESO обновил Secret, CNPG сделал `ALTER ROLE`: новый пароль работает через **19 с**, старый отвергается |
| Failover | `kubectl delete pod <primary>` под записью раз в 0,5 с | реплика повышена, простой записи **~8,4 с**, подтверждённые записи не потеряны |
| PITR | `DROP TABLE orders` → `lab/pitr-restore.yaml` с `targetTime` | отдельный кластер поднялся из S3 за **85 с**, 1000 строк / сумма совпали; таблица возвращена в прод через `pg_dump` |
| Vault sealed | рестарт `vault-0` | ExternalSecret → `SecretSyncedError`, но Secret остаётся и Postgres работает; после unseal синк вернулся сам |
| Изоляция | ExternalSecret в `default`; логин в Vault токеном `default/default` | ESO: отказ по `conditions`; Vault: **403** |
| Аудит | Loki: `{namespace="vault"} \|= "lab-data/pg-reporting" \| json` | видно запись root и чтения от `kubernetes-lab-data-eso-vault` раз в минуту |

Полезное: `kubectl get backup` в этом кластере показывает Velero — у CNPG
`kubectl get backups.postgresql.cnpg.io`.

## Решения

- **Идентичность на арендатора.** `ClusterSecretStore` без `serviceAccountRef.namespace`
  берёт SA из namespace ExternalSecret; роль Vault привязана к `lab-data/eso-vault`,
  политика — `read` на `kv/data/lab-data/*`. Один store на кластер, изоляция в Vault.
- **`longhorn-r1` под Postgres.** PG реплицирует сам; 3 реплики Longhorn под каждой
  репликой PG — шесть копий и лишняя сетевая запись.
- **Barman Cloud plugin**, не встроенный `barmanObjectStore` (deprecated с CNPG 1.26).
- **Восстановление — в отдельный кластер** и без архиватора WAL: иначе он начнёт писать
  в тот же путь в S3.
- Ничего не планируется на control-plane ноду.

## Что сделать в проде иначе

- Vault: 3–5 нод Raft, auto-unseal (KMS/transit), TLS (cert-manager), конфигурация через
  terraform-provider-vault, root token отозван; алерт на `vault_core_unsealed == 0`.
- Динамические учётки Postgres (database secrets engine) вместо статических паролей.
- Синхронная репликация (`postgresql.synchronous`), если нужен RPO = 0.
- s3.json SeaweedFS — из Vault через ExternalSecret с template, а не ConfigMap.
- Argo CD управляет сам собой (сейчас поставлен `kubectl apply`, лимит контроллера
  поднят патчем до 1Gi после OOM на новых CRD).
