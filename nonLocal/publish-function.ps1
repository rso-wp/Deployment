# Builds ProvisionFunction and deploys it to the Function App created by nonLocal/terraform (zip deploy, no Core Tools needed).
#
#   powershell -ExecutionPolicy Bypass -File nonLocal/publish-function.ps1
#   powershell -ExecutionPolicy Bypass -File nonLocal/publish-function.ps1 -PackageOnly   # only build the zip
#
# The Function App name comes from `terraform output function_app_name` unless -FunctionApp is given.
param(
    [string]$ResourceGroup = 'rso-rg',
    [string]$FunctionApp = '',
    [switch]$PackageOnly
)

$ErrorActionPreference = 'Stop'
# The service repositories sit next to this one: <root>/Deployment, <root>/ProvisionFunction, ...
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$project = Join-Path $root 'ProvisionFunction/Function'
$out = Join-Path ([IO.Path]::GetTempPath()) "provision-function-$([guid]::NewGuid().ToString('N'))"
$zip = "$out.zip"

Write-Host "=== dotnet publish" -ForegroundColor Cyan
dotnet publish $project -c Release -o $out
if ($LASTEXITCODE -ne 0) { throw 'dotnet publish failed' }

# Compress-Archive (Windows PowerShell 5.1) writes no entry for the .azurefunctions folder itself, and Azure rejects such
# a package ("Cannot find required .azurefunctions directory"). So write the zip with an explicit entry per folder.
Write-Host "=== zip" -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$base = (Get-Item $out).FullName.TrimEnd('\') + '\'
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
    Get-ChildItem $out -Recurse -Force | ForEach-Object {
        $name = $_.FullName.Substring($base.Length).Replace('\', '/')
        if ($_.PSIsContainer) { [void]$archive.CreateEntry("$name/") }
        else { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $name) }
    }
}
finally {
    $archive.Dispose()
}
Remove-Item -Recurse -Force $out

if ($PackageOnly) {
    Write-Host "Package: $zip" -ForegroundColor Green
    return
}

if (-not $FunctionApp) {
    $FunctionApp = terraform "-chdir=$PSScriptRoot/terraform" output -raw function_app_name
    if ($LASTEXITCODE -ne 0 -or -not $FunctionApp) { throw 'No Function App name: run terraform apply first, or pass -FunctionApp.' }
}

Write-Host "=== deploy to $FunctionApp" -ForegroundColor Cyan
az functionapp deployment source config-zip -g $ResourceGroup -n $FunctionApp --src $zip
if ($LASTEXITCODE -ne 0) { throw 'zip deploy failed' }
Remove-Item -Force $zip

Write-Host "=== functions now deployed" -ForegroundColor Cyan
az functionapp function list -g $ResourceGroup -n $FunctionApp --query "[].name" -o tsv
