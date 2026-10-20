#!/usr/bin/env bash
# =============================================================================
#  zabbix-proxy-install.sh
#
#  Installiert und konfiguriert einen Zabbix Proxy (SQLite3, MariaDB/MySQL oder
#  PostgreSQL) auf Debian/Ubuntu – inkl. PSK-Verschlüsselung und optionaler
#  Registrierung des Proxys im Zabbix-Frontend über die API.
#
#  Aufruf:    sudo ./zabbix-proxy-install.sh
#
#  Optional lassen sich Vorgaben per Umgebungsvariable setzen, z. B.:
#    sudo ZBX_VERSION=8.0 ZBX_API_URL=https://zabbix.example.de \
#         ZBX_API_TOKEN=xxxx ./zabbix-proxy-install.sh
#
#  Das Script kann gefahrlos erneut ausgeführt werden (z. B. zum Umkonfigurieren
#  oder für einen neuen PSK): vorhandene Werte werden als Vorgabe angeboten und
#  die Proxy-Konfiguration wird vor jeder Änderung gesichert.
# =============================================================================
set -Eeuo pipefail

# ---------- Grundeinstellungen ----------------------------------------------
ZBX_VERSION_DEFAULT="${ZBX_VERSION:-8.0}"
PROXY_CONF="/etc/zabbix/zabbix_proxy.conf"
PROXY_SVC="zabbix-proxy"
PROXY_BIN="zabbix_proxy"
PROXY_LOG="/var/log/zabbix/zabbix_proxy.log"
PSK_FILE="/etc/zabbix/zabbix_proxy.psk"
SQLITE_DB="/var/lib/zabbix/zabbix_proxy.db"
DB_NAME="zabbix_proxy"
DB_USER="zbx_proxy"
LOGFILE="/var/log/zabbix-proxy-install.log"
BLOCK_BEGIN="# BEGIN zabbix-proxy-install"
BLOCK_END="# END zabbix-proxy-install"

# ---------- Globale Variablen ------------------------------------------------
OS_ID="" OS_VER="" OS_PRETTY="" ARCH="" DEFAULT_IP=""
ZBX_VERSION=""
DB_TYPE=""         # sqlite3 | mysql | pgsql
PROXY_PKG="" OTHER_PKGS=() DB_PASS="" DB_PASS_REUSED=0
MODE=""            # active | passive
TARGETS=""         # Server-Adressen wie eingegeben
CONF_SERVER=""
PROXY_NAME="" PROXY_ADDR="" OFFLINE_BUFFER=""
PSK_IDENTITY="" PSK_KEY="" PSK_REUSED=0
REMOVE_OTHER=0 OPEN_UFW=0 UFW_AGENT_NETS="" CONF_BACKUP=""
USE_API=0 API_DONE=0
API_URL="${ZBX_API_URL:-}" API_TOKEN="${ZBX_API_TOKEN:-}" API_RESULT="" API_ERR="" API_VERSION=""
CURL_OPTS=()
PROXY_ID="" ALLOWED_ADDR=""
PGROUP_ID="" PGROUP_NAME=""
HEALTH_HOST=0 HEALTH_DONE=0 GROUP_NAME="" GROUP_ID="" GROUP_CREATE=0 TEMPLATE_ID=""
START_TS=0

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

# ask_opt VAR "Frage" [Vorgabe]   – leere Eingabe erlaubt ("-" leert eine Vorgabe)
ask_opt() {
  local __v=$1 __q=$2 __d=${3-} __a=""
  if [[ -n $__d ]]; then
    read -rp "  $__q [$__d, '-' = leer]: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
    __a=${__a:-$__d}
    [[ $__a == - ]] && __a=""
  else
    read -rp "  $__q [leer lassen = nein]: " __a || die "Keine Eingabe möglich (stdin geschlossen)."
  fi
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

# Letzten aktiven Wert eines Parameters aus einer Konfigurationsdatei lesen
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

# Ports entfernen und Semikolons durch Kommas ersetzen (Passiv: erlaubte Server)
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

set_db_vars() {
  case $1 in
    1) DB_TYPE=sqlite3 ;;
    2) DB_TYPE=mysql ;;
    3) DB_TYPE=pgsql ;;
  esac
  PROXY_PKG="zabbix-proxy-$DB_TYPE"
  OTHER_PKGS=()
  local p
  for p in zabbix-proxy-sqlite3 zabbix-proxy-mysql zabbix-proxy-pgsql; do
    [[ $p != "$PROXY_PKG" ]] && pkg_installed "$p" && OTHER_PKGS+=("$p")
  done
  return 0
}

