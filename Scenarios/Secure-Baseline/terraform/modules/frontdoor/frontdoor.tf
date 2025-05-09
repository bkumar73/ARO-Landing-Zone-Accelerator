
data "azurerm_client_config" "current" {}

data "azurerm_resources" "aro-internal-lb" {
  resource_group_name = var.aro_resource_group_name
  type = "Microsoft.Network/loadBalancers"
}

data "azurerm_lb" "aro_ilb" {
  name = data.azurerm_resources.aro-internal-lb.resources[0].name
  resource_group_name = data.azurerm_resources.aro-internal-lb.resources[0].resource_group_name
}

resource "azurerm_private_link_service" "pl" {
  name = var.afd_pls_name
  resource_group_name = var.spoke_rg_name
  location = var.location

  nat_ip_configuration {
    name = "primary"
    private_ip_address_version = "IPv4"
    subnet_id = var.aro_worker_subnet_id
    primary = true
  }
  load_balancer_frontend_ip_configuration_ids = [data.azurerm_lb.aro_ilb.frontend_ip_configuration[1].id]
  visibility_subscription_ids                 = [data.azurerm_client_config.current.subscription_id]
}

resource "azurerm_cdn_frontdoor_profile" "fd" {
  name = var.afd_name
  resource_group_name = var.spoke_rg_name
  sku_name = var.afd_sku
}

resource "azurerm_cdn_frontdoor_endpoint" "fd" {
  name = "aro-ilb${var.random}"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id
}

resource "azurerm_cdn_frontdoor_origin_group" "aro" {
  name                     = "aro-origin-group"
  cdn_frontdoor_profile_id = azurerm_cdn_frontdoor_profile.fd.id

  health_probe {
    interval_in_seconds = 100
    path                = "/"
    protocol            = "Http"
    request_type        = "GET"
  }

  load_balancing {}
}

resource "azurerm_cdn_frontdoor_origin" "aro" {
  name                          = "aro-origin"
  cdn_frontdoor_origin_group_id = azurerm_cdn_frontdoor_origin_group.aro.id
  enabled                       = true

  certificate_name_check_enabled = true
  host_name                      = data.azurerm_lb.aro_ilb.frontend_ip_configuration[1].private_ip_address
  priority                       = 1
  weight                         = 500

  private_link {
    request_message        = "Request access for Private Link Origin CDN Frontdoor"
    location               = var.location
    private_link_target_id = azurerm_private_link_service.pl.id
  }

  depends_on = [ azurerm_cdn_frontdoor_origin_group.aro ]
}


resource "azurerm_monitor_diagnostic_setting" "afd_diag" {
  name = "afdtoLogAnalytics"
  target_resource_id = azurerm_cdn_frontdoor_profile.fd.id
  log_analytics_workspace_id = var.la_id

  enabled_log {
    category = "FrontDoorAccessLog"
  }

  enabled_log {
    category = "FrontDoorHealthProbeLog"
  }

   enabled_log {
    category = "FrontDoorWebApplicationFirewallLog"
  }

  metric {
    category = "AllMetrics"
  }

  depends_on = [ azurerm_cdn_frontdoor_endpoint.fd,
                azurerm_cdn_frontdoor_origin_group.aro, 
                azurerm_cdn_frontdoor_origin.aro 
                ]  
}

