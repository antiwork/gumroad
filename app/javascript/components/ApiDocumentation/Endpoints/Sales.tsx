import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

export const GetSales = () => (
  <ApiEndpoint
    method="get"
    path="/sales"
    description="Retrieves all of the successful sales by the authenticated user. Available with the 'view_sales' scope."
  >
    <ApiParameters>
      <ApiParameter
        name="after"
        description="(optional, date in form YYYY-MM-DD) - Only return sales after this date"
      />
      <ApiParameter
        name="before"
        description="(optional, date in form YYYY-MM-DD) - Only return sales before this date"
      />
      <ApiParameter name="product_id" description="(optional) - Filter sales by this product" />
      <ApiParameter name="email" description="(optional) - Filter sales by this email" />
      <ApiParameter name="order_id" description="(optional) - Filter sales by this Order ID" />
      <ApiParameter
        name="page_key"
        description="(optional) - A key representing a page of results. It is given in the response as `next_page_key`."
      />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/sales \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "before=2021-09-03" \\
  -d "after=2020-09-03" \\
  -d "product_id=bfi_30HLgGWL8H2wo_Gzlg==" \\
  -d "email=calvin@gumroad.com" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "next_page_url": "/v2/sales?page_key=20230119081040000000-123456&before=2021-09-03&after=2020-09-03&email=calvin%40gumroad.com",
  "next_page_key": "20230119081040000000-123456",
  "sales": [
    {
      "id": "B28UKN-dvxYabdavG97Y-Q==",
      "email": "calvin@gumroad.com",
      "seller_id": "kL0paVL2SdmJSYsNs-OCMg==",
      "timestamp": "about 2 months ago",
      "daystamp": " 5 Jan 2021 11:38 AM",
      "created_at": "2021-01-05T19:38:56Z",
      "product_name": "Pencil Icon PSD",
      "product_has_variants": true,
      "price": 1000,
      "gumroad_fee": 60,
      "subscription_duration": "monthly",
      "formatted_display_price": "$10 a month",
      "formatted_total_price": "$10 a month",
      "currency_symbol": "$",
      "amount_refundable_in_currency": "0",
      "product_id": "32-nPainqpLj1B_WIwVlMw==",
      "product_permalink": "XCBbJ",
      "partially_refunded": false,
      "chargedback": false,
      "purchase_email": "calvin@gumroad.com",
      "zip_code": "625003",
      "paid": false,
      "has_variants": true,
      "variants": {
        "Tier": "Premium"
      },
      "variants_and_quantity": "(Premium)",
      "has_custom_fields": true,
      "custom_fields": {"Twitter handle": "@gumroad"},
      "order_id": 524459995,
      "is_product_physical": false,
      "purchaser_id": "5530311507811",
      "is_recurring_billing": true,
      "can_contact": true,
      "is_following": false,
      "disputed": false,
      "dispute_won": false,
      "is_additional_contribution": false,
      "discover_fee_charged": false,
      "is_gift_sender_purchase": false,
      "is_gift_receiver_purchase": false,
      "referrer": "https://www.facebook.com",
      "card": {
        "visual": null,
        "type": null
      },
      "product_rating": null,
      "reviews_count": 0,
      "average_rating": 0,
      "subscription_id": "GazW4_NBcQy-o7Gjjng7lw==",
      "cancelled": false,
      "ended": false,
      "recurring_charge": false,
      "license_key": "83DB262A-C19D3B06-A5235A6B-8C079166",
      "license_id": "bEtKQ3Zu9SgNopem0-ZywA==",
      "license_disabled": false,
      "affiliate": {
        "email": "affiliate@example.com",
        "amount": "$2.50"
      },
      "quantity": 1
    }, {...}, {...}
  ]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetSale = () => (
  <ApiEndpoint
    method="get"
    path="/sales/:id"
    description="Retrieves the details of a sale by this user. Available with the 'view_sales' scope."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/sales/FO8TXN-dvxYabdavG97Y-Q== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "sale": {
    "id": "FO8TXN-dvxYabdavG97Y-Q==",
    "email": "calvin@gumroad.com",
    "seller_id": "kL0paVL2SdmJSYsNs-OCMg==",
    "timestamp": "about 2 months ago",
    "daystamp": " 5 Jan 2021 11:38 AM",
    "created_at": "2021-01-05T19:38:56Z",
    "product_name": "Pencil Icon PSD",
    "product_has_variants": true,
    "price": 1000,
    "gumroad_fee": 60,
    "subscription_duration": "monthly",
    "formatted_display_price": "$10 a month",
    "formatted_total_price": "$10 a month",
    "currency_symbol": "$",
    "amount_refundable_in_currency": "0",
    "product_id": "32-nPainqpLj1B_WIwVlMw==",
    "product_permalink": "XCBbJ",
    "partially_refunded": false,
    "chargedback": false,
    "purchase_email": "calvin@gumroad.com",
    "zip_code": "625003",
    "paid": false,
    "has_variants": true,
    "variants": {
      "Tier": "Premium"
    },
    "variants_and_quantity": "(Premium)",
    "has_custom_fields": false,
    "custom_fields": {},
    "order_id": 524459995,
    "is_product_physical": false,
    "purchaser_id": "5530311507811",
    "is_recurring_billing": true,
    "can_contact": true,
    "is_following": false,
    "disputed": false,
    "dispute_won": false,
    "is_additional_contribution": false,
    "discover_fee_charged": false,
    "is_gift_sender_purchase": false,
    "is_gift_receiver_purchase": false,
    "referrer": "direct",
    "card": {
      "visual": null,
      "type": null
    },
    "product_rating": null,
    "reviews_count": 0,
    "average_rating": 0,
    "subscription_id": "GazW4_NBcQy-o7Gjjng7lw==",
    "cancelled": false,
    "ended": false,
    "recurring_charge": false,
    "license_key": "83DB262A-C19D3B06-A5235A6B-8C079166",
    "license_id": "bEtKQ3Zu9SgNopem0-ZywA==",
    "license_disabled": false,
    "affiliate": {
      "email": "affiliate@example.com",
      "amount": "$2.50"
    },
    "offer_code": {
      "name": "FLAT50",
      "displayed_amount_off": "50%"
    },
    "quantity": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const MarkSaleAsShipped = () => (
  <ApiEndpoint
    method="put"
    path="/sales/:id/mark_as_shipped"
    description="Marks a sale as shipped. Available with the 'mark_sales_as_shipped' scope."
  >
    <ApiParameters>
      <ApiParameter name="tracking_url" description="(optional)" />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/sales/A-m3CDDC5dlrSdKZp0RFhA==/mark_as_shipped \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "tracking_url=https://www.shippingcompany.com/track/t123" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "sale": {
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "email": "calvin@gumroad.com",
    "seller_id": "RkCCaDkPPciPd9155vcaJg==",
    "timestamp": "about 1 month ago",
    "daystamp": "23 Jan 2021 12:23 PM",
    "created_at": "2021-01-23T20:23:21Z",
    "product_name": "classic physical product",
    "product_has_variants": true,
    "price": 2200,
    "gumroad_fee": 217,
    "formatted_display_price": "$22",
    "formatted_total_price": "$22",
    "currency_symbol": "$",
    "amount_refundable_in_currency": "22",
    "product_id": "CCQadnagaqfmKxdHaG5AKQ==",
    "product_permalink": "KHc",
    "refunded": false,
    "partially_refunded": false,
    "chargedback": false,
    "purchase_email": "calvin@gumroad.com",
    "full_name": "Sample Name",
    "street_address": "Sample street",
    "city": "New York",
    "state": "NY",
    "zip_code": "10001",
    "country": "United States",
    "country_iso2": "US",
    "paid": true,
    "has_variants": true,
    "variants": {
      "Format": "Premium"
    },
    "variants_and_quantity": "(Premium)",
    "has_custom_fields": false,
    "custom_fields": {},
    "order_id": 292372715,
    "is_product_physical": true,
    "purchaser_id": "6225273416381",
    "is_recurring_billing": false,
    "can_contact": true,
    "is_following": false,
    "disputed": false,
    "dispute_won": false,
    "is_additional_contribution": false,
    "discover_fee_charged": false,
    "is_gift_sender_purchase": false,
    "is_gift_receiver_purchase": false,
    "referrer": "direct",
    "card": {
      "visual": "**** **** **** 4242",
      "type": "visa"
    },
    "product_rating": null,
    "reviews_count": 0,
    "average_rating": 0,
    "shipped": true,
    "tracking_url": "https://www.shippingcompany.com/track/t123",
    "license_key": "740A36FE-80134D88-9998290C-1B30910C",
    "license_id": "mN7CdHiwHaR9FlxKvF-n-g==",
    "license_disabled": false,
    "sku_id": "6Oo2MGSSagZU5naeWaDaNQ==",
    "sku_external_id": "6Oo2MGSS1gaU5a5eWaDaNQ==",
    "affiliate": {
      "email": "affiliate@example.com",
      "amount": "$2.50"
    },
    "quantity": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const RefundSale = () => (
  <ApiEndpoint
    method="put"
    path="/sales/:id/refund"
    description="Refunds a sale. Available with the 'edit_sales' scope."
  >
    <ApiParameters>
      <ApiParameter
        name="amount_cents"
        description="(optional) - Amount in cents (in currency of the sale) to be refunded. If set, issue partial refund by this amount. If not set, issue full refund. You can issue multiple partial refunds per sale until it is fully refunded."
      />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/sales/A-m3CDDC5dlrSdKZp0RFhA==/refund \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "amount_cents=200" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "sale": {
    "id": "A-m3CDDC5dlrSdKZp0RFhA==",
    "email": "calvin@gumroad.com",
    "seller_id": "RkCCODaPPciPd9155vcQJg==",
    "timestamp": "about 1 month ago",
    "daystamp": "23 Jan 2021 10:24 AM",
    "created_at": "2021-01-23T18:24:07Z",
    "product_name": "Pencil Icon PSD",
    "product_has_variants": false,
    "price": 1000,
    "gumroad_fee": 115,
    "formatted_display_price": "$10",
    "formatted_total_price": "$10",
    "currency_symbol": "$",
    "amount_refundable_in_currency": "8",
    "product_id": "e7xqFa2WL0E-qJlQ4WYJxA==",
    "product_permalink": "RSE",
    "refunded": false,
    "partially_refunded": true,
    "chargedback": false,
    "purchase_email": "calvin@gumroad.com",
    "street_address": "",
    "city": "",
    "state": "AA",
    "zip_code": "67600",
    "paid": true,
    "has_variants": false,
    "variants_and_quantity": "",
    "has_custom_fields": false,
    "custom_fields": {},
    "order_id": 343932147,
    "is_product_physical": false,
    "is_recurring_billing": false,
    "can_contact": true,
    "is_following": false,
    "disputed": false,
    "dispute_won": false,
    "is_additional_contribution": false,
    "discover_fee_charged": false,
    "is_gift_sender_purchase": false,
    "is_gift_receiver_purchase": false,
    "referrer": "direct",
    "card": {
      "visual": "**** **** **** 4242",
      "type": "visa"
    },
    "product_rating": null,
    "reviews_count": 0,
    "average_rating": 0,
    "affiliate": {
      "email": "affiliate@example.com",
      "amount": "$2.50"
    },
    "quantity": 1
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const ResendReceipt = () => (
  <ApiEndpoint
    method="post"
    path="/sales/:id/resend_receipt"
    description="Resend the purchase receipt to the customer's email. Available with the 'edit_sales' scope."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/sales/A-m3CDDC5dlrSdKZp0RFhA==/resend_receipt \\
  -d "access_token=ACCESS_TOKEN" \\
  -X POST`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
