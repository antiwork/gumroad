import React from "react";

import CodeSnippet from "$app/components/ui/CodeSnippet";

import { ApiEndpoint } from "../ApiEndpoint";
import { ApiParameter, ApiParameters } from "../ApiParameters";

const ResourceSubscriptionsDescription = () => (
  <>
    <p>
      Subscribe to a resource. Currently there are 8 supported resource names - "sale", "refund", "dispute",
      "dispute_won", "cancellation", "subscription_updated", "subscription_ended", and "subscription_restarted".
    </p>

    <div className="flex flex-col gap-4">
      <p>
        <strong>sale</strong> - When subscribed to this resource, you will be notified of the user's sales with an HTTP
        POST to your post_url. The format of the POST is described on the <a href="/ping">Gumroad Ping</a> page.
      </p>

      <p>
        <strong>refund</strong> - When subscribed to this resource, you will be notified of refunds to the user's sales
        with an HTTP POST to your post_url. The format of the POST is same as described on the{" "}
        <a href="/ping">Gumroad Ping</a> page.
      </p>

      <p>
        <strong>dispute</strong> - When subscribed to this resource, you will be notified of the disputes raised against
        user's sales with an HTTP POST to your post_url. The format of the POST is described on the{" "}
        <a href="/ping">Gumroad Ping</a> page.
      </p>

      <p>
        <strong>dispute_won</strong> - When subscribed to this resource, you will be notified of the sale disputes won
        by the user with an HTTP POST to your post_url. The format of the POST is described on the{" "}
        <a href="/ping">Gumroad Ping</a> page.
      </p>

      <p>
        <strong>cancellation</strong> - When subscribed to this resource, you will be notified of cancellations of the
        user's subscribers with an HTTP POST to your post_url.
      </p>
      <p>
        <strong>subscription_updated</strong> - When subscribed to this resource, you will be notified when
        subscriptions to the user's products have been upgraded or downgraded with an HTTP POST to your post_url. A
        subscription is "upgraded" when the subscriber switches to an equally or more expensive tier and/or subscription
        duration. It is "downgraded" when the subscriber switches to a less expensive tier and/or subscription duration.
        In the case of a downgrade, this change will take effect at the end of the current billing period. (Note: This
        currently applies only to tiered membership products, not to all subscription products.)
      </p>

      <p>
        <strong>subscription_ended</strong> - When subscribed to this resource, you will be notified when subscriptions
        to the user's products have ended with an HTTP POST to your post_url. These events include termination of a
        subscription due to: failed payment(s); cancellation; or a subscription of fixed duration ending. Notifications
        are sent at the time the subscription has officially ended, not, for example, at the time cancellation is
        requested.
      </p>

      <p>
        <strong>subscription_restarted</strong> - When subscribed to this resource, you will be notified when
        subscriptions to the user's products have been restarted with an HTTP POST to your post_url. A subscription is
        "restarted" when the subscriber restarts their subscription after previously terminating it.
      </p>
      <p>In each POST request, Gumroad sends these parameters:</p>
      <p>
        <strong>subscription_id</strong>: id of the subscription
        <br />
        <strong>product_id</strong>: id of the product
        <br />
        <strong>product_name</strong>: name of the product
        <br />
        <strong>user_id</strong>: user id of the subscriber
        <br />
        <strong>user_email</strong>: email address of the subscriber
        <br />
        <strong>purchase_ids</strong>: array of charge ids belonging to this subscription
        <br />
        <strong>created_at</strong>: timestamp when subscription was created
        <br />
        <strong>charge_occurrence_count</strong>: number of charges made for this subscription
        <br />
        <strong>recurrence</strong>: subscription duration - monthly/quarterly/biannually/yearly/every_two_years
        <br />
        <strong>free_trial_ends_at</strong>: timestamp when free trial ends, if free trial is enabled for the membership
        <br />
        <strong>custom_fields</strong>: custom fields from the original purchase
        <br />
        <strong>license_key</strong>: license key from the original purchase
      </p>

      <p>
        <em>For "cancellation" resource:</em>
        <br />
        <strong>cancelled</strong>: true if subscription has been cancelled, otherwise false
        <br />
        <strong>cancelled_at</strong>: timestamp at which subscription will be cancelled
        <br />
        <strong>cancelled_by_admin</strong>: true if subscription was been cancelled by admin, otherwise not present
        <br />
        <strong>cancelled_by_buyer</strong>: true if subscription was been cancelled by buyer, otherwise not present
        <br />
        <strong>cancelled_by_seller</strong>: true if subscription was been cancelled by seller, otherwise not present
        <br />
        <strong>cancelled_due_to_payment_failures</strong>: true if subscription was been cancelled automatically
        because of payment failure, otherwise not present
      </p>

      <p>
        <em>For "subscription_updated" resource:</em>
        <br />
        <strong>type</strong>: "upgrade" or "downgrade"
        <br />
        <strong>effective_as_of</strong>: timestamp at which the change went or will go into effect
        <br />
        <strong>old_plan</strong>: tier, subscription duration, price, and quantity of the subscription before the
        change
        <br />
        <strong>new_plan</strong>: tier, subscription duration, price, and quantity of the subscription after the change
      </p>

      <p>Example</p>
      <pre>
        {`{
  ...
  type: "upgrade",
  effective_as_of: "2021-02-23T16:31:44Z",
  old_plan: {
    tier: { id: "G_-mnBf9b1j9A7a4ub4nFQ==", name: "Basic tier" },
    recurrence: "monthly",
    price_cents: "1000",
    quantity: 1
  },
  new_plan: {
    tier: { id: "G_-mnBf9b1j9A7a4ub4nFQ==", name: "Basic tier" },
    recurrence: "yearly",
    price_cents: "12000",
    quantity: 2
  }
}`}
      </pre>

      <p>
        <em>For "subscription_ended" resource:</em>
        <br />
        <strong>ended_at</strong>: timestamp at which the subscription ended
        <br />
        <strong>ended_reason</strong>: the reason for the subscription ending ("cancelled", "failed_payment", or
        "fixed_subscription_period_ended")
      </p>

      <p>
        <em>For "subscription_restarted" resource:</em>
        <br />
        <strong>restarted_at</strong>: timestamp at which the subscription was restarted
      </p>
    </div>
  </>
);

