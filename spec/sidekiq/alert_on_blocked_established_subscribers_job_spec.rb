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

  it "names the room and sender it reports to" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async).with("risk", "Blocked established subscribers", anything)
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

  # A block outlives the membership it broke: UnsubscribeAndFailWorker terminates ~5 days after the
  # failed renewal, so most reported entries name a subscription nobody can save by unblocking.
  # Measured on production: 56 of 114 qualifying entries were already terminated.
  describe "reachability of the reported subscriber" do
    it "says whether the membership is still alive, and leads with the ones that are" do
      dead = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription: dead, created_at: 20.days.ago)
      dead.update!(failed_at: 15.days.ago)
      live = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription: live, guid: "guid-live", buyer_email: "live@example.com", created_at: 10.days.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-live")

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("1 of them can still be saved")
        expect(message).to match(/subscription #{live.id}.*still renewing/)
        expect(message).to match(/subscription #{dead.id}.*membership already terminated/)
        expect(message.index("subscription #{live.id}")).to be < message.index("subscription #{dead.id}")
      end
    end

    it "marks a failure from the last day as new so the delta is readable" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, created_at: 2.hours.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("• NEW — subscription #{subscription.id}")
      end
    end

    it "does not mark an older failure as new" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, created_at: 8.days.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("• subscription #{subscription.id}")
        expect(message).not_to include("NEW —")
      end
    end
  end

  # The domain check reads four addresses; two of them had no coverage, so deleting either from the
  # lookup kept the suite green while silently dropping those subscribers.
  describe "the four domains the block check reads" do
    it "alerts on a blocked gifter domain" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      renewal = failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
      create(:gift, gifter_purchase: renewal, gifter_email: "sender@gifted-domain.com")
      renewal.update!(is_gift_sender_purchase: true)
      block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "gifted-domain.com")

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("subscription #{subscription.id}")
        expect(message).to include("blocked since #{block.blocked_at.to_date}")
      end
    end

    it "does not raise on an unparseable email address" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      renewal = failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
      renewal.update_column(:email, "not@an@address")

      expect { described_class.new.perform }.not_to raise_error
      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "skips a domain-blocked renewal with no usable address at all" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      renewal = failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
      renewal.update_column(:email, "")
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "example.com")

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end

    it "skips a guid-blocked renewal that carries no guid" do
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      renewal = failed_renewal(subscription:)
      renewal.update_column(:browser_guid, nil)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

      described_class.new.perform

      expect(InternalNotificationWorker).not_to have_received(:perform_async)
    end
  end

  # Both entries are live, so recency is the only thing that can order them — otherwise a passing
  # example proves nothing about the sort, only about the liveness tier.
  it "reports the newest failure first among equally reachable subscribers" do
    older = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: older, created_at: 9.days.ago)
    newer = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: newer, guid: "guid-newer", buyer_email: "newer@example.com", created_at: 2.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-newer")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect([older, newer].all? { |sub| sub.reload.alive? }).to be(true)
      expect(message.index("subscription #{newer.id}")).to be < message.index("subscription #{older.id}")
    end
  end

  # Recency must NOT outrank reachability: a fresh failure on a dead membership is not more
  # actionable than an older one that can still be saved.
  it "puts a saveable subscriber above a more recent one whose membership is gone" do
    dead = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: dead, created_at: 1.hour.ago)
    dead.update!(failed_at: 30.minutes.ago)
    live = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: live, guid: "guid-live", buyer_email: "live@example.com", created_at: 12.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-live")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message.index("subscription #{live.id}")).to be < message.index("subscription #{dead.id}")
    end
  end

  # The cap renders the top of the sorted list, so a saveable subscriber must not be dropped in
  # favour of terminated ones just because their failure is older.
  it "spends a limited report on the saveable subscribers first" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    2.times do |i|
      dead = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription: dead, guid: "guid-dead-#{i}", buyer_email: "dead#{i}@example.com",
                     created_at: (i + 1).minutes.ago)
      dead.update!(failed_at: 1.day.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-dead-#{i}")
    end
    live = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: live, guid: "guid-live", buyer_email: "live@example.com", created_at: 20.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-live")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{live.id}")
      expect(message).to include("…and 2 more.")
    end
  end

  it "ignores a blocked failure that is not a subscription renewal" do
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)
    create(:purchase, email:, browser_guid:, purchase_state: "failed",
                      error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports both truncations at once without contradicting itself" do
    stub_const("#{described_class}::MAX_SUBSCRIPTIONS_SCANNED", 2)
    stub_const("#{described_class}::MAX_REPORTED", 1)
    3.times do |i|
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, guid: "guid-#{i}", buyer_email: "buyer#{i}@example.com",
                     created_at: (i + 1).hours.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-#{i}")
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("At least 2 subscriptions with")
      expect(message).to include("The scan stopped at the newest 2 subscriptions")
      expect(message).to include("…and 1 more.")
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
