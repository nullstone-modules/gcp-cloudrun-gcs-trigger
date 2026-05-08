output "job_iam_members" {
  value = [
    {
      # Job target only: starting an execution with containerOverrides (the env-var
      # injection in trigger.tf) needs run.jobs.runWithOverrides, which is NOT in
      # roles/run.invoker. roles/run.jobsExecutorWithOverrides is the minimum
      # predefined role that includes it (run.jobs.run + run.jobs.runWithOverrides
      # + run.executions.cancel, nothing else).
      name   = "allow-exec-override"
      role   = "roles/run.jobsExecutorWithOverrides"
      member = "serviceAccount:${google_service_account.trigger.email}"
    }
  ]
}
