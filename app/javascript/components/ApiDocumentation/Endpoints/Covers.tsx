import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { COVER_FIELDS } from "../responseFieldDefinitions";

const CoversResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "covers",
        type: "array",
        description: "Covers for the product, in display order",
        children: COVER_FIELDS,
      },
      {
        name: "main_cover_id",
        type: "string | null",
        description: "ID of the first cover in display order; null when the product has no covers",
      },
    ])}
  </ApiResponseFields>
);

export const CreateCover = () => (
  <ApiEndpoint
    method="post"
    path="/products/:product_id/covers"
    description={
      <>
        Add a cover to a product from a publicly accessible URL. The server fetches the URL and stores a copy, so the
        URL must be reachable over HTTP(S) and cannot be a private or pre-signed upload URL. Accepts image (JPEG, PNG,
        GIF) and video URLs, as well as YouTube and Vimeo URLs. Requires the <code>edit_products</code> scope.
      </>
    }
  >
    <ApiParameters>
      <ApiParameter
        name="url"
        description="(required; a publicly accessible image/video URL, or a YouTube/Vimeo URL)"
      />
    </ApiParameters>
    <CoversResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/covers \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "url=https://www.youtube.com/watch?v=qKebcV1jv3A" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "covers": [{
    "id": "abc123",
    "url": "https://www.youtube.com/embed/qKebcV1jv3A?feature=oembed&enablejsapi=1",
    "original_url": "https://www.youtube.com/embed/qKebcV1jv3A?feature=oembed&enablejsapi=1",
    "thumbnail": "https://i.ytimg.com/vi/qKebcV1jv3A/hqdefault.jpg",
    "type": "oembed",
    "filetype": null,
    "width": 670,
    "height": 377,
    "native_width": 1280,
    "native_height": 720
  }],
  "main_cover_id": "abc123"
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteCover = () => (
  <ApiEndpoint
    method="delete"
    path="/products/:product_id/covers/:id"
    description={
      <>
        Delete a cover from a product. Requires the <code>edit_products</code> scope.
      </>
    }
  >
    <CoversResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/covers/abc123 \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "covers": [],
  "main_cover_id": null
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
