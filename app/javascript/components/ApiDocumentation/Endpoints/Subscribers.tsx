import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

export const GetSubscribers = () => (
  <ApiEndpoint
    method="get"
    path="/products/:product_id/subscribers"
    description={
      <>
        <p>
          Retrieves all of the active subscribers for one of the authenticated user's products. Available with the
          'view_sales' scope
        </p>
        <p>
          A subscription is terminated if any of failed_at, ended_at, or cancelled_at timestamps are populated and are
          in the past.
        </p>
        <p>
          A subscription's status can be one of: alive, pending_cancellation, pending_failure, failed_payment,
          fixed_subscription_period_ended, cancelled.
        </p>
      </>
    }
  >
    <ApiParameters>
      <ApiParameter name="email" description="(optional) - Filter subscribers by this email" />
      <ApiParameter
        name="paginated"
        description='(optional, default: "false") - Set to "true" to limit the number of subscribers returned to 100.'
      />
      <ApiParameter
        name="page_key"
        description="(optional) - A key representing a page of results. It is given in the paginated response of the previous page as `next_page_key`."
      />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/products/0ssD7adjRklGBjS5cwlWPq==/subscribers \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "paginated=true" \\
  -d "email=calvin@gumroad.com" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success":true,
  "next_page_url": "/v2/products/0ssD7adjRklGBjS5cwlWPq==/subscribers?page_key=20241004235318372406-857093235&email=calvin%40gumroad.com",
  "next_page_key": "20241004235318372406-857093235",
  "subscribers": [{
    "id": "P5ppE6H8XIjy2JSCgUhbAw==",
    "product_id": "0ssD7adjRklGBjS5cwlWPq==",
    "product_name":"Pencil Icon PSD",
    "user_id": "3523953790232",
    "user_email":"calvin@gumroad.com",
    "purchase_ids": [O4pjE6H8XNjy2JSCgKhbAw==],
    "created_at": "2015-06-30T17:38:04Z",
    "user_requested_cancellation_at": null,
    "charge_occurrence_count": null,
    "recurrence": "monthly",
    "cancelled_at": null,
    "ended_at": null,
    "failed_at": null,
    "free_trial_ends_at": null,
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "status": "alive"
  }]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetSubscriber = () => (
  <ApiEndpoint
    method="get"
    path="/subscribers/:id"
    description="Retrieves the details of a subscriber to this user's product. Available with the 'view_sales' scope."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/subscribers/P5ppE6H8XIjy2JSCgUhbAw== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success":true,
  "subscribers": {
    "id": "P5ppE6H8XIjy2JSCgUhbAw==",
    "product_id": "0ssD7adjRklGBjS5cwlWPq==",
    "product_name":"Pencil Icon PSD",
    "user_id": "3523953790232",
    "user_email":"calvin@gumroad.com",
    "purchase_ids": [O4pjE6H8XNjy2JSCgKhbAw==],
    "created_at": "2015-06-30T17:38:04Z",
    "user_requested_cancellation_at": null,
    "charge_occurrence_count": null,
    "recurrence": "monthly",
    "cancelled_at": null,
    "ended_at": null,
    "failed_at": null,
    "free_trial_ends_at": null,
    "license_key": "85DB562A-C11D4B06-A2335A6B-8C079166",
    "status": "alive"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
