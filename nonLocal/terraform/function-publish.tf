# The Function App is created without its code. With publish_function = true, terraform apply also publishes it: on the first
# apply, when the Function App is replaced, and whenever the function's source files change. Without it, run
# nonLocal/publish-function.ps1 yourself (until then new sites stay Queued).
#
# The script is a PowerShell zip deploy and takes the function's source from the ProvisionFunction repository, which has to
# sit next to this repository: <root>/Deployment and <root>/ProvisionFunction.

locals {
  function_dir = "${path.module}/../../../ProvisionFunction/Function"
}

resource "terraform_data" "publish_function" {
  count = var.publish_function ? 1 : 0

  triggers_replace = [
    azurerm_function_app_flex_consumption.provision.id,
    # A hash of the source (not bin/ or obj/, which change with every build).
    sha256(join("", [
      for f in sort(tolist(fileset(local.function_dir, "{Contracts,Features,Infrastructure}/**/*.cs"))) :
      filesha256("${local.function_dir}/${f}")
    ])),
    filesha256("${local.function_dir}/Program.cs"),
    filesha256("${local.function_dir}/Function.csproj"),
    filesha256("${local.function_dir}/host.json"),
  ]

  provisioner "local-exec" {
    interpreter = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    # Name and resource group are passed in: without them the script would ask `terraform output`, which waits for the
    # state lock that this apply holds.
    command = "& '${path.module}/../publish-function.ps1' -ResourceGroup '${azurerm_resource_group.rso.name}' -FunctionApp '${azurerm_function_app_flex_consumption.provision.name}'"
  }

  depends_on = [
    azurerm_role_assignment.function_queues,
    azurerm_role_assignment.function_tenants,
  ]
}
