import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { THUMBNAIL_FIELDS } from "../responseFieldDefinitions";

const ThumbnailResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "thumbnail",
        type: "object | null",
        description: "The product thumbnail; null after deletion",
        children: THUMBNAIL_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

export const CreateThumbnail = () => (
  <ApiEndpoint
    method="post"
    path="/products/:product_id/thumbnail"
    description={
      <>
        Set a product thumbnail from a signed upload or publicly accessible image URL. URL thumbnails are downloaded and
        stored by Gumroad, so the URL must be reachable over HTTP(S) and cannot be a private or pre-signed upload URL.
        Thumbnail images must be square, at least 600x600px, smaller than 5 MB, and in JPG, PNG, or GIF format. Requires
        the <code>edit_products</code> scope.
      </>
    }
  >
    <ApiParameters>
      <ApiParameter
        name="signed_blob_id"
        description="(required unless url is provided; signed ID from a direct upload)"
      />
      <ApiParameter
        name="url"
        description="(required unless signed_blob_id is provided; a publicly accessible image URL)"
      />
    </ApiParameters>
    <ThumbnailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/thumbnail \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "url=https://example.com/thumbnail.png" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "thumbnail": {
    "url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "guid": "abc123"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteThumbnail = () => (
  <ApiEndpoint
    method="delete"
    path="/products/:product_id/thumbnail"
    description={
      <>
        Delete a product thumbnail. Requires the <code>edit_products</code> scope.
      </>
    }
  >
    <ThumbnailResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/thumbnail \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "thumbnail": null
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
