# 🔒 Corporate Security Hardening — WSL2 & Podman auf Windows 11

Dieses Dokument beschreibt alle Sicherheitsmaßnahmen, die in einem regulierten Unternehmensumfeld für die WSL2/Podman-Deployment-Lösung notwendig sind. Es umfasst:

- Analyse des Bedrohungsmodells
- Lokale Gruppe `podman-users` und deren Rechte
- Alle relevanten Group Policy (GPO) Einstellungen mit exakten `gpedit.msc`-Pfaden zum manuellen Testen
- NTFS-Berechtigungen auf dem geschützten Skriptverzeichnis
- WSL-interne Härtungsmaßnahmen
- Verifizierungsbefehle für jeden Schritt

> **Hinweis zur Testumgebung:** Alle GPO-Einstellungen werden manuell über `gpedit.msc` (Lokaler Gruppenrichtlinien-Editor) gesetzt. Im Produktionsbetrieb werden diese Einstellungen über Active Directory GPOs oder Microsoft Intune (Settings Catalog) ausgerollt.

---

## 1. 📊 Bedrohungsanalyse

### Was muss geschützt werden?

| Bedrohung | Risiko | Priorität |
|---|---|---|
| Entwickler installiert beliebige Linux-Distros (`wsl --install`, `wsl --import`) | Umgehung Zero-Trust-Registry, ungeprüfte Toolchains | 🔴 Kritisch |
| Distro-Download über Microsoft Store | Gleich wie oben | 🔴 Kritisch |
| Manipulation der Corporate-Skripte in `SecureStorage` | Policy-Bypass, Registry-Manipulation | 🔴 Kritisch |
| WSL-Prozess läuft als `root`-User | Privilege Escalation innerhalb des Containers | 🟠 Hoch |
| Kein Audit-Log für WSL/Podman-Aktivitäten | Kein Nachweis bei Security-Incidents | 🟠 Hoch |
| Wildcard PowerShell-Ausführung | Ausführung nicht autorisierter Skripte | 🟠 Hoch |
| WSL-Netzwerkinterface umgeht Windows Firewall | Lateralbewegung, Datexfiltration | 🟡 Mittel |
| Windows-PATH und Windows-Dateien in WSL sichtbar | Informationsoffenlegung | 🟡 Mittel |

### Was darf NICHT eingeschränkt werden?

| Funktion | Begründung |
|---|---|
| `podman machine stop` / `podman machine start` | Entwickler müssen Podman eigenständig neu starten können — kein Admin nötig |
| `wsl --terminate podman-machine-default` | Hängenden WSL-Prozess beenden — kein Admin nötig |
| `podman pull`, `podman run`, etc. | Kernfunktionalität — nur von genehmigter Registry |
| Lesen der Skripte in `SecureStorage` | Debugging durch Entwickler erlaubt (Read-only) |

---

## 2. 👥 Lokale Gruppe `podman-users`

### Zweck

Die Gruppe `podman-users` ist der einzige autorisierte Personenkreis für die Nutzung von Podman auf einem Gerät. Durch die Kopplung des Scheduled Tasks `Podman-User-Init` an diese Gruppe wird die Podman-Maschine **nur für Mitglieder initialisiert**.

### Erstellung (PowerShell als Admin)

```powershell
# Gruppe anlegen
New-LocalGroup -Name "podman-users" -Description "Autorisierte Podman-Entwickler (IT-verwaltet)" -ErrorAction SilentlyContinue

# Prüfen
Get-LocalGroup -Name "podman-users"
```

### Mitglieder hinzufügen (IT-Administrator)

```powershell
# Einzelnen Benutzer hinzufügen
Add-LocalGroupMember -Group "podman-users" -Member "DOMAIN\max.mustermann"

# Lokalen Benutzer hinzufügen (Test-VM)
Add-LocalGroupMember -Group "podman-users" -Member "developer"

# Alle aktuellen Mitglieder anzeigen
Get-LocalGroupMember -Group "podman-users"
```

