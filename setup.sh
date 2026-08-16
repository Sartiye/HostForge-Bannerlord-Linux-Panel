#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$REPO_DIR/configs"
ENV_FILE="$CONFIG_DIR/hostforge.env"
DEFAULT_UBUNTU_CODENAME="$(
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    printf '%s\n' "${VERSION_CODENAME:-noble}"
  elif command -v lsb_release >/dev/null 2>&1; then
    lsb_release -sc
  else
    printf 'noble\n'
  fi
)"
UBUNTU_CODENAME="${UBUNTU_CODENAME:-$DEFAULT_UBUNTU_CODENAME}"
INSTALL_DOTNET48="${HF_INSTALL_DOTNET48:-0}"
STEAMCMD_BIN="${HF_STEAMCMD:-steamcmd}"
STEAM_VALIDATE="${HF_VALIDATE:-0}"
if [[ -n "${HF_SERVICE_USER:-}" ]]; then
  HF_SERVICE_USER="$HF_SERVICE_USER"
elif [[ "${EUID}" -eq 0 ]]; then
  HF_SERVICE_USER="root"
else
  HF_SERVICE_USER="${USER:-$(id -un)}"
fi
HF_SERVICE_HOME="${HF_SERVICE_HOME:-$(getent passwd "$HF_SERVICE_USER" 2>/dev/null | awk -F: 'NR == 1 { print $6 }')}"
HF_SERVICE_HOME="${HF_SERVICE_HOME:-$HOME}"
DEFAULT_BANNERLORD_ROOT="${HF_SERVICE_HOME}/.steam/steam/steamapps/common/Mount & Blade II Dedicated Server"
WINE_PREFIX="${HF_WINEPREFIX:-${HF_SERVICE_HOME}/.wine-hostforge}"
HF_COLLECTOR_PORT="${HF_COLLECTOR_PORT:-8080}"
HF_CLOUDFLARED_ORIGIN_URL="${HF_CLOUDFLARED_ORIGIN_URL:-http://localhost:8080}"
DEFAULT_WEB_PASSWORD="${HF_DEFAULT_WEB_PASSWORD:-admin123}"
export PATH="/opt/wine-stable/bin:$PATH"
export HF_CLOUDFLARED_ORIGIN_URL

write_hostforge_env() {
  mkdir -p "$CONFIG_DIR"
  touch "$ENV_FILE"
  upsert_env_value "HF_HOSTFORGE_MODULE_DIR" "$REPO_DIR/module-hostforge"
  upsert_env_value "HF_WEB_PASSWORD" "$RESOLVED_WEB_PASSWORD"
  upsert_env_value "HF_WINEPREFIX_BASE" "${HF_SERVICE_HOME}/.wine-hostforge"
  upsert_env_value "HF_WINEPREFIX_TEMPLATE" "$WINE_PREFIX"
}

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

cleanup_winehq_apt_state() {
  $SUDO rm -f \
    /etc/apt/keyrings/winehq-archive.key \
    /etc/apt/keyrings/winehq-archive.gpg \
    /etc/apt/sources.list.d/winehq.sources \
    /etc/apt/sources.list.d/winehq-*.sources
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_value="${2:-yes}"
  local answer suffix

  if [[ ! -t 0 || ! -t 1 ]]; then
    [[ "$default_value" == "yes" ]]
    return
  fi

  if [[ "$default_value" == "yes" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    read -r -p "$prompt_text $suffix " answer
    answer="$(trim "$answer")"
    answer="${answer,,}"

    if [[ -z "$answer" ]]; then
      [[ "$default_value" == "yes" ]]
      return
    fi

    case "$answer" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        echo "Please answer y or n."
        ;;
    esac
  done
}

should_run_optional_step() {
  local env_name="$1"
  local prompt_text="$2"
  local default_value="${3:-yes}"
  local configured_value="${!env_name:-}"

  case "${configured_value,,}" in
    1|true|yes|y)
      return 0
      ;;
    0|false|no|n)
      echo "Skipping because $env_name=$configured_value."
      return 1
      ;;
  esac

  prompt_yes_no "$prompt_text" "$default_value"
}

enable_ubuntu_repository_component() {
  local component="$1"

  if command -v add-apt-repository >/dev/null 2>&1; then
    $SUDO add-apt-repository "$component" -y || echo "Warning: could not enable apt component: $component" >&2
  else
    echo "Skipping apt component '$component': add-apt-repository is unavailable." >&2
  fi
}

