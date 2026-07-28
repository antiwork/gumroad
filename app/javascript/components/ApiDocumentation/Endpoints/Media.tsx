import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

// The creator's media library: images hosted on Gumroad's public storage so they render on custom
// pages, whose Content-Security-Policy blocks images loaded from other sites. Endpoints
// have been live for a while but were never documented, so creators were harvesting URLs out of
// the product description editor instead.
const MEDIA_FIELDS = [
  { name: "id", type: "string", description: "The file's unique ID; pass to DELETE /media/:id" },
  { name: "name", type: "string", description: "The file's display name" },
  {
    name: "extension",
    type: "string",
    description:
      "The uppercased file extension, e.g. PNG. Derived from the filename, so a filename with no extension yields the filename itself",
  },
  { name: "file_size", type: "number | null", description: "Size in bytes; null if no file is attached" },
  {
    name: "url",
    type: "string | null",
    description: "Public CDN URL for the file — this is what you embed in a custom page",
  },
  { name: "status", type: "object", description: 'Upload status; always { "type": "saved" } for a stored file' },
  {
    name: "file_group",
    type: "string | null",
    description:
      "Broad file category matched from the extension, e.g. 'image'; null when nothing matches. The match is a substring one, so a filename with no extension is matched against the whole name",
  },
  { name: "created_at", type: "string", description: "ISO 8601 timestamp of when the file was uploaded" },
];

export const GetMedia = () => (
  <ApiEndpoint
    method="get"
    path="/media"
    description={
      <>
        <p>
          Lists the files in the authenticated user's media library, newest first. Requires the{" "}
          <code className="inline-code">view_profile</code> scope.
        </p>
        <p>
          The media library hosts images on Gumroad's own storage so they can be displayed on your public pages. Custom
          product and profile pages render under a Content Security Policy that blocks images loaded from other sites —
          only inline <code className="inline-code">data:</code>/<code className="inline-code">blob:</code> images and
          Gumroad's own public asset hosts are allowed — so an image hosted elsewhere will not load there. Upload it
          here first and embed the returned <code className="inline-code">url</code>. Files belong to your account
          rather than to a single product, so the same image can be used across as many pages as you like.
        </p>
      </>
    }
  >
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "media", type: "array", description: "Array of media files", children: MEDIA_FIELDS },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/media \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "media": [
    {
      "id": "k7m2q9x4tb1zn6dw",
      "name": "logo",
      "extension": "PNG",
      "file_size": 18422,
      "url": "https://public-files.gumroad.com/abc123/logo.png",
      "status": { "type": "saved" },
      "file_group": "image",
      "created_at": "2026-03-01T12:00:00Z"
    }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateMedia = () => (
  <ApiEndpoint
    method="post"
    path="/media"
    description={
      <>
        <p>
          Uploads an image to the media library, either from a publicly reachable URL that Gumroad downloads for you or
          from a signed blob ID produced by a direct upload. Requires the{" "}
          <code className="inline-code">edit_profile</code> scope.
        </p>
        <p>
          Images may be up to 10 MB, and the file type is determined by inspecting the bytes rather than trusting the
          file extension. SVG is not accepted, because these files are served from a Gumroad domain and SVG can carry
          script. An account may hold up to 500 files at a time.
        </p>
        <p>
          Uploads are rate limited to 20 per 10 minutes. Accounts that are suspended or closed cannot upload, and a
          token holding only the broad <code className="inline-code">account</code> scope is rejected — this endpoint
          requires <code className="inline-code">edit_profile</code> specifically.
        </p>
        <p>
          To use <code className="inline-code">signed_blob_id</code>, first reserve a direct upload with{" "}
          <code className="inline-code">POST /v2/direct_uploads</code> passing{" "}
          <code className="inline-code">purpose=media</code>, upload the bytes to the URL it returns, then pass the
          returned signed ID here.
        </p>
      </>
    }
  >
    <ApiParameters>
      <ApiParameter
        name="url"
        description="(required unless signed_blob_id is provided) - A publicly reachable image URL. Gumroad downloads the file server-side."
      />
      <ApiParameter
        name="signed_blob_id"
        description="(required unless url is provided) - A signed blob ID from a POST /v2/direct_uploads reservation made with purpose=media."
      />
      <ApiParameter
        name="name"
        description="(optional) - Display name for the file. Defaults to the filename with its extension stripped."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "media", type: "object", description: "The uploaded file", children: MEDIA_FIELDS },
        {
          name: "message",
          type: "string",
          description: "Why the upload was rejected",
          condition: "present when success is false",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/media \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "url=https://example.com/logo.png" \\
  -d "name=logo" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "media": {
    "id": "k7m2q9x4tb1zn6dw",
    "name": "logo",
    "extension": "PNG",
    "file_size": 18422,
    "url": "https://public-files.gumroad.com/abc123/logo.png",
    "status": { "type": "saved" },
    "file_group": "image",
    "created_at": "2026-03-01T12:00:00Z"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteMedia = () => (
  <ApiEndpoint
    method="delete"
    path="/media/:id"
    description={
      <>
        Deletes a file from the media library. Requires the <code className="inline-code">edit_profile</code> scope. The
        file leaves your library immediately and the hosted copy is queued for removal, so any page still embedding its
        URL will show a broken image once the purge runs.
      </>
    }
  >
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "message", type: "string", description: "Confirmation, or why the request failed" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/media/k7m2q9x4tb1zn6dw \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The file was deleted."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
