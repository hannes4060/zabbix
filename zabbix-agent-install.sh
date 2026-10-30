#!/usr/bin/env bash
# =============================================================================
#  zabbix-agent-install.sh
#
#  Installiert und konfiguriert den Zabbix Agent (zabbix-agent oder
#  zabbix-agent2) auf Debian/Ubuntu – inkl. PSK-Verschlüsselung und optionaler
#  Registrierung des Hosts im Zabbix-Frontend über die API.
#
#  Aufruf:    sudo ./zabbix-agent-install.sh
#
#  Optional lassen sich Vorgaben per Umgebungsvariable setzen, z. B.:
#    sudo ZBX_VERSION=8.0 ZBX_API_URL=https://zabbix.example.de \
#         ZBX_API_TOKEN=xxxx ./zabbix-agent-install.sh
#
#  Das Script kann gefahrlos erneut ausgeführt werden (z. B. zum Umkonfigurieren
#  oder für einen neuen PSK): vorhandene Werte werden als Vorgabe angeboten und
#  die Agent-Konfiguration wird vor jeder Änderung gesichert.
# =============================================================================
set -Eeuo pipefail

# ---------- Grundeinstellungen ----------------------------------------------
ZBX_VERSION_DEFAULT="${ZBX_VERSION:-8.0}"
PSK_FILE="/etc/zabbix/zabbix_agent.psk"
LOGFILE="/var/log/zabbix-agent-install.log"
BACKUP_KEEP="${ZBX_BACKUP_KEEP:-3}"   # so viele Konfig-Backups behalten
BLOCK_BEGIN="# BEGIN zabbix-agent-install"
BLOCK_END="# END zabbix-agent-install"

# ---------- Globale Variablen ------------------------------------------------
OS_ID="" OS_VER="" OS_PRETTY="" ARCH="" DEFAULT_IP=""
ZBX_VERSION=""
AGENT_PKG="" AGENT_SVC="" AGENT_CONF="" AGENT_BIN="" AGENT_LOG="" OTHER_PKG="" OTHER_CONF=""
MODE=""            # active | passive | both
VIA=""             # server | proxy
TARGETS=""         # Adressen wie eingegeben (für ServerActive)
CONF_SERVER="" CONF_SERVER_ACTIVE=""
HOST_NAME="" HOST_IP=""
PSK_IDENTITY="" PSK_KEY="" PSK_REUSED=0
REMOVE_OTHER=0 OPEN_UFW=0 CONF_BACKUP="" AGENT_RUNNING=0
USE_API=0 API_DONE=0
API_URL="${ZBX_API_URL:-}" API_TOKEN="${ZBX_API_TOKEN:-}" API_RESULT="" API_ERR="" API_VERSION=""
CURL_OPTS=()
GROUP_NAME="" GROUP_ID="" GROUP_CREATE=0
TEMPLATE_NAME="" TEMPLATE_ID=""
PROXY_ID="" PROXY_NAME="" MONITORED_BY=0
HOST_ID=""
HOST_UPDATE=1          # bestehender Host: PSK/TLS aktualisieren
CUR_MB="" CUR_PROXY="" # bestehender Host: aktuelle Überwachung (monitored_by/proxyid)
PROXY_KEEP=0           # bestehender Host: Überwachung durch Server/Proxy unverändert lassen

# ---------- Zusatz: apt-Updates (templates/apt-updates im Repo) --------------
ZBX_REPO_RAW="${ZBX_REPO_RAW:-https://raw.githubusercontent.com/hannes4060/zabbix/main}"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || echo .)
APT_DIR="templates/apt-updates"
APT_SUDOERS="/etc/sudoers.d/zabbix-apt"
APT_SUDO_RULE="zabbix ALL=(root) NOPASSWD: /usr/bin/apt-get update -qq"
APT_UP_FILE="userparameter_apt_updates.conf"
APT_KEY="apt.updates.count"
APT_UPDATES=0 APT_TPL_NAME="" APT_TPL_FILE="" APT_TPL_ID="" APT_TPL_IMPORT=0 APT_TPL_LINKED=0
APT_UP_DIR=""
APT_CHECK_FILE="zabbix-apt-check"
APT_CHECK_BIN="/usr/local/bin/zabbix-apt-check"
APT_CHECK_OK=0          # Helfer auf dem Host installiert
APT_SCRIPT_NAME="apt-Updates prüfen"
APT_SCRIPT_ID="" APT_SCRIPT_CREATE=0

# ---------- Ausgabe ----------------------------------------------------------
if [[ -t 1 ]]; then
  C_R=$'\e[31m' C_G=$'\e[32m' C_Y=$'\e[33m' C_B=$'\e[1;34m' C_BOLD=$'\e[1m' C_0=$'\e[0m'
else
  C_R="" C_G="" C_Y="" C_B="" C_BOLD="" C_0=""
fi
info()   { printf '%s[i]%s %s\n' "$C_B" "$C_0" "$*"; }
ok()     { printf '%s[✓]%s %s\n' "$C_G" "$C_0" "$*"; }
warn()   { printf '%s[!]%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
die()    { printf '%s[✗]%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }
header() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

trap 'printf "%s[✗]%s Unerwarteter Fehler in Zeile %s: %s (Log: %s)\n" "$C_R" "$C_0" "$LINENO" "$BASH_COMMAND" "$LOGFILE" >&2' ERR

# Befehl ausführen, Ausgabe ins Log, bei Fehler abbrechen
run() {
  echo "+ $*" >>"$LOGFILE"
  "$@" >>"$LOGFILE" 2>&1 || die "Befehl fehlgeschlagen: $* (Details: $LOGFILE)"
}

# ---------- Eingabe-Helfer ---------------------------------------------------
# ask VAR "Frage" [Vorgabe]   – ohne Vorgabe ist eine Eingabe Pflicht
ask() {
  local __v=$1 __q=$2 __d=${3-} __a=""
  while :; do
    if [[ -n $__d ]]; then
      read -rp "  $__q [$__d]: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
      __a=${__a:-$__d}
    else
      read -rp "  $__q: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
    fi
    [[ -n $__a ]] && break
    warn "Eingabe erforderlich."
  done
  printf -v "$__v" '%s' "$__a"
}

# ask_yn "Frage" j|n   – Rückgabe 0 = ja
ask_yn() {
  local __q=$1 __d=${2:-j} __a __hint="J/n"
  [[ $__d == n ]] && __hint="j/N"
  while :; do
    read -rp "  $__q [$__hint]: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
    __a=${__a:-$__d}
    case ${__a,,} in
      j|ja|y|yes) return 0 ;;
      n|nein|no)  return 1 ;;
    esac
  done
}

