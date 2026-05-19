data "ns_workspace" "this" {}

// Generate a random suffix to ensure uniqueness of resources
resource "random_string" "resource_suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = false
  special = false
}

locals {
  labels          = { for k, v in data.ns_workspace.this.tags : lower(k) => v }
  block_name      = data.ns_workspace.this.block_name
  resource_suffix = random_string.resource_suffix.result
  resource_name   = "${data.ns_workspace.this.block_ref}-${local.resource_suffix}"
}
