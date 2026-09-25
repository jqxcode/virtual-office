[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet(
        'List',
        'Export',
        'BuildFromEmail',
        'CreateFromEmail',
        'Create',
        'Update',
        'Enable',
        'Disable',
        'Delete'
    )]
    [string]$Operation = 'List',

    [string]$RuleId,
    [string]$RuleFile,
    [string]$OutputPath,

    [string]$RuleName,
    [string]$SenderAddress,
    [string]$SenderName,
    [string[]]$SubjectContains,

    [ValidateSet('Delete', 'MarkHigh', 'MarkRead', 'MoveToFolder')]
    [string]$RuleAction,
    [string]$DestinationFolder,

    [switch]$EnableRule,
    [switch]$StopProcessingRules,
    [switch]$ForceReconnect
)

$ErrorActionPreference = 'Stop'
$RulesPath = '/me/mailFolders/inbox/messageRules'

function ConvertTo-Hashtable {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $Value.Keys) {
            $result[$key] = ConvertTo-Hashtable $Value[$key]
        }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @($Value | ForEach-Object { ConvertTo-Hashtable $_ })
    }
    if ($Value -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Hashtable $property.Value
        }
        return $result
    }
    return $Value
}

function Ensure-GraphConnection {
    param([switch]$Write)

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    $requiredScopes = if ($Write) {
        @('MailboxSettings.ReadWrite', 'Mail.ReadBasic')
    }
    else {
        @('MailboxSettings.Read')
    }

    $context = Get-MgContext
    $missingScope = -not $context -or @(
        $requiredScopes | Where-Object { $_ -notin $context.Scopes }
    ).Count -gt 0

    if ($ForceReconnect -or $missingScope) {
        Connect-MgGraph -Scopes $requiredScopes -NoWelcome
        $context = Get-MgContext
    }

    if (-not $context) {
        throw 'Microsoft Graph authentication was not established.'
    }
    return $context
}

function Invoke-RulesRequest {
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]$Method,
        [string]$Uri,
        $Body
    )

    $parameters = @{
        Method     = $Method
        Uri        = $Uri
        OutputType = 'PSObject'
    }
    if ($null -ne $Body) {
        $parameters.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
        $parameters.ContentType = 'application/json'
    }
    Invoke-MgGraphRequest @parameters
}

function Get-InboxRules {
    $response = Invoke-RulesRequest -Method GET -Uri $RulesPath
    @($response.value)
}