# choose VAR "Frage" Vorgabe-Nr Option1 Option2 ...   – liefert die Nummer (1-basiert)
choose() {
  local __v=$1 __q=$2 __d=$3 __a i
  shift 3
  local -a __o=("$@")
  echo "  $__q"
  for i in "${!__o[@]}"; do printf '    %d) %s\n' $((i + 1)) "${__o[$i]}"; done
  while :; do
    read -rp "  Auswahl [$__d]: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
    __a=${__a:-$__d}
    if [[ $__a =~ ^[0-9]+$ ]] && ((__a >= 1 && __a <= ${#__o[@]})); then
      printf -v "$__v" '%s' "$__a"
      return 0
    fi
    warn "Ungültige Auswahl."
  done
}

# ---------- Allgemeine Helfer ------------------------------------------------
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Letzten aktiven Wert eines Parameters aus einer Agent-Konfig lesen
get_conf() {
  local f=$1 k=$2
  [[ -f $f ]] || return 0
  grep -E "^[[:space:]]*${k}[[:space:]]*=" "$f" | tail -n1 | cut -d= -f2- |
    sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' || true
}

# "a:10051, b;c" -> Liste einzelner Einträge (eine Zeile pro Eintrag)
split_targets() {
  local -a arr
  local e
  IFS=',' read -ra arr <<<"${1//;/,}"
  for e in "${arr[@]}"; do
    e=${e//[[:space:]]/}
    [[ -n $e ]] && printf '%s\n' "$e"
  done
  return 0
}

# Ports entfernen und Semikolons durch Kommas ersetzen (für Parameter "Server")
to_server_list() {
  local -a out=()
  local e
  while IFS= read -r e; do
    if [[ $e =~ ^\[(.+)\]:[0-9]+$ ]]; then
      e=${BASH_REMATCH[1]}
    elif [[ $e =~ ^([^:]+):[0-9]+$ ]]; then
      e=${BASH_REMATCH[1]}
    fi
    out+=("$e")
  done < <(split_targets "$1")
  (IFS=','; echo "${out[*]}")
}

set_agent_vars() {
  if [[ $1 == 1 ]]; then
    AGENT_PKG=zabbix-agent2  AGENT_SVC=zabbix-agent2  AGENT_BIN=zabbix_agent2
    AGENT_CONF=/etc/zabbix/zabbix_agent2.conf AGENT_LOG=/var/log/zabbix/zabbix_agent2.log
    OTHER_PKG=zabbix-agent   OTHER_CONF=/etc/zabbix/zabbix_agentd.conf
    APT_UP_DIR=/etc/zabbix/zabbix_agent2.d
  else
    AGENT_PKG=zabbix-agent   AGENT_SVC=zabbix-agent   AGENT_BIN=zabbix_agentd
    AGENT_CONF=/etc/zabbix/zabbix_agentd.conf AGENT_LOG=/var/log/zabbix/zabbix_agentd.log
    OTHER_PKG=zabbix-agent2  OTHER_CONF=/etc/zabbix/zabbix_agent2.conf
    APT_UP_DIR=/etc/zabbix/zabbix_agentd.d
  fi
}

# fetch_repo_file PFAD_IM_REPO ZIEL – erst neben dem Script suchen (git clone),
# sonst aus dem GitHub-Repo laden
fetch_repo_file() {
  local rel=$1 dest=$2
  if [[ -f "$SCRIPT_DIR/$rel" ]]; then
    cp "$SCRIPT_DIR/$rel" "$dest"
    echo "Lokal: $SCRIPT_DIR/$rel" >>"$LOGFILE"
    return 0
  fi
  echo "Download: $ZBX_REPO_RAW/$rel" >>"$LOGFILE"
  curl -fsSL --max-time 30 -o "$dest" "$ZBX_REPO_RAW/$rel" 2>>"$LOGFILE"
}

# ---------- Zabbix-API -------------------------------------------------------
# api_call METHODE PARAMS_JSON  -> Ergebnis in $API_RESULT, Fehlertext in $API_ERR
api_call() {
  local method=$1 params=$2 body resp errf
  body=$(jq -nc --arg m "$method" --argjson p "$params" '{jsonrpc:"2.0", method:$m, params:$p, id:1}')
  errf=$(mktemp)
  local -a hdr=(-H "Content-Type: application/json-rpc")
  if [[ $method == apiinfo.version ]]; then
    resp=$(curl -sS --max-time 20 "${CURL_OPTS[@]}" "${hdr[@]}" -d "$body" "$API_URL" 2>"$errf") ||
      { API_ERR=$(<"$errf"); rm -f "$errf"; return 1; }
  else
    # Token über Process-Substitution übergeben -> taucht nicht in "ps" auf
    resp=$(curl -sS --max-time 20 "${CURL_OPTS[@]}" "${hdr[@]}" \
      -H @<(printf 'Authorization: Bearer %s\n' "$API_TOKEN") -d "$body" "$API_URL" 2>"$errf") ||
      { API_ERR=$(<"$errf"); rm -f "$errf"; return 1; }
  fi
  rm -f "$errf"
  if ! jq -e . >/dev/null 2>&1 <<<"$resp"; then
    API_ERR="Keine gültige JSON-Antwort (falsche URL?): ${resp:0:150}"
    return 1
  fi
  if jq -e '.error' >/dev/null 2>&1 <<<"$resp"; then
    API_ERR=$(jq -r '.error | "\(.message) \(.data // "")"' <<<"$resp")
    return 1
  fi
  API_RESULT=$(jq -c '.result' <<<"$resp")
}

api() { api_call "$@" || die "API-Fehler bei $1: $API_ERR"; }

# =============================================================================
#  1) Vorprüfung
# =============================================================================
preflight() {
  [[ $EUID -eq 0 ]] || die "Bitte als root bzw. mit sudo ausführen."
  : >>"$LOGFILE" && chmod 600 "$LOGFILE"
  echo "===== $(date '+%F %T') Start =====" >>"$LOGFILE"

  [[ -r /etc/os-release ]] || die "/etc/os-release nicht gefunden."
  OS_ID=$(. /etc/os-release && echo "${ID,,}")
  OS_VER=$(. /etc/os-release && echo "${VERSION_ID-}")
  OS_PRETTY=$(. /etc/os-release && echo "${PRETTY_NAME-}")
  case $OS_ID in
    debian | ubuntu) ;;
    *) die "Nicht unterstütztes System: $OS_PRETTY (nur Debian/Ubuntu)." ;;
  esac
  [[ -n $OS_VER ]] || die "Keine VERSION_ID gefunden (Debian testing/sid wird nicht unterstützt)."

  ARCH=$(dpkg --print-architecture)
  case $ARCH in
    amd64 | arm64) ;;
    *) warn "Architektur $ARCH – Zabbix bietet ggf. keine Pakete dafür an." ;;
  esac

  DEFAULT_IP=$(ip -4 route get 1.1.1.1 2>/dev/null |
    awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)
  [[ -n $DEFAULT_IP ]] || DEFAULT_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)

  ok "System erkannt: $OS_PRETTY ($ARCH), IP ${DEFAULT_IP:-unbekannt}"

  local -a need=()
  local p
  for p in curl ca-certificates jq openssl; do pkg_installed "$p" || need+=("$p"); done
  if ((${#need[@]})); then
    info "Installiere benötigte Hilfspakete: ${need[*]}"
    run apt-get update
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y "${need[@]}"
  fi
}

# =============================================================================
#  2) Abfragen
# =============================================================================
ask_questions() {
  local c def

  header "Zabbix-Version"
  while :; do
    ask ZBX_VERSION "Zabbix-Version (Repository)" "$ZBX_VERSION_DEFAULT"
    [[ $ZBX_VERSION =~ ^[0-9]+\.[0-9]+$ ]] && break
    warn "Format z. B. 8.0"
  done

  header "Agent"
  def=1
  if pkg_installed zabbix-agent && ! pkg_installed zabbix-agent2; then def=2; fi
  choose c "Welcher Agent soll installiert werden?" "$def" \
    "zabbix-agent2  (Go, empfohlen)" "zabbix-agent   (klassisch, C)"
  set_agent_vars "$c"

  if pkg_installed "$OTHER_PKG"; then
    warn "$OTHER_PKG ist ebenfalls installiert – beide nutzen Port 10050."
    ask_yn "$OTHER_PKG stoppen und entfernen?" j && REMOVE_OTHER=1
  fi

  # Vorgaben aus bestehender Konfiguration (bei erneutem Lauf)
  local cfg_sa cfg_s cfg_host
  cfg_sa=$(get_conf "$AGENT_CONF" ServerActive)
  cfg_s=$(get_conf "$AGENT_CONF" Server)
  cfg_host=$(get_conf "$AGENT_CONF" Hostname)
  [[ $cfg_sa == 127.0.0.1 ]] && cfg_sa=""
  [[ $cfg_s == 127.0.0.1 ]] && cfg_s=""
  [[ $cfg_host == "Zabbix server" ]] && cfg_host=""

  header "Betriebsmodus"
  def=1
  if [[ -n $cfg_s && -n $cfg_sa ]]; then def=3; elif [[ -n $cfg_s ]]; then def=2; fi
  choose c "Wie soll der Agent arbeiten?" "$def" \
    "Aktiv   – Agent schickt Daten an Server/Proxy (Port 10051 ausgehend)" \
    "Passiv  – Server/Proxy fragt den Agent ab   (Port 10050 eingehend)" \
    "Aktiv + Passiv"
  case $c in 1) MODE=active ;; 2) MODE=passive ;; 3) MODE=both ;; esac

  header "Server / Proxy"
  choose c "Wer überwacht diesen Host?" 1 "Zabbix-Server" "Zabbix-Proxy"
  if [[ $c == 1 ]]; then VIA=server; else VIA=proxy; fi
  local what="Zabbix-Servers"
  [[ $VIA == proxy ]] && what="Zabbix-Proxys"
  echo "  Mehrere Adressen mit Komma trennen, Knoten eines Server-HA-Clusters mit Semikolon."
  echo "  Optionaler Port als host:port (Standard 10051)."
  ask TARGETS "Adresse(n) des $what (IP oder DNS)" "${cfg_sa:-$cfg_s}"
  TARGETS=${TARGETS//[[:space:]]/}
  CONF_SERVER=$(to_server_list "$TARGETS")
  CONF_SERVER_ACTIVE=""
  [[ $MODE != passive ]] && CONF_SERVER_ACTIVE=$TARGETS

  header "Host"
  local def_host
  def_host=${cfg_host:-$(hostname -f 2>/dev/null || hostname)}
  while :; do
    ask HOST_NAME "Hostname (muss exakt dem Host-Namen in Zabbix entsprechen)" "$def_host"
    [[ $HOST_NAME =~ ^[A-Za-z0-9._\ -]+$ ]] && break
    warn "Erlaubt sind Buchstaben, Ziffern, Leerzeichen, Punkt, Bindestrich und Unterstrich."
  done
  if [[ $MODE == active ]]; then
    HOST_IP=""      # reine Aktiv-Checks: kein Agent-Interface nötig
  else
    ask HOST_IP "IP-Adresse für das Agent-Interface (Passiv-Checks)" "$DEFAULT_IP"
  fi

  header "PSK-Verschlüsselung"
  local old_id
  old_id=$(get_conf "$AGENT_CONF" TLSPSKIdentity)
  [[ -n $old_id ]] || old_id=$(get_conf "$OTHER_CONF" TLSPSKIdentity)
  if [[ -s $PSK_FILE && -n $old_id ]] &&
    ask_yn "Vorhandenen PSK weiterverwenden (Identity: $old_id)?" j; then
    PSK_IDENTITY=$old_id
    PSK_KEY=$(tr -d '[:space:]' <"$PSK_FILE")
    PSK_REUSED=1
    ok "Bestehender PSK wird weiterverwendet."
  else
    ask PSK_IDENTITY "PSK-Identity" "PSK-${HOST_NAME// /_}"
    PSK_KEY=$(openssl rand -hex 32)
    ok "Neuer 256-Bit-PSK erzeugt."
  fi

  header "Zusatzüberwachung"
  echo "  apt-Updates: zählt alle 6 h die aktualisierbaren Pakete (sudo-Regel + UserParameter"
  echo "  auf dem Host, Template 'Linux updates by Zabbix agent [active]' im Frontend)."
  if ask_yn "apt-Updates-Überwachung einrichten?" j; then
    APT_UPDATES=1
    # Aktiv und Aktiv+Passiv -> aktive Variante (apt update dauert, kein Poller blockiert)
    if [[ $MODE == passive ]]; then
      APT_TPL_NAME="Linux updates by Zabbix agent"
      APT_TPL_FILE="template_apt_updates_passive.yaml"
    else
      APT_TPL_NAME="Linux updates by Zabbix agent active"
      APT_TPL_FILE="template_apt_updates_active.yaml"
    fi
  fi

  if [[ $MODE != active ]] && command -v ufw >/dev/null 2>&1 &&
    ufw status 2>/dev/null | grep -q "Status: active"; then
    header "Firewall"
    ask_yn "ufw ist aktiv – Port 10050/tcp für $CONF_SERVER freigeben?" j && OPEN_UFW=1
  fi

  header "Registrierung im Zabbix-Frontend"
  if ask_yn "Host automatisch per API anlegen bzw. aktualisieren?" j; then
    USE_API=1
    api_setup
  fi
}