### Über GUI (lusrmgr.msc)

```
Win+R → lusrmgr.msc
→ Gruppen → podman-users → Doppelklick → Hinzufügen
```

### Was die Gruppe kontrolliert

| Kontrolle | Mechanismus |
|---|---|
| Podman-Maschinen-Initialisierung | `Podman-User-Init`-Task läuft nur für `podman-users`-Mitglieder |
| Lese-Zugriff auf SecureStorage-Skripte | NTFS ACL: `podman-users` = Read & Execute |
| Kein Schreib-Zugriff auf Corporate-Konfiguration | NTFS ACL: Kein Write für `podman-users` |

---

## 3. 🛡️ GPO-Einstellungen (gpedit.msc)

> `gpedit.msc` öffnen: `Win+R → gpedit.msc → Enter`

---

### 3.1 WSL2 — Distro-Installation sperren

> **Voraussetzung:** Windows 11 Version 22H2 oder neuer. Die WSL-ADMX-Vorlagen werden automatisch mit der WSL-Installation bereitgestellt.

#### WSL2 aktiviert lassen

```
Computer Configuration
  └── Administrative Templates
      └── Windows Components
          └── Windows Subsystem for Linux
              └── Allow the Windows Subsystem for Linux
                  → Status: ENABLED
```

#### Benutzer-Distro-Installation sperren

```
Computer Configuration
  └── Administrative Templates
      └── Windows Components
          └── Windows Subsystem for Linux
              └── Allow user distribution installation
                  → Status: DISABLED
```

> **Wirkung:** Blockiert `wsl --install <distro>`, `wsl --import`, `wsl --register` für Standardbenutzer. Die bereits installierte `podman-machine-default`-Distro ist davon nicht betroffen.

#### Registry-Äquivalent (zur Verifikation oder als Fallback)

```powershell
# Setzen (als Admin):
$Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Lxss"
if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
Set-ItemProperty -Path $Path -Name "AllowUserDistributionInstallation" -Value 0 -Type DWord
Set-ItemProperty -Path $Path -Name "DefaultVersion" -Value 2 -Type DWord

# Prüfen:
Get-ItemProperty -Path $Path
```

---

### 3.2 Microsoft Store sperren

```
Computer Configuration
  └── Administrative Templates
      └── Windows Components
          └── Store
              └── Turn off the Store application
                  → Status: ENABLED
```

> **Wirkung:** Verhindert den Download von Linux-Distros und Podman Desktop-Updates über den Store.

---

### 3.3 PowerShell Execution Policy

```
Computer Configuration
  └── Administrative Templates
      └── Windows Components
          └── Windows PowerShell
              └── Turn on Script Execution
                  → Status: ENABLED
                  → Execution Policy: Allow local scripts and remote signed scripts
                                      (RemoteSigned)
```

> **Wirkung:** Lokale Skripte (wie unsere in `C:\ProgramData\`) können ausgeführt werden. Heruntergeladene Skripte benötigen eine Signatur. Verhindert das uneingeschränkte Ausführen von Skripten aus dem Internet.

---

### 3.4 Prozess-Auditing (Logging aller WSL/Podman-Aufrufe)

#### Schritt 1: Advanced Audit Policy

```
Computer Configuration
  └── Windows Settings
      └── Security Settings
          └── Advanced Audit Policy Configuration
              └── System Audit Policies - Local Group Policy Object
                  └── Detailed Tracking
                      └── Audit Process Creation
                          → Check: SUCCESS
                          → Check: FAILURE
```

#### Schritt 2: Kommandozeile in Ereignislog aufzeichnen

```
Computer Configuration
  └── Administrative Templates
      └── System
          └── Audit Process Creation
              └── Include command line in process creation events
                  → Status: ENABLED
```

> **Wirkung:** Jeder Aufruf von `wsl.exe`, `podman.exe`, `powershell.exe` wird mit vollständiger Kommandozeile im Windows-Ereignisprotokoll (Event Log → Security, Event ID 4688) aufgezeichnet.

#### Verifizierung nach Aktivierung

```powershell
# Letzte 10 wsl.exe-Aufrufe aus dem Security-Log anzeigen:
Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4688]]" -MaxEvents 100 |
  Where-Object { $_.Message -match "wsl.exe|podman.exe" } |
  Select-Object TimeCreated, Message |
  Format-List
