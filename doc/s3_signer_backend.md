# S3 multipart signer backend

`HttpS3MultipartSigner(baseUrl: …)` calls four `POST` endpoints under
`baseUrl`. Every call carries the task's headers — supply your app auth via
`headerProvider`.

| Endpoint | Request JSON | Response JSON |
|---|---|---|
| `/initiate` | `{fileName, contentType, fileSize, tag, metadata}` | `{uploadId, key}` |
| `/sign-part` | `{uploadId, key, partNumber, contentLength}` | `{url, headers?}` |
| `/complete` | `{uploadId, key, parts: [{partNumber, eTag}]}` | anything → `task.response` |
| `/abort` | `{uploadId, key}` | anything |

Non-2xx responses surface as `UploadException(statusCode)` and follow the
retry policy (401 is refreshed-and-retried when a `headerProvider` exists;
403/404 fail).

**Security requirements for any implementation**

1. Authenticate every call.
2. Generate the object key server-side, under a per-user prefix.
3. On `sign-part`, `complete` and `abort`, reject keys outside the caller's
   prefix — otherwise one user can write into another's upload.
4. Enforce size and content-type limits at `initiate`.
5. Presign with a short expiry (the client signs each part just before
   sending it, so 15 minutes is plenty).
6. Add a bucket lifecycle rule: *abort incomplete multipart uploads after N
   days*.

---

## Supabase Edge Function (Deno) — S3, R2, MinIO, Wasabi, Spaces

`supabase/functions/s3-multipart/index.ts`

```ts
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  S3Client,
  UploadPartCommand,
} from "npm:@aws-sdk/client-s3@3";
import { getSignedUrl } from "npm:@aws-sdk/s3-request-presigner@3";

const env = (name: string) => {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`Missing env ${name}`);
  return value;
};

const BUCKET = env("S3_BUCKET");
const MAX_FILE_BYTES = Number(Deno.env.get("MAX_FILE_BYTES") ?? 5 * 1024 ** 3);
const ALLOWED_TYPES = (Deno.env.get("ALLOWED_CONTENT_TYPES") ?? "")
  .split(",").map((s) => s.trim()).filter(Boolean);

const s3 = new S3Client({
  region: Deno.env.get("S3_REGION") ?? "auto",
  endpoint: Deno.env.get("S3_ENDPOINT") || undefined, // R2 / MinIO / Wasabi
  forcePathStyle: Deno.env.get("S3_FORCE_PATH_STYLE") === "true",
  credentials: {
    accessKeyId: env("S3_ACCESS_KEY_ID"),
    secretAccessKey: env("S3_SECRET_ACCESS_KEY"),
  },
  // AWS SDK v3 ≥ 3.729 adds CRC32 checksums to presigned UploadPart URLs by
  // default, which the mobile client can't satisfy. Only send them when the
  // operation requires it.
  requestChecksumCalculation: "WHEN_REQUIRED",
  responseChecksumValidation: "WHEN_REQUIRED",
});

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);

  // 1. Authenticate (verify_jwt stays ON for this function).
  const supabase = createClient(env("SUPABASE_URL"), env("SUPABASE_ANON_KEY"), {
    global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
  });
  const { data: { user }, error: authError } = await supabase.auth.getUser();
  if (authError || !user) return json({ error: "unauthorized" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid json" }, 400);
  }

  const action = new URL(req.url).pathname.split("/").pop();
  const prefix = `uploads/${user.id}/`;
  const ownsKey = (key: unknown): key is string =>
    typeof key === "string" && key.startsWith(prefix) && !key.includes("..");

  try {
    switch (action) {
      case "initiate": {
        const fileSize = Number(body.fileSize ?? -1);
        const contentType = String(body.contentType ?? "application/octet-stream");
        if (!Number.isFinite(fileSize) || fileSize < 0 || fileSize > MAX_FILE_BYTES) {
          return json({ error: "file too large" }, 413);
        }
        if (ALLOWED_TYPES.length && !ALLOWED_TYPES.includes(contentType)) {
          return json({ error: "content type not allowed" }, 415);
        }
        const safeName = String(body.fileName ?? "file")
          .replace(/[^\w.\-]+/g, "_")
          .slice(-120);
        // 2. Key generated server-side under the caller's prefix.
        const key = `${prefix}${crypto.randomUUID()}-${safeName}`;
        const out = await s3.send(
          new CreateMultipartUploadCommand({ Bucket: BUCKET, Key: key, ContentType: contentType }),
        );
        return json({ uploadId: out.UploadId, key });
      }

      case "sign-part": {
        const { uploadId, key } = body;
        const partNumber = Number(body.partNumber);
        // 3. Ownership check.
        if (!ownsKey(key) || typeof uploadId !== "string") return json({ error: "forbidden" }, 403);
        if (!Number.isInteger(partNumber) || partNumber < 1 || partNumber > 10000) {
          return json({ error: "invalid partNumber" }, 400);
        }
        const url = await getSignedUrl(
          s3,
          new UploadPartCommand({ Bucket: BUCKET, Key: key, UploadId: uploadId, PartNumber: partNumber }),
          { expiresIn: 900 }, // 5. short-lived
        );
        return json({ url });
      }

      case "complete": {
        const { uploadId, key, parts } = body;
        if (!ownsKey(key) || typeof uploadId !== "string" || !Array.isArray(parts)) {
          return json({ error: "forbidden" }, 403);
        }
        const out = await s3.send(new CompleteMultipartUploadCommand({
          Bucket: BUCKET,
          Key: key,
          UploadId: uploadId,
          MultipartUpload: {
            Parts: parts.map((p: { partNumber: number; eTag: string }) => ({
              PartNumber: p.partNumber,
              ETag: p.eTag,
            })),
          },
        }));
        // Optionally insert a row in your `files` table here.
        return json({ key, eTag: out.ETag, location: out.Location });
      }

      case "abort": {
        const { uploadId, key } = body;
        if (!ownsKey(key) || typeof uploadId !== "string") return json({ error: "forbidden" }, 403);
        await s3.send(new AbortMultipartUploadCommand({ Bucket: BUCKET, Key: key, UploadId: uploadId }));
        return json({ aborted: true });
      }

      default:
        return json({ error: "not found" }, 404);
    }
  } catch (e) {
    console.error(`[s3-multipart] ${action}`, e);
    // NoSuchUpload on sign-part/complete means the session expired or was
    // aborted — the client fails the task; user can retry from scratch.
    const name = (e as { name?: string }).name;
    if (name === "NoSuchUpload") return json({ error: "upload session not found" }, 404);
    return json({ error: "storage error" }, 502); // 5xx → client retries
  }
});
```