api_setup() {
  local c

  # --- Verbindung & Token ---
  while :; do
    ask API_URL "Frontend-URL (z. B. https://zabbix.example.de)" "$API_URL"
    [[ $API_URL =~ ^https?:// ]] || API_URL="https://$API_URL"
    API_URL=${API_URL%/}
    [[ $API_URL == *api_jsonrpc.php ]] || API_URL="$API_URL/api_jsonrpc.php"

    if ! api_call apiinfo.version '[]'; then
      if [[ $API_ERR == *SSL* || $API_ERR == *certificate* ]] && ((${#CURL_OPTS[@]} == 0)) &&
        ask_yn "Zertifikat ungültig/selbstsigniert – Prüfung für diese Sitzung deaktivieren?" n; then
        CURL_OPTS=(-k)
        continue
      fi
      warn "API nicht erreichbar: $API_ERR"
      ask_yn "Erneut versuchen?" j && continue
      USE_API=0
      return 0
    fi
    API_VERSION=$(jq -r . <<<"$API_RESULT")
    ok "API erreichbar – Zabbix $API_VERSION"
    if ((${API_VERSION%%.*} < 7)); then
      warn "Das Script nutzt die API ab Zabbix 7.0 (monitored_by/proxyid) – Registrierung übersprungen."
      USE_API=0
      return 0
    fi

    if [[ -z $API_TOKEN ]]; then
      read -rsp "  API-Token (Benutzereinstellungen → API-Tokens): " API_TOKEN || die "Keine Eingabe."
      echo
    fi
    if api_call host.get '{"output":["hostid"],"limit":1}'; then
      ok "Token gültig."
      break
    fi
    warn "Token abgelehnt: $API_ERR"
    API_TOKEN=""
    ask_yn "Erneut versuchen?" j || { USE_API=0; return 0; }
  done

  # --- Existiert der Host bereits? ---
  api host.get "$(jq -nc --arg h "$HOST_NAME" '{output:["hostid","monitored_by","proxyid"], filter:{host:[$h]}}')"
  HOST_ID=$(jq -r '.[0].hostid // empty' <<<"$API_RESULT")
  if [[ -n $HOST_ID ]]; then
    CUR_MB=$(jq -r '.[0].monitored_by // "0"' <<<"$API_RESULT")
    CUR_PROXY=$(jq -r '.[0].proxyid // "0"' <<<"$API_RESULT")
    warn "Host '$HOST_NAME' existiert bereits im Frontend (ID $HOST_ID)."
    # Ein "Nein" betrifft nur PSK/TLS – Templates und Menü-Script werden trotzdem ergänzt
    ask_yn "PSK-Einstellungen dieses Hosts im Frontend aktualisieren?" j || HOST_UPDATE=0
  else
    # --- Hostgruppe ---
    while :; do
      ask GROUP_NAME "Hostgruppe" "${GROUP_NAME:-Linux servers}"
      api hostgroup.get "$(jq -nc --arg n "$GROUP_NAME" '{output:["groupid"], filter:{name:[$n]}}')"
      GROUP_ID=$(jq -r '.[0].groupid // empty' <<<"$API_RESULT")
      [[ -n $GROUP_ID ]] && break
      if ask_yn "Gruppe '$GROUP_NAME' existiert nicht – anlegen?" j; then
        GROUP_CREATE=1
        break
      fi
    done

    # --- Template ---
    local tdef=1
    [[ $MODE != active ]] && tdef=2
    while :; do
      choose c "Welches Template soll verknüpft werden?" "$tdef" \
        "Linux by Zabbix agent active" "Linux by Zabbix agent" \
        "Anderes Template (Namen eingeben)" "Kein Template"
      case $c in
        1) TEMPLATE_NAME="Linux by Zabbix agent active" ;;
        2) TEMPLATE_NAME="Linux by Zabbix agent" ;;
        3) ask TEMPLATE_NAME "Template-Name" ;;
        4) TEMPLATE_NAME="" TEMPLATE_ID="" && break ;;
      esac
      api template.get "$(jq -nc --arg n "$TEMPLATE_NAME" '{output:["templateid"], filter:{host:[$n]}}')"
      TEMPLATE_ID=$(jq -r '.[0].templateid // empty' <<<"$API_RESULT")
      if [[ -z $TEMPLATE_ID ]]; then
        api template.get "$(jq -nc --arg n "$TEMPLATE_NAME" '{output:["templateid"], filter:{name:[$n]}}')"
        TEMPLATE_ID=$(jq -r '.[0].templateid // empty' <<<"$API_RESULT")
      fi
      [[ -n $TEMPLATE_ID ]] && break
      warn "Template '$TEMPLATE_NAME' nicht gefunden."
    done
  fi

  # --- apt-Updates-Template ---
  if ((APT_UPDATES)); then
    api template.get "$(jq -nc --arg n "$APT_TPL_NAME" '{output:["templateid"], filter:{host:[$n]}}')"
    APT_TPL_ID=$(jq -r '.[0].templateid // empty' <<<"$API_RESULT")
    if [[ -n $APT_TPL_ID ]]; then
      ok "Template '$APT_TPL_NAME' gefunden."
    elif ask_yn "Template '$APT_TPL_NAME' fehlt im Frontend – aus dem Repo importieren?" j; then
      APT_TPL_IMPORT=1
    else
      warn "Template wird nicht verknüpft – Host-Seite wird trotzdem eingerichtet."
    fi

    if [[ -n $HOST_ID ]]; then
      # Bereits verknüpft? Andere Variante verknüpft (apt update liefe doppelt)?
      api template.get "$(jq -nc --arg id "$HOST_ID" \
        '{output:["host"], hostids:[$id],
          filter:{host:["Linux updates by Zabbix agent","Linux updates by Zabbix agent active"]}}')"
      local linked
      linked=$(jq -r '.[].host' <<<"$API_RESULT")
      if grep -qxF "$APT_TPL_NAME" <<<"$linked"; then
        APT_TPL_LINKED=1
        ok "Template '$APT_TPL_NAME' ist am Host bereits verknüpft."
      elif [[ -n $linked ]]; then
        warn "Am Host ist bereits '$linked' verknüpft – bitte im Frontend entfernen,"
        warn "sonst läuft 'apt update' doppelt."
      fi
    fi
  fi

  # --- Zabbix-Script "apt-Updates prüfen" (einmalig global) ---
  if ((APT_UPDATES)); then
    if api_call script.get "$(jq -nc --arg n "$APT_SCRIPT_NAME" '{output:["scriptid"], filter:{name:[$n]}}')"; then
      APT_SCRIPT_ID=$(jq -r '.[0].scriptid // empty' <<<"$API_RESULT")
      if [[ -n $APT_SCRIPT_ID ]]; then
        ok "Zabbix-Script '$APT_SCRIPT_NAME' vorhanden."
      elif ask_yn "Zabbix-Script '$APT_SCRIPT_NAME' fürs Host-Menü anlegen?" j; then
        APT_SCRIPT_CREATE=1
      fi
    else
      warn "script.get nicht erlaubt ($API_ERR) – Zabbix-Script wird nicht angelegt."
    fi
  fi

  # --- Proxy ---
  MONITORED_BY=0
  local -a pnames=() pids=()
  local i pdef=1 cur_name=""
  api proxy.get '{"output":["proxyid","name"],"sortfield":"name"}'
  mapfile -t pnames < <(jq -r '.[].name' <<<"$API_RESULT")
  mapfile -t pids < <(jq -r '.[].proxyid' <<<"$API_RESULT")
  for i in "${!pids[@]}"; do
    [[ ${pids[$i]} == "$CUR_PROXY" ]] && pdef=$((i + 1)) && cur_name=${pnames[$i]}
  done

  # Bestehender Host: aktuelle Zuordnung nur auf ausdrückliche Nachfrage ändern
  if [[ -n $HOST_ID ]]; then
    local cur_txt="Zabbix-Server"
    [[ $CUR_MB == 1 ]] && cur_txt="Proxy '${cur_name:-ID $CUR_PROXY}'"
    [[ $CUR_MB == 2 ]] && cur_txt="Proxy-Gruppe"
    info "Im Frontend wird der Host aktuell überwacht durch: $cur_txt"
    if { [[ $VIA == server && $CUR_MB == 0 ]] || [[ $VIA == proxy && $CUR_MB == 1 && -n $cur_name ]]; } &&
      ask_yn "Diese Zuordnung beibehalten?" j; then
      PROXY_KEEP=1
      return 0
    fi
    if ! { [[ $VIA == server && $CUR_MB == 0 ]] || [[ $VIA == proxy && $CUR_MB == 1 ]]; }; then
      warn "Deine Auswahl ('$VIA') weicht davon ab."
      if ! ask_yn "Zuordnung im Frontend ändern?" n; then
        PROXY_KEEP=1
        return 0
      fi
    fi
  fi

  if [[ $VIA == proxy ]]; then
    if ((${#pids[@]} == 0)); then
      warn "Keine Proxys im Frontend gefunden – Host wird als 'vom Server überwacht' eingetragen."
    else
      choose c "Welcher Proxy überwacht den Host (im Frontend)?" "$pdef" "${pnames[@]}"
      PROXY_ID=${pids[c - 1]}
      PROXY_NAME=${pnames[c - 1]}
      MONITORED_BY=1
    fi
  fi
}

show_summary() {
  local mode_txt
  case $MODE in active) mode_txt="Aktiv" ;; passive) mode_txt="Passiv" ;; both) mode_txt="Aktiv + Passiv" ;; esac
  header "Zusammenfassung"
  printf '  %-20s %s\n' "System:" "$OS_PRETTY ($ARCH)"
  printf '  %-20s %s\n' "Zabbix-Version:" "$ZBX_VERSION"
  printf '  %-20s %s\n' "Agent:" "$AGENT_PKG"
  printf '  %-20s %s\n' "Modus:" "$mode_txt"
  printf '  %-20s %s\n' "Überwacht durch:" "$VIA ($TARGETS)"
  [[ $MODE != active ]] && printf '  %-20s %s\n' "Server=" "$CONF_SERVER"
  [[ -n $CONF_SERVER_ACTIVE ]] && printf '  %-20s %s\n' "ServerActive=" "$CONF_SERVER_ACTIVE"
  printf '  %-20s %s\n' "Hostname:" "$HOST_NAME"
  printf '  %-20s %s\n' "Agent-Interface:" "${HOST_IP:-keins (nur Aktiv-Checks)}"
  printf '  %-20s %s\n' "PSK-Identity:" "$PSK_IDENTITY $([[ $PSK_REUSED == 1 ]] && echo '(bestehend)' || echo '(neu)')"
  ((REMOVE_OTHER)) && printf '  %-20s %s\n' "Entfernen:" "$OTHER_PKG"
  ((OPEN_UFW)) && printf '  %-20s %s\n' "Firewall:" "ufw 10050/tcp für $CONF_SERVER"
  if ((APT_UPDATES)); then
    local apt_txt="sudo-Regel + UserParameter"
    if ((USE_API)); then
      if ((APT_TPL_LINKED)); then apt_txt+=", Template schon verknüpft"
      elif ((APT_TPL_IMPORT)); then apt_txt+=", Template importieren + verknüpfen"
      elif [[ -n $APT_TPL_ID ]]; then apt_txt+=", Template verknüpfen"
      fi
      ((APT_SCRIPT_CREATE)) && apt_txt+=", Zabbix-Script anlegen"
    fi
    printf '  %-20s %s\n' "apt-Updates:" "$apt_txt"
    printf '  %-20s %s\n' "" "($APT_TPL_NAME)"
  fi
  if ((USE_API)); then
    if [[ -n $HOST_ID ]]; then
      printf '  %-20s %s\n' "API:" "bestehender Host (ID $HOST_ID): $( ((HOST_UPDATE)) && echo 'PSK aktualisieren' || echo 'PSK unverändert'), Überwachung $( ((PROXY_KEEP)) && echo unverändert || echo "→ ${PROXY_NAME:-Server}")"
    else
      printf '  %-20s %s\n' "API:" "Host anlegen – Gruppe '$GROUP_NAME'$([[ $GROUP_CREATE == 1 ]] && echo ' (neu)')"
      printf '  %-20s %s\n' "Template:" "${TEMPLATE_NAME:-keins}"
    fi
    [[ -n $PROXY_NAME ]] && printf '  %-20s %s\n' "Proxy (Frontend):" "$PROXY_NAME"
  else
    printf '  %-20s %s\n' "API:" "nein – Host manuell im Frontend anlegen"
  fi
  echo
  ask_yn "Installation jetzt durchführen?" j || die "Abgebrochen – es wurde nichts verändert."
}

