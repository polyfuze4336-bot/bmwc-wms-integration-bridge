<#
  scripts/post-provision.ps1
  azd hook: runs after 'azd provision' to wire up APIM Named Values
  with the actual Logic App trigger callback URL.

  What this script does:
  1. Reads azd environment outputs (APIM name, Logic App name, RG)
  2. Retrieves the Logic App HTTP trigger callback URL (contains SAS signature)
  3. Updates the APIM Named Value 'la-bmwc-ingest-url' with the real URL

  Usage: called automatically by azd via hooks.postprovision in azure.yaml
         Can also be run manually: .\scripts\post-provision.ps1
#>

param(
    [string]$EnvironmentName = $env:AZURE_ENV_NAME,
    [string]$SubscriptionId  = $env:AZURE_SUBSCRIPTION_ID,
    [string]$ResourceGroup   = $env:RESOURCE_GROUP_NAME,
    [string]$LogicAppName    = $env:LOGIC_APP_NAME,
    [string]$ApimName        = $env:APIM_NAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host "`n[post-provision] Updating APIM Named Value with Logic App trigger URL..."

# ── Ensure logged in ───────────────────────────────────────────────────────
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in to Azure CLI. Run: az login"
    exit 1
}

# ── Get Logic App trigger callback URL ────────────────────────────────────
Write-Host "[post-provision] Fetching callback URL for workflow 'bmwc-rest-ingress'..."

$callbackResponse = az rest `
    --method POST `
    --url "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$LogicAppName/hostruntime/runtime/webhooks/workflow/api/management/workflows/bmwc-rest-ingress/triggers/HTTP_Ingest/listCallbackUrl?api-version=2022-03-01" `
    2>$null | ConvertFrom-Json

if (-not $callbackResponse -or -not $callbackResponse.value) {
    Write-Warning "[post-provision] Could not retrieve callback URL — Logic App may still be initialising."
    Write-Warning "  Re-run this script after the Logic App has fully started."
    exit 0
}

$triggerUrl  = $callbackResponse.value

# Keep the FULL URL including query string (sp/sv/sig SAS token).
# The SAS token is required for APIM to invoke the Logic App HTTP trigger.
# Stripping the query string would cause 401 Unauthorized from the trigger.
Write-Host "[post-provision] Trigger URL (with SAS): $triggerUrl"

# ── Update APIM Named Value ────────────────────────────────────────────────
Write-Host "[post-provision] Updating APIM Named Value 'la-bmwc-ingest-url'..."

az apim nv update `
    --resource-group $ResourceGroup `
    --service-name $ApimName `
    --named-value-id "la-bmwc-ingest-url" `
    --value $triggerUrl `
    --output none

Write-Host "[post-provision] Done. APIM is now routing POST /bmwc/orders → Logic App."
Write-Host "[post-provision] Gateway URL: $env:APIM_GATEWAY_URL/bmwc/orders"
