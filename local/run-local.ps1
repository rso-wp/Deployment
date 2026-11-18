# Starts the infrastructure in docker and every service with `dotnet run`, one window each.
# Stop a service by closing its window; stop the infrastructure with:
#   docker compose -f local/docker-compose.yml down
$ErrorActionPreference = 'Stop'
# The service repositories sit next to this one: <root>/Deployment, <root>/UserService, ...
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

docker compose -f "$PSScriptRoot/docker-compose.yml" up -d --wait
if ($LASTEXITCODE -ne 0) { throw 'docker compose failed' }

$projects = @(
    'UserService/Api',
    'PaymentService/PaymentService',
    'ProvisioningService/Api'
)

foreach ($project in $projects) {
    $path = Join-Path $root $project
    Start-Process powershell -ArgumentList '-NoExit', '-Command', "`$Host.UI.RawUI.WindowTitle = '$project'; dotnet run --project '$path'"
}

# ProvisionFunction is an Azure Function: it runs in the Functions host (Azure Functions Core Tools), not with dotnet run.
$function = Join-Path $root 'ProvisionFunction/Function'
if (Get-Command func -ErrorAction SilentlyContinue) {
    Start-Process powershell -WorkingDirectory $function -ArgumentList '-NoExit', '-Command', "`$Host.UI.RawUI.WindowTitle = 'ProvisionFunction'; func start"
} else {
    Write-Warning 'Azure Functions Core Tools (func) not found: start ProvisionFunction from Visual Studio, or install them (npm i -g azure-functions-core-tools@4).'
}

Write-Host 'Started. UserService :5076, PaymentService :5263/:5264, ProvisioningService :5151 (sign up at http://localhost:4200 or with POST /auth/signup).'
