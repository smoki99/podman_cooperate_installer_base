# 🧪 KVM Windows 11 Testlab — Schritt-für-Schritt-Anleitung

Dieses Dokument beschreibt, wie man auf einem **Linux Mint Host** eine Windows 11 KVM-Maschine für das Testen des Podman-Deployment-Skripts aufsetzt — vollständig per Kommandozeile.

---

## 📋 Voraussetzungen

### Dateien in `/iso` bereitstellen

```
/iso/
 ┣ Win11_<Version>_German_x64.iso    ← Windows 11 ISO (dein eigenes)
 ┗ virtio-win.iso                    ← Treiber-ISO (Schritt unten)
```

**virtio-win.iso herunterladen** (KVM-Paravirtualisierungstreiber für Windows):
```bash
wget -O /iso/virtio-win.iso \
  https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso
```

---

## 1. KVM-Pakete installieren (Linux Mint Host)

```bash
sudo apt update && sudo apt install -y \
  qemu-kvm \
  libvirt-daemon-system \
  libvirt-clients \
  virtinst \
  ovmf \
  swtpm \
  swtpm-tools \
  libguestfs-tools \
  virt-manager

# Aktuellen Benutzer zur libvirt-Gruppe hinzufügen (Terminal-Neustart danach nötig)
sudo usermod -aG libvirt,kvm "$USER"
newgrp libvirt
```

### Nested Virtualization prüfen und aktivieren

**Zwingend erforderlich** — WSL2 läuft nur, wenn die CPU des Hosts ihre Virtualisierungsfähigkeiten an die VM weitergibt.

```bash
# Intel-CPU: Prüfen
cat /sys/module/kvm_intel/parameters/nested
# AMD-CPU: Prüfen
cat /sys/module/kvm_amd/parameters/nested

# Erwartete Ausgabe: Y oder 1
# Falls nicht:

# Intel aktivieren:
echo "options kvm-intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel

# AMD aktivieren:
echo "options kvm-amd nested=1" | sudo tee /etc/modprobe.d/kvm-amd.conf
sudo modprobe -r kvm_amd && sudo modprobe kvm_amd
```

### libvirtd starten

```bash
sudo systemctl enable --now libvirtd
sudo systemctl status libvirtd   # Sollte "active (running)" zeigen
```

---

## 2. VM erstellen

### Festplatten-Image anlegen

```bash
# Zielverzeichnis anlegen falls nötig
sudo mkdir -p /mnt/data2/virtimages

# 80 GB qcow2-Image erstellen
sudo qemu-img create -f qcow2 /mnt/data2/virtimages/win11-podman-test.qcow2 80G
```

### VM per XML definieren (empfohlene Methode)

`virt-install` hat auf diesem System Einschränkungen beim Parsen von `--clock`- und `--boot`-Optionen. Die zuverlässigste Methode ist `virsh define` mit einer vorbereiteten XML-Datei, abgeleitet von einer bereits funktionierenden VM-Konfiguration.

