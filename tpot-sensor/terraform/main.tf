terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id
  features {}
}

# One source of truth for the user-data: the same template used for non-Azure hosts.
locals {
  cloud_init = {
    for name, s in var.sensors : name => replace(replace(replace(replace(replace(
      file("${path.module}/../cloud-init.yaml"),
      "PLACEHOLDER_SSH_PUBKEY", var.ssh_public_key),
      "PLACEHOLDER_SENSOR_WG_PRIVKEY", var.sensor_secrets[name].wg_private_key),
      "PLACEHOLDER_HIVE_WG_PUBKEY", var.hive_wg_public_key),
      "PLACEHOLDER_WG_ADDRESS", s.wg_address),
    "PLACEHOLDER_WEB_PASSWORD", var.sensor_secrets[name].web_password)
  }
}

resource "azurerm_resource_group" "sensor" {
  for_each = var.sensors
  name     = "rg-tpot-sensor-${each.key}"
  location = each.value.location
}

resource "azurerm_virtual_network" "sensor" {
  for_each            = var.sensors
  name                = "vnet-tpot-sensor-${each.key}"
  address_space       = ["10.0.0.0/24"]
  location            = each.value.location
  resource_group_name = azurerm_resource_group.sensor[each.key].name
}

resource "azurerm_subnet" "sensor" {
  for_each             = var.sensors
  name                 = "snet-tpot-sensor"
  resource_group_name  = azurerm_resource_group.sensor[each.key].name
  virtual_network_name = azurerm_virtual_network.sensor[each.key].name
  address_prefixes     = ["10.0.0.0/28"]
}

# Standard SKU is static-only and billable (~$3.65/mo); Basic was retired 2025-09-30.
resource "azurerm_public_ip" "sensor" {
  for_each            = var.sensors
  name                = "pip-tpot-sensor-${each.key}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.sensor[each.key].name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_network_security_group" "sensor" {
  for_each            = var.sensors
  name                = "nsg-tpot-sensor-${each.key}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.sensor[each.key].name

  # Management stays private; 64295 (SSH) is key-only and left reachable for bootstrap.
  security_rule {
    name                       = "deny-mgmt-from-internet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["64294", "64297"]
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }

  # Everything else open on purpose: this is the bait.
  security_rule {
    name                       = "allow-honeypot-all"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "sensor" {
  for_each            = var.sensors
  name                = "nic-tpot-sensor-${each.key}"
  location            = each.value.location
  resource_group_name = azurerm_resource_group.sensor[each.key].name

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.sensor[each.key].id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.sensor[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "sensor" {
  for_each                  = var.sensors
  network_interface_id      = azurerm_network_interface.sensor[each.key].id
  network_security_group_id = azurerm_network_security_group.sensor[each.key].id
}

resource "azurerm_linux_virtual_machine" "sensor" {
  for_each              = var.sensors
  name                  = "tpot-sensor-${each.key}"
  location              = each.value.location
  resource_group_name   = azurerm_resource_group.sensor[each.key].name
  size                  = each.value.size
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.sensor[each.key].id]
  custom_data           = base64encode(local.cloud_init[each.key])

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = each.value.disk_gb
  }

  source_image_reference {
    publisher = "Debian"
    offer     = "debian-13"
    sku       = "13-gen2"
    version   = "latest"
  }
}
