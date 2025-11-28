#Requires -Modules ActiveDirectory

<#
.SYNOPSIS
    Active Directory user account management script for disabling and deleting inactive accounts.

.DESCRIPTION
    This script disables user accounts inactive for a specified period and deletes accounts
    inactive beyond a deletion threshold. It operates on user accounts within a specified OU
    structure while excluding designated service account paths.

.PARAMETER DryRun
    This is a string value to handle a bug in AWS SSM!  Set to "True" to report only without making changes, "False" to execute changes. Default: "True"

.PARAMETER DisableDays
    Number of days of inactivity before disabling an account. Default: 180

.PARAMETER DeleteDays
    Number of days of inactivity before deleting an account. Default: 360

.PARAMETER UserOU
    The parent OU containing user accounts (without domain DN). Default: "OU=Users,OU=NOMS RBAC"

.PARAMETER ServiceAccountsOUPaths
    Array of OU paths to exclude (relative to UserOU). Default: @("OU=Service")

.PARAMETER LogBasePath
    Base path for log files. Default: "C:\ScriptLogs\ADUserManagement"

.EXAMPLE
    .\AD-UserManagement.ps1 -DryRun $true -DisableDays 60 -DeleteDays 180

.EXAMPLE
    .\AD-UserManagement.ps1 -DryRun $false -UserOU "OU=Users,OU=NOMS RBAC" -ServiceAccountsOUPaths @("OU=Service","OU=Admins")

.NOTES
    Author: Dave Kent
    Version: 2.0
    Requires: ActiveDirectory PowerShell module
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$DryRun = "True",
    
    [Parameter(Mandatory=$false)]
    [int]$DisableDays = 180,
    
    [Parameter(Mandatory=$false)]
    [int]$DeleteDays = 360,
    
    [Parameter(Mandatory=$false)]
    [string]$UserOU = "OU=Users,OU=NOMS RBAC",
    
    [Parameter(Mandatory=$false)]
    [string[]]$ServiceAccountsOUPaths = @("OU=Service"),
    
    [Parameter(Mandatory=$false)]
    [string]$LogBasePath = "C:\ScriptLogs\ADUserManagement"
)

# ============================================================================
# SCRIPT INITIALIZATION
# ============================================================================

$DryRunBool = [System.Convert]::ToBoolean($DryRun)

# Get domain DN and build full paths
$domainDN = (Get-ADDomain).DistinguishedName
$userOUFull = "$UserOU,$domainDN"

# Build full excluded paths
$excludedPaths = @()
foreach ($path in $ServiceAccountsOUPaths) {
    $excludedPaths += "$path,$userOUFull"
}

# Create log directory if it doesn't exist
if (-not (Test-Path -Path $LogBasePath)) {
    New-Item -Path $LogBasePath -ItemType Directory -Force | Out-Null
}

# Define log file paths
$dateStamp = Get-Date -Format "yyyy-MM-dd_HHmmss"
$disableLogPath = Join-Path -Path $LogBasePath -ChildPath "Disable_$dateStamp.log"
$deleteLogPath = Join-Path -Path $LogBasePath -ChildPath "Delete_$dateStamp.log"

# Calculate threshold dates
$disableThreshold = (Get-Date).AddDays(-$DisableDays)
$deleteThreshold = (Get-Date).AddDays(-$DeleteDays)

# Initialize counters
$disabledCount = 0
$deletedCount = 0
$errorCount = 0

# ============================================================================
# FUNCTIONS
# ============================================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp - $Message"
    Add-Content -Path $LogPath -Value $logEntry
    Write-Host $logEntry
}

function Test-ExcludedOU {
    param(
        [string]$UserDN
    )
    
    foreach ($excludedPath in $excludedPaths) {
        # Check if the user's DN contains the excluded path
        # This will match the OU and all nested sub-OUs
        if ($UserDN -like "*,$excludedPath") {
            # Write-Host "  [EXCLUDED] Matched: $UserDN" -ForegroundColor DarkGray
            return $true
        }
    }
    return $false
}