```bash
# XML-Datei in /tmp ablegen (exakt wie die funktionierende Referenz-VM)
cat > /tmp/win11-podman-test.xml << 'EOF'
<domain type="kvm">
  <name>win11-podman-test</name>
  <metadata>
    <libosinfo:libosinfo xmlns:libosinfo="http://libosinfo.org/xmlns/libvirt/domain/1.0">
      <libosinfo:os id="http://microsoft.com/win/11"/>
    </libosinfo:libosinfo>
  </metadata>
  <memory unit="KiB">8388608</memory>
  <currentMemory unit="KiB">8388608</currentMemory>
  <memoryBacking>
    <source type="memfd"/>
    <access mode="shared"/>
  </memoryBacking>
  <vcpu placement="static">4</vcpu>
  <resource>
    <partition>/machine</partition>
  </resource>
  <os firmware="efi">
    <type arch="x86_64" machine="pc-q35-8.2">hvm</type>
    <firmware>
      <feature enabled="yes" name="enrolled-keys"/>
      <feature enabled="yes" name="secure-boot"/>
    </firmware>
    <loader readonly="yes" secure="yes" type="pflash">/usr/share/OVMF/OVMF_CODE_4M.ms.fd</loader>
    <nvram template="/usr/share/OVMF/OVMF_VARS_4M.ms.fd">/var/lib/libvirt/qemu/nvram/win11-podman-test_VARS.fd</nvram>
  </os>
  <features>
    <acpi/>
    <apic/>
    <hyperv mode="custom">
      <relaxed state="on"/>
      <vapic state="on"/>
      <spinlocks state="on" retries="8191"/>
      <vpindex state="on"/>
      <synic state="on"/>
      <stimer state="on"/>
      <reset state="on"/>
      <vendor_id state="on" value="KVM Hv"/>
      <frequencies state="on"/>
      <reenlightenment state="on"/>
      <tlbflush state="on"/>
      <ipi state="on"/>
    </hyperv>
    <kvm><hidden state="on"/></kvm>
    <vmport state="off"/>
    <smm state="on"/>
  </features>
  <cpu mode="host-passthrough" check="none" migratable="on">
    <topology sockets="1" dies="1" cores="4" threads="1"/>
    <!-- AMD Ryzen: svm. Bei Intel-CPU diese Zeile durch <feature policy="require" name="vmx"/> ersetzen -->
    <feature policy="require" name="svm"/>
  </cpu>
  <clock offset="localtime">
    <timer name="rtc" tickpolicy="catchup"/>
    <timer name="pit" tickpolicy="delay"/>
    <timer name="hpet" present="no"/>
    <timer name="hypervclock" present="yes"/>
  </clock>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <pm>
    <suspend-to-mem enabled="no"/>
    <suspend-to-disk enabled="no"/>
  </pm>
  <devices>
    <emulator>/usr/bin/qemu-system-x86_64</emulator>
    <!-- Hauptfestplatte: sata-Bus — Windows erkennt sie ohne zusätzlichen Treiber -->
    <disk type="file" device="disk">
      <driver name="qemu" type="qcow2"/>
      <source file="/mnt/data2/virtimages/win11-podman-test.qcow2"/>
      <target dev="sda" bus="sata"/>
      <boot order="2"/>
      <address type="drive" controller="0" bus="0" target="0" unit="0"/>
    </disk>
    <!-- Windows 11 Installations-ISO -->
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="/mnt/data1/iso/Win11_25H2_EnglishInternational_x64.iso"/>
      <target dev="sdb" bus="sata"/>
      <boot order="1"/>
      <readonly/>
      <address type="drive" controller="0" bus="0" target="0" unit="1"/>
    </disk>
    <!-- VirtIO-Treiber-ISO (für Netzwerk nach der Installation) -->
    <disk type="file" device="cdrom">
      <driver name="qemu" type="raw"/>
      <source file="/mnt/data1/iso/virtio-win-0.1.285.iso"/>
      <target dev="sdc" bus="sata"/>
      <readonly/>
      <address type="drive" controller="0" bus="0" target="0" unit="2"/>
    </disk>
    <controller type="usb" index="0" model="qemu-xhci" ports="15">
      <address type="pci" domain="0x0000" bus="0x02" slot="0x00" function="0x0"/>
    </controller>
    <controller type="pci" index="0" model="pcie-root"/>
    <controller type="pci" index="1" model="pcie-root-port">
      <model name="pcie-root-port"/>
      <target chassis="1" port="0x10"/>
      <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x0" multifunction="on"/>
    </controller>
    <controller type="pci" index="2" model="pcie-root-port">
      <model name="pcie-root-port"/>
      <target chassis="2" port="0x11"/>
      <address type="pci" domain="0x0000" bus="0x00" slot="0x02" function="0x1"/>
    </controller>
    <controller type="virtio-serial" index="0">
      <address type="pci" domain="0x0000" bus="0x03" slot="0x00" function="0x0"/>
    </controller>
    <controller type="sata" index="0">
      <address type="pci" domain="0x0000" bus="0x00" slot="0x1f" function="0x2"/>
    </controller>
    <!-- Bridge-Netzwerk: direkte Verbindung ins LAN (kein NAT) -->
    <interface type="bridge">
      <source bridge="br0"/>
      <model type="virtio"/>
      <address type="pci" domain="0x0000" bus="0x01" slot="0x00" function="0x0"/>
    </interface>
    <serial type="pty">
      <target type="isa-serial" port="0">
        <model name="isa-serial"/>
      </target>
    </serial>
    <console type="pty">
      <target type="serial" port="0"/>
    </console>
    <channel type="spicevmc">
      <target type="virtio" name="com.redhat.spice.0"/>
      <address type="virtio-serial" controller="0" bus="0" port="1"/>
    </channel>
    <input type="mouse" bus="ps2"/>
    <input type="keyboard" bus="ps2"/>
    
    <tpm model="tpm-crb"><backend type="emulator" version="2.0"/></tpm>
    <graphics type="spice">
      <listen type="none"/>
      <image compression="off"/>
    </graphics>
    <sound model="ich9">
      <address type="pci" domain="0x0000" bus="0x00" slot="0x1b" function="0x0"/>
    </sound>
    <audio id="1" type="spice"/>
    <video>
      <model type="virtio" heads="1" primary="yes"/>
      <address type="pci" domain="0x0000" bus="0x00" slot="0x01" function="0x0"/>
    </video>
    <memballoon model="virtio">
      <address type="pci" domain="0x0000" bus="0x04" slot="0x00" function="0x0"/>
    </memballoon>
  </devices>
</domain>
EOF

# VM aus XML definieren
sudo virsh define /tmp/win11-podman-test.xml

# Prüfen ob die VM definiert wurde
sudo virsh list --all | grep win11-podman-test

# VM starten
sudo virsh start win11-podman-test

# Konsole sofort öffnen (in einem zweiten Terminal)
virt-viewer --connect qemu:///system win11-podman-test &
```

