locals {
  hostname = "quote-api.example.com"
}

# Proxied (orange-cloud) record: traffic goes through Cloudflare's CDN/WAF.
resource "cloudflare_dns_record" "quote_api" {
  zone_id = var.zone_id
  name    = local.hostname
  type    = "CNAME"
  content = var.origin_hostname
  proxied = true
  ttl     = 1 # 1 = automatic; required for proxied records
  comment = "Managed by Terraform (iac/cloudflare)"
}

# Cache rules live in the zone's http_request_cache_settings phase.
# There is exactly one entry-point ruleset per zone and phase, so all cache rules
# for the zone belong in this resource. Rules are evaluated in order; later
# matches override earlier ones.
resource "cloudflare_ruleset" "cache_rules" {
  zone_id     = var.zone_id
  name        = "Cache rules"
  description = "Cache rules for ${local.hostname}"
  kind        = "zone"
  phase       = "http_request_cache_settings"

  rules = [
    {
      description = "API responses are dynamic: never cache"
      expression  = "(http.host eq \"${local.hostname}\" and starts_with(http.request.uri.path, \"/api/\"))"
      action      = "set_cache_settings"
      action_parameters = {
        cache = false
      }
      enabled = true
    },
    {
      description = "Static assets: cache aggressively (fingerprinted file names)"
      expression  = "(http.host eq \"${local.hostname}\" and http.request.uri.path.extension in {\"css\" \"js\" \"mjs\" \"png\" \"jpg\" \"jpeg\" \"gif\" \"svg\" \"webp\" \"avif\" \"ico\" \"woff\" \"woff2\"})"
      action      = "set_cache_settings"
      action_parameters = {
        cache = true
        edge_ttl = {
          mode    = "override_origin"
          default = 2592000 # 30 days at the edge
        }
        browser_ttl = {
          mode    = "override_origin"
          default = 86400 # 1 day in browsers, so a bad asset can still be fixed
        }
      }
      enabled = true
    },
  ]
}

# Adopting a record that someone created by hand in the dashboard.
# `terraform plan` shows "1 to import" with no changes when the block below
# matches reality; after the import is applied the import block can be deleted.
import {
  to = cloudflare_dns_record.www
  id = "${var.zone_id}/${var.legacy_record_id}"
}

resource "cloudflare_dns_record" "www" {
  zone_id = var.zone_id
  name    = "www.example.com"
  type    = "CNAME"
  content = "example.com"
  proxied = true
  ttl     = 1
}
