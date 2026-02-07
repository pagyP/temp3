terraform {
  //required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "xxxxxxx"
}

#####################
# Variables
#####################
variable "prefix" {
  type    = string
  default = "labfd"
}

variable "location" {
  type    = string
  default = "uksouth"
}

variable "vnet_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

variable "appgw_subnet_cidr" {
  type    = string
  default = "10.10.1.0/24"
}

variable "pe_subnet_cidr" {
  type    = string
  default = "10.10.2.0/24"
}

variable "appgw_private_ip" {
  type    = string
  default = "10.10.1.10"
}

variable "appgw_private_link_ip" {
  type    = string
  default = "10.10.2.10"
}

# Backend for App Gateway (lab placeholder)
variable "appgw_backend_ip" {
  type    = string
  default = "10.10.2.4"
}

#####################
# Resource Group
#####################
resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg1"
  location = var.location
}

#####################
# Network
#####################
resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "appgw" {
  name                 = "${var.prefix}-appgw-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.appgw_subnet_cidr]
}

resource "azurerm_subnet" "private_endpoints" {
  name                 = "${var.prefix}-pe-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = [var.pe_subnet_cidr]

  private_link_service_network_policies_enabled = false
}

resource "azurerm_public_ip" "appgw_pip" {
  name                = "${var.prefix}-appgw-pip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

#####################
# Application Gateway (private frontend, HTTP)
#####################
resource "azurerm_application_gateway" "appgw" {
  name                = "${var.prefix}-appgw"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  sku {
    name     = "Standard_v2"
    tier     = "Standard_v2"
    capacity = 1
  }

  gateway_ip_configuration {
    name      = "appgw-ipcfg"
    subnet_id = azurerm_subnet.appgw.id
  }

  frontend_port {
    name = "http-80"
    port = 80
  }

  frontend_ip_configuration {
    name                          = "private-frontend"
    subnet_id                     = azurerm_subnet.appgw.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.appgw_private_ip
    private_link_configuration_name = "appgw-private-link"
  }

  frontend_ip_configuration {
    name                 = "public-frontend"
    public_ip_address_id = azurerm_public_ip.appgw_pip.id
  }

  private_link_configuration {
    name = "appgw-private-link"

    ip_configuration {
      name                          = "private-frontend"
      subnet_id                     = azurerm_subnet.private_endpoints.id
      private_ip_address_allocation = "Dynamic"
      primary = true
    }
  }

  backend_address_pool {
    name = "backend-pool"
    ip_addresses = [var.appgw_backend_ip]
  }

  backend_http_settings {
    name                  = "http-settings"
    port                  = 80
    protocol              = "Http"
    request_timeout       = 30
    cookie_based_affinity = "Disabled"
  }

  http_listener {
    name                           = "http-listener"
    frontend_ip_configuration_name = "private-frontend"
    frontend_port_name             = "http-80"
    protocol                       = "Http"
  }

  request_routing_rule {
    name                       = "http-rule"
    rule_type                  = "Basic"
    http_listener_name         = "http-listener"
    backend_address_pool_name  = "backend-pool"
    backend_http_settings_name = "http-settings"
    priority                   = 100
  }
}

#####################
# Front Door Premium + Private Link origin
#####################
resource "azurerm_cdn_frontdoor_profile" "fd_profile" {
  name                = "${var.prefix}-fd"
  resource_group_name = azurerm_resource_group.rg.name
  sku_name            = "Premium_AzureFrontDoor"
  depends_on = [ azurerm_application_gateway.appgw ]
}

resource "azurerm_cdn_frontdoor_endpoint" "fd_endpoint" {
  name                       = "${var.prefix}-fd-endpoint"
  cdn_frontdoor_profile_id   = azurerm_cdn_frontdoor_profile.fd_profile.id
}

resource "azurerm_cdn_frontdoor_origin_group" "fd_origin_group" {
  name                     = "${var.prefix}-fd-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd_profile.id

  load_balancing {
    sample_size                        = 4
    successful_samples_required        = 3
    additional_latency_in_milliseconds = 0
  }

  health_probe {
    interval_in_seconds = 30
    protocol            = "Http"
    path                = "/"
    request_type        = "GET"
  }
}

resource "azurerm_cdn_frontdoor_origin" "fd_origin" {
  name                          = "${var.prefix}-appgw-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.fd_origin_group.id
  

  # Host header for lab (HTTP). Use a DNS name you control if needed.
  host_name          = "10.10.1.10"
  origin_host_header = "10.10.1.10"

  http_port  = 80
  https_port = 443

  enabled                        = true
  certificate_name_check_enabled = true

  private_link {
    //private_link_target_id = "${azurerm_application_gateway.appgw.id}/privateLinkConfigurations/appgw-private-link"
     private_link_target_id = "/subscriptions/xxxxxxx/resourceGroups/labfd-rg1/providers/Microsoft.Network/privateLinkServices/_e41f87a2_labfd-appgw_appgw-private-link"
    location               = azurerm_resource_group.rg.location
    request_message        = "Please approve Front Door Private Link to App Gateway."
  }
  //depends_on = [ azurerm_application_gateway.appgw ]
}


resource "azurerm_cdn_frontdoor_route" "fd_route" {
  name                            = "${var.prefix}-fd-route"
  cdn_frontdoor_endpoint_id       = azurerm_cdn_frontdoor_endpoint.fd_endpoint.id
  cdn_frontdoor_origin_group_id   = azurerm_cdn_frontdoor_origin_group.fd_origin_group.id
  cdn_frontdoor_origin_ids        = [azurerm_cdn_frontdoor_origin.fd_origin.id]
  supported_protocols             = ["Http"]
  patterns_to_match               = ["/*"]
  forwarding_protocol             = "HttpOnly"
  link_to_default_domain          = true
  https_redirect_enabled = false
}


resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  
}

resource "azurerm_monitor_diagnostic_setting" "appgwdiagnostic" {
  name               = "${var.prefix}-appgw-diagnostic"
  target_resource_id = azurerm_application_gateway.appgw.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {category = "ApplicationGatewayAccessLog"}

  enabled_log {category = "ApplicationGatewayPerformanceLog"}

  enabled_log {category = "ApplicationGatewayFirewallLog"}
}