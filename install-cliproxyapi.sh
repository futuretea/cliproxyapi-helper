#!/usr/bin/env bash
set -Eeuo pipefail

readonly service_name="cli-proxy-api.service"
readonly service_user="cliproxy"
readonly config_dir="/etc/cli-proxy-api"
readonly tls_dir="${config_dir}/tls"
readonly management_env="${config_dir}/management.env"
readonly state_dir="/var/lib/cli-proxy-api"
readonly config_path="${state_dir}/config.yaml"
readonly legacy_config_path="${config_dir}/config.yaml"
readonly static_dir="${state_dir}/static"
readonly binary_path="/usr/local/bin/cli-proxy-api"
readonly service_path="/etc/systemd/system/${service_name}"
readonly hook_path="/etc/letsencrypt/renewal-hooks/deploy/50-cliproxyapi"

public_ip=""
listen_port=443
requested_version="${CLIPROXY_VERSION:-v8.0.20}"
acme_email="${ACME_EMAIL:-}"
management_mode="preserve"
management_enabled=false
download_dir=""
release_tag=""
client_api_key=""

log() {
  printf '[cliproxyapi] %s\n' "$*" >&2
}

die() {
  printf '[cliproxyapi] ERROR: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  printf '[cliproxyapi] ERROR: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}

usage() {
  printf '%s\n' 'Install CLIProxyAPI with HTTPS and systemd.' '' \
    'USAGE' \
    '  install-cliproxyapi.sh --ip <public-ipv4> [options]' '' \
    'OPTIONS' \
    '  --management-port <port>       Shared HTTPS port for the management UI and API (default: 443)' \
    '  --enable-remote-management     Expose /management.html and the authenticated management API' \
    '  --disable-remote-management    Disable the management UI and management API' \
    '  --cliproxy-version <tag|latest> CLIProxyAPI release (default: v8.0.20)' \
    "  --acme-email <email>            Register the Let's Encrypt account with an email address" \
    '  --ip <public-ipv4>              Public IPv4 address assigned to the host' \
    '  -h, --help                      Show this help' '' \
    'EXAMPLES' \
    '  install-cliproxyapi.sh --ip 203.0.113.10 --enable-remote-management' \
    '  install-cliproxyapi.sh --ip 203.0.113.10 --management-port 8443'
}

require_value() {
  local flag="$1" value="${2:-}"
  [[ -n "$value" && "$value" != --* ]] || usage_error "${flag} requires a value."
}

parse_args() {
  while (($#)); do
    case "$1" in
      --ip) require_value "$1" "${2:-}"; public_ip="$2"; shift 2 ;;
      --management-port) require_value "$1" "${2:-}"; listen_port="$2"; shift 2 ;;
      --enable-remote-management)
        [[ "$management_mode" != disable ]] || usage_error "Remote management flags are mutually exclusive."
        management_mode="enable"; shift ;;
      --disable-remote-management)
        [[ "$management_mode" != enable ]] || usage_error "Remote management flags are mutually exclusive."
        management_mode="disable"; shift ;;
      --cliproxy-version) require_value "$1" "${2:-}"; requested_version="$2"; shift 2 ;;
      --acme-email) require_value "$1" "${2:-}"; acme_email="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) usage_error "Unknown option: $1" ;;
    esac
  done
}

parse_and_validate_args() {
  parse_args "$@"
  [[ -n "$public_ip" ]] || usage_error "--ip is required."
}

cleanup() {
  if [[ -n "$download_dir" && "$download_dir" == /tmp/cliproxyapi-install.* && -d "$download_dir" ]]; then
    find "$download_dir" -type f -delete
    find "$download_dir" -depth -type d -empty -delete
  fi
}
trap cleanup EXIT

