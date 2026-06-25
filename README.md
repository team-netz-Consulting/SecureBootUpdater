# Secure Boot / UEFI Ablauf (Windows + VMware)

Dieses Verzeichnis enthaelt zwei PowerShell-Skripte fuer den Secure-Boot/UEFI-2023-Ablauf:

- `SecureBoot.ps1` -> Ausfuehrung auf der betroffenen Windows Client/Server-VM
- `Vmware-ManageSecureBoot.ps1` -> Ausfuehrung auf einem Admin-PC mit VMware PowerCLI

## Enthaltene Dateien

- `SecureBoot.ps1`
- `Vmware-ManageSecureBoot.ps1`
- `Start-SecureBoot.bat`
- `Start-Vmware-ManageSecureBoot.bat`

Optional lokal (werden bei Bedarf automatisch geladen):

- `WindowsOEMDevicesPK.der`
- `KEK-2023.der`

Hinweis:
- Die Zertifikatsdateien sind per `.gitignore` vom Repository ausgeschlossen.

## Voraussetzungen

### Fuer `SecureBoot.ps1` (auf VM)

- Windows VM mit UEFI/Secure Boot
- PowerShell als Administrator gestartet
- Zugriff auf folgende Windows-Kommandos:
  - `Confirm-SecureBootUEFI`
  - `Get-SecureBootUEFI`
  - `Get-ScheduledTask` / `Start-ScheduledTask`
  - `Get-Disk`, `Initialize-Disk`, `New-Partition`, `Format-Volume`
- Optionaler Internetzugriff fuer Zertifikat-Download (Fallback)

### Fuer `Vmware-ManageSecureBoot.ps1` (Admin-PC)

- Windows Admin-PC mit installiertem VMware PowerCLI
- Netzwerkzugriff auf vCenter
- Berechtigung zum Aendern von VM-Settings und Power-Operationen
- Anmeldung an vCenter moeglich

## Installation VMware PowerCLI (Admin-PC)

PowerShell als Administrator:

```powershell
Install-Module VMware.PowerCLI -Scope CurrentUser
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false
```

## Script 1: `SecureBoot.ps1` (auf betroffener VM)

### Start (empfohlen per BAT)

```bat
Start-SecureBoot.bat
```

Die Batch-Datei:
- fordert bei Bedarf automatisch Administratorrechte an
- startet `SecureBoot.ps1` mit `ExecutionPolicy Bypass`

### Start

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\support
.\SecureBoot.ps1
```

Hinweis:
- Das Skript prueft beim Start, ob die Zertifikate `WindowsOEMDevicesPK.der` und `KEK-2023.der` im gleichen Ordner liegen.
- Falls eine Datei fehlt oder ungueltig ist, wird ein Download versucht.
- Erwartete Subjects:
  - PK: `CN=Windows UEFI CA 2023`
  - KEK: `CN=Microsoft Corporation KEK 2K CA 2023`

### Menuepunkte (Kurzueberblick)

- `1` Secure-Boot-Update Status pruefen (kompakte Gruen/Rot-Ausgabe)
- `2` DB-Zertifikat einspielen (Trigger `0x40`)
- `3` DB-Zertifikat pruefen
- `4` KEK/Bootmanager Trigger (`0x5944`) + Event-Entscheidung + Hilfsdisk-/Zertifikatsablauf
- `6` Platform-Key-Enrollment Anleitung

### Typischer Ablauf auf der VM

1. Menuepunkt `1`: Ausgangslage pruefen
2. Menuepunkt `2`: DB-Zertifikat einspielen
3. Reboot
4. Menuepunkt `3`: DB-Status pruefen
5. Menuepunkt `4`: KEK/Bootmanager triggern und Event-Entscheidung auswerten

Normalfall (kein Event 1803):
1. Event `1799` bzw. kein Fehlerpfad
2. Menuepunkt `1` oder `3` zur Abschlusspruefung
3. Aufraeumen (Hilfsdisk entfernen, Dokumentation aktualisieren)

Sonderfall Event `1803`:
1. Nicht rebooten
2. Hilfsdisk vorbereiten und Zertifikate kopieren (wird im Ablauf gefuehrt)
3. Auf Admin-PC zu `Vmware-ManageSecureBoot.ps1` wechseln
4. Dort Menuepunkt `4` fuer EFI-Enrollment + Rollback ausfuehren
5. Zurueck auf die betroffene VM und mit Menuepunkt `1` oder `3` verifizieren
6. Danach aufraeumen (VM herunterfahren, Rollback bestaetigen, 128-MB-Disk loeschen)

## Script 2: `Vmware-ManageSecureBoot.ps1` (auf Admin-PC)

### Start (empfohlen per BAT)

```bat
Start-Vmware-ManageSecureBoot.bat
```

Die Batch-Datei startet das VMware-Skript direkt mit `ExecutionPolicy Bypass`.
Sie fordert ebenfalls automatisch Administratorrechte an.

### Start

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
cd C:\support
.\Vmware-ManageSecureBoot.ps1
```

