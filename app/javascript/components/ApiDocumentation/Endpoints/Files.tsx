import React from "react";

import { CardContent } from "$app/components/ui/Card";
import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

export const FilesOverview = () => (
  <CardContent details>
    <div className="flex grow flex-col gap-4">
      <p>Uploading a file is a four-step flow:</p>
      <ol className="ml-4 list-decimal">
        <li>
          <a href="#post-/files/presign">Presign</a> — get an upload ID and a presigned URL for each 100 MB part.
        </li>
        <li>
          Upload — <code>PUT</code> each part's bytes to its presigned URL and capture the <code>ETag</code> response
          header.
        </li>
        <li>
          <a href="#post-/files/complete">Complete</a> — finalize the upload by submitting the list of ETags.
        </li>
        <li>
          <a href="#attach-file">Attach</a> — pass the <code>file_url</code> to <code>POST /v2/products</code> or{" "}
          <code>PUT /v2/products/:id</code>.
        </li>
      </ol>
      <p>
        If an upload fails partway through, call <a href="#post-/files/abort">/v2/files/abort</a> to cancel it. Abort
        responses include a <code>status</code> field: <code>accepted</code> means S3 took the cancellation but parts
        still in flight may finish seconds later, and <code>already_gone</code> means S3 has no multipart session for
        this <code>upload_id</code>. Call abort again while you see <code>accepted</code>; stop when you see{" "}
        <code>already_gone</code>.
      </p>
    </div>
  </CardContent>
);

export const PresignFile = () => (
  <ApiEndpoint
    method="post"
    path="/files/presign"
    description="Start a multipart upload. Returns presigned URLs for each part. Requires the edit_products scope."
  >
    <ApiParameters>
      <ApiParameter name="filename" description="(e.g. course.pdf)" />
      <ApiParameter name="file_size" description="(in bytes; max 20 GB)" />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "upload_id", type: "string", description: "S3 multipart upload ID; pass to /files/complete" },
        { name: "key", type: "string", description: "S3 object key for the uploaded file; pass to /files/complete" },
        {
          name: "file_url",
          type: "string",
          description:
            "Canonical S3 URL ({S3_BASE_URL}attachments/{seller_external_id}/{guid}/original/{filename}); the S3 object isn't accessible until /files/complete finalizes the multipart upload",
        },
        {
          name: "parts",
          type: "array",
          description: "One entry per 100 MB part; PUT the bytes for each part to its presigned_url",
          children: [
            { name: "part_number", type: "integer", description: "Sequential part number, starting at 1" },
            {
              name: "presigned_url",
              type: "string",
              description: "S3 presigned URL; expires after 900 seconds (15 minutes)",
            },
          ],
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/files/presign \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "filename=course.pdf" \\
  -d "file_size=104857600" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "upload_id": "ibZBv_75gd9o.uPYmGbJ5JjxqK4_VsP3...",
  "key": "attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf",
  "file_url": "https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf",
  "parts": [
    { "part_number": 1, "presigned_url": "https://gumroad-specials.s3.amazonaws.com/...&partNumber=1&uploadId=..." }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CompleteFile = () => (
  <ApiEndpoint
    method="post"
    path="/files/complete"
    description="Finalize the multipart upload started by /v2/files/presign. Returns the final file_url. Requires the edit_products scope."
  >
    <ApiParameters>
      <ApiParameter name="upload_id" description="(returned by /files/presign)" />
      <ApiParameter name="key" description="(returned by /files/presign)" />
      <ApiParameter name="parts" description="(array of { part_number, etag })" />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "file_url",
          type: "string",
          description: "Pass this as files[][url] when attaching to a product",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/files/complete \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "upload_id=ibZBv_75gd9o.uPYmGbJ5JjxqK4_VsP3..." \\
  -d "key=attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf" \\
  -d "parts[][part_number]=1" \\
  -d 'parts[][etag]="9b2cf535f27731c974343645a3985328"' \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "file_url": "https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf"
}`}
    </CodeSnippet>
    <p>
      <strong>Don't retry this call.</strong> The <code>upload_id</code> works only once. If you lose the response,
      start a fresh upload with <code>/v2/files/presign</code> and use the new <code>file_url</code>.
    </p>
  </ApiEndpoint>
);

export const AbortFile = () => (
  <ApiEndpoint
    method="post"
    path="/files/abort"
    description="Cancel a multipart upload started by /v2/files/presign. Requires the edit_products scope."
  >
    <ApiParameters>
      <ApiParameter name="upload_id" description="(returned by /files/presign)" />
      <ApiParameter name="key" description="(returned by /files/presign)" />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "status",
          type: "string",
          description:
            "accepted if S3 took the cancellation on this call (parts still in flight may finish seconds later); already_gone if S3 has no multipart session for this upload_id",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/files/abort \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "upload_id=ibZBv_75gd9o.uPYmGbJ5JjxqK4_VsP3..." \\
  -d "key=attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "status": "accepted"
}`}
    </CodeSnippet>
    <p>
      Loop on <code>status</code>: while it's <code>accepted</code>, keep calling abort; when it's{" "}
      <code>already_gone</code>, stop. <code>already_gone</code> only tells you S3 has no multipart session for this{" "}
      <code>upload_id</code> — it does not distinguish "fully cancelled" from "finalized by a racing{" "}
      <code>/v2/files/complete</code>". To avoid ambiguity, don't issue abort and complete for the same upload
      concurrently.
    </p>
  </ApiEndpoint>
);

