# frozen_string_literal: true

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

  # Mirrors the base :purchase factory (see test/fixtures/purchases.yml for the
  # same money math): a successful sale on the platform Stripe account.
  # calculate_fees is an after(:build) hook in the factory, so invoke it
  # explicitly before saving.
  def create_purchase(link:, seller: :default, purchaser: nil, variant_attributes: nil, **attrs)
    seller = link.user if seller == :default
    price_cents = attrs.delete(:price_cents) || link.price_cents || 100
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
      stripe_fingerprint: "shfbeg5142fff",
      stripe_transaction_id: "2763276372637263",
      charge_processor_id: "stripe",
      merchant_account: merchant_accounts(:gumroad_stripe),
    }.merge(attrs))
    purchase.purchaser = purchaser if purchaser
    purchase.variant_attributes = variant_attributes if variant_attributes
    purchase.send(:calculate_fees)
    purchase.save!
    purchase
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

  # An original subscription sale on a plain (non-tiered) recurring product —
  # enough for code that only cares about the subscription, not membership tiers.
  def create_membership_purchase(link: nil, created_at: nil, **attrs)
    link ||= create_subscription_product
    subscription = create_subscription(link:)
    create_purchase(link:, subscription:, is_original_subscription_purchase: true, created_at:, **attrs)
  end

  # Subscriptions must have a payment_option before they validate, so build it
  # (priced at the product's default price) before saving, like the :subscription
  # factory's before(:create) hook does.
  def create_subscription(link: nil, user: nil, **attrs)
    link ||= create_product
    user ||= create_user
    subscription = Subscription.new({ link:, user:, is_installment_plan: false }.merge(attrs))
    subscription.payment_options << PaymentOption.new(subscription:, price: link.default_price)
    subscription.save!
    subscription
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
