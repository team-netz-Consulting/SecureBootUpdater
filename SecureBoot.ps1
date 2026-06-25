<#
    Script: SecureBoot.ps1
    Author: Michael Schwenke
    Company: team-netz Consulting GmbH
    License: Apache License 2.0

    Zweck:
    Interaktives Windows Secure-Boot/UEFI Hilfsscript fuer Pruefung, Vorbereitung,
    Zertifikatsbereitstellung und gefuehrte Enrollment-Schritte (PK/KEK 2023).

    Version History:
    - 1.0.0: Basismenue mit Statuspruefungen und Trigger-Aktionen
    - 1.1.0: Farbige Statusausgabe und kompaktere Erlaeuterungen
    - 1.2.0: Hilfsdisk-Automation, Zertifikat-Download-Fallback und Enrollment-Hinweise

    https://learn.microsoft.com/de-de/windows-hardware/manufacture/desktop/windows-secure-boot-key-creation-and-management-guidance?view=windows-11#14-signature-databases-db-and-dbx
    https://techcommunity.microsoft.com/blog/windows-itpro-blog/secure-boot-playbook-for-certificates-expiring-in-2026/4469235/replies/4477370


    Inspiration zu dem Halbautomatischen Script.
    https://knowledge.broadcom.com/external/article/423893
    https://knowledge.broadcom.com/external/article/423919/manual-update-of-secure-boot-variables-i.html
    https://support.microsoft.com/de-de/topic/beispielskript-f%C3%BCr-die-sammlung-von-daten-f%C3%BCr-den-sicheren-startbestand-d02971d2-d4b5-42c9-b58a-8527f0ffa30b
    https://support.microsoft.com/de-de/topic/beispielleitfaden-f%C3%BCr-die-e2e-automatisierung-f%C3%BCr-den-sicheren-start-f850b329-9a6e-40d1-823a-0925c965b8a0
    https://s-edv.com/anleitungen/secure-boot-2023-uefi-zertifikate-windows-server-vmware

    Alternative, ab 8.02 https://github.com/haz-ard-9/Windows-vSphere-VMs-Bulk-Secure-Boot-2023-Certificate-Remediation, aber nicht supporetet durch Broadcom/Microsoft, daher nicht fuer produktive Umgebungen empfohlen.
#>

function Show-Menu {
    Clear-Host
    Write-Host "======================================"
    Write-Host " Computername: $env:COMPUTERNAME " -ForegroundColor Cyan
    Write-Host "======================================"
    Write-Host " Secure Boot / UEFI Check"
    Write-Host "======================================"
    Write-Host "1. Secure-Boot-Update Status prüfen"
    Write-Host "2. DB-Zertifikat einspielen"
    Write-Host "3. DB-Zertifikat prüfen"
    Write-Host "4. KEK und Bootmanager anstoßen - Trigger 0x5944"
    Write-Host "6. Platform-Key-Enrollment (Anleitung)"
    Write-Host "0. Beenden"
    Write-Host ""
}

