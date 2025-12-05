resource "google_eventarc_trigger" "this" {
  for_each = toset(var.event_types)

  name            = "${local.resource_name}-${regex("[^.]+$", each.key)}"
  location        = local.bucket_location
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
  description         = "Triggered by GCS events via Eventarc; runs Cloud Run Job"
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
          - job_id: "${local.job_id}"
          - object_pattern: "${local.object_pattern_for_workflow}"
    - check_pattern:
        switch:
          - condition: $${object_pattern == "" or text.match_regex(event_file, object_pattern)}
            next: run_job
          - condition: true
            next: end
    - run_job:
        call: googleapis.run.v2.projects.locations.jobs.run
        args:
          name: $${job_id}
          body:
            overrides:
              containerOverrides:
                env:
                  - name: INPUT_BUCKET
                    value: $${event_bucket}
                  - name: INPUT_FILE
                    value: $${event_file}
        result: job_execution
    - finish:
        return: $${job_execution}
EOF

  depends_on = [google_project_service.workflows]
}
