import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

export const GetOfferCodes = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/offer_codes"
    description="Retrieve all of the existing offer codes for a product. Either amount_cents or percent_off will be returned depending if the offer code is a fixed amount off or a percentage off. A universal offer code is one that applies to all products."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_codes": [{
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": null,
    "universal": false,
    "times_used": 1
  }, {
    "id": "l5C1XQfr2TG3WXcGY7-r-g==",
    "name": "HALFOFF",
    "percent_off": 50,
    "max_purchase_count": null,
    "universal": false,
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
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=1OFF" \\
  -d "amount_cents=100" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_code": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": null,
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
      <ApiParameter name="universal" description="(optional, true or false) Default: false" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "name=1OFF" \\
  -d "amount_off=100" \\
  -d "offer_type=cents" \\
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
    "times_used": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const UpdateOfferCode = () => (
  <ApiEndpoint
    method="put"
    path="/products/:product_id/offer_codes/:id"
    description="Edit an existing product's offer code."
  >
    <ApiParameters>
      <ApiParameter name="offer_code" />
      <ApiParameter name="max_purchase_count" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/A-m3CDDC5dlrSdKZp0RFhA==/offer_codes/bfi_30HLgGWL8H2wo_Gzlg== \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "max_purchase_count=10" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "offer_code": {
    "id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "name": "1OFF",
    "amount_cents": 100,
    "max_purchase_count": 10,
    "universal": false
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

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
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The offer_code has been deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
