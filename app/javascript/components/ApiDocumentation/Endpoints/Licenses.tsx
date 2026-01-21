import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

export const VerifyLicense = () => (
  <ApiEndpoint method="post" path="/licenses/verify" description="Verify a license">
    <ApiParameters>
      <ApiParameter name="product_id" description="(the unique ID of the product, available on product's edit page)" />
      <ApiParameter name="license_key" description="(the license key provided by your customer)" />
      <ApiParameter name="increment_uses_count" description='("true"/"false", optional, default: "true")' />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/licenses/verify \\
  -d "product_id=32-nPAicqbLj8B_WswVlMw==" \\
  -d "license_key=A1B2C3D4-E5F60718-9ABCDEF0-1234ABCD" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "uses": 3,
  "purchase": {
    "seller_id": "kL0psVL2admJSYRNs-OCMg==",
    "product_id": "32-nPAicqbLj8B_WswVlMw==",
    "product_name": "licenses demo product",
    "permalink": "QMGY",
    "product_permalink": "https://sahil.gumroad.com/l/pencil",
    "email": "customer@example.com",
    "price": 0,
    "gumroad_fee": 0,
    "currency": "usd",
    "quantity": 1,
    "discover_fee_charged": false,
    "can_contact": true,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "order_number": 524459935,
    "sale_id": "FO8TXN-dbxYaBdahG97Y-Q==",
    "sale_timestamp": "2021-01-05T19:38:56Z",
    "purchaser_id": "5550321502811",
    "subscription_id": "GDzW4_aBdQc-o7Gbjng7lw==",
    "variants": "",
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "is_multiseat_license": false,
    "ip_country": "United States",
    "recurrence": "monthly",
    "is_gift_receiver_purchase": false,
    "refunded": false,
    "disputed": false,
    "dispute_won": false,
    "id": "FO8TXN-dvaYbBbahG97a-Q==",
    "created_at": "2021-01-05T19:38:56Z",
    "custom_fields": [],
    "chargebacked": false, # purchase was refunded, non-subscription product only
    "subscription_ended_at": null, # subscription was ended, subscription product only
    "subscription_cancelled_at": null, # subscription was cancelled, subscription product only
    "subscription_failed_at": null # we were unable to charge the subscriber's card
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const EnableLicense = () => (
  <ApiEndpoint method="put" path="/licenses/enable" description="Enable a license">
    <ApiParameters>
      <ApiParameter name="product_id" description="(the unique ID of the product, available on product's edit page)" />
      <ApiParameter name="license_key" description="(the license key provided by your customer)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/licenses/enable \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "product_id=32-nPAicqbLj8B_WswVlMw==" \\
  -d "license_key=A1B2C3D4-E5F60718-9ABCDEF0-1234ABCD" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "uses": 3,
  "purchase": {
    "seller_id": "kL0psVL2admJSYRNs-OCMg==",
    "product_id": "32-nPAicqbLj8B_WswVlMw==",
    "product_name": "licenses demo product",
    "permalink": "QMGY",
    "product_permalink": "https://sahil.gumroad.com/l/pencil",
    "email": "customer@example.com",
    "price": 0,
    "gumroad_fee": 0,
    "currency": "usd",
    "quantity": 1,
    "discover_fee_charged": false,
    "can_contact": true,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "order_number": 524459935,
    "sale_id": "FO8TXN-dbxYaBdahG97Y-Q==",
    "sale_timestamp": "2021-01-05T19:38:56Z",
    "purchaser_id": "5550321502811",
    "subscription_id": "GDzW4_aBdQc-o7Gbjng7lw==",
    "variants": "",
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "is_multiseat_license": false,
    "ip_country": "United States",
    "recurrence": "monthly",
    "is_gift_receiver_purchase": false,
    "refunded": false,
    "disputed": false,
    "dispute_won": false,
    "id": "FO8TXN-dvaYbBbahG97a-Q==",
    "created_at": "2021-01-05T19:38:56Z",
    "custom_fields": [],
    "chargebacked": false, # purchase was refunded, non-subscription product only
    "subscription_ended_at": null, # subscription was ended, subscription product only
    "subscription_cancelled_at": null, # subscription was cancelled, subscription product only
    "subscription_failed_at": null # we were unable to charge the subscriber's card
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DisableLicense = () => (
  <ApiEndpoint method="put" path="/licenses/disable" description="Disable a license">
    <ApiParameters>
      <ApiParameter name="product_id" description="(the unique ID of the product, available on product's edit page)" />
      <ApiParameter name="license_key" description="(the license key provided by your customer)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/licenses/disable \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "product_id=32-nPAicqbLj8B_WswVlMw==" \\
  -d "license_key=A1B2C3D4-E5F60718-9ABCDEF0-1234ABCD" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "uses": 3,
  "purchase": {
    "seller_id": "kL0psVL2admJSYRNs-OCMg==",
    "product_id": "32-nPAicqbLj8B_WswVlMw==",
    "product_name": "licenses demo product",
    "permalink": "QMGY",
    "product_permalink": "https://sahil.gumroad.com/l/pencil",
    "email": "customer@example.com",
    "price": 0,
    "gumroad_fee": 0,
    "currency": "usd",
    "quantity": 1,
    "discover_fee_charged": false,
    "can_contact": true,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "order_number": 524459935,
    "sale_id": "FO8TXN-dbxYaBdahG97Y-Q==",
    "sale_timestamp": "2021-01-05T19:38:56Z",
    "purchaser_id": "5550321502811",
    "subscription_id": "GDzW4_aBdQc-o7Gbjng7lw==",
    "variants": "",
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "is_multiseat_license": false,
    "ip_country": "United States",
    "recurrence": "monthly",
    "is_gift_receiver_purchase": false,
    "refunded": false,
    "disputed": false,
    "dispute_won": false,
    "id": "FO8TXN-dvaYbBbahG97a-Q==",
    "created_at": "2021-01-05T19:38:56Z",
    "custom_fields": [],
    "chargebacked": false, # purchase was refunded, non-subscription product only
    "subscription_ended_at": null, # subscription was ended, subscription product only
    "subscription_cancelled_at": null, # subscription was cancelled, subscription product only
    "subscription_failed_at": null # we were unable to charge the subscriber's card
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DecrementUsesCount = () => (
  <ApiEndpoint method="put" path="/licenses/decrement_uses_count" description="Decrement the uses count of a license">
    <ApiParameters>
      <ApiParameter name="product_id" description="(the unique ID of the product, available on product's edit page)" />
      <ApiParameter name="license_key" description="(the license key provided by your customer)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/licenses/decrement_uses_count \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "product_id=32-nPAicqbLj8B_WswVlMw==" \\
  -d "license_key=A1B2C3D4-E5F60718-9ABCDEF0-1234ABCD" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "uses": 3,
  "purchase": {
    "seller_id": "kL0psVL2admJSYRNs-OCMg==",
    "product_id": "32-nPAicqbLj8B_WswVlMw==",
    "product_name": "licenses demo product",
    "permalink": "QMGY",
    "product_permalink": "https://sahil.gumroad.com/l/pencil",
    "email": "customer@example.com",
    "price": 0,
    "gumroad_fee": 0,
    "currency": "usd",
    "quantity": 1,
    "discover_fee_charged": false,
    "can_contact": true,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "order_number": 524459935,
    "sale_id": "FO8TXN-dbxYaBdahG97Y-Q==",
    "sale_timestamp": "2021-01-05T19:38:56Z",
    "purchaser_id": "5550321502811",
    "subscription_id": "GDzW4_aBdQc-o7Gbjng7lw==",
    "variants": "",
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "is_multiseat_license": false,
    "ip_country": "United States",
    "recurrence": "monthly",
    "is_gift_receiver_purchase": false,
    "refunded": false,
    "disputed": false,
    "dispute_won": false,
    "id": "FO8TXN-dvaYbBbahG97a-Q==",
    "created_at": "2021-01-05T19:38:56Z",
    "custom_fields": [],
    "chargebacked": false, # purchase was refunded, non-subscription product only
    "subscription_ended_at": null, # subscription was ended, subscription product only
    "subscription_cancelled_at": null, # subscription was cancelled, subscription product only
    "subscription_failed_at": null # we were unable to charge the subscriber's card
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const RotateLicense = () => (
  <ApiEndpoint
    method="put"
    path="/licenses/rotate"
    description="Rotate a license key. The old license key will no longer be valid."
  >
    <ApiParameters>
      <ApiParameter name="product_id" description="(the unique ID of the product, available on product's edit page)" />
      <ApiParameter name="license_key" description="(the license key provided by your customer)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/licenses/rotate \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "product_id=32-nPAicqbLj8B_WswVlMw==" \\
  -d "license_key=A1B2C3D4-E5F60718-9ABCDEF0-1234ABCD" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "uses": 3,
  "purchase": {
    "seller_id": "kL0psVL2admJSYRNs-OCMg==",
    "product_id": "32-nPAicqbLj8B_WswVlMw==",
    "product_name": "licenses demo product",
    "permalink": "QMGY",
    "product_permalink": "https://sahil.gumroad.com/l/pencil",
    "email": "customer@example.com",
    "price": 0,
    "gumroad_fee": 0,
    "currency": "usd",
    "quantity": 1,
    "discover_fee_charged": false,
    "can_contact": true,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "order_number": 524459935,
    "sale_id": "FO8TXN-dbxYaBdahG97Y-Q==",
    "sale_timestamp": "2021-01-05T19:38:56Z",
    "purchaser_id": "5550321502811",
    "subscription_id": "GDzW4_aBdQc-o7Gbjng7lw==",
    "variants": "",
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "is_multiseat_license": false,
    "ip_country": "United States",
    "recurrence": "monthly",
    "is_gift_receiver_purchase": false,
    "refunded": false,
    "disputed": false,
    "dispute_won": false,
    "id": "FO8TXN-dvaYbBbahG97a-Q==",
    "created_at": "2021-01-05T19:38:56Z",
    "custom_fields": [],
    "chargebacked": false, # purchase was refunded, non-subscription product only
    "subscription_ended_at": null, # subscription was ended, subscription product only
    "subscription_cancelled_at": null, # subscription was cancelled, subscription product only
    "subscription_failed_at": null # we were unable to charge the subscriber's card
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
