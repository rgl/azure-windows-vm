# NB you can test the relative speed from you browser to a location using https://azurespeedtest.azurewebsites.net/
# get the available locations with: az account list-locations --output table
variable "location" {
  default = "France Central" # see https://azure.microsoft.com/en-us/global-infrastructure/france/
}

# NB this name must be unique within the Azure subscription.
#    all the other names must be unique within this resource group.
variable "resource_group_name" {
  default = "rgl-windows-vm-example"
}

variable "admin_username" {
  default = "rgl"
}

variable "admin_password" {
  default = "HeyH0Password"
}

output "app_ip_address" {
  value = "${azurerm_public_ip.app.ip_address}"
}

provider "azurerm" {}

resource "azurerm_resource_group" "example" {
  name     = "${var.resource_group_name}" # NB this name must be unique within the Azure subscription.
  location = "${var.location}"
}

# NB this generates a single random number for the resource group.
resource "random_id" "example" {
  keepers = {
    resource_group = "${azurerm_resource_group.example.name}"
  }

  byte_length = 10
}

resource "azurerm_storage_account" "diagnostics" {
  # NB this name must be globally unique as all the azure storage accounts share the same namespace.
  # NB this name must be at most 24 characters long.
  name = "diag${random_id.example.hex}"

  resource_group_name      = "${azurerm_resource_group.example.name}"
  location                 = "${azurerm_resource_group.example.location}"
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_virtual_network" "example" {
  name                = "example"
  address_space       = ["10.1.0.0/16"]
  location            = "${azurerm_resource_group.example.location}"
  resource_group_name = "${azurerm_resource_group.example.name}"
}

resource "azurerm_subnet" "backend" {
  name                 = "backend"
  resource_group_name  = "${azurerm_resource_group.example.name}"
  virtual_network_name = "${azurerm_virtual_network.example.name}"
  address_prefix       = "10.1.1.0/24"
}

resource "azurerm_public_ip" "app" {
  name                         = "app"
  resource_group_name          = "${azurerm_resource_group.example.name}"
  location                     = "${azurerm_resource_group.example.location}"
  public_ip_address_allocation = "Static"
  sku                          = "Basic"
}

resource "azurerm_network_security_group" "app" {
  name                = "app"
  resource_group_name = "${azurerm_resource_group.example.name}"
  location            = "${azurerm_resource_group.example.location}"

  # NB By default, a security group, will have the following Inbound rules:
  #     | Priority | Name                           | Port  | Protocol  | Source            | Destination     | Action  |
  #     |----------|--------------------------------|-------|-----------|-------------------|-----------------|---------|
  #     | 65000    | AllowVnetInBound               | Any   | Any       | VirtualNetwork    | VirtualNetwork  | Allow   |
  #     | 65001    | AllowAzureLoadBalancerInBound  | Any   | Any       | AzureLoadBalancer | Any             | Allow   |
  #     | 65500    | DenyAllInBound                 | Any   | Any       | Any               | Any             | Deny    |
  # NB By default, a security group, will have the following Outbound rules:
  #     | Priority | Name                           | Port  | Protocol  | Source            | Destination     | Action  |
  #     |----------|--------------------------------|-------|-----------|-------------------|-----------------|---------|
  #     | 65000    | AllowVnetOutBound              | Any   | Any       | VirtualNetwork    | VirtualNetwork  | Allow   |
  #     | 65001    | AllowInternetOutBound          | Any   | Any       | Any               | Internet        | Allow   |
  #     | 65500    | DenyAllOutBound                | Any   | Any       | Any               | Any             | Deny    |

  security_rule {
    name                       = "app"
    priority                   = 1000
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "rdp"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "app" {
  name                      = "app"
  resource_group_name       = "${azurerm_resource_group.example.name}"
  location                  = "${azurerm_resource_group.example.location}"
  network_security_group_id = "${azurerm_network_security_group.app.id}"

  ip_configuration {
    name                          = "app"
    primary                       = true
    public_ip_address_id          = "${azurerm_public_ip.app.id}"
    subnet_id                     = "${azurerm_subnet.backend.id}"
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.1.1.4"                     # NB Azure reserves the first four addresses in each subnet address range, so do not use those.
  }
}

resource "azurerm_virtual_machine_extension" "app" {
  name                 = "app"
  location             = "${azurerm_resource_group.example.location}"
  resource_group_name  = "${azurerm_resource_group.example.name}"
  virtual_machine_name = "${azurerm_virtual_machine.app.name}"
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.9"

  settings = <<SETTINGS
    {
      "commandToExecute": "PowerShell -ExecutionPolicy Bypass -NonInteractive -Command \"gc -Raw C:\\AzureData\\CustomData.bin | iex\""
    }
SETTINGS
}

resource "azurerm_virtual_machine" "app" {
  name                  = "app"
  resource_group_name   = "${azurerm_resource_group.example.name}"
  location              = "${azurerm_resource_group.example.location}"
  network_interface_ids = ["${azurerm_network_interface.app.id}"]
  vm_size               = "Standard_DS1_v2"

  delete_os_disk_on_termination    = true
  delete_data_disks_on_termination = true

  storage_os_disk {
    name          = "app_os"
    caching       = "ReadWrite" # TODO is this advisable?
    create_option = "FromImage"

    # resize the storage_image_reference disk size to this value.
    # NB this is optional.
    # NB MUST be higher than the used storage_image_reference disk size.
    # NB Azure maps the provisioned size (rounded up) to the nearest disk size offer.
    #    at the time of writing, the minimum disk size is 128GB (the E10 offer).
    #    see https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disks-standard-ssd
    # NB You MUST resize the file system yourself (as-in provision.ps1).
    #disk_size_gb = "40"

    managed_disk_type = "StandardSSD_LRS" # Locally Redundant Storage.
  }

  # see https://docs.microsoft.com/en-us/azure/virtual-machines/windows/cli-ps-findimage
  # e.g. az vm image list --all --publisher MicrosoftWindowsServer --offer WindowsServer --output table
  storage_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2019-Datacenter-smalldisk" # NB two disk sizes versions are available: 2019-Datacenter (127GB) and 2019-Datacenter-smalldisk (30GB).
    version   = "latest"
  }

  # add data disk.
  # NB normally, the first data disk will be assigned the F drive letter (C is the os, D is the ephemeral disk, and E is the cd-rom).
  # NB this disk will not be initialized by azure.
  #    it will be initialized by our script (see os_profile.custom_data).
  # NB Azure maps the provisioned size (rounded up) to the nearest disk size offer.
  #    at the time of writing, the minimum disk size is 128GB (the E10 offer).
  #    see https://docs.microsoft.com/en-us/azure/virtual-machines/windows/disks-standard-ssd
  # NB You MUST initialize the disk and file system yourself (as-in provision.ps1).
  storage_data_disk {
    name              = "app_data1"
    caching           = "ReadWrite"       # TODO is this advisable?
    create_option     = "Empty"
    disk_size_gb      = "10"
    lun               = 0
    managed_disk_type = "StandardSSD_LRS"
  }

  os_profile {
    computer_name  = "app"
    admin_username = "${var.admin_username}"                  # NB the built-in Administrator account will be renamed to this one.
    admin_password = "${var.admin_password}"
    custom_data    = "${base64encode(file("provision.ps1"))}"
  }

  os_profile_windows_config {
    provision_vm_agent        = true
    enable_automatic_upgrades = false
    timezone                  = "GMT Standard Time"
  }

  boot_diagnostics {
    enabled     = true
    storage_uri = "${azurerm_storage_account.diagnostics.primary_blob_endpoint}"
  }
}
