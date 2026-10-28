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
