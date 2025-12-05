variable "app_metadata" {
  description = <<EOF
Nullstone automatically injects metadata from the app module into this module through this variable.
This variable is a reserved variable for capabilities.
EOF

  type    = map(string)
  default = {}
}

locals {
  service_account_email = var.app_metadata["service_account_email"]
  job_name              = var.app_metadata["job_name"]
}
