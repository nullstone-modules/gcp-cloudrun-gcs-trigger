# gcp-cloudrun-gcs-trigger

Nullstone capability that runs a Cloud Run **Job** *or* invokes a Cloud Run **Service** when an object is created (or modified) in a GCS bucket.

## How it works

```
GCS Bucket  ──►  Eventarc  ──►  Cloud Workflow  ──►  Cloud Run Job
                                              └──►  Cloud Run Service
```

1. A file lands in a connected GCS bucket.
2. Eventarc receives the GCS event.
3. Eventarc invokes a small Cloud Workflow.
4. The workflow either:
   - calls the **Cloud Run Jobs API** and starts a job execution, passing the bucket and object as env-var overrides, or
   - sends an **authenticated HTTP POST** to the Cloud Run Service URL with the GCS event payload as the JSON body.

The capability auto-detects which path to use by looking at the connected app:
- `app_metadata.job_name` set ⇒ **Job** target
- `app_metadata.service_name` set ⇒ **Service** target

This module provisions the Eventarc trigger, the workflow, a dedicated service account, and all the IAM bindings required to make the chain work.

## How to use

This is a Nullstone *capability*. Attach it to either a Cloud Run Job application or a Cloud Run Service application in your stack.

### Step 1 — Connect a bucket

The capability requires a connection named `bucket` that satisfies the `datastore/gcp/gcs` contract. In your Nullstone stack, wire the capability to a GCS bucket datastore. The bucket name and location are pulled automatically — you don't pass them as variables.

### Step 2 — Read the trigger inputs in your app

The shape of the input depends on whether your app is a **Job** or a **Service**.

#### If your app is a Cloud Run Job

The job is started with two environment variables on each execution:

| Variable       | Description                                |
| -------------- | ------------------------------------------ |
| `INPUT_BUCKET` | Name of the bucket where the object landed |
| `INPUT_FILE`   | Full path of the object within the bucket  |

Example (Python):

```python
import os

bucket = os.environ["INPUT_BUCKET"]
key    = os.environ["INPUT_FILE"]
print(f"Processing gs://{bucket}/{key}")
```

> **Note:** these env vars are injected as per-execution overrides. They do not show up in the Job's static configuration in the GCP console — they are added at run time by the workflow.

#### If your app is a Cloud Run Service

The service receives an authenticated HTTP request from the workflow in **CloudEvents HTTP binary mode** — the same wire format Eventarc uses when delivering directly to a Cloud Run Service. A service written for direct Eventarc → Cloud Run delivery works behind this capability without code changes.

- **Method + path**: always `POST /`. If your service expects events at a different path, route them inside your code or use Cloud Run's path-based ingress.
- **Content-Type**: `application/json`.
- **CloudEvent metadata in `ce-*` headers**:

| Header           | Value                                                                  |
| ---------------- | ---------------------------------------------------------------------- |
| `ce-specversion` | `1.0`                                                                  |
| `ce-id`          | Unique event ID                                                        |
| `ce-type`        | The event type (e.g. `google.cloud.storage.object.v1.finalized`)       |
| `ce-source`      | `//storage.googleapis.com/projects/_/buckets/<bucket>`                 |
| `ce-subject`     | `objects/<object-path>`                                                |
| `ce-time`        | Event timestamp                                                        |

- **Body**: the GCS object payload (the CloudEvent's `data` field). Example:

```json
{
  "bucket": "my-bucket-name",
  "name": "incoming/file.csv",
  "size": "12345",
  "contentType": "text/csv",
  "...": "other GCS object metadata"
}
```

If you've configured multiple `event_types` for a single service, read `ce-type` to discriminate between them.

Example (Python / Flask):

```python
from flask import Flask, request

app = Flask(__name__)

@app.post("/")
def handle_event():
    data   = request.get_json()
    bucket = data["bucket"]
    key    = data["name"]
    print(f"Processing gs://{bucket}/{key}")
    return ("", 204)
```

Example (Node.js / Express):

```js
app.post("/", (req, res) => {
  const eventType    = req.header("ce-type");
  const { bucket, name } = req.body;
  console.log(`[${eventType}] gs://${bucket}/${name}`);
  res.status(204).end();
});
```

The request is signed with an OIDC ID token from the trigger's service account. If your service requires authentication (the default for new Cloud Run services), the workflow's identity is granted `roles/run.invoker` automatically.

### Step 3 — (Optional) Filter which objects trigger the app

By default, **every** object created in the bucket triggers the app. The workflow performs a regex check against the object path *before* invoking the target, so filtered events incur near-zero cost. See the variables below.

## Variables

| Variable              | Type           | Default                                        | Description                                                                                                                                                                                              |
| --------------------- | -------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `event_types`         | `list(string)` | `["google.cloud.storage.object.v1.finalized"]` | GCS event types that should trigger the app. One Eventarc trigger is created per entry. See the table below for the supported values and what each one means.                                           |
| `object_name_pattern` | `string`       | `null`                                         | Optional regex matched against the object path. When `null`, every event triggers the app. When set, only events whose object name matches the regex trigger the app. Example: `"^incoming/.*\\.csv$"`. |

### Supported event types

| Event type                                          | When it fires                                                                                                                                                                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google.cloud.storage.object.v1.finalized`          | A new object was successfully written to the bucket. This covers brand-new uploads and overwrites of existing objects. **This is the default and is what you want for "run my app whenever a file lands in the bucket".**                                       |
| `google.cloud.storage.object.v1.deleted`            | An object was permanently removed. On a non-versioned bucket, this fires on every delete. On a versioned bucket, it fires only when a noncurrent version is permanently removed (the live version going away fires `archived` instead).                          |
| `google.cloud.storage.object.v1.archived`           | Only fires on versioned buckets. The live version of an object was replaced or deleted, so the previous version became a noncurrent (archived) version. Use this if you care about object history rather than the latest state.                                  |
| `google.cloud.storage.object.v1.metadataUpdated`    | An object's metadata changed (custom headers, content-type, storage class, ACLs) without the object's data being rewritten. Fires for things like changing a cache-control header or moving an object between storage classes.                                   |

### Filter examples

Trigger only on CSV files under `incoming/`:

```hcl
object_name_pattern = "^incoming/.*\\.csv$"
```

Trigger on both create and delete events:

```hcl
event_types = [
  "google.cloud.storage.object.v1.finalized",
  "google.cloud.storage.object.v1.deleted",
]
```

## Cost & latency

The workflow adds roughly **~$35 per million events** (at GCP's published Workflows pricing) and **~200–600 ms** of dispatch latency on top of Eventarc's own ~1–3 s delivery time. For event-driven ingest patterns this is generally invisible. For latency-sensitive synchronous services it may matter — consider whether the workflow hop is acceptable for your use case.

## Limitations

- Eventarc requires the bucket and the trigger to be in compatible locations. Multi-region buckets (`US`, `EU`, `ASIA`) work universally; regional buckets must match the workspace's GCP region. Mismatches surface as Eventarc API errors at apply time.
- The `INPUT_BUCKET` / `INPUT_FILE` env-var contract (Job target) and the CloudEvent body shape (Service target) are fixed. If your app needs different names, rename them inside your code.
- Workflow execution failures do not currently dead-letter — Eventarc will retry per its built-in policy, and persistent failures are visible in the Workflow execution history.