validate_common_host() {
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

validate_install_host() {
  validate_common_host
  [[ "$listen_port" =~ ^[0-9]+$ ]] || die "Management port must be numeric."
  ((listen_port >= 1 && listen_port <= 65535)) || die "Management port must be between 1 and 65535."
  command -v apt-get >/dev/null || die "This installer requires apt-get."

  local os_id listener
  os_id="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')"
  [[ "$os_id" == ubuntu ]] || die "This installer currently supports Ubuntu only."
  ip -4 -o address show scope global | awk '{sub(/\/.*/, "", $4); print $4}' \
    | grep -Fqx -- "$public_ip" || die "${public_ip} is not assigned to a global interface on this host."

  listener="$(ss -H -ltnp "sport = :${listen_port}")"
  if [[ -n "$listener" && "$listener" != *cli-proxy-api* ]]; then
    die "Port ${listen_port} is already used by another process."
  fi
  if ss -H -ltn 'sport = :80' | grep -q .; then
    die "Port 80 must remain free for the Certbot standalone HTTP-01 challenge."
  fi
}

install_dependencies() {
  log "Installing operating-system dependencies"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl iproute2 openssl python3 snapd tar util-linux
  systemctl enable --now snapd.socket
  timeout 180 snap wait system seed.loaded

  if snap list certbot >/dev/null 2>&1; then
    snap refresh certbot
  else
    snap install certbot --classic
  fi

  local certbot_version
  certbot_version="$(/snap/bin/certbot --version | awk '{print $2}')"
  dpkg --compare-versions "$certbot_version" ge 5.4.0 \
    || die "Certbot 5.4.0 or newer is required for IP certificates."
  systemctl enable --now snap.certbot.renew.timer
}

resolve_release() {
  local asset_arch release_number asset_name expected actual
  case "$(uname -m)" in
    x86_64) asset_arch="amd64" ;;
    aarch64|arm64) asset_arch="aarch64" ;;
    *) die "Unsupported CPU architecture: $(uname -m)" ;;
  esac

  if [[ "$requested_version" == latest ]]; then
    release_tag="$(curl -fsSL --retry 3 https://api.github.com/repos/router-for-me/CLIProxyAPI/releases/latest \
      | python3 -c 'import json, sys; print(json.load(sys.stdin)["tag_name"])')"
  else
    release_tag="$requested_version"
  fi
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid release tag: ${release_tag}"

  release_number="${release_tag#v}"
  asset_name="CLIProxyAPI_${release_number}_linux_${asset_arch}.tar.gz"
  download_dir="$(mktemp -d /tmp/cliproxyapi-install.XXXXXX)"
  log "Downloading CLIProxyAPI ${release_tag}"
  curl -fsSL --retry 3 --retry-all-errors -o "${download_dir}/checksums.txt" \
    "https://github.com/router-for-me/CLIProxyAPI/releases/download/${release_tag}/checksums.txt"
  curl -fsSL --retry 3 --retry-all-errors -o "${download_dir}/${asset_name}" \
    "https://github.com/router-for-me/CLIProxyAPI/releases/download/${release_tag}/${asset_name}"
  expected="$(awk -v name="$asset_name" '$2 == name {print $1}' "${download_dir}/checksums.txt")"
  actual="$(sha256sum "${download_dir}/${asset_name}" | awk '{print $1}')"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ && "$actual" == "$expected" ]] \
    || die "Release checksum verification failed."

  tar -xzf "${download_dir}/${asset_name}" -C "$download_dir" cli-proxy-api
  [[ -f "${download_dir}/cli-proxy-api" && ! -L "${download_dir}/cli-proxy-api" ]] \
    || die "Release archive did not contain a regular CLIProxyAPI binary."
  chmod 0755 "${download_dir}/cli-proxy-api"
  install -o root -g root -m 0755 "${download_dir}/cli-proxy-api" "$binary_path"
}

write_config_from_stdin() {
  local temporary
  temporary="$(runuser -u "$service_user" -- mktemp "${state_dir}/.config.yaml.XXXXXX")"
  if runuser -u "$service_user" -- tee -- "$temporary" >/dev/null \
    && runuser -u "$service_user" -- chmod 0600 -- "$temporary" \
    && runuser -u "$service_user" -- mv -fT -- "$temporary" "$config_path"; then
    return 0
  fi
  runuser -u "$service_user" -- unlink -- "$temporary" 2>/dev/null || true
  return 1
}

prepare_runtime() {
  getent group "$service_user" >/dev/null || groupadd --system "$service_user"
  id -u "$service_user" >/dev/null 2>&1 \
    || useradd --system --gid "$service_user" --home-dir "$state_dir" --no-create-home --shell /usr/sbin/nologin "$service_user"

  install -d -o root -g root -m 0755 "$config_dir"
  install -d -o root -g "$service_user" -m 0750 "$tls_dir"
  install -d -o "$service_user" -g "$service_user" -m 0750 "$state_dir"
  runuser -u "$service_user" -- install -d -m 0750 -- "${state_dir}/auth" "$static_dir"
  install -d -o root -g root -m 0755 "$(dirname "$hook_path")"

  if [[ ! -e "$config_path" && -f "$legacy_config_path" ]]; then
    log "Migrating the managed configuration to writable service state"
    write_config_from_stdin <"$legacy_config_path"
  fi
}

