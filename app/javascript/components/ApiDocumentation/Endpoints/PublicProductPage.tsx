import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

// Public, unauthenticated, read-only product page JSON.
// Unlike the OAuth `/v2/products/:id` endpoint, this requires no access token —
// it returns the same public data the rendered product page shows, so creators
// can build their own storefronts, embeds, and widgets that stay in sync.
export const GetPublicProductPage = () => (
  <ApiEndpoint
    method="get"
    path="/l/:permalink.json"
    customUrl="https://[seller].gumroad.com/l/:permalink.json"
    description={
      <>
        Retrieve the public, display data for a product page — no authentication required. This is the read/display
        counterpart to the OAuth Products API: it returns exactly the information shown on the rendered product page
        (price, covers, description, reviews, variants, and social proof), and never exposes buyer-specific,
        seller-private, or analytics fields. Append <code className="inline-code">.json</code> to any public product
        URL.
      </>
    }
  >
    <ApiResponseFields>
      {renderFields([
        { name: "api_version", type: "number", description: "The schema version of this public payload" },
        { name: "id", type: "string", description: "The product's unique external ID" },
        { name: "permalink", type: "string", description: "The product's permalink" },
        { name: "name", type: "string", description: "The product's name" },
        { name: "native_type", type: "string", description: "The product type (e.g. digital, membership, bundle)" },
        { name: "url", type: "string", description: "The full public product URL" },
        { name: "thumbnail_url", type: "string", description: "The product's thumbnail image URL, if set" },
        { name: "created_at", type: "string", description: "ISO 8601 creation timestamp" },
        { name: "updated_at", type: "string", description: "ISO 8601 last-updated timestamp" },
        {
          name: "seller",
          type: "object",
          description: "Public author byline (name, avatar, profile URL, verified) — no PII",
        },
        { name: "price_cents", type: "number", description: "The product's price in cents" },
        { name: "currency_code", type: "string", description: "The product's currency code" },
        { name: "price_formatted", type: "string", description: "The human-formatted price" },
        { name: "is_pay_what_you_want", type: "boolean", description: "Whether the buyer can name their price" },
        {
          name: "suggested_price_cents",
          type: "number",
          description: "Suggested price for pay-what-you-want products; otherwise null",
        },
        { name: "is_recurring_billing", type: "boolean", description: "Whether the product is a subscription" },
        { name: "is_tiered_membership", type: "boolean", description: "Whether the product is a tiered membership" },
        {
          name: "recurrences",
          type: "object",
          description: "Available subscription durations and pricing; null for non-recurring products",
        },
        { name: "free_trial", type: "object", description: "Free trial duration, if enabled; otherwise null" },
        { name: "description_html", type: "string", description: "The product's rich-text description as HTML" },
        { name: "summary", type: "string", description: "The product's short custom summary, if set" },
        { name: "covers", type: "array", description: "All product preview images/media" },
        { name: "attributes", type: "array", description: "Public name/value product attributes" },
        {
          name: "ratings",
          type: "object",
          description:
            "Average rating, review count, and a five-item percentages array ordered from 1 star through 5 stars; null when the creator hides reviews",
        },
        {
          name: "sales_count",
          type: "number",
          description: "Number of sales; null unless the creator opts to show the sales count",
        },
        { name: "options", type: "array", description: "Variants/tiers with per-option pricing and inventory" },
        { name: "quantity_remaining", type: "number", description: "Remaining inventory, if the product is limited" },
        { name: "is_quantity_enabled", type: "boolean", description: "Whether buyers can choose a quantity" },
        { name: "is_sales_limited", type: "boolean", description: "Whether the product has a max purchase count" },
        { name: "is_published", type: "boolean", description: "Whether the product is published and live" },
        { name: "is_physical", type: "boolean", description: "Whether the product is physical" },
        { name: "refund_policy", type: "object", description: "The applicable refund policy, if any" },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://sahil.gumroad.com/l/pencil.json \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "api_version": 1,
  "id": "A-m3CDDC5dlrSdKZp0RFhA==",
  "permalink": "pencil",
  "name": "Pencil Icon PSD",
  "native_type": "digital",
  "url": "https://sahil.gumroad.com/l/pencil",
  "thumbnail_url": "https://public-files.gumroad.com/variants/abc/def",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-02-01T00:00:00Z",
  "seller": {
    "id": "G_-mnBf9b1j9A7a4ub4nFQ==",
    "name": "Sahil",
    "avatar_url": "https://public-files.gumroad.com/user/abc/avatar",
    "profile_url": "https://sahil.gumroad.com",
    "is_verified": true
  },
  "price_cents": 100,
  "currency_code": "usd",
  "price_formatted": "$1",
  "is_pay_what_you_want": false,
  "suggested_price_cents": null,
  "is_recurring_billing": false,
  "is_tiered_membership": false,
  "recurrences": null,
  "free_trial": null,
  "description_html": "<p>I made this for fun.</p>",
  "summary": "You'll get one PSD file.",
  "covers": [],
  "attributes": [{ "name": "Format", "value": "PSD" }],
  "ratings": { "count": 12, "average": 4.5, "percentages": [0, 0, 8, 34, 58] },
  "sales_count": null,
  "options": [],
  "quantity_remaining": null,
  "is_quantity_enabled": false,
  "is_sales_limited": false,
  "is_published": true,
  "is_physical": false,
  "refund_policy": { "title": "30-day money back guarantee", "fine_print": null, "updated_at": "2024-01-01" }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
