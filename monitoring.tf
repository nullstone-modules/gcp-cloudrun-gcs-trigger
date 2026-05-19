data "ns_connection" "notification" {
  name     = "notification"
  contract = "datastore/gcp/notification"
  optional = true
}

locals {
  notification_channels = try(data.ns_connection.notification.outputs.notification_channels, [data.ns_connection.notification.outputs.notification_name], [])
}

locals {
  monitoring_event_types = length(local.notification_channels) == 0 ? toset([]) : toset(var.event_types)

  # Eventarc creates and manages a Pub/Sub subscription per trigger as the event-delivery transport.
  # transport.pubsub.subscription is returned as "projects/{project}/subscriptions/{name}"; the monitoring
  # filter wants just the short name, so we strip the prefix.
  monitoring_subscriptions = {
    for trigger in local.monitoring_event_types : trigger => {
      display_name = "${regex("[^.]+$", trigger)}-${local.resource_suffix}-unacked"
      subscription = regex("[^/]+$", google_eventarc_trigger.this[trigger].transport[0].pubsub[0].subscription)
    }
  }
}

resource "google_monitoring_alert_policy" "unacked_message_age" {
  for_each = local.monitoring_subscriptions

  display_name = each.value.display_name
  combiner     = "OR"

  conditions {
    display_name = "oldest_unacked_message_age > ${var.unacked_message_age_threshold}s"

    condition_threshold {
      filter          = "resource.type = \"pubsub_subscription\" AND resource.label.subscription_id = \"${each.value.subscription}\" AND metric.type = \"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      comparison      = "COMPARISON_GT"
      threshold_value = var.unacked_message_age_threshold
      duration        = "300s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = local.notification_channels

  alert_strategy {
    auto_close = "1800s"
  }
}
