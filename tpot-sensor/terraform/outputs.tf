output "sensors" {
  description = "Public IP and tunnel address per sensor; feed the IP into the hive's wg0.conf Endpoint."
  value = {
    for name, s in var.sensors : name => {
      public_ip  = azurerm_public_ip.sensor[name].ip_address
      wg_address = s.wg_address
      location   = s.location
      size       = s.size
    }
  }
}
