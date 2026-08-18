# frozen_string_literal: true

require "spec_helper"

describe AlertOnBlockedEstablishedSubscribersJob do
  let(:browser_guid) { "guid-established" }
  let(:email) { "established@example.com" }

  # A subscription's successful history predates the renewal that failed, which is the only shape
  # the report is about. Leaving these at Time.current would put a successful renewal after every
  # failure and read as recovery.
  let(:history_starts_at) { 6.months.ago }

  # Builds a subscription with exactly `total` successful purchases against it. The membership
  # factory's own original purchase is successful and counts, so only the remainder are renewals.
  def subscription_with_history(total)
    subscription = create(:membership_purchase).subscription
    (total - 1).times do |index|
      successful_renewal(subscription:, created_at: history_starts_at + index.days)
    end
    subscription
  end

  def successful_renewal(subscription:, created_at:)
    create(:purchase, link: subscription.link, subscription:,
                      is_original_subscription_purchase: false, purchase_state: "successful",
                      created_at:)
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
      expect(room).to eq("agent_reports")
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

    expect(InternalNotificationWorker).to have_received(:perform_async).with("agent_reports", "Blocked established subscribers", anything)
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

  # Enforcement short-circuits on the first blocked domain of the four it reads, so when two of a
  # subscriber's domains are blocked the report has to name that row and not simply the oldest one
  # — dating a renewal from a block that did not stop it sends cleanup at the wrong row.
  it "dates the block on the domain enforcement stopped at, not the oldest blocked domain" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    purchaser = create(:user, email: "member@account-domain.com")
    renewal = failed_renewal(subscription:, buyer_email: "member@purchase-domain.com",
                             error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    renewal.update!(purchaser:)

    declining_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "purchase-domain.com")
    older_block = travel_to(3.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "account-domain.com")
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{declining_block.blocked_at.to_date}")
      expect(message).not_to include("blocked since #{older_block.blocked_at.to_date}")
    end
  end

  # The guid check does NOT scope to its own type: check_for_past_blocked_guids calls
  # #past_blocked_object, which matches object_value alone. A row of another type carrying the guid
  # string is therefore what declined this renewal, and a type-scoped lookup here would find no
  # active block and drop the subscriber from the report entirely.
  it "finds the guid block when the row carrying the value is stored under another type" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # The domain half is the asymmetry's other side: blocked_by_email_domain? runs through
  # AttributeBlockable, which does scope to :email_domain, so a row of another type carrying the
  # domain string declines nothing and must not be reported as the block.
  it "does not treat another block type carrying the domain value as the domain block" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email], object_value: "example.com")

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # object_value collates case-insensitively, so a row stored in another casing is enforcing in
  # production and has to be found here too — a case-sensitive lookup would drop the subscriber
  # rather than merely lose the date. The casing can differ on either side: block rows are stored
  # verbatim, and User#email is not downcased on write the way Purchase#email is.
  it "finds a domain block stored in a different casing" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "Example.COM")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  it "finds a guid block stored in a different casing" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, guid: "guid-mixed-case")
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "GUID-Mixed-Case")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  # The mirror of the two above, pinning the lookup side rather than the stored side: the value read
  # off the purchase is what carries the casing here. Purchase#email is downcased on write, so the
  # domain that can arrive mixed-case is the purchaser's — User#email has no such callback.
  it "finds a domain block when the purchaser's account domain is the mixed-case side" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    purchaser = create(:user, email: "member@Account-Domain.com")
    renewal = failed_renewal(subscription:, buyer_email: "member@purchase-domain.com",
                             error_code: PurchaseErrorCode::BLOCKED_EMAIL_DOMAIN)
    renewal.update!(purchaser:)
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:email_domain], object_value: "account-domain.com")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since #{block.blocked_at.to_date}")
    end
  end

  it "finds a guid block when the purchase's guid is the mixed-case side" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, guid: "GUID-Mixed-Case")
    block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-mixed-case")

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

  # Eligibility is "stranded now", not "was ever blocked".
  it "ignores a subscription that renewed successfully after its blocked failure" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, created_at: 20.days.ago)
    successful_renewal(subscription:, created_at: 10.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "still reports a subscription whose successful renewal predates the blocked failure" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    successful_renewal(subscription:, created_at: 20.days.ago)
    failed_renewal(subscription:, created_at: 10.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
    end
  end

  # An upgrade charge settles the overdue period, so the subscriber is not stranded when the report
  # runs. Pinned because it is a judgment call, not an oversight: the upgrade carries a live
  # browser_guid, so a guid-blocked subscriber who self-rescues this way is only reported again
  # after their next renewal fails.
  it "treats a successful upgrade charge as recovery" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, created_at: 20.days.ago)
    create(:purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false,
                      is_upgrade_purchase: true, purchase_state: "successful", created_at: 10.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # created_at is second-precision, so an import can land both rows in the same second. An
  # ambiguous ordering should produce a human-reviewed report entry, not a silent drop.
  it "reports a subscription whose successful renewal shares a timestamp with the blocked failure" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_at = 10.days.ago.change(usec: 0)
    failed_renewal(subscription:, created_at: failed_at)
    successful_renewal(subscription:, created_at: failed_at)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
    end
  end

  # A gifted membership's opening purchase is not a renewal, so it is not evidence that renewals
  # are getting through — the same predicate the failure side uses has to apply here too.
  it "does not treat a later gift-receiver purchase as a recovered renewal" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:, created_at: 20.days.ago)
    create(:purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false,
                      is_gift_receiver_purchase: true, purchase_state: "successful", created_at: 10.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
    end
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

  # The report says a subscriber is blocked from RENEWING, so the failure it describes has to be a
  # renewal. An original subscription purchase carries a subscription_id and still runs the fraud
  # checks, and a plan change is the everyday way a long-tenured member acquires one — reporting it
  # would tell risk a member cannot renew when their renewals are fine.
  it "ignores a blocked purchase that is not a renewal" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    plan_change = failed_renewal(subscription:)
    # The row a blocked plan change leaves behind: non-recurring, but carrying a subscription_id and
    # a block code. Written directly because building it with the flag set sends the purchase down a
    # different validation path that replaces error_code, so the block code never lands.
    plan_change.update_columns(
      flags: plan_change.flags | Purchase.flag_mapping["flags"][:is_original_subscription_purchase])
    expect(plan_change.reload.is_recurring_subscription_charge).to be(false)
    expect(plan_change.error_code).to eq(PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # `recurring_charge` excludes the original purchase but not the gift-receiver one, and that row is
  # the opening purchase of a gifted membership rather than a renewal — Subscription counts it
  # alongside the original, and Purchase#is_recurring_subscription_charge excludes both.
  it "ignores a blocked gift-receiver purchase, which opens a membership rather than renewing one" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    giftee_purchase = failed_renewal(subscription:)
    giftee_purchase.update_columns(
      flags: giftee_purchase.flags | Purchase.flag_mapping["flags"][:is_gift_receiver_purchase])
    expect(giftee_purchase.reload.is_recurring_subscription_charge).to be(false)
    expect(giftee_purchase.error_code).to eq(PurchaseErrorCode::BLOCKED_BROWSER_GUID)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  # Row ids are not a clock. A backfill, an import or a retry that preserves timestamps can leave an
  # older failure holding the higher id, and picking by MAX(id) then quoted that older row's guid,
  # block date and "last tried" date while the message claimed to describe the newest renewal.
  it "describes the newest failed renewal even when an older one has a higher id" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    newest = failed_renewal(subscription:, guid: "guid-newest", created_at: 1.hour.ago)
    older = failed_renewal(subscription:, guid: "guid-older", created_at: 10.days.ago)
    # The import case, made explicit: the older renewal was written last, so it holds the higher id.
    expect(older.id).to be > newest.id

    newest_block = PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-newest")
    older_block = travel_to(3.years.ago) do
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-older")
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("blocked since #{newest_block.blocked_at.to_date}")
      expect(message).to include("last tried #{newest.created_at.to_date}")
      expect(message).not_to include("blocked since #{older_block.blocked_at.to_date}")
      expect(message).not_to include("last tried #{older.created_at.to_date}")
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
      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
      2.times { |i| blocked_established_subscriber(i) }

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("At least 1 subscription with")
        expect(message).to include("The scan stopped at 1 subscriptions with a blocked renewal")
      end
    end

    # The bound used to be spent on failure rows, so one subscriber's retries could consume it and
    # hide everybody behind them. Counting subscriptions is what makes it mean what it says.
    it "does not let one subscriber's repeated failures consume the cap" do
      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 2)
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
      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
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

    # The bulk-block regression this bound exists for is what fills the newest pages with one- and
    # two-charge subscribers, so the walk has to keep going through batches that yield nothing.
    it "reports an established subscriber sitting behind a page of newcomers" do
      stub_const("#{described_class}::CHARGE_COUNT_BATCH", 1)
      3.times do |i|
        newcomer = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES - 1)
        failed_renewal(subscription: newcomer, guid: "new-#{i}", buyer_email: "new#{i}@example.com",
                       created_at: (i + 1).minutes.ago)
        PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "new-#{i}")
      end
      established = blocked_established_subscriber(9)

      described_class.new.perform

      expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
        expect(message).to include("subscription #{established.id}")
      end
    end

    it "does not claim truncation when the window held exactly the cap" do
      stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 1)
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
    stub_const("#{described_class}::MAX_CANDIDATES_SCANNED", 2)
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
      expect(message).to include("The scan stopped at 2 subscriptions with a blocked renewal")
      expect(message).to include("…and 1 more.")
    end
  end

  # A subscriber whose block is already gone is not reportable at all, so letting one hold a line of
  # a limited report would hide a subscriber who IS still stranded. The unblocked subscription has
  # the newer failure, which is what would otherwise win the slot.
  it "does not let a subscriber whose block was cleared take a line of the report" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    unblocked = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: unblocked, guid: "guid-unblocked",
                   buyer_email: "unblocked@example.com", created_at: 1.hour.ago)

    still_blocked = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: still_blocked, guid: "guid-still-blocked",
                   buyer_email: "still-blocked@example.com", created_at: 5.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-still-blocked")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{still_blocked.id}")
      expect(message).not_to include("subscription #{unblocked.id}")
    end
  end

  # latest_block_failures returns rows keyed by id rather than by recency, so a report that sliced
  # the raw accumulator would keep an arbitrary subset. The OLDER failure is created first so it
  # holds the lower id: without the sort it wins the only line on id order.
  it "keeps the newest stranded subscriber when the report has one line" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    older = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: older, guid: "guid-older",
                   buyer_email: "older@example.com", created_at: 20.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-older")

    newer = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: newer, guid: "guid-newer",
                   buyer_email: "newer@example.com", created_at: 1.hour.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-newer")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{newer.id}")
      expect(message).not_to include("subscription #{older.id}")
    end
  end

  # Recency alone is not the report's ranking: message_for prints still-renewing subscribers first,
  # because those are the only ones unblocking can still save. A report that ranks by recency only
  # spends its last line on a newer subscriber whose membership is already terminated and
  # drop the older one who is still saveable — the row the alert exists to surface.
  it "keeps the subscriber who can still be saved over a newer one already terminated" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    live = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: live, guid: "guid-live",
                   buyer_email: "live@example.com", created_at: 20.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-live")

    dead = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: dead, guid: "guid-dead",
                   buyer_email: "dead@example.com", created_at: 1.hour.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-dead")
    dead.update!(failed_at: 1.minute.ago)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{live.id}")
      expect(message).not_to include("subscription #{dead.id}")
    end
  end

  # The live-first ranking has to hold across the whole window, not within whatever the scan reached
  # first. Candidates arrive newest-failure-first, so terminated memberships with fresher failures
  # occupy the leading batches; a scan that stopped once it had enough rows ranked only those and
  # never saw the older membership that is still renewing — the one row unblocking can still save.
  # The row budget this example guards against is gone, so the stub below is inert here on purpose:
  # it is what makes the example red on any tree that still stops the walk at that budget, instead
  # of silently passing because three rows never reach a bound of two thousand.
  it "keeps a saveable subscriber sitting behind whole batches of newer terminated ones" do
    stub_const("#{described_class}::MAX_ESTABLISHED_FOUND", 1)
    stub_const("#{described_class}::MAX_REPORTED", 1)
    stub_const("#{described_class}::CHARGE_COUNT_BATCH", 1)
    dead = 2.times.map do |i|
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
      failed_renewal(subscription:, guid: "guid-dead-#{i}", buyer_email: "dead#{i}@example.com",
                     created_at: (i + 1).hours.ago)
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-dead-#{i}")
      subscription.update!(failed_at: 1.minute.ago)
      subscription
    end

    live = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription: live, guid: "guid-live", buyer_email: "live@example.com",
                   created_at: 20.days.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-live")

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{live.id}")
      dead.each { |subscription| expect(message).not_to include("subscription #{subscription.id}") }
      expect(message).to include("…and 2 more.")
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
    mail = InternalNotificationMailer.notify(room_name: "agent_reports", sender: "spec", message_text: "hello")

    expect(mail.to).to be_present
  end
end