export const AttachFile = () => (
  <CardContent details id="attach-file">
    <div className="flex grow flex-col gap-4">
      <div role="heading" aria-level={3}>
        Attaching to a product
      </div>
      <p>
        Pass the <code>file_url</code> from <code>/v2/files/complete</code> as <code>files[][url]</code> on{" "}
        <code>POST /v2/products</code> or <code>PUT /v2/products/:id</code>. The attach step rejects URLs that don't
        start with your seller prefix.
      </p>
      <CodeSnippet caption="Attach on create (POST /v2/products)">
        {`curl https://api.gumroad.com/v2/products \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "native_type=digital" \\
  -d "name=My product" \\
  -d "price=500" \\
  -d "files[][url]=https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf" \\
  -X POST`}
      </CodeSnippet>
      <p>
        <strong>
          <code>files</code> on <code>PUT /v2/products/:id</code> is a full replacement
        </strong>{" "}
        — any file you omit is deleted. To keep an existing file, resubmit its <code>id</code> along with its current
        canonical <code>file_url</code>. Entries without a <code>url</code> are dropped (and the file they point to is
        deleted).
      </p>
      <CodeSnippet caption="Attach on update (PUT /v2/products/:id) — preserve existing files">
        {`curl https://api.gumroad.com/v2/products/PRODUCT_ID \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "files[][id]=EXISTING_FILE_ID_1" \\
  -d "files[][url]=https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/aaaa1111/original/existing1.pdf" \\
  -d "files[][id]=EXISTING_FILE_ID_2" \\
  -d "files[][url]=https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/bbbb2222/original/existing2.pdf" \\
  -d "files[][url]=https://gumroad-specials.s3.amazonaws.com/attachments/A-m3CDDC5dlrSdKZp0RFhA==/9f2c1b7d6e4a/original/course.pdf" \\
  -X PUT`}
      </CodeSnippet>
      <p>
        Save the canonical <code>file_url</code> on your side. <code>GET /v2/products/:id</code> returns a time-limited
        signed download URL, not the canonical URL, so you can't recover it from a read. Changing a file's{" "}
        <code>display_name</code> rewrites its canonical URL asynchronously — avoid renaming uploaded files through the
        API, and if you do, refresh your stored URL out of band.
      </p>
    </div>
  </CardContent>
);
