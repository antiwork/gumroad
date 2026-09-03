# frozen_string_literal: true

require "test_helper"

# Ported from spec/services/gdpr_buyer_erasure_service_spec.rb (#5801).
class GdprBuyerErasureServiceTest < ActiveSupport::TestCase
  setup do
    @admin = create_admin_user
  end

  test "raises when email is blank" do
    error = assert_raises(ArgumentError) do
      GdprBuyerErasureService.new("", performed_by: @admin).perform!
    end

    assert_match(/Email is required/, error.message)
  end

  test "raises when email belongs to an active registered user" do
    create_user(email: "registered@example.com")

    error = assert_raises(ArgumentError) do
      GdprBuyerErasureService.new("registered@example.com", performed_by: @admin).perform!
    end

    assert_match(/Use GdprDataErasureService/, error.message)
  end

  test "raises when email belongs to a soft-deleted registered user" do
    create_user(email: "deleted-user@example.com", deleted_at: Time.current)

    error = assert_raises(ArgumentError) do
      GdprBuyerErasureService.new("deleted-user@example.com", performed_by: @admin).perform!
    end

    assert_match(/Use GdprDataErasureService/, error.message)
  end

  test "does not log validation failures as erasure failures" do
    Rails.logger.stubs(:error)
    Rails.logger.expects(:error).with(regexp_matches(/GDPR buyer erasure failed/)).never

    assert_raises(ArgumentError) do
      GdprBuyerErasureService.new("", performed_by: @admin).perform!
    end
  end

  test "does not log the original buyer email in plaintext when the erasure fails" do
    buyer_email = "leak-check@example.com"
    create_free_purchase(link: create_product, email: buyer_email)
    ActiveRecord::Relation.any_instance.stubs(:update_all).raises(StandardError, "boom")
    logged = []
    Rails.logger.stubs(:error).with { |msg| logged << msg; true }

    assert_raises(StandardError) do
      GdprBuyerErasureService.new(buyer_email, performed_by: @admin).perform!
    end

    assert_not_includes logged.join("\n"), buyer_email
  end

  test "raises when any purchase under this email belongs to a registered user" do
    registered_buyer = create_user
    purchase = create_free_purchase(link: create_product, email: "mixed-owner@example.com")
    purchase.update_columns(purchaser_id: registered_buyer.id)

    error = assert_raises(ArgumentError) do
      GdprBuyerErasureService.new("mixed-owner@example.com", performed_by: @admin).perform!
    end

    assert_match(/belonging to registered users/, error.message)
    assert_equal "mixed-owner@example.com", purchase.reload.email
  end
end

