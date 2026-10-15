import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";
import { ApiResponseFields, renderFields } from "../ApiResponseFields";
import { OFFER_CODE_FIELDS } from "../responseFieldDefinitions";

const OfferCodeResponseFields = () => (
  <ApiResponseFields>
    {renderFields([
      { name: "success", type: "boolean", description: "Whether the request succeeded" },
      {
        name: "offer_code",
        type: "object",
        description: "The offer code object",
        children: OFFER_CODE_FIELDS,
      },
    ])}
  </ApiResponseFields>
);

const SaleParameters = () => (
  <>
    <ApiParameter
      name="auto_apply"
      description="(optional, true or false) Apply a universal discount automatically on product pages and profile cards. Creation defaults to false."
    />
    <ApiParameter
      name="sale_label"
      description='(optional) Plain text, up to 32 characters. Automatic sales display "Sale" when this field is blank. Disabling automatic application clears the label.'
    />
    <ApiParameter
      name="valid_at"
      description="(optional) Start time as an RFC 3339 timestamp with a time zone, such as 2026-11-27T00:00:00-05:00. Seconds must be 00 through 59."
    />
    <ApiParameter
      name="expires_at"
      description="(optional) End time in the same format. An end requires a start. The end must follow the start."
    />
  </>
);

const SaleRules = () => (
  <p>
    Automatic application requires a universal discount. Only one non-deleted discount per seller can have automatic
    application enabled, including scheduled and expired discounts. Disable the current automatic discount before
    enabling another. A product's own default discount takes priority while buyers can redeem it. Fixed discounts apply
    only to products with the same currency. These settings do not change the product's base price.
  </p>
);