function Test-IsAdministrator {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Initialize-HelperDisk {
    Write-Host "Hilfsdisk vorbereiten (128 MB / 134217728 Byte)" -ForegroundColor Cyan
    Write-Host ""

    $allDisks = Get-Disk
    $allDisks | Select-Object Number, Size, OperationalStatus | Format-Table -AutoSize | Out-Host
    Write-Host ""

    $targetSizeBytes = [uint64]134217728
    $sizeToleranceBytes = [uint64]1048576
    $candidateDisks = @(
        $allDisks | Where-Object {
            $null -ne $_.Number -and
            [uint64]$_.Size -ge ($targetSizeBytes - $sizeToleranceBytes) -and
            [uint64]$_.Size -le ($targetSizeBytes + $sizeToleranceBytes)
        }
    )
    $suggestedNumber = $null
    if ($candidateDisks.Count -eq 1) {
        $suggestedNumber = $candidateDisks[0].Number
        Write-Host "Vorschlag: Disk $suggestedNumber (134217728 Byte)" -ForegroundColor Green
    }
    elseif ($candidateDisks.Count -gt 1) {
        $suggestedNumber = $candidateDisks[0].Number
        Write-Host "Mehrere 128-MB-Disks gefunden. Vorschlag: Disk $suggestedNumber" -ForegroundColor Yellow
    }
    else {
        Write-Host "Keine exakte 128-MB-Disk gefunden. Bitte Disk-Nummer manuell waehlen." -ForegroundColor Yellow
    }

    $prompt = if ($null -ne $suggestedNumber) {
        "Disk-Nummer der 128-MB-Hilfsdisk (Enter = $suggestedNumber)"
    }
    else {
        "Disk-Nummer der 128-MB-Hilfsdisk"
    }

    $n = Read-Host $prompt
    if ([string]::IsNullOrWhiteSpace($n) -and $null -ne $suggestedNumber) {
        $n = [string]$suggestedNumber
    }

    if ($n -notmatch '^\d+$') {
        Write-Host "Ungueltige Eingabe. Bitte eine numerische Disk-Nummer eingeben." -ForegroundColor Red
        return $null
    }

    $disk = Get-Disk -Number ([int]$n) -ErrorAction SilentlyContinue
    if (-not $disk) {
        Write-Host "Disk wurde nicht gefunden." -ForegroundColor Red
        return $null
    }

    if ($disk.Size -ne 134217728) {
        Write-Host "WARNUNG: Ausgewaehlte Disk hat nicht 134217728 Byte!" -ForegroundColor Red
        Write-Host "Abbruch zur Sicherheit, damit keine falsche Disk formatiert wird." -ForegroundColor Red
        return $null
    }

    try {
        Set-Disk -Number $disk.Number -IsOffline $false -ErrorAction Stop | Out-Null
        Set-Disk -Number $disk.Number -IsReadOnly $false -ErrorAction Stop | Out-Null

        # Hilfsdisk idempotent vorbereiten: vorhandene Partitionen entfernen und neu anlegen.
        $existingPartitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue
        if ($existingPartitions) {
            foreach ($p in $existingPartitions) {
                Remove-Partition -DiskNumber $disk.Number -PartitionNumber $p.PartitionNumber -Confirm:$false -ErrorAction Stop
            }
        }

        $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
        if ($disk.PartitionStyle -eq 'RAW') {
            Initialize-Disk -Number $disk.Number -PartitionStyle MBR -ErrorAction Stop | Out-Null
        }

        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
        Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT32 -NewFileSystemLabel KEYUPDATE -Confirm:$false -Force -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Host "Fehler beim Vorbereiten der Hilfsdisk: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    $drive = "$($part.DriveLetter):"
    Write-Host "Laufwerk: $drive" -ForegroundColor Green
    return [string]$drive
}

function Test-CertificateFileSubject {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$ExpectedPattern,
        [Parameter(Mandatory=$true)]
        [string]$DisplayName
    )

    if (-not (Test-Path $Path)) {
        return $false
    }

    try {
        $subject = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($Path)).Subject
        if ($subject -match $ExpectedPattern) {
            return $true
        }

        Write-Host "$DisplayName hat unerwartetes Subject: $subject" -ForegroundColor Red
        return $false
    }
    catch {
        Write-Host "$DisplayName ist keine gueltige Zertifikatsdatei: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Get-CertificateFile {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [string]$Url,
        [Parameter(Mandatory=$true)]
        [string]$ExpectedPattern,
        [Parameter(Mandatory=$true)]
        [string]$DisplayName
    )

    if (Test-CertificateFileSubject -Path $Path -ExpectedPattern $ExpectedPattern -DisplayName $DisplayName) {
        return $true
    }

    if (Test-Path $Path) {
        Write-Host "$DisplayName ist ungueltig, versuche erneuten Download..." -ForegroundColor Yellow
    }
    else {
        Write-Host "$DisplayName fehlt, versuche Download..." -ForegroundColor Yellow
    }

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Path -UseBasicParsing -ErrorAction Stop
        Write-Host "Download erfolgreich: $Path" -ForegroundColor Green
    }
    catch {
        Write-Host "Download fehlgeschlagen fuer ${DisplayName}: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }

    return (Test-CertificateFileSubject -Path $Path -ExpectedPattern $ExpectedPattern -DisplayName $DisplayName)
}

