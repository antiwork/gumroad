# frozen_string_literal: true

GUMROAD_API_V2_METHODS = [
  {
    name: "Products",
    methods: [
      {
        type: :get,
        path: "/products",
        description: "Retrieve all of the existing products for the authenticated user.",
        response_layout: :products,
        curl_layout: :get_products
      },
      {
        type: :get,
        path: "/products/:id",
        description: "Retrieve the details of a product.",
        response_layout: :product,
        curl_layout: :get_product
      },
      {
        type: :delete,
        path: "/products/:id",
        description: "Permanently delete a product.",
        response_layout: :product_deleted,
        curl_layout: :delete_product
      },

      # product enable / disable

      {
        type: :put,
        path: "/products/:id/enable",
        description: "Enable an existing product.",
        response_layout: :product,
        curl_layout: :enable_product
      },
      {
        type: :put,
        path: "/products/:id/disable",
        description: "Disable an existing product.",
        response_layout: :disabled_product,
        curl_layout: :disable_product
      }
    ]
  },
  {
    name: "Variant categories",
    methods: [
      {
        type: :post,
        path: "/products/:product_id/variant_categories",
        description: "Create a new variant category on a product.",
        response_layout: :variant_category,
        curl_layout: :create_variant_category,
        parameters_layout: :create_variant_category
      },
      {
        type: :get,
        path: "/products/:product_id/variant_categories/:id",
        description: "Retrieve the details of a variant category of a product.",
        response_layout: :variant_category,
        curl_layout: :get_variant_category
      },
      {
        type: :put,
        path: "/products/:product_id/variant_categories/:id",
        description: "Edit a variant category of an existing product.",
        response_layout: :variant_category,
        curl_layout: :update_variant_category,
        parameters_layout: :create_variant_category
      },
      {
        type: :delete,
        path: "/products/:product_id/variant_categories/:id",
        description: "Permanently delete a variant category of a product.",
        response_layout: :variant_category_deleted,
        curl_layout: :delete_variant_category
      },
      {
        type: :get,
        path: "/products/:product_id/variant_categories",
        description: "Retrieve all of the existing variant categories of a product.",
        response_layout: :variant_categories,
        curl_layout: :get_variant_categories
      },
      {
        type: :post,
        path: "/products/:product_id/variant_categories/:variant_category_id/variants",
        description: "Create a new variant of a product.",
        response_layout: :variant,
        curl_layout: :create_variant,
        parameters_layout: :create_variant
      },
      {
        type: :get,
        path: "/products/:product_id/variant_categories/:variant_category_id/variants/:id",
        description: "Retrieve the details of a variant of a product.",
        response_layout: :variant,
        curl_layout: :get_variant
      },
      {
        type: :put,
        path: "/products/:product_id/variant_categories/:variant_category_id/variants/:id",
        description: "Edit a variant of an existing product.",
        response_layout: :variant,
        curl_layout: :update_variant,
        parameters_layout: :create_variant
      },
      {
        type: :delete,
        path: "/products/:product_id/variant_categories/:variant_category_id/variants/:id",
        description: "Permanently delete a variant of a product.",
        response_layout: :variant_deleted,
        curl_layout: :delete_variant
      },
      {
        type: :get,
        path: "/products/:product_id/variant_categories/:variant_category_id/variants",
        description: "Retrieve all of the existing variants in a variant category.",
        response_layout: :variants,
        curl_layout: :get_variants
      }
    ]
  },

  {
    name: "Offer codes",
    methods: [
      {
        type: :get,
        path: "/products/:product_id/offer_codes",
        description: "Retrieve all of the existing offer codes for a product. Either amount_cents or percent_off " \
                     "will be returned depending if the offer code is a fixed amount off or a percentage off. " \
                     "A universal offer code is one that applies to all products.",
        response_layout: :offer_codes,
        curl_layout: :get_offer_codes
      },
      {
        type: :get,
        path: "/products/:product_id/offer_codes/:id",
        description: "Retrieve the details of a specific offer code of a product",
        response_layout: :offer_code,
        curl_layout: :get_offer_code
      },
      {
        type: :post,
        path: "/products/:product_id/offer_codes",
        description: "Create a new offer code for a product. Default offer code is in cents. A universal offer code is one that applies to all products.",
        response_layout: :offer_code,
        curl_layout: :create_offer_code,
        parameters_layout: :create_offer_code
      },
      {
        type: :put,
        path: "/products/:product_id/offer_codes/:id",
        description: "Edit an existing product's offer code.",
        response_layout: :update_offer_code,
        curl_layout: :update_offer_code,
        parameters_layout: :update_offer_code
      },
      {
        type: :delete,
        path: "/products/:product_id/offer_codes/:id",
        description: "Permanently delete a product's offer code.",
        response_layout: :offer_code_deleted,
        curl_layout: :delete_offer_code
      }
    ]
  },
  {
    name: "Custom fields",
    methods: [
      {
        type: :get,
        path: "/products/:product_id/custom_fields",
        description: "Retrieve all of the existing custom fields for a product.",
        response_layout: :custom_fields,
        curl_layout: :get_custom_fields
      },
      {
        type: :post,
        path: "/products/:product_id/custom_fields",
        description: "Create a new custom field for a product.",
        response_layout: :custom_field,
        curl_layout: :create_custom_field,
        parameters_layout: :create_custom_field
      },
      {
        type: :put,
        path: "/products/:product_id/custom_fields/:name",
        description: "Edit an existing product's custom field.",
        response_layout: :custom_field,
        curl_layout: :update_custom_field,
        parameters_layout: :update_custom_field
      },
      {
        type: :delete,
        path: "/products/:product_id/custom_fields/:name",
        description: "Permanently delete a product's custom field.",
        response_layout: :custom_field_deleted,
        curl_layout: :delete_custom_field
      }
    ]
  },
  {
    name: "User",
    methods: [
      {
        type: :get,
        path: "/user",
        description: "Retrieve the user's data.",
        response_layout: :user,
        curl_layout: :get_user
      }
    ]
  },
  {
    name: "Resource subscriptions",
    methods: [
      {
        type: :put,
        path: "/resource_subscriptions",
        description: "Subscribe to a resource. Currently there are 8 supported resource names - \"sale\", \"refund\", \"dispute\", \"dispute_won\", \"cancellation\", \"subscription_updated\", \"subscription_ended\", and \"subscription_restarted\".</p>" \
                     "<p><strong>sale</strong>" \
                     " - When subscribed to this resource, you will be notified of the user's sales with an HTTP POST to your post_url. The format of the POST is described on the <a href='/ping'>Gumroad Ping</a> page.</p>" \
                     "<p><strong>refund</strong>" \
                     " - When subscribed to this resource, you will be notified of refunds to the user's sales with an HTTP POST to your post_url. The format of the POST is same as described on the <a href='/ping'>Gumroad Ping</a> page.</p>" \
                     "<p><strong>dispute</strong>" \
                     " - When subscribed to this resource, you will be notified of the disputes raised against user's sales with an HTTP POST to your post_url. The format of the POST is described on the <a href='/ping'>Gumroad Ping</a> page.</p>" \
                     "<p><strong>dispute_won</strong>" \
                     " - When subscribed to this resource, you will be notified of the sale disputes won by the user with an HTTP POST to your post_url. The format of the POST is described on the <a href='/ping'>Gumroad Ping</a> page.</p>" \
                     "<p><strong>cancellation</strong>" \
                     " - When subscribed to this resource, you will be notified of cancellations of the user's subscribers with an HTTP POST to your post_url.</p>" \
                     "<p><strong>subscription_updated</strong>" \
                     " - When subscribed to this resource, you will be notified when subscriptions to the user's products have been upgraded or downgraded with an HTTP POST to your post_url. A subscription is \"upgraded\" when the subscriber switches to an equally or more expensive tier and/or subscription duration. It is \"downgraded\" when the subscriber switches to a less expensive tier and/or subscription duration. In the case of a downgrade, this change will take effect at the end of the current billing period. (Note: This currently applies only to tiered membership products, not to all subscription products.)</p>"\
                     "<p><strong>subscription_ended</strong>" \
                     " - When subscribed to this resource, you will be notified when subscriptions to the user's products have ended with an HTTP POST to your post_url. These events include termination of a subscription due to: failed payment(s); cancellation; or a subscription of fixed duration ending. Notifications are sent at the time the subscription has officially ended, not, for example, at the time cancellation is requested.</p>" \
                     "<p><strong>subscription_restarted</strong>" \
                     " - When subscribed to this resource, you will be notified when subscriptions to the user's products have been restarted with an HTTP POST to your post_url. A subscription is \"restarted\" when the subscriber restarts their subscription after previously terminating it.</p>" \
                     "<p>
                        <span>In each POST request, Gumroad sends these parameters:</span><br>
                        <strong>subscription_id</strong>: id of the subscription<br>
                        <strong>product_id</strong>: id of the product<br>
                        <strong>product_name</strong>: name of the product<br>
                        <strong>user_id</strong>: user id of the subscriber<br>
                        <strong>user_email</strong>: email address of the subscriber<br>
                        <strong>purchase_ids</strong>: array of charge ids belonging to this subscription<br>
                        <strong>created_at</strong>: timestamp when subscription was created<br>
                        <strong>charge_occurrence_count</strong>: number of charges made for this subscription<br>
                        <strong>recurrence</strong>: subscription duration - monthly/quarterly/biannually/yearly/every_two_years<br>
                        <strong>free_trial_ends_at</strong>: timestamp when free trial ends, if free trial is enabled for the membership<br>
                        <strong>custom_fields</strong>: custom fields from the original purchase<br>
                        <strong>license_key</strong>: license key from the original purchase
                      </p>
                      <p>
                        <em>For \"cancellation\" resource:</em><br>
                        <strong>cancelled</strong>: true if subscription has been cancelled, otherwise false<br>
                        <strong>cancelled_at</strong>: timestamp at which subscription will be cancelled<br>
                        <strong>cancelled_by_admin</strong>: true if subscription was been cancelled by admin, otherwise not present<br>
                        <strong>cancelled_by_buyer</strong>: true if subscription was been cancelled by buyer, otherwise not present<br>
                        <strong>cancelled_by_seller</strong>: true if subscription was been cancelled by seller, otherwise not present<br>
                        <strong>cancelled_due_to_payment_failures</strong>: true if subscription was been cancelled automatically because of payment failure, otherwise not present
                      </p>
                      <p>
                        <em>For \"subscription_updated\" resource:</em><br>
                        <strong>type</strong>: \"upgrade\" or \"downgrade\"<br>
                        <strong>effective_as_of</strong>: timestamp at which the change went or will go into effect<br>
                        <strong>old_plan</strong>: tier, subscription duration, price, and quantity of the subscription before the change<br>
                        <strong>new_plan</strong>: tier, subscription duration, price, and quantity of the subscription after the change
                      </p>
<figure class=\"code\">
  <figcaption>Example</figcaption><pre tabindex=\"0\">{
  ...
  type: \"upgrade\",
  effective_as_of: \"2021-02-23T16:31:44Z\",
  old_plan: {
    tier: { id: \"G_-mnBf9b1j9A7a4ub4nFQ==\", name: \"Basic tier\" },
    recurrence: \"monthly\",
    price_cents: \"1000\",
    quantity: 1
  },
  new_plan: {
    tier: { id: \"G_-mnBf9b1j9A7a4ub4nFQ==\", name: \"Basic tier\" },
    recurrence: \"yearly\",
    price_cents: \"12000\",
    quantity: 2
  }
}</pre></figure><p></p>
                      <p>
                        <em>For \"subscription_ended\" resource:</em><br>
                        <strong>ended_at</strong>: timestamp at which the subscription ended<br>
                        <strong>ended_reason</strong>: the reason for the subscription ending (\"cancelled\", \"failed_payment\", or \"fixed_subscription_period_ended\")
                      </p>
                      <p>
                        <em>For \"subscription_restarted\" resource:</em><br>
                        <strong>restarted_at</strong>: timestamp at which the subscription was restarted<br>
                      ",
        response_layout: :resource_subscription,
        curl_layout: :create_resource_subscription
      },
      {
        type: :get,
        path: "/resource_subscriptions",
        description: "Show all active subscriptions of user for the input resource.",
        response_layout: :resource_subscriptions,
        curl_layout: :get_resource_subscriptions,
        parameters_layout: :get_resource_subscriptions
      },
      {
        type: :delete,
        path: "/resource_subscriptions/:resource_subscription_id",
        description: "Unsubscribe from a resource.",
        response_layout: :resource_subscription_deleted,
        curl_layout: :delete_resource_subscription
      }
    ]
  },
  {
    name: "Sales",
    methods: [
      {
        type: :get,
        path: "/sales",
        description: "Retrieves all of the successful sales by the authenticated user. Available with the 'view_sales' scope.",
        response_layout: :sales,
        curl_layout: :get_sales,
        parameters_layout: :get_sales
      },
      {
        type: :get,
        path: "/sales/:id",
        description: "Retrieves the details of a sale by this user. Available with the 'view_sales' scope.",
        response_layout: :sale,
        curl_layout: :get_sale
      },
      {
        type: :put,
        path: "/sales/:id/mark_as_shipped",
        description: "Marks a sale as shipped. Available with the 'mark_sales_as_shipped' scope.",
        response_layout: :sale_shipped,
        curl_layout: :mark_sale_as_shipped,
        parameters_layout: :mark_sale_as_shipped
      },
      {
        type: :put,
        path: "/sales/:id/refund",
        description: "Refunds a sale. Available with the 'refund_sales' scope.",
        response_layout: :sale_refunded,
        curl_layout: :refund_sale,
        parameters_layout: :refund_sale
      }
    ]
  },
  {
    name: "Subscribers",
    methods: [
      {
        type: :get,
        path: "/products/:product_id/subscribers",
        description: "Retrieves all of the active subscribers for one of the authenticated user's products. Available with the 'view_sales' scope" \
                     "<p>A subscription is terminated if any of <strong>failed_at</strong>, <strong>ended_at</strong>, or <strong>cancelled_at</strong> timestamps are populated and are in the past.</p>" \
                     "<p>A subscription's <strong>status</strong> can be one of: <strong>alive</strong>, <strong>pending_cancellation</strong>, <strong>pending_failure</strong>, <strong>failed_payment</strong>, <strong>fixed_subscription_period_ended</strong>, <strong>cancelled</strong>.</p>",
        response_layout: :subscribers,
        curl_layout: :get_subscribers,
        parameters_layout: :get_subscribers
      },
      {
        type: :get,
        path: "/subscribers/:id",
        description: "Retrieves the details of a subscriber to this user's product. Available with the 'view_sales' scope.",
        response_layout: :subscriber,
        curl_layout: :get_subscriber
      }
    ]
  },
  {
    name: "Licenses",
    methods: [
      {
        type: :post,
        path: "/licenses/verify",
        description: "Verify a license",
        response_layout: :license,
        curl_layout: :verify_license,
        parameters_layout: :verify_license
      },
      {
        type: :put,
        path: "/licenses/enable",
        description: "Enable a license",
        response_layout: :license,
        curl_layout: :enable_license,
        parameters_layout: :enable_disable_license
      },
      {
        type: :put,
        path: "/licenses/disable",
        description: "Disable a license",
        response_layout: :license,
        curl_layout: :disable_license,
        parameters_layout: :enable_disable_license
      },
      {
        type: :put,
        path: "/licenses/decrement_uses_count",
        description: "Decrement the uses count of a license",
        response_layout: :license,
        curl_layout: :decrement_uses_count,
        parameters_layout: :decrement_uses_count
      }
    ]
  },
  {
    name: "Payouts",
    methods: [
      {
        type: :get,
        path: "/payouts",
        description: "Retrieves all of the payouts for the authenticated user. Available with the 'view_payouts' scope.",
        response_layout: :payouts,
        curl_layout: :get_payouts,
        parameters_layout: :get_payouts
      },
      {
        type: :get,
        path: "/payouts/:id",
        description: "Retrieves the details of a specific payout by this user. Available with the 'view_payouts' scope.",
        response_layout: :payout,
        curl_layout: :get_payout
      }
    ]
  }
].freeze