# The "with guest buyer data" context of the original spec: two purchases under
# the guest buyer's email plus an unrelated one.
class GdprBuyerErasureServiceGuestBuyerDataTest < ActiveSupport::TestCase
  setup do
    @admin = create_admin_user
    @buyer_email = "guest-buyer@example.com"
    @purchase1 = create_free_purchase(link: create_product, email: @buyer_email).tap do |p|
      p.update_columns(
        full_name: "Jane Doe",
        ip_address: "1.2.3.4",
        street_address: "123 Main St",
        city: "NYC",
        state: "NY",
        zip_code: "10001",
        country: "US",
        stripe_fingerprint: "fp_123",
        card_visual: "**** 4242",
        card_bin: "424242",
        browser_guid: "guid-1",
        custom_fields: '{"phone": "555-1234"}',
      )
    end
    @purchase2 = create_free_purchase(link: create_product, email: @buyer_email).tap do |p|
      p.update_columns(full_name: "Jane Doe", ip_address: "1.2.3.5", browser_guid: "guid-2")
    end
    @unrelated_purchase = create_free_purchase(link: create_product, email: "other@example.com")
  end

  test "anonymizes all purchases matching the email" do
    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal true, result[:success]
    assert_equal 2, result[:counts][:purchases]

    @purchase1.reload
    assert @purchase1.email.end_with?("@deleted.gumroad.com")
    assert_equal "[deleted]", @purchase1.full_name
    assert_nil @purchase1.ip_address
    assert_nil @purchase1.street_address
    assert_nil @purchase1.city
    assert_nil @purchase1.stripe_fingerprint
    assert_nil @purchase1.card_visual
    assert_nil @purchase1.card_bin
    # `Purchase#custom_fields` maps the purchase_custom_fields association, not this column, so
    # asserting on the reader passes whether or not the service nulled anything.
    assert_nil @purchase1.read_attribute(:custom_fields)

    @unrelated_purchase.reload
    assert_equal "other@example.com", @unrelated_purchase.email
  end

  test "anonymizes all PII columns on events tied to the buyer's purchases" do
    event = build_event(purchase_id: @purchase1.id, email: @buyer_email)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    event.reload
    assert_nil event.email
    assert_nil event.ip_address
    assert_nil event.ip_country
    assert_nil event.ip_state
    assert_nil event.billing_zip
    assert_nil event.card_type
    assert_nil event.card_visual
    assert_nil event.fingerprint
    assert_nil event.browser_fingerprint
    assert_nil event.browser_plugins
    assert_nil event.browser_guid
  end

  test "anonymizes events located by purchase even when the email column is empty" do
    event = build_event(purchase_id: @purchase2.id, email: nil)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    event.reload
    assert_nil event.ip_address
    assert_nil event.browser_guid
  end

  test "leaves events tied to unrelated purchases untouched" do
    event = build_event(purchase_id: @unrelated_purchase.id, email: "other@example.com")

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    event.reload
    assert_equal "9.9.9.9", event.ip_address
    assert_equal "guid_event", event.browser_guid
  end

  test "anonymizes events on a re-run after the events step was skipped, even though purchases were already anonymized" do
    event = build_event(purchase_id: @purchase1.id, email: @buyer_email)

    first_run = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin)
    first_run.stubs(:anonymize_events!).raises(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
    first_result = first_run.perform!

    assert_includes first_result[:skipped], :events
    assert @purchase1.reload.email.end_with?("@deleted.gumroad.com")
    assert_equal "9.9.9.9", event.reload.ip_address

    second_result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_empty second_result[:skipped]
    assert_equal 1, second_result[:counts][:events]
    assert_nil event.reload.ip_address
    assert_nil event.browser_guid
  end

  test "anonymizes followers by email" do
    follower = Follower.create!(email: @buyer_email, user: @purchase1.seller)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    follower.reload
    assert follower.email.end_with?("@deleted.gumroad.com")
  end

  test "anonymizes carts by email" do
    cart = Cart.create!(email: @buyer_email, ip_address: "5.6.7.8", browser_guid: "abc123", user: @purchase1.seller)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    cart.reload
    assert cart.email.end_with?("@deleted.gumroad.com")
    assert_nil cart.ip_address
    assert_nil cart.browser_guid
  end

  test "logs erasure on affected sellers" do
    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    seller = @purchase1.seller.reload
    comment = seller.comments.last
    assert_includes comment.content, "GDPR buyer erasure"
    assert_equal @admin.id, comment.author_id
  end

  test "generates a deterministic anonymized email" do
    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert result[:anonymized_to].start_with?("buyer-")
    assert result[:anonymized_to].end_with?("@deleted.gumroad.com")
  end

  test "uses HMAC keyed on secret_key_base, not a plain truncated SHA256 of the email" do
    service = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin)
    anonymized = service.send(:generate_anonymized_email)
    plain_sha_truncated = Digest::SHA256.hexdigest(@buyer_email)[0..11]

    assert_not_includes anonymized, plain_sha_truncated
    assert_includes anonymized, OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, @buyer_email)[0..15]
  end

  test "does not touch purchases with different emails" do
    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    @unrelated_purchase.reload
    assert_not_equal "[deleted]", @unrelated_purchase.full_name
  end

  test "completes the erasure even if logging fails" do
    with_user_find_by_raising(id: @purchase1.seller_id, message: "log failure") do
      assert_nothing_raised do
        GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!
      end
    end

    @purchase1.reload
    assert @purchase1.email.end_with?("@deleted.gumroad.com")
    assert_equal "[deleted]", @purchase1.full_name
  end

  test "swallows unexpected log_erasure! failures so a logging hiccup is not reported as a failed erasure" do
    service = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin)
    service.instance_variable_set(:@anonymized_email, "buyer-test@deleted.gumroad.com")
    service.instance_variable_set(:@seller_ids, nil)

    assert_nothing_raised { service.send(:log_erasure!) }
  end

  test "continues logging on other sellers when one seller's comment fails" do
    other_purchase = create_free_purchase(link: create_product, email: @buyer_email)
    seller_a = @purchase1.seller
    seller_b = other_purchase.seller

    with_user_find_by_raising(id: seller_a.id, message: "boom") do
      GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!
    end

    assert seller_b.reload.comments.where("content LIKE ?", "%GDPR buyer erasure%").exists?
  end

  test "anonymizes email-type blocked_customer_objects" do
    seller = @purchase1.seller
    block = BlockedCustomerObject.create!(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
      object_value: @buyer_email,
      blocked_at: Time.current
    )

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert block.reload.object_value.end_with?("@deleted.gumroad.com")
  end

  test "anonymizes buyer_email on email-type blocked_customer_objects that have it populated" do
    seller = @purchase1.seller
    block = BlockedCustomerObject.new(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
      object_value: @buyer_email,
      buyer_email: @buyer_email,
      blocked_at: Time.current
    )
    block.save!(validate: false)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    block.reload
    assert block.object_value.end_with?("@deleted.gumroad.com")
    assert block.buyer_email.end_with?("@deleted.gumroad.com")
  end

  test "does not count email-type blocked_customer_objects under the fingerprint scope" do
    seller = @purchase1.seller
    # An email-type row that happens to have buyer_email set should not be
    # counted twice when we tally fingerprint-type vs email-type updates.
    email_row = BlockedCustomerObject.new(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
      object_value: @buyer_email,
      buyer_email: @buyer_email,
      blocked_at: Time.current
    )
    email_row.save!(validate: false)

    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    # One row touched once (object_value updated), not double-counted.
    assert_equal 1, result[:counts][:blocked_customer_objects]
  end

  test "anonymizes fingerprint-type blocked_customer_objects via buyer_email" do
    seller = @purchase1.seller
    block = BlockedCustomerObject.create!(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:charge_processor_fingerprint],
      object_value: "fp_xyz",
      buyer_email: @buyer_email,
      blocked_at: Time.current
    )

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert block.reload.buyer_email.end_with?("@deleted.gumroad.com")
    assert_equal "fp_xyz", block.object_value
  end

  test "merges duplicate email-type blocked_customer_objects when an anonymized row already exists" do
    seller = @purchase1.seller
    anonymized = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).send(:generate_anonymized_email)
    existing_anonymized = BlockedCustomerObject.create!(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
      object_value: anonymized,
      blocked_at: Time.current
    )
    fresh = BlockedCustomerObject.create!(
      seller: seller,
      object_type: BlockedCustomerObject::SUPPORTED_OBJECT_TYPES[:email],
      object_value: @buyer_email,
      blocked_at: Time.current
    )

    assert_nothing_raised { GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform! }
    assert BlockedCustomerObject.where(id: existing_anonymized.id).exists?
    assert_not BlockedCustomerObject.where(id: fresh.id).exists?
  end

  test "does not anonymize discover_searches whose browser_guid is also used by another buyer's purchase" do
    shared_guid = "shared-guid-#{SecureRandom.hex(4)}"
    @purchase1.update_columns(browser_guid: shared_guid)
    other_buyer_purchase = create_free_purchase(link: create_product, email: "other-guest@example.com")
    other_buyer_purchase.update_columns(browser_guid: shared_guid)
    search = DiscoverSearch.create!(browser_guid: shared_guid, ip_address: "9.9.9.9")

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    search.reload
    assert_equal shared_guid, search.browser_guid
    assert_equal "9.9.9.9", search.ip_address
  end

  test "nullifies fingerprint on charges whose purchases are all owned by the erased buyer" do
    create_free_purchase(link: create_product, email: "other@example.com")
    charge = create_charge(payment_method_fingerprint: "fp_exclusive")
    ChargePurchase.create!(charge: charge, purchase: @purchase1)
    ChargePurchase.create!(charge: charge, purchase: @purchase2)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_nil charge.reload.payment_method_fingerprint
  end

  test "leaves fingerprint untouched on charges shared with another buyer's purchase" do
    other_buyer_purchase = create_free_purchase(link: create_product, email: "other@example.com")
    shared_charge = create_charge(payment_method_fingerprint: "fp_shared")
    ChargePurchase.create!(charge: shared_charge, purchase: @purchase1)
    ChargePurchase.create!(charge: shared_charge, purchase: other_buyer_purchase)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal "fp_shared", shared_charge.reload.payment_method_fingerprint
  end

  test "merges duplicate audience_members without violating the unique index" do
    seller = @purchase1.seller
    anonymized = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).send(:generate_anonymized_email)
    AudienceMember.where(seller: seller, email: [@buyer_email, anonymized]).delete_all
    existing_anonymized = AudienceMember.new(seller: seller, email: anonymized, details: { purchases: [{ id: 1 }] })
    existing_anonymized.save!(validate: false)
    fresh = AudienceMember.new(seller: seller, email: @buyer_email, details: { purchases: [{ id: 2 }] })
    fresh.save!(validate: false)

    anonymized_member_ids = AudienceMember.where(email: @buyer_email).where.not(id: fresh.id).ids
    ElasticsearchIndexerWorker.jobs.clear

    assert_nothing_raised { GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform! }
    assert_equal 0, AudienceMember.where(seller: seller, email: @buyer_email).count
    assert AudienceMember.where(id: existing_anonymized.id).exists?
    assert_not AudienceMember.where(id: fresh.id).exists?

    indexer_args = ElasticsearchIndexerWorker.jobs.map { _1["args"] }
    assert_includes indexer_args, ["delete", { "record_id" => fresh.id, "class_name" => "AudienceMember" }]
    assert_predicate anonymized_member_ids, :present?
    anonymized_member_ids.each do |member_id|
      reindex_args = indexer_args.find { _1[0] == "index" && _1[1]["record_id"] == member_id }
      assert_predicate reindex_args, :present?
    end
  end

  test "reindexes anonymized members with the anonymized document passed inline" do
    anonymized = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).send(:generate_anonymized_email)
    member_ids = AudienceMember.where(email: @buyer_email).ids
    assert_predicate member_ids, :present?
    ElasticsearchIndexerWorker.jobs.clear

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    audience_member_args = ElasticsearchIndexerWorker.jobs.map { _1["args"] }.select { _1[1]["class_name"] == "AudienceMember" }
    assert_equal 0, audience_member_args.count { _1[0] == "delete" }
    expected_document = {
      "email" => anonymized,
      "customer" => false,
      "follower" => false,
      "affiliate" => false,
      "purchases" => [],
      "affiliates" => [],
      "follower_id" => nil,
    }
    member_ids.each do |member_id|
      reindex_args = audience_member_args.find { _1[0] == "index" && _1[1]["record_id"] == member_id }
      assert_predicate reindex_args, :present?
      assert_equal expected_document, reindex_args[1]["body"].slice(*expected_document.keys)
    end

    AudienceMember.where(id: member_ids).each do |member|
      assert_equal false, member.customer
      assert_nil member.min_paid_cents
      assert_nil member.max_purchase_created_at
    end
  end

  test "anonymizes audience member rows for sellers the buyer only follows" do
    followed_seller = create_user
    Follower.create!(email: @buyer_email, user: followed_seller, confirmed_at: Time.current)
    member = AudienceMember.find_by(email: @buyer_email, seller: followed_seller)
    assert_predicate member, :present?
    assert_empty Purchase.where(email: @buyer_email, seller_id: followed_seller.id).ids

    anonymized = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).send(:generate_anonymized_email)
    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal anonymized, member.reload.email
  end

  # audience_members is indexed only on (seller_id, email), so an email filter without
  # a seller_id scans the whole table.
  test "filters audience_members by seller_id alongside email so the lookup stays indexed" do
    statements = []
    collector = ->(_name, _start, _finish, _id, payload) { statements << payload[:sql] }

    ActiveSupport::Notifications.subscribed(collector, "sql.active_record") do
      GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!
    end

    email_filters = statements.filter_map do |sql|
      next unless sql.include?("`audience_members`")
      conditions = sql.split(/\bWHERE\b/, 2)[1]
      conditions if conditions&.include?("`email`")
    end

    assert_predicate email_filters, :present?
    email_filters.each do |conditions|
      assert_includes conditions, "`seller_id`", "audience_members email filter must be seller-scoped: #{conditions}"
    end
  end

  test "anonymizes guest credit cards but leaves user-owned cards untouched" do
    guest_card = CreditCard.create!(
      visual: "UPI",
      card_type: CardType::UPI,
      stripe_fingerprint: "fp_guest",
      stripe_customer_id: "cus_guest",
      processor_payment_method_id: "pm_guest",
      charge_processor_id: StripeChargeProcessor.charge_processor_id,
      payment_method_type: "upi",
      stripe_account_id: "acct_guest",
      recurring_authorization_verified_at: Time.current,
      recurring_authorization_currency: Currency::INR,
      recurring_authorization_max_amount_cents: 100_000,
    )
    owned_card = CreditCard.new(visual: "**** 2222", card_type: "visa", stripe_fingerprint: "fp_owned")
    owned_card.save!(validate: false)
    User.find(create_user.id).update_columns(credit_card_id: owned_card.id)

    @purchase1.update_columns(credit_card_id: guest_card.id)
    @purchase2.update_columns(credit_card_id: owned_card.id)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    guest_card.reload
    assert_equal "[redacted]", guest_card.visual
    assert_not guest_card.recurring_upi?
    assert_nil guest_card.stripe_account_id
    assert_nil guest_card.recurring_authorization_verified_at
    assert_nil guest_card.recurring_authorization_currency
    assert_nil guest_card.recurring_authorization_max_amount_cents
    assert_equal "**** 2222", owned_card.reload.visual
  end

  test "does not anonymize a credit card also used by another buyer's purchase" do
    shared_card = CreditCard.new(visual: "**** 9999", card_type: "visa", stripe_fingerprint: "fp_shared")
    shared_card.save!(validate: false)

    @purchase1.update_columns(credit_card_id: shared_card.id)
    other_buyer_purchase = create_free_purchase(link: create_product, email: "other-guest@example.com")
    other_buyer_purchase.update_columns(credit_card_id: shared_card.id)

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal "**** 9999", shared_card.reload.visual
  end

  test "skips a timed-out step, still erases the rest, and reports it as skipped" do
    # Simulate the events table contending for a lock (the #438 failure):
    # the events step times out, but purchases and everything else must
    # still be anonymized rather than rolled back.
    GdprBuyerErasureService.any_instance.stubs(:anonymize_events!).raises(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")

    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal true, result[:success]
    assert_equal [:events], result[:skipped]
    # The rest of the erasure still happened.
    assert_equal result[:anonymized_to], @purchase1.reload.email
    assert_equal GdprDataErasureService::ANONYMIZED_NAME, @purchase1.full_name
    assert_equal result[:anonymized_to], @purchase2.reload.email
  end

  test "treats StatementTimeout and QueryCanceled as non-critical skips too" do
    GdprBuyerErasureService.any_instance.stubs(:anonymize_carts!).raises(ActiveRecord::StatementTimeout, "statement timeout")
    GdprBuyerErasureService.any_instance.stubs(:anonymize_followers!).raises(ActiveRecord::QueryCanceled, "canceling statement")

    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal true, result[:success]
    assert_equal %i[carts followers].sort, result[:skipped].sort
    assert_equal result[:anonymized_to], @purchase1.reload.email
  end

  test "records skipped tables in the seller admin comment" do
    GdprBuyerErasureService.any_instance.stubs(:anonymize_events!).raises(ActiveRecord::LockWaitTimeout, "Lock wait timeout exceeded")
    seller = @purchase1.seller

    GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    comment = seller.reload.comments.last
    assert_includes comment.content, "skipped due to lock-wait timeouts"
    assert_includes comment.content, "events"
  end

  test "still raises (does NOT silence) a non-timeout error" do
    GdprBuyerErasureService.any_instance.stubs(:anonymize_purchases!).raises(StandardError, "boom")

    error = assert_raises(StandardError) do
      GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!
    end

    assert_match(/boom/, error.message)
  end

  test "returns an empty skipped list when nothing times out" do
    result = GdprBuyerErasureService.new(@buyer_email, performed_by: @admin).perform!

    assert_equal [], result[:skipped]
  end

  private
    def build_event(attrs)
      Event.new({
        ip_address: "9.9.9.9",
        ip_country: "US",
        ip_state: "NY",
        billing_zip: "11111",
        card_type: "visa",
        card_visual: "**** 4242",
        fingerprint: "fp_event",
        browser_fingerprint: "bfp_event",
        browser_plugins: "Flash, Java",
        browser_guid: "guid_event",
        event_name: "purchase",
      }.merge(attrs)).tap { _1.save!(validate: false) }
    end

    # Equivalent of the original's `allow(User).to receive(:find_by).and_call_original`
    # plus a raising override for one id: mocha's stubs replace the method for
    # every argument list, so dispatch to the original ourselves.
    def with_user_find_by_raising(id:, message:)
      original = User.method(:find_by)
      User.define_singleton_method(:find_by) do |*args, **kwargs|
        raise StandardError, message if kwargs[:id] == id

        original.call(*args, **kwargs)
      end
      yield
    ensure
      User.singleton_class.remove_method(:find_by)
    end
end