upsert_env_value() {
  local key="$1"
  local value="$2"
  local escaped_value

  escaped_value="${value//\\/\\\\}"
  escaped_value="${escaped_value//\"/\\\"}"

  if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
    sed -i -E "s|^[[:space:]]*${key}=.*|${key}=\"${escaped_value}\"|" "$ENV_FILE"
  else
    printf '%s="%s"\n' "$key" "$escaped_value" >> "$ENV_FILE"
  fi
}

read_env_value() {
  local key="$1"
  local line value

  if [[ ! -f "$ENV_FILE" ]]; then
    return 1
  fi

  line="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | tail -n 1 || true)"
  if [[ -z "$line" ]]; then
    return 1
  fi

  value="${line#*=}"
  value="$(trim "$value")"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  fi
  value="${value//\\\"/\"}"
  value="${value//\\\\/\\}"
  printf '%s\n' "$value"
}

resolve_web_password() {
  local configured existing default_value answer

  configured="${HF_WEB_PASSWORD:-}"
  if [[ -n "$configured" ]]; then
    printf '%s\n' "$configured"
    return
  fi

  existing="$(read_env_value HF_WEB_PASSWORD || true)"
  default_value="${existing:-$DEFAULT_WEB_PASSWORD}"

  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '%s\n' "$default_value"
    return
  fi

  echo
  read -r -s -p "HostForge web password for Cloudflared/private website (blank keeps default): " answer
  echo
  answer="$(trim "$answer")"

  if [[ -n "$answer" ]]; then
    printf '%s\n' "$answer"
  else
    printf '%s\n' "$default_value"
  fi
}

expand_path() {
  local path_value
  path_value="$(trim "$1")"

  case "$path_value" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${path_value#\~/}"
      ;;
    *)
      printf '%s\n' "$path_value"
      ;;
  esac
}

resolve_bannerlord_root() {
  local root_value="" default_root=""

  default_root="$(expand_path "$DEFAULT_BANNERLORD_ROOT")"

  if [[ -n "${HF_BANNERLORD_ROOT:-}" ]]; then
    root_value="$HF_BANNERLORD_ROOT"
  elif [[ -n "${HF_INSTALL_DIR:-}" ]]; then
    root_value="$HF_INSTALL_DIR"
  else
    root_value="$default_root"
  fi

  expand_path "$root_value"
}

steam_update() {
  local app_id="$1"
  local install_dir="${2:-}"
  local args=()

  if [[ -n "$install_dir" ]]; then
    mkdir -p "$install_dir"
    args+=("+force_install_dir" "$install_dir")
  fi

  args+=("+login" "anonymous")

  if [[ "$STEAM_VALIDATE" == "1" ]]; then
    args+=("+app_update" "$app_id validate")
  else
    args+=("+app_update" "$app_id")
  fi

  args+=("+quit")
  "$STEAMCMD_BIN" "${args[@]}"
}

install_cloudflared() {
  local deb_arch
  deb_arch="$(dpkg --print-architecture)"

  echo "Installing cloudflared from Cloudflare's apt repository"
  $SUDO mkdir -p --mode=0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | $SUDO tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
  echo "deb [arch=$deb_arch signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" | $SUDO tee /etc/apt/sources.list.d/cloudflared.list >/dev/null
  $SUDO apt-get update
  $SUDO apt-get install cloudflared -y
}

select_winehq_codename() {
  local candidate

  for candidate in "${HF_WINEHQ_CODENAME:-}" "$UBUNTU_CODENAME" noble jammy focal; do
    [[ -n "$candidate" ]] || continue
    if curl -fsI "https://dl.winehq.org/wine-builds/ubuntu/dists/${candidate}/InRelease" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return
    fi
  done
}

install_winehq() {
  local winehq_codename winehq_keyring source_path repo_file

  winehq_codename="$(select_winehq_codename || true)"
  if [[ -z "$winehq_codename" ]]; then
    echo "[ERROR] Could not find a WineHQ Ubuntu repository for $UBUNTU_CODENAME"
    echo "Set HF_WINEHQ_CODENAME manually if WineHQ has changed their repository layout."
    return 1
  fi

  winehq_keyring="/etc/apt/keyrings/winehq-archive.gpg"
  source_path="/etc/apt/sources.list.d/winehq.sources"

  echo "Installing WineHQ stable from Ubuntu repo line: $winehq_codename"
  $SUDO mkdir -pm755 /etc/apt/keyrings
  curl -fsSL https://dl.winehq.org/wine-builds/winehq.key | $SUDO gpg --batch --yes --dearmor -o "$winehq_keyring"
  $SUDO rm -f /etc/apt/keyrings/winehq-archive.key /etc/apt/sources.list.d/winehq-*.sources

  repo_file="$(mktemp)"
  cat > "$repo_file" <<EOF
Types: deb
URIs: https://dl.winehq.org/wine-builds/ubuntu
Suites: $winehq_codename
Components: main
Architectures: amd64 i386
Signed-By: $winehq_keyring
EOF

  $SUDO mv "$repo_file" "$source_path"
  $SUDO chmod 644 "$source_path"
  $SUDO apt update
  $SUDO apt install --install-recommends winehq-stable -y
}