export const CreateResourceSubscription = () => (
  <ApiEndpoint method="put" path="/resource_subscriptions" description={<ResourceSubscriptionsDescription />}>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/resource_subscriptions \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "resource_name=sale" \\
  -d "post_url=https://postatmebro.com" \\
  -X PUT`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "resource_subscription": {
    "id": "G_-mnBf9b1j9A7a4ub4nFQ==",
    "resource_name": "sale",
    "post_url": "https://postatmebro.com"
  }
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const GetResourceSubscriptions = () => (
  <ApiEndpoint
    method="get"
    path="/resource_subscriptions"
    description="Show all active subscriptions of user for the input resource."
  >
    <ApiParameters>
      <ApiParameter
        name="resource_name"
        description='(string) - Currently there are 8 supported values - "sale", "refund", "dispute", "dispute_won", "cancellation", "subscription_updated", "subscription_ended", and "subscription_restarted".'
      />
    </ApiParameters>
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/resource_subscriptions \\
  -d "access_token=ACCESS_TOKEN" \\
  -d "resource_name=sale" \\
  -X GET`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "resource_subscriptions": [{
    "id": "G_-mnBf9b1j9A7a4ub4nFQ==",
    "resource_name": "sale",
    "post_url": "https://postatmebro.com"
  }, {...}, {...}]
}`}
    </CodeSnippet>
  </ApiEndpoint>
);

export const DeleteResourceSubscription = () => (
  <ApiEndpoint
    method="delete"
    path="/resource_subscriptions/:resource_subscription_id"
    description="Unsubscribe from a resource."
  >
    <CodeSnippet caption="cURL example">
      {`curl https://api.gumroad.com/v2/resource_subscriptions/G_-mnBf9b1j9A7a4ub4nFQ== \\
  -d "access_token=ACCESS_TOKEN" \\
  -X DELETE`}
    </CodeSnippet>
    <CodeSnippet caption="Example response:">
      {`{
  "success": true,
  "message": "The resource_subscription was deleted successfully."
}`}
    </CodeSnippet>
  </ApiEndpoint>
);