function Resolve-MailFolderId {
    param([Parameter(Mandatory)][string]$Folder)

    if ($Folder -match '^AAMk') {
        return $Folder
    }
    $escaped = [uri]::EscapeDataString($Folder)
    $response = Invoke-MgGraphRequest `
        -Method GET `
        -Uri "/me/mailFolders/$escaped?`$select=id,displayName" `
        -OutputType PSObject
    if (-not $response.id) {
        throw "Unable to resolve mail folder '$Folder'."
    }
    $response.id
}

function New-RuleFromEmailSpec {
    if ([string]::IsNullOrWhiteSpace($RuleName)) {
        throw '-RuleName is required.'
    }
    if ([string]::IsNullOrWhiteSpace($SenderAddress) -and
        (-not $SubjectContains -or $SubjectContains.Count -eq 0)) {
        throw 'Provide -SenderAddress and/or -SubjectContains.'
    }
    if ([string]::IsNullOrWhiteSpace($RuleAction)) {
        throw '-RuleAction is required.'
    }

    $conditions = @{}
    if (-not [string]::IsNullOrWhiteSpace($SenderAddress)) {
        $conditions.fromAddresses = @(
            @{
                emailAddress = @{
                    address = $SenderAddress
                    name    = if ($SenderName) { $SenderName } else { $SenderAddress }
                }
            }
        )
    }
    if ($SubjectContains) {
        $conditions.subjectContains = @($SubjectContains)
    }

    $actions = @{
        stopProcessingRules = [bool]$StopProcessingRules
    }
    switch ($RuleAction) {
        'Delete' {
            $actions.delete = $true
        }
        'MarkHigh' {
            $actions.markImportance = 'high'
        }
        'MarkRead' {
            $actions.markAsRead = $true
        }
        'MoveToFolder' {
            if ([string]::IsNullOrWhiteSpace($DestinationFolder)) {
                throw '-DestinationFolder is required for MoveToFolder.'
            }
            $actions.moveToFolder = $DestinationFolder
        }
    }

    @{
        displayName = $RuleName
        sequence    = 999
        isEnabled   = [bool]$EnableRule
        conditions  = $conditions
        actions     = $actions
    }
}

function Read-RuleFile {
    if ([string]::IsNullOrWhiteSpace($RuleFile)) {
        throw '-RuleFile is required.'
    }
    if (-not (Test-Path -LiteralPath $RuleFile)) {
        throw "Rule file does not exist: $RuleFile"
    }
    ConvertTo-Hashtable (Get-Content -LiteralPath $RuleFile -Raw | ConvertFrom-Json)
}

function Verify-RuleReadback {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Expected
    )

    $actual = Invoke-RulesRequest -Method GET -Uri "$RulesPath/$Id"
    $checks = [ordered]@{
        id          = $actual.id
        displayName = $actual.displayName
        isEnabled   = $actual.isEnabled
        isReadOnly  = $actual.isReadOnly
        hasError    = $actual.hasError
        sequence    = $actual.sequence
        conditions  = $actual.conditions
        exceptions  = $actual.exceptions
        actions     = $actual.actions
    }
    if ($Expected.displayName -and $actual.displayName -ne $Expected.displayName) {
        throw "Rule readback mismatch: expected displayName '$($Expected.displayName)', got '$($actual.displayName)'."
    }
    if ($Expected.ContainsKey('isEnabled') -and
        [bool]$actual.isEnabled -ne [bool]$Expected.isEnabled) {
        throw 'Rule readback mismatch: isEnabled differs.'
    }
    [pscustomobject]$checks
}

function Test-IsRuleNotFoundError {
    param([Parameter(Mandatory)]$ErrorRecord)

    $statusCode = $null
    if ($ErrorRecord.Exception.Response -and
        $ErrorRecord.Exception.Response.StatusCode) {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    $message = [string]$ErrorRecord.Exception.Message
    return $statusCode -eq 404 -or
        $message -match '(?i)\b404\b|ErrorItemNotFound|not found'
}

if ($Operation -eq 'BuildFromEmail') {
    New-RuleFromEmailSpec | ConvertTo-Json -Depth 20
    exit 0
}

$writeOperation = $Operation -in @(
    'CreateFromEmail', 'Create', 'Update', 'Enable', 'Disable', 'Delete'
)
$context = if ($writeOperation -and $WhatIfPreference) {
    $null
}
else {
    Ensure-GraphConnection -Write:$writeOperation
}

switch ($Operation) {
    'List' {
        Get-InboxRules |
            Select-Object id, displayName, sequence, isEnabled, isReadOnly, hasError,
                conditions, exceptions, actions
    }
    'Export' {
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            throw '-OutputPath is required for Export.'
        }
        $rules = Get-InboxRules
        $rules | ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $OutputPath -Encoding utf8
        Get-Item -LiteralPath $OutputPath
    }
    'CreateFromEmail' {
        $rule = New-RuleFromEmailSpec
        if ($PSCmdlet.ShouldProcess($RuleName, 'Create disabled Inbox rule')) {
            if ($rule.actions.moveToFolder) {
                $rule.actions.moveToFolder = Resolve-MailFolderId $rule.actions.moveToFolder
            }
            $created = Invoke-RulesRequest -Method POST -Uri $RulesPath -Body $rule
            Verify-RuleReadback -Id $created.id -Expected $rule
        }
    }
    'Create' {
        $rule = Read-RuleFile
        if (-not $rule.ContainsKey('isEnabled')) {
            $rule.isEnabled = $false
        }
        if ($PSCmdlet.ShouldProcess($rule.displayName, 'Create Inbox rule')) {
            $created = Invoke-RulesRequest -Method POST -Uri $RulesPath -Body $rule
            Verify-RuleReadback -Id $created.id -Expected $rule
        }
    }
    'Update' {
        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw '-RuleId is required for Update.'
        }
        $rule = Read-RuleFile
        if ($PSCmdlet.ShouldProcess($RuleId, 'Update Inbox rule')) {
            Invoke-RulesRequest -Method PATCH -Uri "$RulesPath/$RuleId" -Body $rule |
                Out-Null
            Verify-RuleReadback -Id $RuleId -Expected $rule
        }
    }
    'Enable' {
        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw '-RuleId is required for Enable.'
        }
        $body = @{ isEnabled = $true }
        if ($PSCmdlet.ShouldProcess($RuleId, 'Enable Inbox rule')) {
            Invoke-RulesRequest -Method PATCH -Uri "$RulesPath/$RuleId" -Body $body |
                Out-Null
            Verify-RuleReadback -Id $RuleId -Expected $body
        }
    }
    'Disable' {
        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw '-RuleId is required for Disable.'
        }
        $body = @{ isEnabled = $false }
        if ($PSCmdlet.ShouldProcess($RuleId, 'Disable Inbox rule')) {
            Invoke-RulesRequest -Method PATCH -Uri "$RulesPath/$RuleId" -Body $body |
                Out-Null
            Verify-RuleReadback -Id $RuleId -Expected $body
        }
    }
    'Delete' {
        if ([string]::IsNullOrWhiteSpace($RuleId)) {
            throw '-RuleId is required for Delete.'
        }
        if ($PSCmdlet.ShouldProcess($RuleId, 'Delete Inbox rule')) {
            Invoke-RulesRequest -Method DELETE -Uri "$RulesPath/$RuleId" | Out-Null
            try {
                Invoke-RulesRequest -Method GET -Uri "$RulesPath/$RuleId" | Out-Null
                throw 'Rule still exists after DELETE.'
            }
            catch {
                if ($_.Exception.Message -eq 'Rule still exists after DELETE.') {
                    throw
                }
                if (-not (Test-IsRuleNotFoundError $_)) {
                    throw
                }
            }
            [pscustomobject]@{ id = $RuleId; deleted = $true }
        }
    }
}