provision_certificate() {
  install -o root -g root -m 0750 /dev/stdin "$hook_path" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
expected_lineage="/etc/letsencrypt/live/${public_ip}"
lineage="\${RENEWED_LINEAGE:-\$expected_lineage}"
[[ "\$lineage" == "\$expected_lineage" ]] || exit 0
/usr/bin/install -d -o root -g ${service_user} -m 0750 ${tls_dir}
/usr/bin/install -o root -g ${service_user} -m 0640 "\${lineage}/fullchain.pem" ${tls_dir}/fullchain.pem
/usr/bin/install -o root -g ${service_user} -m 0640 "\${lineage}/privkey.pem" ${tls_dir}/privkey.pem
if /usr/bin/systemctl is-active --quiet ${service_name}; then
  /usr/bin/systemctl restart ${service_name}
fi
EOF

  local certbot_args
  certbot_args=(certonly --non-interactive --agree-tos --standalone
    --preferred-challenges http-01 --preferred-profile shortlived
    --ip-address "$public_ip" --cert-name "$public_ip" --keep-until-expiring)
  if [[ -n "$acme_email" ]]; then
    certbot_args+=(--email "$acme_email")
  else
    certbot_args+=(--register-unsafely-without-email)
  fi

  log "Ensuring a short-lived Let's Encrypt certificate for ${public_ip}"
  /snap/bin/certbot "${certbot_args[@]}"
  RENEWED_LINEAGE="/etc/letsencrypt/live/${public_ip}" "$hook_path"
  openssl x509 -in "${tls_dir}/fullchain.pem" -noout -checkip "$public_ip" >/dev/null
  openssl x509 -in "${tls_dir}/fullchain.pem" -noout -checkend 86400 >/dev/null
}

read_managed_management_state() {
  runuser -u "$service_user" -- python3 - "$config_path" <<'PY'
import os
import re
import stat
import sys

path = sys.argv[1]
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(descriptor, encoding="utf-8") as handle:
    if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
        raise SystemExit("managed configuration is not a regular file")
    lines = handle.readlines()

if not any("# Managed by install-cliproxyapi.sh." in line for line in lines):
    raise SystemExit("configuration is not managed by install-cliproxyapi.sh")

allow_remote = None
disable_panel = None
in_remote = False
for line in lines:
    if re.match(r"^remote-management\s*:", line):
        in_remote = True
        continue
    if in_remote and line and not line[0].isspace() and not line.lstrip().startswith("#"):
        break
    if in_remote:
        match = re.match(r"^\s+(allow-remote|disable-control-panel)\s*:\s*(true|false)\s*(?:#.*)?$", line)
        if match and match.group(1) == "allow-remote":
            allow_remote = match.group(2)
        elif match:
            disable_panel = match.group(2)

if (allow_remote, disable_panel) == ("true", "false"):
    print("enabled")
elif (allow_remote, disable_panel) == ("false", "true"):
    print("disabled")
else:
    print("mixed")
PY
}

configure_management() {
  local preserved_state
  case "$management_mode" in
    enable) management_enabled=true ;;
    disable) management_enabled=false ;;
    preserve)
      if [[ -e "$config_path" ]]; then
        preserved_state="$(read_managed_management_state)" \
          || die "Unable to read the managed remote-management state."
        case "$preserved_state" in
          enabled) management_enabled=true ;;
          disabled) management_enabled=false ;;
          *)
            die "Managed remote-management settings are mixed; pass an explicit enable or disable flag."
            ;;
        esac
      else
        management_enabled=false
      fi
      ;;
  esac

  if [[ "$management_enabled" == true ]]; then
    if [[ ! -s "$management_env" ]]; then
      local management_password
      management_password="$(openssl rand -hex 32)"
      install -o root -g root -m 0600 /dev/stdin "$management_env" <<EOF
