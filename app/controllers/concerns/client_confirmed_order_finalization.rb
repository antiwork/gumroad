# frozen_string_literal: true

module ClientConfirmedOrderFinalization
  extend ActiveSupport::Concern
  include Events

  private
    def finalize_client_confirmed_order(order)
      service = Order::FinalizeConfirmedChargeService.new(order:)
      responses = service.perform

      record_purchase_events(order)
      attribute_utm_link_sale(order, cookies[:_gumroad_guid])

      [responses, service.charge_intent]
    end

    def attribute_utm_link_sale(order, browser_guid)
      return unless order.persisted? && order.purchases.successful.any? && UtmLinkVisit.where(browser_guid:).any?
      UtmLinkSaleAttributionJob.perform_async(order.id, browser_guid)
    end

    def create_purchase_event_and_recommendation_info(purchase)
      create_purchase_event(purchase)
      purchase.handle_recommended_purchase if purchase.was_product_recommended
    end

    # Idempotent: each successful purchase gets one event, whether finalized in #prepare or #finalize.
    def record_purchase_events(order)
      order.purchases.each do |purchase|
        next unless purchase.successful?
        next if Event.purchase.exists?(purchase_id: purchase.id)
        create_purchase_event_and_recommendation_info(purchase)
      end
    end
end
