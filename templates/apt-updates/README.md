# Aktualisierbare Pakete per Zabbix-Agent zählen

Der Agent führt alle 6 Stunden `apt-get update` aus und zählt danach, wie viele installierte Pakete aktualisiert werden können (dieselbe Zahl wie `apt list --upgradable`). Es wird nichts installiert. Funktioniert mit Agent 1 und Agent 2 auf Debian/Ubuntu.

## Automatisch per Install-Script

[`zabbix-agent-install.sh`](../../zabbix-agent-install.sh) erledigt alle
folgenden Schritte selbst: Frage *„apt-Updates-Überwachung einrichten?“* mit
Ja beantworten. Mit API-Registrierung wird das passende Template außerdem
importiert (falls nötig) und am Host verknüpft. Die manuelle Anleitung unten
ist nur nötig, wenn du das Script nicht verwendest.

## 1. sudo-Regel anlegen

Der Agent läuft als Benutzer `zabbix`, `apt update` braucht aber root. Die Regel erlaubt nur genau diesen einen Befehl:

```sh
visudo -f /etc/sudoers.d/zabbix-apt
```

Inhalt:

```
zabbix ALL=(root) NOPASSWD: /usr/bin/apt-get update -qq
```

## 2. UserParameter installieren

```sh
# Agent 2:
install -m 0644 userparameter_apt_updates.conf /etc/zabbix/zabbix_agent2.d/
systemctl restart zabbix-agent2

# Agent 1:
install -m 0644 userparameter_apt_updates.conf /etc/zabbix/zabbix_agentd.d/
systemctl restart zabbix-agent
```

Test vom Zabbix-Server aus (kann wegen `apt update` einige Sekunden dauern):

```sh
zabbix_get -s <host> -k apt.updates.count -t 120
```

## 3. Template importieren

1. *Datenerfassung → Templates → Importieren*: die passende YAML-Datei (siehe Punkt 2)
2. Template den Linux-Hosts zuweisen:
   - **Linux updates by Zabbix agent** für passive Checks (Server fragt den Agent ab), Datei `template_apt_updates_passive.yaml`
   - **Linux updates by Zabbix agent active** für aktive Checks (Agent holt sich die Items selbst), Datei `template_apt_updates_active.yaml`. Voraussetzung: `ServerActive` und `Hostname` in der Agent-Konfiguration passen zum Host in Zabbix.

   Beide nutzen denselben UserParameter und dieselbe sudo-Regel. Pro Host nur eines der beiden zuweisen, sonst läuft `apt update` doppelt.

Ergebnis: Item **„apt: aktualisierbare Pakete“** und Trigger **„Paket-Updates verfügbar“** (Information). Die aktuelle Anzahl steht in der Spalte *Operational data* der Problemansicht. Sie wird bei jeder Anzeige neu berechnet, während ein Wert im Problemnamen beim Entstehen des Problems fest eingesetzt würde.

**Template aktualisieren:** Die YAML-Datei erneut importieren und bei *Templates*, *Items* und *Triggers* jeweils „Vorhandene aktualisieren“ anhaken. Die UUIDs sind gleich, Verknüpfungen und Daten bleiben erhalten.

| Makro | Standard | Bedeutung |
|---|---|---|
| `{$APT.UPDATES.INTERVAL}` | 6h | Wie oft `apt update` läuft und gezählt wird |
| `{$APT.UPDATES.MIN}` | 1 | Ab so vielen Paketen löst der Trigger aus |

Das Item hat ein eigenes Timeout von 3 Minuten, weil `apt update` länger als das Standard-Timeout des Agents dauern kann.

## 4. Sofortabfrage im Host-Menü (optional)

Mit dem Zabbix-Script **„apt-Updates prüfen“** lässt sich die Liste jederzeit
über das Host-Menü abrufen (Klick auf den Hostnamen → *Scripts*). Es zeigt
sofort die aktualisierbaren Pakete mit alter und neuer Version sowie den Stand
der Paketlisten. Pakete, die apt zurückhält (z. B. Ubuntu *phased updates*),
werden als Hinweis mitgezählt.

Sind die Paketlisten älter als 15 Minuten, stößt der Helfer `apt update` im
Hintergrund an; ein erneuter Aufruf nach etwa einer Minute zeigt den aktuellen
Stand. Synchron geht das nicht, weil der Agent Remote-Befehle nach seinem
`Timeout` abbricht (Agent 2: standardmäßig 3 s), `apt update` aber meist
länger dauert.

Das Install-Script richtet das automatisch ein. Von Hand:

```sh
# Helfer installieren
install -m 0755 zabbix-apt-check /usr/local/bin/

# nur genau diesen Befehl für Remote-Ausführung freigeben
echo 'AllowKey=system.run[/usr/local/bin/zabbix-apt-check,*]' \
  > /etc/zabbix/zabbix_agent2.d/apt-check.conf      # Agent 1: zabbix_agentd.d/
systemctl restart zabbix-agent2                     # Agent 1: zabbix-agent
```

Einmalig im Frontend unter *Alerts → Scripts → Create script*:

| Feld | Wert |
|---|---|
| Name | `apt-Updates prüfen` |
| Scope | Manual host action |
| Type | Script |
| Execute on | Zabbix agent |
| Commands | `/usr/local/bin/zabbix-apt-check` |
| Timeout | 60s |
| Host group | All (oder die Gruppe der Linux-Hosts) |

Hinweise:

- Bei reinen **Aktiv**-Agents holt sich der Agent den Befehl bei seiner
  nächsten Verbindung zum Server ab. Das wird ab Agent 7.0 unterstützt, die
  Antwort kann einige Sekunden dauern.
- Die Sofortabfrage zeigt nur die Liste an und ändert das Item nicht. Das Item
  aktualisiert sich im nächsten Intervall (`{$APT.UPDATES.INTERVAL}`).
- Steht in der Agent-Konfiguration ein aktives `DenyKey=system.run[*]` vor dem
  `AllowKey`, greift die Freigabe nicht. Die erste passende Regel gewinnt.
