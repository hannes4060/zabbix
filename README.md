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

### Sicherheit

- Das Repository enthält keine Zugangsdaten. PSK und API-Token werden erst
  beim Ausführen eingegeben bzw. erzeugt und nur auf dem Zielhost gespeichert.
- Bitte niemals echte Tokens, PSKs oder interne Adressen in Issues oder
  Pull Requests posten.

### Haftungsausschluss

Das Script installiert Pakete und ändert Systemkonfigurationen mit
root-Rechten. Nutzung auf eigene Verantwortung – vor dem produktiven Einsatz
bitte auf einem Testsystem ausprobieren.

## Lizenz

[MIT](LICENSE) © hannes4060

Fehler und Verbesserungsvorschläge gerne als
[Issue](https://github.com/hannes4060/zabbix/issues) oder Pull Request.
