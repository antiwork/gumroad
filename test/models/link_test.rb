# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/link_spec.rb. Link (a product) is exercised mostly
# through model logic — validations, callbacks, pricing, scopes — so objects
# are built with the shared ModelFactories helpers (create_product/build_product,
# create_variant, …). The RSpec file was tagged :vcr defensively, but the
# product model paths here make no external HTTP calls.
class LinkTest < ActiveSupport::TestCase
  setup do
    @product = create_product
  end

  # --- #custom_html= ---------------------------------------------------------

  test "custom_html= clears the page HTML without marking the associated page for destruction" do
    @product.update!(custom_html: "<section>Live landing page</section>")
    page = @product.reload.page

    @product.custom_html = nil

    assert_equal page, @product.page
    refute @product.page.marked_for_destruction?

    @product.save!

    assert_equal page, @product.reload.page
    assert_nil @product.custom_html
  end

  test "is not a single-unit currency" do
    assert_equal false, @product.send(:single_unit_currency?)
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
    refute product.valid?
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
    refute product.valid?
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
    refute product.valid?
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
    refute product.valid?
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
      refute product.valid?, "expected #{fee.inspect} to be invalid"
      assert_includes product.errors.full_messages, message
    end
  end

  # --- alive_category_variants_presence validation ---------------------------

  test "physical product with no versions is valid" do
    product = create_physical_product
    assert_nothing_raised { product.save! }
    assert product.valid?
    refute product.errors.any?
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
    refute product.valid?
    assert_equal "Sorry, the product versions must have at least one option.", product.errors.full_messages.to_sentence
  end

  test "non-physical product with no versions is valid" do
    assert_nothing_raised { @product.save! }
    assert @product.valid?
  end

  test "non-physical product with non-empty versions is valid" do
    category_one = create_variant_category(link: @product)
    category_two = create_variant_category(link: @product)
    create_variant(variant_category: category_one)
    create_variant(variant_category: category_two)
    assert_nothing_raised { @product.save! }
    assert @product.valid?
  end

  test "non-physical product with an empty version fails" do
    create_variant_category(link: @product)
    category_two = create_variant_category(link: @product)
    create_variant(variant_category: category_two)
    assert_raises(ActiveRecord::RecordInvalid) { @product.save! }
    refute @product.valid?
    assert_equal "Sorry, the product versions must have at least one option.", @product.errors.full_messages.to_sentence
  end

  # --- free trial validation -------------------------------------------------

  test "free trial can be enabled on a recurring product with valid duration" do
    product = build_subscription_product(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    assert product.valid?
  end

  test "free trial requires duration properties when enabled" do
    product = build_subscription_product(free_trial_enabled: true)
    refute product.valid?
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
    refute product.valid?
  end

  test "free trial properties are not required when disabled" do
    assert build_subscription_product(free_trial_enabled: false).valid?
  end

  test "free trial only allows permitted durations" do
    product = build_subscription_product(free_trial_enabled: true, free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    assert product.valid?

    product.free_trial_duration_amount = 2
    refute product.valid?

    product.free_trial_duration_amount = 0.5
    refute product.valid?
  end

  test "free trial cannot be enabled on a non-recurring product" do
    product = build_product(free_trial_enabled: true)
    refute product.valid?
    assert_includes product.errors.full_messages, "Free trials are only allowed for subscription products."
  end

  test "free trial properties cannot be set on a non-recurring product" do
    product = build_product(free_trial_duration_unit: :week, free_trial_duration_amount: 1)
    refute product.valid?
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
    refute_nil product.reload.purchase_disabled_at
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
    @product.purchase_type = :buy_only
    assert_equal "buy_only", @product.purchase_type
    @product.purchase_type = :rent_only
    assert_equal "rent_only", @product.purchase_type
    @product.purchase_type = :buy_and_rent
    assert_equal "buy_and_rent", @product.purchase_type
  end

  test "purchase_type= defaults to buy_only for an invalid value" do
    @product.purchase_type = "buy"
    assert_equal "buy_only", @product.purchase_type
  end

  test "purchase_type= does not raise for an invalid value" do
    assert_nothing_raised { @product.purchase_type = "invalid" }
    assert_equal "buy_only", @product.purchase_type
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

  private
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
