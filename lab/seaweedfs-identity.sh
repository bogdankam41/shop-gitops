#!/usr/bin/env bash
# Отдельная S3-учётка SeaweedFS для CNPG, права — только на бакет cnpg-backups.
# Ключи берутся из Vault (kv/lab-data/s3-cnpg) — источник правды там.
#
# Техдолг: s3.json SeaweedFS живёт в ConfigMap вне git и с ключами открытым
# текстом (там же учётка Velero). Правильно — ExternalSecret с template,
# который собирает s3.json из Vault, и монтировать Secret вместо ConfigMap.
set -euo pipefail

INIT_FILE=${VAULT_INIT_FILE:-$HOME/.config/vault-lab/init.json}
BUCKET=cnpg-backups

creds=$(jq -r .root_token "$INIT_FILE" |
  kubectl -n vault exec -i vault-0 -- sh -c \
    'read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault kv get -format=json kv/lab-data/s3-cnpg' |
  jq -c .data.data)

cur=$(kubectl -n seaweedfs get cm s3-config -o jsonpath='{.data.s3\.json}')
new=$(jq --argjson c "$creds" --arg b "$BUCKET" '
  .identities |= (map(select(.name != "cnpg")) + [{
    name: "cnpg",
    credentials: [{accessKey: $c.access_key_id, secretKey: $c.secret_access_key}],
    actions: ["Read:\($b)", "Write:\($b)", "List:\($b)", "Tagging:\($b)"]
  }])' <<<"$cur")

if [ "$cur" = "$new" ]; then
  echo "seaweedfs: identity cnpg already up to date"
else
  kubectl -n seaweedfs create cm s3-config --from-literal=s3.json="$new" \
    --dry-run=client -o yaml | kubectl apply -f -
  # s3.json читается только при старте
  kubectl -n seaweedfs rollout restart deploy/seaweedfs
  kubectl -n seaweedfs rollout status deploy/seaweedfs --timeout=180s
fi

# Бакет создаём админкой SeaweedFS, а не ключами CNPG — у них нет права на CreateBucket.
kubectl -n seaweedfs exec deploy/seaweedfs -- sh -c \
  "echo 's3.bucket.list' | weed shell 2>/dev/null | grep -qw $BUCKET || echo 's3.bucket.create -name $BUCKET' | weed shell"
echo "seaweedfs: bucket $BUCKET ready"
