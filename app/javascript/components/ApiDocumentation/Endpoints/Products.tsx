import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { PRODUCT_FIELDS, PRODUCT_LIST_FIELDS } from "../responseFieldDefinitions";

const ProductResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      { name: "products", type: "array", description: "Array of product objects", children: PRODUCT_LIST_FIELDS },
      {
        name: "next_page_key",
        type: "string",
        description: "Opaque cursor to pass as page_key to fetch the next page",
        condition: "present when more results follow",
      },
      {
        name: "next_page_url",
        type: "string",
        description: "Path-relative URL (with query string) for the next page of results",
        condition: "present when more results follow",
      },
    ])}
  </ApiResponseFields>
);

const SingleProductResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      { name: "product", type: "object", description: "The product object", children: PRODUCT_FIELDS },
    ])}
  </ApiResponseFields>
);

const UpdateProductResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      { name: "product", type: "object", description: "The product object", children: PRODUCT_FIELDS },
      {
        name: "warning",
        type: "string",
        description:
          "Warning about offer codes that became invalid for the product (currency mismatch or below minimum price).",
        condition: "present when at least one offer code is invalid after the update",
      },
    ])}
  </ApiResponseFields>
);

export const GetProducts = () => (
  <ApiEndpoint
    method="get"
    path="/products"
    description="Retrieve all of the existing products for the authenticated user."
  >
    <ProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "products": [{
    "custom_permalink": null,
    "custom_receipt": null,
    "custom_summary": "You'll get one PSD file.",
    "custom_fields": [],
    "customizable_price": null,
    "description": "I made this for fun.",
    "deleted": false,
    "max_purchase_count": null,
    "name": "Pencil Icon PSD",
    "preview_url": null,
    "require_shipping": false,
    "subscription_duration": null,
    "published": true,
    "url": null, # Deprecated, always null
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "price": 100,
    "purchasing_power_parity_prices": {
      "US": 100,
      "IN": 50,
      "EC": 25
    },
    "currency": "usd",
    "short_url": "https://sahil.gumroad.com/l/pencil",
    "thumbnail_url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "tags": ["pencil", "icon"],
    "formatted_price": "$1",
    "file_info": {},
    "sales_count": 0, # available with the 'view_sales' or 'account' scope
    "sales_usd_cents": 0, # available with the 'view_sales' or 'account' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # 0 for tiered membership options; non-zero for non-membership options with a price bump
            "purchasing_power_parity_prices": { # present when PPP is enabled for the seller and the product has not opted out; null when price_difference is null
              "US": 200,
              "IN": 100,
              "EC": 50
            },
            "is_pay_what_you_want": false,
            "recurrence_prices": { # present for membership products; otherwise null
              "monthly": {
                "price_cents": 300,
                "suggested_price_cents": null, # may return number if is_pay_what_you_want is true
                "purchasing_power_parity_prices": {
                  "US": 400,
                  "IN": 200,
                  "EC": 100
                }
              }
            }
          }
        ]
      }
    ]
  }, {...}, {...}]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetProduct = () => (
  <ApiEndpoint method="get" path="/products/:id" description="Retrieve the details of a product.">
    <SingleProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "custom_permalink": null,
    "custom_receipt": null,
    "custom_summary": "You'll get one PSD file.",
    "custom_fields": [],
    "customizable_price": null,
    "description": "I made this for fun.",
    "deleted": false,
    "max_purchase_count": null,
    "name": "Pencil Icon PSD",
    "preview_url": null,
    "require_shipping": false,
    "subscription_duration": null,
    "published": true,
    "url": null, # Deprecated, always null
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "price": 100,
    "purchasing_power_parity_prices": {
      "US": 100,
      "IN": 50,
      "EC": 25
    },
    "currency": "usd",
    "short_url": "https://sahil.gumroad.com/l/pencil",
    "thumbnail_url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "tags": ["pencil", "icon"],
    "formatted_price": "$1",
    "file_info": {},
    "sales_count": 0, # available with the 'view_sales' or 'account' scope
    "sales_usd_cents": 0, # available with the 'view_sales' or 'account' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # 0 for tiered membership options; non-zero for non-membership options with a price bump
            "purchasing_power_parity_prices": { # present when PPP is enabled for the seller and the product has not opted out; null when price_difference is null
              "US": 200,
              "IN": 100,
              "EC": 50
            },
            "is_pay_what_you_want": false,
            "recurrence_prices": { # present for membership products; otherwise null
              "monthly": {
                "price_cents": 300,
                "suggested_price_cents": null, # may return number if is_pay_what_you_want is true
                "purchasing_power_parity_prices": {
                  "US": 400,
                  "IN": 200,
                  "EC": 100
                }
              }
            }
          }
        ]
      }
    ]
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateProduct = () => (
  <ApiEndpoint
    method="post"
    path="/products"
    description={
      <>
        Create a new product (as a draft). Requires the <code>edit_products</code> or <code>account</code> scope.
      </>
    }
  >
    <ApiParameters>
      <ApiParameter
        name="native_type"
        description='(optional, "digital" (default), "course", "ebook", "membership", "bundle", "coffee", "call", or "commission") cannot be changed later'
      />
      <ApiParameter name="name" description="(required)" />
      <ApiParameter name="description" description="(optional) HTML" />
      <ApiParameter name="custom_permalink" description="(optional)" />
      <ApiParameter name="price" description="(required) in the smallest currency unit (e.g. cents)" />
      <ApiParameter
        name="price_currency_type"
        description="(optional) ISO currency code; defaults to your account currency"
      />
      <ApiParameter
        name="subscription_duration"
        description='(optional, membership only, "monthly", "quarterly", "biannually", "yearly", or "every_two_years")'
      />
      <ApiParameter name="customizable_price" description="(optional, true or false) pay-what-you-want" />
      <ApiParameter name="suggested_price_cents" description="(optional)" />
      <ApiParameter name="max_purchase_count" description="(optional)" />
      <ApiParameter name="taxonomy_id" description="(optional)" />
      <ApiParameter name="tags" description="(optional) array of tag strings" />
      <ApiParameter name="custom_summary" description="(optional)" />
      <ApiParameter
        name="rich_content"
        description="(optional) array of { id, title, description } pages; description is a ProseMirror doc"
      />
      <ApiParameter
        name="files"
        description={
          <>
            (optional) array of files to attach — see <a href="#attach-file">Attaching to a product</a>
          </>
        }
      />
    </ApiParameters>
    <p>
      Cover images and thumbnails are attached separately via <code>POST /v2/products/:id/covers</code> and{" "}
      <code>POST /v2/products/:id/thumbnail</code>.
    </p>
    <SingleProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "native_type=digital" \\
  -d "name=Pencil Icon PSD" \\
  -d "price=100" \\
  -d "price_currency_type=usd" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "name": "Pencil Icon PSD",
    "price": 100,
    "currency": "usd",
    "published": false,
    "files": [],
    "covers": [],
    "main_cover_id": null,
    "rich_content": [],
    "has_same_rich_content_for_all_variants": true
# ...remaining product fields
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateProduct = () => (
  <ApiEndpoint
    method="put"
    path="/products/:id"
    description={
      <>
        Update an existing product. Send only the fields you want to change. Sending <code>files</code>,{" "}
        <code>tags</code>, or <code>rich_content</code> replaces the entire collection. Requires the{" "}
        <code>edit_products</code> or <code>account</code> scope.
      </>
    }
  >
    <ApiParameters>
      <ApiParameter name="name" description="(optional)" />
      <ApiParameter name="description" description="(optional) HTML" />
      <ApiParameter name="custom_permalink" description="(optional)" />
      <ApiParameter
        name="price"
        description="(optional) in the smallest currency unit; not allowed for tiered memberships — use the variant endpoints to manage tier pricing"
      />
      <ApiParameter name="price_currency_type" description="(optional) ISO currency code" />
      <ApiParameter name="customizable_price" description="(optional, true or false)" />
      <ApiParameter name="suggested_price_cents" description="(optional)" />
      <ApiParameter name="max_purchase_count" description="(optional)" />
      <ApiParameter name="quantity_enabled" description="(optional, true or false)" />
      <ApiParameter name="is_adult" description="(optional, true or false)" />
      <ApiParameter name="display_product_reviews" description="(optional, true or false)" />
      <ApiParameter name="should_show_sales_count" description="(optional, true or false)" />
      <ApiParameter name="taxonomy_id" description="(optional)" />
      <ApiParameter name="tags" description="(optional) array of tag strings; full replacement" />
      <ApiParameter name="custom_receipt" description="(optional)" />
      <ApiParameter name="custom_summary" description="(optional)" />
      <ApiParameter name="cover_ids" description="(optional) array of cover GUIDs in display order" />
      <ApiParameter name="rich_content" description="(optional) array of pages; full replacement" />
      <ApiParameter
        name="has_same_rich_content_for_all_variants"
        description="(optional, true or false) switches between product-level and per-variant rich content"
      />
      <ApiParameter
        name="files"
        description={
          <>
            (optional) array of files; full replacement — see <a href="#attach-file">Attaching to a product</a> for how
            to keep existing files
          </>
        }
      />
    </ApiParameters>
    <UpdateProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=Pencil Icon PSD v2" \\
  -d "max_purchase_count=100" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "name": "Pencil Icon PSD v2",
    "max_purchase_count": 100,
    "files": [
      {
        "id": "K7QmZw==",
        "name": "Pencil Icon",
        "size": 102400,
        "url": "https://api.gumroad.com/r/...signed...",
        "filetype": "psd",
        "filegroup": "image"
      }
    ]
# ...remaining product fields
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteProduct = () => (
  <ApiEndpoint method="delete" path="/products/:id" description="Permanently delete a product.">
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The product has been deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const EnableProduct = () => (
  <ApiEndpoint method="put" path="/products/:id/enable" description="Enable an existing product.">
    <SingleProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/enable \\
  -d "access_token=ACCESS_TOKEN" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "custom_permalink": null,
    "custom_receipt": null,
    "custom_summary": "You'll get one PSD file.",
    "custom_fields": [],
    "customizable_price": null,
    "description": "I made this for fun.",
    "deleted": false,
    "max_purchase_count": null,
    "name": "Pencil Icon PSD",
    "preview_url": null,
    "require_shipping": false,
    "subscription_duration": null,
    "published": true,
    "url": null, # Deprecated, always null
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "price": 100,
    "purchasing_power_parity_prices": {
      "US": 100,
      "IN": 50,
      "EC": 25
    },
    "currency": "usd",
    "short_url": "https://sahil.gumroad.com/l/pencil",
    "thumbnail_url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "tags": ["pencil", "icon"],
    "formatted_price": "$1",
    "file_info": {},
    "sales_count": 0, # available with the 'view_sales' or 'account' scope
    "sales_usd_cents": 0, # available with the 'view_sales' or 'account' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # 0 for tiered membership options; non-zero for non-membership options with a price bump
            "purchasing_power_parity_prices": { # present when PPP is enabled for the seller and the product has not opted out; null when price_difference is null
              "US": 200,
              "IN": 100,
              "EC": 50
            },
            "is_pay_what_you_want": false,
            "recurrence_prices": { # present for membership products; otherwise null
              "monthly": {
                "price_cents": 300,
                "suggested_price_cents": null, # may return number if is_pay_what_you_want is true
                "purchasing_power_parity_prices": {
                  "US": 400,
                  "IN": 200,
                  "EC": 100
                }
              }
            }
          }
        ]
      }
    ]
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DisableProduct = () => (
  <ApiEndpoint method="put" path="/products/:id/disable" description="Disable an existing product.">
    <SingleProductResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/disable \\
  -d "access_token=ACCESS_TOKEN" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "custom_permalink": null,
    "custom_receipt": null,
    "custom_summary": "You'll get one PSD file.",
    "custom_fields": [],
    "customizable_price": null,
    "description": "I made this for fun.",
    "deleted": false,
    "max_purchase_count": null,
    "name": "Pencil Icon PSD",
    "preview_url": null,
    "require_shipping": false,
    "subscription_duration": null,
    "published": false,
    "url": null, # Deprecated, always null
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "price": 100,
    "currency": "usd",
    "short_url": "https://sahil.gumroad.com/l/pencil",
    "thumbnail_url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "tags": ["pencil", "icon"],
    "formatted_price": "$1",
    "file_info": {},
    "sales_count": 0, # available with the 'view_sales' or 'account' scope
    "sales_usd_cents": 0, # available with the 'view_sales' or 'account' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # 0 for tiered membership options; non-zero for non-membership options with a price bump
            "is_pay_what_you_want": false,
            "recurrence_prices": { # present for membership products; otherwise null
              "monthly": {
                "price_cents": 300,
                "suggested_price_cents": null # may return number if is_pay_what_you_want is true
              }
            }
          }
        ]
      }
    ]
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
