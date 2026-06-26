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
sudo mkdir -p /var/lib/libvirt/images

sudo qemu-img create -f qcow2 \
  /var/lib/libvirt/images/win11-podman-test.qcow2 \
  80G
```

### VM mit virt-install definieren und starten

```bash
# ISO-Pfad anpassen falls nötig
WIN11_ISO="/iso/$(ls /iso/ | grep -i win11 | head -1)"
echo "Verwende ISO: $WIN11_ISO"

sudo virt-install \
  --name win11-podman-test \
  --memory 8192 \
  --vcpus 4 \
  --cpu host-passthrough \
  --os-variant win11 \
  --machine q35 \
  --boot loader=/usr/share/OVMF/OVMF_CODE_4M.secboot.fd,loader.readonly=yes,loader.type=pflash,loader.secure=yes,nvram.template=/usr/share/OVMF/OVMF_VARS_4M.ms.fd \
  --features smm.state=on \
  --clock hypervclock.present=yes \
  --tpm emulator,model=tpm-crb,version=2.0 \
  --disk path=/var/lib/libvirt/images/win11-podman-test.qcow2,format=qcow2,bus=virtio,cache=writeback \
  --disk "$WIN11_ISO",device=cdrom,bus=sata \
  --disk /iso/virtio-win.iso,device=cdrom,bus=sata \
  --network network=default,model=virtio \
  --graphics spice,listen=127.0.0.1 \
  --video qxl \
  --channel spicevmc \
  --noautoconsole \
  --wait -1
```

> **Hinweis:** `--noautoconsole` startet die Installation ohne GUI-Fenster.  
> Den Installer-Desktop öffnen mit:
> ```bash
> virt-viewer --connect qemu:///system win11-podman-test &
> ```

### Alternativer OVMF-Pfad (ältere Linux Mint / Ubuntu 20.04)

Falls der obige Befehl mit "file not found" für OVMF fehlschlägt:
```bash
ls /usr/share/OVMF/
# Wenn nur OVMF_CODE.fd existiert (ohne _4M):
# --boot loader=/usr/share/OVMF/OVMF_CODE.fd,loader.readonly=yes,loader.type=pflash ...
```

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

## 4. Snapshots: Workflow

### IP-Adresse der VM ermitteln

```bash
# Methode 1: via virsh
sudo virsh domifaddr win11-podman-test

# Methode 2: via arp (nach erster Verbindung)
arp -n | grep virbr
```

### Snapshot-Befehle

```bash
# Snapshot erstellen (VM kann laufen ODER gestoppt sein)
# Empfehlung: VM vorher sauber herunterfahren für konsistente Snapshots
sudo virsh snapshot-create-as \
  --domain win11-podman-test \
  --name "00-fresh-win11" \
  --description "Frische Windows 11 Installation nach allen Treibern, vor Podman"

# Alle Snapshots auflisten
sudo virsh snapshot-list win11-podman-test --tree

# Details zu einem Snapshot anzeigen
sudo virsh snapshot-info win11-podman-test "00-fresh-win11"

# Zu einem Snapshot zurückwechseln
sudo virsh snapshot-revert win11-podman-test "00-fresh-win11"
sudo virsh start win11-podman-test   # VM danach neu starten

# Einzelnen Snapshot löschen
sudo virsh snapshot-delete win11-podman-test "00-fresh-win11"
```

### Empfohlene Snapshot-Struktur für dieses Projekt

```bash
# Snapshot 1: Nach Windows-Grundinstallation + Treiber + OpenSSH
sudo virsh snapshot-create-as win11-podman-test \
  --name "00-fresh-win11" \
  --description "Windows 11 Pro, Virtio-Treiber, OpenSSH aktiv. Kein Podman."

# Snapshot 2: Nach dem Kopieren der Deployment-Dateien, vor Run-Test.cmd
sudo virsh snapshot-create-as win11-podman-test \
  --name "01-pre-install" \
  --description "Deployment-Paket in C:\Podman-Deployment kopiert. Bereit zum Testen."

# Snapshot 3: Nach Install-Master.ps1, vor dem Reboot
sudo virsh snapshot-create-as win11-podman-test \
  --name "02-post-install-pre-reboot" \
  --description "Install-Master.ps1 abgeschlossen. Scheduled Tasks erstellt. Warte auf Reboot."

# Snapshot 4: Nach erstem Reboot, WSL aktiviert
sudo virsh snapshot-create-as win11-podman-test \
  --name "03-post-reboot" \
  --description "WSL2 aktiv. Bereit für User-Init-Test."

# Snapshot 5: Nach erfolgreichem User-Init
sudo virsh snapshot-create-as win11-podman-test \
  --name "04-post-user-init" \
  --description "Podman Machine laeuft. Zero-Trust aktiv. Vollstaendig konfiguriert."
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