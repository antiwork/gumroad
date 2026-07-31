# frozen_string_literal: true

require "spec_helper"

describe AlertOnBlockedEstablishedBuyersJob do
  let(:browser_guid) { "guid-established-buyer" }
  let(:email) { "established@example.com" }

  # Settled history has to predate the blocked attempt, and be old enough to count at all —
  # MIN_PURCHASE_AGE_FOR_CLEAN_HISTORY is what makes a purchase evidence about the person.
  let(:history_starts_at) { 6.months.ago }

  def settled_purchases(count, buyer_email: email, **attrs)
    count.times.map do |index|
      create(:purchase, email: buyer_email, purchase_state: "successful", price_cents: 500,
                        created_at: history_starts_at + index.days, **attrs)
    end
  end

  def blocked_attempt(buyer_email: email, guid: browser_guid, created_at: 1.hour.ago,
                      error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    create(:purchase, email: buyer_email, browser_guid: guid, created_at:,
                      purchase_state: "failed", error_code:)
  end

  def established_count
    Purchase::Blockable::MIN_SUCCESSFUL_PURCHASES_FOR_CLEAN_HISTORY
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "alerts on a buyer with settled history, naming the date the block was written" do
    settled_purchases(established_count)
    blocked_attempt
    block = travel_to(4.months.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, sender, message|
      expect(room).to eq("risk")
      expect(sender).to eq("Blocked established buyers")
      expect(message).to include(email)
      expect(message).to include("#{established_count} settled purchases")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # The whole reason this job exists alongside AlertOnBlockedEstablishedSubscribersJob: the buyer
  # who prompted it had no failing subscription at all, so the subscriber report could not see him.
  it "alerts on a buyer who has never had a subscription" do
    settled_purchases(established_count)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    expect { described_class.new.perform }.not_to change { Purchase.where.not(subscription_id: nil).count }
    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include(email)
    end
  end

  # The subscriber job's 6-charge floor is what made a subscriber under it invisible. A renewal
  # blocked below that floor is the same stranded person, so this job must not re-scope itself away
  # from renewals.
  it "alerts on a blocked renewal that sits under the subscriber report's charge floor" do
    subscription = create(:membership_purchase, email:, created_at: history_starts_at).subscription
    settled_purchases(established_count, buyer_email: email)
    create(:purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false,
                      email:, browser_guid:, purchase_state: "failed", created_at: 1.hour.ago,
                      error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include(email)
    end
  end

  it "alerts when the checkout failed on a blocked email domain" do
    settled_purchases(established_count)
    blocked_attempt(error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include(email)
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  it "counts how many times the buyer tried" do
    settled_purchases(established_count)
    3.times { |index| blocked_attempt(created_at: (index + 1).hours.ago) }
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("3 attempts")
    end
  end

  it "reports the buyer once even when several of their checkouts failed" do
    settled_purchases(established_count)
    3.times { |index| blocked_attempt(created_at: (index + 1).hours.ago) }
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message.scan(/#{Regexp.escape(email)}/).size).to eq(1)
      expect(message).to include("1 buyer with")
    end
  end

  it "ignores a buyer without enough settled purchases" do
    settled_purchases(established_count - 1)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # A purchase from today is not evidence about the person: the cardholder has not had time to
  # notice it. Counting it would let a card tester's own successful run establish them.
  it "ignores purchases too recent to have been disputed" do
    settled_purchases(established_count, buyer_email: email).each do |purchase|
      purchase.update!(created_at: 1.day.ago)
    end
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores free purchases, which cost a card tester nothing" do
    settled_purchases(established_count, price_cents: 0)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # Counting per email rather than per card is what makes this necessary: a buyer with enough clean
  # purchases AND a chargeback elsewhere would otherwise read as established, and a chargeback is
  # exactly what a block is for.
  it "ignores a buyer carrying a chargeback on another purchase" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, chargeback_date: 3.months.ago)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a buyer carrying a full refund on another purchase" do
    settled_purchases(established_count)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500,
                      created_at: history_starts_at, stripe_refunded: true)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a checkout that failed for a reason other than a block" do
    settled_purchases(established_count)
    blocked_attempt(error_code: PurchaseErrorCode::CREDIT_CARD_NOT_PROVIDED)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a failure older than the lookback window" do
    settled_purchases(established_count)
    blocked_attempt(created_at: described_class::FAILURE_LOOKBACK.ago - 1.day)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  describe "eligibility is the block being active now" do
    it "ignores a buyer whose block was already cleared" do
      settled_purchases(established_count)
      blocked_attempt
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid).unblock!

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "ignores a buyer whose block has expired" do
      settled_purchases(established_count)
      blocked_attempt
      travel_to(2.days.ago) do
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid,
                           expires_in: 1.day)
      end

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end
  end

  # An admin or chargeback block names who wrote it. Reporting it as staleness would invite clearing
  # a decision somebody still means.
  it "ignores a block a human wrote" do
    settled_purchases(established_count)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid,
                       by: create(:admin_user).id)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a buyer who bought successfully after their blocked attempt" do
    settled_purchases(established_count)
    blocked_attempt(created_at: 2.days.ago)
    create(:purchase, email:, purchase_state: "successful", price_cents: 500, created_at: 1.day.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "still reports a buyer whose successful purchases all predate the blocked attempt" do
    settled_purchases(established_count)
    blocked_attempt(created_at: 1.hour.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include(email)
    end
  end

  # A guid string is enforced by Purchase::Risk#past_blocked_object, which matches object_value
  # alone — so a row stored under another type still declines the checkout, and scoping the lookup
  # to :browser_guid would drop the buyer entirely.
  it "finds the guid block when the row carrying the value is stored under another type" do
    settled_purchases(established_count)
    blocked_attempt
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  it "does not treat another block type carrying the domain value as the domain block" do
    settled_purchases(established_count)
    blocked_attempt(error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "example.com")

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "finds a domain block stored in a different casing" do
    settled_purchases(established_count)
    blocked_attempt(error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "Example.COM")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  it "dates the block that declined the checkout, not an older unrelated one" do
    settled_purchases(established_count)
    blocked_attempt
    travel_to(2.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")
    end
    guid_block = travel_to(2.months.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{guid_block.blocked_at.to_date}")
    end
  end

  it "ranks the buyer with the most settled history first" do
    small_email = "small@example.com"
    settled_purchases(established_count, buyer_email: small_email)
    blocked_attempt(buyer_email: small_email, created_at: 1.minute.ago)
    settled_purchases(established_count + 5, buyer_email: email)
    blocked_attempt(created_at: 2.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message.index(email)).to be < message.index(small_email)
    end
  end

  it "caps the list and says how many were omitted" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    2.times do |index|
      buyer_email = "buyer#{index}@example.com"
      settled_purchases(established_count, buyer_email:)
      blocked_attempt(buyer_email:)
    end
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("2 buyers with")
      expect(message).to include("…and 1 more.")
    end
  end

  it "sends nothing when no established buyer is blocked" do
    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  describe "when the scan hits its cap" do
    before { stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1) }

    it "says the counts are floors" do
      2.times do |index|
        buyer_email = "buyer#{index}@example.com"
        settled_purchases(established_count, buyer_email:)
        blocked_attempt(buyer_email:, created_at: (index + 1).hours.ago)
      end
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("At least 1 buyer")
        expect(message).to include("The scan stopped at 1 buyers")
      end
    end

    # Otherwise a truncated scan that happened to qualify nobody looks exactly like a clean
    # platform, and the bound rather than the data decided the report was empty.
    it "still reports when the scanned page qualified nobody" do
      2.times do |index|
        blocked_attempt(buyer_email: "buyer#{index}@example.com", created_at: (index + 1).hours.ago)
      end
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("not evidence that nobody is stranded")
      end
    end
  end

  it "does not claim truncation when the whole window fit in the scan" do
    settled_purchases(established_count)
    blocked_attempt
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).not_to include("At least")
      expect(message).not_to include("The scan stopped at")
    end
  end

  it "is registered on the schedule so it actually runs" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))

    expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
  end

  # Every example above stubs the worker, so nothing else would notice the room going away — and
  # InternalNotificationMailer#notify returns silently when the room has no recipient, which would
  # leave the job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: "risk", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