# =============================================================================
#  3) Installation & Konfiguration
# =============================================================================
remove_other_agent() {
  ((REMOVE_OTHER)) || return 0
  info "Entferne $OTHER_PKG ..."
  systemctl disable --now "$OTHER_PKG" >>"$LOGFILE" 2>&1 || true
  run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$OTHER_PKG"
  ok "$OTHER_PKG entfernt."
}

install_repo() {
  local base="https://repo.zabbix.com/zabbix/${ZBX_VERSION}"
  local pool="pool/main/z/zabbix-release"
  local tag="${OS_ID}${OS_VER}"
  local -a urls=(
    "$base/release/$OS_ID/$pool/zabbix-release_latest_${ZBX_VERSION}+${tag}_all.deb"
    "$base/release/$OS_ID/$pool/zabbix-release_latest+${tag}_all.deb"
    "$base/$OS_ID/$pool/zabbix-release_latest_${ZBX_VERSION}+${tag}_all.deb"
    "$base/$OS_ID/$pool/zabbix-release_latest+${tag}_all.deb"
  )
  local tmp u
  tmp=$(mktemp --suffix=.deb)
  info "Richte Zabbix-$ZBX_VERSION-Repository ein ..."
  for u in "${urls[@]}"; do
    if curl -fsSL --max-time 30 -o "$tmp" "$u" 2>>"$LOGFILE"; then
      echo "Repo-Paket: $u" >>"$LOGFILE"
      run env DEBIAN_FRONTEND=noninteractive dpkg --force-confnew -i "$tmp"
      rm -f "$tmp"
      ok "Repository eingerichtet."
      return 0
    fi
  done
  rm -f "$tmp"
  die "Kein zabbix-release-Paket für $OS_PRETTY / Zabbix $ZBX_VERSION gefunden. Siehe https://repo.zabbix.com/zabbix/$ZBX_VERSION/"
}

