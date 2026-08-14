#!/usr/bin/env bash
set -Eeuo pipefail

readonly service_name="cli-proxy-api.service"
readonly service_user="cliproxy"
readonly config_dir="/etc/cli-proxy-api"
readonly state_dir="/var/lib/cli-proxy-api"
readonly binary_path="/usr/local/bin/cli-proxy-api"
readonly service_path="/etc/systemd/system/${service_name}"
readonly hook_path="/etc/letsencrypt/renewal-hooks/deploy/50-cliproxyapi"

public_ip=""
purge=false
assume_yes=false
dry_run=false

log() {
  printf '[cliproxyapi-uninstall] %s\n' "$*" >&2
}

die() {
  printf '[cliproxyapi-uninstall] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' 'Uninstall CLIProxyAPI from a systemd host.' '' \
    'USAGE' \
    '  uninstall-cliproxyapi.sh --ip <public-ipv4> [options]' '' \
    'OPTIONS' \
    '  --purge             Also remove configuration, credentials, state, certificate, user, and group' \
    '  --dry-run           Show exact targets without changing the host' \
    '  --yes               Confirm non-interactive uninstall' \
    '  --ip <public-ipv4>  Certificate identity and target host address' \
    '  -h, --help          Show this help' '' \
    'EXAMPLES' \
    '  uninstall-cliproxyapi.sh --ip 203.0.113.10 --dry-run --purge' \
    '  uninstall-cliproxyapi.sh --ip 203.0.113.10 --purge --yes'
}

usage_error() {
  printf '[cliproxyapi-uninstall] ERROR: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}

parse_args() {
  while (($#)); do
    case "$1" in
      --ip)
        [[ -n "${2:-}" && "${2:-}" != --* ]] || usage_error "--ip requires a value."
        public_ip="$2"
        shift 2
        ;;
      --purge) purge=true; shift ;;
      --dry-run) dry_run=true; shift ;;
      --yes) assume_yes=true; shift ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "Unknown option: $1" ;;
    esac
  done
  [[ -n "$public_ip" ]] || usage_error "--ip is required."
}

validate_host() {
  [[ $EUID -eq 0 ]] || die "Run this command as root."
  local octet
  local -a octets
  [[ "$public_ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
    || die "Only IPv4 addresses are supported."
  IFS=. read -r -a octets <<<"$public_ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || die "Invalid IPv4 address: ${public_ip}."
  done
  [[ "$(ps -p 1 -o comm= | tr -d ' ')" == systemd ]] || die "systemd is required."
}

print_plan() {
  printf 'Uninstall target: CLIProxyAPI on %s\n' "$public_ip"
  printf 'Remove: %s, %s, %s\n' "$service_path" "$binary_path" "$hook_path"
  if [[ "$purge" == true ]]; then
    printf 'Purge: %s, %s, certificate %s, user/group %s\n' \
      "$config_dir" "$state_dir" "$public_ip" "$service_user"
  else
    printf 'Preserve: configuration, credentials, state, certificate, user, group, Certbot, and snapd\n'
  fi
}

confirm_uninstall() {
  [[ "$dry_run" == false ]] || return 0
  [[ "$assume_yes" == false ]] || return 0
  if [[ -t 0 && -t 1 ]]; then
    local answer
    printf 'Continue? Type "uninstall" to confirm: ' >&2
    read -r answer
    [[ "$answer" == uninstall ]] || { log "Cancelled"; exit 3; }
  else
    usage_error "Non-interactive uninstall requires --yes."
  fi
}

unlink_if_present() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    unlink "$target"
  fi
}

safe_delete_tree() {
  local target="$1"
  case "$target" in
    "$config_dir"|"$state_dir") ;;
    *) die "Refusing to delete unexpected directory: ${target}" ;;
  esac
  [[ ! -L "$target" ]] || die "Refusing to recursively delete a symlink: ${target}"
  if [[ -d "$target" ]]; then
    find "$target" -xdev -depth -mindepth 1 -delete
    rmdir "$target"
  fi
}

uninstall_runtime() {
  if systemctl is-active --quiet "$service_name"; then
    systemctl stop "$service_name"
  fi
  if systemctl is-enabled --quiet "$service_name"; then
    systemctl disable "$service_name"
  fi
  unlink_if_present "$service_path"
  unlink_if_present "$binary_path"
  unlink_if_present "$hook_path"
  systemctl daemon-reload
}

purge_data() {
  if [[ -d "/etc/letsencrypt/live/${public_ip}" ]]; then
    [[ -x /snap/bin/certbot ]] || die "Certbot is required to delete certificate ${public_ip}."
    /snap/bin/certbot delete --cert-name "$public_ip" --non-interactive
  fi
  safe_delete_tree "$config_dir"
  safe_delete_tree "$state_dir"
  if id -u "$service_user" >/dev/null 2>&1; then
    userdel "$service_user"
  fi
  if getent group "$service_user" >/dev/null; then
    groupdel "$service_user"
  fi
}

parse_args "$@"
validate_host
print_plan
confirm_uninstall
if [[ "$dry_run" == true ]]; then
  printf 'Dry run complete; no changes made.\n'
  exit 0
fi

uninstall_runtime
[[ "$purge" == false ]] || purge_data
printf 'CLIProxyAPI uninstalled.\n'
[[ "$purge" == true ]] \
  || printf 'Configuration and certificate were preserved; use --purge for full removal.\n'
printf 'Shared Certbot and snapd packages were preserved.\n'
