#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# IndraQ Route 53 Health Check Firewall
# Version: 2.1.0
# ==============================================================================
#
# Securely allows:
#   1) AWS Route 53 health-check IP ranges
#   2) Optional trusted public test source IP/CIDRs
#
# to reach a Docker-published health endpoint.
#
# Default convention:
#   Container name : healthcheck
#   Host port      : 8877/tcp
#   Container port : 8877/tcp
#   Health path    : /health
#
# Supported commands:
#   sudo ./indraq-route53-healthcheck-firewall.sh
#   sudo ./indraq-route53-healthcheck-firewall.sh --apply
#   sudo ./indraq-route53-healthcheck-firewall.sh --uninstall
#   sudo ./indraq-route53-healthcheck-firewall.sh --reset
#   ./indraq-route53-healthcheck-firewall.sh --help
#
# IMPORTANT:
# TEST_SOURCE_CIDRS means the public IP(s) traffic comes FROM.
# It is NOT the server's own public destination IP.
#
# Docker must already be installed and the healthcheck container must already
# be running before this installer is executed.
# ==============================================================================

VERSION="2.1.0"

INSTALL_PATH="/usr/local/sbin/indraq-route53-healthcheck-firewall"
CONFIG_DIR="/etc/indraq"
CONFIG_FILE="${CONFIG_DIR}/route53-healthcheck.conf"

SERVICE_NAME="indraq-route53-healthcheck-firewall.service"
TIMER_NAME="indraq-route53-healthcheck-firewall.timer"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
TIMER_FILE="/etc/systemd/system/${TIMER_NAME}"

CHAIN="INDRAQ-R53-HEALTH"
IPSET="route53_healthchecks"
IPSET_TMP="${IPSET}_new"

DEFAULT_PORT="8877"
DEFAULT_CONTAINER_NAME="healthcheck"
DEFAULT_CONTAINER_PORT="8877"

CONFIG_LOADED=0

# ------------------------------------------------------------------------------
# Preserve explicit environment overrides.
#
# Precedence:
#   defaults < saved config < explicitly supplied environment variables
# ------------------------------------------------------------------------------

capture_override() {
  local name="$1"

  if [[ ${!name+x} ]]; then
    printf -v "OVERRIDE_${name}_SET" '%s' "1"
    printf -v "OVERRIDE_${name}_VALUE" '%s' "${!name}"
  else
    printf -v "OVERRIDE_${name}_SET" '%s' "0"
    printf -v "OVERRIDE_${name}_VALUE" '%s' ""
  fi
}

for _name in PORT CONTAINER_NAME CONTAINER_PORT HOST_IP PUBLIC_IP WAN_IF TEST_SOURCE_CIDRS; do
  capture_override "${_name}"
done
unset _name

set_defaults_and_overrides() {
  PORT="${DEFAULT_PORT}"
  CONTAINER_NAME="${DEFAULT_CONTAINER_NAME}"
  CONTAINER_PORT="${DEFAULT_CONTAINER_PORT}"
  HOST_IP=""
  PUBLIC_IP=""
  WAN_IF=""
  TEST_SOURCE_CIDRS=""

  local name flag value
  for name in PORT CONTAINER_NAME CONTAINER_PORT HOST_IP PUBLIC_IP WAN_IF TEST_SOURCE_CIDRS; do
    flag="OVERRIDE_${name}_SET"
    value="OVERRIDE_${name}_VALUE"

    if [[ "${!flag}" == "1" ]]; then
      printf -v "${name}" '%s' "${!value}"
    fi
  done
}

set_defaults_and_overrides

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

log() {
  printf '[indraq-r53-health] %s\n' "$*"
}

warn() {
  printf '[indraq-r53-health] WARNING: %s\n' "$*" >&2
}

die() {
  printf '[indraq-r53-health] ERROR: %s\n' "$*" >&2
  exit 1
}

