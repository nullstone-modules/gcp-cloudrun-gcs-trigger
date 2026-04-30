data "ns_connection" "bucket" {
  name     = "bucket"
  contract = "datastore/gcp/gcs"
}

locals {
  bucket_name     = data.ns_connection.bucket.outputs.bucket_name
  bucket_location = data.ns_connection.bucket.outputs.bucket_location
  bucket_project  = data.ns_connection.bucket.outputs.bucket_project
}

# Eventarc GCS triggers must live in the bucket's region or multi-region.
# The workflow destination is regional, so a regional bucket must match the workflow region.
check "trigger_location_supported" {
  assert {
    condition     = contains(["US", "EU", "ASIA"], upper(local.bucket_location)) || lower(local.bucket_location) == lower(local.region)
    error_message = "Eventarc GCS trigger requires the bucket to be in a multi-region (US/EU/ASIA) or the same region as the workflow (${local.region}). Got: ${local.bucket_location}."
  }
}