MANAGEMENT_PASSWORD=${management_password}
EOF
      management_password=""
    fi
  elif [[ -e "$management_env" || -L "$management_env" ]]; then
    unlink "$management_env"
  fi
}

render_new_config() {
  client_api_key="$(openssl rand -hex 32)"
  local allow_remote disable_panel
  if [[ "$management_enabled" == true ]]; then
    allow_remote=true
    disable_panel=false
  else
    allow_remote=false
    disable_panel=true
  fi

  write_config_from_stdin <<EOF
# Managed by install-cliproxyapi.sh. The API key was generated during installation.
host: "${public_ip}"
port: ${listen_port}
tls:
  enable: true
  cert: "${tls_dir}/fullchain.pem"
  key: "${tls_dir}/privkey.pem"
remote-management:
  allow-remote: ${allow_remote}
  secret-key: ""
  disable-control-panel: ${disable_panel}
auth-dir: "${state_dir}/auth"
api-keys:
  - "${client_api_key}"
plugins:
  enabled: false
debug: false
logging-to-file: false
usage-statistics-enabled: false
EOF
}

update_managed_config() {
  local enabled_value=false disabled_value=true
  if [[ "$management_enabled" == true ]]; then
    enabled_value=true
    disabled_value=false
  fi

  runuser -u "$service_user" -- python3 - \
    "$config_path" "$public_ip" "$listen_port" "$enabled_value" "$disabled_value" \
    >"${download_dir}/config.yaml.updated" <<'PY'
import os
import re
import stat
import sys

path, host, port, allow_remote, disable_panel = sys.argv[1:]
descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(descriptor, encoding="utf-8") as handle:
    if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
        raise SystemExit("managed configuration is not a regular file")
    lines = handle.readlines()

if not any("# Managed by install-cliproxyapi.sh." in line for line in lines):
    raise SystemExit("refusing to overwrite an unmanaged configuration")

seen = {"host": False, "port": False, "allow": False, "panel": False}
in_remote = False
for index, line in enumerate(lines):
    if re.match(r"^host\s*:", line):
        lines[index] = f'host: "{host}"\n'
        seen["host"] = True
    elif re.match(r"^port\s*:", line):
        lines[index] = f"port: {port}\n"
        seen["port"] = True
    elif re.match(r"^remote-management\s*:", line):
        in_remote = True
    elif in_remote and line and not line[0].isspace() and not line.lstrip().startswith("#"):
        in_remote = False

    if in_remote and re.match(r"^\s+allow-remote\s*:", line):
        indent = line[: len(line) - len(line.lstrip())]
        lines[index] = f"{indent}allow-remote: {allow_remote}\n"
        seen["allow"] = True
    elif in_remote and re.match(r"^\s+disable-control-panel\s*:", line):
        indent = line[: len(line) - len(line.lstrip())]
        lines[index] = f"{indent}disable-control-panel: {disable_panel}\n"
        seen["panel"] = True

missing = [name for name, present in seen.items() if not present]
if missing:
    raise SystemExit("managed config is missing required fields: " + ", ".join(missing))

sys.stdout.writelines(lines)
PY
  write_config_from_stdin <"${download_dir}/config.yaml.updated"
}

configure_application() {
  if [[ -e "$config_path" ]]; then
    update_managed_config
  else
    render_new_config
  fi

  local capability_directives
  if ((listen_port < 1024)); then
    capability_directives=$'AmbientCapabilities=CAP_NET_BIND_SERVICE\nCapabilityBoundingSet=CAP_NET_BIND_SERVICE'
  else
    capability_directives='CapabilityBoundingSet='
  fi

  install -o root -g root -m 0644 /dev/stdin "$service_path" <<EOF
[Unit]
Description=CLIProxyAPI server
Documentation=https://github.com/router-for-me/CLIProxyAPI
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${service_user}
Group=${service_user}
Environment=HOME=${state_dir}
Environment=MANAGEMENT_STATIC_PATH=${static_dir}
EnvironmentFile=-${management_env}
WorkingDirectory=${state_dir}
ExecStartPre=/usr/bin/test -r ${config_path}
ExecStartPre=/usr/bin/test -r ${tls_dir}/fullchain.pem
ExecStartPre=/usr/bin/test -r ${tls_dir}/privkey.pem
ExecStart=${binary_path} --config ${config_path}
Restart=on-failure
RestartSec=5s
UMask=0077
${capability_directives}
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectControlGroups=true
ProtectHome=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectSystem=strict
ReadWritePaths=${state_dir}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$service_name"
  systemctl restart "$service_name"
}

