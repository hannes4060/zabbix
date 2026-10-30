# Zabbix

## zabbix-agent-install.sh

Interaktives Script zur Installation und Konfiguration des Zabbix Agents
(`zabbix-agent` oder `zabbix-agent2`) auf **Debian/Ubuntu** – inklusive
PSK-Verschlüsselung und optionaler Registrierung des Hosts über die Zabbix-API.

### Voraussetzungen

- Debian 12/13 oder Ubuntu 22.04/24.04/26.04 (amd64 oder arm64)
- root-Rechte (`sudo`)
- Internetzugang zu `repo.zabbix.com`
- Für die API-Registrierung: Zabbix-Frontend ab Version 7.0 und ein API-Token

### Aufruf

Script herunterladen, kurz ansehen und ausführen:

```bash
curl -fsSLO https://raw.githubusercontent.com/hannes4060/zabbix/main/zabbix-agent-install.sh
less zabbix-agent-install.sh
sudo bash zabbix-agent-install.sh
```

Oder per Git:

```bash
git clone https://github.com/hannes4060/zabbix.git
sudo bash zabbix/zabbix-agent-install.sh
```

> Das Script läuft interaktiv und stellt Fragen. Ein direktes
> `curl … | sudo bash` funktioniert deshalb nicht – erst herunterladen,
> dann ausführen.

Vorgaben lassen sich per Umgebungsvariable setzen:

```bash
sudo ZBX_VERSION=8.0 ZBX_API_URL=https://zabbix.example.de ZBX_API_TOKEN=xxxx \
  bash zabbix-agent-install.sh
```

> Ein Token in der Kommandozeile landet in der Shell-History. Lässt du
> `ZBX_API_TOKEN` weg, fragt das Script ihn verdeckt ab.

### Was das Script macht

**Ermittelt automatisch:** Betriebssystem, Version, Architektur, IP-Adresse,
FQDN sowie vorhandene Werte aus einer bestehenden Agent-Konfiguration.

**Fragt ab:**

- Zabbix-Version (Standard 8.0)
- Agent: `zabbix-agent2` oder `zabbix-agent`
- Modus: Aktiv, Passiv oder beides
- Überwachung durch Server oder Proxy inkl. Adresse(n)
  (mehrere mit `,`, HA-Knoten mit `;`)
- Hostname, bei Passiv-Checks die Interface-IP
- PSK-Identity (PSK wird erzeugt oder ein vorhandener weiterverwendet)
- Optional [apt-Updates-Überwachung](templates/apt-updates/README.md) (Standard: ja)
- Optional API-Registrierung: Frontend-URL, Token, Hostgruppe, Template, Proxy

**Führt aus (nach Bestätigung):**

1. Zabbix-Repository einrichten, Agent installieren
2. PSK nach `/etc/zabbix/zabbix_agent.psk` schreiben (`root:zabbix`, 640)
3. Optional apt-Updates: sudo-Regel `/etc/sudoers.d/zabbix-apt` (mit `visudo`
   geprüft) und UserParameter ins `zabbix_agent2.d`/`zabbix_agentd.d` legen
4. Agent-Konfiguration sichern und einen verwalteten Block schreiben
   (bei erneutem Lauf wird nur dieser Block ersetzt)
5. Konfiguration testen, Dienst starten, Erreichbarkeit von Port 10051 prüfen,
   ggf. `apt.updates.count` einmal als Benutzer `zabbix` abfragen
6. Optional `ufw`-Freigabe für Port 10050 (nur Passiv)
7. Optional Host per API anlegen bzw. PSK/Proxy eines bestehenden Hosts
   aktualisieren – inklusive apt-Updates-Template (fehlt es im Frontend, wird
   es per `configuration.import` aus dem Repo importiert)
8. Optional das Zabbix-Script *„apt-Updates prüfen“* fürs Host-Menü anlegen
   (einmalig; Helfer `/usr/local/bin/zabbix-apt-check`, freigegeben per
   `AllowKey=system.run[...]` nur für genau diesen Befehl)

### apt-Updates-Überwachung

Die Dateien kommen aus `templates/apt-updates/`: liegt das Script in einem
`git clone`, werden die lokalen Dateien genutzt, sonst lädt das Script sie von
GitHub (`ZBX_REPO_RAW` überschreibt die Quelle, z. B. für einen eigenen Fork).

