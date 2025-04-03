# frozen_string_literal: true

require "spec_helper"

describe CreateMissingPurchaseEventsWorker do
  let!(:purchase) do
    create(:purchase, created_at: 1.day.ago, ip_country: "United States", ip_state: "CA") do |purchase|
      purchase.seller.update!(timezone: "UTC")
    end
  end

  it "creates the missing event and regenerate cached analytics for that day" do
    described_class.new.perform

    expect(Event.first!.attributes.symbolize_keys).to include(
      event_name: "purchase",
      created_at: purchase.created_at,
      user_id: purchase.purchaser_id,
      link_id: purchase.link_id,
      purchase_id: purchase.id,
      ip_address: purchase.ip_address,
      referrer: purchase.referrer,
      referrer_domain: Referrer.extract_domain(purchase.referrer),
      price_cents: purchase.price_cents,
      card_type: purchase.card_type,
      card_visual: purchase.card_visual,
      purchase_state: purchase.purchase_state,
      billing_zip: purchase.zip_code,
      ip_country: purchase.ip_country,
      ip_state: purchase.ip_state,
      browser_guid: purchase.browser_guid,
      visit_id: Event.flag_mapping["visit_id"][:manufactured],
    )
    expect(RegenerateCreatorAnalyticsCacheWorker).to have_enqueued_sidekiq_job(purchase.seller_id, Date.yesterday.to_s)
  end

  it "does not create another event if it already exists" do
    create(:event, event_name: "purchase", link_id: purchase.link_id, purchase_id: purchase.id)

    described_class.new.perform

    expect(Event.count).to eq(1)
    expect(RegenerateCreatorAnalyticsCacheWorker.jobs.size).to eq(0)
  end
end
