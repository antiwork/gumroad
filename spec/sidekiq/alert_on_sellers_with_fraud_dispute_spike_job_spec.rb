# frozen_string_literal: true

require "spec_helper"

describe AlertOnSellersWithFraudDisputeSpikeJob do
  def seller_with_signals(sales:, disputes:)
    seller = create(:user)
    product = create(:product, user: seller)
    purchases = Array.new(sales) { create(:purchase, link: product) }
    purchases.first(disputes).each do |purchase|
      create(:dispute, purchase:, seller:, reason: Dispute::REASON_FRAUDULENT, state: :formalized,
                       event_created_at: Time.current)
    end
    seller
  end

  def reported_message
    captured = nil
    allow(InternalNotificationWorker).to receive(:perform_async) { |_, _, body| captured = body }
    described_class.new.perform
    captured
  end

  before do
    allow(InternalNotificationWorker).to receive(:perform_async)
  end

  it "reports a seller drawing disputes in bulk to the risk room" do
    seller = seller_with_signals(sales: 30, disputes: 12)

    message = reported_message
    expect(message).to include(seller.email, "12 of 30 sales disputed or warned (40.0%)",
                               "12 disputes (12 fraudulent)", "0 early fraud warnings")
    expect(InternalNotificationWorker).to have_received(:perform_async)
      .with("risk", "Sellers drawing fraud disputes in bulk", anything)
  end

  it "says nothing when no seller qualifies" do
    seller_with_signals(sales: 30, disputes: 3)

    expect(reported_message).to be_nil
    expect(InternalNotificationWorker).not_to have_received(:perform_async)
  end

  it "says in the report that it changed nothing" do
    seller_with_signals(sales: 30, disputes: 12)

    expect(reported_message).to include("Nothing has been done to these accounts.")
  end

  it "is scheduled to run every day" do
    schedule = YAML.load_file(Rails.root.join("config", "sidekiq_schedule.yml"))
    entry = schedule.values.find { |job| job["class"] == described_class.name }

    expect(entry).to be_present
    expect(entry["cron"]).to eq("25 11 * * *")
    expect(entry["queue"]).to eq("low")
  end
end