find_command() {
  local command_name

  for command_name in "$@"; do
    if command -v "$command_name" >/dev/null 2>&1; then
      command -v "$command_name"
      return
    fi
  done

  return 1
}

bootstrap_wine_prefix() {
  local wineboot_cmd wineserver_cmd wine_cmd winetricks_cmd

  echo "Creating/updating base Wine prefix template: $WINE_PREFIX"
  mkdir -p "$WINE_PREFIX"

  wineboot_cmd="$(find_command wineboot wineboot-stable /opt/wine-stable/bin/wineboot || true)"
  wineserver_cmd="$(find_command wineserver wineserver-stable /opt/wine-stable/bin/wineserver || true)"
  wine_cmd="$(find_command wine wine-stable /opt/wine-stable/bin/wine || true)"
  winetricks_cmd="$(find_command winetricks || true)"

  if [[ -z "$wineboot_cmd" || -z "$wineserver_cmd" || -z "$wine_cmd" ]]; then
    echo "[ERROR] WineHQ install completed, but required Wine commands are missing from PATH." >&2
    echo "wine:       ${wine_cmd:-missing}" >&2
    echo "wineboot:   ${wineboot_cmd:-missing}" >&2
    echo "wineserver: ${wineserver_cmd:-missing}" >&2
    echo "Try rerunning setup, or inspect: apt-cache policy winehq-stable wine-stable" >&2
    return 1
  fi

  if [[ -z "$winetricks_cmd" ]]; then
    echo "[ERROR] winetricks is missing. Try: sudo apt install winetricks" >&2
    return 1
  fi

  WINEPREFIX="$WINE_PREFIX" \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES=winemenubuilder.exe=d \
    "$wineboot_cmd" -u

  WINEPREFIX="$WINE_PREFIX" "$wineserver_cmd" -w || true

  WINEPREFIX="$WINE_PREFIX" \
    WINEARCH=win64 \
    WINEDEBUG=-all \
    WINEDLLOVERRIDES=winemenubuilder.exe=d \
    "$winetricks_cmd" -q corefonts

  WINEPREFIX="$WINE_PREFIX" "$wineserver_cmd" -w || true

  if [[ "$INSTALL_DOTNET48" == "1" ]]; then
    echo "Installing dotnet48 into $WINE_PREFIX"
    WINEPREFIX="$WINE_PREFIX" \
      WINEARCH=win64 \
      WINEDEBUG=-all \
      WINEDLLOVERRIDES=winemenubuilder.exe=d \
      "$winetricks_cmd" -q dotnet48
    WINEPREFIX="$WINE_PREFIX" "$wineserver_cmd" -w || true
  fi

  if [[ ! -f "$WINE_PREFIX/system.reg" ]]; then
    echo "[ERROR] Wine prefix bootstrap did not create $WINE_PREFIX/system.reg" >&2
    return 1
  fi

  echo "Base Wine prefix is ready for profile cloning: $WINE_PREFIX"
}

wine_documents_dir() {
  local prefix="$1"
  local username="${HF_SERVICE_USER:-${USER:-}}"
  local candidate

  if [[ -n "$username" && -d "$prefix/drive_c/users/$username" ]]; then
    printf '%s\n' "$prefix/drive_c/users/$username/Documents"
    return
  fi

  if [[ -n "${USER:-}" && -d "$prefix/drive_c/users/$USER" ]]; then
    printf '%s\n' "$prefix/drive_c/users/$USER/Documents"
    return
  fi

  candidate="$(find "$prefix/drive_c/users" -mindepth 1 -maxdepth 1 -type d ! -name Public -print -quit 2>/dev/null || true)"
  if [[ -n "$candidate" ]]; then
    printf '%s\n' "$candidate/Documents"
    return
  fi

  printf '%s\n' "$prefix/drive_c/users/${username:-${USER:-steamuser}}/Documents"
}