| Modus | Verknüpftes Template |
|---|---|
| Aktiv, Aktiv + Passiv | *Linux updates by Zabbix agent active* |
| Passiv | *Linux updates by Zabbix agent* |

Ist am bestehenden Host bereits die andere Variante verknüpft, warnt das
Script – sonst liefe `apt update` doppelt.

### Erneut ausführen (bestehende Hosts)

Das Script kann auf bereits eingerichteten Hosts erneut laufen, z. B. um neue
Funktionen nachzurüsten (apt-Updates, Menü-Script) oder den Helfer zu aktualisieren:

- Agent-Konfiguration: nur der verwaltete Block wird ersetzt, vorher Backup.
  Server, Hostname und PSK-Identity aus der bestehenden Konfiguration werden
  als Vorgabe angeboten, der vorhandene PSK kann weiterverwendet werden.
- Frontend: Die aktuelle Überwachung (Server, Proxy) wird ausgelesen und nur
  nach ausdrücklicher Bestätigung geändert. Ein „Nein“ zur PSK-Aktualisierung
  betrifft nur PSK/TLS. Templates und das Menü-Script werden trotzdem ergänzt,
  vorhandene Template-Verknüpfungen bleiben erhalten.
- Ein bereits vorhandenes Menü-Script „apt-Updates prüfen“ wird nicht verändert.

### Modi

| Modus | Agent-Konfig | Frontend (API) |
|---|---|---|
| Aktiv | `ServerActive`, `TLSConnect=psk`; kein Passiv-Listener (agent: `StartAgents=0`, agent2: nur `127.0.0.1`) | kein Agent-Interface, „Verbindungen vom Host“: PSK |
| Passiv | `Server`, `TLSAccept=psk` | Agent-Interface, „Verbindungen zum Host“: PSK |
| Aktiv + Passiv | beides | beides |

### API-Token

Token im Frontend unter *Benutzereinstellungen → API-Tokens* erzeugen.
Benötigte API-Methoden: `apiinfo.version`, `host.get`, `host.create`,
`host.update`, `host.massadd`, `hostgroup.get`, `hostgroup.create`,
`template.get`, `proxy.get`, `hostinterface.get`, `configuration.import`,
`script.get`, `script.create`.

`configuration.import` wird nur gebraucht, wenn das apt-Updates-Template noch
nicht im Frontend existiert (Import eines Templates braucht Super-admin-Rechte
bzw. Schreibrechte auf die Gruppe *Templates/Applications*).

Empfohlen: eigener Service-Benutzer mit einer Rolle, deren API-Zugriff auf
diese Methoden beschränkt ist (Allow list).

### Log

Installationsausgaben landen in `/var/log/zabbix-agent-install.log` (Rechte 600).

### Sicherheit

- Das Repository enthält keine Zugangsdaten. PSK und API-Token werden erst
  beim Ausführen eingegeben bzw. erzeugt und nur auf dem Zielhost gespeichert.
- Bitte niemals echte Tokens, PSKs oder interne Adressen in Issues oder
  Pull Requests posten.

### Haftungsausschluss

Das Script installiert Pakete und ändert Systemkonfigurationen mit
root-Rechten. Nutzung auf eigene Verantwortung – vor dem produktiven Einsatz
bitte auf einem Testsystem ausprobieren.

## zabbix-proxy-install.sh

Interaktives Script zum Ausrollen eines Zabbix Proxys auf **Debian/Ubuntu** –
mit SQLite3, MariaDB/MySQL oder PostgreSQL, PSK-Verschlüsselung zum Server und
optionaler Registrierung des Proxys über die Zabbix-API. Aufbau, Bedienung und
Voraussetzungen wie beim Agent-Script.

### Aufruf

```bash
curl -fsSLO https://raw.githubusercontent.com/hannes4060/zabbix/main/zabbix-proxy-install.sh
less zabbix-proxy-install.sh
sudo bash zabbix-proxy-install.sh
```

Vorgaben per Umgebungsvariable (`ZBX_VERSION`, `ZBX_API_URL`, `ZBX_API_TOKEN`)
funktionieren genauso wie beim Agent-Script.

### Was das Script macht

**Fragt ab:**

