<#
    Script: Vmware-ManageSecureBoot.ps1
    Author: Michael Schwenke
    Company: team-netz Consulting GmbH
    License: Apache License 2.0

    Zweck:
    Interaktives VMware PowerCLI Hilfsscript fuer Secure-Boot/UEFI-Auswertungen,
    EFI-Enrollment-Vorbereitung und automatisches Ruecksetzen temporaerer VM-Settings.

    Version History:
    - 1.0.0: Basismenue fuer VMware Host/VM Uebersicht und lokale Abfragen
    - 1.1.0: Farbige VM-Statusanzeige (Gruen/Rot) mit SecureBoot-Bewertung
    - 1.2.0: EFI-Enrollment-Vorbereitung mit Rollback fuer uefi.allowAuthBypass und Force EFI Setup
#>

# VMware / SecureBoot Menü
# Benötigt: VMware PowerCLI

$vCenter = "vcenter.firma.de"
$Global:SecureBootClients = @()

function Connect-vCenter {
    if (-not (Get-VIServer -Server $vCenter -ErrorAction SilentlyContinue)) {
        Connect-VIServer -Server $vCenter
    }
}

function Show-VMwareInfo {
    Connect-vCenter

    Write-Host "`nVMHost Versionen:" -ForegroundColor Cyan
    Get-VMHost |
        Select-Object Name, Version, Build |
        Format-Table -AutoSize

    Write-Host "`nVM Firmware / Secure Boot / Hardware Version:" -ForegroundColor Cyan

    $vms = Get-View -ViewType VirtualMachine -Property Name,Config.Firmware,Config.BootOptions,Config.Version |
        Select-Object Name,
            @{N='HwVersion';E={$_.Config.Version}},
            @{N='Firmware';E={$_.Config.Firmware}},
            @{N='SecureBoot';E={$_.Config.BootOptions.EfiSecureBootEnabled}} |
        Sort-Object Firmware, Name

    Write-Host "`nVM Status (Gruen = OK, Rot = Handlungsbedarf):" -ForegroundColor Cyan
    foreach ($vm in $vms) {
        $secureBootValue = if ($null -eq $vm.SecureBoot) { 'n/a' } else { $vm.SecureBoot }
        $isOk = $vm.Firmware -eq 'efi' -and $vm.SecureBoot -eq $true
        $status = if ($isOk) { 'OK' } else { 'Handlungsbedarf' }

        $line = "{0,-35} HW:{1,-10} Firmware:{2,-8} SecureBoot:{3,-5} Status:{4}" -f `
            $vm.Name, $vm.HwVersion, $vm.Firmware, $secureBootValue, $status

        Write-Host $line -ForegroundColor ($(if ($isOk) { 'Green' } else { 'Red' }))
    }

    # Clients merken, die UEFI + SecureBoot TRUE haben
    $Global:SecureBootClients = $vms | Where-Object {
        $_.Firmware -eq "efi" -and $_.SecureBoot -eq $true
    }

    Write-Host "`nGemerkte Clients mit UEFI + SecureBoot TRUE:" -ForegroundColor Green
    $Global:SecureBootClients | Select-Object Name, HwVersion, Firmware, SecureBoot | Format-Table -AutoSize
}

function Show-LocalSecureBootInfo {
    Write-Host "`n--- $env:COMPUTERNAME ---" -ForegroundColor Cyan

    Write-Host "`nSecureBoot UEFI:" -ForegroundColor Yellow
    Confirm-SecureBootUEFI

    Write-Host "`nScheduled Task Secure-Boot-Update:" -ForegroundColor Yellow
    Get-ScheduledTask -TaskPath '\Microsoft\Windows\PI\' -TaskName 'Secure-Boot-Update' |
        Select-Object State

    Write-Host "`nWindows UEFI CA 2023 in DB:" -ForegroundColor Yellow
    [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI db).bytes) -match 'Windows UEFI CA 2023'

    Write-Host "`nKEK enthält 2023:" -ForegroundColor Yellow
    [Text.Encoding]::ASCII.GetString((Get-SecureBootUEFI kek).bytes) -match '2023'

    Write-Host "`nSecureBoot Servicing Registry:" -ForegroundColor Yellow
    Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\Servicing' `
        -Name UEFICA2023Status,UEFICA2023Error -ErrorAction SilentlyContinue |
        Select-Object UEFICA2023Status, UEFICA2023Error
}