write_bannerlord_auth_token() {
  local token="$1"
  local documents_dir token_dir token_file

  token="$(trim "$token")"
  if [[ -z "$token" ]]; then
    echo "Skipping Bannerlord auth token write."
    return
  fi

  documents_dir="$(wine_documents_dir "$WINE_PREFIX")"
  token_dir="$documents_dir/Mount and Blade II Bannerlord/Tokens"
  token_file="$token_dir/DedicatedCustomServerAuthToken.txt"

  mkdir -p "$token_dir"
  umask 077
  printf '%s\n' "$token" > "$token_file"
  chmod 600 "$token_file"

  echo "Wrote Bannerlord dedicated auth token to:"
  echo "$token_file"
}

maybe_prompt_bannerlord_auth_token() {
  local token=""

  if [[ -n "${HF_BANNERLORD_AUTH_TOKEN:-}" ]]; then
    write_bannerlord_auth_token "$HF_BANNERLORD_AUTH_TOKEN"
    return
  fi

  if [[ "${HF_BANNERLORD_TOKEN_PROMPT:-1}" != "1" ]]; then
    echo "Skipping Bannerlord token prompt because HF_BANNERLORD_TOKEN_PROMPT is not 1."
    return
  fi

  if [[ ! -t 0 || ! -t 1 ]]; then
    echo "Skipping Bannerlord token prompt because setup is not running interactively."
    return
  fi

  echo
  read -r -s -p "Bannerlord DedicatedCustomServer auth token (blank to skip): " token
  echo
  write_bannerlord_auth_token "$token"
}

BANNERLORD_ROOT="$(resolve_bannerlord_root)"
RESOLVED_WEB_PASSWORD="$(resolve_web_password)"

mkdir -p "$CONFIG_DIR" "$REPO_DIR/logs/wine" "$REPO_DIR/logs/instances"
rm -f "$CONFIG_DIR/bannerlord-path-server.txt"
write_hostforge_env

echo "=== HostForge Linux setup ==="
echo "Repo:            $REPO_DIR"
echo "Service user:    $HF_SERVICE_USER"
echo "Service home:    $HF_SERVICE_HOME"
echo "Collector port:  $HF_COLLECTOR_PORT"
echo "Cloudflared URL: $HF_CLOUDFLARED_ORIGIN_URL"
echo "HostForge env:   $ENV_FILE"
echo "Ubuntu codename: $UBUNTU_CODENAME"
echo "Bannerlord root: $BANNERLORD_ROOT"
echo "Wine prefix:     $WINE_PREFIX"
echo "Dotnet48:        $INSTALL_DOTNET48"
echo

echo "== Base repositories and tooling =="
cleanup_winehq_apt_state
$SUDO apt update
$SUDO apt install wget curl nano ca-certificates gnupg apt-transport-https openssl software-properties-common -y
enable_ubuntu_repository_component universe
enable_ubuntu_repository_component multiverse
$SUDO dpkg --add-architecture i386
$SUDO apt update

echo
echo "== Runtime dependencies =="
$SUDO apt install python3 rsync xvfb winetricks cabextract p7zip-full steamcmd tar iptables ipset tcpdump -y

echo
echo "== Cloudflared =="
if should_run_optional_step HF_SETUP_CLOUDFLARED "Install/update cloudflared for temporary web tunnels?" "yes"; then
  install_cloudflared
else
  echo "Skipping cloudflared install."
fi

echo
echo "== WineHQ setup =="
install_winehq

echo
echo "== Steam content updates =="
steam_update "1007"
steam_update "1863440" "$BANNERLORD_ROOT"

echo
echo "== Wine prefix bootstrap =="
bootstrap_wine_prefix

echo
echo "== Bannerlord dedicated auth token =="
maybe_prompt_bannerlord_auth_token

echo
echo "== Installing HostForge systemd services =="
bash "$REPO_DIR/hostforge.sh" __install-service-template
bash "$REPO_DIR/hostforge.sh" __start-collector

echo
echo "[SUCCESS] Host setup complete."
echo "Collector URL: http://$(hostname -f 2>/dev/null || hostname):$HF_COLLECTOR_PORT/"
echo "Cloudflare quick tunnel service is available for: $HF_CLOUDFLARED_ORIGIN_URL"
echo "Use hostforge.sh for profiles, system actions, firewall traffic, Cloudflare, and repo maintenance."
echo "Repo maintenance syncs: $REPO_DIR/module-hostforge via $ENV_FILE"
echo "Next step: bash hostforge.sh"