install_agent() {
  info "Installiere $AGENT_PKG ..."
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confold "$AGENT_PKG"
  local v
  v=$(dpkg-query -W -f='${Version}' "$AGENT_PKG")
  if [[ $v == *":${ZBX_VERSION}."* || $v == "${ZBX_VERSION}."* ]]; then
    ok "$AGENT_PKG $v installiert."
  else
    warn "Installierte Version $v passt nicht zu $ZBX_VERSION – prüfe 'apt policy $AGENT_PKG'."
  fi
}

write_psk() {
  install -d -m 755 /etc/zabbix
  (umask 077 && printf '%s\n' "$PSK_KEY" >"$PSK_FILE")
  chown root:zabbix "$PSK_FILE"
  chmod 640 "$PSK_FILE"
  ok "PSK gespeichert: $PSK_FILE"
}

configure_agent() {
  local f=$AGENT_CONF k
  [[ -f $f ]] || die "Konfigurationsdatei $f nicht gefunden."
  CONF_BACKUP="$f.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$CONF_BACKUP"

  # Alten verwalteten Block entfernen, dann betroffene Parameter auskommentieren
  sed -i "/^${BLOCK_BEGIN}/,/^${BLOCK_END}/d" "$f"
  for k in Server ServerActive Hostname HostnameItem StartAgents ListenIP \
    TLSConnect TLSAccept TLSPSKIdentity TLSPSKFile; do
    sed -i -E "s/^[[:space:]]*${k}[[:space:]]*=/# &/" "$f"
  done

  {
    echo "$BLOCK_BEGIN – $(date '+%F %T') – wird bei erneutem Lauf des Scripts ersetzt"
    if [[ $MODE == active ]]; then
      # Nur Aktiv-Checks: keine Passiv-Anfragen von außen annehmen
      if [[ $AGENT_PKG == zabbix-agent ]]; then
        echo "StartAgents=0"                    # Listener komplett aus
      else
        echo "Server=127.0.0.1"                 # agent2: nur lokal erreichbar
        echo "ListenIP=127.0.0.1"
      fi
    else
      echo "Server=$CONF_SERVER"
    fi
    [[ -n $CONF_SERVER_ACTIVE ]] && echo "ServerActive=$CONF_SERVER_ACTIVE"
    echo "Hostname=$HOST_NAME"
    # UserParameter-Verzeichnis einbinden, falls die Paket-Konfig das nicht schon tut
    if ((APT_UPDATES)) &&
      ! grep -qE "^[[:space:]]*Include[[:space:]]*=[[:space:]]*${APT_UP_DIR}/?(\*\.conf)?[[:space:]]*$" "$f"; then
      echo "Include=${APT_UP_DIR}/*.conf"
    fi
    # Nur genau den Helfer für das Zabbix-Script "apt-Updates prüfen" freigeben
    # Zabbix ruft Remote-Befehle als system.run[<Befehl>,wait] auf -> ",*" nötig
    ((APT_CHECK_OK)) && echo "AllowKey=system.run[${APT_CHECK_BIN},*]"
    [[ $MODE != passive ]] && echo "TLSConnect=psk"   # Agent -> Server (aktiv)
    [[ $MODE != active ]] && echo "TLSAccept=psk"     # Server -> Agent (passiv)
    echo "TLSPSKIdentity=$PSK_IDENTITY"
    echo "TLSPSKFile=$PSK_FILE"
    echo "$BLOCK_END"
  } >>"$f"

  local out
  if ! out=$("$AGENT_BIN" -T -c "$f" 2>&1) &&
    ! grep -qiE "invalid option|unrecognized|unknown (option|flag)" <<<"$out"; then
    warn "Konfigurationstest fehlgeschlagen:"
    echo "$out" | tail -n 10 >&2
    if ask_yn "Backup wiederherstellen und abbrechen?" j; then
      cp -a "$CONF_BACKUP" "$f"
      die "Abgebrochen – Konfiguration wiederhergestellt."
    fi
  fi
  ok "Konfiguration geschrieben ($f, Backup: $(basename "$CONF_BACKUP"))."
}

