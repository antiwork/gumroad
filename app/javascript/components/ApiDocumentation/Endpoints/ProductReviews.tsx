import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

// Read access to the reviews shown on a product's public page. The aggregate rating already lives
// on the product resource; this is the endpoint that returns the review text itself along with the
// date it was submitted, which is what a creator needs to render testimonials on a custom page.
export const GetProductReviews = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/reviews"
    description={
      <>
        <p>
          Retrieves the reviews shown on one of the authenticated user's product pages, newest first. Available with any
          read scope.
        </p>
        <p>
          Only reviews that appear publicly are returned — a review is included when the buyer left a written message or
          an approved video. Star-only ratings with no message are counted in the product's{" "}
          <code className="inline-code">average_rating</code> but are not returned here.
        </p>
      </>
    }
  >
    <ApiParameters>
      <ApiParameter
        name="page_key"
        description="(optional) - A key representing a page of results. It is given in the response of the previous page as `next_page_key`. Up to 100 reviews are returned per page."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "next_page_url",
          type: "string",
          description: "URL for the next page of results",
          condition: "present when there is another page",
        },
        {
          name: "next_page_key",
          type: "string",
          description: "Key to pass as page_key for the next page",
          condition: "present when there is another page",
        },
        {
          name: "product_reviews",
          type: "array",
          description: "Array of review objects",
          children: [
            { name: "id", type: "string", description: "The review's unique external ID" },
            { name: "rating", type: "number", description: "The star rating, from 1 to 5" },
            {
              name: "message",
              type: "string | null",
              description: "The review text written by the buyer; null when the buyer left a video instead",
            },
            { name: "created_at", type: "string", description: "ISO 8601 timestamp of when the review was submitted" },
            { name: "purchase_id", type: "string", description: "External ID of the purchase being reviewed" },
            {
              name: "rater_name",
              type: "string",
              description: "Display name of the reviewer, or 'Anonymous' when they have no name set",
            },
            {
              name: "response",
              type: "object",
              description: "The seller's public reply, with its own message and created_at; null when there is none",
            },
          ],
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/reviews \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product_reviews": [
    {
      "id": "sJ8Yx3d6mUL1kQpVbHnZ2g==",
      "rating": 5,
      "message": "Exactly what I needed for my workflow.",
      "created_at": "2026-03-01T12:00:00Z",
      "purchase_id": "kL9nR2sTvW4xY7zA1bC3dE==",
      "rater_name": "Avery",
      "response": {
        "message": "Thank you!",
        "created_at": "2026-03-02T09:14:00Z"
      }
    }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
