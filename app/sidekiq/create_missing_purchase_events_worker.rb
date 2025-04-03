# frozen_string_literal: true

class CreateMissingPurchaseEventsWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low

  def perform(date = Date.yesterday)
    purchases = Purchase.successful.left_joins(:events).
      where("purchases.created_at >= ? and purchases.created_at < ?", date, date.tomorrow).
      where("purchases.preorder_id is null and events.id is null")

    analytics_days_to_regenerate = Set.new
    purchases.find_each do |purchase|
      Event.create!(
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
        manufactured: true,
      )
      analytics_days_to_regenerate << [purchase.seller_id, purchase.created_at.in_time_zone(purchase.seller.timezone).to_date.to_s]
    end

    analytics_days_to_regenerate.each do |(seller_id, date_string)|
      RegenerateCreatorAnalyticsCacheWorker.perform_async(seller_id, date_string)
    end
  end
end