install_apt_updates() {
  ((APT_UPDATES)) || return 0
  info "Richte apt-Updates-Überwachung ein ..."

  # sudo wird für die Regel gebraucht (fehlt auf Minimal-Installationen)
  if ! pkg_installed sudo; then
    run env DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
  fi

  # sudo-Regel: nur genau "apt-get update -qq" als root, vorher mit visudo prüfen
  local tmp
  tmp=$(mktemp)
  printf '# Verwaltet von zabbix-agent-install.sh\n%s\n' "$APT_SUDO_RULE" >"$tmp"
  if visudo -cqf "$tmp" >>"$LOGFILE" 2>&1; then
    install -m 0440 -o root -g root "$tmp" "$APT_SUDOERS"
    ok "sudo-Regel: $APT_SUDOERS"
  else
    rm -f "$tmp"
    warn "sudo-Regel ist ungültig – apt-Updates werden nicht eingerichtet."
    APT_UPDATES=0
    return 0
  fi
  rm -f "$tmp"

  # UserParameter aus dem Repo (lokal oder GitHub), notfalls eingebaute Kopie
  install -d -m 0755 "$APT_UP_DIR"
  tmp=$(mktemp)
  if ! fetch_repo_file "$APT_DIR/$APT_UP_FILE" "$tmp" ||
    ! grep -q "^UserParameter=${APT_KEY}," "$tmp"; then
    warn "UserParameter nicht aus dem Repo ladbar – nutze eingebaute Kopie."
    cat >"$tmp" <<'EOF'
# Anzahl der Pakete, die nach "apt update" aktualisiert werden können
# (für zabbix_agentd.d/ und zabbix_agent2.d/ gleichermaßen)
UserParameter=apt.updates.count,sudo -n /usr/bin/apt-get update -qq >/dev/null 2>&1; LC_ALL=C /usr/bin/apt-get -s -o Debug::NoLocking=true dist-upgrade 2>/dev/null | grep -c '^Inst [^ ]* \[' || true
EOF
  fi
  install -m 0644 -o root -g root "$tmp" "$APT_UP_DIR/$APT_UP_FILE"
  rm -f "$tmp"
  ok "UserParameter: $APT_UP_DIR/$APT_UP_FILE"

  # Helfer für das Zabbix-Script "apt-Updates prüfen" (Sofortabfrage im Host-Menü)
  tmp=$(mktemp)
  if fetch_repo_file "$APT_DIR/$APT_CHECK_FILE" "$tmp" && head -n1 "$tmp" | grep -q '^#!/bin/sh'; then
    install -m 0755 -o root -g root "$tmp" "$APT_CHECK_BIN"
    APT_CHECK_OK=1
    ok "Sofortabfrage: $APT_CHECK_BIN"
  else
    warn "$APT_CHECK_FILE nicht ladbar – Sofortabfrage im Host-Menü wird nicht eingerichtet."
  fi
  rm -f "$tmp"
  if ((APT_CHECK_OK)) && grep -qE '^[[:space:]]*DenyKey[[:space:]]*=[[:space:]]*system\.run' "$AGENT_CONF"; then
    warn "In $AGENT_CONF steht ein aktives DenyKey=system.run[...] vor dem verwalteten Block –"
    warn "dann greift das AllowKey für $APT_CHECK_BIN nicht. Bitte prüfen."
  fi

  # Darf der Benutzer zabbix den Befehl ausführen? (-l prüft nur, führt nichts aus)
  if runuser -u zabbix -- sudo -n -l /usr/bin/apt-get update -qq >/dev/null 2>&1; then
    ok "sudo-Regel greift für Benutzer zabbix."
  else
    warn "sudo-Regel greift nicht für Benutzer zabbix – 'sudo -l -U zabbix' prüfen."
  fi
}

# Nach dem Start: Key einmal lokal als Benutzer zabbix abfragen
test_apt_updates() {
  ((APT_UPDATES)) || return 0
  info "Teste $APT_KEY (apt update kann bis zu 2 Minuten dauern) ..."
  local out val
  out=$(timeout 180 runuser -u zabbix -- "$AGENT_BIN" -c "$AGENT_CONF" -t "$APT_KEY" 2>&1 || true)
  echo "$out" >>"$LOGFILE"
  val=$(grep -oE '\[[a-z]\|[^]]*\]' <<<"$out" | tail -n1 | sed -E 's/^\[[a-z]\|//; s/\]$//' || true)
  if [[ $val =~ ^[0-9]+$ ]]; then
    ok "$APT_KEY = $val aktualisierbare Pakete."
  else
    warn "Test von $APT_KEY ohne Ergebnis: ${out:0:200}"
  fi
}

open_firewall() {
  ((OPEN_UFW)) || return 0
  local e
  while IFS= read -r e; do
    if ufw allow from "$e" to any port 10050 proto tcp >>"$LOGFILE" 2>&1; then
      ok "ufw: 10050/tcp von $e erlaubt."
    else
      warn "ufw-Regel für '$e' fehlgeschlagen (ufw erwartet IP/Netz, keinen DNS-Namen)."
    fi
  done < <(split_targets "$CONF_SERVER")
}