base_url() {
  if [[ "$listen_port" == 443 ]]; then
    printf 'https://%s' "$public_ip"
  else
    printf 'https://%s:%s' "$public_ip" "$listen_port"
  fi
}

read_client_api_key() {
  runuser -u "$service_user" -- python3 - "$config_path" <<'PY'
import os
import re
import stat
import sys

in_keys = False
descriptor = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW)
with os.fdopen(descriptor, encoding="utf-8") as handle:
    if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
        raise SystemExit("managed configuration is not a regular file")
    for line in handle:
        if re.match(r"^api-keys\s*:", line):
            in_keys = True
            continue
        if in_keys and line and not line[0].isspace():
            break
        if in_keys:
            match = re.match(r"^\s*-\s*[\"']?([^\"'\n]+)", line)
            if match:
                print(match.group(1).strip())
                break
PY
}

verify_installation() {
  systemctl is-enabled --quiet "$service_name"
  systemctl is-active --quiet "$service_name"
  systemctl is-enabled --quiet snap.certbot.renew.timer
  systemctl is-active --quiet snap.certbot.renew.timer

  local url unauthenticated_status authenticated_status key
  url="$(base_url)"
  unauthenticated_status="$(curl -s --retry 10 --retry-connrefused --retry-delay 1 --retry-max-time 20 \
    -o /dev/null -w '%{http_code}' "${url}/v1/models")" \
    || die "API did not become reachable at ${url}."
  [[ "$unauthenticated_status" == 401 ]] \
    || die "Expected an unauthenticated API 401 response, got ${unauthenticated_status}."

  key="$(read_client_api_key)"
  [[ -n "$key" ]] || die "No client API key was found in the managed configuration."
  authenticated_status="$(
    printf 'header = "Authorization: Bearer %s"\n' "$key" \
      | curl -sS --config - -o /dev/null -w '%{http_code}' "${url}/v1/models"
  )"
  key=""
  [[ "$authenticated_status" == 200 ]] \
    || die "Expected an authenticated API 200 response, got ${authenticated_status}."

  if [[ "$management_enabled" == true ]]; then
    local page_status management_unauthenticated management_authenticated management_password
    page_status="$(curl -sS -o /dev/null -w '%{http_code}' "${url}/management.html")"
    [[ "$page_status" == 200 ]] || die "Expected management.html to return 200, got ${page_status}."
    management_unauthenticated="$(curl -sS -o /dev/null -w '%{http_code}' "${url}/v0/management/config")"
    [[ "$management_unauthenticated" == 401 ]] \
      || die "Expected an unauthenticated management 401 response, got ${management_unauthenticated}."
    management_password="$(sed -n 's/^MANAGEMENT_PASSWORD=//p' "$management_env")"
    management_authenticated="$(
      printf 'header = "X-Management-Key: %s"\n' "$management_password" \
        | curl -sS --config - -o /dev/null -w '%{http_code}' "${url}/v0/management/config"
    )"
    management_password=""
    [[ "$management_authenticated" == 200 ]] \
      || die "Expected an authenticated management 200 response, got ${management_authenticated}."
  fi

  log "Testing automated certificate renewal"
  /snap/bin/certbot renew --cert-name "$public_ip" --dry-run --no-random-sleep-on-renew
  if [[ -e "$legacy_config_path" || -L "$legacy_config_path" ]]; then
    unlink "$legacy_config_path"
  fi

  printf 'API endpoint: %s\n' "$url"
  if [[ "$management_enabled" == true ]]; then
    printf 'Management UI: %s/management.html\n' "$url"
    printf 'Management password: stored in %s (not printed)\n' "$management_env"
  else
    printf 'Management UI: disabled\n'
  fi
  printf 'Client API key: stored in %s (not printed)\n' "$config_path"
  printf 'Version: %s\nService: %s (enabled and active)\n' "$release_tag" "$service_name"
}

run_install() {
  validate_install_host
  install_dependencies
  resolve_release
  prepare_runtime
  provision_certificate
  configure_management
  configure_application
  verify_installation
}

parse_and_validate_args "$@"
run_install