> **Wichtig bei Intel-CPU:** Die Zeile `<feature policy="require" name="svm"/>` in der XML ist AMD-spezifisch (AMD-V). Bei einer Intel-CPU entweder durch `<feature policy="require" name="vmx"/>` ersetzen oder die Zeile ganz entfernen — `host-passthrough` allein reicht für Nested Virtualization.

---

## 3. Windows 11 Installation

Öffne den Installer-Desktop:
```bash
virt-viewer --connect qemu:///system win11-podman-test &
```

### Wichtige Schritte im Installer

1. **Sprache/Tastatur** → Weiter
2. **Jetzt installieren** → Keine Product-Key eingeben → **Windows 11 Pro** wählen
3. **Benutzerdefiniert: Nur Windows installieren**
4. **Festplatte nicht sichtbar?** → "Treiber laden" klicken:
   - `E:\` (virtio-win CD) → `viostor\w11\amd64` → Öffnen → Weiter
   - Jetzt erscheint die virtio-Festplatte → auswählen → Weiter
5. Installation abwarten (~15 Min.)
6. **Benutzer anlegen:**
   - Computername: `WIN11-PODMAN`
   - Kein Microsoft-Konto nötig: "Anmeldeoptionen" → "Offline-Konto" → "Begrenzte Erfahrung"
   - Admin-Benutzer: `ITAdmin` / Passwort deiner Wahl
   - Alle Telemetrie-Fragen: **Nein / Ablehnen**

### Nach der Installation: Virtio-Netzwerktreiber installieren

Das Netzwerk funktioniert noch nicht (kein Treiber). Im Windows-Gerätmanager:
1. Start → Geräte-Manager
2. "Ethernet-Controller" mit Ausrufezeichen → Rechtsklick → Treiber aktualisieren
3. "Auf meinem Computer suchen" → `E:\NetKVM\w11\amd64` → Weiter

Oder per PowerShell im Windows-Terminal (als Admin):
```powershell
# Treiber von virtio-win ISO installieren (Laufwerk E:\ oder F:\)
pnputil /add-driver E:\NetKVM\w11\amd64\netkvm.inf /install
pnputil /add-driver E:\Balloon\w11\amd64\balloon.inf /install
pnputil /add-driver E:\vioserial\w11\amd64\vioser.inf /install
```

### OpenSSH-Server aktivieren (für Dateitransfer vom Host)

```powershell
# In Windows PowerShell als Admin ausführen:
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd
```

---

## 3a. Upgrade zu Windows 11 Pro (für gpedit.msc)

**gpedit.msc ist nur in Windows 11 Pro/Enterprise verfügbar.** Wenn du Home installiert hast, kannst du upgraden:

### Option A: Während der Installation (empfohlen)
Beim Installer auf "Windows 11 Pro" statt "Home" wählen.

### Option B: Upgrade nachträglich via changepk.exe (empfohlen)
```powershell
# Aktuelle Edition prüfen
slmgr /dli

