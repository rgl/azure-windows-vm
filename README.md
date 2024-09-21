an example azure ubuntu virtual machine

![](architecture.png)

# Usage (on a Ubuntu Desktop)

Install the tools:

```bash
./provision-tools.sh
```

Login into azure-cli:

```bash
az login
```

List the subscriptions:

```bash
az account list --all
az account show
```

Set the subscription:

```bash
export ARM_SUBSCRIPTION_ID="<YOUR-SUBSCRIPTION-ID>"
az account set --subscription "$ARM_SUBSCRIPTION_ID"
```

Review `main.tf` and maybe change the `location` variable.

Initialize terraform:

```bash
make terraform-init
```

Launch the example:

```bash
make terraform-apply
```

At VM initialization time a Custom Script Extension will run the `provision.ps1` script to customize the VM and launch the example web application.

Get the initialization script status:

```bash
az vm get-instance-view \
    --resource-group rgl-windows-vm-example \
    --name app \
    --query instanceView.extensions
```

After VM initialization is done (the log is stored at `c:\AzureData\provision-log.txt`), test the `app` endpoint:

```bash
wget -qO- "http://$(terraform output --raw app_ip_address)/test"
```

You can also list all resources:

```bash
az resource list \
    --resource-group rgl-windows-vm-example \
    --output table
```

You can execute commands:

```bash
# NB unfortunately, run-command is somewhat limited. for example, it only
#    outputs last 4k of the command output.
#    see https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command#restrictions
az vm run-command invoke \
    --resource-group rgl-windows-vm-example \
    --name app \
    --command-id RunPowerShellScript \
    --scripts 'whoami /all' \
    > output.json \
    && jq -r '.value[].message' output.json \
    && rm output.json
az vm run-command invoke \
    --resource-group rgl-windows-vm-example \
    --name app \
    --command-id RunPowerShellScript \
    --scripts 'param([string]$name)' 'Write-Host "Hello $name!"' \
    --parameters 'name=Rui' \
    > output.json \
    && jq -r '.value[].message' output.json \
    && rm output.json
```

Destroy the example:

```bash
make terraform-destroy
```

# Reference

* [Azure virtual machine extensions and features](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/overview)
* [Azure Virtual Machine Agent overview](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/agent-windows)
* [Custom Script Extension for Windows](https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/custom-script-windows)
