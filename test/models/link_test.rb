# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/link_spec.rb. Link (a product) is exercised mostly
# through model logic — validations, callbacks, pricing, scopes — so objects
# are built with the shared ModelFactories helpers (create_product/build_product,
# create_variant, …). The RSpec file was tagged :vcr defensively, but the
# product model paths here make no external HTTP calls.
class LinkTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  # --- #custom_html= ---------------------------------------------------------

  test "custom_html= clears the page HTML without marking the associated page for destruction" do
    product.update!(custom_html: "<section>Live landing page</section>")
    page = product.reload.page

    product.custom_html = nil

    assert_equal page, product.page
    assert_not product.page.marked_for_destruction?

    product.save!

    assert_equal page, product.reload.page
    assert_nil product.custom_html
  end

  test "is not a single-unit currency" do
    assert_equal false, product.send(:single_unit_currency?)
  end

  # --- max_purchase_count validation -----------------------------------------

  test "max_purchase_count can be set on new records with no purchases" do
    assert build_product(max_purchase_count: nil).valid?
    assert build_product(max_purchase_count: 100).valid?
  end

  test "max_purchase_count prevents changing below inventory sold" do
    product = create_product(max_purchase_count: 5)
    2.times { create_purchase(link: product) }
    product.reload
    assert product.valid?
    product.max_purchase_count = 1
    assert_equal false, product.valid?
  end

  test "max_purchase_count does not invalidate the record when inventory sold already exceeds it" do
    product = create_product
    2.times { create_purchase(link: product) }
    product.update_column(:max_purchase_count, 1)
    assert product.reload.valid?
  end

  test "max_purchase_count treats a nil sales_count_for_inventory as zero" do
    product = create_product(max_purchase_count: 100)
    product.stub(:sales_count_for_inventory, nil) do
      product.max_purchase_count = 50
      assert_nothing_raised { product.valid? }
      assert product.valid?
    end
  end

  # --- price_must_be_within_range validation ---------------------------------

  test "allows products over $1000 for verified users" do
    assert build_product(user: create_user(verified: true), price_cents: 100_100).valid?
  end

  test "price is valid within acceptable bounds" do
    assert build_product(price_cents: 1_00).valid?
    assert build_product(price_cents: 5000_00).valid?
  end

  test "price fails when too high" do
    product = build_product(price_cents: 5000_01)
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Sorry, we don't support pricing products above $5,000."
  end

  test "price fails when it exceeds the maximum storable value" do
    error = assert_raises(Link::LinkInvalid) do
      build_product(user: create_user(verified: true), price_cents: 2_147_483_648)
    end
    assert_equal "Sorry, the price entered is too large.", error.message
  end

  test "price fails when too low" do
    product = build_product(price_cents: 98)
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Sorry, a product must be at least $0.99."
  end

  test "price validates against the current currency when switching currencies" do
    product = create_product(price_currency_type: "usd", price_cents: 100)
    usd_price = product.default_price
    assert_equal "usd", usd_price.currency
    assert_equal 100, usd_price.price_cents

    error = assert_raises(ActiveRecord::RecordInvalid) do
      product.update!(price_currency_type: "inr", price_cents: 5000)
    end
    assert_equal "Validation failed: Sorry, a product must be at least ₹73.", error.message

    # USD 1.00 is below the INR 73.00 threshold but is ignored — it's not the current currency.
    assert_nothing_raised { product.update!(price_currency_type: "inr", price_cents: 50000) }
  end

  test "price adds an error for an unsupported currency type" do
    product = build_product(price_currency_type: "xyz", price_cents: 100)
    assert_not product.valid?
    assert_includes product.errors.full_messages, "'xyz' is not a supported currency."
  end

  # --- native_type inclusion validation --------------------------------------

  test "native_type fails when nil" do
    product = build_product(native_type: nil)
    assert product.invalid?
    assert_raises(ActiveRecord::NotNullViolation) { product.save!(validate: false) }
  end

  test "native_type succeeds when in the allowed list" do
    assert build_product(native_type: "digital").valid?
  end

  test "native_type fails when not in the allowed list" do
    product = build_product(native_type: "invalid")
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Product type is not included in the list"
  end

  # --- discover_fee_per_thousand inclusion validation ------------------------

  test "discover_fee_per_thousand succeeds when in the allowed list" do
    product = build_product
    [100, 300, 1000, 400, 100].each do |fee|
      product.discover_fee_per_thousand = fee
      assert product.valid?, "expected #{fee} to be valid"
    end
  end

  test "discover_fee_per_thousand fails when not in the allowed list" do
    product = build_product
    message = "Gumroad fee must be between 30% and 100%"
    [0, nil, -1, 10, 1001].each do |fee|
      product.discover_fee_per_thousand = fee
      assert_not product.valid?, "expected #{fee.inspect} to be invalid"
      assert_includes product.errors.full_messages, message
    end
  end

  # --- alive_category_variants_presence validation ---------------------------

  test "physical product with no versions is valid" do
    product = create_physical_product
    assert_nothing_raised { product.save! }
    assert product.valid?
    assert_not product.errors.any?
  end

  test "physical product with non-empty versions is valid" do
    product = create_physical_product
    category_one = create_variant_category(link: product)
    category_two = create_variant_category(link: product)
    create_sku(link: product)
    create_variant(variant_category: category_one)
    create_variant(variant_category: category_two)
    assert_nothing_raised { product.save! }
    assert product.valid?
  end

  test "physical product with an empty version fails" do
    product = create_physical_product
    category_one = create_variant_category(link: product)
    create_variant_category(link: product)
    create_sku(link: product)
    create_variant(variant_category: category_one)
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_not product.valid?
    assert_equal "Sorry, the product versions must have at least one option.", product.errors.full_messages.to_sentence
  end

  test "non-physical product with no versions is valid" do
    assert_nothing_raised { product.save! }
    assert product.valid?
  end

  test "non-physical product with non-empty versions is valid" do
    category_one = create_variant_category(link: product)
    category_two = create_variant_category(link: product)
    create_variant(variant_category: category_one)
    create_variant(variant_category: category_two)
    assert_nothing_raised { product.save! }
    assert product.valid?
  end

  test "non-physical product with an empty version fails" do
    create_variant_category(link: product)
    category_two = create_variant_category(link: product)
    create_variant(variant_category: category_two)
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_not product.valid?
    assert_equal "Sorry, the product versions must have at least one option.", product.errors.full_messages.to_sentence
  end

  # --- free trial validation -------------------------------------------------

  test "free trial can be enabled on a recurring product with valid duration" do
    product = build_subscription_product(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    assert product.valid?
  end

  test "free trial requires duration properties when enabled" do
    product = build_subscription_product(free_trial_enabled: true)
    assert_not product.valid?
    assert_equal ["Free trial duration unit can't be blank", "Free trial duration amount can't be blank"].sort,
                 product.errors.full_messages.sort

    product.free_trial_duration_unit = :week
    product.free_trial_duration_amount = 1
    assert product.valid?
  end

  test "free trial skips validating duration amount unless changed" do
    product = create_subscription_product(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    product.update_attribute(:free_trial_duration_amount, 2) # skip validations
    assert product.valid?

    product.free_trial_duration_amount = 3
    assert_not product.valid?
  end

  test "free trial properties are not required when disabled" do
    assert build_subscription_product(free_trial_enabled: false).valid?
  end

  test "free trial only allows permitted durations" do
    product = build_subscription_product(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    assert product.valid?

    product.free_trial_duration_amount = 2
    assert_not product.valid?

    product.free_trial_duration_amount = 0.5
    assert_not product.valid?
  end

  test "free trial cannot be enabled on a non-recurring product" do
    product = build_product(free_trial_enabled: true)
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Free trials are only allowed for subscription products."
  end

  test "free trial properties cannot be set on a non-recurring product" do
    product = build_product(free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Free trials are only allowed for subscription products."
  end

  # --- callbacks: set_default_discover_fee_per_thousand ----------------------

  test "sets the boosted discover fee when the user has discover_boost_enabled" do
    user = create_user(discover_boost_enabled: true)
    product = build_product(user:)
    product.save
    assert_equal Link::DEFAULT_BOOSTED_DISCOVER_FEE_PER_THOUSAND, product.discover_fee_per_thousand
  end

  test "does not set the boosted discover fee without discover_boost_enabled" do
    user = create_user
    user.update!(discover_boost_enabled: false)
    product = build_product(user:)
    product.save
    assert_equal 100, product.discover_fee_per_thousand
  end

  # --- callbacks: initialize_tier_if_needed ----------------------------------

  test "membership product initializes a Tier category and default tier" do
    product = create_membership_product
    assert_equal "Tier", product.tier_category.title
    assert_equal "Untitled", product.tiers.first.name
  end

  test "membership product creates a default price for the default tier" do
    product = create_membership_product(price_cents: 600)
    prices = product.default_tier.prices
    assert_equal 1, prices.count
    assert_equal 600, prices.first.price_cents
    assert_equal "monthly", prices.first.recurrence
  end

  test "membership product creates a 0-cent price for the product itself" do
    product = create_membership_product(price_cents: 600)
    prices = product.prices
    assert_equal 1, prices.count
    assert_equal 0, prices.first.price_cents
    assert_equal "monthly", prices.first.recurrence
  end

  test "membership product defaults subscription_duration when not set" do
    product = create_membership_product(subscription_duration: nil)
    product.save(validate: false) # skip default price validation, which fails
    assert_equal BasePrice::Recurrence::DEFAULT_TIERED_MEMBERSHIP_RECURRENCE, product.subscription_duration
  end

  test "membership product sets tier prices correctly for single-unit currencies" do
    product = create_membership_product(price_currency_type: "jpy", price_cents: 5000)
    tier_price = product.default_tier.prices.first
    assert_equal "jpy", tier_price.currency
    assert_equal 5000, tier_price.price_cents
  end

  # --- content moderation on publish -----------------------------------------

  test "publish is blocked when the content moderation check fails" do
    product = create_product(purchase_disabled_at: Time.current)
    stub_publish_enforcements(product)
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: false, reasons: ["policy violation"])) do
      error = assert_raises(ActiveRecord::RecordInvalid) { product.publish! }
      assert_includes error.message, "looks like it contains something that may violate our content guidelines"
    end
    assert_not_nil product.reload.purchase_disabled_at
  end

  test "publish skips the content moderation check for VIP creators" do
    product = create_product(purchase_disabled_at: Time.current)
    stub_publish_enforcements(product)
    product.user.stub(:vip_creator?, true) do
      ContentModeration::ModerateRecordService.stub(:check, ->(*) { flunk "moderation check should be skipped for VIP creators" }) do
        product.publish!
      end
    end
    assert_nil product.reload.purchase_disabled_at
  end

  test "publish succeeds when the content moderation check passes" do
    product = create_product(purchase_disabled_at: Time.current)
    stub_publish_enforcements(product)
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: true)) do
      product.publish!
    end
    assert_nil product.reload.purchase_disabled_at
  end

  test "publish clears the publishing flag after it completes" do
    product = create_product(purchase_disabled_at: Time.current)
    stub_publish_enforcements(product)
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: true)) do
      product.publish!
    end
    assert_equal false, product.publishing?
  end

  test "publish clears the publishing flag even when it raises" do
    product = create_product(purchase_disabled_at: Time.current)
    stub_publish_enforcements(product)
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: false, reasons: ["bad"])) do
      assert_raises(ActiveRecord::RecordInvalid) { product.publish! }
    end
    assert_equal false, product.publishing?
  end

  # --- content moderation on edits to a published product --------------------

  test "editing a published product re-checks moderation when the name changes" do
    product = published_moderated_product
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: false, reasons: ["blocked term in name"])) do
      product.name = "New bad name"
      assert_equal false, product.save
      assert_includes product.errors.full_messages.to_sentence, "looks like it contains something that may violate our content guidelines"
    end
  end

  test "editing a published product re-checks moderation when the description changes" do
    product = published_moderated_product
    ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: false, reasons: ["blocked term in description"])) do
      product.description = "<p>New bad body</p>"
      assert_equal false, product.save
      assert_includes product.errors.full_messages.to_sentence, "looks like it contains something that may violate our content guidelines"
    end
  end

  test "editing a published product does not re-check moderation for unrelated attributes" do
    product = published_moderated_product
    ContentModeration::ModerateRecordService.stub(:check, ->(*) { flunk "moderation should not re-run on unrelated changes" }) do
      product.price_cents = product.price_cents + 100
      product.save!
    end
  end

  test "editing a draft product does not run moderation on name/description edits" do
    product = create_product(draft: true)
    ContentModeration::ModerateRecordService.stub(:check, ->(*) { flunk "moderation should not run on draft edits" }) do
      product.update!(name: "Still a draft", description: "<p>Still drafting</p>")
    end
  end

  # --- #purchase_type= -------------------------------------------------------

  test "purchase_type= accepts valid values" do
    product.purchase_type = :buy_only
    assert_equal "buy_only", product.purchase_type
    product.purchase_type = :rent_only
    assert_equal "rent_only", product.purchase_type
    product.purchase_type = :buy_and_rent
    assert_equal "buy_and_rent", product.purchase_type
  end

  test "purchase_type= defaults to buy_only for an invalid value" do
    product.purchase_type = "buy"
    assert_equal "buy_only", product.purchase_type
  end

  test "purchase_type= does not raise for an invalid value" do
    assert_nothing_raised { product.purchase_type = "invalid" }
    assert_equal "buy_only", product.purchase_type
  end

  # --- delete_unused_prices --------------------------------------------------

  test "switching to buy_only deletes rental prices" do
    product = create_product(purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 100)
    rental_price = product.prices.is_rental.first
    assert_equal 2, product.prices.alive.count
    product.update!(purchase_type: :buy_only)
    assert_equal 1, product.prices.alive.count
    assert_equal 0, product.prices.alive.is_rental.count
    assert rental_price.reload.deleted?
  end

  test "switching to rent_only deletes buy prices" do
    product = create_product(purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 100)
    buy_price = product.prices.is_buy.first
    product.update!(purchase_type: :rent_only)
    assert_equal 1, product.prices.alive.count
    assert_equal 0, product.prices.alive.is_buy.count
    assert buy_price.reload.deleted?
  end

  test "switching to buy_and_rent does not delete prices" do
    buy_product = create_product(purchase_type: :buy_only)
    assert_no_difference -> { buy_product.prices.alive.count } do
      buy_product.update!(purchase_type: :buy_and_rent)
    end

    rental_product = create_product(purchase_type: :rent_only, rental_price_cents: 100)
    assert_no_difference -> { rental_product.prices.alive.count } do
      rental_product.update!(purchase_type: :buy_and_rent)
    end
  end

  test "leaving purchase_type unchanged does not run delete_unused_prices" do
    product = create_product(purchase_type: :buy_and_rent, price_cents: 500, rental_price_cents: 100)
    called = false
    product.define_singleton_method(:delete_unused_prices) { |*| called = true }
    product.update!(purchase_type: :buy_and_rent)
    assert_equal false, called
  end

  # --- #rental ---------------------------------------------------------------

  test "rental returns nil for a buy-only product" do
    assert_nil create_product(purchase_type: :buy_only).rental
  end

  test "rental returns price and rent_only flag for a rent-only product" do
    product = create_product(purchase_type: :rent_only, rental_price_cents: 300)
    assert_equal({ price_cents: 300, rent_only: true }, product.rental)
  end

  test "rental returns price and rent_only flag for a buy-and-rent product" do
    product = create_product(purchase_type: :buy_and_rent, rental_price_cents: 200)
    assert_equal({ price_cents: 200, rent_only: false }, product.rental)
  end

  test "rental returns nil for a buy-and-rent product with no rental price" do
    product = create_product(purchase_type: :buy_and_rent, rental_price_cents: 200)
    product.prices.alive.is_rental.each(&:mark_deleted!)
    assert_nil product.reload.rental
  end

  test "rental returns nil for a rent-only product with no rental price" do
    product = create_product(purchase_type: :rent_only, rental_price_cents: 300)
    product.prices.alive.is_rental.each(&:mark_deleted!)
    assert_nil product.reload.rental
  end

  # --- initialize_suggested_amount_if_needed! --------------------------------

  test "non-coffee product does not initialize a suggested amount" do
    product = build_product(user: create_eligible_seller, price_cents: 200)
    product.save
    assert_equal 200, product.price_cents
    assert_empty product.variant_categories_alive
    assert_empty product.alive_variants
    assert_nil product.customizable_price
  end

  test "coffee product initializes a suggested amount category and resets the base price" do
    product = build_product(user: create_eligible_seller, price_cents: 200)
    product.native_type = Link::NATIVE_TYPE_COFFEE
    product.save!
    product.reload
    assert_equal 0, product.price_cents
    assert_equal "Suggested Amounts", product.variant_categories_alive.first.title
    assert_equal "", product.alive_variants.first.name
    assert_equal 200, product.alive_variants.first.price_difference_cents
    assert_equal true, product.customizable_price
  end

  # --- initialize_call_limitation_info_if_needed! ----------------------------

  test "non-call product does not create call limitation info" do
    product = build_product(user: create_eligible_seller, price_cents: 200)
    product.save
    assert_nil product.call_limitation_info
  end

  test "call product creates call limitation info with defaults" do
    product = build_product(user: create_eligible_seller, price_cents: 200)
    product.native_type = Link::NATIVE_TYPE_CALL
    product.save!
    info = product.call_limitation_info
    assert_equal CallLimitationInfo::DEFAULT_MINIMUM_NOTICE_IN_MINUTES, info.minimum_notice_in_minutes
    assert_nil info.maximum_calls_per_day
  end

  # --- initialize_duration_variant_category_for_calls! -----------------------

  test "call product creates a Duration variant category" do
    call = create_call_product
    assert_equal 1, call.variant_categories.count
    assert_equal "Duration", call.variant_categories.first.title
  end

  test "non-call product does not create a Duration variant category" do
    assert_equal 0, create_physical_product.variant_categories.count
  end

  # --- adding to profile sections --------------------------------------------

  test "new products are added to sections with add_new_products set" do
    seller = create_user
    default_sections = Array.new(2) { create_seller_profile_products_section(seller:) }
    other_sections = Array.new(2) { create_seller_profile_products_section(seller:, add_new_products: false) }
    product = create_product(user: seller)

    default_sections.each { |section| assert_includes section.reload.shown_products, product.id }
    other_sections.each { |section| assert_not_includes section.reload.shown_products, product.id }
  end

  test "adding to profile sections re-reads under the lock to avoid clobbering a concurrent change" do
    seller = create_user
    section = create_seller_profile_products_section(seller:, shown_products: [1, 2])
    # Prime a stale cached association, then commit a change it doesn't reflect,
    # as a concurrent writer would. add_to_profile_sections must re-read under the
    # lock and preserve that change rather than overwrite it with the stale list.
    seller.seller_profile_products_sections.load
    SellerProfileSection.find(section.id).update!(json_data: section.json_data.merge("shown_products" => [1, 2, 3]))

    product = create_product(user: seller)

    assert_equal [1, 2, 3, product.id].sort, section.reload.shown_products.sort
  end

  # --- associations ----------------------------------------------------------

  test "has_many self_service_affiliate_products with product_id foreign key" do
    reflection = Link.reflect_on_association(:self_service_affiliate_products)
    assert_equal :has_many, reflection.macro
    assert_equal "product_id", reflection.foreign_key.to_s
  end

  test "confirmed_collaborators returns only those who accepted the invitation" do
    product = create_product
    create_collaborator(pending_invitation: true, products: [product], deleted_at: 1.minute.ago)
    collaborator = create_collaborator(pending_invitation: true, products: [product])
    assert_empty product.confirmed_collaborators

    collaborator.collaborator_invitation.destroy!
    assert_equal [collaborator], product.confirmed_collaborators

    collaborator.mark_deleted!
    assert_equal [collaborator], product.reload.confirmed_collaborators
  end

  test "collaborator returns the live collaborator" do
    product = create_product
    create_collaborator(products: [product], deleted_at: 1.minute.ago)
    collaborator = create_collaborator(products: [product])
    assert_equal collaborator, product.collaborator
  end

  test "collaborator_for_display returns the collaborating user when shown as co-creator" do
    product = create_product
    collaborator = create_collaborator
    assert_nil product.collaborator_for_display

    collaborator.products = [product]
    Collaborator.any_instance.stubs(:show_as_co_creator_for_product?).returns(true)
    assert_equal collaborator.affiliate_user, product.collaborator_for_display

    Collaborator.any_instance.stubs(:show_as_co_creator_for_product?).returns(false)
    assert_nil product.collaborator_for_display
  end

  test "current_base_variants returns live variants and SKUs whose category is live" do
    product = create_physical_product

    size_category = create_variant_category(link: product, title: "Size")
    small_variant = create_variant(variant_category: size_category, name: "Small")
    create_variant(variant_category: size_category, name: "Large", deleted_at: Time.current)

    color_category = create_variant_category(link: product, title: "Color", deleted_at: Time.current)
    create_variant(variant_category: color_category, name: "Red")
    create_variant(variant_category: color_category, name: "Blue", deleted_at: Time.current)

    default_sku = product.skus.is_default_sku.first
    live_sku = create_sku(link: product, name: "Small-Red")
    create_sku(link: product, name: "Large-Blue", deleted_at: Time.current)

    assert_equal [small_variant, live_sku, default_sku].sort_by(&:id), product.current_base_variants.sort_by(&:id)
  end

  # --- publish! (scope) ------------------------------------------------------

  test "publish! publishes the product" do
    _user, product = publish_context
    product.publish!
    assert_nil product.reload.purchase_disabled_at
  end

  test "publish! retries on ActiveRecord::Deadlocked and succeeds" do
    _user, product = publish_context
    call_count = 0
    product.define_singleton_method(:save!) do |*args, **kwargs|
      call_count += 1
      raise ActiveRecord::Deadlocked if call_count <= 2
      super(*args, **kwargs)
    end
    assert_nothing_raised { product.publish! }
    assert_equal 3, call_count
  end

  test "publish! re-raises ActiveRecord::Deadlocked after exhausting retries" do
    _user, product = publish_context
    call_count = 0
    product.define_singleton_method(:save!) { |*| call_count += 1; raise ActiveRecord::Deadlocked }
    assert_raises(ActiveRecord::Deadlocked) { product.publish! }
    assert_equal 3, call_count
  end

  test "publish! raises when the user has not confirmed their email address" do
    user, product = publish_context
    user.update!(confirmed_at: nil)
    assert_raises(Link::LinkInvalid) { product.publish! }
    assert_equal "You have to confirm your email address before you can do that.", product.errors.full_messages.to_sentence
    assert_not_nil product.reload.purchase_disabled_at
  end

  test "publish! raises when a bundle has no alive products" do
    user, product = publish_context
    product.update!(is_bundle: true)
    BundleProduct.create!(bundle: product, product: create_product(user:), deleted_at: Time.current)
    assert_raises(ActiveRecord::RecordInvalid) { product.publish! }
    assert_equal "Bundles must have at least one product.", product.errors.full_messages.to_sentence
    assert_not_nil product.reload.purchase_disabled_at
  end

  test "publish! associates and notifies the seller's universal affiliates" do
    user, product = publish_context
    direct_affiliate = create_direct_affiliate(seller: user, apply_to_all_products: true)
    assert_enqueued_email_with(AffiliateMailer, :notify_direct_affiliate_of_new_product, args: [direct_affiliate.id, product.id]) do
      product.publish!
    end
    assert_equal [direct_affiliate], product.reload.direct_affiliates
    assert_equal [product], direct_affiliate.reload.products
  end

  test "publish! does not re-notify affiliates already associated with the product" do
    user, product = publish_context
    direct_affiliate = create_direct_affiliate(seller: user, apply_to_all_products: true, products: [product])
    assert_no_enqueued_emails { product.publish! }
    assert_equal [direct_affiliate], product.reload.direct_affiliates
    assert_equal [product], direct_affiliate.reload.products
  end

  test "publish! does not notify affiliates that have been removed" do
    user, product = publish_context
    direct_affiliate = create_direct_affiliate(seller: user, apply_to_all_products: true)
    direct_affiliate.mark_deleted!
    assert_no_enqueued_emails { product.publish! }
    assert_empty product.reload.direct_affiliates
    assert_empty direct_affiliate.reload.products
  end

  # --- #public_files / #communities ------------------------------------------

  test "public_files returns all public files for the product, including deleted" do
    product = create_product
    public_file = create_public_file(resource: product)
    deleted_public_file = create_public_file(resource: product, deleted_at: Time.current)
    create_public_file # a different product's file

    assert_equal [public_file, deleted_public_file], product.public_files
  end

  test "alive_public_files returns only live public files for the product" do
    product = create_product
    public_file = create_public_file(resource: product)
    create_public_file(resource: product, deleted_at: Time.current)
    create_public_file

    assert_equal [public_file], product.alive_public_files
  end

  test "communities returns all communities for the product, including deleted" do
    product = create_product
    communities = [
      create_community(resource: product, deleted_at: 1.minute.ago),
      create_community(resource: product),
    ]
    assert_equal communities.sort_by(&:id), product.communities.sort_by(&:id)
  end

  test "active_community returns the live community" do
    product = create_product
    create_community(resource: product, deleted_at: 1.minute.ago)
    community = create_community(resource: product)
    assert_equal community, product.active_community
  end

  # --- scopes ----------------------------------------------------------------

  test "alive scope returns only live products" do
    user = create_user
    create_product(user:, name: "alive")
    create_product(user:, purchase_disabled_at: Time.current)
    create_product(user:, deleted_at: Time.current)
    create_product(user:, banned_at: Time.current)

    assert_equal 1, user.links.alive.count
    assert_equal "alive", user.links.alive.first.name
  end

  test "visible scope excludes deleted products but includes archived ones" do
    user = create_user
    create_product(user:, deleted_at: Time.current)
    product = create_product(user:)
    archived_product = create_product(user:, archived: true)

    assert_equal 2, user.links.visible.count
    assert_equal [product, archived_product], user.links.visible
  end

  test "visible_and_not_archived scope excludes deleted and archived products" do
    user = create_user
    create_product(user:, deleted_at: Time.current)
    product = create_product(user:)
    create_product(user:, archived: true)

    assert_equal 1, user.links.visible_and_not_archived.count
    assert_equal [product], user.links.visible_and_not_archived
  end

  test "by_general_permalink matches by unique permalink" do
    product = create_product(unique_permalink: "xxx")
    create_product(unique_permalink: "yyy", custom_permalink: "custom")
    assert_equal [product], Link.by_general_permalink("xxx")
  end

  test "by_general_permalink matches by custom permalink" do
    create_product(unique_permalink: "xxx")
    product = create_product(unique_permalink: "yyy", custom_permalink: "custom")
    assert_equal [product], Link.by_general_permalink("custom")
  end

  test "by_general_permalink does not match a blank permalink" do
    create_product(unique_permalink: "yyy", custom_permalink: "custom")
    assert_empty Link.by_general_permalink(nil)
    assert_empty Link.by_general_permalink("")
  end

  test "by_unique_permalinks matches by unique permalink only" do
    product_1 = create_product(unique_permalink: "xxx")
    product_2 = create_product(unique_permalink: "yyy", custom_permalink: "custom")
    assert_equal [product_1, product_2].sort_by(&:id), Link.by_unique_permalinks(%w[xxx yyy]).sort_by(&:id)
  end

  test "by_unique_permalinks does not match custom permalinks" do
    create_product(unique_permalink: "yyy", custom_permalink: "custom")
    create_product(unique_permalink: "zzz", custom_permalink: "awesome")
    assert_empty Link.by_unique_permalinks(%w[awesome custom])
  end

  test "by_unique_permalinks ignores permalinks that do not match" do
    product_1 = create_product(unique_permalink: "xxx")
    create_product(unique_permalink: "yyy", custom_permalink: "custom")
    assert_equal [product_1], Link.by_unique_permalinks(%w[xxx custom])
  end

  test "by_unique_permalinks returns nothing when given no permalinks" do
    assert_empty Link.by_unique_permalinks([])
  end

  test "unpublished products are those with a purchase_disabled_at" do
    user = create_user
    create_product(user:)
    create_product(user:, purchase_disabled_at: Time.current, name: "unpublished")

    unpublished = user.links.where.not(purchase_disabled_at: nil)
    assert_equal 1, unpublished.count
    assert_equal "unpublished", unpublished.first.name
  end

  test "deleted scope returns only deleted products" do
    user = create_user
    create_product(user:)
    create_product(user:, deleted_at: Time.current, name: "deleted")
    assert_equal 1, user.links.deleted.count
    assert_equal "deleted", user.links.deleted.first.name
  end

  test "has_paid_sales scope returns products with successful sales" do
    user = create_user
    product = create_product(user:, name: "paid_download")
    3.times { create_purchase(link: product, purchase_state: "successful") }
    create_product(user:)
    assert_equal 1, user.links.has_paid_sales.count
    assert_equal product.id, user.links.has_paid_sales.first.id
  end

  test "not_draft scope excludes drafts" do
    user = create_user
    product = create_product(user:, draft: false)
    create_product(user:, draft: true)
    assert_equal 1, user.links.not_draft.count
    assert_equal product.id, user.links.not_draft.first.id
  end

  test "created_between scope returns products created within the range" do
    user = create_user
    product = create_product(user:, created_at: 2.days.ago)
    create_product(user:, created_at: 6.days.ago)
    scoped = user.links.created_between(3.days.ago..Time.current)
    assert_equal 1, scoped.count
    assert_equal product.id, scoped.first.id
  end

  test "has_paid_sales_between returns products with sales in the window" do
    recent = create_product
    old = create_product
    create_purchase(link: recent, created_at: 1.minute.ago)
    create_purchase(link: old, created_at: 2.weeks.ago)
    result = Link.has_paid_sales_between(1.week.ago, Time.current)
    assert_includes result, recent
    assert_not_includes result, old
  end

  test "membership scope returns membership products" do
    membership = create_subscription_product
    create_product
    assert_equal [membership], Link.membership
  end

  test "non_membership scope returns non-membership products" do
    # Link.non_membership is a global scope, so (unlike the clean-DB RSpec run)
    # it also returns the shared fixture product; assert inclusion/exclusion.
    product = create_product
    membership = create_subscription_product
    assert_includes Link.non_membership, product
    assert_not_includes Link.non_membership, membership
  end

  test "collabs_as_collaborator returns products the user is a collaborator on" do
    user = create_user

    # collabs I created (not returned)
    3.times do
      product = create_product(user:)
      create_product_affiliate(product:, affiliate: create_collaborator(seller: user))
    end

    # products I'm a collaborator on (returned)
    seller = create_user
    seller_collabs = Array.new(2) { create_product(user: seller) }
    collaborator = create_collaborator(affiliate_user: user, seller:)
    seller_collabs.each { |product| create_product_affiliate(product:, affiliate: collaborator) }

    # products I'm no longer a collaborator on (not returned)
    seller_old_collab = create_product(user: seller)
    old_collaborator = create_collaborator(affiliate_user: user, seller:, deleted_at: 1.day.ago)
    create_product_affiliate(product: seller_old_collab, affiliate: old_collaborator)

    # products others are collaborators on (not returned)
    2.times do
      product = create_product(user: seller)
      create_product_affiliate(product:, affiliate: create_collaborator(seller:))
    end

    # products I'm invited to collaborate on (not returned)
    inviter = create_user
    create_collaborator(affiliate_user: user, seller: inviter, pending_invitation: true,
                        products: Array.new(2) { create_product(user: inviter) })

    # non-collab products (not returned)
    create_product(user:)
    create_product(user: seller)

    # collab products where I have a prior non-collaborator affiliate association (not returned)
    other_collabs = Array.new(2) { create_collab_product(user: seller) }
    create_direct_affiliate(affiliate_user: user, seller:, products: [other_collabs.first])
    create_product_affiliate(affiliate: user.global_affiliate, product: other_collabs.last)

    assert_equal seller_collabs.map(&:id).sort, Link.collabs_as_collaborator(user).pluck(:id).sort
  end

  test "collabs_as_seller_or_collaborator returns collabs the user created and collaborates on" do
    user = create_user

    own_collabs = Array.new(3) do
      product = create_product(user:)
      create_product_affiliate(product:, affiliate: create_collaborator(seller: user))
      product
    end

    seller1 = create_user
    seller1_collabs = Array.new(2) { create_product(user: seller1) }
    collaborator = create_collaborator(affiliate_user: user, seller: seller1)
    seller1_collabs.each { |product| create_product_affiliate(product:, affiliate: collaborator) }

    seller2 = create_user
    seller2_collab = create_product(user: seller2)
    create_product_affiliate(product: seller2_collab, affiliate: create_collaborator(affiliate_user: user, seller: seller2))

    # no longer a collaborator
    seller1_old_collab = create_product(user: seller1)
    create_product_affiliate(product: seller1_old_collab, affiliate: create_collaborator(affiliate_user: user, seller: seller1, deleted_at: 1.day.ago))

    # others' collabs
    Array.new(2) { create_product(user: seller1) }.each { |product| create_product_affiliate(product:, affiliate: create_collaborator(seller: seller1)) }
    create_product_affiliate(product: create_product(user: seller2), affiliate: create_collaborator(seller: seller2))

    # invited (pending)
    inviter = create_user
    create_collaborator(affiliate_user: user, seller: inviter, pending_invitation: true, products: Array.new(2) { create_product(user: inviter) })

    # non-collab
    create_product(user:)
    create_product(user: seller1)
    create_product(user: seller2)
    create_direct_affiliate(affiliate_user: user, products: [create_product])

    # collab products with prior affiliate associations
    other_collabs = Array.new(2) { create_collab_product(user: seller1) }
    create_direct_affiliate(affiliate_user: user, seller: seller1, products: [other_collabs.first])
    create_product_affiliate(affiliate: user.global_affiliate, product: other_collabs.last)

    expected = own_collabs.map(&:id) + seller1_collabs.map(&:id) + [seller2_collab.id]
    assert_equal expected.sort, Link.collabs_as_seller_or_collaborator(user).pluck(:id).sort
  end

  test "for_balance_page returns the user's own products and collab products" do
    user = create_user

    own_collabs = Array.new(3) do
      product = create_product(user:)
      create_product_affiliate(product:, affiliate: create_collaborator(seller: user))
      product
    end

    seller = create_user
    seller_collabs = Array.new(2) { create_product(user: seller) }
    collaborator = create_collaborator(affiliate_user: user, seller:)
    seller_collabs.each { |product| create_product_affiliate(product:, affiliate: collaborator) }

    # no longer a collaborator
    seller_old_collab = create_product(user: seller)
    create_product_affiliate(product: seller_old_collab, affiliate: create_collaborator(affiliate_user: user, seller:, deleted_at: 1.day.ago))

    # others' collabs
    Array.new(2) { create_product(user: seller) }.each { |product| create_product_affiliate(product:, affiliate: create_collaborator(seller:)) }

    non_collabs = Array.new(2) { create_product(user:) }
    create_product(user: seller)

    other_collabs = Array.new(2) { create_collab_product(user: seller) }
    create_direct_affiliate(affiliate_user: user, seller:, products: [other_collabs.first])
    create_product_affiliate(affiliate: user.global_affiliate, product: other_collabs.last)

    expected = (own_collabs + seller_collabs + non_collabs).map(&:id)
    assert_equal expected.sort, Link.for_balance_page(user).pluck(:id).sort
  end

  test "not_call scope excludes call products" do
    call_product = create_call_product
    product = create_product
    assert_includes Link.not_call, product
    assert_not_includes Link.not_call, call_product
  end

  # --- custom_permalink validity ---------------------------------------------

  test "custom_permalink is valid with numbers, letters, underscores, and dashes" do
    assert build_product(custom_permalink: "a23f").valid?
    assert build_product(custom_permalink: "asdfsdf").valid?
    assert build_product(custom_permalink: "asdf_asdf").valid?
    assert build_product(custom_permalink: "asdf-asdf").valid?
  end

  test "custom_permalink is invalid with special characters" do
    assert_not build_product(custom_permalink: "asdf&asdf").valid?
    assert_not build_product(custom_permalink: "asdf*23sdf").valid?
    assert_not build_product(custom_permalink: "asdf!213").valid?
  end

  test "custom_permalink is invalid when it duplicates another product's custom permalink for the same user" do
    user = create_user
    create_product(user:, custom_permalink: "custom")
    assert_not build_product(user:, custom_permalink: "custom").valid?
  end

  test "custom_permalink is invalid when it duplicates another product's unique permalink for the same user" do
    user = create_user
    create_product(user:, unique_permalink: "abc")
    assert_not build_product(user:, custom_permalink: "abc").valid?
  end

  test "custom_permalink is valid when it duplicates another user's unique permalink" do
    create_product(user: create_user, unique_permalink: "abc")
    assert build_product(user: create_user, custom_permalink: "abc").valid?
  end

  test "custom_permalink is valid when it duplicates another user's custom permalink" do
    create_product(user: create_user, custom_permalink: "custom")
    assert build_product(user: create_user, custom_permalink: "custom").valid?
  end

  test "custom_permalink lookup is case-insensitive" do
    product = create_product(custom_permalink: "custom")
    assert_equal product, Link.find_by(custom_permalink: "custom")
    assert_equal product, Link.find_by(custom_permalink: "CUSTOM")
  end

  # --- unique_permalink ------------------------------------------------------

  test "unique_permalink is invalid with numbers" do
    assert_not build_product(unique_permalink: "a23f").valid?
  end

  test "unique_permalink is valid with underscores" do
    assert build_product(unique_permalink: "a_b_c_d").valid?
  end

  test "unique_permalink lookup is case-insensitive" do
    product = create_product(unique_permalink: "abc")
    assert_equal product, Link.find_by(unique_permalink: "abc")
    assert_equal product, Link.find_by(unique_permalink: "ABC")
  end

  test "unique_permalink generation picks the shortest non-conflicting value" do
    ("a".."z").each { |ch| create_product(unique_permalink: ch) }
    assert_equal 2, create_product.unique_permalink.length
  end

  test "unique_permalink generation may reuse a letter taken only by a custom permalink of another user" do
    ("a".."z").each { |ch| create_product(unique_permalink: ch * 2, custom_permalink: ch) }
    assert_equal 1, create_product.unique_permalink.length
  end

  test "unique_permalink generation avoids conflicts with the same user's custom permalinks" do
    user = create_user
    ("a".."z").each { |ch| create_product(user:, unique_permalink: ch * 2, custom_permalink: ch) }
    assert_not_equal 1, create_product(user:).unique_permalink.length
  end

  test "unique_permalink generation is lowercase and avoids uppercase duplicates" do
    ("A".."Z").each { |ch| create_product(unique_permalink: ch) }
    product = create_product
    assert_match(/\A[a-z]+\z/, product.unique_permalink)
    assert_equal 2, product.unique_permalink.length
  end

  private
    # Lazily-created base product (like the RSpec `let(:link)`). Kept lazy so the
    # permalink-generation tests, which fill up short permalinks, don't collide
    # with an eagerly-created product's auto-assigned short permalink.
    def product
      @product ||= create_product
    end

    # A confirmed seller with a merchant account and an unpublished product
    # carrying a file — the real starting point for the publish! scope tests
    # (substituting a plain merchant account for the VCR-backed Stripe one).
    def publish_context
      user = create_user
      create_merchant_account(user:)
      product = create_product(user:, purchase_disabled_at: Time.current)
      create_product_file(link: product)
      [user, product]
    end

    # A published product whose non-moderation publish gates are stubbed and
    # whose initial publish passed moderation — the starting point for the
    # "edit a published product" moderation tests.
    def published_moderated_product
      product = create_product(purchase_disabled_at: Time.current)
      stub_publish_enforcements(product)
      ContentModeration::ModerateRecordService.stub(:check, moderation_result(passed: true)) { product.publish! }
      product
    end

    # publish! runs several enforcement gates unrelated to content moderation;
    # the RSpec block stubs them out so the moderation behavior can be tested in
    # isolation. Singleton methods on the instance mirror `allow(product).to receive`.
    def stub_publish_enforcements(product)
      %i[
        enforce_shipping_destinations_presence!
        enforce_user_email_confirmation!
        enforce_merchant_account_exits_for_new_users!
        enable_transcode_videos_on_purchase!
      ].each { |m| product.define_singleton_method(m) { |*| true } }
      product.define_singleton_method(:auto_transcode_videos?) { false }
    end
end
