import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";

// Public, unauthenticated, read-only creator profile JSON.
// Returns the same public information a visitor sees on a creator's profile
// page — name, bio, avatar, social links, and their published products — so
// anyone can build directories, storefronts, and widgets that stay in sync.
// Never exposes seller-private fields (email, balance, tokens, tax info).
export const GetPublicProfile = () => (
  <ApiEndpoint
    method="get"
    path="/:username.json"
    customUrl="https://[username].gumroad.com/.json"
    description={
      <>
        Retrieve a creator's public profile — no authentication required. Returns the creator's display information
        (name, bio, avatar, social links) along with the list of their published products. Append{" "}
        <code className="inline-code">.json</code> to any creator profile URL. Never exposes seller-private fields such
        as email, balance, or tax information.
      </>
    }
  >
    <ApiResponseFields>
      {renderFields([
        { name: "api_version", type: "number", description: "The schema version of this public payload" },
        { name: "id", type: "string", description: "The creator's unique external ID" },
        { name: "username", type: "string", description: "The creator's username (their profile subdomain)" },
        { name: "name", type: "string", description: "The creator's display name (falls back to username)" },
        { name: "bio", type: "string", description: "The creator's profile bio, if set; otherwise null" },
        { name: "avatar_url", type: "string", description: "The creator's avatar image URL" },
        { name: "profile_url", type: "string", description: "The full public profile URL" },
        { name: "subdomain", type: "string", description: "The creator's profile subdomain" },
        { name: "twitter_handle", type: "string", description: "The creator's Twitter/X handle, if set" },
        { name: "is_verified", type: "boolean", description: "Whether the creator is verified" },
        {
          name: "products",
          type: "array",
          description:
            "The creator's published products (id, permalink, name, native_type, url, thumbnail_url, price_cents, currency_code, price_formatted, is_pay_what_you_want, is_recurring_billing, ratings, sales_count). Capped at 100, newest first.",
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://sahil.gumroad.com/.json \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "api_version": 1,
  "id": "G_-mnBf9b1j9A7a4ub4nFQ==",
  "username": "sahil",
  "name": "Sahil",
  "bio": "I make tools for creators.",
  "avatar_url": "https://public-files.gumroad.com/user/abc/avatar",
  "profile_url": "https://sahil.gumroad.com",
  "subdomain": "sahil.gumroad.com",
  "twitter_handle": "shl",
  "is_verified": true,
  "products": [
    {
      "id": "A-m3CDDC5dlrSdKZp0RFhA==",
      "permalink": "pencil",
      "name": "Pencil Icon PSD",
      "native_type": "digital",
      "url": "https://sahil.gumroad.com/l/pencil",
      "thumbnail_url": "https://public-files.gumroad.com/variants/abc/def",
      "price_cents": 100,
      "currency_code": "usd",
      "price_formatted": "$1",
      "is_pay_what_you_want": false,
      "is_recurring_billing": false,
      "ratings": { "count": 12, "average": 4.5 },
      "sales_count": null
    }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
