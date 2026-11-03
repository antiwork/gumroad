# frozen_string_literal: true

# Public listing data for a partner application's product feed.
#
# PUBLIC fields only, built from the same card Discover and profile pages render: no files,
# no post-purchase content and no sales or revenue numbers. `as_json_for_api` is not safe here.
class PartnerProductPresenter
  include ActionView::Helpers::OutputSafetyHelper
  include CurrencyHelper

  def initialize(product:, partner_seller:)
    @product = product
    @partner_seller = partner_seller
  end

  def props
    card_props = ProductPresenter.card_for_web(product:, show_seller: false, compute_description: false, compute_inventory: false)

    {
      id: product.external_id,
      permalink: product.general_permalink,
      name: product.name,
      native_type: product.native_type,
      url: product.long_url,
      thumbnail_url: card_props[:thumbnail_url],
      price_cents: card_props[:price_cents],
      currency_code: card_props[:currency_code],
      price_formatted: product_card_formatted_price(
        price: card_props[:price_cents],
        currency_code: card_props[:currency_code],
        is_pay_what_you_want: card_props[:is_pay_what_you_want],
        recurrence: card_props[:recurrence],
        duration_in_months: card_props[:duration_in_months],
      ).to_s,
      is_pay_what_you_want: card_props[:is_pay_what_you_want],
      is_recurring_billing: product.is_recurring_billing,
      ratings: card_props[:ratings],
      rated_as_adult: product.rated_as_adult?,
      creator: PartnerSellerPresenter.new(partner_seller:).props,
    }
  end

  private
    attr_reader :product, :partner_seller
end
