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
    failed_renewal(subscription:, created_at: described_class::LOOKBACK.ago - 1.hour)
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

  it "still reports when the block row has since been cleared, without inventing a date" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_CHARGES)
    failed_renewal(subscription:)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since unknown")
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