### Konfiguration

Im Skript den vCenter-Namen pruefen/anpassen:

```powershell
$vCenter = "vcenter.bachl.local"
```

### Menuepunkte (Kurzueberblick)

- `1` VMware Host + VM Firmware/SecureBoot Status
- `2` Lokale SecureBoot-Abfrage (auf dem Admin-PC)
- `3` Gemerkte VMs mit UEFI + SecureBoot TRUE
- `4` EFI vorbereiten + Enrollment + Rollback (per VM-Name)

### Ablauf Menuepunkt 4 (Admin-PC)

1. VM-Name eingeben
2. Skript faehrt VM herunter (falls noetig)
3. Setzt `uefi.allowAuthBypass=TRUE`
4. Aktiviert `Force EFI Setup`
5. Startet VM
6. Zeigt EFI-Enrollment-Anleitung an
7. Wartet auf Bestaetigung (Enter)
8. Fuehrt Rollback aus:
   - VM herunterfahren
   - `uefi.allowAuthBypass` zuruecksetzen/entfernen
   - `Force EFI Setup` auf alten Zustand
   - VM wieder starten

## Empfohlene Betriebsreihenfolge

1. Auf Admin-PC: `Vmware-ManageSecureBoot.ps1` fuer VM-Vorbereitung/EFI-Setup nutzen
2. Auf betroffener VM: `SecureBoot.ps1` fuer Zertifikate, Trigger, Pruefung und Verifikation nutzen
3. Nach erfolgreichem Abschluss aufraeumen:
   - temporaere 128-MB-Hilfsdisk entfernen
   - Dokumentation der Aenderungen aktualisieren

## Troubleshooting

- `Confirm-SecureBootUEFI konnte nicht gelesen werden`
  - PowerShell als Administrator starten
  - Pruefen, ob VM wirklich UEFI/Secure-Boot-faehig ist

- Zertifikate fehlen trotz Download
  - Internet/Proxy pruefen
  - Zertifikate manuell in denselben Ordner wie `SecureBoot.ps1` legen

- Event 1803 bleibt bestehen
  - PK/KEK Enrollment im EFI-Menue erneut sauber durchfuehren
  - Auf Commit/Yes und fehlende rote Fehler achten

- VMware-Befehle schlagen fehl
  - PowerCLI-Modul und vCenter-Login pruefen
  - Berechtigungen auf VM und vCenter kontrollieren

## Sicherheitshinweise

- Vor kritischen Schritten Snapshot erstellen
- Bei vTPM + BitLocker vorher Recovery-Key sichern oder Schutz temporaer aussetzen
- Hilfsdisk immer eindeutig identifizieren (128 MB = 134217728 Byte)
- Nie ungepruefte Datentraeger formatieren

## Lizenz

Apache License 2.0

## Haftungsausschluss

Nutzung auf eigene Gefahr.

Dieses Repository und die enthaltenen Skripte werden ohne Gewaehr bereitgestellt.
Es wird keine Haftung fuer direkte oder indirekte Schaeden, Datenverlust, Ausfaelle,
Fehlkonfigurationen oder Folgeschaeden uebernommen, die durch die Verwendung,
Anpassung oder Ausfuehrung der Skripte entstehen.

Vor produktivem Einsatz:

1. In Testumgebung pruefen.
2. Vollstaendige Backups/Snapshots erstellen.
3. Change- und Freigabeprozess der Organisation einhalten.
4. Auswirkungen auf BitLocker, vTPM, Boot- und Recovery-Prozesse bewerten.

Die Verantwortung fuer Planung, Ausfuehrung und Betrieb liegt beim jeweiligen
Anwender bzw. Betreiber.