db_label() {
  case $DB_TYPE in
    sqlite3) echo "SQLite3 ($SQLITE_DB)" ;;
    mysql)   echo "MariaDB/MySQL lokal (DB $DB_NAME, Benutzer $DB_USER)" ;;
    pgsql)   echo "PostgreSQL lokal (DB $DB_NAME, Benutzer $DB_USER)" ;;
  esac
}

# SQL als postgres-Benutzer ausführen (SQL über stdin)
pg_sql() { (cd / && runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 "$@"); }

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

  if pkg_installed zabbix-server-mysql || pkg_installed zabbix-server-pgsql; then
    warn "Auf diesem Host läuft ein Zabbix-Server – Server und Proxy nutzen beide Port 10051."
    ask_yn "Trotzdem fortfahren?" n || die "Abgebrochen."
  fi

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

  header "Datenbank"
  def=1
  if pkg_installed zabbix-proxy-mysql; then def=2; elif pkg_installed zabbix-proxy-pgsql; then def=3; fi
  choose c "Welche Datenbank soll der Proxy nutzen?" "$def" \
    "SQLite3        (empfohlen für die meisten Proxys, keine DB-Pflege)" \
    "MariaDB/MySQL  (lokal, für große Proxys)" \
    "PostgreSQL     (lokal, für große Proxys)"
  set_db_vars "$c"

  if [[ $DB_TYPE != sqlite3 ]] && ((${ZBX_VERSION%%.*} >= 8)) &&
    [[ $OS_ID == ubuntu && $OS_VER == 22.04 ]]; then
    warn "Ubuntu 22.04 bringt MariaDB 10.6 / PostgreSQL 14 mit – Zabbix 8.0 braucht"
    warn "mindestens MariaDB 10.11 bzw. PostgreSQL 15. SQLite3 ist hier die sichere Wahl."
    ask_yn "Trotzdem mit $DB_TYPE fortfahren?" n || die "Abgebrochen – bitte SQLite3 wählen."
  fi

  if ((${#OTHER_PKGS[@]})); then
    warn "Bereits installiert: ${OTHER_PKGS[*]} – es kann nur ein Proxy-Paket geben."
    ask_yn "${OTHER_PKGS[*]} stoppen und entfernen (Konfiguration wird gesichert)?" j ||
      die "Abgebrochen – es wurde nichts verändert."
    REMOVE_OTHER=1
  fi

  # Vorgaben aus bestehender Konfiguration (bei erneutem Lauf)
  local cfg_mode cfg_s cfg_host cfg_buf
  cfg_mode=$(get_conf "$PROXY_CONF" ProxyMode)
  cfg_s=$(get_conf "$PROXY_CONF" Server)
  cfg_host=$(get_conf "$PROXY_CONF" Hostname)
  cfg_buf=$(get_conf "$PROXY_CONF" ProxyOfflineBuffer)
  [[ $cfg_s == 127.0.0.1 ]] && cfg_s=""
  [[ $cfg_host == "Zabbix proxy" ]] && cfg_host=""

  if [[ $DB_TYPE != sqlite3 ]] && ((REMOVE_OTHER == 0)); then
    DB_PASS=$(get_conf "$PROXY_CONF" DBPassword)
    [[ -n $DB_PASS ]] && DB_PASS_REUSED=1
  fi
  [[ $DB_TYPE != sqlite3 && -z $DB_PASS ]] && DB_PASS=$(openssl rand -hex 24)

  header "Betriebsmodus"
  def=1
  [[ $cfg_mode == 1 ]] && def=2
  choose c "Wie soll der Proxy arbeiten?" "$def" \
    "Aktiv   – Proxy verbindet sich zum Server (Port 10051 ausgehend, empfohlen)" \
    "Passiv  – Server verbindet sich zum Proxy (Port 10051 eingehend)"
  case $c in 1) MODE=active ;; 2) MODE=passive ;; esac

  header "Zabbix-Server"
  if [[ $MODE == active ]]; then
    echo "  Knoten eines Server-HA-Clusters mit Semikolon trennen, optionaler Port als host:port."
    while :; do
      ask TARGETS "Adresse(n) des Zabbix-Servers (IP oder DNS)" "$cfg_s"
      TARGETS=${TARGETS//[[:space:]]/}
      [[ $TARGETS != *,* ]] && break
      warn "Ein aktiver Proxy spricht nur mit einem Server bzw. HA-Cluster – HA-Knoten mit ';' trennen."
    done
    CONF_SERVER=$TARGETS
  else
    echo "  Erlaubte Server-Adressen mit Komma trennen (bei HA alle Knoten angeben)."
    ask TARGETS "Adresse(n) des Zabbix-Servers (IP, Netz oder DNS)" "$cfg_s"
    TARGETS=${TARGETS//[[:space:]]/}
    CONF_SERVER=$(to_server_list "$TARGETS")
  fi

  header "Proxy"
  local def_host
  def_host=${cfg_host:-$(hostname -f 2>/dev/null || hostname)}
  while :; do
    ask PROXY_NAME "Proxy-Name (muss exakt dem Proxy-Namen im Frontend entsprechen)" "$def_host"
    [[ $PROXY_NAME =~ ^[A-Za-z0-9._\ -]+$ ]] && break
    warn "Erlaubt sind Buchstaben, Ziffern, Leerzeichen, Punkt, Bindestrich und Unterstrich."
  done
  if [[ $MODE == passive ]]; then
    ask PROXY_ADDR "Adresse, unter der der Server den Proxy erreicht (IP oder DNS)" "$DEFAULT_IP"
  fi
  while :; do
    ask OFFLINE_BUFFER "Daten bei Server-Ausfall puffern für (Stunden, 1–720)" "${cfg_buf:-24}"
    [[ $OFFLINE_BUFFER =~ ^[0-9]+$ ]] && ((OFFLINE_BUFFER >= 1 && OFFLINE_BUFFER <= 720)) && break
    warn "Bitte eine Zahl zwischen 1 und 720 eingeben."
  done

  header "PSK-Verschlüsselung (Proxy ↔ Server)"
  local old_id
  old_id=$(get_conf "$PROXY_CONF" TLSPSKIdentity)
  if [[ -s $PSK_FILE && -n $old_id ]] &&
    ask_yn "Vorhandenen PSK weiterverwenden (Identity: $old_id)?" j; then
    PSK_IDENTITY=$old_id
    PSK_KEY=$(tr -d '[:space:]' <"$PSK_FILE")
    PSK_REUSED=1
    ok "Bestehender PSK wird weiterverwendet."
  else
    ask PSK_IDENTITY "PSK-Identity" "PSK-${PROXY_NAME// /_}"
    PSK_KEY=$(openssl rand -hex 32)
    ok "Neuer 256-Bit-PSK erzeugt."
  fi

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    header "Firewall"
    echo "  Aktive Agents senden ihre Daten an Port 10051 des Proxys."
    ask_opt UFW_AGENT_NETS "Agent-Netze für 10051/tcp freigeben (z. B. 10.0.0.0/8,192.168.1.0/24, 'any')"
    UFW_AGENT_NETS=${UFW_AGENT_NETS//[[:space:]]/}
    if [[ $MODE == passive ]]; then
      ask_yn "Port 10051/tcp für den Zabbix-Server ($CONF_SERVER) freigeben?" j && OPEN_UFW=1
    fi
    [[ -n $UFW_AGENT_NETS ]] && OPEN_UFW=1
  fi

  header "Registrierung im Zabbix-Frontend"
  if ask_yn "Proxy automatisch per API anlegen bzw. aktualisieren?" j; then
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
      warn "Das Script nutzt die Proxy-API ab Zabbix 7.0 – Registrierung übersprungen."
      USE_API=0
      return 0
    fi
    if [[ ${API_VERSION%.*} != "$ZBX_VERSION" ]]; then
      warn "Frontend ist Zabbix $API_VERSION, installiert wird Proxy $ZBX_VERSION."
      warn "Der Proxy sollte die gleiche Hauptversion wie der Server haben."
      ask_yn "Trotzdem fortfahren?" n || die "Abgebrochen – es wurde nichts verändert."
    fi

    if [[ -z $API_TOKEN ]]; then
      read -rsp "  API-Token (Benutzereinstellungen → API-Tokens): " API_TOKEN || die "Keine Eingabe."
      echo
    fi
    if api_call proxy.get '{"output":["proxyid"],"limit":1}'; then
      ok "Token gültig."
      break
    fi
    warn "Token abgelehnt: $API_ERR"
    API_TOKEN=""
    ask_yn "Erneut versuchen?" j || { USE_API=0; return 0; }
  done

  # --- Existiert der Proxy bereits? ---
  api proxy.get "$(jq -nc --arg n "$PROXY_NAME" '{output:["proxyid","operating_mode","proxy_groupid","allowed_addresses","local_address"], filter:{name:[$n]}}')"
  PROXY_ID=$(jq -r '.[0].proxyid // empty' <<<"$API_RESULT")
  local cur_group="" cur_allowed="" cur_local=""
  if [[ -n $PROXY_ID ]]; then
    cur_group=$(jq -r '.[0].proxy_groupid // "0"' <<<"$API_RESULT")
    cur_allowed=$(jq -r '.[0].allowed_addresses // ""' <<<"$API_RESULT")
    cur_local=$(jq -r '.[0].local_address // ""' <<<"$API_RESULT")
    [[ $cur_group == 0 ]] && cur_group=""
    warn "Proxy '$PROXY_NAME' existiert bereits im Frontend (ID $PROXY_ID)."
    if ! ask_yn "Modus, PSK und Adressen dieses Proxys aktualisieren?" j; then
      USE_API=0
      return 0
    fi
  fi

  # --- Aktiv: erlaubte Absenderadresse ---
  if [[ $MODE == active ]]; then
    echo "  Optional: Nur Verbindungen von dieser Adresse als Proxy akzeptieren"
    echo "  (Achtung bei NAT – dann die öffentliche Adresse angeben)."
    ask_opt ALLOWED_ADDR "Proxy-Adresse im Frontend einschränken auf" "$cur_allowed"
    ALLOWED_ADDR=${ALLOWED_ADDR//[[:space:]]/}
  fi

  # --- Proxy-Gruppe (Lastverteilung/HA, ab Zabbix 7.0) ---
  if api_call proxygroup.get '{"output":["proxy_groupid","name"],"sortfield":"name"}'; then
    local -a gnames gids
    mapfile -t gnames < <(jq -r '.[].name' <<<"$API_RESULT")
    mapfile -t gids < <(jq -r '.[].proxy_groupid' <<<"$API_RESULT")
    if ((${#gids[@]})); then
      local gdef=1 i
      for i in "${!gids[@]}"; do [[ ${gids[$i]} == "$cur_group" ]] && gdef=$((i + 2)); done
      choose c "Proxy einer Proxy-Gruppe zuordnen?" "$gdef" "Keine Gruppe" "${gnames[@]}"
      if ((c > 1)); then
        PGROUP_ID=${gids[c - 2]}
        PGROUP_NAME=${gnames[c - 2]}
        ask PROXY_ADDR "Adresse, unter der Agents diesen Proxy erreichen (für die Gruppe)" \
          "${cur_local:-${PROXY_ADDR:-$DEFAULT_IP}}"
      fi
    fi
  else
    warn "Proxy-Gruppen konnten nicht abgefragt werden ($API_ERR) – übersprungen."
  fi

  # --- Host zur Selbstüberwachung ---
  echo
  echo "  Der Proxy kann sich selbst überwachen (interne Items: Queue, Caches, Prozesse)."
  if ask_yn "Host '$PROXY_NAME' mit Template 'Zabbix proxy health' anlegen?" j; then
    api template.get '{"output":["templateid"],"filter":{"host":["Zabbix proxy health"]}}'
    TEMPLATE_ID=$(jq -r '.[0].templateid // empty' <<<"$API_RESULT")
    if [[ -z $TEMPLATE_ID ]]; then
      warn "Template 'Zabbix proxy health' nicht gefunden – übersprungen."
    else
      api host.get "$(jq -nc --arg h "$PROXY_NAME" '{output:["hostid"], filter:{host:[$h]}}')"
      if [[ -n $(jq -r '.[0].hostid // empty' <<<"$API_RESULT") ]]; then
        warn "Ein Host '$PROXY_NAME' existiert bereits – Template ggf. manuell verknüpfen."
      else
        HEALTH_HOST=1
        while :; do
          ask GROUP_NAME "Hostgruppe" "${GROUP_NAME:-Zabbix proxies}"
          api hostgroup.get "$(jq -nc --arg n "$GROUP_NAME" '{output:["groupid"], filter:{name:[$n]}}')"
          GROUP_ID=$(jq -r '.[0].groupid // empty' <<<"$API_RESULT")
          [[ -n $GROUP_ID ]] && break
          if ask_yn "Gruppe '$GROUP_NAME' existiert nicht – anlegen?" j; then
            GROUP_CREATE=1
            break
          fi
        done
      fi
    fi
  fi
}

show_summary() {
  header "Zusammenfassung"
  printf '  %-22s %s\n' "System:" "$OS_PRETTY ($ARCH)"
  printf '  %-22s %s\n' "Zabbix-Version:" "$ZBX_VERSION"
  printf '  %-22s %s\n' "Paket:" "$PROXY_PKG"
  printf '  %-22s %s\n' "Datenbank:" "$(db_label)"
  [[ $DB_TYPE != sqlite3 ]] &&
    printf '  %-22s %s\n' "DB-Passwort:" "$([[ $DB_PASS_REUSED == 1 ]] && echo 'aus bestehender Konfig' || echo 'neu erzeugt')"
  printf '  %-22s %s\n' "Modus:" "$([[ $MODE == active ]] && echo Aktiv || echo Passiv)"
  printf '  %-22s %s\n' "Server=" "$CONF_SERVER"
  printf '  %-22s %s\n' "Proxy-Name:" "$PROXY_NAME"
  [[ -n $PROXY_ADDR ]] && printf '  %-22s %s\n' "Proxy-Adresse:" "$PROXY_ADDR"
  printf '  %-22s %s\n' "Offline-Puffer:" "$OFFLINE_BUFFER h"
  printf '  %-22s %s\n' "PSK-Identity:" "$PSK_IDENTITY $([[ $PSK_REUSED == 1 ]] && echo '(bestehend)' || echo '(neu)')"
  ((REMOVE_OTHER)) && printf '  %-22s %s\n' "Entfernen:" "${OTHER_PKGS[*]}"
  if ((OPEN_UFW)); then
    [[ $MODE == passive ]] && printf '  %-22s %s\n' "Firewall (Server):" "ufw 10051/tcp von $CONF_SERVER"
    [[ -n $UFW_AGENT_NETS ]] && printf '  %-22s %s\n' "Firewall (Agents):" "ufw 10051/tcp von $UFW_AGENT_NETS"
  fi
  if ((USE_API)); then
    if [[ -n $PROXY_ID ]]; then
      printf '  %-22s %s\n' "API:" "bestehenden Proxy aktualisieren (ID $PROXY_ID)"
    else
      printf '  %-22s %s\n' "API:" "Proxy anlegen"
    fi
    [[ -n $ALLOWED_ADDR ]] && printf '  %-22s %s\n' "Erlaubte Adresse:" "$ALLOWED_ADDR"
    printf '  %-22s %s\n' "Proxy-Gruppe:" "${PGROUP_NAME:-keine}"
    if ((HEALTH_HOST)); then
      printf '  %-22s %s\n' "Selbstüberwachung:" "Host '$PROXY_NAME' in '$GROUP_NAME'$([[ $GROUP_CREATE == 1 ]] && echo ' (neu)')"
    fi
  else
    printf '  %-22s %s\n' "API:" "nein – Proxy manuell im Frontend anlegen"
  fi
  echo
  ask_yn "Installation jetzt durchführen?" j || die "Abgebrochen – es wurde nichts verändert."
}

# =============================================================================
#  3) Installation & Konfiguration
# =============================================================================
remove_other_proxy() {
  ((REMOVE_OTHER)) || return 0
  local p
  systemctl disable --now "$PROXY_SVC" >>"$LOGFILE" 2>&1 || true
  if [[ -f $PROXY_CONF ]]; then
    cp -a "$PROXY_CONF" "$PROXY_CONF.vor-db-wechsel.$(date +%Y%m%d-%H%M%S)"
  fi
  for p in "${OTHER_PKGS[@]}"; do
    info "Entferne $p ..."
    run env DEBIAN_FRONTEND=noninteractive apt-get purge -y "$p"
    ok "$p entfernt."
  done
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

install_proxy() {
  local -a pkgs=("$PROXY_PKG")
  case $DB_TYPE in
    mysql) pkgs+=(zabbix-sql-scripts mariadb-server mariadb-client) ;;
    pgsql) pkgs+=(zabbix-sql-scripts postgresql) ;;
  esac
  info "Installiere ${pkgs[*]} ..."
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::=--force-confold "${pkgs[@]}"
  local v
  v=$(dpkg-query -W -f='${Version}' "$PROXY_PKG")
  if [[ $v == *":${ZBX_VERSION}."* || $v == "${ZBX_VERSION}."* ]]; then
    ok "$PROXY_PKG $v installiert."
  else
    warn "Installierte Version $v passt nicht zu $ZBX_VERSION – prüfe 'apt policy $PROXY_PKG'."
  fi
  # Dienst erst starten, wenn alles konfiguriert ist
  systemctl stop "$PROXY_SVC" >>"$LOGFILE" 2>&1 || true
}

setup_db() {
  case $DB_TYPE in
    sqlite3) setup_sqlite ;;
    mysql)   setup_mysql ;;
    pgsql)   setup_pgsql ;;
  esac
}

setup_sqlite() {
  install -d -o zabbix -g zabbix -m 750 "$(dirname "$SQLITE_DB")"
  if [[ -f $SQLITE_DB ]]; then
    ok "SQLite-Datenbank vorhanden ($SQLITE_DB)."
  else
    ok "SQLite-Datenbank wird beim ersten Start angelegt ($SQLITE_DB)."
  fi
}

setup_mysql() {
  local schema=/usr/share/zabbix/sql-scripts/mysql/proxy.sql n
  run systemctl enable --now mariadb
  mysql -e "SELECT 1" >/dev/null 2>&1 ||
    die "Kein root-Zugriff auf MariaDB per Unix-Socket – DB bitte manuell anlegen."

  info "Lege Datenbank $DB_NAME und Benutzer $DB_USER an ..."
  # Passwort über stdin -> taucht nicht in "ps" oder im Log auf
  run mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_bin;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

  n=$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME'")
  if ((n > 0)); then
    ok "Schema bereits vorhanden ($n Tabellen) – Import übersprungen."
  else
    [[ -f $schema ]] || die "Schema $schema nicht gefunden (Paket zabbix-sql-scripts?)."
    info "Importiere Proxy-Schema ..."
    run mysql -e "SET GLOBAL log_bin_trust_function_creators = 1"
    if ! mysql --default-character-set=utf8mb4 "$DB_NAME" <"$schema" >>"$LOGFILE" 2>&1; then
      mysql -e "SET GLOBAL log_bin_trust_function_creators = 0" >>"$LOGFILE" 2>&1 || true
      die "Schema-Import fehlgeschlagen (Details: $LOGFILE)"
    fi
    run mysql -e "SET GLOBAL log_bin_trust_function_creators = 0"
    ok "Schema importiert."
  fi
  ok "MariaDB eingerichtet ($(mysql -N -e 'SELECT VERSION()'))."
}

setup_pgsql() {
  local schema=/usr/share/zabbix/sql-scripts/postgresql/proxy.sql n
  run systemctl enable --now postgresql

  info "Lege Datenbank $DB_NAME und Benutzer $DB_USER an ..."
  # Passwort über stdin -> taucht nicht in "ps" oder im Log auf
  run pg_sql <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
    CREATE ROLE $DB_USER LOGIN;
  END IF;
END \$\$;
ALTER ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';
SQL
  if [[ -z $(pg_sql -tA -c "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" </dev/null) ]]; then
    run pg_sql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0" </dev/null
  fi

  n=$(pg_sql -d "$DB_NAME" -tA -c \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'" </dev/null)
  if ((n > 0)); then
    ok "Schema bereits vorhanden ($n Tabellen) – Import übersprungen."
  else
    [[ -f $schema ]] || die "Schema $schema nicht gefunden (Paket zabbix-sql-scripts?)."
    info "Importiere Proxy-Schema ..."
    # Als Rolle des Proxys importieren, damit ihr die Tabellen gehören
    run pg_sql -d "$DB_NAME" < <(echo "SET ROLE $DB_USER;"; cat "$schema")
    ok "Schema importiert."
  fi
  ok "PostgreSQL eingerichtet ($(pg_sql -tA -c 'SHOW server_version' </dev/null))."
}

write_psk() {
  install -d -m 755 /etc/zabbix
  (umask 077 && printf '%s\n' "$PSK_KEY" >"$PSK_FILE")
  chown root:zabbix "$PSK_FILE"
  chmod 640 "$PSK_FILE"
  ok "PSK gespeichert: $PSK_FILE"
}

configure_proxy() {
  local f=$PROXY_CONF k
  [[ -f $f ]] || die "Konfigurationsdatei $f nicht gefunden."
  CONF_BACKUP="$f.bak.$(date +%Y%m%d-%H%M%S)"
  cp -a "$f" "$CONF_BACKUP"

  # Alten verwalteten Block entfernen, dann betroffene Parameter auskommentieren
  sed -i "/^${BLOCK_BEGIN}/,/^${BLOCK_END}/d" "$f"
  for k in ProxyMode Server Hostname HostnameItem DBHost DBName DBSchema DBUser \
    DBPassword DBSocket DBPort ProxyOfflineBuffer \
    TLSConnect TLSAccept TLSPSKIdentity TLSPSKFile; do
    sed -i -E "s/^[[:space:]]*${k}[[:space:]]*=/# &/" "$f"
  done

  {
    echo "$BLOCK_BEGIN – $(date '+%F %T') – wird bei erneutem Lauf des Scripts ersetzt"
    if [[ $MODE == active ]]; then
      echo "ProxyMode=0"
    else
      echo "ProxyMode=1"
    fi
    echo "Server=$CONF_SERVER"
    echo "Hostname=$PROXY_NAME"
    case $DB_TYPE in
      sqlite3)
        echo "DBName=$SQLITE_DB"
        ;;
      mysql)
        echo "DBHost=localhost"
        echo "DBName=$DB_NAME"
        echo "DBUser=$DB_USER"
        echo "DBPassword=$DB_PASS"
        ;;
      pgsql)
        echo "DBHost=localhost"
        echo "DBName=$DB_NAME"
        echo "DBUser=$DB_USER"
        echo "DBPassword=$DB_PASS"
        ;;
    esac
    echo "ProxyOfflineBuffer=$OFFLINE_BUFFER"
    if [[ $MODE == active ]]; then
      echo "TLSConnect=psk"     # Proxy -> Server
    else
      echo "TLSAccept=psk"      # Server -> Proxy
    fi
    echo "TLSPSKIdentity=$PSK_IDENTITY"
    echo "TLSPSKFile=$PSK_FILE"
    echo "$BLOCK_END"
  } >>"$f"

  # Enthält ggf. das DB-Passwort
  chown root:zabbix "$f"
  chmod 640 "$f"

  local out
  if ! out=$("$PROXY_BIN" -T -c "$f" 2>&1) &&
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

open_firewall() {
  ((OPEN_UFW)) || return 0
  local e
  ufw_rule() {
    local src=$1 what=$2
    if [[ ${src,,} == any ]]; then
      ufw allow 10051/tcp >>"$LOGFILE" 2>&1 && ok "ufw: 10051/tcp von überall erlaubt ($what)." && return 0
    elif ufw allow from "$src" to any port 10051 proto tcp >>"$LOGFILE" 2>&1; then
      ok "ufw: 10051/tcp von $src erlaubt ($what)."
      return 0
    fi
    warn "ufw-Regel für '$src' fehlgeschlagen (ufw erwartet IP/Netz, keinen DNS-Namen)."
  }
  if [[ $MODE == passive ]]; then
    while IFS= read -r e; do ufw_rule "$e" "Server"; done < <(split_targets "$CONF_SERVER")
  fi
  while IFS= read -r e; do ufw_rule "$e" "Agents"; done < <(split_targets "$UFW_AGENT_NETS")
}

register_proxy() {
  ((USE_API)) || return 0
  info "Registriere Proxy im Frontend ..."

  # TLS (1 = unverschlüsselt, 2 = PSK)
  #   aktiv:  Proxy verbindet sich zum Server  -> tls_accept = PSK
  #   passiv: Server verbindet sich zum Proxy  -> tls_connect = PSK
  local mode_num=0 tls_connect=1 tls_accept=2
  if [[ $MODE == passive ]]; then
    mode_num=1 tls_connect=2 tls_accept=1
  fi

  local params
  params=$(jq -nc --arg n "$PROXY_NAME" --argjson m "$mode_num" \
    --argjson tc "$tls_connect" --argjson ta "$tls_accept" \
    --arg idn "$PSK_IDENTITY" --arg psk "$PSK_KEY" \
    --arg addr "$PROXY_ADDR" --arg allowed "$ALLOWED_ADDR" --arg grp "$PGROUP_ID" \
    '{name:$n, operating_mode:$m, tls_connect:$tc, tls_accept:$ta,
      tls_psk_identity:$idn, tls_psk:$psk}
     + (if $m == 1 then {address:$addr, port:"10051"} else {allowed_addresses:$allowed} end)
     + (if $grp == "" then {proxy_groupid:"0"}
        else {proxy_groupid:$grp, local_address:$addr, local_port:"10051"} end)')

  if [[ -n $PROXY_ID ]]; then
    params=$(jq -c --arg id "$PROXY_ID" '. + {proxyid:$id}' <<<"$params")
    if api_call proxy.update "$params"; then
      ok "Proxy '$PROXY_NAME' aktualisiert (ID $PROXY_ID)."
      API_DONE=1
    else
      warn "proxy.update fehlgeschlagen: $API_ERR"
    fi
  else
    params=$(jq -c --arg d "Ausgerollt per zabbix-proxy-install.sh am $(date '+%F')" \
      '. + {description:$d}' <<<"$params")
    if api_call proxy.create "$params"; then
      PROXY_ID=$(jq -r '.proxyids[0]' <<<"$API_RESULT")
      ok "Proxy '$PROXY_NAME' angelegt (ID $PROXY_ID)."
      API_DONE=1
    else
      warn "proxy.create fehlgeschlagen: $API_ERR"
    fi
  fi
}

start_proxy() {
  START_TS=$(date +%s)
  run systemctl enable "$PROXY_SVC"
  systemctl restart "$PROXY_SVC" >>"$LOGFILE" 2>&1 || true
  sleep 5
  if systemctl is-active --quiet "$PROXY_SVC"; then
    ok "$PROXY_SVC läuft."
  else
    warn "$PROXY_SVC läuft NICHT. Letzte Logzeilen:"
    tail -n 15 "$PROXY_LOG" 2>/dev/null >&2 || journalctl -u "$PROXY_SVC" -n 15 --no-pager >&2 || true
  fi
}

check_ports() {
  [[ $MODE == active ]] || return 0
  local e h p
  while IFS= read -r e; do
    if [[ $e =~ ^\[(.+)\]:([0-9]+)$ || $e =~ ^([^:]+):([0-9]+)$ ]]; then
      h=${BASH_REMATCH[1]} p=${BASH_REMATCH[2]}
    else
      h=$e p=10051
    fi
    if timeout 3 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$h" "$p" 2>/dev/null; then
      ok "Server $h:$p erreichbar."
    else
      warn "Server $h:$p nicht erreichbar – Firewall/DNS prüfen."
    fi
  done < <(split_targets "$CONF_SERVER")
}

register_health_host() {
  ((USE_API && API_DONE && HEALTH_HOST)) || return 0

  if ((GROUP_CREATE)); then
    if ! api_call hostgroup.create "$(jq -nc --arg n "$GROUP_NAME" '{name:$n}')"; then
      warn "Hostgruppe konnte nicht angelegt werden: $API_ERR"
      return 0
    fi
    GROUP_ID=$(jq -r '.groupids[0]' <<<"$API_RESULT")
    ok "Hostgruppe '$GROUP_NAME' angelegt."
  fi

  local params
  params=$(jq -nc --arg h "$PROXY_NAME" --arg g "$GROUP_ID" --arg t "$TEMPLATE_ID" --arg p "$PROXY_ID" \
    '{host:$h, groups:[{groupid:$g}], templates:[{templateid:$t}], monitored_by:1, proxyid:$p}')
  if api_call host.create "$params"; then
    ok "Host '$PROXY_NAME' zur Selbstüberwachung angelegt (ID $(jq -r '.hostids[0]' <<<"$API_RESULT"))."
    HEALTH_DONE=1
  else
    warn "host.create fehlgeschlagen: $API_ERR"
  fi
}

# Warten, bis der Server den Proxy sieht (letzter Kontakt nach dem Start)
wait_for_proxy() {
  ((USE_API && API_DONE)) || return 0
  systemctl is-active --quiet "$PROXY_SVC" || return 0
  info "Warte auf Verbindung zwischen Server und Proxy (bis 60 s) ..."
  local i last ver
  for ((i = 0; i < 12; i++)); do
    if api_call proxy.get "$(jq -nc --arg id "$PROXY_ID" '{output:["lastaccess","version"], proxyids:[$id]}')"; then
      last=$(jq -r '.[0].lastaccess // 0' <<<"$API_RESULT")
      if ((last >= START_TS)); then
        ver=$(jq -r '.[0].version // ""' <<<"$API_RESULT")
        ok "Server hat Kontakt zum Proxy$([[ -n $ver && $ver != 0 ]] && echo " (Version-ID $ver)")."
        return 0
      fi
    fi
    sleep 5
  done
  warn "Noch kein Kontakt. Prüfe: tail -f $PROXY_LOG und das Server-Log."
  warn "Häufige Ursachen: Proxy-Name/PSK passen nicht, Port 10051 gesperrt, falscher Modus."
}

final_report() {
  local line="=================================================================="
  printf '\n%s%s%s\n' "$C_G" "$line" "$C_0"
  printf '%s  Zabbix Proxy eingerichtet%s\n' "$C_BOLD" "$C_0"
  printf '%s%s%s\n' "$C_G" "$line" "$C_0"
  printf '  %-16s %s\n' "Proxy:" "$PROXY_NAME ($([[ $MODE == active ]] && echo aktiv || echo passiv))"
  printf '  %-16s %s\n' "Paket:" "$PROXY_PKG / Dienst $PROXY_SVC"
  printf '  %-16s %s\n' "Datenbank:" "$(db_label)"
  printf '  %-16s %s\n' "PSK-Identity:" "$PSK_IDENTITY"
  printf '  %-16s %s\n' "PSK:" "$PSK_KEY"
  printf '  %-16s %s\n' "PSK-Datei:" "$PSK_FILE"
  if ((API_DONE)); then
    printf '  %-16s %s\n' "Frontend:" "per API eingetragen (Proxy-ID $PROXY_ID)"
    ((HEALTH_DONE)) && printf '  %-16s %s\n' "" "Host '$PROXY_NAME' mit 'Zabbix proxy health' angelegt"
  else
    printf '  %-16s %s\n' "Frontend:" "MANUELL eintragen: Administration → Proxys → Proxy anlegen"
    if [[ $MODE == active ]]; then
      echo "                   (Modus Aktiv, Verschlüsselung: Verbindungen vom Proxy: PSK)"
    else
      echo "                   (Modus Passiv, Adresse $PROXY_ADDR:10051,"
      echo "                    Verschlüsselung: Verbindungen zum Proxy: PSK)"
    fi
  fi
  printf '  %-16s %s\n' "Proxy-Log:" "$PROXY_LOG"
  printf '  %-16s %s\n' "Install-Log:" "$LOGFILE"
  echo
  echo "  Tipp: Den Proxy-Host selbst überwachst du mit zabbix-agent-install.sh"
  echo "        (Überwachung durch: Zabbix-Proxy, Adresse 127.0.0.1)."
  printf '%s%s%s\n\n' "$C_G" "$line" "$C_0"
}

# =============================================================================
#  Ablauf
# =============================================================================
main() {
  if [[ ${1-} == -h || ${1-} == --help ]]; then
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
  fi
  preflight
  ask_questions
  show_summary
  header "Installation"
  remove_other_proxy
  install_repo
  install_proxy
  setup_db
  write_psk
  configure_proxy
  open_firewall
  register_proxy
  start_proxy
  check_ports
  register_health_host
  wait_for_proxy
  final_report
}

main "$@"