function Get-HelperCertificates {
    $pkSource = Join-Path $PSScriptRoot 'WindowsOEMDevicesPK.der'
    $kekSource = Join-Path $PSScriptRoot 'KEK-2023.der'

    $pkUrl = 'https://go.microsoft.com/fwlink/?LinkId=2239776'
    $kekUrl = 'https://go.microsoft.com/fwlink/p/?linkid=2239775'

    $pkOk = Get-CertificateFile `
        -Path $pkSource `
        -Url $pkUrl `
        -ExpectedPattern 'CN=Windows UEFI CA 2023' `
        -DisplayName 'WindowsOEMDevicesPK.der'

    if (-not $pkOk) {
        return $false
    }

    $kekOk = Get-CertificateFile `
        -Path $kekSource `
        -Url $kekUrl `
        -ExpectedPattern 'CN=Microsoft Corporation KEK 2K CA 2023' `
        -DisplayName 'KEK-2023.der'

    return $kekOk
}

function Copy-HelperCertificatesToDisk {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Drive
    )

    $normalizedDrive = $Drive.Trim()
    if ($normalizedDrive.EndsWith('\\')) {
        $normalizedDrive = $normalizedDrive.TrimEnd('\\')
    }
    if ($normalizedDrive.Length -eq 1) {
        $normalizedDrive = "${normalizedDrive}:"
    }

    $pkSource = Join-Path $PSScriptRoot 'WindowsOEMDevicesPK.der'
    $kekSource = Join-Path $PSScriptRoot 'KEK-2023.der'

    #
    #$certsReady = Get-HelperCertificates
    #if (-not $certsReady) {
    #    Write-Host "Zertifikate konnten nicht bereitgestellt werden." -ForegroundColor Red
    #    return $false
    #}
    

    if (-not (Test-Path $pkSource)) {
        Write-Host "Datei fehlt: $pkSource" -ForegroundColor Red
        return $false
    }
    if (-not (Test-Path $kekSource)) {
        Write-Host "Datei fehlt: $kekSource" -ForegroundColor Red
        return $false
    }

    Copy-Item $pkSource "$normalizedDrive\\" -Force
    Copy-Item $kekSource "$normalizedDrive\\" -Force

    $pkSubject = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $normalizedDrive 'WindowsOEMDevicesPK.der'))).Subject
    $kekSubject = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $normalizedDrive 'KEK-2023.der'))).Subject

    Write-Host "PK Subject:  $pkSubject"
    Write-Host "KEK Subject: $kekSubject"

    
    #$pkOk = $pkSubject -match 'CN=Windows OEM Devices PK'
    $pkOk = $pkSubject -match 'CN=Windows UEFI CA 2023'
    $kekOk = $kekSubject -match 'CN=Microsoft Corporation KEK 2K CA 2023'

    if ($pkOk -and $kekOk) {
        Write-Host "Subject-Pruefung erfolgreich." -ForegroundColor Green
        return $true
    }

    Write-Host "Subject-Pruefung fehlgeschlagen. Erwartet: CN=Windows UEFI CA 2023 und CN=Microsoft Corporation KEK 2K CA 2023." -ForegroundColor Red
    return $false
}