- Zabbix-Version (Standard 8.0)
- Datenbank: SQLite3 (Standard), MariaDB/MySQL oder PostgreSQL – jeweils lokal
- Modus: Aktiv (Standard) oder Passiv
- Server-Adresse(n): aktiv HA-Knoten mit `;`, passiv erlaubte Server mit `,`
- Proxy-Name, bei Passiv die Adresse, unter der der Server den Proxy erreicht
- Offline-Puffer in Stunden (`ProxyOfflineBuffer`, Standard 24)
- PSK-Identity (PSK wird erzeugt oder ein vorhandener weiterverwendet)
- Bei aktivem `ufw`: Freigabe von 10051/tcp für Agent-Netze (und bei Passiv für den Server)
- Optional API-Registrierung: Frontend-URL, Token, erlaubte Proxy-Adresse,
  Proxy-Gruppe, Host zur Selbstüberwachung

**Führt aus (nach Bestätigung):**

1. Zabbix-Repository einrichten, `zabbix-proxy-<db>` installieren
2. Datenbank einrichten:
   - SQLite3: `/var/lib/zabbix/zabbix_proxy.db`, wird beim ersten Start angelegt
   - MariaDB/PostgreSQL: Server installieren, DB `zabbix_proxy` und Benutzer
     `zbx_proxy` mit Zufallspasswort anlegen, Schema importieren
     (bei erneutem Lauf wird ein vorhandenes Schema nicht angefasst)
3. PSK nach `/etc/zabbix/zabbix_proxy.psk` schreiben (`root:zabbix`, 640)
4. Proxy-Konfiguration sichern und einen verwalteten Block schreiben
   (bei erneutem Lauf wird nur dieser Block ersetzt; Datei `root:zabbix`, 640,
   da sie ggf. das DB-Passwort enthält)
5. Proxy per API anlegen bzw. aktualisieren, Dienst starten,
   Erreichbarkeit des Servers prüfen
6. Optional Host `<Proxy-Name>` mit Template *Zabbix proxy health* anlegen
   (überwacht durch den neuen Proxy)
7. Bis zu 60 s warten, bis der Server Kontakt zum Proxy meldet

### Modi

| Modus | Proxy-Konfig | Frontend (API) |
|---|---|---|
| Aktiv | `ProxyMode=0`, `Server=<Server/HA-Knoten>`, `TLSConnect=psk` | „Verbindungen vom Proxy“: PSK, optional erlaubte Adresse |
| Passiv | `ProxyMode=1`, `Server=<erlaubte Server>`, `TLSAccept=psk` | Adresse + Port 10051, „Verbindungen zum Proxy“: PSK |

### Hinweise

- Zabbix 8.0 verlangt mindestens **MariaDB 10.11** bzw. **PostgreSQL 15**.
  Ubuntu 22.04 bringt ältere Versionen mit – dort SQLite3 verwenden
  (das Script warnt).
- Proxy und Server sollten die gleiche Hauptversion haben; das Script
  vergleicht das mit der Version des Frontends.
- Ein Wechsel der Datenbank (z. B. SQLite3 → PostgreSQL) entfernt das alte
  Proxy-Paket; die alte Konfiguration wird vorher gesichert.
- Den Proxy-Host selbst (CPU, Platte, …) überwachst du anschließend mit
  `zabbix-agent-install.sh` – Überwachung durch *Zabbix-Proxy*, Adresse `127.0.0.1`.

### API-Token

Benötigte API-Methoden: `apiinfo.version`, `proxy.get`, `proxy.create`,
`proxy.update`, `proxygroup.get`, `template.get`, `host.get`, `host.create`,
`hostgroup.get`, `hostgroup.create`.

### Log

Installationsausgaben landen in `/var/log/zabbix-proxy-install.log` (Rechte 600).

## Template: Linux-Updates (apt)

Zabbix-Template, das auf Debian/Ubuntu-Hosts regelmäßig `apt update` ausführt und
die Anzahl aktualisierbarer Pakete meldet. Je eine Variante für passive und aktive
Checks, inklusive UserParameter. Installation und sudo-Regel:
[templates/apt-updates/README.md](templates/apt-updates/README.md).

## Lizenz

[MIT](LICENSE) © hannes4060

Fehler und Verbesserungsvorschläge gerne als
[Issue](https://github.com/hannes4060/zabbix/issues) oder Pull Request.
