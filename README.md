# gcp-cloudrun-gcs-trigger

Nullstone capability that triggers a Cloud Run Job when an object is created (or modified) in a GCS bucket.

## How it works

```
GCS Bucket  ──►  Eventarc  ──►  Cloud Workflow  ──►  Cloud Run Job
```

1. A file lands in a connected GCS bucket.
2. Eventarc receives the GCS event.
3. Eventarc invokes a small Cloud Workflow.
4. The workflow calls the Cloud Run Jobs API and starts a job execution, passing the bucket name and object path to your container as environment variables.

This module provisions the Eventarc trigger, the workflow, a dedicated service account, and all the IAM bindings required to make the chain work.

## How to use

This is a Nullstone *capability*. You attach it to a Cloud Run Job application in your stack.

### Step 1 — Connect a bucket

The capability requires a connection named `bucket` that satisfies the `datastore/gcp/gcs` contract. In your Nullstone stack, wire the capability to a GCS bucket datastore. The bucket name and location are pulled automatically — you don't pass them as variables.

### Step 2 — Read the trigger inputs in your job

Every time the trigger fires, the Cloud Run Job is started with two environment variables:

| Variable       | Description                                     |
| -------------- | ----------------------------------------------- |
| `INPUT_BUCKET` | Name of the bucket where the object landed.     |
| `INPUT_FILE`   | Full path of the object within the bucket.      |

Read these in your container to know which file to process. Example (Python):

```python
import os

bucket = os.environ["INPUT_BUCKET"]
key    = os.environ["INPUT_FILE"]
print(f"Processing gs://{bucket}/{key}")
```

Example (Node.js):

```js
const bucket = process.env.INPUT_BUCKET;
const key    = process.env.INPUT_FILE;
console.log(`Processing gs://${bucket}/${key}`);
```

> **Note:** these env vars are injected as per-execution overrides on the Cloud Run Job. They do not show up in the Job's static configuration in the GCP console — they are added at run time by the workflow.

### Step 3 — (Optional) Filter which objects trigger the job

By default, **every** object created in the bucket triggers the job. To narrow it down, set one or both of the variables below.

## Variables

| Variable              | Type           | Default                                        | Description                                                                                                                                                                                              |
| --------------------- | -------------- | ---------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `event_types`         | `list(string)` | `["google.cloud.storage.object.v1.finalized"]` | GCS event types that should trigger the job. One Eventarc trigger is created per entry. See the table below for the supported values and what each one means.                                            |
| `object_name_pattern` | `string`       | `null`                                         | Optional regex matched against the object path. When `null`, every event triggers the job. When set, only events whose object name matches the regex trigger the job. Example: `"^incoming/.*\\.csv$"`. |

### Supported event types

| Event type                                          | When it fires                                                                                                                                                                                                                                                  |
| --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `google.cloud.storage.object.v1.finalized`          | A new object was successfully written to the bucket. This covers brand-new uploads and overwrites of existing objects. **This is the default and is what you want for "run my job whenever a file lands in the bucket".**                                       |
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

## Limitations

- Eventarc requires the bucket and the trigger to be in compatible locations. Multi-region buckets (`US`, `EU`, `ASIA`) work universally; regional buckets must match the workspace's GCP region. Mismatches surface as Eventarc API errors at apply time.
- Each event spawns a fresh Cloud Run Job execution, which incurs cold-start latency and per-execution cost. For very high event rates with small payloads, consider a Cloud Run *Service* with an HTTP push subscription instead.
- The `INPUT_BUCKET` / `INPUT_FILE` env-var contract is fixed. If your job needs different names, rename them inside the container's entrypoint.
- Workflow execution failures do not currently dead-letter — Eventarc will retry per its built-in policy, and persistent failures are visible in the Workflow execution history.