# Upgrade zu Professional mit generischem Key
changepk.exe /ProductKey xxxxxxxxx

# Nach Aufforderung neu starten
shutdown /r /t 0
```

**Hinweis:** Der oben genannte Key ist ein generischer Upgrade-Key. Für eine dauerhafte Aktivierung benötigst du einen gekauften Pro-Lizenzschlüssel.

---

## 3b. Test-Benutzerkonten einrichten (Admin vs. Standard-User)

Für das Testen des Deployment-Skripts benötigst du zwei Konten:
- **ITAdmin** — Volladministrator (bereits erstellt bei Installation)
- **developer** — Standardbenutzer mit eingeschränkten Rechten

### Standard-Benutzer "developer" erstellen

```powershell
# PowerShell als ITAdmin öffnen und ausführen:
$SecurePassword = ConvertTo-SecureString "DevPass123!" -AsPlainText -Force
New-LocalUser -Name "developer" -Password $SecurePassword -FullName "Developer Test User" -Description "Standardbenutzer für Podman-Tests"
Add-LocalGroupMember -Group "Users" -Member "developer"

# Bestätigen:
Get-LocalUser developer | Select-Object Name, Enabled, PasswordNeverExpires
```

### Optional: GPO-Restriktionen für Standard-Benutzer anwenden (via PowerShell)

```powershell
# Als ITAdmin ausführen — setzt Registry-Keys für den Benutzer "developer"

# 1. Software-Installation verhindern
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows" -Name "NoRun" -Value 1 -Type DWORD -Force

# Windows Installer deaktivieren
New-Item -Path "HKCU:\Software\Policies\Microsoft\WindowsInstaller" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\WindowsInstaller" -Name "DisableUserControlledInstallations" -Value 1 -Type DWORD -Force

# 2. Registry-Zugriff einschränken (regedit, reg.exe blockieren)
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\System" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\System" -Name "DisableRegistryTools" -Value 1 -Type DWORD -Force

# 3. WSL-Installationen verhindern (optional)
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsSubsystemForLinux" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\WindowsSubsystemForLinux" -Name "AllowWSLInstallations" -Value 0 -Type DWORD -Force

# 4. Control Panel Programme und Funktionen deaktivieren
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Control Panel" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Control Panel" -Name "ProhibitedPages" -Value "Programs;System;DateAndTime;Desktop;Display;Mouse;Keyboard;RegionalOptions;Accessibility;Sounds;Themes;Personalization;Default Programs;SyncCenter;Parental Controls;All Items" -Type String -Force
```

**Hinweis:** Diese Registry-Keys gelten für den aktuellen Benutzer. Um sie auf "developer" anzuwenden, musst du als developer eingeloggt sein oder `Load-Hive` verwenden.

### Schnell zwischen Konten wechseln zum Testen

```powershell
# Von der Anmeldeoberfläche:
# Ctrl+Alt+Entf → Benutzer wechseln → developer auswählen

