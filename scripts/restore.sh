#!/usr/bin/env bash
# restore.sh — restore a MariaDB dump and data tarball created by backup.sh.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SQL_GZ="${1:-}"
DATA_TAR="${2:-}"

usage() {
  echo "Usage: $0 <librenms_db_YYYYMMDD_HHMMSS.sql.gz> <librenms_data_YYYYMMDD_HHMMSS.tar.gz>" >&2
  exit 1
}

[[ -n "$SQL_GZ" && -n "$DATA_TAR" ]] || usage
[[ -f "$SQL_GZ" && -f "$DATA_TAR" ]] || {
  echo "Backup files not found" >&2
  exit 1
}

cd "$INSTALL_DIR" || {
  echo "Cannot access install dir: $INSTALL_DIR" >&2
  exit 1
}
[[ -f .env ]] || {
  echo "Missing .env in $INSTALL_DIR" >&2
  exit 1
}

load_env() {
  local file="$1"
  if [[ -r "$file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  else
    set -a
    # shellcheck disable=SC1090
    source <(sudo cat "$file")
    set +a
  fi
}

load_env .env
: "${DB_ROOT_PASSWORD:?DB_ROOT_PASSWORD missing from .env}"
: "${DB_NAME:?DB_NAME missing from .env}"

echo "WARNING: This will stop containers, replace data/, and overwrite database '$DB_NAME'."
read -rp "Type 'restore' to continue: " confirm
[[ "$confirm" == "restore" ]] || {
  echo "Aborted"
  exit 1
}

echo "Stopping stack..."
sudo docker compose down

echo "Restoring data archive..."
sudo rm -rf "${INSTALL_DIR}/data"
sudo tar -xzf "$DATA_TAR" -C "$INSTALL_DIR"

echo "Starting database..."
sudo docker compose up -d db
for i in $(seq 1 90); do
  if sudo docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
    mariadb-admin ping -hlocalhost -uroot --silent &>/dev/null; then
    break
  fi
  sleep 2
  [[ $i -eq 90 ]] && {
    echo "Database did not become ready" >&2
    exit 1
  }
done

echo "Restoring SQL dump..."
gzip -dc "$SQL_GZ" |
  sudo docker compose exec -T -e MYSQL_PWD="$DB_ROOT_PASSWORD" db \
    mariadb -u root "$DB_NAME"

echo "Starting full stack..."
sudo docker compose up -d
echo "Restore complete. Verify the web UI before relying on this host."
