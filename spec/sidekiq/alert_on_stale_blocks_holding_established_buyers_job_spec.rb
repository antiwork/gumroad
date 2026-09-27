# frozen_string_literal: true

require "spec_helper"

describe AlertOnStaleBlocksHoldingEstablishedBuyersJob do
  let(:email) { "established@example.com" }

  # Settled history has to be old enough to count at all — MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY is what
  # makes a purchase evidence about the person rather than a fresh card that has not been disputed yet.
  let(:history_starts_at) { 6.months.ago }

  def settled_purchases(count, buyer_email: email, **attrs)
    count.times.map do |index|
      create(:purchase, email: buyer_email, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at + index.days, **attrs)
    end
  end

  def block_email(value = email, blocked_at: 2.years.ago, **attrs)
    travel_to(blocked_at) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: value, **attrs)
    end
  end

  def established_count
    Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY
  end

  def message
    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_, _, body| captured = body }
    described_class.new.perform
    captured
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  # The whole point of this job: no failure row anywhere, so the failure-keyed report cannot see this
  # buyer at all.
  it "clears and reports a buyer who has never attempted a blocked checkout" do
    settled_purchases(established_count)
    block = block_email

    expect(message).to include(email, "#{established_count} settled purchases", "cleared")
    expect(block.reload.blocked_at).to be_nil
  end

  it "names the date the block was written" do
    settled_purchases(established_count)
    block_email(blocked_at: Date.new(2021, 4, 29).to_time)

    expect(message).to include("blocked by email since 2021-04-29")
  end

  it "ignores a buyer without enough settled purchases" do
    settled_purchases(established_count - 1)
    block = block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
    expect(block.reload.blocked_at).to be_present
  end

  it "ignores purchases too recent to have been disputed" do
    settled_purchases(established_count, created_at: 1.day.ago)
    block = block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
    expect(block.reload.blocked_at).to be_present
  end

  it "ignores free purchases, which cost a card tester nothing" do
    settled_purchases(established_count, price_cents: 0)
    block = block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
    expect(block.reload.blocked_at).to be_present
  end

  it "ignores a buyer carrying a chargeback on another purchase" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, chargeback_date: 1.month.ago)
    block = block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
    expect(block.reload.blocked_at).to be_present
  end

  it "still clears a buyer whose only chargeback was reversed" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, chargeback_date: 1.month.ago,
                      flags: Purchase.flag_mapping["flags"][:chargeback_reversed])
    block = block_email

    expect(message).to include(email, "cleared")
    expect(block.reload.blocked_at).to be_nil
  end

  # A named block is somebody's decision about this buyer, not a rule that outlived itself.
  it "ignores a block a human wrote" do
    settled_purchases(established_count)
    block = block_email(by: create(:admin_user).id)

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
    expect(block.reload.blocked_at).to be_present
  end

  it "ignores a block that was already cleared" do
    settled_purchases(established_count)
    block_email.unblock!

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "ignores a block that has expired" do
    settled_purchases(established_count)
    block = block_email
    block.update!(expires_at: 1.day.ago)

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  # Only email blocks name a person. A guid block names a device, so this job cannot say whose
  # history to count and the failure-keyed report owns that case.
  it "ignores a browser guid block" do
    settled_purchases(established_count)
    travel_to(2.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-abc")
    end

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "ignores an email domain block, which holds more than one buyer" do
    settled_purchases(established_count)
    travel_to(2.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")
    end

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  # The column collates ci, so a legacy mixed-case history row comes back under its own casing and
  # would not join to a lowercase block value without normalising both sides.
  #
  # Purchase#downcase_email lowercases on write, so a mixed-case row cannot be created through
  # validation — update_column is what actually puts the legacy casing in the table. Creating it
  # normally makes this test pass whether or not the job normalises anything.
  it "matches legacy mixed-case history to the block value" do
    settled_purchases(established_count).each do |purchase|
      purchase.update_column(:email, "Established@Example.com")
    end
    block_email

    expect(message).to include("#{established_count} settled purchases")
  end

  it "reports the oldest block first" do
    settled_purchases(established_count)
    settled_purchases(established_count, buyer_email: "newer@example.com")
    block_email(blocked_at: 3.years.ago)
    block_email("newer@example.com", blocked_at: 6.months.ago)

    lines = message.split("\n").select { |line| line.start_with?("•") }
    expect(lines.first).to include(email)
    expect(lines.second).to include("newer@example.com")
  end

  describe "clearing the card and browser rows from the email block's burst" do
    let(:guid) { "guid-established" }
    let(:fingerprint) { "fp-established" }

    def block_value(type, value, blocked_at: 2.years.ago, **attrs)
      travel_to(blocked_at) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[type], object_value: value, **attrs) }
    end

    before { settled_purchases(established_count, browser_guid: guid, stripe_fingerprint: fingerprint) }

    it "clears the buyer's own browser and card rows written in the same burst" do
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      guid_block = block_value(:browser_guid, guid, blocked_at: at + 1.second)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at + 1.second)

      expect(message).to include(email, "cleared with 2 card/browser blocks from the same burst")
      expect([email_block, guid_block, card_block].map { _1.reload.blocked_at }).to all(be_nil)
    end

    it "leaves a row of the buyer's written outside the burst" do
      block_email(blocked_at: 2.years.ago)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: 1.year.ago)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "leaves a stranger's row written in the same burst" do
      at = 2.years.ago
      block_email(blocked_at: at)
      stranger = block_value(:charge_processor_fingerprint, "fp-stranger", blocked_at: at)

      message
      expect(stranger.reload.blocked_at).to be_present
    end

    it "leaves a row a human wrote" do
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at, by: create(:admin_user).id)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "leaves the IP row, which is shared and expires on its own" do
      at = 2.years.ago
      block_email(blocked_at: at)
      ip_block = block_value(:ip_address, "203.0.113.9", blocked_at: at, expires_in: 10.years)

      message
      expect(ip_block.reload.blocked_at).to be_present
    end

    it "keeps a browser the card-testing velocity rule still wants" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "tested-#{index}",
                          email: "tester#{index}@example.com")
      end
      at = 2.years.ago
      block_email(blocked_at: at)
      guid_block = block_value(:browser_guid, guid, blocked_at: at)

      message
      expect(guid_block.reload.blocked_at).to be_present
    end

    it "keeps a browser the all-time card-testing rule still wants after the 7-day window" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "old-tested-#{index}",
                          email: "old-tester#{index}@example.com",
                          charge_processor_id: StripeChargeProcessor.charge_processor_id,
                          created_at: (Purchase::Blockable::CARD_TESTING_WATCH_PERIOD + 1.day).ago)
      end
      at = 2.years.ago
      block_email(blocked_at: at)
      guid_block = block_value(:browser_guid, guid, blocked_at: at)

      message
      expect(guid_block.reload.blocked_at).to be_present
    end

    it "keeps the card sibling while the burst's own browser holds the 7-day rule" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "browser-tested-#{index}",
                          email: "other#{index}@example.com",
                          charge_processor_id: StripeChargeProcessor.charge_processor_id,
                          created_at: (Purchase::Blockable::CARD_TESTING_WATCH_PERIOD - 1.day).ago)
      end
      at = 2.years.ago
      block_email(blocked_at: at)
      guid_block = block_value(:browser_guid, guid, blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(guid_block.reload.blocked_at).to be_present
      expect(card_block.reload.blocked_at).to be_present
    end

    it "clears the burst when the failures are spread over browsers no single attempt counted" do
      shared_guid = "guid-shared"
      settled_purchases(1, browser_guid: shared_guid)
      2.times do |index|
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "spread-a#{index}",
                          email: "a#{index}@example.com",
                          created_at: (Purchase::Blockable::CARD_TESTING_WATCH_PERIOD - 1.day).ago)
        create(:purchase, purchase_state: "failed", browser_guid: shared_guid, stripe_fingerprint: "spread-b#{index}",
                          email: "b#{index}@example.com",
                          created_at: (Purchase::Blockable::CARD_TESTING_WATCH_PERIOD - 1.day).ago)
      end
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      guid_block = block_value(:browser_guid, guid, blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect([email_block, guid_block, card_block].map { _1.reload.blocked_at }).to all(be_nil)
    end

    it "leaves a stranger's card block that only matches a Stripe masked visual" do
      visual = "**** **** **** 4062"
      Purchase.successful.where(email:).update_all(card_visual: visual, charge_processor_id: StripeChargeProcessor.charge_processor_id)
      at = 2.years.ago
      block_email(blocked_at: at)
      stranger = block_value(:charge_processor_fingerprint, visual, blocked_at: at)

      message
      expect(stranger.reload.blocked_at).to be_present
    end

    it "keeps a card the issuer fraud rule still wants" do
      stolen = "fp-stolen"
      create(:purchase, email:, stripe_fingerprint: stolen, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      create(:purchase, purchase_state: "failed", stripe_fingerprint: stolen, email: "thief@example.com",
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD,
                        charge_processor_id: StripeChargeProcessor.charge_processor_id)
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, stolen, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "keeps a card a fraud-coded renewal blocked on the charged card, not the failed row" do
      saved = "fp-saved-card"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      prior = create(:purchase, email:, stripe_fingerprint: "fp-column-differs", purchase_state: "successful", price_cents: 500,
                                created_at: history_starts_at)
      renewal = create(:purchase, email: "renewal@example.com", stripe_fingerprint: "fp-other-row", purchase_state: "failed",
                                  stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      at = 2.years.ago
      prior.update_columns(credit_card_id: charged.id, subscription_id:, stripe_fingerprint: "fp-column-differs")
      renewal.update_columns(credit_card_id: charged.id, subscription_id:, created_at: at)
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "clears a card whose fraud-coded renewals were on subscriptions that never paid with it" do
      saved = "fp-unproven-card"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4311")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      at = 2.years.ago
      described_class::SUBSCRIPTION_CARD_LOOKUP_LIMIT.times do
        renewal = create(:purchase, email: "renewal@example.com", stripe_fingerprint: "fp-other-row", purchase_state: "failed",
                                    stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
        renewal.update_columns(credit_card_id: charged.id, subscription_id:, created_at: at)
      end
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_nil
    end

    it "keeps a renewal card after a later block refreshes blocked_at" do
      saved = "fp-refreshed-card"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      first_write = 10.days.ago
      renewal = create(:purchase, email: "renewal@example.com", stripe_fingerprint: "fp-other-row", purchase_state: "failed",
                                  stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      prior = create(:purchase, email:, stripe_fingerprint: "fp-column-differs", purchase_state: "successful", price_cents: 500,
                                created_at: history_starts_at)
      prior.update_columns(credit_card_id: charged.id, subscription_id:)
      renewal.update_columns(credit_card_id: charged.id, subscription_id:, created_at: first_write)
      refreshed = Time.current
      block_email(blocked_at: refreshed)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: first_write)
      card_block.update_columns(blocked_at: refreshed)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "clears a card when fraud-coded failures in the window do not meet the fraud rule" do
      saved = "fp-unrelated-window"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      described_class::SUBSCRIPTION_CARD_LOOKUP_LIMIT.times do |index|
        decline = create(:purchase, email: "noise#{index}@example.com", stripe_fingerprint: "fp-noise-#{index}",
                                    purchase_state: "failed", stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
        decline.update_columns(credit_card_id: charged.id, subscription_id:, created_at: 1.hour.ago)
      end
      at = Time.current
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_nil
    end

    it "keeps a card when fraud-coded failures exceed the decline scan limit" do
      stub_const("#{described_class}::RENEWAL_DECLINE_WORK_LIMIT", described_class::SUBSCRIPTION_CARD_LOOKUP_LIMIT)
      saved = "fp-over-scan"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      (described_class::SUBSCRIPTION_CARD_LOOKUP_LIMIT + 1).times do |index|
        decline = create(:purchase, email: "over-scan#{index}@example.com", stripe_fingerprint: "fp-over-scan-#{index}",
                                    purchase_state: "failed", stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
        decline.update_columns(credit_card_id: charged.id, subscription_id:, created_at: 1.hour.ago)
      end
      at = Time.current
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "keeps a renewal the fraud rule wants when unrelated failures fill the lookup page" do
      saved = "fp-page-past-noise"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      now = Time.current
      noise_subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      described_class::SUBSCRIPTION_CARD_LOOKUP_LIMIT.times do |index|
        decline = create(:purchase, email: "page-noise#{index}@example.com", stripe_fingerprint: "fp-page-noise-#{index}",
                                    purchase_state: "failed", stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
        decline.update_columns(credit_card_id: charged.id, subscription_id: noise_subscription_id, created_at: 1.hour.ago)
      end
      renewal = create(:purchase, email: "renewal-page@example.com", stripe_fingerprint: "fp-page-other-row", purchase_state: "failed",
                                  stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
      paid_subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      prior = create(:purchase, email:, stripe_fingerprint: "fp-page-column-differs", purchase_state: "successful", price_cents: 500,
                                created_at: history_starts_at)
      prior.update_columns(credit_card_id: charged.id, subscription_id: paid_subscription_id)
      renewal.update_columns(credit_card_id: charged.id, subscription_id: paid_subscription_id, created_at: 1.hour.ago)
      at = Time.current
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "clears a card when failures are split across browsers the writer would not combine" do
      other_guid = "guid-other-browser"
      create(:purchase, email:, purchase_state: "successful", price_cents: 500, browser_guid: other_guid,
                        stripe_fingerprint: fingerprint, created_at: history_starts_at)
      2.times do |index|
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "split-a-#{index}",
                          email: "split-a#{index}@example.com", charge_processor_id: StripeChargeProcessor.charge_processor_id,
                          created_at: 1.day.ago)
        create(:purchase, purchase_state: "failed", browser_guid: other_guid, stripe_fingerprint: "split-b-#{index}",
                          email: "split-b#{index}@example.com", charge_processor_id: StripeChargeProcessor.charge_processor_id,
                          created_at: 1.day.ago)
      end
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_nil
    end

    it "keeps a renewal that sits only in the original window after a later block overlaps it" do
      saved = "fp-overlap-card"
      charged = CreditCard.new(stripe_fingerprint: saved, card_type: "visa", visual: "**** **** **** 4242")
      charged.save!(validate: false)
      create(:purchase, email:, stripe_fingerprint: saved, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at)
      first_write = 3.days.ago
      renewal = create(:purchase, email: "renewal-overlap@example.com", stripe_fingerprint: "fp-overlap-row",
                                  purchase_state: "failed", stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD)
      now = Time.current
      subscription_id = Subscription.connection.insert(
        Subscription.sanitize_sql_array(["INSERT INTO subscriptions (link_id, created_at, updated_at, flags) VALUES (?, ?, ?, 0)", create(:product).id, now, now])
      )
      prior = create(:purchase, email:, stripe_fingerprint: "fp-overlap-column", purchase_state: "successful", price_cents: 500,
                                created_at: history_starts_at)
      prior.update_columns(credit_card_id: charged.id, subscription_id:)
      renewal.update_columns(credit_card_id: charged.id, subscription_id:, created_at: first_write - 36.hours)
      refreshed = first_write + 1.day
      block_email(blocked_at: refreshed)
      card_block = block_value(:charge_processor_fingerprint, saved, blocked_at: first_write)
      card_block.update_columns(blocked_at: refreshed)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "keeps a card when this email and one browser together still trip the 7-day rule" do
      half = Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS / 2
      half.times do |index|
        create(:purchase, purchase_state: "failed", email:, browser_guid: "guid-other-email-failures",
                          stripe_fingerprint: "union-email-#{index}",
                          charge_processor_id: StripeChargeProcessor.charge_processor_id, created_at: 1.day.ago)
        create(:purchase, purchase_state: "failed", browser_guid: guid, stripe_fingerprint: "union-guid-#{index}",
                          email: "union-other#{index}@example.com",
                          charge_processor_id: StripeChargeProcessor.charge_processor_id, created_at: 1.day.ago)
      end
      at = 2.years.ago
      block_email(blocked_at: at)
      block_value(:browser_guid, guid, blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "clears no sibling when successful-purchase browsers exceed the lookup cap" do
      stub_const("#{described_class}::MAX_SIBLING_VALUES", 1)
      create(:purchase, email:, purchase_state: "successful", price_cents: 500, browser_guid: "guid-over-cap",
                        stripe_fingerprint: fingerprint, created_at: history_starts_at)
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end

    it "retries a sibling clear that raises while the email block is still active" do
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)
      raised = false
      allow_any_instance_of(PlatformBlock).to receive(:unblock!).and_wrap_original do |original, *args|
        if !raised && original.receiver.id == card_block.id
          raised = true
          raise "sibling clear failed"
        end
        original.call(*args)
      end

      expect { described_class.new.perform }.to raise_error("sibling clear failed")
      expect(email_block.reload.blocked_at).to be_present
      expect(card_block.reload.blocked_at).to be_present

      message
      expect(email_block.reload.blocked_at).to be_nil
      expect(card_block.reload.blocked_at).to be_nil
    end

    it "clears a fraud-coded card once that card has the settled history the fraud rule requires" do
      settled = "fp-stolen-settled"
      settled_purchases(established_count, stripe_fingerprint: settled)
      create(:purchase, purchase_state: "failed", stripe_fingerprint: settled, email: "thief@example.com",
                        stripe_error_code: PurchaseErrorCode::CARD_DECLINED_STOLEN_CARD,
                        charge_processor_id: StripeChargeProcessor.charge_processor_id)
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, settled, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_nil
    end

    it "leaves a card that only reached this email on a failed attempt" do
      create(:purchase, purchase_state: "failed", email:, stripe_fingerprint: "fp-tester")
      at = 2.years.ago
      block_email(blocked_at: at)
      tester_card = block_value(:charge_processor_fingerprint, "fp-tester", blocked_at: at)

      message
      expect(tester_card.reload.blocked_at).to be_present
    end

    it "clears no sibling while the 7-day email velocity rule would still fire" do
      Purchase::Blockable::MAX_NUMBER_OF_FAILED_FINGERPRINTS.times do |index|
        create(:purchase, purchase_state: "failed", email:, browser_guid: "other-#{index}", stripe_fingerprint: "tested-#{index}")
      end
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(email_block.reload.blocked_at).to be_nil
      expect(card_block.reload.blocked_at).to be_present
    end

    it "keeps a sibling an admin re-blocked after the lookup" do
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)
      admin = create(:admin_user)
      allow_any_instance_of(PlatformBlock).to receive(:unblock!).and_wrap_original do |original, *args|
        PlatformBlock.add!(object_type: card_block.object_type, object_value: fingerprint, by: admin.id) if original.receiver.id == email_block.id
        original.call(*args)
      end

      message
      expect(card_block.reload).to have_attributes(blocked_by: admin.id, blocked_at: be_present)
    end

    it "leaves the email block for the next run when a sibling write raises" do
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)
      allow_any_instance_of(PlatformBlock).to receive(:unblock!).and_wrap_original do |original, *args|
        raise ActiveRecord::ActiveRecordError, "sibling write failed" if original.receiver.id == card_block.id

        original.call(*args)
      end

      expect { described_class.new.perform }.to raise_error(ActiveRecord::ActiveRecordError)
      expect(email_block.reload.blocked_at).to be_present
    end

    it "keeps an email an admin re-blocked while siblings were clearing" do
      at = 2.years.ago
      email_block = block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)
      admin = create(:admin_user)
      allow_any_instance_of(PlatformBlock).to receive(:unblock!).and_wrap_original do |original, *args|
        PlatformBlock.add!(object_type: email_block.object_type, object_value: email, by: admin.id) if original.receiver.id == card_block.id
        original.call(*args)
      end

      described_class.new.perform
      expect(email_block.reload).to have_attributes(blocked_by: admin.id, blocked_at: be_present)
    end

    it "clears no sibling when the email block is held" do
      create(:user, email:, user_risk_state: "suspended_for_fraud")
      at = 2.years.ago
      block_email(blocked_at: at)
      card_block = block_value(:charge_processor_fingerprint, fingerprint, blocked_at: at)

      message
      expect(card_block.reload.blocked_at).to be_present
    end
  end

  describe "the account-suspension veto (Sahil, gumroad-private#1746)" do
    # The whole reason this job holds rather than clears: a block tied to a suspended account is a
    # fraud call, not staleness, even though the block row itself carries blocked_by: nil.
    it "holds a block whose email is a suspended account's own login email" do
      create(:user, email:, user_risk_state: "suspended_for_fraud")
      settled_purchases(established_count)
      block = block_email

      expect(message).to include(email, "held", "linked to a suspended account")
      expect(block.reload.blocked_at).to be_present
    end

    it "holds a block whose purchases resolve to a suspended account as purchaser" do
      suspended_user = create(:user, user_risk_state: "suspended_for_tos_violation")
      settled_purchases(established_count, purchaser_id: suspended_user.id)
      block = block_email

      expect(message).to include(email, "held", "linked to a suspended account")
      expect(block.reload.blocked_at).to be_present
    end

    it "clears a block whose account is merely flagged, not suspended" do
      create(:user, email:, user_risk_state: "flagged_for_fraud")
      settled_purchases(established_count)
      block = block_email

      expect(message).to include(email, "cleared")
      expect(block.reload.blocked_at).to be_nil
    end

    it "clears a block with no linked account at all" do
      settled_purchases(established_count)
      block = block_email

      expect(message).to include(email, "cleared")
      expect(block.reload.blocked_at).to be_nil
    end
  end

  describe "re-checking the block immediately before writing" do
    # The candidate query's snapshot can go stale between enumeration and the write — a concurrent
    # admin block is exactly the case blocked_by: nil is supposed to protect, so re-reading the row
    # right before unblock! is what keeps a race from clearing a human's decision.
    it "does not clear a block that was attended to after this run's candidate scan" do
      settled_purchases(established_count)
      block = block_email

      admin_id = create(:admin_user).id
      original_reload = PlatformBlock.instance_method(:reload)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |instance|
        instance.update_column(:blocked_by, admin_id) if instance.id == block.id && instance.blocked_by.nil?
        original_reload.bind_call(instance)
      end

      expect(message).to include(email, "held")
      expect(block.reload.blocked_by).to eq(admin_id)
    end

    # reject_disputed and linked_to_suspended_account both run once per batch, before any row's
    # write — a chargeback recorded (or an account suspended) in that gap must still be caught at
    # the write, not just at enumeration time.
    it "does not clear a block whose buyer got a chargeback after the batch's dispute check ran" do
      purchases = settled_purchases(established_count)
      block = block_email

      original_reload = PlatformBlock.instance_method(:reload)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |instance|
        purchases.first.update!(chargeback_date: Time.current) if instance.id == block.id
        original_reload.bind_call(instance)
      end

      expect(message).to include(email, "held")
      expect(block.reload.blocked_at).to be_present
    end

    it "does not clear a block whose account got suspended after the batch's suspension check ran" do
      settled_purchases(established_count)
      block = block_email

      original_reload = PlatformBlock.instance_method(:reload)
      allow_any_instance_of(PlatformBlock).to receive(:reload) do |instance|
        if instance.id == block.id && !User.exists?(email:)
          create(:user, email:, user_risk_state: "suspended_for_fraud")
        end
        original_reload.bind_call(instance)
      end

      expect(message).to include(email, "held")
      expect(block.reload.blocked_at).to be_present
    end
  end

  describe "sweeping the backlog across runs" do
    # The whole point of gp#1746: a fixed page re-reports the same blocks forever and never reaches
    # the rest. Each run must resume past what the previous one judged.
    it "resumes after the block the previous run stopped at" do
      settled_purchases(established_count)
      settled_purchases(established_count, buyer_email: "second@example.com")
      first = block_email
      block_email("second@example.com", blocked_at: 1.year.ago)

      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)

      expect(message).to include(email)
      expect($redis.get(RedisKey.stale_block_sweep_cursor).to_i).to eq(first.id)

      # Second run: the first block is behind the cursor, so the next one surfaces.
      second_message = message
      expect(second_message).to include("second@example.com")
      expect(second_message).not_to include(email)
    end

    it "wraps to the start once it runs out of blocks" do
      settled_purchases(established_count)
      block = block_email
      $redis.set(RedisKey.stale_block_sweep_cursor, block.id)

      # Nothing past the cursor, so the sweep restarts rather than reporting nothing forever.
      expect(message).to include(email)
    end

    # gp#1746 P1: the cursor used to be saved right after fetching the page, before the history
    # queries ran, so a raise on the FIRST run would still commit an advanced cursor and the retry
    # (or next scheduled run) would resume past the failed page rather than re-scanning it.
    it "does not advance the cursor when a history query raises mid-page" do
      settled_purchases(established_count)
      block = block_email

      allow(Purchase).to receive(:successful).and_raise("boom")

      expect { described_class.new.perform }.to raise_error("boom")
      expect($redis.get(RedisKey.stale_block_sweep_cursor)).to be_nil

      # Retry re-scans the same block instead of skipping it, now that the query works again.
      allow(Purchase).to receive(:successful).and_call_original
      expect(message).to include(email)
      expect($redis.get(RedisKey.stale_block_sweep_cursor).to_i).to eq(block.id)
    end
  end

  # A truncated scan that found nothing must still report: otherwise the bound, not the platform,
  # decided the report was empty and nobody knows.
  it "reports truncation even when nothing on the page qualified" do
    stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
    block_email("nohistory1@example.com", blocked_at: 3.years.ago)
    block_email("nohistory2@example.com", blocked_at: 2.years.ago)

    expect(message).to include("not evidence that none do", "floor")
  end

  it "says the count is a floor when the scan was truncated" do
    stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
    settled_purchases(established_count)
    block_email(blocked_at: 3.years.ago)
    block_email("other@example.com", blocked_at: 2.years.ago)

    expect(message).to include("cleared", "floor")
  end

  it "sends nothing when no block qualifies and the scan was not truncated" do
    settled_purchases(established_count)

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end
end
