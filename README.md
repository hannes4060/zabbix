# Zabbix

## zabbix-agent-install.sh

Interaktives Script zur Installation und Konfiguration des Zabbix Agents
(`zabbix-agent` oder `zabbix-agent2`) auf **Debian/Ubuntu** – inklusive
PSK-Verschlüsselung und optionaler Registrierung des Hosts über die Zabbix-API.

### Aufruf

```bash
curl -fsSLO https://raw.githubusercontent.com/hannes4060/zabbix/main/zabbix-agent-install.sh
sudo bash zabbix-agent-install.sh
```

Vorgaben lassen sich per Umgebungsvariable setzen:

```bash
sudo ZBX_VERSION=8.0 ZBX_API_URL=https://zabbix.example.de ZBX_API_TOKEN=xxxx \
  bash zabbix-agent-install.sh
```

> Das Repo ist privat. Für den `curl`-Download wird dann ein Token benötigt,
> alternativ das Script per `scp` auf den Host kopieren.

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
- Optional API-Registrierung: Frontend-URL, Token, Hostgruppe, Template, Proxy

**Führt aus (nach Bestätigung):**

1. Zabbix-Repository einrichten, Agent installieren
2. PSK nach `/etc/zabbix/zabbix_agent.psk` schreiben (`root:zabbix`, 640)
3. Agent-Konfiguration sichern und einen verwalteten Block schreiben
   (bei erneutem Lauf wird nur dieser Block ersetzt)
4. Konfiguration testen, Dienst starten, Erreichbarkeit von Port 10051 prüfen
5. Optional `ufw`-Freigabe für Port 10050 (nur Passiv)
6. Optional Host per API anlegen bzw. PSK/Proxy eines bestehenden Hosts aktualisieren

### Modi

| Modus | Agent-Konfig | Frontend (API) |
|---|---|---|
| Aktiv | `ServerActive`, `TLSConnect=psk`; kein Passiv-Listener (agent: `StartAgents=0`, agent2: nur `127.0.0.1`) | kein Agent-Interface, „Verbindungen vom Host“: PSK |
| Passiv | `Server`, `TLSAccept=psk` | Agent-Interface, „Verbindungen zum Host“: PSK |
| Aktiv + Passiv | beides | beides |

### API-Token

Token im Frontend unter *Benutzereinstellungen → API-Tokens* erzeugen.
Benötigte API-Methoden: `apiinfo.version`, `host.get`, `host.create`,
`host.update`, `hostgroup.get`, `hostgroup.create`, `template.get`,
`proxy.get`, `hostinterface.get`.

Empfohlen: eigener Service-Benutzer mit einer Rolle, deren API-Zugriff auf
diese Methoden beschränkt ist (Allow list).

### Log

Installationsausgaben landen in `/var/log/zabbix-agent-install.log` (Rechte 600).