function Invoke-EFIEnrollPreparation {
    Connect-vCenter

    $vmName = Read-Host "`nVM-Name fuer EFI-Enrollment Vorbereitung"
    if ([string]::IsNullOrWhiteSpace($vmName)) {
        Write-Host "Kein VM-Name angegeben." -ForegroundColor Red
        return
    }

    $vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Host "VM '$vmName' nicht gefunden." -ForegroundColor Red
        return
    }

    $vmView = $vm | Get-View -Property Config.ExtraConfig,Config.BootOptions,Name

    $authSetting = Get-AdvancedSetting -Entity $vm -Name 'uefi.allowAuthBypass' -ErrorAction SilentlyContinue
    $oldAuthValue = if ($authSetting) { $authSetting.Value } else { $null }
    $oldEnterBios = $vmView.Config.BootOptions.EnterBIOSSetup

    Write-Host "`nVorbereitung fuer VM: $($vm.Name)" -ForegroundColor Cyan
    Write-Host "Aktueller PowerState: $($vm.PowerState)"

    if ($vm.PowerState -ne 'PoweredOff') {
        Write-Host "VM wird heruntergefahren..." -ForegroundColor Yellow
        Stop-VM -VM $vm -Confirm:$false | Out-Null
        $vm | Wait-Tools -TimeoutSeconds 1 -ErrorAction SilentlyContinue | Out-Null
        do {
            Start-Sleep -Seconds 2
            $vm = Get-VM -Name $vm.Name
        } while ($vm.PowerState -ne 'PoweredOff')
    }

    if ($authSetting) {
        Set-AdvancedSetting -AdvancedSetting $authSetting -Value 'TRUE' -Confirm:$false | Out-Null
    }
    else {
        New-AdvancedSetting -Entity $vm -Name 'uefi.allowAuthBypass' -Value 'TRUE' -Force -Confirm:$false | Out-Null
    }

    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $spec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
    $spec.BootOptions.EnterBIOSSetup = $true
    $vm.ExtensionData.ReconfigVM_Task($spec) | Out-Null

    Write-Host "uefi.allowAuthBypass=TRUE gesetzt und Force EFI Setup aktiviert." -ForegroundColor Green

    Start-VM -VM $vm -Confirm:$false | Out-Null
    Write-Host "VM gestartet. Bitte jetzt die Webkonsole oeffnen und Enrollment durchfuehren." -ForegroundColor Cyan

    Write-Host "`nEFI vorbereiten und enrollen:" -ForegroundColor Yellow
    Write-Host "1. VMX-Parameter uefi.allowAuthBypass = TRUE setzen (Edit Settings -> Advanced Parameters)."
    Write-Host "2. Force EFI Setup aktivieren (VM Options -> Boot Options)."
    Write-Host "3. VM einschalten und die Webkonsole oeffnen."
    Write-Host ""
    Write-Host "Im EFI-Menue dann:" -ForegroundColor Yellow
    Write-Host "1. Secure Boot Configuration -> PK Options -> Enroll PK -> Volume KEYUPDATE -> WindowsOEMDevicesPK.der -> Commit/Yes"
    Write-Host "2. Esc -> KEK Options -> Enroll KEK -> KEK-2023.der -> Commit/Yes"
    Write-Host "3. Esc -> Boot normally"
    Write-Host "VMware committet sofort, ein globales Speichern ist nicht noetig."
    Write-Host "Achte auf eine Bestaetigung pro Enroll und darauf, dass kein roter Fehler erscheint." -ForegroundColor Yellow

    Read-Host "`nWeiter mit Enter, sobald du fertig bist (danach werden Einstellungen rueckgaengig gemacht)"

    $vm = Get-VM -Name $vm.Name
    if ($vm.PowerState -ne 'PoweredOff') {
        Write-Host "VM wird fuer Rollback heruntergefahren..." -ForegroundColor Yellow
        Stop-VM -VM $vm -Confirm:$false | Out-Null
        do {
            Start-Sleep -Seconds 2
            $vm = Get-VM -Name $vm.Name
        } while ($vm.PowerState -ne 'PoweredOff')
    }

    $vm = Get-VM -Name $vm.Name

    if ($null -ne $oldAuthValue) {
        $authSettingRestore = Get-AdvancedSetting -Entity $vm -Name 'uefi.allowAuthBypass' -ErrorAction SilentlyContinue
        if ($authSettingRestore) {
            Set-AdvancedSetting -AdvancedSetting $authSettingRestore -Value $oldAuthValue -Confirm:$false | Out-Null
        }
    }
    else {
        $authSettingRestore = Get-AdvancedSetting -Entity $vm -Name 'uefi.allowAuthBypass' -ErrorAction SilentlyContinue
        if ($authSettingRestore) {
            Remove-AdvancedSetting -AdvancedSetting $authSettingRestore -Confirm:$false | Out-Null
        }
    }

    $restoreSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    $restoreSpec.BootOptions = New-Object VMware.Vim.VirtualMachineBootOptions
    $restoreSpec.BootOptions.EnterBIOSSetup = [bool]$oldEnterBios
    $vm.ExtensionData.ReconfigVM_Task($restoreSpec) | Out-Null

    Start-VM -VM $vm -Confirm:$false | Out-Null
    Write-Host "Rollback abgeschlossen: uefi.allowAuthBypass und Force EFI Setup wurden zurueckgesetzt." -ForegroundColor Green
}

do {
    Clear-Host
    Write-Host "===== VMware / SecureBoot Menü =====" -ForegroundColor Cyan
    Write-Host "1. VMware Host + VM Firmware / SecureBoot abfragen"
    Write-Host "2. Lokale SecureBoot / UEFI CA 2023 Abfrage"
    Write-Host "3. Gemerkte UEFI + SecureBoot TRUE Clients anzeigen"
    Write-Host "4. EFI vorbereiten + Enrollment + Rollback (per VM-Name)"
    Write-Host "0. Beenden"

    $choice = Read-Host "`nAuswahl"

    switch ($choice) {
        "1" {
            Show-VMwareInfo
            Pause
        }
        "2" {
            Show-LocalSecureBootInfo
            Pause
        }
        "3" {
            Write-Host "`nGemerkte Clients:" -ForegroundColor Green
            $Global:SecureBootClients | Format-Table -AutoSize
            Pause
        }
        "4" {
            Invoke-EFIEnrollPreparation
            Pause
        }
        "0" {
            Write-Host "Beendet."
        }
        default {
            Write-Host "Ungültige Auswahl." -ForegroundColor Red
            Pause
        }
    }
} while ($choice -ne "0")

Disconnect-VIServer -Server $vCenter -Confirm:$false -ErrorAction SilentlyContinue