### Deploy

```bash
supabase secrets set \
  S3_BUCKET=my-bucket \
  S3_REGION=af-south-1 \
  S3_ACCESS_KEY_ID=... \
  S3_SECRET_ACCESS_KEY=... \
  MAX_FILE_BYTES=5368709120 \
  ALLOWED_CONTENT_TYPES=video/mp4,video/quicktime,image/jpeg,image/png,application/pdf
# Cloudflare R2:  S3_REGION=auto S3_ENDPOINT=https://<account>.r2.cloudflarestorage.com
# MinIO:          S3_ENDPOINT=https://minio.example.com S3_FORCE_PATH_STYLE=true

supabase functions deploy s3-multipart
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` are injected automatically.

### Flutter side

```dart
await FlorevilleUploadManager.initialize(
  headerProvider: (_) async => {
    'Authorization':
        'Bearer ${Supabase.instance.client.auth.currentSession?.accessToken}',
  },
  adapters: [
    S3MultipartUploadAdapter(
      signer: HttpS3MultipartSigner(
        baseUrl: '${supabaseUrl}/functions/v1/s3-multipart',
      ),
    ),
  ],
);
```

### Bucket lifecycle (AWS CLI)

```bash
aws s3api put-bucket-lifecycle-configuration --bucket my-bucket \
  --lifecycle-configuration '{"Rules":[{"ID":"abort-mpu","Status":"Enabled",
  "Filter":{"Prefix":"uploads/"},
  "AbortIncompleteMultipartUpload":{"DaysAfterInitiation":3}}]}'
```

R2 offers the same rule under *Settings → Object lifecycle rules*.
