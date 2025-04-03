# frozen_string_literal: true

require "spec_helper"

describe PostToPingEndpointsWorker, :vcr do
  before do
    @user = create(:user, notification_endpoint: "http://notification.com")
    @product = create(:product, user: @user, unique_permalink: "Iqw", price_cents: 500)

    @default_params = lambda do |purchase|
      link = purchase.link

      {
        seller_id: ObfuscateIds.encrypt(link.user.id),
        product_id: ObfuscateIds.encrypt(link.id),
        product_name: link.name,
        permalink: link.unique_permalink,
        product_permalink: link.long_url,
        short_product_id: link.unique_permalink,
        email: purchase.email,
        price: purchase.price_cents,
        gumroad_fee: purchase.fee_cents,
        currency: purchase.link.price_currency_type,
        quantity: purchase.quantity,
        is_gift_receiver_purchase: false,
        order_number: purchase.external_id_numeric,
        sale_id: purchase.external_id,
        sale_timestamp: purchase.created_at.as_json,
        resource_name: ResourceSubscription::SALE_RESOURCE_NAME,
        refunded: false,
        disputed: false,
        dispute_won: false,
        discover_fee_charged: purchase.was_discover_fee_charged,
        can_contact: purchase.can_contact,
        referrer: purchase.referrer,
        card: {
          bin: nil,
          expiry_month: purchase.card_expiry_month,
          expiry_year: purchase.card_expiry_year,
          type: purchase.card_type,
          visual: purchase.card_visual
        }
      }
    end


    @http_double = double
    allow(@http_double).to receive(:success?).and_return(true)
    allow(@http_double).to receive(:code).and_return(200)
  end

  it "enqueues job PostToIndividualPingEndpointWorker with the correct parameters" do
    purchase = create(:purchase, link: @product, price_cents: 500)
    PostToPingEndpointsWorker.new.perform(purchase.id, "{\"first_param\":\"test\",\"second_param\":\"flkdjaf\"}")
    params = @default_params.call(purchase).merge(
      url_params: "{\"first_param\":\"test\",\"second_param\":\"flkdjaf\"}"
    )

    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes a license key if the purchase has one" do
    link = create(:product, user: @user, unique_permalink: "lic", is_licensed: true)
    purchase = create(:purchase, link:, price_cents: 500)
    create(:license, link:, purchase:)
    PostToPingEndpointsWorker.new.perform(purchase.id, nil)
    params = @default_params.call(purchase).merge(
      product_name: link.name,
      permalink: "lic",
      product_permalink: link.long_url,
      license_key: purchase.license.serial
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes gift related information if the purchase is a gift" do
    gift = create(:gift, gifter_email: "gifter@gumroad.com", giftee_email: "giftee@gumroad.com", link: @product)
    gifter_purchase = create(:purchase, link: @product, price_cents: 500, email: "gifter@gumroad.com", is_gift_sender_purchase: true)
    giftee_purchase = create(:purchase, link: @product,
                                        email: "giftee@gumroad.com",
                                        price_cents: 0,
                                        is_gift_receiver_purchase: true,
                                        purchase_state: "gift_receiver_purchase_successful")
    gift.gifter_purchase = gifter_purchase
    gift.giftee_purchase = giftee_purchase
    gift.mark_successful
    gift.save!
    PostToPingEndpointsWorker.new.perform(giftee_purchase.id, nil)
    params = @default_params.call(giftee_purchase).merge(
      email: "giftee@gumroad.com",
      price: 0,
      gift_price: 500,
      is_gift_receiver_purchase: true,
      gifter_email: gifter_purchase.email
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes a purchaser id if there is one for the purchase" do
    purchaser = create(:user)
    purchase = create(:purchase, link: @product, price_cents: 500, purchaser:)
    PostToPingEndpointsWorker.new.perform(purchase.id, "{\"first_param\":\"test\",\"second_param\":\"flkdjaf\"}")
    params = @default_params.call(purchase).merge(
      purchaser_id: purchaser.external_id,
      url_params: "{\"first_param\":\"test\",\"second_param\":\"flkdjaf\"}"
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes the sku id in the post if there's a sku" do
    @product.skus_enabled = true
    @product.is_physical = true
    @product.require_shipping = true
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)

    @product.save!
    purchase = create(:physical_purchase, link: @product, price_cents: 500)
    purchase.variant_attributes << create(:sku)

    PostToPingEndpointsWorker.new.perform(purchase.id, nil)
    params = @default_params.call(purchase).merge(
      full_name: "barnabas",
      street_address: "123 barnabas street",
      country: "United States",
      state: "CA",
      zip_code: "94114",
      city: "barnabasville",
      shipping_information: {
        full_name: "barnabas",
        street_address: "123 barnabas street",
        country: "United States",
        state: "CA",
        zip_code: "94114",
        city: "barnabasville"
      },
      sku_id: purchase.sku.external_id,
      variants: { "Version" => "Large" },
      shipping_rate: 0
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes the custom sku in the post if there's a sku" do
    @product.skus_enabled = true
    @product.is_physical = true
    @product.require_shipping = true
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)

    @product.save!
    purchase = create(:physical_purchase, link: @product, price_cents: 500)
    purchase.variant_attributes << create(:sku)
    Sku.last.update_attribute(:custom_sku, "CUSTOMIZE")

    PostToPingEndpointsWorker.new.perform(purchase.id, nil)
    params = @default_params.call(purchase).merge(
      full_name: "barnabas",
      street_address: "123 barnabas street",
      country: "United States",
      state: "CA",
      zip_code: "94114",
      city: "barnabasville",
      shipping_information: {
        full_name: "barnabas",
        street_address: "123 barnabas street",
        country: "United States",
        state: "CA",
        zip_code: "94114",
        city: "barnabasville"
      },
      sku_id: "CUSTOMIZE",
      original_sku_id: Sku.last.external_id,
      variants: { "Version" => "Large" },
      shipping_rate: 0
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  it "includes the sku id in the post if the product is sku-enabled and doesn't have a sku" do
    @product.skus_enabled = true
    @product.is_physical = true
    @product.require_shipping = true
    @product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)

    @product.save!
    purchase = create(:physical_purchase, link: @product, price_cents: 500)

    PostToPingEndpointsWorker.new.perform(purchase.id, nil)
    params = @default_params.call(purchase).merge(
      full_name: "barnabas",
      street_address: "123 barnabas street",
      country: "United States",
      state: "CA",
      zip_code: "94114",
      city: "barnabasville",
      shipping_information: {
        full_name: "barnabas",
        street_address: "123 barnabas street",
        country: "United States",
        state: "CA",
        zip_code: "94114",
        city: "barnabasville"
      },
      sku_id: purchase.sku_custom_name_or_external_id,
      shipping_rate: 0
    )
    expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
  end

  describe "shipping information" do
    it "makes a post with the correct body" do
      link = create(:product, user: @user, unique_permalink: "Klm", require_shipping: true)
      purchase = create(:purchase, link:, price_cents: 500, full_name: "Edgar Gumstein", street_address: "123 Gum Road",
                                   city: "Montgomery", state: "Alabama", country: "United States", zip_code: "12345")
      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: link.name,
        product_permalink: link.long_url,
        permalink: "Klm",
        shipping_information: {
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          city: "Montgomery",
          state: "Alabama",
          country: "United States",
          zip_code: "12345"
        },
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        city: "Montgomery",
        state: "Alabama",
        country: "United States",
        zip_code: "12345"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "quantity" do
    it "makes a post with the correct body" do
      link = create(:physical_product, user: @user, unique_permalink: "Klm", require_shipping: true)
      purchase = create(:purchase, link:, price_cents: 500, full_name: "Edgar Gumstein", street_address: "123 Gum Road",
                                   city: "Montgomery", state: "Alabama", country: "United States", zip_code: "12345", quantity: 5)
      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: link.name,
        product_permalink: link.long_url,
        permalink: "Klm",
        quantity: 5,
        shipping_information: {
          full_name: "Edgar Gumstein",
          street_address: "123 Gum Road",
          city: "Montgomery",
          state: "Alabama",
          country: "United States",
          zip_code: "12345"
        },
        full_name: "Edgar Gumstein",
        street_address: "123 Gum Road",
        city: "Montgomery",
        state: "Alabama",
        country: "United States",
        zip_code: "12345",
        shipping_rate: 0,
        sku_id: "pid_#{link.external_id}"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "buyer ip country" do
    it "makes a post with the correct body" do
      link = create(:product, user: @user, unique_permalink: "Klm")
      purchase = create(:purchase, link:, price_cents: 500, ip_country: "United States")
      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: link.name,
        product_permalink: link.long_url,
        permalink: "Klm",
        ip_country: "United States"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "custom_fields" do
    it "makes the request to the endpoint with the correct paramters" do
      purchase = create(
        :purchase,
        link: @product,
        price_cents: 500,
        purchase_custom_fields: [
          build(:purchase_custom_field, name: "pet_name", value: "woofy"),
          build(:purchase_custom_field, name: "species", value: "dog")
        ]
      )
      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        pet_name: "woofy",
        species: "dog",
        custom_fields: {
          "pet_name" => "woofy",
          "species" => "dog"
        }
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "offer_code" do
    it "makes request to the endpoint with the correct parameters" do
      purchase = create(:purchase, link: @product, price_cents: 500)
      offer_code = create(:offer_code, products: [@product], code: "thanks9")
      offer_code.purchases << purchase

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        offer_code: "thanks9"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "recurring charge" do
    it "makes request to endpoint with the correct parameters" do
      purchase = create(:purchase, link: @product, price_cents: 500)
      subscription = create(:subscription, link: @product)
      subscription.purchases << purchase

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        is_recurring_charge: true,
        recurrence: subscription.recurrence,
        subscription_id: subscription.external_id
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end
  end

  describe "refund resource" do
    it "does not send a ping to the user's notification_endpoint about sale refund", :sidekiq_inline do
      purchase = create(:purchase, link: @product, price_cents: 500, stripe_refunded: true)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME)
      expect(params[:refunded]).to be(true)

      expect(params[:refunded]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params)

      PostToPingEndpointsWorker.new.perform(purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME)
    end
  end

  describe "cancellation resource" do
    it "does not send a ping to the user's notification_endpoint about subscription cancellation", :sidekiq_inline do
      purchase = create(:membership_purchase, link: @product, price_cents: 500)
      subscription = create(:subscription, link: @product, cancelled_at: Time.current, user_requested_cancellation_at: Time.current)
      subscription.purchases << purchase
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

      expect(params[:cancelled]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, subscription.id)
    end
  end

  describe "resource subscription" do
    before do
      @product = create(:product, user: @user, unique_permalink: "abc")
      @app = create(:oauth_application, owner: create(:user))
      @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_sales")
      @resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user)
      @refunded_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                       resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME)
      @cancelled_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                        resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)
      @subscription_ended_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                                 resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)
      @subscription_restarted_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                                     resource_name: ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME)
      @subscription_updated_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                                   resource_name: ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME)
    end

    it "posts to the app's post url" do
      purchaser = create(:user)
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com", seller: @product.user, purchaser:)
      expect(purchase.purchaser).to eq purchaser
      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        purchaser_id: purchaser.external_id,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@resource_subscription.post_url, params, @resource_subscription.content_type)
    end

    it "posts affiliate_credit information to the app's post url" do
      @product.update!(price_cents: 500)
      @affiliate_user = create(:affiliate_user)
      @direct_affiliate = create(:direct_affiliate, affiliate_user: @affiliate_user, seller: @user, affiliate_basis_points: 1500, products: [@product])
      @purchase = create(:purchase_in_progress, link: @product, email: "ibuy@gumroad.com", price_cents: 500, purchase_state: "in_progress", affiliate: @direct_affiliate)
      @purchase.process!
      @purchase.update_balance_and_mark_successful!

      PostToPingEndpointsWorker.new.perform(@purchase.id, nil)

      params = @default_params.call(@purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com",
        affiliate_credit_amount_cents: 53,
        affiliate: @affiliate_user.form_email
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@resource_subscription.post_url, params, @resource_subscription.content_type)
    end

    it "posts to all apps' post urls and to the user's notification endpoint" do
      @user.update(notification_endpoint: "http://notification.com")
      another_app = create(:oauth_application, owner: create(:user), name: "another app")
      create("doorkeeper/access_token", application: another_app, resource_owner_id: @user.id, scopes: "view_sales")
      another_resource_subscription = create(:resource_subscription, oauth_application: another_app, user: @user, post_url: "http://preposterous.com")
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com")

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@resource_subscription.post_url, params, @resource_subscription.content_type)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(another_resource_subscription.post_url, params, another_resource_subscription.content_type)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@user.notification_endpoint, params, @user.notification_content_type)
    end

    it "does not post to the app's post url if the token is revoked" do
      @token.revoke
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com")

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      jobs = PostToIndividualPingEndpointWorker.jobs
      expect(jobs.size).to eq(1)
      expect(jobs.first["args"].first).to eq("http://notification.com")
    end

    it "does not post to the app's post url if the post url is invalid" do
      @resource_subscription.update!(post_url: "http://localhost/path")
      purchase = create(:purchase, link: @product)

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      expect(PostToIndividualPingEndpointWorker).to_not have_enqueued_sidekiq_job(@resource_subscription.post_url, anything, @resource_subscription.content_type)
    end

    it "does not post to the app's post url if the user hasn't given view_sales permissions to the app" do
      another_app = create(:oauth_application, owner: create(:user), name: "another app")
      create("doorkeeper/access_token", application: another_app, resource_owner_id: @user.id, scopes: "edit_products")
      create(:resource_subscription, oauth_application: another_app, user: @user, post_url: "http://preposterous.com")
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com")

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      jobs = PostToIndividualPingEndpointWorker.jobs
      expect(jobs.size).to eq(2)
      expect(jobs.first["args"].first).to eq(@resource_subscription.post_url)
      expect(jobs.second["args"].first).to eq("http://notification.com")
    end

    it "posts to the app's post url if the user has given multiple permissions to the app, including view_sales" do
      @token.revoke

      another_app = create(:oauth_application, owner: create(:user), name: "another app")
      create("doorkeeper/access_token", application: another_app, resource_owner_id: @user.id, scopes: "view_sales edit_products")
      another_resource_subscription = create(:resource_subscription, oauth_application: another_app, user: @user, post_url: "http://preposterous.com")
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com")

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(another_resource_subscription.post_url, params, another_resource_subscription.content_type)
    end

    it "posts to the app's post url even if the token is expired" do
      @token.update!(expires_in: -10.minutes)
      expect(@token.expired?).to be(true)
      purchase = create(:purchase, link: @product, price_cents: 500, email: "ibuy@gumroad.com")

      PostToPingEndpointsWorker.new.perform(purchase.id, nil)

      params = @default_params.call(purchase).merge(
        product_name: @product.name,
        product_permalink: @product.long_url,
        permalink: "abc",
        email: "ibuy@gumroad.com"
      )
      expect(PostToIndividualPingEndpointWorker).to have_enqueued_sidekiq_job(@resource_subscription.post_url, params, @resource_subscription.content_type)
    end

    it "posts sale refunded ping to the 'refunded' resource's post_url", :sidekiq_inline do
      purchase = create(:purchase, link: @product, price_cents: 500, stripe_refunded: true)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::REFUNDED_RESOURCE_NAME)

      expect(params[:refunded]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params.deep_stringify_keys)
      expect(HTTParty).to receive(:post).with(@refunded_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => @refunded_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(purchase.id, nil, ResourceSubscription::REFUNDED_RESOURCE_NAME)
    end

    it "posts subscription cancelled ping to the 'cancellation' resource's post_url", :sidekiq_inline do
      purchase = create(:membership_purchase, link: @product, price_cents: 500)
      subscription = create(:subscription, link: @product, cancelled_at: Time.current, user_requested_cancellation_at: Time.current)
      subscription.purchases << purchase
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)

      expect(params[:cancelled]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params.deep_stringify_keys)
      expect(HTTParty).to receive(:post).with(@cancelled_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => @cancelled_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::CANCELLED_RESOURCE_NAME, subscription.id)
    end

    it "posts subscription ended ping to the 'subscription_ended' resource's post_url", :sidekiq_inline do
      subscription = create(:subscription, link: @product, deactivated_at: Time.current, cancelled_at: Time.current)
      create(:membership_purchase, subscription:, link: @product)
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

      expect(params[:ended_reason]).to be_present
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params.deep_stringify_keys)
      expect(HTTParty).to receive(:post).with(@subscription_ended_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => @subscription_ended_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, subscription.id)
    end

    it "does not post subscription ended ping to the 'subscription_ended' resource's post_url if the subscription has not ended", :sidekiq_inline do
      subscription = create(:subscription, link: @product, cancelled_at: 1.week.from_now)
      create(:membership_purchase, subscription:, link: @product)
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)

      expect(HTTParty).not_to receive(:post).with(@subscription_ended_resource_subscription.post_url,
                                                  timeout: 5,
                                                  body: params.deep_stringify_keys,
                                                  headers: { "Content-Type" => @subscription_ended_resource_subscription.content_type }
                                                  )

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME, subscription.id)
    end

    it "posts subscription restarted ping ot the 'subscription_restarted' resource's post_url", :sidekiq_inline do
      subscription = create(:subscription, link: @product)
      create(:membership_purchase, subscription:, link: @product)
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME)

      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params.deep_stringify_keys)
      expect(HTTParty).to receive(:post).with(@subscription_restarted_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => @subscription_restarted_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, subscription.id)
    end

    it "does not post subscription restarted ping to the 'subscription_restarted' resource's post_url if the subscription has a termination date", :sidekiq_inline do
      subscription = create(:subscription, link: @product, cancelled_at: Time.current)
      create(:membership_purchase, subscription:, link: @product)

      expect(HTTParty).not_to receive(:post)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, subscription.id)
    end

    it "posts subscription updated ping to the 'subscription_updated' resource's post_url", :sidekiq_inline do
      subscription = create(:subscription, link: @product)
      create(:membership_purchase, subscription:, link: @product)
      params = subscription.payload_for_ping_notification(resource_name: ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, additional_params: { "foo" => "bar" })

      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint, timeout: 5, body: params.deep_stringify_keys)
      expect(HTTParty).to receive(:post).with(@subscription_updated_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => @subscription_updated_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(nil, nil, ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, subscription.id, { "foo" => "bar" })
    end

    it "posts sale disputed ping to the 'dispute' resource's post_url", :sidekiq_inline do
      purchase = create(:purchase, link: @product, price_cents: 500, chargeback_date: Date.today)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_RESOURCE_NAME)
      dispute_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                     resource_name: ResourceSubscription::DISPUTE_RESOURCE_NAME)

      expect(params[:disputed]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint,
                                                  timeout: 5,
                                                  body: params.deep_stringify_keys,
                                                  headers: { "Content-Type" => @user.notification_content_type })
      expect(HTTParty).to receive(:post).with(dispute_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => dispute_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(purchase.id, nil, ResourceSubscription::DISPUTE_RESOURCE_NAME)
    end

    it "posts sale dispute won ping to the 'dispute_won' resource's post_url", :sidekiq_inline do
      purchase = create(:purchase, link: @product, price_cents: 500, chargeback_date: Date.today, chargeback_reversed: true)
      params = purchase.payload_for_ping_notification(resource_name: ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)
      dispute_won_resource_subscription = create(:resource_subscription, oauth_application: @app, user: @user,
                                                                         resource_name: ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)

      expect(params[:dispute_won]).to be(true)
      expect(HTTParty).not_to receive(:post).with(@user.notification_endpoint,
                                                  timeout: 5,
                                                  body: params.deep_stringify_keys,
                                                  headers: { "Content-Type" => @user.notification_content_type })
      expect(HTTParty).to receive(:post).with(dispute_won_resource_subscription.post_url,
                                              timeout: 5,
                                              body: params.deep_stringify_keys,
                                              headers: { "Content-Type" => dispute_won_resource_subscription.content_type }).and_return(@http_double)

      PostToPingEndpointsWorker.new.perform(purchase.id, nil, ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)
    end
  end
end
