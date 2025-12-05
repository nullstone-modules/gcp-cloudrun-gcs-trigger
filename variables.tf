variable "app_metadata" {
  description = <<EOF
Nullstone automatically injects metadata from the app module into this module through this variable.
This variable is a reserved variable for capabilities.
EOF

  type    = map(string)
  default = {}
}

variable "event_types" {
  description = <<EOF
GCS event types that should trigger the Cloud Run Job. Each entry creates one Eventarc trigger.
Defaults to firing on every newly uploaded object.

Supported values:
  - google.cloud.storage.object.v1.finalized
      A new object was successfully written to the bucket. This includes brand-new
      uploads and overwrites of existing objects. This is the most common trigger
      and is what you want for "run my job whenever a file lands in the bucket".

  - google.cloud.storage.object.v1.deleted
      An object was permanently removed. On a non-versioned bucket, this fires on
      every delete. On a versioned bucket, it fires only when a noncurrent version
      is permanently removed (the live version going away fires "archived" instead).

  - google.cloud.storage.object.v1.archived
      Only fires on versioned buckets. The live version of an object was replaced
      or deleted, so the previous version became a noncurrent (archived) version.
      Use this if you care about object history rather than the latest state.

  - google.cloud.storage.object.v1.metadataUpdated
      An object's metadata changed (custom headers, content-type, storage class, ACLs)
      without the object's data being rewritten. Fires for things like changing a
      cache-control header or moving an object between storage classes.
EOF

  type    = list(string)
  default = ["google.cloud.storage.object.v1.finalized"]

  validation {
    condition     = length(var.event_types) > 0
    error_message = "event_types must contain at least one event type."
  }
}

variable "object_name_pattern" {
  description = <<EOF
Optional regex matched against the object name (the path within the bucket).
When null (default), every event triggers the job. When set, only events whose object name matches the regex trigger the job.

Example: "^incoming/.*\\.csv$" runs the job only for CSV uploads under the "incoming/" prefix.
EOF

  type    = string
  default = null
}

locals {
  service_account_email = var.app_metadata["service_account_email"]
  job_id                = var.app_metadata["job_id"]

  object_pattern_for_workflow = var.object_name_pattern == null ? "" : var.object_name_pattern
}