# Oder per Befehl (als ITAdmin):
taskkill /F /IM explorer.exe  # Explorer beenden, um abzumelden
```

### Berechtigungs-Checkliste: Was kann jeder Account?

| Aktion | ITAdmin | developer |
|--------|---------|-----------|
| Install-Master.ps1 ausführen | ✓ | ✗ (benötigt Admin) |
| WSL2 installieren/aktivieren | ✓ | ✗ |
| Podman Machine erstellen | ✓ | ✗ |
| Scheduled Tasks erstellen | ✓ | ✗ |
| GPO ändern | ✓ | ✗ |
| Init-PodmanUser.ps1 ausführen (als Task) | N/A | ✓ (wenn als Task geplant) |
| podman machine ls | ✓ | ✓ (nach Setup) |
| podman run | ✓ | ✓ (nach Setup) |

### Berechtigungen prüfen (PowerShell)

```powershell
# Prüfen ob aktueller Benutzer Admin ist:
whoami /groups | findstr "S-1-5-32-544"
# Ausgabe: S-1-5-32-544 0x20000 BUILTIN\Administrators → JA, Admin

# Alle Gruppen des aktuellen Benutzers anzeigen:
whoami /groups
```

---

## 4. Snapshots: Workflow

> **WICHTIG:** Diese VM verwendet OVMF UEFI (pflash) Firmware, was interne libvirt-Snapshots nicht unterstützt.
> Die folgenden Befehle verwenden externe qcow2-Backups als Alternative.

### IP-Adresse der VM ermitteln

```bash
# Methode 1: via virsh
sudo virsh domifaddr win11-podman-test

# Methode 2: via arp (nach erster Verbindung)
arp -n | grep virbr
```

### Snapshot-Befehle (externe qcow2-Backups)

```bash
DISK="/mnt/data2/virtimages/win11-podman-test.qcow2"
BACKUP_DIR="/mnt/data2/virtimages/backups"
mkdir -p "$BACKUP_DIR"

# Snapshot erstellen (VM stoppen für konsistente Backups)
sudo virsh shutdown win11-podman-test
sleep 30  # Warten bis VM gestoppt ist
sudo cp "$DISK" "$BACKUP_DIR/00-fresh-win11.qcow2"
echo "Snapshot '00-fresh-win11' erstellt"
sudo virsh start win11-podman-test

# Alle Snapshots auflisten
ls -lh "$BACKUP_DIR/"

# Zu einem Snapshot zurückwechseln
sudo virsh shutdown win11-podman-test
sleep 30
sudo cp "$BACKUP_DIR/00-fresh-win11.qcow2" "$DISK"
sudo virsh start win11-podman-test
echo "Zurückgesetzt auf Snapshot '00-fresh-win11'"

# Einzelnen Snapshot löschen
sudo rm "$BACKUP_DIR/00-fresh-win11.qcow2"
```

### Empfohlene Snapshot-Struktur für dieses Projekt

```bash
DISK="/mnt/data2/virtimages/win11-podman-test.qcow2"
BACKUP_DIR="/mnt/data2/virtimages/backups"
mkdir -p "$BACKUP_DIR"

# Backup 1: Nach Windows-Grundinstallation + Treiber + OpenSSH
sudo virsh shutdown win11-podman-test && sleep 30
sudo cp "$DISK" "$BACKUP_DIR/00-fresh-win11.qcow2"
sudo virsh start win11-podman-test
echo "Backup '00-fresh-win11' erstellt: Windows 11 Pro, Virtio-Treiber, OpenSSH aktiv."

# Backup 2: Nach dem Kopieren der Deployment-Dateien, vor Run-Test.cmd
sudo virsh shutdown win11-podman-test && sleep 30
sudo cp "$DISK" "$BACKUP_DIR/01-pre-install.qcow2"
sudo virsh start win11-podman-test
echo "Backup '01-pre-install' erstellt: Deployment-Paket kopiert, bereit zum Testen."

# Backup 3: Nach Install-Master.ps1, vor dem Reboot
sudo virsh shutdown win11-podman-test && sleep 30
sudo cp "$DISK" "$BACKUP_DIR/02-post-install-pre-reboot.qcow2"
sudo virsh start win11-podman-test
echo "Backup '02-post-install-pre-reboot' erstellt: Install-Master.ps1 abgeschlossen."

