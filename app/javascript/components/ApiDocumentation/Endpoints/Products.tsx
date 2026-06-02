import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { CATEGORY_FIELDS, PRODUCT_FIELDS, PRODUCT_LIST_FIELDS } from "../responseFieldDefinitions";

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

const CategoriesResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      { name: "categories", type: "array", description: "Flat list of product categories", children: CATEGORY_FIELDS },
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
          "Warning about offer codes that became invalid for the product, or custom HTML that has no buy element.",
        condition: "present when there is an advisory warning after the update",
      },
    ])}
  </ApiResponseFields>
);

const CustomHtmlDocumentation = () => (
  <div id="custom-html" className="grid gap-4">
    <h4>Custom HTML landing pages</h4>
    <p>
      A product can have one custom HTML landing page, stored in its <code>custom_html</code> field. While it's set and
      the product is published, buyers see it instead of the default product page. Authenticate with a Bearer token that
      has the <code>edit_products</code> scope.
    </p>
    <ul>
      <li>
        <code>GET /v2/products/:id</code> returns the <code>custom_html</code> field.
      </li>
      <li>
        <code>PUT /v2/products/:id</code> sets it; send <code>null</code> or an empty string to clear it.
      </li>
      <li>
        <code>POST /v2/products/:id/preview_custom_html</code> returns the sanitized HTML and a sanitization report
        without saving — use it to iterate before you publish.
      </li>
      <li>
        Both <code>PUT</code> and preview return a <code>sanitization_report</code> listing what was stripped.
      </li>
      <li>
        Both <code>PUT</code> and preview return a top-level <code>warning</code> if the custom HTML has no{" "}
        <code>data-gumroad-action="buy"</code> element or <code>gumroad:checkout</code> postMessage.
      </li>
      <li>
        A successful <code>PUT</code> also returns <code>previous_custom_html</code> (the prior value, for one-step
        rollback) and the live <code>landing_url</code>.
      </li>
      <li>Only the latest version is stored — there's no history, so keep your source under version control.</li>
      <li>The HTML is capped at 500,000 characters.</li>
      <li>
        Rate limits per token: 30 <code>PUT</code>s/min, 60 previews/min.
      </li>
    </ul>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/<permalink> \\
  -X PUT \\
  -H "Authorization: Bearer <user_api_token>" \\
  -H "Content-Type: application/json" \\
  -d '{"custom_html":"<main><h1>My landing page</h1></main>"}'`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad products page preview <permalink> ./landing.html
gumroad products page publish <permalink> ./landing.html`}
    </CodeSnippet>
    <p>
      Your HTML is sanitized — disallowed tags and attributes are stripped — then served inside a sandboxed iframe (
      <code>sandbox="allow-scripts allow-forms"</code>).
    </p>
    <p>It can:</p>
    <ul>
      <li>Run inline JavaScript for animations, scroll effects, sticky headers, and modals.</li>
      <li>Load scripts from the Tailwind, jsDelivr, and unpkg CDNs.</li>
      <li>Load fonts from Google Fonts and Bunny Fonts.</li>
      <li>Load images and media from Gumroad only — e.g. your product's covers and thumbnail.</li>
      <li>Submit forms in-page with JavaScript.</li>
    </ul>
    <p>It can't:</p>
    <ul>
      <li>Read your Gumroad cookies or session — it runs on an opaque origin.</li>
      <li>Touch or navigate the parent page, or open popups.</li>
      <li>
        Make <code>fetch</code>, <code>XHR</code>, or WebSocket requests (<code>connect-src 'none'</code>).
      </li>
      <li>Load images or media from any non-Gumroad host.</li>
      <li>
        Submit forms to external URLs — off-site <code>action</code> attributes are stripped.
      </li>
    </ul>
    <p>
      Every external load is restricted to Gumroad's CDN (images and media) or the named font and script CDNs above, so
      the page has no arbitrary-host network channel — it can't beacon data off to a server you control.
    </p>
    <h5>Live values and buy buttons</h5>
    <p>
      Mark elements with data attributes that Gumroad fills in server-side so the page always shows current values and a
      working checkout button:
    </p>
    <ul>
      <li>
        <code>data-gumroad-field="name|price|description"</code> — the element's contents are replaced with the
        product's current value (HTML-escaped).
      </li>
      <li>
        <code>data-gumroad-action="buy"</code> — wires the element up to launch the Gumroad checkout. Works on any tag (
        <code>&lt;a&gt;</code>, <code>&lt;button&gt;</code>, <code>&lt;div&gt;</code>).
      </li>
    </ul>
    <p>
      For products with selection state, set the choice directly on the buy element. Invalid values silently fall back
      to the product defaults — they won't break the page.
    </p>
    <ul>
      <li>
        <code>data-gumroad-option="&lt;variant name&gt;"</code> — products with variants/versions/tiers.
      </li>
      <li>
        <code>data-gumroad-quantity="&lt;integer&gt;"</code> — products with quantity enabled.
      </li>
      <li>
        <code>data-gumroad-price="&lt;decimal&gt;"</code> — pay-what-you-want products; major units (e.g.{" "}
        <code>"9.99"</code>).
      </li>
      <li>
        <code>data-gumroad-recurrence="monthly|quarterly|biannually|yearly|every_two_years"</code> —
        membership/subscription products.
      </li>
    </ul>
    <CodeSnippet caption="Example buy buttons">
      {`<a data-gumroad-action="buy">Buy now</a>
<a data-gumroad-action="buy" data-gumroad-option="Pro" data-gumroad-recurrence="yearly">Buy Pro – $99/year</a>
<button data-gumroad-action="buy" data-gumroad-quantity="2">Buy 2 seats</button>`}
    </CodeSnippet>
  </div>
);

