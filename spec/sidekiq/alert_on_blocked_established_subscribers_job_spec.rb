# frozen_string_literal: true

require "spec_helper"

describe AlertOnBlockedEstablishedSubscribersJob do
  let(:browser_guid) { "guid-established" }
  let(:email) { "established@example.com" }

  # Builds a subscription with exactly `total` successful purchases against it. The membership
  # factory's own original purchase is successful and counts, so only the remainder are renewals.
  def subscription_with_history(total)
    membership = create(:membership_purchase)
    subscription = membership.subscription
    (total - 1).times do
      create(:purchase, link: subscription.link, subscription:,
                        is_original_subscription_purchase: false, purchase_state: "successful")
    end
    subscription
  end

  def failed_renewal(subscription:, guid: browser_guid, buyer_email: email, created_at: 1.hour.ago)
    create(:purchase, link: subscription.link, subscription:, is_original_subscription_purchase: false,
                      email: buyer_email, browser_guid: guid, created_at:,
                      purchase_state: "failed", error_code: PurchaseErrorCode::BLOCKED_BROWSER_GUID)
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "alerts on a subscriber with enough history, naming the date the block was written" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
    failed_renewal(subscription:)
    travel_to(3.years.ago) { PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid) }

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |room, _sender, message, _colour|
      expect(room).to eq("risk")
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("#{described_class::MIN_SUCCESSFUL_RENEWALS} successful renewals")
      expect(message).to include(3.years.ago.to_date.to_s)
    end
  end

  it "ignores a subscriber without enough successful renewals" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS - 1)
    failed_renewal(subscription:)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores renewals that failed for a reason other than a block" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
    create(:purchase, subscription:, is_original_subscription_purchase: false,
                      email:, browser_guid:, created_at: 1.hour.ago,
                      purchase_state: "failed", error_code: PurchaseErrorCode::CARD_DECLINED_FRAUDULENT)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "ignores a failure older than the lookback window" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
    failed_renewal(subscription:, created_at: described_class::LOOKBACK.ago - 1.hour)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "reports a one-off purchase's subscriber only once per subscription" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
    failed_renewal(subscription:, created_at: 2.hours.ago)
    failed_renewal(subscription:, created_at: 1.hour.ago)
    PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: browser_guid)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message, _colour|
      expect(message.scan("subscription #{subscription.id}").size).to eq(1)
      expect(message).to include("1 subscription with")
    end
  end

  it "still reports when the block row has since been cleared, without inventing a date" do
    subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
    failed_renewal(subscription:)

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message, _colour|
      expect(message).to include("subscription #{subscription.id}")
      expect(message).to include("blocked since unknown")
    end
  end

  it "caps the list and says how many were omitted" do
    stub_const("#{described_class}::MAX_REPORTED", 1)
    2.times do |i|
      subscription = subscription_with_history(described_class::MIN_SUCCESSFUL_RENEWALS)
      failed_renewal(subscription:, guid: "guid-#{i}", buyer_email: "buyer#{i}@example.com")
      PlatformBlock.add!(object_type: PlatformBlock::TYPES[:browser_guid], object_value: "guid-#{i}")
    end

    described_class.new.perform

    expect(InternalNotificationWorker).to have_received(:perform_async) do |_room, _sender, message, _colour|
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
end