```

---

### 3.5 Windows Defender Firewall

Die Firewall-Härtung für WSL2 ist bereits durch `firewall=true` in der `.wslconfig` aktiv (gesetzt durch `SelfHeal-Podman.ps1`). Zusätzliche GPO-Bestätigung:

```
Computer Configuration
  └── Windows Settings
      └── Security Settings
          └── Windows Defender Firewall with Advanced Security
              └── Windows Defender Firewall Properties
                  → Domain Profile:  Firewall state: ON, Inbound: Block, Outbound: Allow
                  → Private Profile: Firewall state: ON, Inbound: Block, Outbound: Allow
                  → Public Profile:  Firewall state: ON, Inbound: Block, Outbound: Allow
```

> **Wirkung in Kombination mit `firewall=true` in `.wslconfig`:** WSL2-Netzwerkverkehr unterliegt den Windows-Firewall-Regeln. Eingehende Verbindungen von außen in den WSL-Container sind standardmäßig blockiert.

---

## 4. 🗂️ NTFS-Berechtigungen auf SecureStorage

Das Verzeichnis `C:\ProgramData\CorporateIT\Podman` enthält die Corporate-Skripte und die Root-CA. Die Berechtigungen werden von `Install-Master.ps1` automatisch gesetzt.

### Ziel-Berechtigungsstruktur

| Identität | Rechte | Begründung |
|---|---|---|
| `SYSTEM` | Full Control | Task-Ausführung durch Scheduled Tasks |
| `BUILTIN\Administrators` | Full Control | IT-Administration |
| `podman-users` | Read & Execute | Entwickler können Skripte lesen/debuggen, nicht ändern |
| `BUILTIN\Users` | Kein Zugriff | Explizit entfernt — Standard-Users ohne podman-users haben keinen Zugriff |

### Manuell setzen (PowerShell als Admin)

```powershell
$SecureDir = "C:\ProgramData\CorporateIT\Podman"

# icacls: Vererbung entfernen und Berechtigungen explizit neu setzen
& icacls $SecureDir /inheritance:r
& icacls $SecureDir /grant "SYSTEM:(OI)(CI)F"
& icacls $SecureDir /grant "BUILTIN\Administrators:(OI)(CI)F"
& icacls $SecureDir /grant "podman-users:(OI)(CI)RX"
& icacls $SecureDir /remove "BUILTIN\Users"
& icacls $SecureDir /remove "Everyone"

# Aktuellen Stand prüfen
& icacls $SecureDir
```

### Verifizierung

```powershell
# Als Mitglied von podman-users: Lesen sollte funktionieren
Get-Content "C:\ProgramData\CorporateIT\Podman\podman-config.json"

# Als Mitglied von podman-users: Schreiben sollte FEHLSCHLAGEN
"test" | Set-Content "C:\ProgramData\CorporateIT\Podman\test.txt"
# Erwartete Ausgabe: "Access to the path ... is denied"
```

---

## 5. 🐧 WSL-interne Härtung (`/etc/wsl.conf`)

Die Podman-Maschine (`podman-machine-default`) wird durch `Init-PodmanUser.ps1` mit einer gehärteten `/etc/wsl.conf` initialisiert.

### Konfiguration

```ini
[user]
# Standard-User ist nicht root — verhindert Privilege Escalation im Container
default=user

[automount]
# Windows-Laufwerke bleiben eingehängt (für wslpath-Operationen benötigt)
enabled=true
# Sichere Berechtigungen: Dateien erhalten 644, Verzeichnisse 755
options=metadata,umask=022,fmask=011