export const GetCategories = () => (
  <ApiEndpoint
    method="get"
    path="/categories"
    description="Retrieve the full product category list. Use a category's path as the category parameter when creating or updating products."
  >
    <CategoriesResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/categories \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "categories": [
    {
      "id": 123,
      "name": "figma",
      "label": "Figma",
      "path": "design/ui-and-web/figma",
      "parent_id": 122
    }
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
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
    <CodeSnippet caption="Gumroad CLI">gumroad products list</CodeSnippet>
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
    "taxonomy_id": 123,
    "category": "design/ui-and-web/figma",
    "category_label": "Figma",
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
    <CodeSnippet caption="Gumroad CLI">gumroad products show A-m3CDDC5dlrSdKZp0RFhA==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "custom_permalink": null,
    "custom_receipt": null,
    "custom_summary": "You'll get one PSD file.",
    "custom_html": null,
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
    "taxonomy_id": 123,
    "category": "design/ui-and-web/figma",
    "category_label": "Figma",
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
      <ApiParameter
        name="category"
        description='(optional) full category path from GET /v2/categories, e.g. "design/ui-and-web/figma"; cannot be sent with taxonomy_id'
      />
      <ApiParameter
        name="taxonomy_id"
        description="(optional) numeric category ID; alias for category, cannot be sent with category"
      />
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
  -d "category=design/ui-and-web/figma" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad products create --type digital \\
  --name "Pencil Icon PSD" \\
  --price 1.00 \\
  --currency usd`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "product": {
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "name": "Pencil Icon PSD",
    "price": 100,
    "currency": "usd",
    "taxonomy_id": 123,
    "category": "design/ui-and-web/figma",
    "category_label": "Figma",
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
      <ApiParameter
        name="category"
        description='(optional) full category path from GET /v2/categories, e.g. "design/ui-and-web/figma"; cannot be sent with taxonomy_id'
      />
      <ApiParameter
        name="taxonomy_id"
        description="(optional) numeric category ID; alias for category, cannot be sent with category"
      />
      <ApiParameter name="tags" description="(optional) array of tag strings; full replacement" />
      <ApiParameter name="custom_receipt" description="(optional)" />
      <ApiParameter name="custom_summary" description="(optional)" />
      <ApiParameter
        name="custom_html"
        description="(optional) custom landing page HTML; null or empty string clears it"
      />
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
  -d "category=design/ui-and-web/figma" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad products update A-m3CDDC5dlrSdKZp0RFhA== \\
  --name "Pencil Icon PSD v2" \\
  --max-purchase-count 100`}
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
    <CustomHtmlDocumentation />
  </ApiEndpoint>
);

export const DeleteProduct = () => (
  <ApiEndpoint method="delete" path="/products/:id" description="Permanently delete a product.">
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad products delete A-m3CDDC5dlrSdKZp0RFhA==</CodeSnippet>
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
    <CodeSnippet caption="Gumroad CLI">gumroad products publish A-m3CDDC5dlrSdKZp0RFhA==</CodeSnippet>
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
    <CodeSnippet caption="Gumroad CLI">gumroad products unpublish A-m3CDDC5dlrSdKZp0RFhA==</CodeSnippet>
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
