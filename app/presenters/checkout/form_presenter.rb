# frozen_string_literal: true

class Checkout::FormPresenter
  include CheckoutDashboardHelper

  attr_reader :pundit_user

  def initialize(pundit_user:)
    @pundit_user = pundit_user
  end

  def form_props
    seller = pundit_user.seller
    products = seller.products.visible.order(created_at: :desc).to_a
    cart_product = products.first
    {
      pages:,
      user: {
        display_offer_code_field: seller.display_offer_code_field?,
        recommendation_type: seller.recommendation_type,
        tipping_enabled: seller.tipping_enabled?,
        ach_payments_enabled: seller.ach_payments_enabled?,
        gifting_disabled: seller.gifting_disabled?,
      },
      cart_item: cart_product.present? ? CheckoutPresenter.new(logged_in_user: nil, ip: nil).checkout_product(cart_product, cart_product.cart_item({}), {}).merge({ quantity: 1, url_parameters: {}, referrer: "" }) : nil,
      custom_fields: seller.custom_fields.not_is_post_purchase.map(&:as_json),
      card_product: cart_product.present? ? ProductPresenter.card_for_web(product: cart_product) : nil,
      products: products.map { |product| { id: product.external_id, name: product.name, archived: product.archived? } },
      paypal_connect:,
      connect_account_fee_info_text:,
    }
  end

  private
    def paypal_connect
      seller = pundit_user.seller
      show_paypal_connect = Pundit.policy!(pundit_user, [:settings, :payments, seller]).paypal_connect? && seller.paypal_connect_enabled?
      paypal_merchant_account = seller.merchant_accounts.alive.paypal.first

      # The merchant email is optional display data fetched live from PayPal. Only
      # fetch it when the section will actually render, and never let a PayPal API
      # failure take down the whole Checkout settings page — worst case the email
      # is simply omitted from the connected-account card.
      if show_paypal_connect && paypal_merchant_account
        begin
          payment_integration_api = PaypalIntegrationRestApi.new(seller, authorization_header: PaypalPartnerRestCredentials.new.auth_token)
          merchant_account_response = payment_integration_api.get_merchant_account_by_merchant_id(paypal_merchant_account.charge_processor_merchant_id)
          paypal_merchant_account_email = merchant_account_response.parsed_response.try(:[], "primary_email")
        rescue => e
          Rails.logger.error("Checkout::FormPresenter PayPal merchant account fetch failed for seller #{seller.id}: #{e.class}: #{e.message}")
          ErrorNotifier.notify(e)
        end
      end

      {
        show_paypal_connect:,
        allow_paypal_connect: seller.paypal_connect_allowed?,
        unsupported_countries: PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.map { |code| ISO3166::Country[code].common_name },
        email: paypal_merchant_account_email,
        charge_processor_merchant_id: paypal_merchant_account&.charge_processor_merchant_id,
        charge_processor_verified: paypal_merchant_account.present? && paypal_merchant_account.charge_processor_verified?,
        needs_email_confirmation: paypal_merchant_account.present? && paypal_merchant_account.meta.present? && paypal_merchant_account.meta["isEmailConfirmed"] == "false",
        paypal_disconnect_allowed: seller.paypal_disconnect_allowed?,
      }
    end

    def connect_account_fee_info_text
      seller = pundit_user.seller
      if seller.alive_user_compliance_info&.country_code == Compliance::Countries::BRA.alpha2
        "All sales will incur a 0% Gumroad fee."
      else
        discover_fee_percent = (Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND / 10.0).round(1)
        discover_fee_percent = discover_fee_percent.to_i == discover_fee_percent ? discover_fee_percent.to_i : discover_fee_percent
        direct_fee_percent = ((seller.custom_fee_per_thousand.presence || Purchase::GUMROAD_FLAT_FEE_PER_THOUSAND) / 10.0).round(1)
        direct_fee_percent = direct_fee_percent.to_i == direct_fee_percent ? direct_fee_percent.to_i : direct_fee_percent
        fixed_fee_cents = Purchase::GUMROAD_FIXED_FEE_CENTS

        "All sales will incur fees based on how customers find your product:\n\n• Direct sales: #{direct_fee_percent}% + #{fixed_fee_cents}¢\n• Discover sales: #{discover_fee_percent}% flat\n"
      end
    end
end