# ============================================================================
# MAIN SCRIPT EXECUTION
# ============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "AD User Account Management Script" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Execution Mode: $(if ($DryRunBool) { 'DRY-RUN (No changes will be made)' } else { 'LIVE (Changes will be applied)' })" -ForegroundColor $(if ($DryRunBool) { 'Yellow' } else { 'Red' })
Write-Host "Disable Threshold: $DisableDays days (Last logon before $($disableThreshold.ToString('yyyy-MM-dd')))" -ForegroundColor White
Write-Host "Delete Threshold: $DeleteDays days (Last logon before $($deleteThreshold.ToString('yyyy-MM-dd')))" -ForegroundColor White
Write-Host "User OU: $userOUFull" -ForegroundColor White
Write-Host "Excluded OU Paths:" -ForegroundColor White
foreach ($path in $excludedPaths) {
    Write-Host "  - $path" -ForegroundColor White
}
Write-Host "========================================`n" -ForegroundColor Cyan

# Initialize logs
Write-Log -Message "=== AD User Management Script Started ===" -LogPath $disableLogPath
Write-Log -Message "Mode: $(if ($DryRunBool) { 'DRY-RUN' } else { 'LIVE' })" -LogPath $disableLogPath
Write-Log -Message "Disable Threshold: $DisableDays days" -LogPath $disableLogPath
Write-Log -Message "Delete Threshold: $DeleteDays days" -LogPath $disableLogPath

Write-Log -Message "=== AD User Management Script Started ===" -LogPath $deleteLogPath
Write-Log -Message "Mode: $(if ($DryRunBool) { 'DRY-RUN' } else { 'LIVE' })" -LogPath $deleteLogPath
Write-Log -Message "Disable Threshold: $DisableDays days" -LogPath $deleteLogPath
Write-Log -Message "Delete Threshold: $DeleteDays days" -LogPath $deleteLogPath

try {
    # Verify OU exists
    $null = Get-ADOrganizationalUnit -Identity $userOUFull -ErrorAction Stop
    
    # Get all user accounts from the specified OU and sub-OUs
    Write-Host "Retrieving user accounts from $userOUFull..." -ForegroundColor Cyan
    $allUsers = Get-ADUser -Filter * -SearchBase $userOUFull -SearchScope Subtree -Properties LastLogonDate, DistinguishedName, Enabled
    
    $totalUsers = $allUsers.Count
    Write-Host "Found $totalUsers user account(s) in OU structure.`n" -ForegroundColor Green
    
    # Filter out excluded OUs
    $users = $allUsers | Where-Object { -not (Test-ExcludedOU -UserDN $_.DistinguishedName) }
    $excludedCount = $totalUsers - $users.Count
    
    if ($excludedCount -gt 0) {
        Write-Host "Excluded $excludedCount account(s) in service account OUs.`n" -ForegroundColor Yellow
    }
    
    # ========================================
    # PROCESS ACCOUNTS FOR DELETION
    # ========================================
    Write-Host "Processing accounts for deletion (inactive > $DeleteDays days)..." -ForegroundColor Cyan
    
    $usersToDelete = $users | Where-Object {
        $_.LastLogonDate -and $_.LastLogonDate -lt $deleteThreshold
    }
    
    foreach ($user in $usersToDelete) {
        $lastLogon = if ($user.LastLogonDate) { $user.LastLogonDate.ToString('yyyy-MM-dd HH:mm:ss') } else { "Never" }
        $logMessage = "Username: $($user.SamAccountName) | LastLogon: $lastLogon | OU: $($user.DistinguishedName)"
        
        try {
            if ($DryRunBool) {
                Write-Log -Message "[DRY-RUN] Would DELETE: $logMessage" -LogPath $deleteLogPath
            } else {
                Remove-ADUser -Identity $user -Confirm:$false -ErrorAction Stop
                Write-Log -Message "[DELETED] $logMessage" -LogPath $deleteLogPath
            }
            $deletedCount++
        }
        catch {
            Write-Log -Message "[ERROR] Failed to delete $($user.SamAccountName): $($_.Exception.Message)" -LogPath $deleteLogPath
            $errorCount++
        }
    }
    
    # ========================================
    # PROCESS ACCOUNTS FOR DISABLING
    # ========================================
    Write-Host "`nProcessing accounts for disabling (inactive > $DisableDays days)..." -ForegroundColor Cyan
    
    # Only process accounts that haven't been deleted and are currently enabled
    $usersToDisable = $users | Where-Object {
        $_.Enabled -eq $true -and
        $_.LastLogonDate -and
        $_.LastLogonDate -lt $disableThreshold -and
        $_.LastLogonDate -ge $deleteThreshold
    }
    
    foreach ($user in $usersToDisable) {
        $lastLogon = if ($user.LastLogonDate) { $user.LastLogonDate.ToString('yyyy-MM-dd HH:mm:ss') } else { "Never" }
        $logMessage = "Username: $($user.SamAccountName) | LastLogon: $lastLogon | OU: $($user.DistinguishedName)"
        
        try {
            if ($DryRunBool) {
                Write-Log -Message "[DRY-RUN] Would DISABLE: $logMessage" -LogPath $disableLogPath
            } else {
                Disable-ADAccount -Identity $user -ErrorAction Stop
                Write-Log -Message "[DISABLED] $logMessage" -LogPath $disableLogPath
            }
            $disabledCount++
        }
        catch {
            Write-Log -Message "[ERROR] Failed to disable $($user.SamAccountName): $($_.Exception.Message)" -LogPath $disableLogPath
            $errorCount++
        }
    }
    
}
catch {
    $errorMessage = "Critical error: $($_.Exception.Message)"
    Write-Host $errorMessage -ForegroundColor Red
    Write-Log -Message $errorMessage -LogPath $disableLogPath
    Write-Log -Message $errorMessage -LogPath $deleteLogPath
    exit 1
}