export const GetOfferCodes = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/offer_codes"
    description="Retrieve all of the existing offer codes for a product. Either amount_cents or percent_off will be returned depending if the offer code is a fixed amount off or a percentage off. A universal offer code is one that applies to all products."
  >
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        {
          name: "offer_codes",
          type: "array",
          description: "Array of offer code objects",
          children: OFFER_CODE_FIELDS,
        },
      ])}
    </ApiResponseFields>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">gumroad offer-codes list --product A-m3CDDC5dlrSdKZp0RFhA==</CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_codes": [{
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": null,
    "universal": false,
    "auto_apply": false,
    "sale_label": null,
    "valid_at": null,
    "expires_at": null,
    "times_used": 1
  }, {
    "id": "l5C1XQfr2TG3WXcGY7-r-g==",
    "name": "HALFOFF",
    "percent_off": 50,
    "max_purchase_count": null,
    "universal": false,
    "auto_apply": false,
    "sale_label": null,
    "valid_at": null,
    "expires_at": null,
    "times_used": 1
  }, {...}, {...}]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetOfferCode = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/offer_codes/:id"
    description="Retrieve the details of a specific offer code of a product"
  >
    <OfferCodeResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=1OFF" \\
  -d "amount_cents=100" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad offer-codes view bfi_30HLgGWL8H2wo_Gzlg== \\
  --product A-m3CDDC5dlrSdKZp0RFhA==`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_code": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": null,
    "universal": false,
    "auto_apply": false,
    "sale_label": null,
    "valid_at": null,
    "expires_at": null,
    "times_used": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const CreateOfferCode = () => (
  <ApiEndpoint
    method="post"
    path="/products/:product_id/offer_codes"
    description="Create a new offer code for a product. Default offer code is in cents. A universal offer code is one that applies to all products."
  >
    <ApiParameters>
      <ApiParameter name="name" description="(the coupon code used at checkout)" />
      <ApiParameter name="amount_off" />
      <ApiParameter name="offer_type" description='(optional, "cents" or "percent") Default: "cents"' />
      <ApiParameter name="max_purchase_count" description="(optional)" />
      <ApiParameter
        name="minimum_amount_cents"
        description="(optional) Minimum order total in cents required for the offer code to apply"
      />
      <ApiParameter name="universal" description="(optional, true or false) Default: false" />
      <SaleParameters />
    </ApiParameters>
    <SaleRules />
    <OfferCodeResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=1OFF" \\
  -d "amount_off=100" \\
  -d "offer_type=cents" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad offer-codes create --product A-m3CDDC5dlrSdKZp0RFhA== \\
  --name 1OFF \\
  --amount 1.00`}
    </CodeSnippet>
    <CodeSnippet caption="Scheduled automatic sale">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=BLACKFRIDAY30" \\
  -d "offer_type=percent" \\
  -d "amount_off=30" \\
  -d "universal=true" \\
  -d "auto_apply=true" \\
  --data-urlencode "sale_label=Black Friday" \\
  --data-urlencode "valid_at=2026-11-27T00:00:00-05:00" \\
  --data-urlencode "expires_at=2026-12-01T00:00:00-05:00" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_code": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": null,
    "minimum_amount_cents": null,
    "universal": false,
    "auto_apply": false,
    "sale_label": null,
    "valid_at": null,
    "expires_at": null,
    "times_used": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateOfferCode = ({ storeWide = false }: { storeWide?: boolean }) => (
  <ApiEndpoint
    method="put"
    path={storeWide ? "/offer_codes/:id" : "/products/:product_id/offer_codes/:id"}
    description="Edit one of your store's discount codes. This endpoint requires edit_products."
  >
    <ApiParameters>
      <ApiParameter name="max_purchase_count" description="(optional)" />
      <ApiParameter
        name="minimum_amount_cents"
        description="(optional) Minimum order total in cents required for the offer code to apply"
      />
      <SaleParameters />
    </ApiParameters>
    <SaleRules />
    <p>
      Omitted fields stay unchanged. Set a date to null in JSON, or an empty string in a form, to clear it. Clear both
      dates to remove the schedule. Set auto_apply to false to stop automatic application. Buyers can still redeem the
      code manually within its validity period. Update cannot change universal or the discount amount.
    </p>
    <OfferCodeResponseFields />
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/${storeWide ? "offer_codes/bfi_30HLgGWL8H2wo_Gzlg==" : "products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes/bfi_30HLgGWL8H2wo_Gzlg=="} \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "max_purchase_count=10" \\
  -X PUT`}
    </CodeSnippet>
    {!storeWide ? (
      <CodeSnippet caption="Gumroad CLI">
        {`gumroad offer-codes update bfi_30HLgGWL8H2wo_Gzlg== \\
  --product A-m3CDDC5dlrSdKZp0RFhA== \\
  --max-purchase-count 10`}
      </CodeSnippet>
    ) : null}
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_code": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": 10,
    "universal": false,
    "auto_apply": false,
    "sale_label": null,
    "valid_at": null,
    "expires_at": null
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetStoreOfferCodes = () => (
  <ApiEndpoint
    method="get"
    path="/offer_codes"
    description="List all non-deleted discount codes in your store, including scheduled and expired codes. This endpoint requires view_sales or edit_products."
  >
    <p>
      Use this endpoint to find the current automatic sale, including codes that exclude a product or use another
      currency. Set auto_apply=true to find the current automatic sale without reading all codes. Results contain 10
      codes per page, newest first. Pass next_page_key as page_key until the response has no next_page_key.
    </p>
    <ApiParameters>
      <ApiParameter
        name="auto_apply"
        description="(optional) Filter by automatic application: true or false. Omit this field to list all codes."
      />
      <ApiParameter
        name="page_key"
        description="(optional) The next_page_key from the previous response. Keep the same auto_apply filter."
      />
    </ApiParameters>
    <ApiResponseFields>
      {renderFields([
        { name: "success", type: "boolean", description: "Whether the request succeeded" },
        { name: "offer_codes", type: "array", description: "The store's discount codes", children: OFFER_CODE_FIELDS },
        {
          name: "next_page_key",
          type: "string",
          description: "Cursor for the next page",
          condition: "present when more codes remain",
        },
        {
          name: "next_page_url",
          type: "string",
          description: "Relative URL for the next page",
          condition: "present when more codes remain",
        },
      ])}
    </ApiResponseFields>
  </ApiEndpoint>
);

export const GetStoreOfferCode = () => (
  <ApiEndpoint
    method="get"
    path="/offer_codes/:id"
    description="Read one of your store's discount codes by its ID. This endpoint requires view_sales or edit_products."
  >
    <OfferCodeResponseFields />
  </ApiEndpoint>
);

export const UpdateStoreOfferCode = () => <UpdateOfferCode storeWide />;

export const DeleteOfferCode = () => (
  <ApiEndpoint
    method="delete"
    path="/products/:product_id/offer_codes/:id"
    description="Permanently delete a product's offer code."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Gumroad CLI">
      {`gumroad offer-codes delete bfi_30HLgGWL8H2wo_Gzlg== \\
  --product A-m3CDDC5dlrSdKZp0RFhA==`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The offer_code has been deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
