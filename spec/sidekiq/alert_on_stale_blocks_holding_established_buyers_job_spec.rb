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
  it "reports a buyer who has never attempted a blocked checkout" do
    settled_purchases(established_count)
    block_email

    expect(message).to include(email, "#{established_count} settled purchases")
  end

  it "names the date the block was written" do
    settled_purchases(established_count)
    block_email(blocked_at: Date.new(2021, 4, 29).to_time)

    expect(message).to include("blocked by email since 2021-04-29")
  end

  it "ignores a buyer without enough settled purchases" do
    settled_purchases(established_count - 1)
    block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "ignores purchases too recent to have been disputed" do
    settled_purchases(established_count, created_at: 1.day.ago)
    block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "ignores free purchases, which cost a card tester nothing" do
    settled_purchases(established_count, price_cents: 0)
    block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "ignores a buyer carrying a chargeback on another purchase" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, chargeback_date: 1.month.ago)
    block_email

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end

  it "still reports a buyer whose only chargeback was reversed" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, chargeback_date: 1.month.ago,
                      flags: Purchase.flag_mapping["flags"][:chargeback_reversed])
    block_email

    expect(message).to include(email)
  end

  # A named block is somebody's decision about this buyer, not a rule that outlived itself.
  it "ignores a block a human wrote" do
    settled_purchases(established_count)
    block_email(by: create(:admin_user).id)

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
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
  end

  # The report must not claim these buyers stopped retrying: it never queries attempts, so that
  # state is unknown to it. Saying it anyway sent a reader looking for a fact the job cannot supply.
  it "does not claim anything about recent checkout attempts" do
    settled_purchases(established_count)
    block_email

    body = message
    expect(body).to include("does NOT query attempts")
    expect(body).not_to include("have NOT tried recently")
    expect(body).not_to include("has not tried to check out recently")
    expect(body).not_to include("no recent attempt")
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

    expect(message).to include("At least 1 active email block", "floor")
  end

  it "sends nothing when no block qualifies and the scan was not truncated" do
    settled_purchases(established_count)

    expect(InternalNotificationWorker).not_to receive(:perform_async)
    described_class.new.perform
  end
end
