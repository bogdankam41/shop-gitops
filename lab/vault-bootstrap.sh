#!/usr/bin/env bash
# Init / unseal / настройка Vault для лабы lab-data. Идемпотентен: можно
# запускать повторно (например, после рестарта пода — Vault снова sealed).
#
#   lab/vault-bootstrap.sh            # init (если нужно) + unseal + настройка + сид секретов
#   lab/vault-bootstrap.sh unseal     # только распечатать
#
# Ключи распечатки и root token пишутся ТОЛЬКО локально в $VAULT_INIT_FILE
# (по умолчанию ~/.config/vault-lab/init.json, 0600) — в git они не попадают.
# Root token передаётся в под через stdin, а не аргументом: не светится в ps.
#
# В проде: 3/5 нод Raft, auto-unseal (KMS / transit), конфигурация Vault —
# terraform-provider-vault, root token отозван после настройки.
set -euo pipefail

NS=vault
POD=vault-0
INIT_FILE=${VAULT_INIT_FILE:-$HOME/.config/vault-lab/init.json}

vexec() { kubectl -n "$NS" exec -i "$POD" -- "$@"; }

# Команда vault с root token. Токен — первой строкой stdin (read забирает
# только её), всё, что после, достаётся самой команде (`kv put ... -`).
VAULT_SH='read -r VAULT_TOKEN; export VAULT_TOKEN; exec vault "$@"'
vroot() {
  jq -r .root_token "$INIT_FILE" |
    kubectl -n "$NS" exec -i "$POD" -- sh -c "$VAULT_SH" vault "$@"
}
vroot_in() {
  { jq -r .root_token "$INIT_FILE"; cat; } |
    kubectl -n "$NS" exec -i "$POD" -- sh -c "$VAULT_SH" vault "$@"
}

status_json() { vexec vault status -format=json 2>/dev/null || true; }

init() {
  if [ "$(status_json | jq -r .initialized)" = "true" ]; then
    echo "vault: already initialized"
    return
  fi
  [ -e "$INIT_FILE" ] && { echo "refusing to overwrite $INIT_FILE" >&2; exit 1; }
  mkdir -p "$(dirname "$INIT_FILE")" && chmod 700 "$(dirname "$INIT_FILE")"
  # Shamir: 3 доли, нужно 2 (в проде доли — у разных людей).
  (umask 077 && vexec vault operator init -key-shares=3 -key-threshold=2 -format=json >"$INIT_FILE")
  echo "vault: initialized, keys in $INIT_FILE"
}

unseal() {
  if [ "$(status_json | jq -r .sealed)" = "false" ]; then
    echo "vault: already unsealed"
    return
  fi
  for i in 0 1; do
    jq -r ".unseal_keys_b64[$i]" "$INIT_FILE" |
      kubectl -n "$NS" exec -i "$POD" -- sh -c 'vault operator unseal "$(cat)" >/dev/null'
  done
  echo "vault: unsealed"
}

configure() {
  # KV v2: версии секретов, откат, soft delete.
  vroot secrets list -format=json | jq -e '."kv/"' >/dev/null ||
    vroot secrets enable -path=kv kv-v2

  # Аудит каждого запроса в stdout пода → Alloy → Loki (значения хэшируются HMAC).
  vroot audit list -format=json 2>/dev/null | jq -e '."stdout/"' >/dev/null ||
    vroot audit enable -path=stdout file file_path=stdout

  # Kubernetes auth: под предъявляет JWT своего SA, Vault проверяет его через
  # TokenReview (свой SA с system:auth-delegator — создаёт чарт).
  vroot auth list -format=json | jq -e '."kubernetes/"' >/dev/null ||
    vroot auth enable kubernetes
  vroot write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc:443

  # Политика арендатора: только чтение своих путей.
  vroot_in policy write lab-data - <<'EOF'
path "kv/data/lab-data/*" {
  capabilities = ["read"]
}
EOF
  vroot write auth/kubernetes/role/lab-data \
    bound_service_account_names=eso-vault \
    bound_service_account_namespaces=lab-data \
    audience=vault \
    token_policies=lab-data \
    token_ttl=15m
}

# Сид секретов — только если их ещё нет (повторный запуск ничего не перезапишет).
seed() {
  local pw
  if ! vroot kv get kv/lab-data/pg-app >/dev/null 2>&1; then
    pw=$(openssl rand -base64 24 | tr -d '/+=')
    printf '%s' "$pw" | jq -Rs '{username:"app",password:.}' | vroot_in kv put kv/lab-data/pg-app - >/dev/null
    echo "seeded kv/lab-data/pg-app"
  fi
  if ! vroot kv get kv/lab-data/pg-reporting >/dev/null 2>&1; then
    pw=$(openssl rand -base64 24 | tr -d '/+=')
    printf '%s' "$pw" | jq -Rs '{username:"reporting",password:.}' | vroot_in kv put kv/lab-data/pg-reporting - >/dev/null
    echo "seeded kv/lab-data/pg-reporting"
  fi
  if ! vroot kv get kv/lab-data/s3-cnpg >/dev/null 2>&1; then
    jq -n --arg id "cnpg$(openssl rand -hex 8)" --arg key "$(openssl rand -hex 24)" \
      '{access_key_id:$id, secret_access_key:$key}' | vroot_in kv put kv/lab-data/s3-cnpg - >/dev/null
    echo "seeded kv/lab-data/s3-cnpg (add it to SeaweedFS: lab/seaweedfs-identity.sh)"
  fi
}

case "${1:-all}" in
  unseal) unseal ;;
  all) init; unseal; configure; seed ;;
  *) echo "usage: $0 [all|unseal]" >&2; exit 2 ;;
esac