start_agent() {
  run systemctl enable "$AGENT_SVC"
  systemctl restart "$AGENT_SVC" >>"$LOGFILE" 2>&1 || true
  sleep 3
  if systemctl is-active --quiet "$AGENT_SVC"; then
    AGENT_RUNNING=1
    ok "$AGENT_SVC läuft."
  else
    warn "$AGENT_SVC läuft NICHT. Letzte Logzeilen:"
    tail -n 15 "$AGENT_LOG" 2>/dev/null >&2 || journalctl -u "$AGENT_SVC" -n 15 --no-pager >&2 || true
  fi
}

# Alte Konfig-Backups aufräumen – nur wenn der Agent nach dem Lauf läuft,
# sonst bleiben alle Backups als Rückfallebene erhalten
prune_backups() {
  local -a baks
  local b n
  if ((!AGENT_RUNNING)); then
    info "Agent läuft nicht – alte Konfig-Backups bleiben erhalten."
    return 0
  fi
  [[ $BACKUP_KEEP =~ ^[0-9]+$ ]] && ((BACKUP_KEEP >= 1)) || BACKUP_KEEP=3
  # Nur eigene Backups (.bak.JJJJMMTT-HHMMSS) – alphabetisch = chronologisch
  mapfile -t baks < <(compgen -G "${AGENT_CONF}.bak.*" |
    grep -E '\.bak\.[0-9]{8}-[0-9]{6}$' | sort -r || true)
  n=0
  for b in "${baks[@]:$BACKUP_KEEP}"; do
    rm -f -- "$b" && n=$((n + 1))
  done
  ((n)) && ok "$n alte Konfig-Backup(s) gelöscht, die letzten $BACKUP_KEEP bleiben."
  return 0
}

check_ports() {
  [[ -n $CONF_SERVER_ACTIVE ]] || return 0
  local e h p
  while IFS= read -r e; do
    if [[ $e =~ ^\[(.+)\]:([0-9]+)$ || $e =~ ^([^:]+):([0-9]+)$ ]]; then
      h=${BASH_REMATCH[1]} p=${BASH_REMATCH[2]}
    else
      h=$e p=10051
    fi
    if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$h" "$p" 2>/dev/null; then
      ok "$h:$p erreichbar."
    else
      warn "$h:$p nicht erreichbar – Firewall/DNS prüfen."
    fi
  done < <(split_targets "$CONF_SERVER_ACTIVE")
}

# apt-Updates-Template aus dem Repo per configuration.import ins Frontend laden
import_apt_template() {
  local tmp params
  tmp=$(mktemp)
  if ! fetch_repo_file "$APT_DIR/$APT_TPL_FILE" "$tmp"; then
    rm -f "$tmp"
    warn "Template-Datei $APT_TPL_FILE nicht ladbar – bitte manuell importieren."
    return 1
  fi
  params=$(jq -nc --rawfile src "$tmp" \
    '{format:"yaml", source:$src,
      rules:{template_groups:{createMissing:true},
             templates:{createMissing:true, updateExisting:false},
             items:{createMissing:true, updateExisting:false},
             triggers:{createMissing:true, updateExisting:false}}}')
  rm -f "$tmp"
  if ! api_call configuration.import "$params"; then
    warn "Template-Import fehlgeschlagen: $API_ERR"
    return 1
  fi
  api template.get "$(jq -nc --arg n "$APT_TPL_NAME" '{output:["templateid"], filter:{host:[$n]}}')"
  APT_TPL_ID=$(jq -r '.[0].templateid // empty' <<<"$API_RESULT")
  [[ -n $APT_TPL_ID ]] || { warn "Template nach dem Import nicht gefunden."; return 1; }
  ok "Template '$APT_TPL_NAME' importiert."
}

register_host() {
  ((USE_API)) || return 0
  info "Registriere Host im Frontend ..."

  # apt-Updates-Template nur mitnehmen, wenn die Host-Seite eingerichtet ist
  if ((APT_UPDATES && APT_TPL_IMPORT)) && [[ -z $APT_TPL_ID ]]; then
    import_apt_template || true
  fi
  ((APT_UPDATES)) || APT_TPL_ID=""

  # Globales Script fürs Host-Menü (Typ Script, auf dem Agent, manuelle Host-Aktion)
  if ((APT_UPDATES && APT_SCRIPT_CREATE)); then
    if api_call script.create "$(jq -nc --arg n "$APT_SCRIPT_NAME" --arg c "$APT_CHECK_BIN" \
      '{name:$n, type:0, scope:2, execute_on:0, command:$c, timeout:"60s",
        groupid:"0", host_access:2,
        description:"apt update ausführen und aktualisierbare Pakete auflisten (zabbix-agent-install.sh)"}')"; then
      ok "Zabbix-Script '$APT_SCRIPT_NAME' angelegt."
    else
      warn "Zabbix-Script konnte nicht angelegt werden: $API_ERR"
    fi
  fi

  if ((GROUP_CREATE)); then
    if ! api_call hostgroup.create "$(jq -nc --arg n "$GROUP_NAME" '{name:$n}')"; then
      warn "Hostgruppe konnte nicht angelegt werden: $API_ERR"
      return 0
    fi
    GROUP_ID=$(jq -r '.groupids[0]' <<<"$API_RESULT")
    ok "Hostgruppe '$GROUP_NAME' angelegt."
  fi

  local params proxy_part='{}'
  ((MONITORED_BY == 1)) && proxy_part=$(jq -nc --arg p "$PROXY_ID" '{proxyid:$p}')

  # TLS je nach Modus (1 = unverschlüsselt, 2 = PSK)
  #   tls_connect: Verbindungen Server/Proxy -> Agent (passiv)
  #   tls_accept:  Verbindungen Agent -> Server/Proxy (aktiv)
  local tls_connect=2 tls_accept=2
  case $MODE in
    active)  tls_connect=1 ;;
    passive) tls_accept=1 ;;
  esac

  if [[ -n $HOST_ID ]]; then
    # Nur ändern, was gewünscht ist: PSK/TLS und/oder Überwachung durch Server/Proxy
    local upd='{}'
    if ((HOST_UPDATE)); then
      upd=$(jq -nc --arg idn "$PSK_IDENTITY" --arg psk "$PSK_KEY" \
        --argjson tc "$tls_connect" --argjson ta "$tls_accept" \
        '{tls_connect:$tc, tls_accept:$ta, tls_psk_identity:$idn, tls_psk:$psk}')
    fi
    if ((!PROXY_KEEP)); then
      upd=$(jq -c --argjson mb "$MONITORED_BY" --argjson px "$proxy_part" '. + {monitored_by:$mb} + $px' <<<"$upd")
    fi
    if [[ $upd != '{}' ]]; then
      params=$(jq -c --arg id "$HOST_ID" '. + {hostid:$id}' <<<"$upd")
      if api_call host.update "$params"; then
        ok "Host '$HOST_NAME' aktualisiert (ID $HOST_ID)."
        API_DONE=1
      else
        warn "host.update fehlgeschlagen: $API_ERR"
      fi
    else
      ok "Host '$HOST_NAME': PSK und Überwachung unverändert gelassen."
      API_DONE=1
    fi
    if [[ $MODE == active ]] &&
      api_call hostinterface.get "$(jq -nc --arg id "$HOST_ID" '{output:["interfaceid"], hostids:[$id], filter:{type:1}}')" &&
      [[ $(jq 'length' <<<"$API_RESULT") -gt 0 ]]; then
      warn "Der bestehende Host hat noch ein Agent-Interface – bei reinen Aktiv-Checks kannst du es im Frontend entfernen."
    fi
    # Template ergänzen, ohne bestehende Verknüpfungen anzufassen
    if [[ -n $APT_TPL_ID ]] && ((!APT_TPL_LINKED)); then
      if api_call host.massadd "$(jq -nc --arg h "$HOST_ID" --arg t "$APT_TPL_ID" \
        '{hosts:[{hostid:$h}], templates:[{templateid:$t}]}')"; then
        ok "Template '$APT_TPL_NAME' verknüpft."
      else
        warn "Template konnte nicht verknüpft werden: $API_ERR"
      fi
    fi
  else
    params=$(jq -nc --arg h "$HOST_NAME" --arg g "$GROUP_ID" --arg ip "$HOST_IP" \
      --arg tpl "$TEMPLATE_ID" --arg apt "$APT_TPL_ID" --arg idn "$PSK_IDENTITY" --arg psk "$PSK_KEY" \
      --argjson mb "$MONITORED_BY" --argjson px "$proxy_part" \
      --argjson tc "$tls_connect" --argjson ta "$tls_accept" \
      '{host:$h, groups:[{groupid:$g}],
        templates:([$tpl, $apt] | map(select(. != "")) | unique | map({templateid:.})),
        monitored_by:$mb, tls_connect:$tc, tls_accept:$ta,
        tls_psk_identity:$idn, tls_psk:$psk}
       + (if $ip == "" then {}
          else {interfaces:[{type:1, main:1, useip:1, ip:$ip, dns:"", port:"10050"}]} end)
       + $px')
    if api_call host.create "$params"; then
      HOST_ID=$(jq -r '.hostids[0]' <<<"$API_RESULT")
      ok "Host '$HOST_NAME' angelegt (ID $HOST_ID)."
      [[ -n $APT_TPL_ID ]] && ok "Template '$APT_TPL_NAME' verknüpft."
      API_DONE=1
    else
      warn "host.create fehlgeschlagen: $API_ERR"
    fi
  fi
}

