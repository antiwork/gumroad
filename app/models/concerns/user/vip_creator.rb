# frozen_string_literal: true

module User::VipCreator
  extend ActiveSupport::Concern

  def vip_creator?
    recent_gross_sales_cents > 5_000_00
  end

  private
    def recent_gross_sales_cents
      search_params = {
        seller: self,
        state: Purchase::CHARGED_SUCCESS_STATES,
        exclude_giftees: true,
        exclude_refunded: true,
        exclude_unreversed_chargedback: true,
        exclude_bundle_product_purchases: true,
        exclude_commission_completion_purchases: true,
        created_after: 30.days.ago,
        aggs: { price_cents_total: { sum: { field: "price_cents" } } },
        size: 0
      }
      result = PurchaseSearchService.search(search_params)
      result.aggregations.price_cents_total.value
    end
end
