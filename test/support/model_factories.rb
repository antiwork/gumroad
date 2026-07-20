# frozen_string_literal: true

# StripePaymentMethodHelper lives under spec/support and has no RSpec
# dependency; require it directly so credit-card builders can tokenize a card
# the same way the RSpec :chargeable factory does. The actual Stripe calls it
# makes are replayed from the shared VCR cassettes (see test/support/vcr.rb).
require Rails.root.join("spec", "support", "stripe_payment_method_helper")

# Factory-equivalent builders for the Minitest + fixtures suite (#5801).
#
# The suite has no FactoryBot, but complex hub models (Installment, Purchase,
# Subscription, Link, …) are genuinely per-test and can't be static fixtures.
# These helpers build them with real `Model.create!` — callbacks run, so the
# objects behave like factory-built ones — and mirror the essential attributes
# each factory sets. They're mixed into every ActiveSupport::TestCase so model
# ports can share one implementation.
#
# Naming mirrors the factories (create_user, create_purchase, …) to keep the
# port mechanical. Add new builders here rather than re-deriving them per file.
module ModelFactories
  # Route URL helpers, without mixing them into the test class directly:
  # `include Rails.application.routes.url_helpers` defines helpers like
  # `test_ping_url`, and Minitest runs every /^test_/ method as a test. Call as
  # `routes.some_url(...)`.
  def routes
    Rails.application.routes.url_helpers
  end

  def unique_suffix
    SecureRandom.hex(8)
  end

  # A distinct IP per purchase within a test (see create_purchase): not_double_charged
  # keys on email + ip_address + link, so a shared/nil IP makes two sales to the
  # same buyer look like a duplicate charge. The factory uses a random IP.
  def unique_ip
    @ip_seq ||= 0
    @ip_seq += 1
    "10.0.#{@ip_seq / 254}.#{@ip_seq % 254 + 1}"
  end

  # Deactivate then restart a subscription, recording the events code paths like
  # Installment#delivery_due? read to reason about post-resubscribe timing.
  def resubscribe(subscription)
    subscription.update!(deactivated_at: nil)
    SubscriptionEvent.create!(subscription:, event_type: :deactivated, occurred_at: 10.days.ago)
    SubscriptionEvent.create!(subscription:, event_type: :restarted, occurred_at: 2.days.ago)
  end

  def moderation_result(passed:, reasons: [])
    ContentModeration::ModerateRecordService::CheckResult.new(passed:, reasons:)
  end

  def create_user(tipping_enabled: false, discover_boost_enabled: false, **attrs)
    user = User.create!({
      email: "user-#{unique_suffix}@example.com",
      username: "u#{unique_suffix}",
      password: "test-password-123!",
      confirmed_at: Time.current,
      user_risk_state: "not_reviewed",
    }.merge(attrs))
    # User's before_create enables both tipping and the Discover boost. The
    # RSpec :user factory turns them back off by default so tests don't silently
    # inherit a boosted 30% Discover fee (discover_fee_per_thousand = 300) or
    # tipping. Mirror that here for parity — callers opt in with the keyword.
    user.update_column(:flags, user.flags ^ User.flag_mapping["flags"][:tipping_enabled]) unless tipping_enabled
    user.update_column(:flags, user.flags ^ User.flag_mapping["flags"][:discover_boost_enabled]) unless discover_boost_enabled
    user
  end

  def build_product(user: nil, **attrs)
    Link.new({
      user: user || create_user,
      name: "The Works of Edgar Gumstein",
      description: "This is a collection of works spanning 1984 — 1994, while I spent time in a shack in the Andes.",
      price_cents: 100,
      # The :product factory turns review display on by default; several
      # behaviors (recommendable?, review widgets) depend on it.
      display_product_reviews: true,
    }.merge(attrs))
  end

  def create_product(user: nil, **attrs)
    build_product(user:, **attrs).tap(&:save!)
  end

  # A recurring (non-tiered) membership product, mirroring :subscription_product.
  def build_subscription_product(user: nil, **attrs)
    Link.new({
      user: user || create_user,
      name: "Membership",
      price_cents: 100,
      is_recurring_billing: true,
      subscription_duration: "monthly",
      is_tiered_membership: false,
    }.merge(attrs))
  end

  def create_subscription_product(user: nil, **attrs)
    build_subscription_product(user:, **attrs).tap(&:save!)
  end

  # A tiered membership product (mirrors :membership_product). The
  # initialize_tier_if_needed callback builds the Tier category + default tier.
  def create_membership_product(user: nil, **attrs)
    Link.create!({
      user: user || create_user,
      name: "Membership",
      price_cents: 100,
      is_recurring_billing: true,
      subscription_duration: "monthly",
      is_tiered_membership: true,
      native_type: Link::NATIVE_TYPE_MEMBERSHIP,
      # The :product parent factory turns review display on; membership products
      # inherit it, and Product#recommendable? requires it.
      display_product_reviews: true,
    }.merge(attrs))
  end

  # A tiered membership with priced tiers (mirrors
  # :membership_product_with_preset_tiered_pricing). Defaults to First Tier $3/mo
  # and Second Tier $5/mo; pass recurrence_price_values (one hash per tier, keyed
  # by recurrence) to set different prices/recurrences.
  def create_membership_product_with_preset_tiered_pricing(user: nil, recurrence_price_values: nil, **attrs)
    recurrence_price_values ||= [
      { "monthly": { enabled: true, price: 3 } },
      { "monthly": { enabled: true, price: 5 } },
    ]
    product = create_membership_product(user:, **attrs)
    tier_category = product.tier_category
    first_tier = tier_category.variants.first
    first_tier.update!(name: "First Tier")
    first_tier.save_recurring_prices!(recurrence_price_values[0])
    second_tier = create_variant(variant_category: tier_category, name: "Second Tier")
    second_tier.save_recurring_prices!(recurrence_price_values[1])
    recurrence_price_values[2..]&.each_with_index do |recurrences, index|
      tier = create_variant(variant_category: tier_category, name: "Tier #{index + 3}")
      tier.save_recurring_prices!(recurrences)
    end
    product.tiers.reload
    product
  end

  # A physical product (mirrors the :is_physical trait): shipping + a default SKU.
  def create_physical_product(user: nil, **attrs)
    product = create_product(user:, **attrs)
    product.require_shipping = true
    product.native_type = "physical"
    product.skus_enabled = true
    product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 0, multiple_items_rate_cents: 0)
    product.skus << Sku.new(price_difference_cents: 0, name: "DEFAULT_SKU", is_default_sku: true)
    product.is_physical = true
    product.quantity_enabled = true
    product.should_show_sales_count = true
    product.save!
    product
  end

  # A product with two digital versions (mirrors :product_with_digital_versions).
  def create_product_with_digital_versions(user: nil, **attrs)
    product = create_product(user:, **attrs)
    category = create_variant_category(link: product, title: "Category")
    create_variant(variant_category: category, name: "Untitled 1")
    create_variant(variant_category: category, name: "Untitled 2")
    product
  end

  def create_product_installment_plan(link: nil, number_of_installments: 3, recurrence: "monthly", **attrs)
    link ||= create_product(price_cents: 1000)
    ProductInstallmentPlan.create!({ link:, number_of_installments:, recurrence: }.merge(attrs))
  end

  def create_sku(link: nil, **attrs)
    Sku.create!({ link: link || create_product, price_difference_cents: 0, name: "Large" }.merge(attrs))
  end

  # A seller old enough to sell service products (call/coffee/commission),
  # mirroring the :eligible_for_service_products user trait.
  def create_eligible_seller(**attrs)
    create_user(created_at: User::MIN_AGE_FOR_SERVICE_PRODUCTS.ago - 1.day, **attrs)
  end

  def create_call_product(user: nil, durations: [30], **attrs)
    product = Link.create!({ user: user || create_eligible_seller, name: "Call", price_cents: 100, native_type: Link::NATIVE_TYPE_CALL }.merge(attrs))
    category = product.variant_categories.first
    durations.each { |duration| category.variants.create!(duration_in_minutes: duration, name: "#{duration} minutes") }
    product
  end

  def create_coffee_product(user: nil, **attrs)
    Link.create!({ user: user || create_eligible_seller, name: "Coffee", price_cents: 100, native_type: Link::NATIVE_TYPE_COFFEE }.merge(attrs))
  end

  def create_collaborator(seller: nil, affiliate_user: nil, products: nil, pending_invitation: false, **attrs)
    collaborator = Collaborator.new({
      seller: seller || create_user,
      affiliate_user: affiliate_user || create_affiliate_user,
      apply_to_all_products: true,
      affiliate_basis_points: 30_00,
    }.merge(attrs))
    collaborator.products = products if products
    collaborator.save!
    CollaboratorInvitation.create!(collaborator:) if pending_invitation
    collaborator
  end

  def create_seller_profile_products_section(seller: nil, **attrs)
    SellerProfileProductsSection.create!({
      seller: seller || create_user,
      default_product_sort: "page_layout",
      shown_products: [],
      show_filters: false,
      add_new_products: true,
    }.merge(attrs))
  end

  def create_price(link: nil, price_cents: 100, currency: "usd", recurrence: nil, **attrs)
    Price.create!({ link: link || create_product, price_cents:, currency:, recurrence: }.merge(attrs))
  end

  def create_variant_category(link: nil, **attrs)
    VariantCategory.create!({ link: link || create_product, title: "Category" }.merge(attrs))
  end

  def build_variant(variant_category: nil, **attrs)
    Variant.new({ variant_category: variant_category || create_variant_category, name: "Untitled" }.merge(attrs))
  end

  def create_variant(variant_category: nil, **attrs)
    build_variant(variant_category:, **attrs).tap(&:save!)
  end

  # Mirrors the :installment factories. Product/variant posts hang off a product;
  # seller/follower/affiliate/audience posts hang off a seller with no link.
  def build_installment(installment_type: "product", link: :default, seller: :default, base_variant: nil, **attrs)
    case installment_type
    when "product"
      link = create_product if link == :default
      seller = link&.user if seller == :default
    when "variant"
      base_variant ||= create_variant
      link = base_variant.link if link == :default
      seller = link&.user if seller == :default
    else # seller, follower, affiliate, audience, abandoned_cart
      link = nil if link == :default
      seller = create_user if seller == :default
    end
    Installment.new({
      installment_type:,
      link:,
      seller:,
      base_variant:,
      message: "<p>A message.</p>",
      name: "A Post",
      send_emails: true,
      shown_on_profile: false,
      allow_comments: true,
    }.merge(attrs))
  end

  def create_installment(**args)
    build_installment(**args).tap(&:save!)
  end

  # Mirrors the :installment_rule / :post_rule factory.
  def create_installment_rule(installment:, **attrs)
    InstallmentRule.create!({ installment:, to_be_published_at: 1.week.from_now, time_period: "hour" }.merge(attrs))
  end

  # Mirrors the base :purchase factory (see test/fixtures/purchases.yml for the
  # same money math): a successful sale on the platform Stripe account.
  # calculate_fees is an after(:build) hook in the factory, so invoke it
  # explicitly before saving.
  def build_purchase(link: nil, seller: :default, purchaser: nil, variant_attributes: nil, chargeable: nil, **attrs)
    link ||= create_product # the :purchase factory defaults link to a fresh product
    seller = link.user if seller == :default
    price_cents = attrs.delete(:price_cents) || link.price_cents || 100
    # Mirror the :purchase factory: a $0 sale carries no charge-processor/stripe
    # ids or merchant account, so financial_transaction_validation treats it as
    # free rather than a broken paid charge. (Tiered memberships price on their
    # tiers, so their product-level price_cents is 0 and lands here.)
    paid = price_cents.to_i > 0
    purchase = Purchase.new({
      link:,
      seller:,
      price_cents:,
      total_transaction_cents: price_cents,
      displayed_price_cents: price_cents,
      tax_cents: 0,
      gumroad_tax_cents: 0,
      shipping_cents: 0,
      ip_address: unique_ip,
      browser_guid: "guid-#{unique_suffix}",
      email: "buyer-#{unique_suffix}@example.com",
      purchase_state: "successful",
      succeeded_at: Time.current,
      card_type: "visa",
      card_visual: "**** **** **** 4062",
      card_country: "US",
      stripe_fingerprint: paid ? "shfbeg5142fff" : nil,
      stripe_transaction_id: paid ? "2763276372637263" : nil,
      charge_processor_id: paid ? "stripe" : nil,
      merchant_account: paid ? merchant_accounts(:gumroad_stripe) : nil,
      # The factory sets a simple flow of funds so purchases that credit the
      # seller's balance (e.g. :purchase_with_balance) have one to split.
      flow_of_funds: FlowOfFunds.build_simple_flow_of_funds(Currency::USD, price_cents),
    }.merge(attrs))
    purchase.purchaser = purchaser if purchaser
    purchase.variant_attributes = variant_attributes if variant_attributes
    purchase.chargeable = chargeable if chargeable
    purchase.send(:calculate_fees)
    purchase
  end

  def create_purchase(**args)
    build_purchase(**args).tap(&:save!)
  end

  # A failed sale (mirrors :failed_purchase): the base purchase with its state
  # flipped to "failed". Kept succeeded_at as-is, matching the factory (which
  # only overrides purchase_state).
  def create_failed_purchase(link:, **attrs)
    create_purchase(link:, purchase_state: "failed", **attrs)
  end

  # A $0 sale (mirrors :free_purchase): no charge processor, card, or stripe ids.
  def create_free_purchase(link:, seller: :default, **attrs)
    create_purchase(
      link:, seller:, price_cents: 0,
      charge_processor_id: nil, merchant_account: nil,
      card_type: nil, card_visual: nil,
      stripe_fingerprint: nil, stripe_transaction_id: nil,
      **attrs
    )
  end

  def create_preorder_authorization_purchase(link:, **attrs)
    create_purchase(link:, purchase_state: "preorder_authorization_successful", **attrs)
  end

  # An original subscription sale (mirrors :membership_purchase). Defaults to a
  # plain non-tiered recurring product, which is enough for code that only cares
  # about the subscription; pass a tiered membership product for tier-aware
  # cases. Like the factory, the variant defaults to the product's tiers (or the
  # explicit `tier:`). An explicit subscription is reused rather than replaced.
  def create_membership_purchase(link: nil, subscription: nil, tier: nil, created_at: nil, **attrs)
    link ||= create_subscription_product
    subscription ||= create_subscription(link:)
    variant_attributes = attrs.delete(:variant_attributes)
    variant_attributes ||= tier ? [tier] : link.tiers.presence
    create_purchase(link:, subscription:, is_original_subscription_purchase: true, created_at:, variant_attributes:, **attrs)
  end

  # A recurring (non-original) membership charge (mirrors
  # :recurring_membership_purchase).
  def create_recurring_membership_purchase(subscription: nil, link: nil, **attrs)
    link ||= subscription&.link || create_membership_product
    subscription ||= create_subscription(link:)
    variant_attributes = attrs.delete(:variant_attributes) || link.tiers.presence
    create_purchase(link:, subscription:, is_original_subscription_purchase: false, variant_attributes:, **attrs)
  end

  # An unsaved subscription (mirrors `build(:subscription)`): no payment option is
  # created, matching the factory's create-only before hook. Enough for the
  # predicate methods (status, termination_reason, cancelled_by_seller?, …).
  def build_subscription(link: nil, user: :default, **attrs)
    link ||= create_product
    user = create_user if user == :default
    Subscription.new({ link:, user:, is_installment_plan: false }.merge(attrs))
  end

  # Subscriptions must have a payment_option before they validate, so build it
  # (priced at the product's default price) before saving, like the :subscription
  # factory's before(:create) hook does.
  #
  # `user:` uses a :default sentinel (like create_free_purchase's seller:) so an
  # explicit `user: nil` builds a GUEST subscription (Subscription#user is
  # optional), matching FactoryBot's `create(:subscription, user: nil)` override
  # semantics — whereas omitting the argument creates a fresh user.
  def create_subscription(link: nil, user: :default, price: nil, **attrs)
    link ||= create_product
    user = create_user if user == :default
    subscription = Subscription.new({ link:, user:, is_installment_plan: false }.merge(attrs))
    # `price` mirrors the :subscription factory's transient: the payment option
    # is priced at the given Price, defaulting to the product's default price.
    option_price = price || link.default_price
    if subscription.is_installment_plan
      # Mirror the factory's before(:create): an installment-plan subscription's
      # payment option carries the product's installment plan, and its charge
      # count is the number of installments. When the product has no plan yet, a
      # placeholder option is saved unvalidated so the subscription still saves.
      installment_plan = link.installment_plan
      if installment_plan.present?
        subscription.payment_options << PaymentOption.new(subscription:, price: option_price, installment_plan:)
        subscription.charge_occurrence_count = installment_plan.number_of_installments
      else
        placeholder = PaymentOption.new(subscription:, price: option_price, installment_plan: nil)
        placeholder.save!(validate: false)
        subscription.payment_options << placeholder
      end
    else
      subscription.payment_options << PaymentOption.new(subscription:, price: option_price)
    end
    subscription.save!
    subscription
  end

  # A subscription lifecycle event (mirrors :subscription_event).
  def create_subscription_event(subscription:, event_type: :deactivated, occurred_at: Time.current, **attrs)
    SubscriptionEvent.create!({ subscription:, event_type:, occurred_at: }.merge(attrs))
  end

  # A gift (mirrors :gift): links a gifter to a giftee by email.
  def create_gift(link: nil, gifter_email: nil, giftee_email: nil, **attrs)
    Gift.create!({
      link: link || create_product,
      gifter_email: gifter_email || "gifter-#{unique_suffix}@example.com",
      giftee_email: giftee_email || "giftee-#{unique_suffix}@example.com",
    }.merge(attrs))
  end

  # A custom-field value on a purchase (mirrors :purchase_custom_field). Built
  # unsaved so callers can push it onto a purchase's association.
  def build_purchase_custom_field(purchase: nil, **attrs)
    PurchaseCustomField.new({
      purchase:,
      field_type: CustomField::TYPE_TEXT,
      name: "Custom field",
      value: "custom field value",
    }.merge(attrs))
  end

  # A subscription payment option (mirrors :payment_option): priced at the
  # product's default price unless overridden.
  def create_payment_option(subscription: nil, price: nil, **attrs)
    subscription ||= create_subscription
    PaymentOption.create!({ subscription:, price: price || subscription.link.default_price }.merge(attrs))
  end

  # A pending/applied plan change on a subscription (mirrors
  # :subscription_plan_change). The tier defaults to a standalone variant, just
  # like the factory's `association :tier, factory: :variant`.
  def create_subscription_plan_change(subscription:, tier: nil, recurrence: "monthly", perceived_price_cents: 500, **attrs)
    SubscriptionPlanChange.create!({
      subscription:,
      tier: tier || create_variant,
      recurrence:,
      perceived_price_cents:,
    }.merge(attrs))
  end

  # A license key tied to a purchase (mirrors :license).
  def create_license(link: nil, purchase: nil, **attrs)
    link ||= create_product
    License.create!({ link:, purchase: purchase || create_purchase(link:), uses: 0 }.merge(attrs))
  end

  # A Chargeable built from a Stripe test payment method (mirrors :chargeable).
  # Tokenizes the card against Stripe, so callers must be inside a VCR cassette.
  def build_chargeable(card: nil, product_permalink: "xx")
    card ||= StripePaymentMethodHelper.success
    Chargeable.new([
                     StripeChargeablePaymentMethod.new(card.to_stripejs_payment_method_id, zip_code: card[:cc_zipcode], product_permalink:)
                   ])
  end

  # A native-PayPal Chargeable (mirrors :native_paypal_chargeable).
  def build_native_paypal_chargeable
    Chargeable.new([PaypalChargeable.new("B-8AM85704X2276171X", "paypal_paypal-gr-integspecs@gumroad.com", "US")])
  end

  # A Braintree-backed PayPal Chargeable (mirrors :paypal_chargeable).
  def build_paypal_chargeable
    Chargeable.new([BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)])
  end

  # A credit card built from a Stripe test payment method (mirrors :credit_card,
  # which does `CreditCard.create(chargeable, nil, user)`).
  def create_credit_card(user: nil, card: nil, chargeable: nil, **attrs)
    chargeable ||= build_chargeable(card:)
    CreditCard.create(chargeable, nil, user)
  end

  # An analytics Event (mirrors :event): the base factory only sets geo defaults.
  def create_event(**attrs)
    Event.create!({ from_profile: false, ip_country: "United States", ip_state: "CA" }.merge(attrs))
  end

  # A sales-tax rate row (mirrors :zip_tax_rate). Defaults match the factory.
  def create_zip_tax_rate(**attrs)
    ZipTaxRate.create!({
      combined_rate: "0.1100000", county_rate: "0.0100000", special_rate: "0.0300000",
      state_rate: "0.0500000", city_rate: "0.0200000", state: "NY", zip_code: "10087",
      country: "US", is_seller_responsible: 1, is_epublication_rate: 0,
    }.merge(attrs))
  end

  # A PayPal merchant account (mirrors :merchant_account_paypal).
  def create_merchant_account_paypal(user: nil, **attrs)
    MerchantAccount.create!({
      user: user || create_user,
      charge_processor_id: PaypalChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: "acct_#{unique_suffix}",
      charge_processor_alive_at: Time.current,
    }.merge(attrs))
  end

  # A Stripe Connect merchant account (mirrors :merchant_account_stripe_connect).
  def create_merchant_account_stripe_connect(user: nil, **attrs)
    MerchantAccount.create!({
      user: user || create_user,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: "acct_1SOb0DEwFhlcVS6d",
      charge_processor_alive_at: Time.current,
      json_data: { "meta" => { "stripe_connect" => "true" } },
    }.merge(attrs))
  end

  # A product review tied to a purchase (mirrors :product_review).
  def create_product_review(purchase: nil, link: nil, rating: 1, **attrs)
    purchase ||= create_purchase(link: link || create_product)
    ProductReview.create!({ purchase:, link: link || purchase.link, rating:, message: "A fine review." }.merge(attrs))
  end

  # A Discover recommendation record for a purchase (mirrors
  # :recommended_purchase_info_via_discover).
  def create_recommended_purchase_info_via_discover(purchase:, **attrs)
    RecommendedPurchaseInfo.create!({
      purchase:,
      recommended_link: purchase.link,
      recommendation_type: "discover",
    }.merge(attrs))
  end

  # A tiered membership that also satisfies Product#recommendable? (mirrors the
  # :recommendable trait applied to a membership product): a compliant seller
  # with a payout address, the films taxonomy, and a reviewed sale.
  def create_recommendable_membership_product_with_preset_tiered_pricing(recurrence_price_values: nil, **attrs)
    seller = create_user(user_risk_state: "compliant", name: "gumbo", payment_address: "gumbo-#{unique_suffix}@example.com")
    product = create_membership_product_with_preset_tiered_pricing(user: seller, recurrence_price_values:,
                                                                   taxonomy: Taxonomy.find_or_create_by(slug: "films"), **attrs)
    reviewed = create_purchase(link: product, created_at: 1.week.ago)
    create_product_review(purchase: reviewed, rating: 5)
    product.reload
    product
  end

  # An in-progress sale (mirrors :purchase_in_progress).
  def create_purchase_in_progress(link:, **attrs)
    create_purchase(link:, purchase_state: "in_progress", **attrs)
  end

  # An in-progress sale that is then marked successful and credited to the
  # seller's balance (mirrors :purchase_with_balance).
  def create_purchase_with_balance(link:, **attrs)
    purchase = create_purchase_in_progress(link:, **attrs)
    purchase.update_balance_and_mark_successful!
    purchase
  end

  # A free-trial membership sale (mirrors :free_trial_membership_purchase): a
  # tiered membership with a free trial enabled, an original "not_charged"
  # purchase flagged as a free trial, and a subscription whose free trial ends
  # after the product's configured trial duration.
  def create_free_trial_membership_purchase(link: nil, user: nil, **attrs)
    link ||= create_membership_product(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    subscription = create_subscription(link:, user:, free_trial_ends_at: Time.current + link.free_trial_duration)
    create_purchase(
      link:, subscription:, purchaser: user,
      variant_attributes: [link.tiers.first],
      is_original_subscription_purchase: true,
      is_free_trial_purchase: true,
      should_exclude_product_review: true,
      purchase_state: "not_charged",
      succeeded_at: nil,
      **attrs
    )
  end

  # Mirrors the :workflow factories. Product/variant workflows hang off a
  # product; the rest have no link.
  def create_workflow(workflow_type: "product", seller: nil, link: :default, **attrs)
    seller ||= create_user
    if %w[product variant].include?(workflow_type)
      link = create_product(user: seller) if link == :default
    elsif link == :default
      link = nil
    end
    Workflow.create!({ seller:, link:, name: "my workflow", workflow_type:, workflow_trigger: nil }.merge(attrs))
  end

  # A seller-scoped workflow (mirrors :seller_workflow): no product link.
  def create_seller_workflow(seller: nil, **attrs)
    create_workflow(workflow_type: Workflow::SELLER_TYPE, seller:, link: nil, **attrs)
  end

  # An audience workflow (mirrors :audience_workflow): no product link.
  def create_audience_workflow(seller: nil, **attrs)
    create_workflow(workflow_type: Workflow::AUDIENCE_TYPE, seller:, link: nil, **attrs)
  end

  # A published post (mirrors :published_installment): an installment already
  # published. Pass workflow:/workflow_trigger:/link: for workflow posts.
  def create_published_installment(**attrs)
    create_installment(published_at: Time.current, **attrs)
  end

  # A price snapshot for an installment-plan payment option (mirrors
  # :installment_plan_snapshot).
  def create_installment_plan_snapshot(payment_option:, number_of_installments: 3, recurrence: "monthly", total_price_cents: 14700, **attrs)
    InstallmentPlanSnapshot.create!({ payment_option:, number_of_installments:, recurrence:, total_price_cents: }.merge(attrs))
  end

  # A product with an installment plan (mirrors the :with_installment_plan
  # trait): a $30 product with a 3-installment plan.
  def create_product_with_installment_plan(number_of_installments: 3, **attrs)
    product = create_product(price_cents: 3000, **attrs)
    create_product_installment_plan(link: product, number_of_installments:)
    product.reload
    product
  end

  # An original installment-plan purchase (mirrors :installment_plan_purchase):
  # a paid, in-full-priced sale whose subscription is flagged is_installment_plan
  # and carries a plan snapshot.
  def create_installment_plan_purchase(link: nil, purchaser: nil, **attrs)
    link ||= create_product_with_installment_plan
    purchase = build_purchase(link:, purchaser:, is_original_subscription_purchase: true, is_installment_payment: true, **attrs)
    purchase.installment_plan = link.installment_plan
    purchase.set_price_and_rate
    purchase.save!
    purchase.subscription ||= create_subscription(link:, is_installment_plan: true, user: purchase.purchaser)
    purchase.save!
    payment_option = purchase.subscription.last_payment_option
    if payment_option && !payment_option.installment_plan_snapshot
      create_installment_plan_snapshot(
        payment_option:,
        number_of_installments: link.installment_plan.number_of_installments,
        recurrence: link.installment_plan.recurrence,
        total_price_cents: purchase.total_price_before_installments || purchase.price_cents
      )
    end
    purchase
  end

  # A recurring (non-original) installment-plan charge (mirrors
  # :recurring_installment_plan_purchase).
  def create_recurring_installment_plan_purchase(link: nil, **attrs)
    link ||= create_product_with_installment_plan
    purchase = build_purchase(link:, is_original_subscription_purchase: false, is_installment_payment: true, **attrs)
    purchase.installment_plan = link.installment_plan
    purchase.set_price_and_rate
    purchase.save!
    purchase
  end

  # A published installment attached to a workflow, with an installment_rule
  # (mirrors :workflow_installment). delayed_delivery_time drives delivery_due?.
  def create_workflow_installment(workflow:, link: nil, published_at: nil, delayed_delivery_time: 0, **attrs)
    installment = Installment.create!({
      workflow:,
      seller: workflow.seller,
      link: link || workflow.link,
      installment_type: workflow.workflow_type,
      base_variant: workflow.base_variant,
      send_emails: true,
      message: "<p>A message.</p>",
      name: "A Post",
      published_at:,
      workflow_installment_published_once_already: published_at.present?,
    }.merge(attrs))
    InstallmentRule.create!(installment:, delayed_delivery_time:, to_be_published_at: 1.week.from_now, time_period: "hour")
    installment
  end

  # An abandoned-cart workflow with its seeded installment (mirrors the
  # abandoned_cart_workflow factory's after(:create) hook).
  def create_abandoned_cart_workflow(seller:, **attrs)
    workflow = Workflow.create!({ seller:, link: nil, name: "my workflow", workflow_type: "abandoned_cart", workflow_trigger: nil }.merge(attrs))
    Installment.create!(
      workflow:,
      seller: workflow.seller,
      link: workflow.link,
      installment_type: workflow.workflow_type,
      base_variant: workflow.base_variant,
      send_emails: true,
      published_at: workflow.published_at,
      workflow_installment_published_once_already: workflow.published_at.present?,
      name: "You left something in your cart",
      message: "When you're ready to buy, complete checking out.<product-list-placeholder />Thanks!"
    )
    workflow
  end

  def create_offer_code(products:, user: nil, amount_cents: 100, **attrs)
    user ||= products.first&.user || create_user
    offer_code = OfferCode.new({ user:, products:, code: "off#{unique_suffix[0, 8]}", amount_cents:, currency_type: user.currency_type }.merge(attrs))
    offer_code.user_id = products.first.user_id if products.present? # mirrors the factory's before(:create)
    offer_code.save!
    offer_code
  end

  # A tiered offer code whose discount depends on how long the buyer has owned an
  # ownership product (mirrors :tiered_offer_code). Pass for_existing_customers:
  # true for the :for_existing_customers trait (existing_customers_only + the
  # products doubling as ownership products).
  def create_tiered_offer_code(products:, user: nil, for_existing_customers: false, **attrs)
    user ||= products.first&.user || create_user
    defaults = {
      amount_cents: nil,
      amount_percentage: 0,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 50 },
      ],
    }
    if for_existing_customers
      defaults[:existing_customers_only] = true
      defaults[:ownership_products] = products
    end
    create_offer_code(products:, user:, **defaults.merge(attrs))
  end

  # A purchase analytics event (mirrors :purchase_event): a successful "purchase"
  # event carrying the purchase's link and price.
  def create_purchase_event(purchase:, **attrs)
    Event.create!({
      event_name: "purchase",
      purchase_state: "successful",
      from_profile: false,
      ip_country: "United States",
      ip_state: "CA",
      purchase:,
      link_id: purchase.link_id,
      price_cents: purchase.price_cents,
    }.merge(attrs))
  end

  # A user-submitted comment (mirrors :comment), defaulting to hanging off a
  # published installment. Pass purchase: to attribute it to a buyer.
  def create_comment(commentable: nil, author: nil, purchase: nil, **attrs)
    author ||= create_user
    Comment.create!({
      commentable: commentable || create_published_installment,
      author:,
      author_name: author.display_name,
      comment_type: Comment::COMMENT_TYPE_USER_SUBMITTED,
      content: "Famous last words.",
      purchase:,
    }.merge(attrs))
  end

  def create_universal_offer_code(user: nil, amount_cents: 100, excluded_products: [], **attrs)
    user ||= create_user
    OfferCode.create!({ user:, universal: true, products: [], excluded_products:, code: "uni#{unique_suffix[0, 6]}", amount_cents:, currency_type: user.currency_type }.merge(attrs))
  end

  def create_upsell(seller:, product: nil, offer_code: nil, selected_products: nil, **attrs)
    product ||= create_product(user: seller)
    upsell = Upsell.new({
      name: "Upsell",
      seller:,
      product:,
      text: "Take advantage of this excellent offer!",
      description: "This offer will only last for a few weeks.",
      cross_sell: false,
      offer_code:,
    }.merge(attrs))
    upsell.selected_products = selected_products if selected_products
    upsell.save!
    upsell
  end

  def create_product_refund_policy(product: nil, **attrs)
    product ||= create_product
    ProductRefundPolicy.create!({ product:, seller: product.user, max_refund_period_in_days: RefundPolicy::DEFAULT_REFUND_PERIOD_IN_DAYS, fine_print: "This is a product-level refund policy" }.merge(attrs))
  end

  def create_affiliate_user(**attrs)
    create_user(**attrs)
  end

  def create_direct_affiliate(seller: nil, affiliate_user: nil, products: nil, **attrs)
    affiliate = DirectAffiliate.new({
      affiliate_user: affiliate_user || create_affiliate_user,
      seller: seller || create_user,
      affiliate_basis_points: 300,
      send_posts: true,
    }.merge(attrs))
    affiliate.products = products if products
    affiliate.save!
    affiliate
  end

  def create_product_affiliate(product:, affiliate:, **attrs)
    ProductAffiliate.create!({ product:, affiliate:, affiliate_basis_points: 30_00 }.merge(attrs))
  end

  # A product flagged as a collab, with a product_affiliate linking a
  # collaborator (mirrors the :is_collab trait).
  def create_collab_product(user: nil, collaborator: nil, collaborator_cut: 30_00, **attrs)
    product = create_product(user:, is_collab: true, **attrs)
    collaborator ||= create_collaborator(seller: product.user)
    create_product_affiliate(product:, affiliate: collaborator, affiliate_basis_points: collaborator_cut)
    product
  end

  def create_custom_field(name: "Custom field", seller: nil, field_type: "text", products: nil, **attrs)
    seller ||= products&.first&.user || create_user
    field = CustomField.new({ name:, seller:, field_type: }.merge(attrs))
    field.products = products if products
    field.save!
    field
  end

  def create_circle_integration(**attrs)
    CircleIntegration.create!({ api_key: GlobalConfig.get("CIRCLE_API_KEY"), community_id: "3512", space_group_id: "43576" }.merge(attrs))
  end

  def create_product_cached_value(product: nil, **attrs)
    product ||= create_product
    # before_create :assign_cached_values reads Elasticsearch-backed stats
    # (monthly_recurring_revenue et al.) that the stubbed-ES Minitest harness
    # can't compute. Feed deterministic zeros so the record can be created; the
    # cached-value tests care about the join/association, not the ES rollups.
    product.stubs(monthly_recurring_revenue: 0, revenue_pending: 0, total_usd_cents: 0)
    ProductCachedValue.create!({ product: }.merge(attrs))
  end

  def create_rich_content(entity: nil, description: [], **attrs)
    RichContent.create!({ entity: entity || create_product, description: }.merge(attrs))
  end

  def create_public_file(resource: nil, with_audio: false, **attrs)
    resource ||= create_product
    public_file = PublicFile.new({
      original_file_name: "test-#{unique_suffix}.mp3",
      display_name: "Test audio",
      public_id: PublicFile.generate_public_id,
      resource:,
    }.merge(attrs))
    if with_audio
      public_file.file.attach(
        io: File.open(Rails.root.join("spec/support/fixtures/test.mp3")),
        filename: "test.mp3",
        content_type: "audio/mpeg"
      )
    end
    public_file.save!
    public_file
  end

  # A product flagged as a bundle with two bundled products (mirrors the
  # :bundle trait / :bundle_product factory).
  def create_bundle(user: nil, **attrs)
    bundle = create_product(user:, name: "Bundle", description: "This is a bundle of products", is_bundle: true, **attrs)
    2.times do |i|
      product = create_product(user: bundle.user, name: "Bundle Product #{i + 1}")
      BundleProduct.create!(bundle:, product:)
    end
    bundle
  end

  def create_community(resource: nil, seller: nil, **attrs)
    resource ||= create_product
    Community.create!({ seller: seller || resource.user, resource: }.merge(attrs))
  end

  def create_merchant_account(user: nil, **attrs)
    MerchantAccount.create!({
      user: user || create_user,
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      charge_processor_merchant_id: "acct_#{unique_suffix}",
      charge_processor_alive_at: Time.current,
    }.merge(attrs))
  end

  def create_blast(post:, **attrs)
    PostEmailBlast.create!({
      post:,
      seller: post.seller,
      requested_at: 30.minutes.ago,
      started_at: 25.minutes.ago,
      first_email_delivered_at: 20.minutes.ago,
      last_email_delivered_at: 10.minutes.ago,
      delivery_count: 1500,
    }.merge(attrs))
  end

  def create_product_file(installment: nil, link: nil, **attrs)
    ProductFile.create!({
      url: "#{S3_BASE_URL}specs/#{unique_suffix}.pdf",
      filetype: "pdf",
      filegroup: "document",
      installment:,
      link:,
    }.merge(attrs))
  end

  def create_readable_document(link: nil, **attrs)
    create_product_file(link:, url: "#{S3_BASE_URL}specs/doc-#{unique_suffix}.pdf", filetype: "pdf", filegroup: "document", **attrs)
  end

  def create_non_readable_document(link: nil, **attrs)
    create_product_file(link:, url: "#{S3_BASE_URL}specs/doc-#{unique_suffix}.epub", filetype: "epub", filegroup: "epub_document", **attrs)
  end

  def create_streamable_video(link: nil, **attrs)
    create_product_file(link:, url: "#{S3_BASE_URL}specs/vid-#{unique_suffix}.mov", filetype: "mov", filegroup: "video", **attrs)
  end

  PRODUCT_FILE_SHAPES = {
    streamable_video: { url: "#{S3_BASE_URL}specs/ScreenRecording.mov", filetype: "mov", filegroup: "video" },
    readable_document: { url: "#{S3_BASE_URL}specs/billion-dollar-company-chapter-0.pdf", filetype: "pdf", filegroup: "document" },
  }.freeze

  def create_installment_file(shape, **attrs)
    ProductFile.create!(PRODUCT_FILE_SHAPES.fetch(shape).merge(attrs))
  end

  # A product thumbnail with the smilie.png fixture attached and analyzed
  # (mirrors the :thumbnail factory).
  def create_thumbnail(product: nil, **attrs)
    thumbnail = Thumbnail.new({ product: product || create_product }.merge(attrs))
    blob = ActiveStorage::Blob.create_and_upload!(
      io: Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", "smilie.png"), "image/png"),
      filename: "smilie.png"
    )
    blob.analyze
    thumbnail.file.attach(blob)
    thumbnail.save!
    thumbnail.file.analyze if thumbnail.file.attached?
    thumbnail
  end

  # An asset preview (cover) with a fixture image attached. Metadata is injected
  # by AssetPreviewAnalysisStub instead of shelling out to the analyzer, matching
  # the :asset_preview factory.
  def create_asset_preview(link: nil, **attrs)
    build_asset_preview(link:, fixture: "kFDzu.png", content_type: "image/png", **attrs)
  end

  def create_asset_preview_mov(link: nil, **attrs)
    build_asset_preview(link:, fixture: "thing.mov", content_type: "video/quicktime", **attrs)
  end

  def create_asset_preview_jpg(link: nil, **attrs)
    build_asset_preview(link:, fixture: "test-small.jpg", content_type: "image/jpeg", **attrs)
  end

  def create_asset_preview_gif(link: nil, **attrs)
    build_asset_preview(link:, fixture: "sample.gif", content_type: "image/gif", **attrs)
  end

  # A recommendable product: a compliant seller with a payout address, the films
  # taxonomy, and a completed sale — the DB-only conditions Product#recommendable?
  # checks (mirrors the :recommendable trait, minus the ES reindex).
  def create_recommendable_product(**attrs)
    seller = create_user(user_risk_state: "compliant", name: "gumbo", payment_address: "gumbo-#{unique_suffix}@example.com")
    product = create_product(user: seller, taxonomy: Taxonomy.find_or_create_by(slug: "films"), **attrs)
    create_purchase(link: product)
    product.reload
    product
  end

  # CreatorContactingCustomersEmailInfo rows, mirroring the nested
  # creator_contacting_customers_email_info_{sent,delivered,opened} factories:
  # each state carries the timestamps of the states it descends from.
  def create_email_info(installment:, purchase:, state: "sent", email_name: "purchase_installment")
    attrs = { installment:, purchase:, email_name:, state: }
    attrs[:sent_at] = Time.current if %w[sent delivered opened].include?(state)
    attrs[:delivered_at] = Time.current if %w[delivered opened].include?(state)
    attrs[:opened_at] = Time.current if state == "opened"
    CreatorContactingCustomersEmailInfo.create!(attrs)
  end

  private
    def build_asset_preview(link:, fixture:, content_type:, **attrs)
      preview = AssetPreview.new({ link: link || create_product }.merge(attrs))
      preview.file.attach(Rack::Test::UploadedFile.new(Rails.root.join("spec", "support", "fixtures", fixture), content_type))
      preview.save!
      AssetPreviewAnalysisStub.analyze(preview.file)
      preview
    end
end

ActiveSupport::TestCase.include(ModelFactories)