# Backup 4: Nach erstem Reboot, WSL aktiviert
sudo virsh shutdown win11-podman-test && sleep 30
sudo cp "$DISK" "$BACKUP_DIR/03-post-reboot.qcow2"
sudo virsh start win11-podman-test
echo "Backup '03-post-reboot' erstellt: WSL2 aktiv."

# Backup 5: Nach erfolgreichem User-Init
sudo virsh shutdown win11-podman-test && sleep 30
sudo cp "$DISK" "$BACKUP_DIR/04-post-user-init.qcow2"
sudo virsh start win11-podman-test
echo "Backup '04-post-user-init' erstellt: Vollstaendig konfiguriert."
```

### Schneller Revert-Befehl (Alias)

```bash
# In ~/.bashrc hinzufügen für schnellen Zugriff:
alias revert-snapshot='sudo virsh shutdown win11-podman-test && sleep 30 && sudo cp /mnt/data2/virtimages/backups/01-pre-install.qcow2 /mnt/data2/virtimages/win11-podman-test.qcow2 && sudo virsh start win11-podman-test'

# Dann einfach aufrufen:
revert-snapshot  # Setzt auf '01-pre-install' zurück
```

---

## 5. Deployment-Dateien in die VM kopieren

### Methode: scp (empfohlen, wenn VM läuft)

```bash
# IP der VM ermitteln
VM_IP=$(sudo virsh domifaddr win11-podman-test | awk '/ipv4/{print $4}' | cut -d'/' -f1)
echo "VM IP: $VM_IP"

# Deployment-Verzeichnis in die VM kopieren
# Passe /mnt/data1/dev/podman_cooperate_installer_base an deinen Pfad an
scp -r /mnt/data1/dev/podman_cooperate_installer_base ITAdmin@$VM_IP:"C:/Podman-Deployment"

# Podman Desktop Installer ebenfalls kopieren (falls lokal vorhanden)
# scp /path/to/podman-desktop-setup.exe ITAdmin@$VM_IP:"C:/Podman-Deployment/"
```

### Methode: virt-copy-in (wenn VM gestoppt ist)

```bash
# VM stoppen
sudo virsh shutdown win11-podman-test
# Warten bis gestoppt:
sudo virsh list --all  # Status sollte "shut off" sein

# Dateien direkt ins Image kopieren
sudo virt-copy-in \
  -a /var/lib/libvirt/images/win11-podman-test.qcow2 \
  /mnt/data1/dev/podman_cooperate_installer_base \
  /Users/ITAdmin/Desktop/

# VM wieder starten
sudo virsh start win11-podman-test
virt-viewer --connect qemu:///system win11-podman-test &
```

---

## 6. Test-Iteration Workflow

```
Snapshot "01-pre-install"
        │
        ▼
┌───────────────────────────────────────────────────────┐
│  In Windows (als ITAdmin-Admin, PowerShell):          │
│  cd C:\Podman-Deployment                              │
│  .\Run-Test.cmd                                       │
│                                                       │
│  Prüfe Exit-Code: echo $LASTEXITCODE  → sollte 3010  │
└───────────────────────────────────────────────────────┘
        │
        ▼  Reboot
┌───────────────────────────────────────────────────────┐
│  Login als Standard-User (developer)                  │
│  Warten ~60 Sekunden                                  │
│  Prüfe: podman machine ls                             │
└───────────────────────────────────────────────────────┘
        │
        ▼  Bug gefunden?
┌───────────────────────────────────────────────────────┐
│  Vom Host:                                            │
│  sudo virsh snapshot-revert win11-podman-test \       │
│    "01-pre-install"                                   │
│  sudo virsh start win11-podman-test                   │
│  Skript lokal korrigieren → scp → nochmal testen      │
└───────────────────────────────────────────────────────┘
```

### Schnell-Iteration: Nur Init-PodmanUser.ps1 testen

```bash
# Einzelne Datei aktualisieren ohne neuen Snapshot:
VM_IP=$(sudo virsh domifaddr win11-podman-test | awk '/ipv4/{print $4}' | cut -d'/' -f1)