[interop]
# WSL darf keine Windows-Prozesse starten (Isolation)
enabled=false
# Windows PATH wird NICHT in WSL-PATH exportiert (Isolation)
appendWindowsPath=false
```

> **Hinweis:** `interop.enabled=false` verhindert, dass Prozesse innerhalb des Containers Windows-Executables aufrufen können. Podman Desktop kommuniziert über Named Pipes, nicht über Interop — diese Einstellung ist sicher.

### Verifizierung inside WSL

```bash
# WSL-Konsole öffnen:
wsl -d podman-machine-default

# Aktuellen User prüfen (sollte NICHT root sein):
whoami        # Erwartete Ausgabe: user

# Interop-Status prüfen:
cat /proc/sys/fs/binfmt_misc/WSLInterop 2>/dev/null || echo "Interop deaktiviert"

# wsl.conf anzeigen:
cat /etc/wsl.conf
```

---

## 6. 🔄 WSL-Neustart für Standard-User

Standard-Benutzer (Mitglieder von `podman-users`) können Podman **ohne Admin-Rechte** neu starten:

### Option 1: Podman-Maschine neu starten (bevorzugt)

```powershell
# Podman Machine stoppen und starten (kein Admin nötig)
podman machine stop
podman machine start
```

### Option 2: WSL-Distro direkt terminieren

```powershell
# Nur die Podman-Distro beenden (kein Admin nötig in Windows 11)
wsl --terminate podman-machine-default

# Danach Podman Machine neu starten
podman machine start
```

### Option 3: Manuell den SelfHeal-Task triggern (Admin nötig)

```powershell
# Nur für IT-Admins: gesamten SelfHeal-Mechanismus auslösen
Start-ScheduledTask -TaskName "Podman-SelfHeal"
```

> **Warum kein Admin?** `podman machine stop/start` laufen vollständig im User-Kontext und modifizieren nur benutzerspezifische Prozesse. `wsl --terminate` beendet nur Distros, die dem aufrufenden Benutzer gehören.

---

## 7. 📋 Berechtigungsmatrix

| Aktion | `developer`\* | `ITAdmin` | `SYSTEM` |
|---|---|---|---|
| Podman Machine starten/stoppen | ✅ | ✅ | ✅ |
| `podman pull` (von genehmigter Registry) | ✅ | ✅ | — |
| `podman pull` (von docker.io/extern) | ❌ Zero-Trust | ❌ Zero-Trust | — |
| Neue WSL-Distro installieren | ❌ GPO | ✅ | ✅ |
| Skripte in SecureStorage lesen | ✅ | ✅ | ✅ |
| Skripte in SecureStorage schreiben | ❌ NTFS | ✅ | ✅ |
| `.wslconfig` ändern | ✅ (eigene) | ✅ | ✅ |
| `.wslconfig` bleibt bei Reboot | ❌ wird zurückgesetzt | — | ✅ SelfHeal |
| Podman-Einstellungen (settings.json) | ✅ (eigene) | ✅ | — |
| Microsoft Store nutzen | ❌ GPO | ✅ | — |
| WSL als root starten | ❌ wsl.conf | ✅ | — |
| `wsl --shutdown` (alle Distros) | ✅ (eigene) | ✅ | ✅ |

> \* `developer` = Mitglied der Gruppe `podman-users`, kein lokaler Admin

---

## 8. ✅ Vollständige Verifikations-Checkliste

Folgende Befehle in der Test-VM ausführen (als `developer`-Standard-User):

```powershell
# --- GPO-Tests ---

# Test 1: Neue Distro installieren → muss FEHLSCHLAGEN
wsl --install Ubuntu
# Erwartete Ausgabe: "Fehler: ... Die Installation ist durch eine Richtlinie deaktiviert"

# Test 2: Distro importieren → muss FEHLSCHLAGEN
wsl --import TestDistro C:\Users\developer\TestDistro C:\some.tar
# Erwartete Ausgabe: Fehler / Zugriff verweigert