final_report() {
  local line="=================================================================="
  printf '\n%s%s%s\n' "$C_G" "$line" "$C_0"
  printf '%s  Zabbix Agent eingerichtet%s\n' "$C_BOLD" "$C_0"
  printf '%s%s%s\n' "$C_G" "$line" "$C_0"
  printf '  %-16s %s\n' "Host:" "$HOST_NAME${HOST_IP:+ ($HOST_IP)}"
  printf '  %-16s %s\n' "Agent:" "$AGENT_PKG / Dienst $AGENT_SVC"
  printf '  %-16s %s\n' "PSK-Identity:" "$PSK_IDENTITY"
  printf '  %-16s %s\n' "PSK:" "$PSK_KEY"
  printf '  %-16s %s\n' "PSK-Datei:" "$PSK_FILE"
  if ((API_DONE)); then
    printf '  %-16s %s\n' "Frontend:" "per API eingetragen (Host-ID $HOST_ID)"
  else
    printf '  %-16s %s\n' "Frontend:" "MANUELL eintragen: Host → Verschlüsselung → PSK"
    case $MODE in
      active)  echo "                   (Verbindungen vom Host: PSK – kein Agent-Interface anlegen)" ;;
      passive) echo "                   (Verbindungen zum Host: PSK)" ;;
      both)    echo "                   (Verbindungen zum und vom Host: PSK)" ;;
    esac
  fi
  if ((APT_UPDATES)); then
    printf '  %-16s %s\n' "apt-Updates:" "$APT_UP_DIR/$APT_UP_FILE, $APT_SUDOERS"
    if ((API_DONE)) && [[ -n $APT_TPL_ID ]]; then
      printf '  %-16s %s\n' "" "Template '$APT_TPL_NAME' verknüpft"
    else
      printf '  %-16s %s\n' "" "Template '$APT_TPL_NAME' MANUELL verknüpfen"
    fi
  fi
  printf '  %-16s %s\n' "Install-Log:" "$LOGFILE"
  printf '%s%s%s\n\n' "$C_G" "$line" "$C_0"
}

# =============================================================================
#  Aufräumen: Script-Datei bzw. sauberen Git-Clone nach Rückfrage löschen
# =============================================================================
cleanup_self() {
  local path top url reason=""
  path=$(readlink -f "${BASH_SOURCE[0]:-}" 2>/dev/null || true)
  # Per "curl | bash" o. ä. gestartet -> keine Datei zum Löschen
  [[ -n $path && -f $path && $path != /dev/* && $path != /proc/* ]] || return 0

  header "Aufräumen"
  if [[ -d $SCRIPT_DIR/.git ]]; then
    top=$SCRIPT_DIR
    # Nur einen sauberen Clone dieses Repos anbieten – sonst droht Datenverlust
    if ! command -v git >/dev/null 2>&1; then
      reason="git ist nicht installiert, der Zustand des Clones lässt sich nicht prüfen"
    else
      url=$(git -C "$top" config --get remote.origin.url 2>/dev/null || true)
      if [[ ! $url =~ [/:]hannes4060/zabbix(\.git)?/?$ ]]; then
        reason="kein Clone von hannes4060/zabbix (origin: ${url:-keiner})"
      elif [[ -n $(git -C "$top" status --porcelain 2>/dev/null) ]]; then
        reason="es gibt geänderte oder ungetrackte Dateien"
      elif ! git -C "$top" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        reason="der Branch hat kein Upstream – ungepushte Commits nicht prüfbar"
      elif [[ $(git -C "$top" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 1) != 0 ]]; then
        reason="es gibt lokale Commits, die nicht gepusht sind"
      elif [[ -n $(git -C "$top" stash list 2>/dev/null) ]]; then
        reason="es gibt einen git stash"
      fi
    fi
    # Grundsätzlich nie Systemverzeichnisse oder Home-Verzeichnisse löschen
    case $top in
      / | /root | /home | /home/* | /etc | /etc/* | /usr | /usr/* | /var | /opt | /srv | /tmp)
        [[ $top == /home/*/* || $top == /tmp/* ]] || reason="Verzeichnis $top ist geschützt" ;;
    esac
    [[ $top == "$HOME" ]] && reason="Verzeichnis ist das Home-Verzeichnis"

    if [[ -n $reason ]]; then
      info "Git-Clone $top bleibt erhalten: $reason."
      return 0
    fi
    if ask_yn "Git-Clone $top löschen (sauber, alles gepusht)?" n; then
      cd / && rm -rf -- "$top" && ok "Git-Clone $top gelöscht."
      info "Stand deine Shell in $top, wechsle mit 'cd ~' heraus."
    fi
  else
    if ask_yn "Script-Datei $path löschen?" n; then
      rm -f -- "$path" && ok "Script-Datei $path gelöscht."
    fi
  fi
  return 0
}

# =============================================================================
#  Ablauf
# =============================================================================
main() {
  if [[ ${1-} == -h || ${1-} == --help ]]; then
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  preflight
  ask_questions
  show_summary
  header "Installation"
  remove_other_agent
  install_repo
  install_agent
  write_psk
  install_apt_updates
  configure_agent
  open_firewall
  start_agent
  prune_backups
  check_ports
  test_apt_updates
  register_host
  final_report
  cleanup_self
}

main "$@"
