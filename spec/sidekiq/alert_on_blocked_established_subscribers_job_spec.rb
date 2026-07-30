# frozen_string_literal: true

require "spec_helper"

describe AlertOnBlockedEstablishedSubscribersJob do
  let(:browser_guid) { "guid-established" }
  let(:email) { "established@example.com" }

  # Builds a subscription with exactly `total` successful purchases against it. The membership
  # factory's own original purchase is successful and counts, so only the remainder are renewals.
  def subscription_with_history(total)
    subscription = create(:membership_purchase).subscription
    (total - 1).times do
      create(:purchase, link: subscription.link, subscription:,
                        is_original_subscription_purchase: false, purchase_state: "successful")
    end
    subscription
  end

  def failed_renewal(subscription:, guid: browser_guid, buyer_email: email, created_at: 1.hour.ago,
                     error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    create(:purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false,
                      email: buyer_email, browser_guid: guid, created_at:,
                      purchase_state: "failed", error_code:)
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "alerts on a subscriber with enough history, naming the date the block was written" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:)
    block = travel_to(3.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, _sender, message|
      expect(room).to eq("risk")
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("#{described_class::MIN_SUCCESSFUL_CHARGES} successful charges")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # The gap the pre-merge review found: a renewal can fail on a domain block too, and those rows
  # have no expiry either, so leaving them out would have made a quiet alert mean "nobody is
  # stranded" when domain-blocked subscribers were.
  it "alerts when the renewal failed on a blocked email domain" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # The domain check reads four addresses, not just the purchase's own. A subscriber blocked on
  # their account's domain is stranded exactly as hard, and reading fewer domains than production
  # does would drop them silently now that an active block is what makes an entry eligible.
  it "alerts when the blocked domain is the purchaser's account domain rather than the purchase's" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    purchaser = create(:user, email: "member@blocked-domain.com")
    renewal = failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    renewal.update!(purchaser:)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "blocked-domain.com")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # A seller blocking their own buyer is a decision, not staleness.
  it "ignores a renewal blocked by the seller's own customer block" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a subscriber without enough successful charges" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES - 1)
    failed_renewal(subscription:)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores renewals that failed for a reason other than a block" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a failure older than the lookback window" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, created_at: described_class::FAILURE_LOOKBACK.ago - 1.day)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a subscription once even when several of its renewals failed" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, created_at: 2.hours.ago)
    failed_renewal(subscription:, created_at: 1.hour.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message.scan("subscription #{subscription.id}").size).to eq(1)
      expect(message).to include("1 subscription with")
    end
  end

  # The two halves of "currently stranded", which is the state this alert is about — not "failed
  # recently", which drifts away from it in both directions.
  describe "eligibility is the block being active now" do
    # A block is not a retryable error, so a blocked subscriber fails once and then goes quiet until
    # their next billing date. Anchoring on recent failures dropped them the following day while the
    # block still stood, which is the case gumroad-private#1480 documented.
    it "still reports an active block whose last failed attempt was days ago" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, created_at: 10.days.ago)
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("subscription #{subscription.id}")
        expect(message).to include("blocked since #{block.blocked_at.to_date}")
      end
    end

    it "drops a subscriber whose block has since been cleared" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid).unblock!

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "drops a subscriber whose renewal failed on a block that never existed any more" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "drops a subscriber whose block has expired" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid, expires_in: 1.day)

      travel_to(2.days.from_now) { described_class.new.perform }

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end
  end

  it "caps the list and says how many were omitted" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    2.times do |i|
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, guid: "guid-#{i}", buyer_email: "buyer#{i}@example.com")
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-#{i}")
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("2 subscriptions with")
      expect(message).to include("…and 1 more.")
    end
  end

  it "sends nothing when no established subscriber is blocked" do
    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # A count taken after a truncated scan is a floor, and reading it as the total understates the
  # incident exactly when the incident is large.
  describe "when the scan hits its cap" do
    def blocked_established_subscriber(index)
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, guid: "guid-#{index}", buyer_email: "buyer#{index}@example.com",
                     created_at: (index + 1).hours.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-#{index}")
      subscription
    end

    it "says so instead of reporting the partial count as the total" do
      stub_const("#{described_class}::MAX_SUBSCRIPTIONS_SCANNED", 1)
      2.times { |i| blocked_established_subscriber(i) }

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("At least 1 subscription with")
        expect(message).to include("The scan stopped at the newest 1 subscriptions")
      end
    end

    # The cap used to be spent on failure rows, so one subscriber's retries could consume it and
    # hide everybody behind them. Counting subscriptions is what makes the cap mean what it says.
    it "does not let one subscriber's repeated failures consume the cap" do
      stub_const("#{described_class}::MAX_SUBSCRIPTIONS_SCANNED", 2)
      noisy = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      3.times { |i| failed_renewal(subscription: noisy, created_at: (i + 1).minutes.ago) }
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
      quiet = blocked_established_subscriber(9)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("subscription #{noisy.id}")
        expect(message).to include("subscription #{quiet.id}")
        expect(message).not_to include("The scan stopped")
      end
    end

    # Truncation plus an unqualifying page is the one shape that used to send nothing at all: the
    # report would go quiet because of its own cap, which reads as "nobody is stranded".
    it "still alerts when the scanned page held nothing qualifying" do
      stub_const("#{described_class}::MAX_SUBSCRIPTIONS_SCANNED", 1)
      newcomer = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES - 1)
      failed_renewal(subscription: newcomer, created_at: 1.minute.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
      blocked_established_subscriber(9)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("the scan was truncated")
        expect(message).not_to include("• subscription")
      end
    end

    it "does not claim truncation when the window held exactly the cap" do
      stub_const("#{described_class}::MAX_SUBSCRIPTIONS_SCANNED", 1)
      blocked_established_subscriber(0)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to start_with("1 subscription with")
        expect(message).not_to include("The scan stopped")
      end
    end
  end

  it "does not claim truncation when the whole window fit in the scan" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to start_with("1 subscription with")
      expect(message).not_to include("The scan stopped")
    end
  end

  # The date has to belong to the block that declined this renewal. An older unrelated block on the
  # same subscriber would make a fresh block look stale and point cleanup at the wrong row.
  it "dates the block that declined the renewal, not an older unrelated one" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    travel_to(3.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")
    end
    guid_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{guid_block.blocked_at.to_date}")
    end
  end

  it "dates a domain-blocked renewal from the domain block, not an older guid block" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    travel_to(3.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    end
    domain_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{domain_block.blocked_at.to_date}")
    end
  end

  it "is registered on the schedule so it actually runs" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
    expect(schedule.values.map { |entry| entry["class"] }).to include(described_class.name)
  end

  # Every example above stubs the worker, so nothing else would notice the room going away —
  # and InternalNotificationMailer#notify returns silently when the room has no recipient, which
  # would leave the job permanently dark with all specs green.
  it "sends to a room that resolves to a real recipient" do
    mail = InternalNotificationMailer.notify(room_name: "risk", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