# Test 3: Store öffnen → muss gesperrt sein
Start-Process "ms-windows-store:"
# Erwartete Wirkung: Store öffnet nicht oder zeigt Sperrmeldung

# --- Berechtigungs-Tests ---

# Test 4: SecureStorage lesen → muss funktionieren
Get-Content "C:\ProgramData\CorporateIT\Podman\podman-config.json"

# Test 5: SecureStorage schreiben → muss FEHLSCHLAGEN
"X" | Set-Content "C:\ProgramData\CorporateIT\Podman\test.txt" -ErrorAction SilentlyContinue
if (Test-Path "C:\ProgramData\CorporateIT\Podman\test.txt") { "FAIL: Schreiben war möglich!" } else { "OK: Schreiben korrekt verweigert" }

# --- WSL-Tests ---

# Test 6: WSL als root starten → muss nicht-root User ergeben
wsl -d podman-machine-default whoami
# Erwartete Ausgabe: "user" (nicht "root")

# Test 7: Podman Machine neu starten → muss ohne Admin funktionieren
podman machine stop
Start-Sleep -Seconds 5
podman machine start
podman machine ls
# Erwartete Ausgabe: Machine im Status "Running"

# Test 8: Zero-Trust Registry prüfen → docker.io muss geblockt sein
podman pull docker.io/library/hello-world
# Erwartete Ausgabe: "Error: ... Source image rejected"

# --- Audit-Log prüfen (als Admin) ---
# Test 9: WSL-Aufruf im Security-Log vorhanden
Get-WinEvent -LogName Security -MaxEvents 50 |
  Where-Object { $_.Id -eq 4688 -and $_.Message -match "wsl.exe" } |
  Select-Object -First 3 TimeCreated, Message
```

---

## 9. 🏢 Intune / Active Directory GPO Deployment

Im Produktionsbetrieb werden die `gpedit.msc`-Einstellungen über folgende Mechanismen ausgerollt:

### Active Directory GPO

Die ADMX-Vorlagen für WSL2 befinden sich nach der WSL-Installation unter:
```
%WINDIR%\PolicyDefinitions\WindowsSubsystemForLinux.admx
%WINDIR%\PolicyDefinitions\<Sprachordner>\WindowsSubsystemForLinux.adml
```
Diese müssen auf den AD-zentralen ADMX-Store kopiert werden (`\\domain\SYSVOL\domain\Policies\PolicyDefinitions\`).

### Microsoft Intune (Settings Catalog)

| Intune-Einstellung | Wert |
|---|---|
| `Windows Subsystem For Linux > Allow The Windows Subsystem For Linux` | Enabled |
| `Windows Subsystem For Linux > Allow User Distribution Installation` | Disabled |
| `Microsoft Store > Turn Off Store Application` | Enabled |
| `Windows PowerShell > Turn On Script Execution` | Enabled — RemoteSigned |
| `Audit > Audit Process Creation` | Success + Failure |
| `Audit > Include Command Line In Process Creation Events` | Enabled |

---

## 10. 🔗 Integration mit `Install-Master.ps1`

`Install-Master.ps1` übernimmt folgende Schritte automatisch:
1. Erstellt die lokale Gruppe `podman-users` (falls nicht vorhanden)
2. Ändert den `Podman-User-Init`-Task auf die Gruppe `podman-users` (statt `BUILTIN\Users`)
3. Setzt die NTFS-ACLs auf `SecureStorage`

`Init-PodmanUser.ps1` konfiguriert beim ersten Start automatisch:
1. `/etc/wsl.conf` mit den Härtungseinstellungen (non-root user, Interop-Sperre, sichere Automount-Optionen)

> Die GPO-Einstellungen aus Abschnitt 3 müssen **separat** über `gpedit.msc`, Active Directory oder Intune ausgerollt werden. Sie sind nicht Teil des Installer-Skripts.