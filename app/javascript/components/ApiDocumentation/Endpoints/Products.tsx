import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";

export const GetProducts = () => (
  <ApiEndpoint
    method="get"
    path="/products"
    description="Retrieve all of the existing products for the authenticated user."
  >
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
    "url": "http://sahillavingia.com/pencil.psd",
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
    "sales_count": "0", # available with the 'view_sales' scope
    "sales_usd_cents": "0", # available with the 'view_sales' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # set for non-membership product options
            "purchasing_power_parity_prices": { # set for non-membership product options
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
    "url": "http://sahillavingia.com/pencil.psd",
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
    "sales_count": "0", # available with the 'view_sales' scope
    "sales_usd_cents": "0", # available with the 'view_sales' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # set for non-membership product options
            "purchasing_power_parity_prices": { # set for non-membership product options
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
    "url": "http://sahillavingia.com/pencil.psd",
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
    "sales_count": "0", # available with the 'view_sales' scope
    "sales_usd_cents": "0", # available with the 'view_sales' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # set for non-membership product options
            "purchasing_power_parity_prices": { # set for non-membership product options
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
    "url": "http://sahillavingia.com/pencil.psd",
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "price": 100,
    "currency": "usd",
    "short_url": "https://sahil.gumroad.com/l/pencil",
    "thumbnail_url": "https://public-files.gumroad.com/variants/72iaezqqthnj1350mdc618namqki/f2f9c6fc18a80b8bafa38f3562360c0e42507f1c0052dcb708593f7efa3bdab8",
    "tags": ["pencil", "icon"],
    "formatted_price": "$1",
    "file_info": {},
    "view_count": "0", # available with the 'view_sales' scope
    "sales_count": "0", # available with the 'view_sales' scope
    "sales_usd_cents": "0", # available with the 'view_sales' scope
    "is_tiered_membership": true,
    "recurrences": ["monthly"], # if is_tiered_membership is true, renders list of available subscription durations; otherwise null
    "variants": [
      {
        "title": "Tier",
        "options": [
          {
            "name": "First Tier",
            "price_difference": 0, # set for non-membership product options
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
