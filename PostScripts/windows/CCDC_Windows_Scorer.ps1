# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# CCDC Windows Target Scorer
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\
# Scores the current state of the Windows target across 4 categories:
#   1. Scored Services      (100) - blue team: keep these UP
#   2. Persistence Survival (100) - red team:  how much survived
#   3. Rogue Users          (100) - red team:  backdoor accounts alive
#   4. Rogue Web Content    (100) - red team:  rogue IIS site alive
# Total: /400
#
# Run: .\CCDC_Windows_Scorer.ps1  (requires Administrator)
# ///////////////////////////////\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\\

#Requires -RunAsAdministrator

# -- Score accumulators -------------------------------------------------------
$script:S1 = 0
$script:S2 = 0
$script:S3 = 0
$script:S4 = 0

# -- Output helpers -----------------------------------------------------------
function Write-Section { param([string]$t)
    Write-Host ""
    Write-Host "==[ $t ]==" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Subtotal { param([int]$s, [int]$m)
    Write-Host ""
    Write-Host ("  Subtotal: {0} / {1}" -f $s, $m) -ForegroundColor Yellow
}

function Check {
    param(
        [string]$Cat,
        [string]$Label,
        [bool]  $Pass,
        [int]   $Pts
    )
    if ($Pass) {
        Write-Host ("[PASS +{0,2}] {1}" -f $Pts, $Label) -ForegroundColor Green
        switch ($Cat) {
            'S1' { $script:S1 += $Pts }
            'S2' { $script:S2 += $Pts }
            'S3' { $script:S3 += $Pts }
            'S4' { $script:S4 += $Pts }
        }
    } else {
        Write-Host ("[FAIL  +{0,2}] {1}" -f 0, $Label) -ForegroundColor Red
    }
}

# -- Banner -------------------------------------------------------------------
Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  CCDC Blue Team Training - Windows Target Scorer" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""

# -- Module loading -----------------------------------------------------------
$IISAvailable = $false
try {
    Import-Module WebAdministration -ErrorAction Stop
    $IISAvailable = $true
    Write-Host "[+] WebAdministration module loaded." -ForegroundColor Green
} catch {
    Write-Host "[!] WebAdministration not available - IIS checks score 0." -ForegroundColor Yellow
}

$ADAvailable = $false
try {
    Import-Module ActiveDirectory -ErrorAction Stop
    $ADAvailable = $true
    Write-Host "[+] ActiveDirectory module loaded." -ForegroundColor Green
} catch {
    Write-Host "[!] ActiveDirectory not available - user checks use local group fallback." -ForegroundColor Yellow
}

# =============================================================================
# CATEGORY 1 - SCORED SERVICES (100 pts)
# These are the services blue team must keep running. Higher = blue team wins.
# =============================================================================
Write-Section "CATEGORY 1 - SCORED SERVICES (100 pts)"

# W3SVC (IIS HTTP) running - 15 pts
$svcW3 = Get-Service -Name 'W3SVC' -ErrorAction SilentlyContinue
Check 'S1' 'W3SVC (IIS HTTP) service running' ($null -ne $svcW3 -and $svcW3.Status -eq 'Running') 15

# HTTP GET http://localhost returns 200 - 15 pts
$httpOk = $false
try {
    $r = Invoke-WebRequest -Uri 'http://localhost' -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
    $httpOk = ($r.StatusCode -eq 200)
} catch {}
Check 'S1' 'HTTP GET http://localhost returns 200' $httpOk 15

# Default Web Site started - 10 pts
$defaultSiteUp = $false
if ($IISAvailable) {
    $dSite = Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue
    $defaultSiteUp = ($null -ne $dSite -and $dSite.State -eq 'Started')
}
Check 'S1' 'IIS "Default Web Site" state = Started' $defaultSiteUp 10

# DNS service running - 15 pts
$svcDns = Get-Service -Name 'DNS' -ErrorAction SilentlyContinue
Check 'S1' 'DNS service running' ($null -ne $svcDns -and $svcDns.Status -eq 'Running') 15

# ccdc.local zone exists - 10 pts
$zoneOk = $false
try {
    $z = Get-DnsServerZone -Name 'ccdc.local' -ErrorAction Stop
    $zoneOk = ($null -ne $z)
} catch {}
Check 'S1' 'DNS zone "ccdc.local" exists' $zoneOk 10

# MSFTPSVC (IIS FTP) running - 15 pts
$svcFtp = Get-Service -Name 'MSFTPSVC' -ErrorAction SilentlyContinue
Check 'S1' 'MSFTPSVC (IIS FTP) service running' ($null -ne $svcFtp -and $svcFtp.Status -eq 'Running') 15

# TCP port 21 accepts connections - 10 pts
$port21 = $false
try {
    $port21 = (Test-NetConnection -ComputerName 'localhost' -Port 21 `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
} catch {}
Check 'S1' 'TCP port 21 (FTP control) accepts connections' ([bool]$port21) 10

# CCDC-FTP site started - 10 pts
$ftpSiteUp = $false
if ($IISAvailable) {
    $fSite = Get-Website -Name 'CCDC-FTP' -ErrorAction SilentlyContinue
    $ftpSiteUp = ($null -ne $fSite -and $fSite.State -eq 'Started')
}
Check 'S1' 'IIS "CCDC-FTP" site state = Started' $ftpSiteUp 10

Write-Subtotal $script:S1 100

# =============================================================================
# CATEGORY 2 - PERSISTENCE SURVIVAL (100 pts)
# Planted persistence mechanisms. Higher = red team artifacts survived.
# =============================================================================
$DropDir = 'C:\ProgramData\Microsoft\Windows\DiagTrack\Telemetry\cache'

Write-Section "CATEGORY 2 - PERSISTENCE SURVIVAL (100 pts)"

# HKLM Run key WUDFComponentHost - 12 pts
$runKeyOk = $false
try {
    $rv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'WUDFComponentHost' -ErrorAction Stop
    $runKeyOk = ($null -ne $rv)
} catch {}
Check 'S2' 'HKLM Run key "WUDFComponentHost" present' $runKeyOk 12

# Winlogon Userinit tampered - 12 pts
$userinit = $false
try {
    $uv = (Get-ItemProperty `
        -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' `
        -Name 'Userinit' -ErrorAction Stop).Userinit
    $userinit = ($uv -match 'userinit-ext')
} catch {}
Check 'S2' 'Winlogon Userinit contains "userinit-ext"' $userinit 12

# Active Setup GUID key - 12 pts
$asPath = 'HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\{89820200-ECBD-11CF-8B85-00AA005B4383}'
Check 'S2' 'Active Setup GUID {89820200-ECBD-11CF-8B85-00AA005B4383} key present' (Test-Path $asPath) 12

# Scheduled task NotepadAlert at \ - 8 pts
$task1 = $false
try {
    $t = Get-ScheduledTask -TaskName 'NotepadAlert' -TaskPath '\' -ErrorAction Stop
    $task1 = ($null -ne $t)
} catch {}
Check 'S2' 'Scheduled task "NotepadAlert" (path \) exists' $task1 8

# Scheduled task AcrobatUpdateTask at \ - 8 pts
$task2 = $false
try {
    $t = Get-ScheduledTask -TaskName 'AcrobatUpdateTask' -TaskPath '\' -ErrorAction Stop
    $task2 = ($null -ne $t)
} catch {}
Check 'S2' 'Scheduled task "AcrobatUpdateTask" (path \) exists' $task2 8

# Hidden task DiagnosticsHub-StandardCollector - 10 pts
$task3 = $false
try {
    $t = Get-ScheduledTask -TaskName 'DiagnosticsHub-StandardCollector' `
        -TaskPath '\Microsoft\Windows\DiagnosticsHub\' -ErrorAction Stop
    $task3 = ($null -ne $t)
} catch {}
Check 'S2' 'Hidden task "DiagnosticsHub-StandardCollector" in \Microsoft\Windows\DiagnosticsHub\' $task3 10

# WmiPrvSE-Helper service present - 10 pts
$fakeSvc = Get-Service -Name 'WmiPrvSE-Helper' -ErrorAction SilentlyContinue
Check 'S2' 'Service "WmiPrvSE-Helper" present' ($null -ne $fakeSvc) 10

# Drop directory present - 3 pts
Check 'S2' 'Payload drop directory present' (Test-Path $DropDir) 3

# Payload files - 5 pts each
foreach ($f in @('wudf-host-svc.ps1', 'userinit-ext.ps1', 'diaghub-collector.ps1',
                  'wmiprvse-helper.ps1', 'iecompat-stub.ps1')) {
    Check 'S2' "Payload file `"$f`" present in drop dir" (Test-Path "$DropDir\$f") 5
}

Write-Subtotal $script:S2 100

# =============================================================================
# CATEGORY 3 - ROGUE USERS (100 pts)
# Backdoor AD accounts. Higher = red team accounts survived.
# Requires ActiveDirectory module; degrades to local group check without it.
# =============================================================================
Write-Section "CATEGORY 3 - ROGUE USERS (100 pts)"

$RogueUsers = @('JohnRedTeam', 'AdobeAcrobat', 'KayneWhitney')

if ($ADAvailable) {
    $daGroup    = Get-ADGroup 'Domain Admins'    -ErrorAction SilentlyContinue
    $admGroup   = Get-ADGroup 'Administrators'   -ErrorAction SilentlyContinue
    $eaGroup    = Get-ADGroup 'Enterprise Admins' -ErrorAction SilentlyContinue
    $anyInEA    = $false

    foreach ($u in $RogueUsers) {
        $adUser = Get-ADUser -Identity $u -Properties adminCount, MemberOf -ErrorAction SilentlyContinue

        # Account exists - 10 pts
        Check 'S3' "AD user `"$u`" exists" ($null -ne $adUser) 10

        if ($null -ne $adUser) {
            # Domain Admins membership - 10 pts
            $inDA = $daGroup -and ($adUser.MemberOf -contains $daGroup.DistinguishedName)
            Check 'S3' "`"$u`" member of Domain Admins" $inDA 10

            # Administrators membership - 10 pts
            $inAdm = $admGroup -and ($adUser.MemberOf -contains $admGroup.DistinguishedName)
            Check 'S3' "`"$u`" member of Administrators" $inAdm 10

            # adminCount = 1 - 3 pts
            Check 'S3' "`"$u`" adminCount = 1 (SDProp bypass)" ($adUser.adminCount -eq 1) 3

            # Track Enterprise Admins for bonus point
            if ($eaGroup -and ($adUser.MemberOf -contains $eaGroup.DistinguishedName)) {
                $anyInEA = $true
            }
        } else {
            Write-Host ("[FAIL  + 0] `"$u`" member of Domain Admins") -ForegroundColor Red
            Write-Host ("[FAIL  + 0] `"$u`" member of Administrators") -ForegroundColor Red
            Write-Host ("[FAIL  + 0] `"$u`" adminCount = 1 (SDProp bypass)") -ForegroundColor Red
        }
    }

    # Enterprise Admins bonus - 1 pt
    Check 'S3' 'Any rogue user in Enterprise Admins' $anyInEA 1

} else {
    # Degraded mode - local Administrators group only (~33 pts per user)
    Write-Host "  [DEGRADED] Checking local Administrators group only (AD module unavailable)" -ForegroundColor Yellow
    Write-Host ""
    $localAdmins = & net localgroup Administrators 2>$null | Out-String
    foreach ($u in $RogueUsers) {
        $found = ($localAdmins -match [regex]::Escape($u))
        Check 'S3' "`"$u`" in local Administrators (degraded)" $found 33
    }
}

Write-Subtotal $script:S3 100

# =============================================================================
# CATEGORY 4 - ROGUE WEB CONTENT (100 pts)
# Rogue IIS site on port 8080. Higher = red team web shell survived.
# =============================================================================
Write-Section "CATEGORY 4 - ROGUE WEB CONTENT (100 pts)"

# DefaultApp_Pool app pool exists - 20 pts
$poolExists = $false
if ($IISAvailable) {
    $poolExists = ($null -ne (Get-WebAppPool -Name 'DefaultApp_Pool' -ErrorAction SilentlyContinue))
}
Check 'S4' 'App pool "DefaultApp_Pool" exists' $poolExists 20

# Any IIS site bound to port 8080 - 20 pts
$port8080Site = $false
if ($IISAvailable) {
    $bindings = Get-WebBinding -ErrorAction SilentlyContinue |
        Where-Object { $_.bindingInformation -match ':8080:' }
    $port8080Site = ($null -ne $bindings -and @($bindings).Count -gt 0)
}
Check 'S4' 'IIS site bound to port 8080' $port8080Site 20

# Rogue web root directory - 15 pts
Check 'S4' 'Directory "C:\inetpub\Default Web Site" exists' `
    (Test-Path 'C:\inetpub\Default Web Site') 15

# Rogue index.asp - 15 pts
Check 'S4' 'Rogue "index.asp" in "C:\inetpub\Default Web Site\"' `
    (Test-Path 'C:\inetpub\Default Web Site\index.asp') 15

# Firewall rule for port 8080 - 15 pts
$fw8080 = $null -ne (Get-NetFirewallRule -DisplayName 'evilwebpage-training-port-8080' `
    -ErrorAction SilentlyContinue)
Check 'S4' 'Firewall rule "evilwebpage-training-port-8080" present' $fw8080 15

# TCP port 8080 accepts connections - 15 pts
$port8080Tcp = $false
try {
    $port8080Tcp = (Test-NetConnection -ComputerName 'localhost' -Port 8080 `
        -InformationLevel Quiet -WarningAction SilentlyContinue -ErrorAction SilentlyContinue)
} catch {}
Check 'S4' 'TCP port 8080 (rogue IIS) accepts connections' ([bool]$port8080Tcp) 15

Write-Subtotal $script:S4 100

# =============================================================================
# SUMMARY TABLE
# =============================================================================
$total = $script:S1 + $script:S2 + $script:S3 + $script:S4

function ScoreColor {
    param([int]$s)
    if ($s -ge 70) { 'Green' } elseif ($s -ge 40) { 'Yellow' } else { 'Red' }
}

Write-Host ""
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "  CCDC WINDOWS SCORE SUMMARY" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ("  Scored Services       [blue team]: {0,3} / 100" -f $script:S1) `
    -ForegroundColor (ScoreColor $script:S1)
Write-Host ("  Persistence Survival  [red  team]: {0,3} / 100" -f $script:S2) `
    -ForegroundColor (ScoreColor $script:S2)
Write-Host ("  Rogue Users           [red  team]: {0,3} / 100" -f $script:S3) `
    -ForegroundColor (ScoreColor $script:S3)
Write-Host ("  Rogue Web Content     [red  team]: {0,3} / 100" -f $script:S4) `
    -ForegroundColor (ScoreColor $script:S4)
Write-Host "--------------------------------------------------------" -ForegroundColor Cyan
Write-Host ("  TOTAL                              {0,3} / 400" -f $total) -ForegroundColor White
Write-Host "========================================================" -ForegroundColor Cyan
Write-Host ""