# ============================================================================
# SUMMARY REPORT
# ============================================================================

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "EXECUTION SUMMARY" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Mode: $(if ($DryRunBool) { 'DRY-RUN' } else { 'LIVE' })" -ForegroundColor $(if ($DryRunBool) { 'Yellow' } else { 'Red' })
Write-Host "Total Accounts Scanned: $totalUsers" -ForegroundColor White
Write-Host "Excluded Accounts: $excludedCount" -ForegroundColor White
if ($excludedPaths.Count -gt 0) {
    Write-Host "Excluded Paths:" -ForegroundColor Yellow
    foreach ($path in $excludedPaths) {
        Write-Host "  - $path" -ForegroundColor Yellow
    }
}
Write-Host "Accounts $(if ($DryRunBool) { 'to be ' } else { '' })Disabled: $disabledCount" -ForegroundColor $(if ($disabledCount -gt 0) { 'Yellow' } else { 'Green' })
Write-Host "Accounts $(if ($DryRunBool) { 'to be ' } else { '' })Deleted: $deletedCount" -ForegroundColor $(if ($deletedCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "Errors Encountered: $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { 'Red' } else { 'Green' })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nLog Files:" -ForegroundColor Cyan
Write-Host "  Disable Log: $disableLogPath" -ForegroundColor White
Write-Host "  Delete Log: $deleteLogPath" -ForegroundColor White
Write-Host "========================================`n" -ForegroundColor Cyan

# Write summary to logs
$summaryMessage = @"
=== EXECUTION SUMMARY ===
Mode: $(if ($DryRunBool) { 'DRY-RUN' } else { 'LIVE' })
Total Accounts Scanned: $totalUsers
Excluded Accounts: $excludedCount
Accounts $(if ($DryRunBool) { 'to be ' } else { '' })Disabled: $disabledCount
Accounts $(if ($DryRunBool) { 'to be ' } else { '' })Deleted: $deletedCount
Errors Encountered: $errorCount
"@

Write-Log -Message $summaryMessage -LogPath $disableLogPath
Write-Log -Message $summaryMessage -LogPath $deleteLogPath

if ($DryRunBool) {
    Write-Host "NOTE: This was a dry-run. No changes were made to AD accounts." -ForegroundColor Yellow
    Write-Host "Set -DryRun `$false to execute changes.`n" -ForegroundColor Yellow
}

# Return exit code based on errors
if ($errorCount -gt 0) {
    exit 1
} else {
    exit 0
}