Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

param(
    [string]$Kubectl = "kubectl",
    [string]$KustomizePath = $PSScriptRoot
)

$resolvedKustomizePath = (Resolve-Path -Path $KustomizePath).Path

Write-Host "Applying Grafana dashboards from $resolvedKustomizePath"
& $Kubectl apply -k $resolvedKustomizePath
exit $LASTEXITCODE