need_root() {
  [[ "${EUID}" -eq 0 ]] || die "Run this command with sudo/root."
}

# ------------------------------------------------------------------------------
# Validation
# ------------------------------------------------------------------------------

valid_ipv4() {
  local ip="$1"
  local IFS=.
  local -a octets
  local o

  read -r -a octets <<< "${ip}"
  [[ "${#octets[@]}" -eq 4 ]] || return 1

  for o in "${octets[@]}"; do
    [[ "${o}" =~ ^[0-9]{1,3}$ ]] || return 1
    (( 10#${o} <= 255 )) || return 1
  done

  return 0
}

normalize_cidr_list() {
  local input="$1"
  local public_ip="${2:-}"
  local raw="${input//,/ }"
  local item ip prefix
  local result=""

  for item in ${raw}; do
    [[ -n "${item}" ]] || continue

    if [[ "${item}" == */* ]]; then
      ip="${item%/*}"
      prefix="${item#*/}"
    else
      ip="${item}"
      prefix="32"
    fi

    valid_ipv4 "${ip}" || return 1
    [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#${prefix} <= 32 )) || return 1

    # The most common configuration mistake: putting the server's own public
    # destination IP into the trusted SOURCE field.
    if [[ -n "${public_ip}" && "${ip}" == "${public_ip}" && "${prefix}" == "32" ]]; then
      return 2
    fi

    [[ -z "${result}" ]] || result+=" "
    result+="${ip}/${prefix}"
  done

  printf '%s' "${result}"
}

validate_settings() {
  [[ "${PORT}" =~ ^[0-9]+$ ]] || die "PORT must be numeric."
  [[ "${CONTAINER_PORT}" =~ ^[0-9]+$ ]] || die "CONTAINER_PORT must be numeric."

  (( 10#${PORT} >= 1 && 10#${PORT} <= 65535 )) \
    || die "PORT must be between 1 and 65535."

  (( 10#${CONTAINER_PORT} >= 1 && 10#${CONTAINER_PORT} <= 65535 )) \
    || die "CONTAINER_PORT must be between 1 and 65535."

  [[ "${CONTAINER_NAME}" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || die "CONTAINER_NAME contains unsupported characters."

  if [[ -n "${HOST_IP}" ]]; then
    valid_ipv4 "${HOST_IP}" || die "Invalid HOST_IP: ${HOST_IP}"
  fi

  if [[ -n "${PUBLIC_IP}" ]]; then
    valid_ipv4 "${PUBLIC_IP}" || die "Invalid PUBLIC_IP: ${PUBLIC_IP}"
  fi

  if [[ -n "${WAN_IF}" ]]; then
    [[ "${WAN_IF}" =~ ^[A-Za-z0-9_.:-]+$ ]] \
      || die "WAN_IF contains unsupported characters."
  fi

  if [[ -n "${TEST_SOURCE_CIDRS}" ]]; then
    local normalized rc
    set +e
    normalized="$(normalize_cidr_list "${TEST_SOURCE_CIDRS}" "${PUBLIC_IP}")"
    rc=$?
    set -e

    if [[ "${rc}" -eq 2 ]]; then
      die "TEST_SOURCE_CIDRS contains the server's own PUBLIC_IP (${PUBLIC_IP}). Enter the public IP you are connecting FROM, not the server IP you are connecting TO."
    elif [[ "${rc}" -ne 0 ]]; then
      die "Invalid TEST_SOURCE_CIDRS: ${TEST_SOURCE_CIDRS}"
    fi

    TEST_SOURCE_CIDRS="${normalized}"
  fi
}

# ------------------------------------------------------------------------------
# Saved config
# ------------------------------------------------------------------------------

load_saved_config() {
  [[ -f "${CONFIG_FILE}" ]] || return 0

  # The file is created by this script as root and contains only our variables.
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
  CONFIG_LOADED=1

  # Re-apply explicit environment variables so they override saved config.
  local name flag value
  for name in PORT CONTAINER_NAME CONTAINER_PORT HOST_IP PUBLIC_IP WAN_IF TEST_SOURCE_CIDRS; do
    flag="OVERRIDE_${name}_SET"
    value="OVERRIDE_${name}_VALUE"

    if [[ "${!flag}" == "1" ]]; then
      printf -v "${name}" '%s' "${!value}"
    fi
  done

  validate_settings
}

write_config() {
  mkdir -p "${CONFIG_DIR}"

  cat > "${CONFIG_FILE}" <<EOF
PORT="${PORT}"
CONTAINER_NAME="${CONTAINER_NAME}"
CONTAINER_PORT="${CONTAINER_PORT}"
HOST_IP="${HOST_IP}"
PUBLIC_IP="${PUBLIC_IP}"
WAN_IF="${WAN_IF}"
TEST_SOURCE_CIDRS="${TEST_SOURCE_CIDRS}"
EOF

  chown root:root "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"
}

# ------------------------------------------------------------------------------
# Interactive setup
# ------------------------------------------------------------------------------

prompt_fresh_install() {
  if [[ ! -t 0 ]]; then
    [[ -n "${PUBLIC_IP}" ]] \
      || die "PUBLIC_IP is required for non-interactive installation."
    validate_settings
    return 0
  fi

  echo
  echo "=============================================================="
  echo " IndraQ Route 53 Health Check Setup"
  echo "=============================================================="
  echo

  if [[ -z "${PUBLIC_IP}" ]]; then
    while true; do
      read -r -p "Enter this server/site PUBLIC IP (example 110.225.255.65): " PUBLIC_IP

      if valid_ipv4 "${PUBLIC_IP}"; then
        break
      fi

      echo "Invalid IPv4 address. Please try again."
    done
  fi

  echo
  echo "AWS Route 53 will connect TO:"
  echo "  http://${PUBLIC_IP}:${PORT}/health"
  echo
  echo "Optional manual testing"
  echo "-----------------------"
  echo "Enter the PUBLIC SOURCE IP of the internet connection you will"
  echo "test FROM. Leave it blank if you only want AWS Route 53 allowed."
  echo
  echo "Example:"
  echo "  Server public IP (destination): ${PUBLIC_IP}"
  echo "  Testing connection public IP:   49.36.10.20"
  echo "  Value to enter:                  49.36.10.20/32"
  echo
  echo "DO NOT enter ${PUBLIC_IP} below."
  echo

  if [[ -z "${TEST_SOURCE_CIDRS}" ]]; then
    while true; do
      local entered normalized rc
      read -r -p "Trusted test SOURCE IP/CIDR(s) [optional]: " entered

      if [[ -z "${entered}" ]]; then
        TEST_SOURCE_CIDRS=""
        break
      fi

      set +e
      normalized="$(normalize_cidr_list "${entered}" "${PUBLIC_IP}")"
      rc=$?
      set -e

      if [[ "${rc}" -eq 0 ]]; then
        TEST_SOURCE_CIDRS="${normalized}"
        break
      elif [[ "${rc}" -eq 2 ]]; then
        echo
        echo "That is the server's own public destination IP."
        echo "Enter the public IP you are connecting FROM instead."
        echo
      else
        echo
        echo "Invalid value. Example: 49.36.10.20/32"
        echo
      fi
    done
  fi

  validate_settings
}

# ------------------------------------------------------------------------------
# Dependencies / network / Docker
# ------------------------------------------------------------------------------

install_dependencies() {
  command -v docker >/dev/null 2>&1 \
    || die "Docker is not installed. Install Docker and start the healthcheck container first."

  command -v systemctl >/dev/null 2>&1 \
    || die "systemd/systemctl is required."

  command -v ip >/dev/null 2>&1 \
    || die "The 'ip' command is required (normally provided by iproute2)."

  local -a packages=()

  command -v curl >/dev/null 2>&1 || packages+=("curl")
  command -v jq >/dev/null 2>&1 || packages+=("jq")
  command -v ipset >/dev/null 2>&1 || packages+=("ipset")
  command -v iptables >/dev/null 2>&1 || packages+=("iptables")

  if (( ${#packages[@]} == 0 )); then
    log "All required helper packages are already installed."
    return 0
  fi

  command -v apt-get >/dev/null 2>&1 \
    || die "Missing packages (${packages[*]}) and apt-get is unavailable."

  log "Installing required packages: ${packages[*]}"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
}

detect_network() {
  if [[ -z "${WAN_IF}" ]]; then
    WAN_IF="$(ip -4 route show default | awk 'NR==1 {print $5}')"
  fi

  [[ -n "${WAN_IF}" ]] \
    || die "Could not detect the primary network interface. Set WAN_IF manually."

  if [[ -z "${HOST_IP}" ]]; then
    HOST_IP="$(
      ip -4 addr show dev "${WAN_IF}" scope global \
        | awk '/inet / {sub(/\/.*/, "", $2); print $2; exit}'
    )"
  fi

  [[ -n "${HOST_IP}" ]] \
    || die "Could not detect the server IPv4 address. Set HOST_IP manually."

  validate_settings
}

wait_for_docker() {
  local i running

  for i in {1..30}; do
    if iptables -S DOCKER-USER >/dev/null 2>&1 \
       && docker inspect "${CONTAINER_NAME}" >/dev/null 2>&1; then

      running="$(
        docker inspect -f '{{.State.Running}}' "${CONTAINER_NAME}" 2>/dev/null \
          || true
      )"

      if [[ "${running}" == "true" ]]; then
        return 0
      fi
    fi

    sleep 1
  done

  die "Docker/DOCKER-USER is not ready or container '${CONTAINER_NAME}' is not running."
}

verify_docker_port() {
  local mappings
  mappings="$(docker port "${CONTAINER_NAME}" "${CONTAINER_PORT}/tcp" 2>/dev/null || true)"

  [[ -n "${mappings}" ]] \
    || die "Container '${CONTAINER_NAME}' does not publish ${CONTAINER_PORT}/tcp."

  if ! grep -Eq "(:|\])${PORT}$" <<< "${mappings}"; then
    die "Docker port mismatch. Expected host port ${PORT} -> container port ${CONTAINER_PORT}. Current mapping: ${mappings//$'\n'/, }"
  fi

  log "Docker port mapping verified: ${mappings//$'\n'/, }"
}

get_container_ip() {
  docker inspect \
    -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{"\n"}}{{end}}' \
    "${CONTAINER_NAME}" 2>/dev/null \
    | awk 'NF {print; exit}'
}

local_health_test() {
  local url="http://${HOST_IP}:${PORT}/health"

  if curl --fail --silent --show-error --max-time 5 "${url}" >/dev/null; then
    log "Local health endpoint OK: ${url}"
  else
    die "Local health endpoint failed: ${url}"
  fi
}

# ------------------------------------------------------------------------------
# AWS Route 53 IP set
# ------------------------------------------------------------------------------

refresh_aws_ipset() {
  local tmp_json count
  tmp_json="$(mktemp)"

  log "Downloading current AWS ip-ranges.json..."

  if ! curl --fail --silent --show-error --location \
      --connect-timeout 10 \
      --max-time 30 \
      https://ip-ranges.amazonaws.com/ip-ranges.json \
      -o "${tmp_json}"; then

    rm -f "${tmp_json}"
    die "Could not download AWS ip-ranges.json. Existing active allowlist was not replaced."
  fi

  count="$(
    jq '[.prefixes[]
         | select(.service == "ROUTE53_HEALTHCHECKS")
         | .ip_prefix] | length' "${tmp_json}"
  )"

  if ! [[ "${count}" =~ ^[0-9]+$ ]] || (( count == 0 )); then
    rm -f "${tmp_json}"
    die "AWS returned no ROUTE53_HEALTHCHECKS IPv4 ranges. Existing allowlist was not replaced."
  fi

  ipset create "${IPSET}" hash:net family inet -exist
  ipset create "${IPSET_TMP}" hash:net family inet -exist
  ipset flush "${IPSET_TMP}"

  while IFS= read -r cidr; do
    [[ -n "${cidr}" ]] && ipset add "${IPSET_TMP}" "${cidr}" -exist
  done < <(
    jq -r '.prefixes[]
           | select(.service == "ROUTE53_HEALTHCHECKS")
           | .ip_prefix' "${tmp_json}"
  )

  # Atomic replacement. If downloading/parsing failed above, we never reach
  # this point, so the previous active set stays intact.
  ipset swap "${IPSET_TMP}" "${IPSET}"
  ipset destroy "${IPSET_TMP}" 2>/dev/null || true

  rm -f "${tmp_json}"

  log "Loaded ${count} AWS Route 53 health-check IPv4 prefixes."
}

# ------------------------------------------------------------------------------
# Firewall
# ------------------------------------------------------------------------------

remove_legacy_manual_rules() {
  # Only removes the temporary/manual rules used during development.
  # It NEVER deletes or flushes INDRAQ-DOCKER-GUARD itself.
  if ! command -v iptables >/dev/null 2>&1; then
    return 0
  fi

  if ! iptables -L INDRAQ-DOCKER-GUARD -n >/dev/null 2>&1; then
    return 0
  fi

  local n

  while true; do
    n="$(
      iptables -L INDRAQ-DOCKER-GUARD -n --line-numbers 2>/dev/null \
        | awk '/Allow Route53 health checks to Docker 8877|TEMP healthcheck 8877 test/ {print $1; exit}'
    )"

    [[ -n "${n}" ]] || break
    iptables -D INDRAQ-DOCKER-GUARD "${n}"
  done
}

ensure_firewall_rules() {
  local container_ip
  container_ip="$(get_container_ip)"

  iptables -N "${CHAIN}" 2>/dev/null || true
  iptables -F "${CHAIN}"

  # AWS Route 53 health checkers.
  #
  # We match the connection's ORIGINAL destination before Docker's DNAT.
  # We intentionally do not hard-code the Docker container IP in the rule.
  # This means recreating the container with a different internal Docker IP
  # does not invalidate the AWS firewall allow rule.
  iptables -A "${CHAIN}" \
    -i "${WAN_IF}" \
    -p tcp \
    -m set --match-set "${IPSET}" src \
    -m conntrack \
    --ctorigdst "${HOST_IP}" \
    --ctorigdstport "${PORT}" \
    -m comment --comment "AWS Route53 health checks to Docker ${PORT}" \
    -j ACCEPT

  # Optional trusted external testing sources.
  if [[ -n "${TEST_SOURCE_CIDRS}" ]]; then
    local cidr

    for cidr in ${TEST_SOURCE_CIDRS}; do
      iptables -A "${CHAIN}" \
        -i "${WAN_IF}" \
        -p tcp \
        -s "${cidr}" \
        -m conntrack \
        --ctorigdst "${HOST_IP}" \
        --ctorigdstport "${PORT}" \
        -m comment --comment "Trusted test source ${cidr} to Docker ${PORT}" \
        -j ACCEPT
    done
  fi

  # Anything not explicitly allowed here continues to your existing Docker
  # hardening policy.
  iptables -A "${CHAIN}" \
    -m comment --comment "Return unmatched traffic to existing Docker policy" \
    -j RETURN

  # Always guarantee our allowlist is first in DOCKER-USER.
  while iptables -C DOCKER-USER -j "${CHAIN}" >/dev/null 2>&1; do
    iptables -D DOCKER-USER -j "${CHAIN}"
  done

  iptables -I DOCKER-USER 1 -j "${CHAIN}"

  if [[ -n "${container_ip}" ]]; then
    log "Firewall active: ${WAN_IF} -> ${HOST_IP}:${PORT} -> Docker ${container_ip}:${CONTAINER_PORT}"
  else
    log "Firewall active: ${WAN_IF} -> ${HOST_IP}:${PORT} -> Docker '${CONTAINER_NAME}'"
  fi
}

remove_broad_ufw_rule() {
  command -v ufw >/dev/null 2>&1 || return 0

  if ufw status 2>/dev/null \
      | grep -Eq "^[[:space:]]*${PORT}(/tcp)?[[:space:]].*ALLOW"; then

    log "Removing broad UFW allow for port ${PORT}..."
    ufw --force delete allow "${PORT}" >/dev/null 2>&1 || true
    ufw --force delete allow "${PORT}/tcp" >/dev/null 2>&1 || true
  fi
}

# ------------------------------------------------------------------------------
# systemd persistence
# ------------------------------------------------------------------------------

write_systemd_units() {
  cat > "${SERVICE_FILE}" <<'EOF'
[Unit]
Description=IndraQ Route 53 health-check Docker firewall
Wants=network-online.target
After=network-online.target docker.service
Requires=docker.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/indraq/route53-healthcheck.conf
ExecStart=/usr/local/sbin/indraq-route53-healthcheck-firewall --apply
EOF

  cat > "${TIMER_FILE}" <<'EOF'
[Unit]
Description=Refresh AWS Route 53 health-check firewall allowlist daily

[Timer]
OnBootSec=2min
OnUnitActiveSec=1d
Persistent=true
Unit=indraq-route53-healthcheck-firewall.service

[Install]
WantedBy=timers.target
EOF

  chown root:root "${SERVICE_FILE}" "${TIMER_FILE}"
  chmod 0644 "${SERVICE_FILE}" "${TIMER_FILE}"
}

# ------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------

apply_rules() {
  need_root
  validate_settings
  detect_network
  wait_for_docker
  verify_docker_port
  refresh_aws_ipset
  ensure_firewall_rules
  local_health_test

  log "Current dedicated chain:"
  iptables -L "${CHAIN}" -n -v --line-numbers || true
}

install_self() {
  need_root
  install_dependencies
  validate_settings
  detect_network

  if [[ "${CONFIG_LOADED}" -eq 0 ]]; then
    prompt_fresh_install
  else
    log "Existing saved configuration detected: ${CONFIG_FILE}"
    log "Reusing it. Use --reset for a completely fresh interactive setup."
  fi

  wait_for_docker
  verify_docker_port
  remove_legacy_manual_rules

  # Install/update the canonical copy used by systemd.
  if [[ "$(readlink -f "$0")" != "${INSTALL_PATH}" ]]; then
    install -m 0755 "$0" "${INSTALL_PATH}"
  else
    chmod 0755 "${INSTALL_PATH}"
  fi

  write_config
  write_systemd_units
  remove_broad_ufw_rule

  systemctl daemon-reload
  systemctl enable "${TIMER_NAME}" >/dev/null

  # Apply immediately using the same systemd service path used later.
  systemctl restart "${SERVICE_NAME}"
  systemctl start "${TIMER_NAME}"

  log "Installed permanently."
  log "Config:  ${CONFIG_FILE}"
  log "Service: ${SERVICE_NAME}"
  log "Timer:   ${TIMER_NAME}"
  log "AWS Route 53 ranges refresh automatically once per day."
  log "Public health URL: http://${PUBLIC_IP}:${PORT}/health"
  log ""
  log "Useful checks:"
  log "  systemctl status ${SERVICE_NAME} --no-pager"
  log "  systemctl status ${TIMER_NAME} --no-pager"
  log "  iptables -L DOCKER-USER -n -v --line-numbers"
  log "  iptables -L ${CHAIN} -n -v --line-numbers"
  log "  ipset list ${IPSET}"
}

uninstall_core() {
  local remove_installed_binary="${1:-yes}"

  need_root

  log "Removing Route 53 health-check setup..."
  log "Docker, the healthcheck container, and existing Docker hardening will remain."

  systemctl disable --now "${TIMER_NAME}" >/dev/null 2>&1 || true
  systemctl stop "${SERVICE_NAME}" >/dev/null 2>&1 || true

  if command -v iptables >/dev/null 2>&1; then
    if iptables -L DOCKER-USER -n >/dev/null 2>&1; then
      while iptables -C DOCKER-USER -j "${CHAIN}" >/dev/null 2>&1; do
        iptables -D DOCKER-USER -j "${CHAIN}"
      done
    fi

    if iptables -L "${CHAIN}" -n >/dev/null 2>&1; then
      iptables -F "${CHAIN}" || true
      iptables -X "${CHAIN}" || true
    fi

    remove_legacy_manual_rules
  fi

  if command -v ipset >/dev/null 2>&1; then
    ipset destroy "${IPSET_TMP}" >/dev/null 2>&1 || true
    ipset destroy "${IPSET}" >/dev/null 2>&1 || true
  fi

  rm -f "${SERVICE_FILE}" "${TIMER_FILE}" "${CONFIG_FILE}"
  rmdir "${CONFIG_DIR}" >/dev/null 2>&1 || true

  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if [[ "${remove_installed_binary}" == "yes" ]]; then
    rm -f "${INSTALL_PATH}"
  fi

  log "Route 53 health-check setup removed."
  log "Healthcheck Docker container/app was left untouched."
  log "Existing Docker hardening was left untouched."
}

uninstall_self() {
  uninstall_core "yes"
}

reset_and_install() {
  need_root

  # Load the old config first so cleanup knows the previous custom values.
  load_saved_config
  uninstall_core "no"

  # Remove old runtime values and start a genuinely fresh wizard.
  set_defaults_and_overrides
  CONFIG_LOADED=0

  echo
  log "Starting fresh installation..."
  install_self
}

# ------------------------------------------------------------------------------
# Help
# ------------------------------------------------------------------------------

show_usage() {
  cat <<EOF
IndraQ Route 53 Health Check Firewall v${VERSION}

Usage:

  sudo $0
      Fresh install, or update an existing installation using saved config.

  sudo $0 --apply
      Load saved config, refresh AWS Route 53 IP ranges, and re-apply
      firewall rules.

  sudo $0 --uninstall
      Remove only this Route 53 health-check setup.
      Docker and existing Docker hardening remain untouched.

  sudo $0 --reset
      Remove this Route 53 setup and immediately start a fresh interactive
      installation.

  $0 --help
      Show this help.

  $0 --version
      Show version.

Optional environment overrides:

  PORT=8877
  CONTAINER_NAME=healthcheck
  CONTAINER_PORT=8877
  HOST_IP=192.168.10.101
  PUBLIC_IP=110.225.255.65
  WAN_IF=enp19s0
  TEST_SOURCE_CIDRS="49.36.10.20/32 122.160.20.10/32"

Examples:

  sudo $0

  sudo $0 --apply

  sudo TEST_SOURCE_CIDRS="49.36.10.20/32" $0 --apply

  sudo $0 --uninstall

  sudo $0 --reset
EOF
}

# ------------------------------------------------------------------------------
# Dispatcher
# ------------------------------------------------------------------------------

case "${1:-}" in
  --apply)
    need_root
    load_saved_config
    apply_rules
    ;;

  --uninstall)
    need_root
    load_saved_config
    uninstall_self
    ;;

  --reset)
    reset_and_install
    ;;

  --install|"")
    need_root
    load_saved_config
    install_self
    ;;

  --help|-h)
    show_usage
    ;;

  --version)
    echo "${VERSION}"
    ;;

  *)
    show_usage
    exit 2
    ;;
esac
