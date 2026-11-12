# frozen_string_literal: true

module MetaConversions
  # Every gate the sender re-checks at send time. Returns the first gate that fails as a symbol, or
  # nil when a purchase may be sent.
  module Eligibility
    SEND_WINDOW = 7.days

    # The EEA, the UK and Switzerland. Country names arrive from the purchase row, so they are
    # compared by their ISO code.
    RESTRICTED_COUNTRY_CODES = (
      Compliance::Countries::EU_VAT_APPLICABLE_COUNTRY_CODES + %w[IS LI NO CH GB]
    ).to_set.freeze

    module_function

    def seller_skip_reason(seller)
      return unless seller

      return :flag_off unless Feature.active?(:meta_conversions_api, seller)
      return :no_pixel_id if seller.facebook_pixel_id.blank?
      return :third_party_analytics_disabled if seller.disable_third_party_analytics?

      setting = seller.meta_conversions_setting
      return :no_token if setting.blank?
      return :token_rejected if setting.token_rejected_at.present?

      nil
    end

    def purchase_skip_reason(purchase, context)
      return :no_context if context.blank?
      return :free_sale_analytics_disabled if purchase.free_purchase? && purchase.seller.skip_free_sale_analytics?
      return :test_purchase if purchase.is_test_purchase?
      return :recurring_subscription_charge if purchase.is_recurring_subscription_charge
      return :bundle_product_purchase if purchase.is_bundle_product_purchase
      return :gift_receiver_purchase if purchase.is_gift_receiver_purchase
      return :no_ip_country if purchase.ip_country.blank?
      return :restricted_country if restricted_country?(purchase.ip_country) || restricted_country?(purchase.country)
      return :outside_send_window if purchase.succeeded_at.blank? || purchase.succeeded_at < SEND_WINDOW.ago

      nil
    end

    def restricted_country?(country_name)
      code = Compliance::Countries.find_by_name(country_name)&.alpha2
      code.present? && RESTRICTED_COUNTRY_CODES.include?(code)
    end
  end
end
