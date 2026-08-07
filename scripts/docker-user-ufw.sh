#!/usr/bin/env bash
# docker-user-ufw.sh — optional DOCKER-USER iptables helpers.
#
# Docker publishes container ports via iptables and can bypass UFW.
# This script installs a documented DOCKER-USER drop/accept pattern for
# common LibreNMS EasyDeploy ports. Review before applying on production hosts.
#
# See: https://docs.docker.com/network/packet-filtering-firewalls/
set -euo pipefail

ACTION="${1:-status}"

allow_ports=(
  "80/tcp"
  "443/tcp"
  "162/tcp"
  "162/udp"
  "514/tcp"
  "514/udp"
)

ensure_chain() {
  if ! iptables -L DOCKER-USER -n &>/dev/null; then
    echo "DOCKER-USER chain not found (is Docker running?)" >&2
    exit 1
  fi
}

status() {
  ensure_chain
  echo "=== DOCKER-USER ==="
  iptables -L DOCKER-USER -n -v --line-numbers
}

apply() {
  ensure_chain
  # Idempotent-ish: flush prior EasyDeploy markers then re-add.
  while iptables -C DOCKER-USER -m comment --comment "librenms-easydeploy-drop" -j DROP 2>/dev/null; do
    iptables -D DOCKER-USER -m comment --comment "librenms-easydeploy-drop" -j DROP || true
  done
  for spec in "${allow_ports[@]}"; do
    port="${spec%/*}"
    proto="${spec#*/}"
    while iptables -C DOCKER-USER -p "$proto" --dport "$port" -m comment --comment "librenms-easydeploy-allow" -j RETURN 2>/dev/null; do
      iptables -D DOCKER-USER -p "$proto" --dport "$port" -m comment --comment "librenms-easydeploy-allow" -j RETURN || true
    done
  done

  for spec in "${allow_ports[@]}"; do
    port="${spec%/*}"
    proto="${spec#*/}"
    iptables -I DOCKER-USER -p "$proto" --dport "$port" -m comment --comment "librenms-easydeploy-allow" -j RETURN
  done
  iptables -A DOCKER-USER -m comment --comment "librenms-easydeploy-drop" -j DROP
  echo "Applied DOCKER-USER allowlist for LibreNMS EasyDeploy ports."
  status
}

remove() {
  ensure_chain
  while iptables -C DOCKER-USER -m comment --comment "librenms-easydeploy-drop" -j DROP 2>/dev/null; do
    iptables -D DOCKER-USER -m comment --comment "librenms-easydeploy-drop" -j DROP || true
  done
  for spec in "${allow_ports[@]}"; do
    port="${spec%/*}"
    proto="${spec#*/}"
    while iptables -C DOCKER-USER -p "$proto" --dport "$port" -m comment --comment "librenms-easydeploy-allow" -j RETURN 2>/dev/null; do
      iptables -D DOCKER-USER -p "$proto" --dport "$port" -m comment --comment "librenms-easydeploy-allow" -j RETURN || true
    done
  done
  echo "Removed LibreNMS EasyDeploy DOCKER-USER rules."
  status
}

case "$ACTION" in
status) status ;;
apply)
  [[ $EUID -eq 0 ]] || {
    echo "Run as root" >&2
    exit 1
  }
  apply
  ;;
remove)
  [[ $EUID -eq 0 ]] || {
    echo "Run as root" >&2
    exit 1
  }
  remove
  ;;
*)
  echo "Usage: $0 {status|apply|remove}" >&2
  exit 1
  ;;
esac