scp /mnt/data1/dev/podman_cooperate_installer_base/Init-PodmanUser.ps1 \
    ITAdmin@$VM_IP:"C:/ProgramData/CorporateIT/Podman/Init-PodmanUser.ps1"

# Task manuell triggern (in Windows PowerShell als Admin):
# Start-ScheduledTask -TaskName "Podman-User-Init"
# — oder via SSH vom Host:
ssh ITAdmin@$VM_IP "powershell -Command \"Start-ScheduledTask -TaskName 'Podman-User-Init'\""
```

---

## 7. VM-Konsole und Verwaltung

```bash
# Grafische Konsole öffnen
virt-viewer --connect qemu:///system win11-podman-test &

# VM starten / stoppen / hart abschalten
sudo virsh start    win11-podman-test
sudo virsh shutdown win11-podman-test   # Sauber (sendet Shutdown-Signal)
sudo virsh destroy  win11-podman-test   # Sofortiger Abbruch (= Stecker ziehen)

# VM-Status
sudo virsh domstate win11-podman-test

# Alle VMs anzeigen
sudo virsh list --all

# CPU/RAM-Nutzung der VM
sudo virsh domstats win11-podman-test --cpu --balloon
```

---

## 8. VM vollständig löschen

**Alle Daten, Snapshots und NVRAM der VM werden unwiderruflich gelöscht.**

```bash
# Schritt 1: VM stoppen (falls läuft)
sudo virsh destroy win11-podman-test 2>/dev/null || true

# Schritt 2: VM-Definition + NVRAM + alle Storage-Images löschen
sudo virsh undefine win11-podman-test \
  --nvram \
  --remove-all-storage \
  --delete-snapshots

# Schritt 3: Prüfen, ob alles weg ist
sudo virsh list --all | grep win11        # Sollte keine Ausgabe zeigen
ls /var/lib/libvirt/images/ | grep win11  # Sollte keine Ausgabe zeigen

# Schritt 4: Eventuelle NVRAM-Datei manuell entfernen (falls noch vorhanden)
sudo rm -f /var/lib/libvirt/qemu/nvram/win11-podman-test_VARS.fd
```

---

## 9. Troubleshooting

### Problem: `virt-install` schlägt fehl mit "OVMF not found"
```bash
# Verfügbare OVMF-Dateien anzeigen:
ls /usr/share/OVMF/

# Falls nur OVMF_CODE.fd (kein _4M):
sudo apt install --reinstall ovmf
# Oder manuellen Pfad anpassen:
# --boot loader=/usr/share/OVMF/OVMF_CODE.fd,...
```

### Problem: Windows 11 Installer zeigt "PC doesn't meet requirements"
```bash
# CPU-Passthrough erzwingen (ist bereits in obigem Befehl enthalten):
# --cpu host-passthrough
# Falls immer noch Fehler: Registry-Bypass während der Installation:
# Im Installer SHIFT+F10 → regedit →
# HKLM\SYSTEM\Setup\LabConfig → DWORD:
#   BypassTPMCheck = 1
#   BypassSecureBootCheck = 1
#   BypassRAMCheck = 1
```

### Problem: Netzwerk in der VM nicht verfügbar
```bash
# Auf dem Host: libvirt default-Netzwerk prüfen
sudo virsh net-list --all
sudo virsh net-start default   # Falls "inactive"
sudo virsh net-autostart default
```

### Problem: Nested Virtualization — WSL2 startet nicht in der VM
```bash
# Auf dem Host prüfen:
sudo virt-host-validate
# Suche nach: QEMU: Checking for device assignment IOMMU support

# Im Windows-Gast prüfen (PowerShell als Admin):
# Get-WmiObject -Class Win32_ComputerSystem | Select-Object HypervisorPresent
# systeminfo | findstr "Hyper-V"  → sollte "Ja" zeigen
```

### Problem: scp-Verbindung schlägt fehl
```bash
# Prüfe, ob OpenSSH in Windows läuft:
# Windows PowerShell: Get-Service sshd
# Windows Firewall ggf. öffnen:
# New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22

# SSH known_hosts bereinigen (nach Snapshot-Revert):
ssh-keygen -R "$VM_IP"