function Show-PlatformKeyEnrollmentGuide {
    Write-Host "--- $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host "Schritt 6: Platform-Key-Enrollment" -ForegroundColor Green
    Write-Host ""

    Write-Host "Hilfsdisk anlegen und Zertifikate laden" -ForegroundColor Cyan
    Write-Host "Fahre die VM herunter und lege einen separaten Snapshot an."
    Write-Host "Hange dann eine 128-MB-Disk an (Edit Settings -> Add New Device -> Hard Disk) und starte die VM wieder."
    Write-Host "Die neue Disk hat exakt 134217728 Byte und wird mit FAT32 formatiert."
    Write-Host ""

    Write-Host "PowerShell-Kommandos (Disk vorbereiten):" -ForegroundColor Yellow
    @'
Get-Disk | Select Number, Size, OperationalStatus        # die Disk mit 134217728 Byte ist die neue
$n = <Nummer>                                            # NUR die 128-MB-Disk!
Set-Disk -Number $n -IsOffline $false
Set-Disk -Number $n -IsReadOnly $false
Initialize-Disk -Number $n -PartitionStyle MBR -EA SilentlyContinue
$part = New-Partition -DiskNumber $n -UseMaximumSize -AssignDriveLetter
Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT32 -NewFileSystemLabel KEYUPDATE -Confirm:$false
"Laufwerk: $($part.DriveLetter):"
'@ | Write-Host

    Write-Host ""
    Write-Host "PowerShell-Kommandos (Zertifikate kopieren und Subject pruefen):" -ForegroundColor Yellow
    @'
$drive = '<Buchstabe>:'
Copy-Item '\\fileserver\certs\UEFI-Certs\WindowsOEMDevicesPK.der' "$drive\"
Copy-Item '\\fileserver\certs\UEFI-Certs\KEK-2023.der' "$drive\"
(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("$drive\WindowsOEMDevicesPK.der")).Subject
(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("$drive\KEK-2023.der")).Subject
'@ | Write-Host

    Write-Host "Erwartung: CN=Windows UEFI CA 2023 und CN=Microsoft Corporation KEK 2K CA 2023." -ForegroundColor Green
    Write-Host ""
    Write-Host "Tipp: 128-MB-FAT32-Disk mit beiden .der-Dateien als kleine VMDK aufheben," -ForegroundColor Yellow
    Write-Host "bei der naechsten VM wieder anhaengen, danach sauber dokumentieren und wieder abhaengen."
    Write-Host ""

    Write-Host "EFI vorbereiten und enrollen" -ForegroundColor Cyan
    Write-Host "1) VMX-Parameter uefi.allowAuthBypass = TRUE setzen (Edit Settings -> Advanced Parameters)."
    Write-Host "2) Force EFI Setup aktivieren (VM Options -> Boot Options)."
    Write-Host "3) VM einschalten und Webkonsole oeffnen."
    Write-Host ""
    Write-Host "Im EFI-Menue:" -ForegroundColor Yellow
    Write-Host "1) Secure Boot Configuration -> PK Options -> Enroll PK -> Volume KEYUPDATE -> WindowsOEMDevicesPK.der -> Commit/Yes"
    Write-Host "2) Esc -> KEK Options -> Enroll KEK -> KEK-2023.der -> Commit/Yes"
    Write-Host "3) Esc -> Boot normally"
    Write-Host "VMware committet sofort; globales Speichern ist nicht noetig."
    Write-Host "Auf Bestätigung pro Enroll achten und auf fehlende rote Fehlermeldung."
    Write-Host ""

    Write-Host "Enrollment verifizieren (Windows):" -ForegroundColor Cyan
    @'
$pk = Get-SecureBootUEFI -Name PK
$cert = $pk.Bytes[44..($pk.Bytes.Length-1)]
[IO.File]::WriteAllBytes("$env:TEMP\PK.der", $cert)
(New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("$env:TEMP\PK.der")).Subject   # Windows OEM Devices PK
[Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match '2023'                            # True
Confirm-SecureBootUEFI                                                                                    # True
'@ | Write-Host

    Pause
}

function Test-SecureBootUpdateStatus {
    Write-Host "--- $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host ""

    $statusSecureBoot = $false
    $statusTaskReady = $false
    $statusDbOk = $false
    $statusKekOk = $false
    $secureBootValue = 'n/a'
    $task = 'n/a'
    $dbCheck = $null
    $kekCheck = $null
    $regStatus = $null
    $regError = $null
    $regOk = $null

    Write-Host "Ergebnisse (kompakt):" -ForegroundColor Cyan
    try {
        $secureBoot = Confirm-SecureBootUEFI
        $secureBootValue = $secureBoot
        $statusSecureBoot = ($secureBoot -eq $true)
        Write-Host "SecureBootUEFI: $secureBootValue" -ForegroundColor ($(if ($statusSecureBoot) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "SecureBootUEFI: nicht lesbar" -ForegroundColor Yellow
    }

    try {
        $task = Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update' -ErrorAction Stop |
            Select-Object -ExpandProperty State

        $statusTaskReady = ($task -eq 'Ready')
        Write-Host "ScheduledTask Secure-Boot-Update: $task" -ForegroundColor ($(if ($statusTaskReady) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "ScheduledTask Secure-Boot-Update: nicht vorhanden" -ForegroundColor Yellow
    }

    try {
        $dbCheck = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
        $statusDbOk = ($dbCheck -eq $true)
        Write-Host "DB enthält Windows UEFI CA 2023: $dbCheck" -ForegroundColor ($(if ($statusDbOk) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "DB enthält Windows UEFI CA 2023: nicht lesbar" -ForegroundColor Yellow
    }

    try {
        $kekCheck = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match '2023'
        $statusKekOk = ($kekCheck -eq $true)
        Write-Host "KEK enthält 2023: $kekCheck" -ForegroundColor ($(if ($statusKekOk) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "KEK enthält 2023: nicht lesbar" -ForegroundColor Yellow
    }

    $reg = Get-ItemProperty `
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' `
        -Name UEFICA2023Status, UEFICA2023Error `
        -ErrorAction SilentlyContinue

    if ($reg) {
        $regValues = $reg | Select-Object UEFICA2023Status, UEFICA2023Error
        $regStatus = $regValues.UEFICA2023Status
        $regError = $regValues.UEFICA2023Error
        $regOk = ($regValues.UEFICA2023Error -eq 0 -or $null -eq $regValues.UEFICA2023Error)
        $regErrorText = if ($null -eq $regError -or [string]::IsNullOrWhiteSpace([string]$regError)) { 'leer' } else { $regError }
        Write-Host "Registry UEFICA2023Status: $regStatus" -ForegroundColor Cyan
        Write-Host "Registry UEFICA2023Error: $regErrorText" -ForegroundColor ($(if ($regOk) { 'Green' } else { 'Red' }))
    }
    else {
        Write-Host "Registry UEFICA2023Status/UEFICA2023Error: nicht vorhanden" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Erläuterung:" -ForegroundColor Green

    if ($statusSecureBoot -and $statusTaskReady -and $statusDbOk -and $statusKekOk -and (($regOk -eq $true) -or $null -eq $regOk)) {
        Write-Host "Alles passend: Secure Boot aktiv, Task bereit, DB/KEK 2023 vorhanden." -ForegroundColor Green
    }
    else {
        if (-not $statusSecureBoot) {
            Write-Host "Secure Boot ist nicht aktiv oder nicht lesbar." -ForegroundColor Yellow
        }
        if (-not $statusTaskReady) {
            Write-Host "Secure-Boot-Update ist nicht Ready oder fehlt." -ForegroundColor Yellow
            Write-Host "Naechster Schritt: aktuelles kumulatives Update einspielen und neu starten." -ForegroundColor Yellow
        }
        if ($dbCheck -eq $false -or $kekCheck -eq $false) {
            Write-Host "DB/KEK 2023 unvollstaendig: volles Verfahren weiter durchlaufen." -ForegroundColor Yellow
        }
        if ($regOk -eq $false) {
            Write-Host "Registry meldet Fehlerwert bei UEFICA2023Error." -ForegroundColor Yellow
        }
    }
    Write-Host ""

    Pause
}

function Install-DBCertificate {
    Write-Host "--- $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host "Schritt 2: DB-Zertifikat einspielen" -ForegroundColor Green
    Write-Host ""

    Set-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' `
        -Name AvailableUpdates `
        -Value 0x40

    Write-Host "AvailableUpdates wurde auf 0x40 gesetzt."

    Start-ScheduledTask `
        -TaskPath '\Microsoft\Windows\PI\' `
        -TaskName 'Secure-Boot-Update'

    Write-Host "Scheduled Task Secure-Boot-Update wurde gestartet."
    Write-Host "Warte 45 Sekunden..."
    Start-Sleep -Seconds 45

    Write-Host ""
    Write-Host "Aktueller AvailableUpdates-Wert:"

    Get-ItemProperty `
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' `
        -Name AvailableUpdates |
        Select-Object AvailableUpdates

    Write-Host ""
    Write-Host "Hinweis:" -ForegroundColor Yellow
    Write-Host "Wenn AvailableUpdates auf 0 zurückfällt, wurde das Bit abgearbeitet."
    Write-Host "Danach kontrollierten Reboot durchführen."
    Write-Host "Server 2019 benötigt gelegentlich zwei Neustarts."
    Write-Host ""

    Write-Host "Nach dem Reboot bitte mit Menüpunkt 1 verifizieren:"
    Write-Host "Confirm-SecureBootUEFI sollte True sein."
    Write-Host "DB-Check sollte True sein."
    Write-Host ""

    Pause
}

function Test-DBCertificate {
    Write-Host "--- $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host "Schritt 3: DB-Zertifikat prüfen" -ForegroundColor Green
    Write-Host ""

    try {
        $secureBoot = Confirm-SecureBootUEFI
        Write-Host "Confirm-SecureBootUEFI = $secureBoot"
    }
    catch {
        Write-Host "Confirm-SecureBootUEFI konnte nicht gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $taskState = Get-ScheduledTask `
            -TaskPath '\Microsoft\Windows\PI\' `
            -TaskName 'Secure-Boot-Update' `
            -ErrorAction Stop |
            Select-Object -ExpandProperty State

        Write-Host "Secure-Boot-Update State = $taskState"
    }
    catch {
        Write-Host "Secure-Boot-Update Aufgabe fehlt" -ForegroundColor Yellow
    }

    try {
        $dbCheck = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
        Write-Host "DB enthält Windows UEFI CA 2023 = $dbCheck"
    }
    catch {
        Write-Host "DB konnte nicht gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $kekCheck = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match '2023'
        Write-Host "KEK enthält 2023 = $kekCheck"
    }
    catch {
        Write-Host "KEK konnte nicht gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    $reg = Get-ItemProperty `
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' `
        -Name UEFICA2023Status, UEFICA2023Error `
        -ErrorAction SilentlyContinue

    if ($reg) {
        Write-Host ""
        Write-Host "Registry SecureBoot Servicing:"
        $reg | Select-Object UEFICA2023Status, UEFICA2023Error | Format-List
    }
    else {
        Write-Host "Keine Registry-Werte UEFICA2023Status / UEFICA2023Error gefunden." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Erwartung nach Schritt 2:" -ForegroundColor Green
    Write-Host "Confirm-SecureBootUEFI = True"
    Write-Host "DB enthält Windows UEFI CA 2023 = True"
    Write-Host ""

    Pause
}

function Start-KEKBootmanagerUpdate {
    Write-Host "--- $env:COMPUTERNAME ---" -ForegroundColor Cyan
    Write-Host "Schritt 4: KEK und Bootmanager anstoßen - Trigger 0x5944" -ForegroundColor Green
    Write-Host ""

    Write-Host "WICHTIG: Vorher frischen Snapshot erstellen!" -ForegroundColor Yellow
    $confirm = Read-Host "Weiter mit Trigger 0x5944? (J/N)"
    if ($confirm -notin @("J","j","Y","y")) {
        Write-Host "Abgebrochen."
        Pause
        return
    }

    Set-ItemProperty `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' `
        -Name AvailableUpdates `
        -Value 0x5944

    Write-Host "AvailableUpdates wurde auf 0x5944 gesetzt."

    Start-ScheduledTask `
        -TaskPath '\Microsoft\Windows\PI\' `
        -TaskName 'Secure-Boot-Update'

    Write-Host "Secure-Boot-Update wurde gestartet."
    Write-Host "Warte 60 Sekunden..."
    Start-Sleep -Seconds 60

    Write-Host ""
    Write-Host "Aktueller AvailableUpdates-Wert:"
    Get-ItemProperty `
        'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' `
        -Name AvailableUpdates |
        Select-Object AvailableUpdates

    Write-Host ""
    Write-Host "TPM-WMI Events der letzten 5 Minuten:" -ForegroundColor Cyan

    $events = Get-WinEvent -FilterHashtable @{
        LogName      = 'System'
        ProviderName = 'Microsoft-Windows-TPM-WMI'
        StartTime    = (Get-Date).AddMinutes(-5)
    } -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Id -in 1043,1044,1045,1799,1800,1801,1803,1795,1796
    }

    if ($events) {
        $events | Select-Object TimeCreated, Id, Message | Format-List
    }
    else {
        Write-Host "Keine relevanten TPM-WMI Events gefunden." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Zertifikatsstatus nach Triggerlauf:" -ForegroundColor Cyan

    try {
        $dbCheckAfter = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'
        Write-Host "DB enthält Windows UEFI CA 2023 = $dbCheckAfter" -ForegroundColor ($(if ($dbCheckAfter) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "DB konnte nicht gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    try {
        $kekCheckAfter = [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match '2023'
        Write-Host "KEK enthält 2023 = $kekCheckAfter" -ForegroundColor ($(if ($kekCheckAfter) { 'Green' } else { 'Red' }))
    }
    catch {
        Write-Host "KEK konnte nicht gelesen werden: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Entscheidung:" -ForegroundColor Green

    if ($events.Id -contains 1803) {
        Write-Host "Event 1803 gefunden: Kein PK-signierter KEK gefunden." -ForegroundColor Red
        Write-Host "NICHT rebooten!" -ForegroundColor Red
        Write-Host "Trigger wird auf 0 zurückgesetzt..."

        Set-ItemProperty `
            -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot' `
            -Name AvailableUpdates `
            -Value 0

        Write-Host "AvailableUpdates wurde auf 0 zurückgesetzt."
        Write-Host "Weiter mit Schritt 5: Platform-Key-Enrollment."
        Write-Host ""
        Write-Host "Schritt 5 (nur bei Event 1803):" -ForegroundColor Yellow
        Write-Host "- Nicht rebooten."
        Write-Host "- Bei vTPM + BitLocker/versiegelter Verschluesselung: Recovery-Key sichern oder Schutz temporaer aussetzen."
        Write-Host "- VM herunterfahren, separaten Snapshot erstellen und 128-MB-Hilfsdisk sofort anhaengen (134217728 Byte)."
        Write-Host "- VM starten und Hilfsdisk direkt per Subfunktion vorbereiten." -ForegroundColor Cyan

        $runPrepare = Read-Host "Hilfsdisk jetzt vorbereiten? (J/N)"
        if ($runPrepare -in @("J","j","Y","y")) {
            $preparedDrive = Initialize-HelperDisk
            if ($preparedDrive) {
                Write-Host "Hilfsdisk erfolgreich vorbereitet: $preparedDrive" -ForegroundColor Green

                Write-Host "Zertifikate werden jetzt aus dem Script-Ordner auf die Hilfsdisk kopiert und geprueft..." -ForegroundColor Cyan
                $copyOk = Copy-HelperCertificatesToDisk -Drive $preparedDrive
                if ($copyOk) {
                    Write-Host "Zertifikate wurden kopiert und validiert." -ForegroundColor Green
                }
            }
        }

        Write-Host ""
        Write-Host "Kurzanleitung (naechster Schritt):" -ForegroundColor Yellow
        Write-Host "1 - Wechsel auf den Admin-PC und starte Vmware-ManageSecureBoot.ps1."
        Write-Host "2 - Waehle Menuepunkt 4 (EFI vorbereiten + Enrollment + Rollback)."
        Write-Host "3 - Fuehre PK/KEK Enrollment in der VMware-Webkonsole durch und bestaetige danach im VM-Script."
        Write-Host "4 - Zurueck auf dieser VM: Menuepunkt 1 oder 3 zur Pruefung ausfuehren."
        Write-Host ""
        Write-Host "Wenn alles passt, dann aufraeumen:" -ForegroundColor Yellow
        Write-Host "1 - VM herunterfahren."
        Write-Host "2 - Im VM-Script bestaetigen, damit die Einstellungen zurueckgesetzt werden."
        Write-Host "3 - Die 128-MB-Disk loeschen."
    }
    elseif ($events.Id -contains 1799) {
        Write-Host "Event 1799 gefunden: Bootmanager 2023 installiert." -ForegroundColor Green
        Write-Host "Weiter mit Schritt 6."
    }
    else {
        Write-Host "Weder Event 1803 noch Event 1799 gefunden." -ForegroundColor Yellow
        Write-Host "Events prüfen, bevor ein Reboot durchgeführt wird."
    }

    Write-Host ""
    Write-Host "Hinweis: Windows Server 2025 formuliert die Events ggf. leicht anders,"
    Write-Host "z. B. mit 'Ursache: Boot Manager'. Inhaltlich ist es identisch."
    Write-Host ""

    Pause
}

Write-Host "Pruefe Zertifikate im Script-Ordner..." -ForegroundColor Cyan
$isAdmin = Test-IsAdministrator
if (-not $isAdmin) {
    Write-Host "Dieses Script benoetigt Administratorrechte. Bitte als Administrator starten." -ForegroundColor Red
    Pause
    return
}

$startupCertsOk = Get-HelperCertificates
if ($startupCertsOk) {
    Write-Host "Zertifikate sind vorhanden." -ForegroundColor Green
}
else {
    Write-Host "Zertifikate fehlen weiterhin. Punkt 4 kann Zertifikatskopie ggf. nicht vollstaendig ausfuehren." -ForegroundColor Yellow
}

do {
    Show-Menu
    $choice = Read-Host "Bitte Menüpunkt auswählen"

    switch ($choice) {
        "1" {
            Clear-Host
            Test-SecureBootUpdateStatus
        }
        "2" {
            Clear-Host
            Install-DBCertificate
        }
        "3" {
            Clear-Host
            Test-DBCertificate
        }
        "4" {
            Clear-Host
            Start-KEKBootmanagerUpdate
        }
        "6" {
            Clear-Host
            Show-PlatformKeyEnrollmentGuide
        }
        "0" {
            Write-Host "Script wird beendet."
        }
        default {
            Write-Host "Ungültige Auswahl." -ForegroundColor Red
            Pause
        }
    }
}
while ($choice -ne "0")