locals {
  # Eventarc requires multi-region locations in lowercase (us/eu/asia); regional locations are already lowercase.
  trigger_location = contains(["US", "EU", "ASIA"], upper(local.bucket_location)) ? lower(local.bucket_location) : local.bucket_location

  # Workflow step that runs the Cloud Run Job by calling the Jobs API.
  # The job is started with INPUT_BUCKET / INPUT_FILE env-var overrides.
  invoke_step_job = <<EOT
    - run_target:
        call: googleapis.run.v2.projects.locations.jobs.run
        args:
          name: "${local.job_id}"
          body:
            overrides:
              containerOverrides:
                env:
                  - name: INPUT_BUCKET
                    value: $${event_bucket}
                  - name: INPUT_FILE
                    value: $${event_file}
        result: target_response
EOT

  # Workflow step that invokes the Cloud Run Service over authenticated HTTP.
  # The body and ce-* headers mirror the CloudEvents HTTP binary-mode format
  # that Eventarc uses when delivering directly to a Cloud Run Service, so a
  # service written for direct Eventarc delivery works unchanged here.
  invoke_step_service = <<EOT
    - run_target:
        call: http.post
        args:
          url: "${local.service_url}"
          auth:
            type: OIDC
            audience: "${local.service_url}"
          headers:
            Content-Type: application/json
            ce-specversion: $${event.specversion}
            ce-id: $${event.id}
            ce-type: $${event.type}
            ce-source: $${event.source}
            ce-subject: $${event.subject}
            ce-time: $${event.time}
          body: $${event.data}
        result: target_response
EOT

  invoke_step = local.target_type == "job" ? local.invoke_step_job : local.invoke_step_service
}

resource "google_eventarc_trigger" "this" {
  for_each = toset(var.event_types)

  name            = "${local.resource_name}-${regex("[^.]+$", each.key)}"
  location        = local.trigger_location
  labels          = local.labels
  service_account = google_service_account.trigger.email

  matching_criteria {
    attribute = "type"
    value     = each.key
  }

  matching_criteria {
    attribute = "bucket"
    value     = local.bucket_name
  }

  destination {
    workflow = google_workflows_workflow.gcs_to_job.id
  }

  depends_on = [
    google_project_service.eventarc,
    google_project_iam_member.gcs_agent_pubsub_publisher,
  ]
}

resource "google_workflows_workflow" "gcs_to_job" {
  name                = "${local.resource_name}-trigger"
  region              = local.region
  description         = "Triggered by GCS events via Eventarc; invokes a Cloud Run ${title(local.target_type)}"
  service_account     = google_service_account.trigger.email
  labels              = local.labels
  deletion_protection = false

  source_contents = <<EOF
main:
  params: [event]
  steps:
    - init:
        assign:
          - event_bucket: $${event.data.bucket}
          - event_file: $${event.data.name}
          - object_pattern: "${local.object_pattern_for_workflow}"
    - check_pattern:
        switch:
          - condition: $${object_pattern == "" or text.match_regex(event_file, object_pattern)}
            next: run_target
          - condition: true
            next: end
${local.invoke_step}
    - finish:
        return: $${target_response}
EOF

  depends_on = [google_project_service.workflows]

  lifecycle {
    precondition {
      condition     = (local.job_name != "") != (local.service_name != "")
      error_message = "app_metadata must contain exactly one of job_name (Cloud Run Job target) or service_name (Cloud Run Service target). Found job_name=\"${local.job_name}\", service_name=\"${local.service_name}\"."
    }
    precondition {
      condition     = local.target_type != "service" || local.service_url != ""
      error_message = "Cloud Run Service target requires service_url in app_metadata."
    }
  }
}
