# PowerCLI script to locate, power off, and rename a VM
param(
    [Parameter(Mandatory=$true)][string]$VMName,
    [Parameter(Mandatory=$true)][string]$User,
    [Parameter(Mandatory=$true)][string]$Password,

    # List of vCenters to search
    [string[]]$vCenters = @('dfwvc01.levi.com','dfwvcpg01.levi.com','dfwvcno01.levi.com','dfwvcnoe01.levi.com','dfwvcneom01.levi.com','dalvc20.levi.com','dalvcpg20.levi.com','dalvcpo20.levi.com','dalvcpoe20.levi.com','dalvcpeom20.levi.com'),

    # Log path (using PSScriptRoot ensures it writes to the same folder as the script)
    [string]$LogPath = (Join-Path $PSScriptRoot "PowerOffRename_$(Get-Date -Format 'yyyyMMdd').log")
)

# Helper function for logging
function Write-Log {
    param([string]$Message, [string]$Level="INFO", [ConsoleColor]$Color="White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    # Write to Console
    Write-Host $logEntry -ForegroundColor $Color

    # Write to File (Cross-platform compatible)
    try {
        Add-Content -Path $LogPath -Value $logEntry -Encoding UTF8
    } catch {
        Write-Warning "Could not write to log file: $_"
    }
}

# 1. Configure PowerCLI (Corrected: Removed invalid -Force parameter)
try {
    # We use -Confirm:$false to suppress prompts.
    # We use -ErrorAction SilentlyContinue so it doesn't crash if already set.
    Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Set-PowerCLIConfiguration -ParticipateInCEIP $false -Scope Session -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
} catch {
    # If this fails, we log it but proceed.
    Write-Warning "Configuration warning: $_"
}

Write-Log "Starting process for VM: $VMName" "INFO" "Cyan"

# 2. Create Credential Object from parameters
try {
    $SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($User, $SecurePassword)
} catch {
    Write-Log "Failed to create credential object. Check password format." "ERROR" "Red"
    exit 1
}

# 3. Connect to vCenters
$ConnectedVCenters = @()
foreach ($VCenter in $vCenters) {
    try {
        # Connect using the passed credential
        $connection = Connect-VIServer -Server $VCenter -Credential $cred -ErrorAction Stop
        $ConnectedVCenters += $connection
    } catch {
        # Optional: Comment out the next line to reduce noise if connection failures are expected
        # Write-Log "Failed to connect to $VCenter" "WARNING" "Yellow"
    }
}

if ($ConnectedVCenters.Count -eq 0) {
    Write-Log "No vCenters connected. Check credentials or network." "ERROR" "Red"
    exit 1
}

# 4. Search for the VM
$VM = $null
$VCenterFound = $null

foreach ($conn in $ConnectedVCenters) {
    $VM = Get-VM -Name $VMName -Server $conn -ErrorAction SilentlyContinue
    if ($VM) {
        $VCenterFound = $conn
        Write-Log "Found VM '$VMName' on $($conn.Name)" "INFO" "Green"
        break
    }
}

if (-not $VM) {
    Write-Log "VM '$VMName' not found on any connected vCenter." "ERROR" "Red"
    #Disconnect-VIServer * -Confirm:$false
    Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
    exit 1
}

# 5. Power Off Logic
if ($VM.PowerState -eq "PoweredOn") {
    Write-Log "VM is Powered ON. Attempting shutdown..." "INFO" "Yellow"
    try {
        # Try graceful guest shutdown first
        Stop-VMGuest -VM $VM -Confirm:$false -ErrorAction SilentlyContinue

        # Wait loop (up to 60 seconds)
        $timer = 0
        while ($timer -lt 60) {
            if ((Get-VM -Id $VM.Id -Server $VCenterFound).PowerState -eq "PoweredOff") { break }
            Start-Sleep -Seconds 5
            $timer += 5
        }

        # Force stop if still running
        if ((Get-VM -Id $VM.Id -Server $VCenterFound).PowerState -eq "PoweredOn") {
             Write-Log "Graceful shutdown timed out. Forcing Power Off." "WARNING" "Yellow"
             Stop-VM -VM $VM -Confirm:$false -ErrorAction Stop
        } else {
             Write-Log "Graceful shutdown successful." "INFO" "Green"
        }
    } catch {
        Write-Log "Failed to power off: $_" "ERROR" "Red"
        # Disconnect-VIServer * -Confirm:$false
        Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }
} else {
    Write-Log "VM is already Powered OFF." "INFO" "Green"
}

# 6. Rename Logic
$NewName = "_DoNotPowerOn-$VMName"

# Check if already renamed
if ($VM.Name -eq $NewName) {
    Write-Log "VM is already renamed." "INFO" "Green"
} else {
    try {
        Set-VM -VM $VM -Name $NewName -Confirm:$false -ErrorAction Stop
        Write-Log "Successfully renamed to '$NewName'" "INFO" "Green"
    } catch {
        Write-Log "Rename failed: $_" "ERROR" "Red"
        # Disconnect-VIServer * -Confirm:$false
        Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue
        exit 1
    }
}

# 7. Cleanup
# Disconnect-VIServer * -Confirm:$false
Disconnect-VIServer * -Confirm:$false -ErrorAction SilentlyContinue