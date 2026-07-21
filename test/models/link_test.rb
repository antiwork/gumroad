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

  # The licensed-permalink tests seed force_product_id_timestamp in Redis, which
  # (unlike the DB) isn't rolled back between tests. Clear it so it can't leak
  # into other tests' permalink validation.
  teardown { $redis.del(RedisKey.force_product_id_timestamp) }

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

  # --- publish!: video transcoding -------------------------------------------

  test "creating a video file on a draft product does not enqueue transcoding" do
    product = create_product(draft: true)
    product.user.stubs(:auto_transcode_videos?).returns(true)
    create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter2.mp4", filetype: "mp4")

    assert_equal 0, TranscodeVideoForStreamingWorker.jobs.size
  end

  test "publish! transcodes only the product files whose queue_for_transcoding? is true" do
    _, product = publish_context
    User.any_instance.stubs(:auto_transcode_videos?).returns(true)
    file1 = create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter2.mp4", filetype: "mp4")
    file2 = create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter3.mp4", filetype: "mp4")
    file3 = create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter4.mp4", filetype: "mp4")
    file3.delete!

    # Freshly-created files aren't analyzed, so queue_for_transcoding? is false.
    product.publish!
    assert_equal 0, TranscodeVideoForStreamingWorker.jobs.size
    product.unpublish!

    ProductFile.any_instance.stubs(:queue_for_transcoding?).returns(true)
    product.publish!
    enqueued = TranscodeVideoForStreamingWorker.jobs.map { |job| job["args"].first }
    assert_includes enqueued, file1.id
    assert_includes enqueued, file2.id
    assert_not_includes enqueued, file3.id
  end

  test "publish! transcodes videos when auto-transcode is enabled" do
    _, product = publish_context
    video_file = create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter2.mp4", filetype: "mp4")
    product.stubs(:auto_transcode_videos?).returns(true)
    ProductFile.any_instance.stubs(:queue_for_transcoding?).returns(true)

    product.publish!
    assert_includes TranscodeVideoForStreamingWorker.jobs.map { |job| job["args"].first }, video_file.id
  end

  test "publish! does not transcode videos when auto-transcode is disabled" do
    _, product = publish_context
    create_streamable_video(link: product, url: "#{S3_BASE_URL}specs/chapter2.mp4", filetype: "mp4")
    product.stubs(:auto_transcode_videos?).returns(false)

    assert_no_difference -> { TranscodeVideoForStreamingWorker.jobs.size } do
      product.publish!
    end
  end

  test "publish! enables transcode-on-purchase when auto-transcode is disabled" do
    _, product = publish_context
    product.update!(transcode_videos_on_purchase: false)
    product.stubs(:auto_transcode_videos?).returns(false)

    product.publish!
    assert product.reload.transcode_videos_on_purchase?
  end

  test "adding and analyzing a video on a published product triggers transcoding" do
    skip "exercises ProductFile#analyze's transcoding trigger, which needs FFMPEG::Movie + S3 doubles; belongs to product_file coverage"
  end

  # --- publish!: merchant account enforcement --------------------------------

  test "publish! raises LinkInvalid when a new account has no valid merchant account" do
    user = create_user
    merchant = create_merchant_account(user:)
    product = create_product(user:, purchase_disabled_at: Time.current)
    create_product_file(link: product)
    user.check_merchant_account_is_linked = true
    user.update!(payment_address: nil)
    merchant.mark_deleted!

    assert_raises(Link::LinkInvalid) { product.publish! }
    assert_not_nil product.reload.purchase_disabled_at
  end

  test "a failed publish! does not associate or notify the seller's universal affiliates" do
    user = create_user
    merchant = create_merchant_account(user:)
    product = create_product(user:, purchase_disabled_at: Time.current)
    create_product_file(link: product)
    user.check_merchant_account_is_linked = true
    user.update!(payment_address: nil)
    merchant.mark_deleted!
    affiliate = create_direct_affiliate(seller: user, apply_to_all_products: true)

    assert_no_enqueued_emails { product.publish! rescue nil }
    assert_empty product.reload.direct_affiliates
    assert_empty affiliate.reload.products
  end

  test "publish! succeeds under merchant migration when a valid merchant account is connected" do
    user, product = publish_context
    Feature.activate_user(:merchant_migration, user)
    product.publish!
    assert_nil product.reload.purchase_disabled_at
  ensure
    Feature.deactivate_user(:merchant_migration, user)
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

  test "can_be_bundle scope returns only products eligible to be bundles" do
    bundle = create_bundle
    membership = create_membership_product
    versioned = create_product_with_digital_versions
    call = create_call_product
    product = create_product

    result = Link.can_be_bundle
    assert_includes result, product
    assert_includes result, bundle
    bundle.bundle_products.each { |bp| assert_includes result, bp.product }
    assert_not_includes result, membership
    assert_not_includes result, versioned
    assert_not_includes result, call
  end

  test "with_latest_product_cached_values joins the latest cached-value row per product" do
    user = create_user
    product_1 = create_product(user:)
    create_product_cached_value(product: product_1)
    product_1_latest = create_product_cached_value(product: product_1)
    product_2 = create_product(user:)
    product_2_cached_value = create_product_cached_value(product: product_2)
    product_3 = create_product(user:) # no cached value → left-join nil

    results = Link.where(user:)
                  .with_latest_product_cached_values(user_id: user.id)
                  .select("links.id, latest_product_cached_values.id as lpcvid")
                  .order(:id)
    assert_equal product_1.id, results[0].id
    assert_equal product_1_latest.id, results[0].lpcvid
    assert_equal product_2.id, results[1].id
    assert_equal product_2_cached_value.id, results[1].lpcvid
    assert_equal product_3.id, results[2].id
    assert_nil results[2].lpcvid
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

  test "a licensed product created before force_product_id_timestamp is invalid when its custom permalink overlaps another seller's licensed product" do
    timestamp = seed_licensed_permalink_conflict
    product = create_product(is_licensed: true, created_at: timestamp - 1.day)
    assert_equal false, product.update(custom_permalink: "abc")
    assert_equal "Custom permalink has already been taken", product.errors.full_messages.to_sentence
  end

  test "switching a pre-timestamp product to licensed is invalid when its custom permalink overlaps another seller's licensed product" do
    timestamp = seed_licensed_permalink_conflict
    product = create_product(custom_permalink: "abc", created_at: timestamp - 1.day)
    assert_equal false, product.update(is_licensed: true)
    assert_equal "Custom permalink has already been taken", product.errors.full_messages.to_sentence
  end

  # The overlap validation must be correctly scoped — it should NOT fire in these
  # cases, mirroring the RSpec "product is valid" shared examples.

  test "an unpersisted licensed product with a conflicting permalink is valid" do
    seed_licensed_permalink_conflict
    assert build_product(is_licensed: true, custom_permalink: "abc").valid?
    assert build_product(is_licensed: true, custom_permalink: "xyz").valid?
  end

  test "a licensed product created after force_product_id_timestamp can take a conflicting permalink" do
    timestamp = seed_licensed_permalink_conflict
    %w[abc xyz].each do |permalink|
      product = create_product(is_licensed: true, created_at: timestamp + 1.day)
      assert product.update(custom_permalink: permalink), product.errors.full_messages.to_sentence
    end
  end

  test "a non-licensed product created before the timestamp can take a conflicting permalink" do
    timestamp = seed_licensed_permalink_conflict
    %w[abc xyz].each do |permalink|
      product = create_product(is_licensed: false, created_at: timestamp - 1.day)
      assert product.update(custom_permalink: permalink), product.errors.full_messages.to_sentence
    end
  end

  test "a licensed product is valid when the other seller's licensed product was created after the timestamp" do
    timestamp = seed_licensed_permalink_conflict
    @other_licensed_product.update!(created_at: timestamp + 1.day)
    %w[abc xyz].each do |permalink|
      product = create_product(is_licensed: true, created_at: timestamp - 1.day)
      assert product.update(custom_permalink: permalink), product.errors.full_messages.to_sentence
    end
  end

  test "a product created after the timestamp can become licensed despite a permalink overlap" do
    timestamp = seed_licensed_permalink_conflict
    product = create_product(custom_permalink: "abc", created_at: timestamp + 1.day)
    assert product.update(is_licensed: true), product.errors.full_messages.to_sentence
  end

  test "a product can become licensed when the other seller's licensed product was created after the timestamp" do
    timestamp = seed_licensed_permalink_conflict
    @other_licensed_product.update!(created_at: timestamp + 1.day)
    product = create_product(custom_permalink: "abc", created_at: timestamp - 1.day)
    assert product.update(is_licensed: true), product.errors.full_messages.to_sentence
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

  # --- .fetch_leniently ------------------------------------------------------

  test "fetch_leniently by unique permalink fetches, scopes to user, and skips deleted" do
    ctx = fetch_leniently_context
    assert_equal ctx[:product_1], Link.fetch_leniently("aaa")
    assert_equal ctx[:product_1], Link.fetch_leniently("aaa", user: ctx[:user_1])
    assert_nil Link.fetch_leniently("aaa", user: ctx[:user_2])
    assert_nil Link.fetch_leniently("ccc") # deleted
  end

  test "fetch_leniently by custom permalink fetches oldest, per-user, and skips deleted" do
    ctx = fetch_leniently_context
    assert_equal ctx[:product_2], Link.fetch_leniently("custom") # oldest
    assert_equal ctx[:product_6], Link.fetch_leniently("custom", user: ctx[:user_2])
    assert_equal ctx[:product_5], Link.fetch_leniently("awesome", user: ctx[:user_2])
    assert_nil Link.fetch_leniently("awesome", user: ctx[:user_1])
    assert_nil Link.fetch_leniently("no-longer-alive") # deleted
  end

  test "fetch_leniently uses a legacy permalink mapping when present" do
    ctx = fetch_leniently_context
    # no mapping yet
    assert_equal ctx[:product_2], Link.fetch_leniently("custom")
    assert_equal ctx[:product_6], Link.fetch_leniently("custom", user: ctx[:user_2])

    LegacyPermalink.create!(permalink: "custom", product: ctx[:product_6])
    assert_equal ctx[:product_6], Link.fetch_leniently("custom")

    ctx[:product_6].mark_deleted!
    assert_equal ctx[:product_2], Link.fetch_leniently("custom") # falls back past the deleted mapped product

    assert_equal ctx[:product_2], Link.fetch_leniently("custom", user: ctx[:user_1])
  end

  # --- .fetch ----------------------------------------------------------------

  test "fetch matches by unique permalink only, scopes to user, and skips deleted" do
    user_1 = create_user
    product_1 = create_product(user: user_1, unique_permalink: "aaa")
    create_product(user: user_1, unique_permalink: "bbb", custom_permalink: "custom")
    create_product(user: user_1, unique_permalink: "ccc", custom_permalink: "no-longer-alive", deleted_at: Time.current)
    user_2 = create_user
    create_product(user: user_2, unique_permalink: "ddd", custom_permalink: "custom")

    assert_equal product_1, Link.fetch("aaa")
    assert_nil Link.fetch("custom") # custom permalinks aren't matched by fetch
    assert_equal product_1, Link.fetch("aaa", user: user_1)
    assert_nil Link.fetch("aaa", user: user_2)
    assert_nil Link.fetch("ccc") # deleted
  end

  # --- #matches_permalink? ---------------------------------------------------

  test "matches_permalink? matches unique and custom permalinks case-insensitively" do
    product = build_product(unique_permalink: "aB1", custom_permalink: "custom")
    assert_equal false, product.matches_permalink?("invalid")
    assert_equal true, product.matches_permalink?("aB1")
    assert_equal true, product.matches_permalink?("ab1")
    assert_equal false, product.matches_permalink?("aB") # partial
    assert_equal true, product.matches_permalink?("custom")
    assert_equal true, product.matches_permalink?("CUSTOM")
    assert_equal false, product.matches_permalink?("custo") # partial
  end

  test "matches_permalink? returns false for a blank permalink when custom is blank" do
    product = build_product
    assert_equal false, product.matches_permalink?(nil)
    assert_equal false, product.matches_permalink?("")
  end

  # --- name ------------------------------------------------------------------

  test "name is invalid when too long" do
    assert_not build_product(name: "hi there" * 255).valid?
  end

  # --- #bundle_is_not_in_bundle ----------------------------------------------

  test "a product not in any bundle can become a bundle" do
    product = create_product(draft: true, purchase_disabled_at: Time.current)
    product.is_bundle = true
    product.save
    assert_empty product.errors
  end

  test "a product already in a bundle cannot become a bundle" do
    product = create_product(draft: true, purchase_disabled_at: Time.current)
    bundle = create_product(user: product.user, is_bundle: true)
    BundleProduct.create!(product:, bundle:)
    product.is_bundle = true
    product.save
    assert_equal ["This product cannot be converted to a bundle because it is already part of a bundle."], product.errors.full_messages
  end

  test "a product formerly in a bundle can become a bundle" do
    product = create_product(draft: true, purchase_disabled_at: Time.current)
    bundle = create_product(user: product.user, is_bundle: true)
    BundleProduct.create!(product:, bundle:, deleted_at: Time.current)
    product.is_bundle = true
    product.save
    assert_empty product.errors
  end

  # --- multifile_aware_product_file_info / removed_file_info_attributes ------

  test "multifile_aware_product_file_info returns file info for a single-file product only" do
    one_file = create_product(size: 200)
    create_product_file(link: one_file, size: 300, pagelength: 7)
    two_files = create_product(size: 400)
    create_product_file(link: two_files, size: 500, pagelength: 1)
    create_product_file(link: two_files, size: 600, pagelength: 2)

    assert_equal({ Size: "300 Bytes", Length: "7 pages" }, one_file.multifile_aware_product_file_info)
    assert_equal({}, two_files.multifile_aware_product_file_info)
  end

  test "removed_file_info_attributes accumulates removed attributes" do
    link = build_product
    assert_equal [], link.removed_file_info_attributes
    link.add_removed_file_info_attributes([:Size])
    assert_equal [:Size], link.removed_file_info_attributes
    link.add_removed_file_info_attributes([:Length])
    assert_equal %i[Size Length], link.removed_file_info_attributes
  end

  # --- #remaining_for_sale_count ---------------------------------------------

  test "remaining_for_sale_count defaults to nil" do
    assert_nil product.max_purchase_count
    assert_nil product.remaining_for_sale_count
  end

  test "remaining_for_sale_count uses a tier's max_purchase_count when the product has none" do
    membership = create_membership_product
    membership.tiers.first.update!(max_purchase_count: 100)
    assert_equal 100, membership.remaining_for_sale_count
    membership.tiers.first.update!(max_purchase_count: 200)
    assert_equal 200, membership.remaining_for_sale_count
  end

  test "remaining_for_sale_count equals max_purchase_count when no sales have been made" do
    product = create_product(max_purchase_count: 50)
    assert_equal 50, product.remaining_for_sale_count
  end

  test "remaining_for_sale_count decrements by successful sales only" do
    product = create_product(max_purchase_count: 50)
    create_purchase(link: product)
    create_purchase(link: product)
    create_purchase(link: product, purchase_state: "failed")
    assert_equal 48, product.remaining_for_sale_count
  end

  test "remaining_for_sale_count returns the minimum across a bundle and its bundled products" do
    bundle = create_bundle(max_purchase_count: 3)
    assert_equal 3, bundle.remaining_for_sale_count
    bundle.bundle_products.second.product.update!(max_purchase_count: 2)
    assert_equal 2, bundle.remaining_for_sale_count
    bundle_product = bundle.bundle_products.first
    variant = create_variant(variant_category: create_variant_category(link: bundle_product.product), max_purchase_count: 1)
    bundle_product.update!(variant:)
    assert_equal 1, bundle.remaining_for_sale_count
  end

  test "remaining_for_sale_count excludes deleted bundle products" do
    bundle = create_bundle(max_purchase_count: 3)
    assert_equal 3, bundle.remaining_for_sale_count
    bundle.bundle_products.second.product.update!(max_purchase_count: 2)
    assert_equal 2, bundle.remaining_for_sale_count
    bundle.bundle_products.second.mark_deleted!
    assert_equal 3, bundle.remaining_for_sale_count
  end

  test "remaining_for_sale_count treats a nil sales_count_for_inventory as zero" do
    product = create_product(max_purchase_count: 100)
    product.stubs(:sales_count_for_inventory).returns(nil)
    assert_nothing_raised { product.remaining_for_sale_count }
    assert_equal 100, product.remaining_for_sale_count
  end

  # --- #remaining_call_availabilities ----------------------------------------

  test "remaining_call_availabilities delegates to ComputeCallAvailabilitiesService" do
    call_product = create_call_product
    service = mock
    Product::ComputeCallAvailabilitiesService.expects(:new).with(call_product).returns(service)
    service.expects(:perform)

    call_product.remaining_call_availabilities
  end

  # --- #plaintext_description ------------------------------------------------

  test "plaintext_description keeps a normal description the same" do
    assert_equal "I like pie.", create_product(description: "I like pie.").plaintext_description
  end

  test "plaintext_description strips html" do
    assert_equal "I like pie. Do you?", create_product(description: "I like <strong><u>pie</u></strong>. Do you?").plaintext_description
  end

  test "plaintext_description encodes lone angle brackets" do
    assert_equal "some &lt; text &gt;", create_product(description: "some < text >").plaintext_description
  end

  test "plaintext_description does not encode apostrophes" do
    assert_equal "The world's foremost", create_product(description: "The world's foremost").plaintext_description
  end

  # --- suggested_price_cents -------------------------------------------------

  test "suggested_price sets suggested_price_cents" do
    link = create_product
    link.suggested_price = 4
    assert_equal 400, link.suggested_price_cents
    link.suggested_price = nil
    assert_nil link.suggested_price_cents
  end

  test "suggested_price_formatted is correct" do
    assert_equal "4", create_product(suggested_price_cents: 400).suggested_price_formatted
  end

  test "suggested_price_cents cannot be less than price_cents" do
    link = create_product
    link.price_range = "2+"
    link.suggested_price_cents = 100
    assert_equal false, link.valid?
  end

  test "suggested_price_cents is not validated for non-customizable prices" do
    link = create_product(price_cents: 200)
    link.suggested_price_cents = 100
    assert link.valid?
  end

  # --- #default_price / #default_price_recurrence ----------------------------

  test "default_price returns the last price for a non-recurring product" do
    product = create_product
    create_price(link: product, price_cents: 100)
    last_price = create_price(link: product, price_cents: 200)
    assert_equal last_price, product.reload.default_price
  end

  test "default_price returns the recurrence-matched price for a non-tiered recurring product" do
    product = create_subscription_product(subscription_duration: BasePrice::Recurrence::MONTHLY)
    monthly_price = create_price(link: product, recurrence: BasePrice::Recurrence::MONTHLY)
    create_price(link: product, recurrence: BasePrice::Recurrence::YEARLY)
    assert_equal monthly_price, product.reload.default_price
  end

  test "default_price returns the recurrence-matched price for a tiered membership product" do
    recurrence_price_values = Array.new(2) do
      { BasePrice::Recurrence::MONTHLY => { enabled: true, price: 2 }, BasePrice::Recurrence::YEARLY => { enabled: true, price: 2 } }
    end
    product = create_membership_product_with_preset_tiered_pricing(subscription_duration: BasePrice::Recurrence::YEARLY, recurrence_price_values:)
    yearly_price = product.prices.alive.find_by!(recurrence: BasePrice::Recurrence::YEARLY)
    assert_equal yearly_price, product.default_price
  end

  test "default_price_recurrence returns the price matching the product's subscription duration" do
    product = create_membership_product(subscription_duration: BasePrice::Recurrence::MONTHLY)
    monthly_price = product.prices.find_by!(recurrence: BasePrice::Recurrence::MONTHLY)
    yearly_price = create_price(link: product, recurrence: BasePrice::Recurrence::YEARLY)
    create_price(link: product, recurrence: BasePrice::Recurrence::QUARTERLY)
    assert_equal monthly_price, product.reload.default_price_recurrence

    product.update!(subscription_duration: BasePrice::Recurrence::YEARLY)
    assert_equal yearly_price, product.reload.default_price_recurrence
  end

  test "default_price_recurrence returns nil for a non-recurring product" do
    product = create_product
    create_price(link: product)
    assert_nil product.default_price_recurrence
  end

  # --- #price_range ----------------------------------------------------------

  test "price_range can be assigned a number" do
    product.price_range = 1
    assert_equal 100, product.price_cents
    product.price_range = 1.01
    assert_equal 101, product.price_cents
    product.price_range = 10.01
    assert_equal 1001, product.price_cents
  end

  test "price_range absorbs random data" do
    product.price_range = "1sdlkjglsjdhgfsjhdgf"
    assert_equal 100, product.price_cents
    product.price_range = "1.sdlkjglsjdhgfsjhdgf01"
    assert_equal 101, product.price_cents
    product.price_range = "1sdlkjglsjdhgfsjhdgf0.01"
    assert_equal 1001, product.price_cents
  end

  test "price_range treats a trailing plus sign as customizable" do
    product.price_range = "0.99+"
    assert_equal true, product.customizable_price
    product.price_range = "0.99"
    assert_equal false, product.customizable_price
  end

  test "price_range sets price cents for USD" do
    product.price_currency_type = :usd
    product.price_range = "1"
    assert_equal 100, product.price_cents
    product.price_range = "10.01"
    assert_equal 1001, product.price_cents
  end

  test "price_range sets and saves price cents for GBP" do
    product.price_currency_type = :gbp
    product.price_range = "10.01"
    assert_equal 1001, product.price_cents
    product.save!
    assert_equal 1001, product.price_cents
  end

  test "price_range handles JPY (single-unit currency)" do
    product.price_currency_type = "jpy"
    product.price_range = "100"
    assert_equal 100, product.price_cents
    product.price_range = "¥100.01"
    assert_equal 100, product.price_cents
    product.price_range = "100"
    product.save!
    assert_equal 100, product.price_cents
  end

  test "price_range accepts 0+ and 1+ but not 0.50+" do
    product.price_range = "0+"
    assert_equal true, product.save
    product.price_range = "0.50+"
    assert_equal false, product.save
    product.price_range = "1+"
    assert_equal true, product.save
  end

  test "price_range handles euro-style entries" do
    product.user.update!(verified: true)
    { "999,99" => 99_999, "999.99" => 99_999, "1.999,99" => 199_999, "1,999.99" => 199_999, "1,999" => 199_900 }.each do |input, cents|
      product.price_range = input
      product.save!
      assert_equal cents, product.price_cents, "expected #{input.inspect} to parse to #{cents}"
    end
  end

  # --- #rental_price_range ---------------------------------------------------

  test "rental_price_range trailing plus is customizable only for rent-only products" do
    product.purchase_type = :rent_only
    product.rental_price_cents = 100
    product.save!
    product.rental_price_range = "1.99+"
    assert_equal true, product.customizable_price
    assert_equal 199, product.price_cents

    product.rental_price_range = "0.99"
    assert_equal false, product.customizable_price
    assert_equal 99, product.price_cents

    product.purchase_type = :buy_only
    product.price_cents = 100
    product.save!
    product.rental_price_range = "1.99+"
    assert_equal false, product.customizable_price
    assert_equal 100, product.price_cents

    product.purchase_type = :buy_and_rent
    product.save!
    product.rental_price_range = "1.99+"
    assert_equal false, product.customizable_price
    assert_equal 100, product.price_cents
    assert_equal 199, product.rental_price_cents
  end

  test "saving a product creates a permalink" do
    product.save!
    assert_not_nil product.unique_permalink
  end

  # --- #price_formatted ------------------------------------------------------

  test "price_formatted for a standard USD price" do
    product = create_product
    product.price_range = "1.00"
    assert_equal 100, product.price_cents
    assert_equal "$1", product.price_formatted
    assert_equal "1", product.price_formatted_without_dollar_sign
  end

  test "price_formatted for a non-standard USD price" do
    product = create_product
    product.update!(price_range: "1.01")
    assert_equal 101, product.price_cents
    assert_equal "$1.01", product.price_formatted
    assert_equal "1.01", product.price_formatted_without_dollar_sign
  end

  test "price_formatted for a customizable USD price" do
    product = create_product
    product.update!(price_range: "2.5+")
    assert_equal 250, product.price_cents
    assert_equal "$2.50", product.price_formatted
    assert_equal "2.50", product.price_formatted_without_dollar_sign
  end

  test "price_formatted for a standard JPY price" do
    product = create_product
    product.update!(price_currency_type: :jpy, price_range: "100")
    assert_equal 100, product.price_cents
    assert_equal "¥100", product.price_formatted
    assert_equal "100", product.price_formatted_without_dollar_sign
  end

  test "price_formatted for a non-standard JPY price" do
    product = create_product
    product.update!(price_currency_type: :jpy, price_range: "104")
    assert_equal "¥104", product.price_formatted
  end

  test "price_formatted for a customizable JPY price" do
    product = create_product
    product.update!(price_currency_type: :jpy, price_range: "177+")
    assert_equal 177, product.price_cents
    assert_equal "¥177", product.price_formatted
  end

  # --- compliance_blocked ----------------------------------------------------

  test "compliance_blocked is false for a good IP" do
    assert_equal false, build_product.compliance_blocked("199.21.86.138") # San Francisco WebPass
  end

  test "compliance_blocked is true for an IP in a blocked country" do
    assert_equal true, build_product.compliance_blocked("2.144.0.1") # MCI Iran
  end

  test "compliance_blocked is false for a nil IP" do
    assert_equal false, build_product.compliance_blocked(nil)
  end

  test "compliance_blocked is false for an unidentifiable IP" do
    assert_equal false, build_product.compliance_blocked("10.0.1.1")
  end

  # --- #long_url -------------------------------------------------------------

  test "long_url uses the seller's subdomain" do
    product = create_product
    assert_equal "#{product.user.subdomain_with_protocol}/l/#{product.general_permalink}", product.long_url
  end

  test "long_url appends recommended_by and code query params when present" do
    product = create_product
    base = "#{product.user.subdomain_with_protocol}/l/#{product.general_permalink}"
    assert_equal "#{base}?recommended_by=abc", product.long_url(recommended_by: "abc")
    assert_equal "#{base}?code=BLACKFRIDAY2025", product.long_url(code: "BLACKFRIDAY2025")
  end

  test "long_url omits a blank recommended_by" do
    product = create_product
    base = "#{product.user.subdomain_with_protocol}/l/#{product.general_permalink}"
    ["", " ", nil].each { |value| assert_equal base, product.long_url(recommended_by: value) }
  end

  test "long_url omits the protocol when include_protocol is false" do
    product = create_product
    assert_equal "#{product.user.subdomain}/l/#{product.general_permalink}", product.long_url(include_protocol: false)
  end

  # --- .total_usd_cents_earned_by_user (documented skip) ---------------------

  test "total_usd_cents_earned_by_user sums earnings across owned and affiliated products" do
    skip "needs :sidekiq_inline + a live Elasticsearch index for affiliate-credit rollups; the Minitest harness stubs EsClient"
  end

  # --- #release_custom_permalink_if_possible ---------------------------------

  test "release_custom_permalink_if_possible frees a deleted product's custom permalink" do
    user = create_user
    deleted_product = create_product(user:, deleted_at: Time.current, custom_permalink: "twitter")
    new_product = build_product(user:, custom_permalink: "twitter")
    assert_equal true, new_product.save
    assert_nil deleted_product.reload.custom_permalink
  end

  test "release_custom_permalink_if_possible does not free a live product's custom permalink" do
    user = create_user
    active_product = create_product(user:, custom_permalink: "seo")
    new_product = build_product(user:, custom_permalink: "seo")
    assert_equal false, new_product.save
    assert_equal "seo", active_product.reload.custom_permalink
  end

  test "release_custom_permalink_if_possible does not free another user's deleted product's permalink" do
    other_users_deleted = create_product(user: create_user, deleted_at: Time.current, custom_permalink: "wealth")
    new_product = build_product(user: create_user, custom_permalink: "wealth")
    assert_equal true, new_product.save
    assert_equal "wealth", other_users_deleted.reload.custom_permalink
  end

  # --- #has_stampable_pdfs? / #customize_file_per_purchase? ------------------

  test "has_stampable_pdfs? is false without files or stampable pdfs, true with one" do
    product = create_product
    assert_equal false, product.has_stampable_pdfs?

    product.product_files << create_non_readable_document
    product.product_files << create_readable_document(pdf_stamp_enabled: false)
    # a fresh instance avoids the memoized alive_product_files cache poisoned by the earlier check
    assert_equal false, Link.find(product.id).has_stampable_pdfs?

    product.product_files << create_readable_document(pdf_stamp_enabled: true)
    assert_equal true, Link.find(product.id).has_stampable_pdfs?
  end

  test "customize_file_per_purchase? is false without stampable pdfs, true with one" do
    product = create_product
    assert_equal false, product.customize_file_per_purchase?

    product.product_files << create_non_readable_document
    product.product_files << create_readable_document(pdf_stamp_enabled: false)
    assert_equal false, Link.find(product.id).customize_file_per_purchase?

    product.product_files << create_readable_document(pdf_stamp_enabled: true)
    assert_equal true, Link.find(product.id).customize_file_per_purchase?
  end

  # --- #allow_parallel_purchases? --------------------------------------------

  test "allow_parallel_purchases? is false for a call product" do
    assert_equal false, create_call_product.allow_parallel_purchases?
  end

  test "allow_parallel_purchases? is false when the product has a max purchase count" do
    product = create_product(max_purchase_count: 1)
    assert_equal false, product.allow_parallel_purchases?
    product.update!(max_purchase_count: nil)
    assert_equal true, product.allow_parallel_purchases?
  end

  # --- #is_downloadable? -----------------------------------------------------

  test "is_downloadable? is false without product files" do
    assert_equal false, create_product.is_downloadable?
  end

  test "is_downloadable? is false when files are stampable pdfs" do
    product = create_product
    product.product_files << create_non_readable_document
    product.product_files << create_readable_document(pdf_stamp_enabled: true)
    assert_equal false, product.is_downloadable?
  end

  test "is_downloadable? is false for a rent-only product" do
    product = create_product
    product.update!(purchase_type: "rent_only", rental_price_cents: 1_00)
    product.product_files << create_non_readable_document
    product.product_files << create_readable_document(pdf_stamp_enabled: false)
    assert_equal false, product.is_downloadable?
  end

  test "is_downloadable? is false when all files are stream-only" do
    product = create_product
    product.product_files << create_streamable_video(stream_only: true)
    product.product_files << create_streamable_video(stream_only: true)
    assert_equal false, product.is_downloadable?
  end

  test "is_downloadable? is true with unstampable, non-stream-only files" do
    product = create_product
    product.product_files << create_non_readable_document
    product.product_files << create_streamable_video(stream_only: true)
    product.product_files << create_readable_document(pdf_stamp_enabled: false)
    assert_equal true, product.is_downloadable?
  end

  # --- #create_licenses_for_existing_customers -------------------------------

  test "enabling licensing queues CreateLicensesForExistingCustomersWorker" do
    product = create_product
    create_readable_document(link: product)
    product.is_licensed = true
    product.save!
    assert CreateLicensesForExistingCustomersWorker.jobs.any? { |job| job["args"] == [product.id] }
  end

  test "disabling licensing does not queue CreateLicensesForExistingCustomersWorker" do
    product = create_product(is_licensed: true)
    create_readable_document(link: product)
    CreateLicensesForExistingCustomersWorker.jobs.clear
    product.is_licensed = false
    product.save!
    assert_empty CreateLicensesForExistingCustomersWorker.jobs
  end

  test "updating a non-licensing attribute does not queue CreateLicensesForExistingCustomersWorker" do
    product = create_product
    create_readable_document(link: product)
    CreateLicensesForExistingCustomersWorker.jobs.clear
    product.update!(description: "This is a new description.")
    assert_equal 0, CreateLicensesForExistingCustomersWorker.jobs.size
  end

  # --- subscription_duration / preorders -------------------------------------

  test "subscription_duration persists the integer enum correctly" do
    link = create_product(subscription_duration: :monthly)
    link.update!(subscription_duration: :yearly)
    assert_equal "yearly", link.reload.subscription_duration
    assert_equal 1, link.subscription_duration_before_type_cast
  end

  test "a product can be created for a preorder" do
    assert create_product(is_in_preorder_state: true).valid?
  end

  # --- offer_code creation ---------------------------------------------------

  test "an offer code can lower the price to 0" do
    product = create_product(price_currency_type: "eur", price_cents: 240)
    assert_difference -> { OfferCode.count }, 1 do
      create_offer_code(products: [product], currency_type: "eur", amount_cents: 240)
    end
  end

  test "an offer code can keep the price above the minimum" do
    product = create_product(price_currency_type: "eur", price_cents: 240)
    assert_difference -> { OfferCode.count }, 1 do
      create_offer_code(products: [product], currency_type: "eur", amount_cents: 100)
    end
  end

  test "an offer code cannot bring the price below the minimum" do
    product = create_product(price_currency_type: "eur", price_cents: 240)
    error = assert_raises(ActiveRecord::RecordInvalid) do
      create_offer_code(products: [product], currency_type: "eur", amount_cents: 239)
    end
    assert_equal "The price after discount for all of your products must be either €0 or at least €0.79.", error.record.errors.full_messages.to_sentence
  end

  # --- #delete! --------------------------------------------------------------

  test "delete! marks the custom domain as deleted" do
    product = create_product
    custom_domain = CustomDomain.create!(domain: "www.example1.com", user: nil, product:)
    product.delete!
    assert_equal false, custom_domain.reload.alive?
  end

  test "delete! enqueues subscription cancellations after a 10-minute delay" do
    product = create_product(is_recurring_billing: true, subscription_duration: "monthly")
    subscription = create_subscription
    product.subscriptions << subscription
    create_purchase(link: product, subscription:, is_original_subscription_purchase: true)
    product.delete!
    assert_enqueued_in CancelSubscriptionsForProductWorker, [product.id], delay: 10.minutes
  end

  test "delete! enqueues rich content deletion after a 10-minute delay" do
    product = create_product
    product.delete!
    assert_enqueued_in DeleteProductRichContentWorker, [product.id], delay: 10.minutes
  end

  test "delete! enqueues product file and archive deletion after a 10-minute delay" do
    product = create_product
    product.product_files << create_readable_document
    product.product_files << create_readable_document(is_linked_to_existing_file: true)
    create_purchase(link: product, purchase_state: "successful")
    assert_equal 2, product.reload.product_files.alive.size

    product.delete!
    assert_enqueued_in DeleteProductFilesWorker, [product.id], delay: 10.minutes
    assert_enqueued_in DeleteProductFilesArchivesWorker, [product.id, nil], delay: 10.minutes
    assert_not_nil product.reload.deleted_at
  end

  test "delete! enqueues wishlist product deletion after a 10-minute delay" do
    product = create_product
    product.delete!
    assert_enqueued_in DeleteWishlistProductsJob, [product.id], delay: 10.minutes
  end

  test "delete! removes the product id from every profile section's shown_products" do
    seller = create_user
    product = create_product(user: seller)
    other_product = create_product(user: seller)
    with_product = create_seller_profile_products_section(seller:, shown_products: [product.id, other_product.id])
    without_product = create_seller_profile_products_section(seller:, shown_products: [other_product.id])

    product.delete!

    assert_equal [other_product.id], with_product.reload.shown_products
    assert_equal [other_product.id], without_product.reload.shown_products
  end

  test "delete! schedules the product's public files for deletion" do
    product = create_product
    public_file1 = create_public_file(resource: product, with_audio: true)
    public_file2 = create_public_file(resource: product, with_audio: true)
    other_public_file = create_public_file(with_audio: true) # a different product's file

    product.delete!

    assert public_file1.reload.file.attached?
    assert public_file1.alive?
    assert_in_delta 10.minutes.from_now.to_i, public_file1.scheduled_for_deletion_at.to_i, 5
    assert public_file2.reload.file.attached?
    assert public_file2.alive?
    assert_in_delta 10.minutes.from_now.to_i, public_file2.scheduled_for_deletion_at.to_i, 5
    assert_nil other_public_file.reload.scheduled_for_deletion_at
  end

  test "delete! removes a tiered membership even when its tier categories are inconsistent" do
    product = create_membership_product_with_preset_tiered_pricing
    product.tier_category.mark_deleted!
    product.reload

    assert_nothing_raised { product.delete! }
    assert product.reload.deleted?
  end

  # --- #ordered_by_ids -------------------------------------------------------

  test "ordered_by_ids returns products in the given id order, or by id when nil" do
    creator = create_user
    product1 = create_product(user: creator)
    product2 = create_product(user: creator, created_at: 1.minute.ago)
    product3 = create_product(user: creator, created_at: 2.minutes.ago)
    product4 = create_product(user: creator, created_at: 3.minutes.ago)

    order = [product3.id, product1.id, product2.id, product4.id]
    assert_equal [product3, product1, product2, product4], creator.links.ordered_by_ids(order)
    assert_equal [product1, product2, product3, product4], creator.links.ordered_by_ids(nil)
  end

  # --- #tiers / #default_tier / #tier_category -------------------------------

  test "tiers returns the tier variants for a tiered membership" do
    product = create_membership_product
    assert_equal 1, product.tiers.size
    assert_equal product.variant_categories.alive.first.variants.first, product.tiers.first
  end

  test "tier_category is nil for a non-membership product" do
    assert_nil create_product.tier_category
  end

  test "default_tier returns the first tier for a tiered membership" do
    product = create_membership_product
    second_tier = create_variant(variant_category: product.tier_category)
    assert_equal product.tiers.first, product.default_tier
    assert_not_equal second_tier, product.default_tier
  end

  test "default_tier is nil for a non-membership product" do
    assert_nil create_product.default_tier
  end

  test "tier_category returns the Tier category for a tiered membership" do
    product = create_membership_product
    category = product.tier_category
    assert_instance_of VariantCategory, category
    assert_equal product, category.link
    assert_equal "Tier", category.title
  end

  # --- #has_downloadable_content? --------------------------------------------

  test "has_downloadable_content? is false without files" do
    assert_equal false, create_product.has_downloadable_content?
  end

  test "has_downloadable_content? is false for a preorder product" do
    product = create_product(is_in_preorder_state: true)
    product.product_files << create_streamable_video(stream_only: true)
    assert_equal false, product.has_downloadable_content?
  end

  test "has_downloadable_content? is false when all files are stream-only" do
    product = create_product
    product.product_files << create_streamable_video(stream_only: true)
    assert_equal false, product.has_downloadable_content?
  end

  test "has_downloadable_content? is true with a non-stream-only file" do
    product = create_product
    product.product_files << create_readable_document
    product.product_files << create_streamable_video(stream_only: true)
    assert_equal true, product.has_downloadable_content?
  end

  # --- #save_shipping_destinations! ------------------------------------------

  test "save_shipping_destinations! clears all entries when input is empty for an unpublished product" do
    product = create_product
    product.deleted_at = Time.current
    assert_equal false, product.alive?
    product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
    product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
    product.save!
    assert_equal 2, product.shipping_destinations.alive.size

    product.save_shipping_destinations!([])
    product.reload
    assert_equal 0, product.shipping_destinations.alive.size
  end

  test "save_shipping_destinations! raises when input is empty for a live product" do
    product = create_product
    product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
    product.save!
    assert_raises(Link::LinkInvalid) { product.save_shipping_destinations!([]) }
  end

  test "save_shipping_destinations! saves entries with unique country values" do
    product = create_product
    product.save_shipping_destinations!([
                                          { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 },
                                          { "country_code" => Compliance::Countries::DEU.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 },
                                        ])
    product.reload
    assert_equal 2, product.shipping_destinations.alive.size
    assert_equal ["US", 2000, 1000], [product.shipping_destinations.first.country_code, product.shipping_destinations.first.one_item_rate_cents, product.shipping_destinations.first.multiple_items_rate_cents]
    assert_equal ["DE", 1000, 0], [product.shipping_destinations.second.country_code, product.shipping_destinations.second.one_item_rate_cents, product.shipping_destinations.second.multiple_items_rate_cents]
  end

  test "save_shipping_destinations! accepts rates already in cents" do
    product = create_product
    product.save_shipping_destinations!([
                                          { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate_cents" => 2000, "multiple_items_rate_cents" => 1000 },
                                        ])
    product.reload
    assert_equal ["US", 2000, 1000], [product.shipping_destinations.first.country_code, product.shipping_destinations.first.one_item_rate_cents, product.shipping_destinations.first.multiple_items_rate_cents]
  end

  test "save_shipping_destinations! rejects duplicated countries" do
    product = create_product
    assert_raises(Link::LinkInvalid) do
      product.save_shipping_destinations!([
                                            { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 },
                                            { "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 },
                                          ])
    end
  end

  test "save_shipping_destinations! removes entries absent from the input" do
    product = create_product
    product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
    product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
    product.save!

    product.save_shipping_destinations!([{ "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 20, "multiple_items_rate" => 10 }])
    assert_equal 1, product.shipping_destinations.alive.size
  end

  test "save_shipping_destinations! resurrects a deactivated entry when reconfigured" do
    product = create_product
    product.shipping_destinations << ShippingDestination.new(country_code: Product::Shipping::ELSEWHERE, one_item_rate_cents: 20, multiple_items_rate_cents: 10)
    product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::DEU.alpha2, one_item_rate_cents: 10, multiple_items_rate_cents: 5)
    product.save!

    product.save_shipping_destinations!([{ "country_code" => Compliance::Countries::USA.alpha2, "one_item_rate" => 10, "multiple_items_rate" => 0 }])
    product.reload
    assert_equal 1, product.shipping_destinations.alive.size

    product.save_shipping_destinations!([{ "country_code" => Product::Shipping::ELSEWHERE, "one_item_rate" => 20, "multiple_items_rate" => 10 }])
    assert_equal 1, product.shipping_destinations.alive.size
    assert_equal ["ELSEWHERE", 2000, 1000], [product.shipping_destinations.alive.first.country_code, product.shipping_destinations.alive.first.one_item_rate_cents, product.shipping_destinations.alive.first.multiple_items_rate_cents]
  end

  test "save_shipping_destinations! marks virtual countries" do
    product = create_product
    product.save_shipping_destinations!([{ "country_code" => ShippingDestination::Destinations::EUROPE, "one_item_rate" => 20, "multiple_items_rate" => 10 }])
    product.reload
    destination = product.shipping_destinations.first
    assert_equal ["EUROPE", 2000, 1000], [destination.country_code, destination.one_item_rate_cents, destination.multiple_items_rate_cents]
    assert_equal true, destination.is_virtual_country
  end

  # --- prices migration ------------------------------------------------------

  test "a buy product has the proper buy price" do
    price = create_product(price_cents: 200).prices.last
    assert_equal [200, "usd", false, nil], [price.price_cents, price.currency, price.is_rental, price.recurrence]
  end

  test "the buy price updates when the price changes" do
    product = create_product(price_cents: 200)
    product.update!(price_cents: 300)
    assert_equal 1, product.prices.alive.count
    price = product.prices.alive.last
    assert_equal [300, "usd", false, nil], [price.price_cents, price.currency, price.is_rental, price.recurrence]
  end

  test "adding a rental price keeps both buy and rental prices for buy_and_rent" do
    product = create_product(price_cents: 200)
    assert_difference -> { product.prices.alive.count }, 1 do
      product.rental_price_cents = 100
      product.purchase_type = :buy_and_rent
      product.save!
    end
    assert_equal [200, false, nil], [product.prices.is_buy.last.price_cents, product.prices.is_buy.last.is_rental, product.prices.is_buy.last.recurrence]
    assert_equal [100, true, nil], [product.prices.is_rental.last.price_cents, product.prices.is_rental.last.is_rental, product.prices.is_rental.last.recurrence]
  end

  test "switching to rent-only keeps only the rental price" do
    product = create_product(price_cents: 200)
    product.rental_price_cents = 100
    product.purchase_type = :buy_and_rent
    product.save!
    assert_difference -> { product.prices.alive.count }, -1 do
      product.purchase_type = :rent_only
      product.save!
    end
    rental_price = product.prices.alive.is_rental.last
    assert_equal [100, "usd", true, nil], [rental_price.price_cents, rental_price.currency, rental_price.is_rental, rental_price.recurrence]
  end

  test "a subscription product has a recurrence-tagged price" do
    product = create_product(is_recurring_billing: true, subscription_duration: "monthly", price_cents: 200)
    price = product.prices.alive.last
    assert_equal [200, "usd", false, BasePrice::Recurrence::MONTHLY], [price.price_cents, price.currency, price.is_rental, price.recurrence]
  end

  test "a subscription product's price updates when the price changes" do
    product = create_product(is_recurring_billing: true, subscription_duration: "monthly", price_cents: 200)
    product.update!(price_cents: 500)
    price = product.prices.alive.last
    assert_equal [500, BasePrice::Recurrence::MONTHLY], [price.price_cents, price.recurrence]
  end

  test "the price carries the product's currency" do
    price = create_product(price_cents: 200, price_currency_type: "jpy").prices.alive.last
    assert_equal [200, "jpy", false, nil], [price.price_cents, price.currency, price.is_rental, price.recurrence]
  end

  # --- require_shipping_for_physical -----------------------------------------

  test "a physical product with require_shipping false is invalid" do
    assert_equal false, build_product(is_physical: true, require_shipping: false).valid?
  end

  test "clearing require_shipping on a physical product raises" do
    product = create_physical_product
    product.require_shipping = false
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_equal "Shipping form is required for physical products.", product.errors.full_messages.to_sentence
  end

  # --- twitter_share_url -----------------------------------------------------

  test "twitter_share_url uri-escapes the product name" do
    product = create_product(name: "you & i")
    assert_equal "https://twitter.com/intent/tweet?text=I+got+you+%26+i+on+%40Gumroad:%20#{product.long_url}", product.twitter_share_url
  end

  # --- duration_multiple_of_price_options ------------------------------------

  test "duration_in_months may be null" do
    product = create_subscription_product(subscription_duration: "yearly", duration_in_months: 12)
    product.duration_in_months = nil
    assert_nothing_raised { product.save! }
  end

  test "duration_in_months may be a multiple of 12 for yearly" do
    product = create_subscription_product(subscription_duration: "yearly", duration_in_months: 12)
    product.duration_in_months = 24
    assert_nothing_raised { product.save! }
  end

  test "duration_in_months of 0 is invalid" do
    product = create_subscription_product(subscription_duration: "yearly", duration_in_months: 12)
    product.duration_in_months = 0
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_equal "Your subscription length in months must be a number greater than zero.", product.errors.full_messages.to_sentence
  end

  test "duration_in_months not a multiple of 12 is invalid for yearly" do
    product = create_subscription_product(subscription_duration: "yearly", duration_in_months: 12)
    product.duration_in_months = 5
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_equal "Your subscription length in months must be a multiple of 12 because you have selected a payment option of yearly payments.", product.errors.full_messages.to_sentence
  end

  # --- #rated_as_adult? / #has_adult_keywords? -------------------------------

  test "rated_as_adult? is true when the product is flagged adult" do
    assert_equal true, create_product(is_adult: true).rated_as_adult?
  end

  test "rated_as_adult? is true when the seller marks all products adult" do
    assert_equal true, create_product(user: create_user(all_adult_products: true)).rated_as_adult?
  end

  test "rated_as_adult? is true when the product has adult keywords" do
    product = create_product
    product.stubs(:has_adult_keywords?).returns(true)
    assert_equal true, product.rated_as_adult?
  end

  test "has_adult_keywords? checks product and seller fields" do
    assert build_product(name: "abs punch product").has_adult_keywords?
    assert build_product(description: "NSFW product").has_adult_keywords?
    assert build_product(user: create_user(bio: "NSFW stuff")).has_adult_keywords?
    assert build_product(user: create_user(name: "NsfwUser")).has_adult_keywords?
    assert build_product(user: create_user(username: "futa123")).has_adult_keywords?
  end

  test "has_adult_keywords? classifies descriptions, avoiding false positives" do
    {
      "squirtle is a Pokémon" => false,
      "small fuéta" => false,
      "ns fw" => false,
      "Yuri Gagarin was a great astronaut" => false,
      "Tentacle Monster Hat" => false,
      "nude2screen" => true,
      "Click here for #HotHentaiComics!" => true,
    }.each do |description, adult|
      assert_equal adult, build_product(description:).has_adult_keywords?, "#{description.inspect} should be #{adult ? '' : 'non-'}adult"
    end
  end

  # --- #has_content? ---------------------------------------------------------

  test "has_content? is false without rich content or with empty rich content" do
    product = create_product
    assert_equal false, product.has_content?
    create_rich_content(entity: product, description: [])
    assert_equal false, product.reload.has_content?
  end

  test "has_content? is true with non-empty rich content" do
    product = create_product
    create_rich_content(entity: product, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "hello" }] }])
    assert_equal true, product.reload.has_content?
  end

  # --- #statement_description ------------------------------------------------

  test "statement_description prefers the creator's name, falling back to username" do
    creator = create_user(name: "name", username: "username")
    product = create_product(user: creator)
    assert_equal "name", product.statement_description
    creator.update!(name: nil)
    assert_equal "username", product.statement_description
  end

  # --- #free_trial_duration --------------------------------------------------

  test "free_trial_duration is nil when free trial is disabled" do
    assert_nil build_product.free_trial_duration
  end

  test "free_trial_duration reflects the configured amount and unit" do
    product = build_product(free_trial_enabled: true, free_trial_duration_amount: 1, free_trial_duration_unit: :week)
    assert_equal 1.week, product.free_trial_duration
    product.free_trial_duration_amount = 3
    assert_equal 3.weeks, product.free_trial_duration
    product.free_trial_duration_unit = :month
    assert_equal 3.months, product.free_trial_duration
  end

  # --- #has_customizable_price_option? ---------------------------------------

  test "has_customizable_price_option? reflects customizable_price for a non-tiered product" do
    assert_equal true, build_product(customizable_price: true).has_customizable_price_option?
    assert_equal false, build_product(customizable_price: false).has_customizable_price_option?
  end

  test "has_customizable_price_option? is false for a tiered membership without customizable tiers" do
    assert_equal false, create_membership_product.has_customizable_price_option?
  end

  test "has_customizable_price_option? is true when a tier is customizable" do
    product = create_membership_product
    product.default_tier.update!(customizable_price: true)
    assert_equal true, product.has_customizable_price_option?
  end

  test "has_customizable_price_option? ignores deleted customizable tiers" do
    product = create_membership_product
    create_variant(variant_category: product.tier_category, customizable_price: true, deleted_at: Time.current)
    assert_equal false, product.has_customizable_price_option?
  end

  # --- #recurrence_price_enabled? --------------------------------------------

  test "recurrence_price_enabled? is true with a live price for the recurrence" do
    product = create_product
    create_price(link: product, recurrence: "monthly")
    assert_equal true, product.recurrence_price_enabled?("monthly")
  end

  test "recurrence_price_enabled? is false without a live price for the recurrence" do
    product = create_product
    assert_equal false, product.recurrence_price_enabled?("monthly")
    create_price(link: product, recurrence: "monthly", deleted_at: 1.day.ago)
    assert_equal false, product.recurrence_price_enabled?("monthly")
  end

  # --- #has_multiple_variants? -----------------------------------------------

  test "has_multiple_variants? for physical products depends on live custom SKUs" do
    product = create_physical_product
    assert_equal false, product.has_multiple_variants? # default SKU only

    create_sku(link: product, deleted_at: Time.current)
    assert_equal false, product.has_multiple_variants?

    sku = create_sku(link: product)
    assert_equal false, product.has_multiple_variants? # a single custom SKU is not "multiple"

    create_sku(link: product)
    assert_equal true, product.has_multiple_variants?
    assert sku # (silence unused warning; the first custom SKU is part of the setup)
  end

  test "has_multiple_variants? for non-physical products depends on live variants" do
    product = create_product
    category = create_variant_category(link: product)

    create_variant(variant_category: category, deleted_at: Time.current)
    assert_equal false, product.has_multiple_variants?

    create_variant(variant_category: category)
    assert_equal false, product.has_multiple_variants?

    create_variant(variant_category: category)
    assert_equal true, product.has_multiple_variants?
  end

  test "has_multiple_variants? is true across multiple variant categories" do
    product = create_product
    category = create_variant_category(link: product)
    other_category = create_variant_category(link: product)
    create_variant(variant_category: category)
    create_variant(variant_category: other_category)
    assert_equal true, product.has_multiple_variants?
  end

  # --- associations: integrations / cached values / affiliates / variants ----

  test "product_integrations returns alive and deleted integrations" do
    integration_1 = create_circle_integration
    integration_2 = create_circle_integration
    product = create_product
    product.active_integrations << integration_1 << integration_2
    assert_no_difference -> { product.product_integrations.count } do
      product.product_integrations.find_by(integration: integration_1).mark_deleted!
    end
    assert_equal [integration_1, integration_2].map(&:id).sort, product.product_integrations.pluck(:integration_id).sort
  end

  test "live_product_integrations excludes deleted integrations" do
    integration_1 = create_circle_integration
    integration_2 = create_circle_integration
    product = create_product
    product.active_integrations << integration_1 << integration_2
    assert_difference -> { product.live_product_integrations.count }, -1 do
      product.product_integrations.find_by(integration: integration_1).mark_deleted!
    end
    assert_equal [integration_2.id], product.live_product_integrations.pluck(:integration_id)
  end

  test "active_integrations excludes deleted integrations" do
    integration_1 = create_circle_integration
    integration_2 = create_circle_integration
    product = create_product
    product.active_integrations << integration_1 << integration_2
    assert_difference -> { product.active_integrations.count }, -1 do
      product.product_integrations.find_by(integration: integration_1).mark_deleted!
    end
    assert_equal [integration_2.id], product.active_integrations.pluck(:integration_id)
  end

  test "product_cached_values returns all cached values, expired or not" do
    skip "ProductCachedValue#assign_cached_values computes monthly_recurring_revenue from Elasticsearch on create, which the stubbed-ES Minitest harness can't satisfy"
  end

  test "affiliate associations split direct and global affiliates" do
    product = create_product
    direct_affiliate = create_direct_affiliate
    global_affiliate = create_user.global_affiliate
    product_affiliates = [
      create_product_affiliate(product:, affiliate: direct_affiliate),
      create_product_affiliate(product:, affiliate: global_affiliate),
    ]
    assert_equal product_affiliates.sort_by(&:id), product.product_affiliates.sort_by(&:id)
    assert_equal [direct_affiliate, global_affiliate].sort_by(&:id), product.affiliates.sort_by(&:id)
    assert_equal [direct_affiliate], product.direct_affiliates
    assert_equal [global_affiliate], product.global_affiliates
  end

  test "variant associations split alive and deleted variants" do
    product = create_product
    category = create_variant_category(link: product)
    alive_variant = create_variant(variant_category: category)
    deleted_variant = create_variant(variant_category: category, deleted_at: 1.hour.ago)
    assert_equal [alive_variant, deleted_variant].sort_by(&:id), product.variants.sort_by(&:id)
    assert_equal [alive_variant], product.alive_variants
  end

  # --- #has_active_paid_variants? --------------------------------------------

  test "has_active_paid_variants? is false with only free variants, true with a paid one" do
    product = create_product
    category = create_variant_category(link: product)
    create_variant(variant_category: category, price_difference_cents: 0)
    assert_equal false, product.has_active_paid_variants?

    create_variant(variant_category: category, price_difference_cents: 100)
    assert_equal true, product.has_active_paid_variants?
  end

  # --- #sku_title ------------------------------------------------------------

  test "sku_title is 'Version' without categories, else the category titles joined" do
    assert_equal "Version", create_product.sku_title

    product = create_product
    create_variant_category(title: "Color", link: product)
    create_variant_category(title: "Size", link: product)
    assert_equal "Color - Size", product.sku_title
  end

  # --- #enable_transcode_videos_on_purchase! ---------------------------------

  test "enable_transcode_videos_on_purchase! sets the flag" do
    product = create_product
    assert_equal false, product.transcode_videos_on_purchase
    product.enable_transcode_videos_on_purchase!
    assert_equal true, product.transcode_videos_on_purchase
  end

  # --- #html_safe_description ------------------------------------------------

  test "html_safe_description turns bare URLs into anchor tags" do
    product = create_product(description: "Check it out at https://gumroad.com")
    result = product.html_safe_description
    assert_equal "Check it out at <a href=\"https://gumroad.com\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">https://gumroad.com</a>", result
    assert result.html_safe?
  end

  test "html_safe_description is nil for an empty description" do
    assert_nil create_product(description: "").html_safe_description
  end

  test "html_safe_description adds a protocol to protocol-relative URLs" do
    product = create_product(description: "<iframe src='//cdn.iframe.ly'></iframe><img src='//example.com/image.jpg'>")
    assert_equal "<iframe src=\"http://cdn.iframe.ly\"></iframe><img src=\"http://example.com/image.jpg\">", product.html_safe_description
  end

  test "html_safe_description keeps an iframely.net iframe" do
    product = create_product(description: "<iframe src=\"https://iframely.net/api/iframe?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DzumvXpa7kGY&key=31708e31\" allowfullscreen></iframe>")
    assert_includes product.html_safe_description, "iframely.net/api/iframe"
  end

  test "html_safe_description removes an iframe from an untrusted host" do
    product = create_product(description: "before<iframe src=\"https://evil.example.com/embed\"></iframe>after")
    assert_equal "beforeafter", product.html_safe_description
  end

  test "html_safe_description removes a script from an untrusted source" do
    product = create_product(description: "some text<script src='https://untrusted.example.com/script.js'></script>evil script")
    assert_equal "some textevil script", product.html_safe_description
  end

  test "html_safe_description removes a non-embed.js iframe.ly script but keeps embed.js" do
    removed = create_product(description: "some text<script src='https://cdn.iframe.ly/script.js'></script>evil script")
    assert_equal "some textevil script", removed.html_safe_description

    kept = create_product(description: "some text<script src='https://cdn.iframe.ly/embed.js'></script>evil script")
    assert_equal "some text<script src=\"https://cdn.iframe.ly/embed.js\"></script>evil script", kept.html_safe_description
  end

  test "html_safe_description strips unsafe and unknown tags and attributes" do
    description = "<h1><span>Heading in span</span></h1><b>Bold</b><p><style>color: red</style><strong class=\"something\">Strong</strong></p><p onclick=\"alert('hi')\"><em>Italic</em></p><p><u>Underline</u></p><p><s>Strkethrough</s></p><h1>Heading 1</h1><h2>Heading 2</h2><h3>Heading 3</h3><h4>Heading 4</h4><h5>Heading 5</h5><h6>Heading 6</h6><pre><code>Code</code></pre><ul><li>Bullet list</li></ul><ol><li>Numbered list</li></ol><p>Horizontal line</p><hr><blockquote><p>Quote</p></blockquote><p><a target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"https://example.com/\">Link</a></p><figure><img src=\"https://example.com/test.jpg\"><p class=\"figcaption\">Image</p></figure><div class=\"tiptap__raw\"><div><div style=\"left: 0; width: 100%; height: 0; position: relative; padding-bottom: 56.25%;\"><iframe src=\"//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2Fu80Ey6lSRyE&amp;key=1234\" style=\"top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;\" allowfullscreen=\"\" scrolling=\"no\" allow=\"accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;\"></iframe></div></div></div><div class=\"tiptap__raw\"><div class=\"iframely-embed\" style=\"max-width: 550px;\"><div class=\"iframely-responsive\" style=\"padding-bottom: 56.25%;\"><a href=\"https://twitter.com/shl/status/1678978982019223553\" data-iframely-url=\"//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Ftwitter.com%2Fshl%2Fstatus%2F1678978982019223553&amp;key=1234\"></a></div></div><script async=\"\" src=\"//cdn.iframe.ly/embed.js\" charset=\"utf-8\"></script></div><p><br></p><a class=\"tiptap__button button primary\" target=\"_blank\" rel=\"noopener noreferrer nofollow\" href=\"https://example.com/\">Button</a><a href=\"javascript:void(0)\">Click me</a><br><script>var a = 2;</script><iframe src=\"https://example.com\">Lorem ipsum</iframe><public-file-embed id=\"1234567890abcdef\"></public-file-embed>"
    expected = %(<h1><span>Heading in span</span></h1><b>Bold</b><p><strong class="something">Strong</strong></p><p><em>Italic</em></p><p><u>Underline</u></p><p><s>Strkethrough</s></p><h1>Heading 1</h1><h2>Heading 2</h2><h3>Heading 3</h3><h4>Heading 4</h4><h5>Heading 5</h5><h6>Heading 6</h6><pre><code>Code</code></pre><ul><li>Bullet list</li></ul><ol><li>Numbered list</li></ol><p>Horizontal line</p><hr><blockquote><p>Quote</p></blockquote><p><a target="_blank" rel="noopener noreferrer nofollow" href="https://example.com/">Link</a></p><figure><img src="https://example.com/test.jpg"><p class="figcaption">Image</p></figure><div class="tiptap__raw"><div><div style="width:100%;height:0;position:relative;padding-bottom:56.25%;"><iframe src="http://cdn.iframe.ly/api/iframe?url=https%3A%2F%2Fyoutu.be%2Fu80Ey6lSRyE&amp;key=1234" style="top: 0; left: 0; width: 100%; height: 100%; position: absolute; border: 0;" allowfullscreen="" scrolling="no" allow="accelerometer *; clipboard-write *; encrypted-media *; gyroscope *; picture-in-picture *; web-share *;"></iframe></div></div></div><div class="tiptap__raw">\n<div class="iframely-embed" style="max-width:550px;"><div class="iframely-responsive" style="padding-bottom:56.25%;"><a href="https://twitter.com/shl/status/1678978982019223553" data-iframely-url="//cdn.iframe.ly/api/iframe?url=https%3A%2F%2Ftwitter.com%2Fshl%2Fstatus%2F1678978982019223553&amp;key=1234"></a></div></div>\n<script src="http://cdn.iframe.ly/embed.js" charset="utf-8"></script>\n</div><p><br></p><a class="tiptap__button button primary" target="_blank" rel="noopener noreferrer nofollow" href="https://example.com/">Button</a><a>Click me</a><br><public-file-embed id="1234567890abcdef"></public-file-embed>)
    product = create_product(description:)

    assert_equal expected, product.html_safe_description
    assert product.html_safe_description.html_safe?
  end

  # --- description formatting ------------------------------------------------

  test "description strips leading xml processing-instruction comments on save" do
    product = create_product

    desc = "<!--?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?-->\r\n\r\nBy purchasing, you are granted a " \
           "full, exclusive license to this track. This is one-of-a-kind and royalty-free. Visit our website for full licensing info.<br>"
    product.update!(description: desc)
    expected = "\r\n\r\nBy purchasing, you are granted a full, exclusive license to this track. This is " \
               "one-of-a-kind and royalty-free. Visit our website for full licensing info.<br>"
    assert_equal expected, product.description

    desc = "We all have files, pictures or notes on our computer that we'd like to protect. This step-by-step guide " \
           "will show you how to securely encrypt any file or files on your Mac for FREE. <div><br></div><div>You'll learn how to use all of your Mac's " \
           "built in tools to secure ANY file with military-grade protection. </div><div><br></div><div><!--?xml version=\"1.0\" encoding=\"UTF-8\" " \
           "standalone=\"no\"?-->\r\n\r\nNo technical expertise is required. File is delivered as a secure PDF.<br></div>"
    product.update!(description: desc)
    expected = "We all have files, pictures or notes on our computer that we'd like to protect. This step-by-step guide " \
               "will show you how to securely encrypt any file or files on your Mac for FREE. <div><br></div>" \
               "<div>You'll learn how to use all of your Mac's built in tools to secure ANY file with military-grade protection. " \
               "</div><div><br></div><div>\r\n\r\nNo technical expertise is required. File is delivered " \
               "as a secure PDF.<br></div>"
    assert_equal expected, product.description

    desc = "(<!--[if gte mso 9]><xml>\n <w:WordDocument>\n  <w:View>Normal</w:View>\n  <w:Zoom>0</w:Zoom>\n " \
           "<w:DoNotOptimizeForBrowser></w:DoNotOptimizeForBrowser>\n </w:WordDocument>\n</xml><![endif]--><span style=\"font-size:14.0pt;" \
           "mso-bidi-font-size:12.0pt;\nfont-family:\" times=\"\" new=\"\" roman\";mso-fareast-font-family:\"times=\"\" roman\";=\"\" " \
           "mso-ansi-language:en-us;mso-fareast-language:en-us;mso-bidi-language:ar-sa\"=\"\">93.8\nmi - 2 hr 49 min)&nbsp;</span> test <br><br>"
    product.update!(description: desc)
    expected = "(<span style=\"font-size:14.0pt;mso-bidi-font-size:12.0pt;\nfont-family:\" times=\"\" new=\"\" " \
               "roman\";mso-fareast-font-family:\"times=\"\" roman\";=\"\" mso-ansi-language:en-us;mso-fareast-language:en-us;mso-bidi-language:ar-sa\"=\"\">" \
               "93.8\nmi - 2 hr 49 min)&nbsp;</span> test <br><br>"
    assert_equal expected, product.description
  end

  test "description rewrites S3 URLs to their CDN proxy URLs" do
    # In the test env CDN_URL_MAP maps the gumroad S3 origin to the test CDN host.
    product = create_product
    original = %(<img src="#{AWS_S3_ENDPOINT}/gumroad/files/sample/sample/original/sample.jpg" alt="">)
    product.update!(description: original)
    assert_includes product.description, "#{CDN_S3_PROXY_HOST}/res/gumroad/files/sample/sample/original/sample.jpg"
    assert_not_includes product.description, "#{AWS_S3_ENDPOINT}/gumroad/files"
  end

  # --- #options --------------------------------------------------------------

  test "options returns SKUs when the product has SKUs enabled" do
    product = create_physical_product
    sku1 = product.skus.create(price_difference_cents: 1, name: "SKU 1")
    sku2 = product.skus.create(price_difference_cents: 2, name: "SKU 2")
    assert_equal [sku1.to_option, sku2.to_option].sort_by { |o| o[:id] }, product.options.sort_by { |o| o[:id] }
  end

  test "options returns variants when the product has no SKUs" do
    product = create_product_with_digital_versions
    assert_equal [product.alive_variants.first.to_option, product.alive_variants.second.to_option].sort_by { |o| o[:id] }, product.options.sort_by { |o| o[:id] }
  end

  test "options sorts a variant with a nil created_at first without raising" do
    product = create_product
    category = create_variant_category(link: product)
    with_timestamp = create_variant(variant_category: category, name: "Has timestamp")
    without_timestamp = create_variant(variant_category: category, name: "No timestamp")
    [with_timestamp, without_timestamp].each { |variant| variant.update_column(:position_in_category, nil) }
    without_timestamp.update_column(:created_at, nil)

    product.reload
    product.alive_variants.load
    options = nil
    assert_nothing_raised { options = product.options }
    assert_equal ["No timestamp", "Has timestamp"], options.map { |option| option[:name] }
  end

  # --- #auto_transcode_videos? -----------------------------------------------

  test "auto_transcode_videos? is true when the user allows it" do
    product = create_product
    product.user.stubs(:auto_transcode_videos?).returns(true)
    assert_equal true, product.auto_transcode_videos?
  end

  test "auto_transcode_videos? is true when the product has successful sales" do
    product = create_product
    product.stubs(:has_successful_sales?).returns(true)
    assert_equal true, product.auto_transcode_videos?
  end

  # --- #permalink_overlaps_with_other_sellers? -------------------------------

  test "permalink_overlaps_with_other_sellers? detects custom and unique permalink overlaps" do
    create_product(unique_permalink: "abc", custom_permalink: "xyz")
    assert_equal true, create_product(custom_permalink: "abc").permalink_overlaps_with_other_sellers?
    assert_equal true, create_product(unique_permalink: "xyz").permalink_overlaps_with_other_sellers?
    assert_equal false, create_product(unique_permalink: "def", custom_permalink: "ghi").permalink_overlaps_with_other_sellers?
  end

  # --- #purchasing_power_parity_enabled? -------------------------------------

  test "purchasing_power_parity_enabled? follows the user flag and the product override" do
    product = create_product
    assert_equal false, product.purchasing_power_parity_enabled?
    product.update!(purchasing_power_parity_disabled: true)
    assert_equal false, product.purchasing_power_parity_enabled?

    product.update!(purchasing_power_parity_disabled: false)
    product.user.update!(purchasing_power_parity_enabled: true)
    assert_equal true, product.purchasing_power_parity_enabled?
    product.update!(purchasing_power_parity_disabled: true)
    assert_equal false, product.purchasing_power_parity_enabled?
  end

  # --- #has_offer_codes? -----------------------------------------------------

  test "has_offer_codes? is true only with codes and the display flag enabled" do
    product = create_product
    create_offer_code(user: product.user, products: [product])
    assert_equal false, product.has_offer_codes? # flag off
    product.user.update!(display_offer_code_field: true)
    assert_equal true, product.reload.has_offer_codes?
  end

  test "has_offer_codes? is false without codes regardless of the display flag" do
    product = create_product
    assert_equal false, product.has_offer_codes?
    product.user.update!(display_offer_code_field: true)
    assert_equal false, product.reload.has_offer_codes?
  end

  test "has_offer_codes? is false when the only universal code excludes the product" do
    product = create_product
    create_universal_offer_code(user: product.user, excluded_products: [product])
    product.user.update!(display_offer_code_field: true)
    assert_equal false, product.has_offer_codes?
  end

  # --- default offer code validation -----------------------------------------

  test "a universal offer code that excludes the product cannot be the default" do
    product = create_product
    offer_code = create_universal_offer_code(user: product.user, excluded_products: [product])
    product.default_offer_code = offer_code
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Default offer code must apply to this product"
  end

  # --- #validate_product_price_against_all_offer_codes? ----------------------

  test "validate_product_price_against_all_offer_codes? uses tiered discounts across membership tier prices" do
    product = create_membership_product_with_preset_tiered_pricing
    # A tiered (ownership-duration) offer code: 50% off after 12 months.
    create_offer_code(
      products: [product], user: product.user, amount_cents: nil, amount_percentage: 0,
      ownership_duration_tiers: [
        { "months" => 0, "amount_percentage" => 0 },
        { "months" => 12, "amount_percentage" => 50 },
      ]
    )
    # Drop the first tier's buy price to $1.50; 50% off lands below the $0.99 floor.
    product.tiers.first.prices.alive.is_buy.first.update!(price_cents: 1_50)

    assert_equal false, product.validate_product_price_against_all_offer_codes?
    assert_includes product.errors.full_messages,
                    "An existing discount code puts the price of this product below the $0.99 minimum after discount."
  end

  # --- #find_offer_code ------------------------------------------------------

  test "find_offer_code returns the universal code unless it excludes the product" do
    product = create_product
    other_product = create_product(user: product.user)
    universal = create_universal_offer_code(user: product.user, code: "uni")
    assert_equal universal, product.find_offer_code(code: "uni")
    assert_equal universal, other_product.find_offer_code(code: "uni")

    universal.update!(excluded_products: [product])
    assert_nil product.find_offer_code(code: "uni")
    assert_equal universal, other_product.find_offer_code(code: "uni")
  end

  # --- #product_and_universal_offer_codes ------------------------------------

  test "product_and_universal_offer_codes omits universal codes that exclude the product" do
    product = create_product
    other_product = create_product(user: product.user)
    product_offer_code = create_offer_code(user: product.user, products: [product], code: "prod")
    universal = create_universal_offer_code(user: product.user, code: "uni", excluded_products: [other_product])
    assert_equal [product_offer_code, universal].sort_by(&:id), product.product_and_universal_offer_codes.sort_by(&:id)
    assert_equal [], other_product.product_and_universal_offer_codes
  end

  # --- #available_cross_sells ------------------------------------------------

  test "available_cross_sells returns cross-sells for the product or universal ones" do
    seller = create_user
    product = create_product(user: seller)
    for_product = create_upsell(seller:, selected_products: [product], cross_sell: true)
    universal = create_upsell(seller:, universal: true, cross_sell: true)
    create_upsell(seller:, cross_sell: true) # for another product
    assert_equal [for_product, universal].sort_by(&:id), product.available_cross_sells.sort_by(&:id)
  end

  test "available_cross_sells excludes paused or deleted cross-sells" do
    seller = create_user
    product = create_product(user: seller)
    for_product = create_upsell(seller:, selected_products: [product], cross_sell: true)
    universal = create_upsell(seller:, universal: true, cross_sell: true)
    for_product.update!(paused: true)
    universal.mark_deleted!
    assert_empty product.available_cross_sells.reload
  end

  # --- #find_or_initialize_product_refund_policy -----------------------------

  test "find_or_initialize_product_refund_policy returns the existing policy" do
    policy = create_product_refund_policy
    assert_equal policy, policy.product.find_or_initialize_product_refund_policy
  end

  test "find_or_initialize_product_refund_policy builds a new policy when none exists" do
    product = create_product
    policy = product.find_or_initialize_product_refund_policy
    assert_instance_of ProductRefundPolicy, policy
    assert_equal false, policy.persisted?
    assert_equal product, policy.product
    assert_equal product.user, policy.seller
  end

  # --- #purchase_info_for_product_page ---------------------------------------

  test "purchase_info_for_product_page returns a matching user's previous purchase" do
    product = create_product(is_in_preorder_state: false)
    user = create_user
    purchase = create_purchase(link: product, purchaser: user)
    assert_equal purchase.external_id, product.purchase_info_for_product_page(user, nil)[:id]
    assert_equal purchase.purchase_info, product.purchase_info_for_product_page(user, nil)
    assert_equal true, product.purchase_info_for_product_page(user, nil)[:was_paid]
  end

  test "purchase_info_for_product_page marks a free purchase as not paid" do
    product = create_product(is_in_preorder_state: false)
    user = create_user
    create_free_purchase(link: product, purchaser: user)
    assert_equal false, product.purchase_info_for_product_page(user, nil)[:was_paid]
  end

  test "purchase_info_for_product_page marks a paid product discounted to $0 as paid" do
    product = create_product(is_in_preorder_state: false)
    user = create_user
    offer_code = create_offer_code(products: [product], amount_cents: nil, amount_percentage: 100)
    create_free_purchase(link: product, purchaser: user, offer_code:)
    assert_equal true, product.purchase_info_for_product_page(user, nil)[:was_paid]
  end

  test "purchase_info_for_product_page returns nil for a gift sender purchase" do
    product = create_product(is_in_preorder_state: false)
    user = create_user
    create_purchase(link: product, purchaser: user, is_gift_sender_purchase: true)
    assert_nil product.purchase_info_for_product_page(user, nil)
  end

  test "purchase_info_for_product_page returns a gift receiver purchase" do
    product = create_product(is_in_preorder_state: false)
    user = create_user
    purchase = create_purchase(link: product, purchaser: user, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_equal purchase.external_id, product.purchase_info_for_product_page(user, nil)[:id]
  end

  test "purchase_info_for_product_page returns a preorder authorization purchase" do
    product = create_product(is_in_preorder_state: true)
    user = create_user
    purchase = create_preorder_authorization_purchase(link: product, purchaser: user)
    assert_equal purchase.external_id, product.purchase_info_for_product_page(user, nil)[:id]
  end

  test "purchase_info_for_product_page returns nil for a preorder gift sender purchase" do
    product = create_product(is_in_preorder_state: true)
    user = create_user
    create_preorder_authorization_purchase(link: product, purchaser: user, is_gift_sender_purchase: true)
    assert_nil product.purchase_info_for_product_page(user, nil)
  end

  test "purchase_info_for_product_page returns a preorder gift receiver purchase" do
    product = create_product(is_in_preorder_state: true)
    user = create_user
    purchase = create_preorder_authorization_purchase(link: product, purchaser: user, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_equal purchase.external_id, product.purchase_info_for_product_page(user, nil)[:id]
  end

  # --- #purchase_info_for_product_page (by browser guid) ---------------------

  test "purchase_info_for_product_page matches by browser guid when there is no user" do
    product = create_product(is_in_preorder_state: false)
    purchase = create_purchase(link: product)
    assert_equal purchase.external_id, product.purchase_info_for_product_page(nil, purchase.browser_guid)[:id]
  end

  test "purchase_info_for_product_page returns nil for a gift-sender purchase matched by browser guid" do
    product = create_product(is_in_preorder_state: false)
    purchase = create_purchase(link: product, is_gift_sender_purchase: true)
    assert_nil product.purchase_info_for_product_page(nil, purchase.browser_guid)
  end

  test "purchase_info_for_product_page returns nil for a gift-receiver purchase matched by browser guid" do
    product = create_product(is_in_preorder_state: false)
    purchase = create_purchase(link: product, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_nil product.purchase_info_for_product_page(nil, purchase.browser_guid)
  end

  test "purchase_info_for_product_page matches a preorder purchase by browser guid" do
    product = create_product(is_in_preorder_state: true)
    purchase = create_preorder_authorization_purchase(link: product)
    assert_equal purchase.external_id, product.purchase_info_for_product_page(nil, purchase.browser_guid)[:id]
  end

  test "purchase_info_for_product_page returns nil for a preorder gift-sender purchase by browser guid" do
    product = create_product(is_in_preorder_state: true)
    purchase = create_preorder_authorization_purchase(link: product, is_gift_sender_purchase: true)
    assert_nil product.purchase_info_for_product_page(nil, purchase.browser_guid)
  end

  test "purchase_info_for_product_page matches by browser guid even for a non-matching user" do
    product = create_product(is_in_preorder_state: false)
    purchase = create_purchase(link: product)
    assert_equal purchase.external_id, product.purchase_info_for_product_page(create_user, purchase.browser_guid)[:id]
  end

  test "purchase_info_for_product_page returns nil for a non-matching user's gift-receiver browser-guid purchase" do
    product = create_product(is_in_preorder_state: false)
    purchase = create_purchase(link: product, is_gift_receiver_purchase: true, purchase_state: "gift_receiver_purchase_successful")
    assert_nil product.purchase_info_for_product_page(create_user, purchase.browser_guid)
  end

  test "purchase_info_for_product_page returns nil without a user or browser guid" do
    product = create_product(is_in_preorder_state: false)
    create_purchase(link: product)
    assert_nil product.purchase_info_for_product_page(nil, nil)
  end

  # --- service product validation --------------------------------------------

  test "a service product is invalid for a seller not yet eligible" do
    commission = build_product(native_type: "commission")
    commission.save
    assert_not commission.valid?
    assert_equal "Service products are disabled until your account is 30 days old.", commission.errors.full_messages.first
  end

  test "a service product is valid for an eligible seller" do
    commission = build_product(user: create_eligible_seller, native_type: "commission", price_cents: 200)
    commission.save
    assert commission.valid?
  end

  # --- #show_in_sections! ----------------------------------------------------

  test "show_in_sections! moves the product into the given sections" do
    seller = create_user
    product = create_product(user: seller)
    section1 = create_seller_profile_products_section(seller:, shown_products: [product.id])
    section2 = create_seller_profile_products_section(seller:)
    seller.reload

    product.show_in_sections!([section2.external_id])
    assert_equal [], section1.reload.shown_products
    assert_equal [product.id], section2.reload.shown_products
  end

  # --- #variants_or_skus -----------------------------------------------------

  test "variants_or_skus returns custom SKUs when SKUs are enabled" do
    product = create_physical_product
    assert_equal [], product.variants_or_skus # only the default SKU
    sku = create_sku(link: product)
    assert_equal [sku], product.reload.variants_or_skus
  end

  test "variants_or_skus returns variants when SKUs are disabled" do
    product = create_product
    variant = create_variant(variant_category: create_variant_category(link: product))
    assert_equal [variant], product.variants_or_skus
    variant.update!(deleted_at: Time.current)
    assert_equal [], product.reload.variants_or_skus
  end

  # --- #has_embedded_license_key? --------------------------------------------

  test "has_embedded_license_key? is false for product rich content without a license key" do
    product = create_product
    create_rich_content(entity: product)
    assert_equal false, product.has_embedded_license_key?
  end

  test "has_embedded_license_key? is true for product rich content with a license key" do
    product = create_product
    create_rich_content(entity: product, description: [{ "type" => "licenseKey" }])
    assert_equal true, product.has_embedded_license_key?
  end

  test "has_embedded_license_key? is false when no variant rich content has a license key" do
    product = create_product
    variant = create_variant(variant_category: create_variant_category(link: product))
    create_rich_content(entity: variant)
    assert_equal false, product.has_embedded_license_key?
  end

  test "has_embedded_license_key? is true when a variant's rich content has a license key" do
    product = create_product
    category = create_variant_category(link: product)
    variant1 = create_variant(variant_category: category)
    variant2 = create_variant(variant_category: category)
    create_rich_content(entity: variant1, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Some text" }] }])
    create_rich_content(entity: variant2, description: [{ "type" => "paragraph", "content" => [{ "type" => "text", "text" => "Variant 2 text" }] }, { "type" => "licenseKey" }])
    assert_equal true, product.has_embedded_license_key?
  end

  # --- #has_another_collaborator? --------------------------------------------

  test "has_another_collaborator? tracks live collaborators regardless of invitation status" do
    product = create_product
    collaborator_for_another_product = create_collaborator(products: [create_product])
    # affiliates are ignored
    create_direct_affiliate(products: [product])
    create_product_affiliate(product:, affiliate: create_user.global_affiliate)

    assert_equal false, product.has_another_collaborator?
    assert_equal false, product.has_another_collaborator?(collaborator: collaborator_for_another_product)

    collaborator = create_collaborator(pending_invitation: true, products: [product])
    assert_equal true, product.has_another_collaborator?
    assert_equal false, product.has_another_collaborator?(collaborator:)
    assert_equal true, product.has_another_collaborator?(collaborator: collaborator_for_another_product)

    collaborator.collaborator_invitation.destroy!
    assert_equal true, product.has_another_collaborator?
    assert_equal false, product.has_another_collaborator?(collaborator:)
    assert_equal true, product.has_another_collaborator?(collaborator: collaborator_for_another_product)

    collaborator.mark_deleted!
    assert_equal false, product.has_another_collaborator?
    assert_equal false, product.has_another_collaborator?(collaborator:)
    assert_equal false, product.has_another_collaborator?(collaborator: collaborator_for_another_product)
  end

  # --- #has_product_level_rich_content? --------------------------------------

  test "has_product_level_rich_content? is true unless variants have their own content" do
    product = create_product
    physical_product = create_physical_product
    shared = create_product(has_same_rich_content_for_all_variants: true)
    create_variant(variant_category: create_variant_category(link: shared), name: "V1")
    not_shared = create_product
    create_variant(variant_category: create_variant_category(link: not_shared), name: "V1")

    assert [product, physical_product, shared].all?(&:has_product_level_rich_content?)
    assert_equal false, not_shared.has_product_level_rich_content?
  end

  # --- #percentage_revenue_cut_for_user --------------------------------------

  test "percentage_revenue_cut_for_user is 100 for the creator of a non-collab, 0 for others" do
    product = create_product(is_collab: false)
    assert_equal 100, product.percentage_revenue_cut_for_user(product.user)
    assert_equal 0, product.percentage_revenue_cut_for_user(create_user)
  end

  test "percentage_revenue_cut_for_user splits between collaborator and creator once accepted" do
    product = create_collab_product(collaborator_cut: 45_00)
    seller = product.user
    affiliate_user = product.collaborator.affiliate_user

    assert_equal 55, product.percentage_revenue_cut_for_user(seller)
    assert_equal 45, product.percentage_revenue_cut_for_user(affiliate_user)

    product.collaborator.create_collaborator_invitation!
    assert_equal 100, product.percentage_revenue_cut_for_user(seller)
    assert_equal 0, product.percentage_revenue_cut_for_user(affiliate_user)
  end

  test "percentage_revenue_cut_for_user is 0 for unrelated users on a collab" do
    product = create_collab_product(collaborator_cut: 45_00)
    assert_equal 0, product.percentage_revenue_cut_for_user(create_user)
  end

  # --- #unpublish! -----------------------------------------------------------

  test "unpublish! disables purchases and records admin unpublishing" do
    product = create_product
    freeze_time do
      product.unpublish!(is_unpublished_by_admin: true)
      product.reload
      assert_equal Time.current, product.purchase_disabled_at
      assert_equal true, product.is_unpublished_by_admin
    end
  end

  test "unpublish! is allowed even when a membership's tier structure is invalid" do
    membership = create_product(is_tiered_membership: true)
    membership.variant_categories.alive.each { |vc| vc.update!(deleted_at: Time.current) }
    assert_nothing_raised { membership.unpublish! }
    assert membership.reload.purchase_disabled_at.present?
  end

  test "an invalid membership tier structure still fails on non-unpublish updates" do
    membership = create_product(is_tiered_membership: true)
    membership.variant_categories.alive.each { |vc| vc.update!(deleted_at: Time.current) }
    error = assert_raises(Link::LinkInvalid) { membership.update!(name: "New Name") }
    assert_equal "Memberships should only have one Tier version category.", error.message
  end

  # --- #alive? / #published? -------------------------------------------------

  test "alive? reflects purchasable state" do
    assert_equal true, build_product.alive?
    assert_equal false, build_product(banned_at: Time.current).alive?
    assert_equal false, build_product(deleted_at: Time.current).alive?
    assert_equal false, build_product(purchase_disabled_at: Time.current).alive?
  end

  test "published? requires the product be purchasable and not a draft" do
    assert_equal true, build_product.published?
    assert_equal false, build_product(purchase_disabled_at: Time.current).published?
    assert_equal false, build_product(draft: true).published?
  end

  # --- commission validations ------------------------------------------------

  test "a commission priced at 0 is valid" do
    assert create_product(user: create_eligible_seller, native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 0).valid?
  end

  test "a commission priced below double the currency minimum is invalid" do
    commission = create_product(user: create_eligible_seller, native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 0)
    commission.price_cents = 100
    assert_not commission.valid?
    assert_equal "The commission price must be at least 1.98 USD.", commission.errors.full_messages.first
  end

  test "a commission priced at least double the currency minimum is valid" do
    commission = create_product(user: create_eligible_seller, native_type: Link::NATIVE_TYPE_COMMISSION, price_cents: 0)
    commission.price_cents = 198
    assert commission.valid?
  end

  # --- coffee validations ----------------------------------------------------

  test "a seller can only have one coffee product" do
    seller = create_eligible_seller
    create_coffee_product(user: seller, purchase_disabled_at: Time.current)
    coffee = build_product(user: seller, native_type: Link::NATIVE_TYPE_COFFEE)
    assert_not coffee.valid?
    assert_equal "You can only have one coffee product.", coffee.errors.full_messages.first
  end

  test "a second coffee product is allowed when the other is deleted" do
    seller = create_eligible_seller
    create_coffee_product(user: seller, deleted_at: Time.current)
    assert build_product(user: seller, native_type: Link::NATIVE_TYPE_COFFEE).valid?
  end

  test "unarchiving a coffee product is blocked when another exists" do
    seller = create_eligible_seller
    coffee_a = create_coffee_product(user: seller, archived: true)
    create_coffee_product(user: seller)
    coffee_a.archived = false
    assert_not coffee_a.valid?
    assert_equal "You can only have one coffee product.", coffee_a.errors.full_messages.first
  end

  test "unarchiving a coffee product is allowed when no other exists" do
    seller = create_eligible_seller
    coffee_a = create_coffee_product(user: seller, archived: true)
    coffee_a.archived = false
    assert coffee_a.valid?
  end

  test "a coffee product's variants must cost at least the minimum price" do
    coffee = create_coffee_product
    category = create_variant_category(link: coffee)
    variant = create_variant(variant_category: category, price_difference_cents: 100)
    assert_not build_variant(variant_category: category, price_difference_cents: 0).valid?
    variant.price_difference_cents = 0
    assert_not variant.valid?
  end

  # --- calls validations ------------------------------------------------------

  test "a call product with no durations is invalid unless deleted" do
    call = create_call_product(durations: [])
    assert call.invalid?
    assert_equal "Calls must have at least one duration", call.errors.full_messages.first
    call.deleted_at = Time.current
    assert call.valid?
  end

  test "a call product with durations is valid" do
    assert create_call_product(durations: [30]).valid?
  end

  # --- support email validations ---------------------------------------------

  test "support_email may be nil but not blank, and must be a valid format" do
    product = build_product
    product.support_email = nil
    assert product.valid?
    product.support_email = ""
    assert_not product.valid?
    product.support_email = "support@example.com"
    assert product.valid?
    product.support_email = "invalidemail"
    assert_not product.valid?
    assert_includes product.errors[:support_email], "is invalid"
    product.support_email = "user@"
    assert_not product.valid?
    assert_includes product.errors[:support_email], "is invalid"
  end

  # --- #can_gift? -------------------------------------------------------------

  test "can_gift? is true for a regular or recurring product, false for a preorder" do
    assert_equal true, build_product.can_gift?
    assert_equal false, build_product(is_in_preorder_state: true).can_gift?
    assert_equal true, build_product(is_recurring_billing: true).can_gift?
  end

  test "can_gift? is false when the seller has disabled gifting at checkout" do
    product = build_product
    product.user.gifting_disabled = true
    assert_equal false, product.can_gift?
  end

  # --- #quantity_enabled / #can_enable_quantity? ------------------------------

  test "quantity_enabled cannot be true for memberships or calls, but can for others" do
    membership = create_membership_product
    membership.quantity_enabled = true
    assert membership.invalid?
    assert_includes membership.errors.full_messages, "Customers cannot be allowed to choose a quantity for this product."
    membership.quantity_enabled = false
    assert membership.valid?

    call = create_call_product
    call.quantity_enabled = true
    assert call.invalid?

    product = build_product
    product.quantity_enabled = true
    assert product.valid?
  end

  test "can_enable_quantity? is true only for non-membership, non-call products" do
    assert_equal false, create_call_product.can_enable_quantity?
    assert_equal false, create_membership_product.can_enable_quantity?
    assert_equal true, create_physical_product.can_enable_quantity?
  end

  # --- #multiseat_license_enabled? ---------------------------------------------

  test "multiseat_license_enabled? is true when the flag is set on a non-call product" do
    product = create_product(is_licensed: true, is_multiseat_license: true)
    assert_equal true, product.multiseat_license_enabled?
  end

  test "multiseat_license_enabled? is false when the flag is off" do
    product = create_product(is_licensed: true)
    assert_equal false, product.multiseat_license_enabled?
  end

  test "multiseat_license_enabled? is false for calls even when the flag is set" do
    # The editor hides the seat toggle for calls, but the flag can still be set via
    # the API or predate that gating. A call books one slot per purchase, so seats
    # must never be offered or applied for it.
    call = create_call_product
    call.update_attribute(:is_multiseat_license, true)
    assert_equal false, call.multiseat_license_enabled?
  end

  # --- #require_captcha? ------------------------------------------------------

  test "require_captcha? is false for sellers older than 6 months, true for younger" do
    older = create_user(created_at: 6.months.ago - 1.day)
    assert_equal false, create_product(user: older).require_captcha?
    younger = create_user(created_at: 6.months.ago + 1.day)
    assert_equal true, create_product(user: younger).require_captcha?
  end

  # --- #toggle_community_chat! -----------------------------------------------

  test "toggle_community_chat! enables chat and creates a community when none exists" do
    product = create_product
    assert_difference -> { product.reload.communities.count }, 1 do
      product.toggle_community_chat!(true)
    end
    assert_equal true, product.reload.community_chat_enabled
    assert_equal product.communities.last, product.active_community
  end

  test "toggle_community_chat! restores a deleted community when enabling" do
    product = create_product
    community = create_community(resource: product, deleted_at: 1.day.ago)
    assert_nil product.active_community
    product.toggle_community_chat!(true)
    assert_equal true, product.reload.community_chat_enabled
    assert_nil community.reload.deleted_at
    assert_equal community, product.active_community
  end

  test "toggle_community_chat! does nothing when already enabled" do
    product = create_product
    product.update!(community_chat_enabled: true)
    create_community(resource: product)
    assert_no_difference -> { product.communities.count } do
      product.toggle_community_chat!(true)
      assert_equal true, product.reload.community_chat_enabled
    end
  end

  test "toggle_community_chat! disables chat and deletes the active community" do
    product = create_product
    product.update!(community_chat_enabled: true)
    create_community(resource: product)
    assert_difference -> { product.reload.communities.alive.count }, -1 do
      product.toggle_community_chat!(false)
    end
    assert_equal false, product.reload.community_chat_enabled
    assert_nil product.active_community
  end

  test "toggle_community_chat! does nothing when already disabled" do
    product = create_product
    assert_no_difference -> { product.communities.count } do
      product.toggle_community_chat!(false)
      assert_equal false, product.reload.community_chat_enabled
    end
  end

  # --- #cart_item ------------------------------------------------------------

  test "cart_item falls back to product prices when a tier's variant is missing" do
    product = create_membership_product
    product.tier_category.variants.each { |variant| variant.update!(deleted_at: Time.current) }
    result = product.cart_item({})
    assert_kind_of Hash, result
    assert result.key?(:option)
    assert result.key?(:price)
  end

  # --- currencies ------------------------------------------------------------

  test "prices round-trip through price_range for every supported currency" do
    CURRENCY_CHOICES.each_key do |currency_type|
      product = create_product(price_currency_type: currency_type, price_cents: CURRENCY_CHOICES[currency_type][:min_price] * 10)
      original_cents = product.price_cents
      # Reassigning the current unit price should be a no-op; if it changes the
      # price, our subunit treatment has diverged from Money's.
      product.price_range = product.price_formatted_without_dollar_sign
      assert_equal original_cents, product.price_cents, "#{currency_type} did not round-trip"
    end
  end

  # --- #gumroad_amount_for_paypal_order --------------------------------------

  test "gumroad_amount_for_paypal_order returns 10% of the amount" do
    product = create_product
    assert_equal 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00)
    assert_equal 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, was_recommended: true)
  end

  test "gumroad_amount_for_paypal_order adds the discover fee minus 10% for recommended sales" do
    product = create_product
    product.update!(discover_fee_per_thousand: 500)
    assert_equal 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00)
    assert_equal 500, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, was_recommended: true)
  end

  test "gumroad_amount_for_paypal_order adds a direct affiliate's fee" do
    creator = create_user
    product = create_product(user: creator)
    affiliate = create_direct_affiliate(seller: creator, affiliate_basis_points: 2500, products: [product])
    assert_equal 100 + 250, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id)
  end

  test "gumroad_amount_for_paypal_order omits the affiliate fee for direct-affiliate Discover sales" do
    creator = create_user
    product = create_product(user: creator)
    affiliate = create_direct_affiliate(seller: creator, affiliate_basis_points: 2500, products: [product])
    assert_equal 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id, was_recommended: true)
  end

  test "gumroad_amount_for_paypal_order adds a global affiliate's fee, even for Discover sales" do
    product = create_recommendable_product
    affiliate = create_user.global_affiliate
    # Global affiliates earn a flat 10% (100c) and — unlike direct affiliates —
    # keep it on Discover sales too.
    assert_equal 100 + 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id)
    assert_equal 100 + 100, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id, was_recommended: true)
  end

  test "gumroad_amount_for_paypal_order adds VAT" do
    creator = create_user
    product = create_product(user: creator)
    affiliate = create_direct_affiliate(affiliate_user: create_affiliate_user, seller: creator, affiliate_basis_points: 2500, products: [product])
    assert_equal 380, product.gumroad_amount_for_paypal_order(amount_cents: 10_00, affiliate_id: affiliate.id, vat_cents: 30)
  end

  # --- #ppp_details ----------------------------------------------------------

  test "ppp_details returns nil when the country's PPP factor doesn't exist" do
    product = ppp_product
    GeoIp::Result.any_instance.stubs(:country_code).returns("FAKE")
    assert_nil product.ppp_details("109.110.31.255")
  end

  test "ppp_details returns nil when PPP is disabled for the product" do
    product = ppp_product
    product.update!(purchasing_power_parity_disabled: true)
    assert_nil product.ppp_details("109.110.31.255")
  end

  test "ppp_details returns nil when the PPP factor is 1" do
    assert_nil ppp_product.ppp_details("101.198.198.0") # US, factor 1
  end

  test "ppp_details returns the details when the factor exists and isn't 1" do
    assert_equal({ country: "Latvia", factor: 0.5, minimum_price: 99 }, ppp_product.ppp_details("109.110.31.255"))
  end

  # --- #thumbnail_or_cover_url -----------------------------------------------

  test "thumbnail_or_cover_url returns nil when the product has no thumbnail or covers" do
    assert_nil create_product.thumbnail_or_cover_url
  end

  test "thumbnail_or_cover_url returns the thumbnail, falling back to the first cover image" do
    product = create_product
    thumbnail = create_thumbnail(product:)
    assert_equal thumbnail.url, product.thumbnail_or_cover_url

    create_asset_preview_mov(link: product)
    cover = create_asset_preview(link: product)
    assert_equal thumbnail.url, product.reload.thumbnail_or_cover_url

    thumbnail.mark_deleted!
    assert_equal cover.url, product.reload.thumbnail_or_cover_url
  end

  # --- #for_email_thumbnail_url ----------------------------------------------

  test "for_email_thumbnail_url returns the native-type thumbnail when there's no thumbnail" do
    assert_equal ActionController::Base.helpers.image_url("native_types/thumbnails/digital.png"),
                 create_product.for_email_thumbnail_url
  end

  test "for_email_thumbnail_url returns the thumbnail url when there's an active thumbnail" do
    product = create_product
    create_thumbnail(product:)
    assert_equal product.thumbnail.alive.url, product.reload.for_email_thumbnail_url
  end

  test "for_email_thumbnail_url falls back to the native-type thumbnail when the thumbnail is deleted" do
    product = create_product
    create_thumbnail(product:)
    product.reload.thumbnail.mark_deleted!
    assert_equal ActionController::Base.helpers.image_url("native_types/thumbnails/digital.png"),
                 product.reload.for_email_thumbnail_url
  end

  # --- #reorder_previews -----------------------------------------------------

  test "reorder_previews updates the positions of previews" do
    product = create_product
    previews = Array.new(8) { create_asset_preview(link: product) }
    # Move preview[3] to the front; the rest keep their relative order.
    product.reorder_previews(
      previews[0].guid => 1,
      previews[1].guid => 2,
      previews[2].guid => 3,
      previews[3].guid => 0,
      previews[4].guid => 4,
      previews[5].guid => 5,
      previews[6].guid => 6,
      previews[7].guid => 7,
    )

    expected = [previews[3], previews[0], previews[1], previews[2], previews[4], previews[5], previews[6], previews[7]].map(&:id)
    assert_equal expected, product.display_asset_previews.pluck(:id)
  end

  # --- #generate_product_files_archives! -------------------------------------

  test "generate_product_files_archives! generates folder archives for product-level rich content" do
    product = create_product
    file1 = create_product_file(link: product)
    file2 = create_product_file(link: product)
    create_rich_content(entity: product, description: [file_embed_group("folder 1", [file1, file2])])

    assert_difference -> { product.product_files_archives.folder_archives.alive.size }, 1 do
      product.generate_product_files_archives!
    end
  end

  test "generate_product_files_archives! generates folder archives for variant-level rich content" do
    product = create_product
    category = create_variant_category(link: product)
    version1 = create_variant(variant_category: category, name: "V1")
    version2 = create_variant(variant_category: category, name: "V2")

    file1 = create_product_file(display_name: "File 1")
    file2 = create_product_file(display_name: "File 2")
    file3 = create_product_file(display_name: "File 3")
    file4 = create_product_file(display_name: "File 4")
    product.product_files = [file1, file2, file3, file4]
    version1.product_files = [file1, file2]
    version2.product_files = [file3, file4]
    create_rich_content(entity: version1, description: [file_embed_group("folder 1", [file1, file2])])
    create_rich_content(entity: version2, description: [file_embed_group("folder 1", [file3, file4])])

    assert_no_difference -> { product.product_files_archives.folder_archives.size } do
      assert_difference -> { version1.product_files_archives.folder_archives.alive.size }, 1 do
        assert_difference -> { version2.product_files_archives.folder_archives.alive.size }, 1 do
          product.generate_product_files_archives!
        end
      end
    end
  end

  test "generate_product_files_archives! regenerates archives containing the provided files" do
    product = create_product
    file1 = create_product_file(link: product)
    file2 = create_product_file(link: product)
    folder_id = SecureRandom.uuid
    create_rich_content(entity: product, description: [file_embed_group("folder 1", [file1, file2], folder_id:)])

    archive = product.product_files_archives.create!(folder_id:, product_files: product.product_files)
    archive.mark_in_progress!
    archive.mark_ready!

    assert_no_difference -> { archive.reload.deleted? ? 1 : 0 } do
      product.generate_product_files_archives!
    end
    assert_difference -> { archive.reload.deleted? ? 1 : 0 }, 1 do
      product.generate_product_files_archives!(for_files: [file1])
    end
    assert_equal 1, product.product_files_archives.folder_archives.alive.size
    assert_equal folder_id, product.product_files_archives.folder_archives.alive.first.folder_id
  end

  # --- installment plan ------------------------------------------------------

  test "updating the product re-validates its installment plan" do
    product = create_product(price_cents: 1000)
    create_product_installment_plan(link: product, number_of_installments: 2)
    product.price_cents = 99
    assert_not product.valid?
    assert_includes product.errors.full_messages, "Installment plan The minimum price for each installment must be at least 0.99 USD."
  end

  # --- .eligible_for_content_upsells -----------------------------------------

  test "eligible_for_content_upsells returns visible non-membership products (incl. with variants)" do
    regular = create_product
    create_readable_document(link: regular)
    with_variants = create_product_with_digital_versions
    membership = create_membership_product
    archived = create_product(archived: true)

    result = Link.eligible_for_content_upsells
    assert_includes result, regular
    assert_includes result, with_variants
    assert_not_includes result, membership
    assert_not_includes result, archived
  end

  # --- currency --------------------------------------------------------------

  test "yen is a single-unit currency" do
    product.price_currency_type = :jpy
    assert_equal true, product.send(:single_unit_currency?)
  end

  test "price_currency_type= downcases the currency type" do
    product.price_currency_type = "USD"
    assert_equal "usd", product.price_currency_type
  end

  test "price_currency_type= handles symbol input" do
    product.price_currency_type = :GBP
    assert_equal "gbp", product.price_currency_type
  end

  test "price_currency_type= lets clean_price work with uppercase currency input" do
    product = create_product(price_currency_type: "USD", price_cents: 100)
    product.price_range = "12"
    assert_equal 1200, product.price_cents
  end

  # --- #checkout_custom_fields / #custom_field_descriptors -------------------

  test "checkout_custom_fields returns non-post-purchase fields (global first)" do
    product = create_product
    custom_field = create_custom_field(name: "Custom field", products: [product])
    create_custom_field(name: "Post-purchase custom field", products: [product], is_post_purchase: true)
    global_custom_field = create_custom_field(name: "Global custom field", global: true, seller: product.user)
    create_custom_field(name: "Post-purchase global custom field", seller: product.user, is_post_purchase: true, global: true)

    assert_equal [global_custom_field, custom_field], product.checkout_custom_fields
  end

  test "custom_field_descriptors returns formatted custom fields" do
    product = create_product
    product.custom_fields << create_custom_field(name: "I'm custom!")
    assert_equal [
      { id: product.custom_fields.last.external_id, type: "text", name: "I'm custom!", required: false, collect_per_product: false },
    ], product.custom_field_descriptors
  end

  # --- #custom_view_content_button_text --------------------------------------

  test "custom_view_content_button_text saves when within the limit" do
    product.custom_view_content_button_text = "Custom Name"
    product.save!
    assert_equal "Custom Name", product.custom_view_content_button_text
  end

  test "custom_view_content_button_text errors when longer than 26 characters" do
    product = create_product
    text = "This text is over 26 characters and it can't be saved."
    product.custom_view_content_button_text = text
    assert_raises(ActiveRecord::RecordInvalid) { product.save! }
    assert_equal "Button: #{text.length - 26} characters over limit (max: 26)", product.errors.full_messages.to_sentence
  end

  # --- #content_cannot_contain_adult_keywords --------------------------------

  test "content with no adult keywords adds no errors" do
    product = create_product
    product.name = "Safe name"
    product.description = "This is a safe description."
    product.save
    assert_empty product.errors
  end

  test "adult keyword in the description adds an error" do
    product = create_product
    product.description = "fetish"
    product.save
    assert_includes product.errors.full_messages, "Adult keywords are not allowed"
  end

  test "adult keyword in the name adds an error" do
    product = create_product
    product.name = "fetish"
    product.save
    assert_includes product.errors.full_messages, "Adult keywords are not allowed"
  end

  private
    # A rich-content fileEmbedGroup node wrapping the given product files —
    # the shape generate_product_files_archives! walks to build folder archives.
    def file_embed_group(name, files, folder_id: SecureRandom.uuid)
      {
        "type" => "fileEmbedGroup",
        "attrs" => { "name" => name, "uid" => folder_id },
        "content" => files.map do |file|
          { "type" => "fileEmbed", "attrs" => { "id" => file.external_id, "uid" => SecureRandom.uuid } }
        end,
      }
    end

    # Six products across two users for the permalink-fetching tests.
    def fetch_leniently_context
      user_1 = create_user
      user_2 = create_user
      {
        user_1:, user_2:,
        product_1: create_product(user: user_1, unique_permalink: "aaa"),
        product_2: create_product(user: user_1, unique_permalink: "bbb", custom_permalink: "custom"),
        product_3: create_product(user: user_1, unique_permalink: "ccc", custom_permalink: "no-longer-alive", deleted_at: Time.current),
        product_4: create_product(user: user_2, unique_permalink: "ddd"),
        product_5: create_product(user: user_2, unique_permalink: "eee", custom_permalink: "awesome"),
        product_6: create_product(user: user_2, unique_permalink: "fff", custom_permalink: "custom"),
      }
    end

    # Sets up another seller's licensed product carrying the "abc"/"xyz"
    # permalinks and created before the force_product_id_timestamp, then seeds
    # that timestamp in Redis. Returns the timestamp. The other product must
    # exist *before* the timestamp is set, otherwise its own creation would trip
    # the same custom_permalink_of_licensed_product validation.
    def seed_licensed_permalink_conflict
      timestamp = Time.current
      @other_licensed_product = create_product(is_licensed: true, custom_permalink: "abc", unique_permalink: "xyz", created_at: timestamp - 1.day)
      $redis.set(RedisKey.force_product_id_timestamp, timestamp)
      timestamp
    end

    # Asserts a Sidekiq worker was enqueued with the given args AND scheduled with
    # the expected delay (fake mode records the scheduled time in job["at"]).
    def assert_enqueued_in(worker, args, delay:)
      job = worker.jobs.find { |enqueued| enqueued["args"] == args }
      assert job, "expected #{worker} to be enqueued with args #{args.inspect}"
      assert job["at"], "expected #{worker} to be scheduled with a delay"
      assert_in_delta delay.from_now.to_f, job["at"], 30, "#{worker} was not scheduled ~#{delay.inspect} out"
    end

    # A product whose seller has PPP enabled, with the LV/US conversion factors
    # seeded in Redis. LV=0.5 (half price) and US=1 (no discount) drive the
    # ppp_details cases. The test IPs (109.110.31.255 → Latvia, 101.198.198.0 →
    # US) are resolved by the real MaxMind GeoIP database.
    def ppp_product
      product = create_product(user: create_user(purchasing_power_parity_enabled: true))
      ppp_service = PurchasingPowerParityService.new
      ppp_service.set_factor("LV", 0.5)
      ppp_service.set_factor("US", 1)
      product
    end

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
