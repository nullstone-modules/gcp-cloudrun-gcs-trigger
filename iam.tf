resource "google_service_account" "trigger" {
  # account_id has a 30-char limit; "-gcs-trigger-" is 13 chars and the random suffix is 5,
  # so the block_name prefix can be at most 12 chars.
  account_id  = "${substr(local.block_name, 0, 12)}-gcs-trigger-${random_string.resource_suffix.result}"
  description = "Service account for triggering ${local.block_name} from GCS bucket ${local.bucket_name}"
}

# Eventarc requires the GCS service agent to publish notifications to Pub/Sub.
# Without this, the trigger creates successfully but no events ever fire.
resource "google_project_iam_member" "gcs_agent_pubsub_publisher" {
  project = local.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_project_iam_member" "eventarc_event_receiver" {
  project = local.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.trigger.email}"
}

resource "google_project_iam_member" "workflows_invoker" {
  project = local.project_id
  role    = "roles/workflows.invoker"
  member  = "serviceAccount:${google_service_account.trigger.email}"
}

resource "google_project_iam_member" "run_invoker" {
  project = local.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.trigger.email}"
}

# Job target only: the workflow must act-as the job's own service account
# when starting an execution. Services run as their own SA when invoked over
# HTTP, so no actAs grant is needed for the service path.
resource "google_service_account_iam_member" "act_as_job_sa" {
  count = local.target_type == "job" ? 1 : 0

  service_account_id = "projects/${local.project_id}/serviceAccounts/${local.service_account_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.trigger.email}"
}

# Job target only: starting an execution with containerOverrides (the env-var
# injection in trigger.tf) needs run.jobs.runWithOverrides, which is NOT in
# roles/run.invoker. roles/run.jobsExecutorWithOverrides is the minimum
# predefined role that includes it (run.jobs.run + run.jobs.runWithOverrides
# + run.executions.cancel, nothing else).
resource "google_cloud_run_v2_job_iam_member" "run_with_overrides" {
  count = local.target_type == "job" ? 1 : 0

  project  = local.project_id
  location = split("/", local.job_id)[3]
  name     = local.job_name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = "serviceAccount:${google_service_account.trigger.email}"
}

# Job target only: the Workflows connector polls the long-running operation
# returned by run.jobs.run via run.operations.get. Cloud Run operations have
# no resource-level IAM, so this must be granted at project scope.
# roles/run.viewer is the narrowest predefined role carrying that permission
# (read-only across all Run resources in the project).
resource "google_project_iam_member" "run_viewer" {
  count = local.target_type == "job" ? 1 : 0

  project = local.project_id
  role    = "roles/run.viewer"
  member  = "serviceAccount:${google_service_account.trigger.email}"
}

resource "google_storage_bucket_iam_member" "gcs_object_viewer" {
  bucket = local.bucket_name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.trigger.email}"
}

resource "google_storage_bucket_iam_member" "bucket_access" {
  bucket = local.bucket_name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.app_metadata["service_account_email"]}"

  count = local.project_id == local.bucket_project ? 1 : 0
}
