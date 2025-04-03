# frozen_string_literal: true

class PaypalIntegrationRestApi
  include HTTParty

  base_uri PAYPAL_REST_ENDPOINT

  attr_reader :merchant, :response, :options

  def initialize(merchant, options = {})
    @merchant = merchant
    @options  = options
  end

  # Create a partner (Gumroad) referral for the given merchant which pre-fills the data when that merchant signs up for
  # a PayPal account.
  def create_partner_referral(return_url)
    self.class.post("/v2/customer/partner-referrals",
                    headers: partner_referral_headers,
                    body: partner_referral_data(return_url).to_json)
  end

  # Get status of merchant account from PayPal using merchant account id.
  def get_merchant_account_by_merchant_id(paypal_merchant_id)
    self.class.get("/v1/customer/partners/#{PAYPAL_PARTNER_ID}/merchant-integrations/#{paypal_merchant_id}",
                   headers: partner_referral_headers)
  end

  private
    def timestamp
      Time.current.to_i.to_s
    end

    def partner_referral_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => options[:authorization_header]
      }
    end

    def partner_referral_data(return_url)
      {
        tracking_id: merchant.external_id + "-" + timestamp,
        email: merchant.email,
        partner_config_override: {
          return_url:,
          partner_logo_url: GUMROAD_LOGO_URL
        },
        operations: [
          {
            operation: "API_INTEGRATION",
            api_integration_preference: {
              rest_api_integration: {
                integration_method: "PAYPAL",
                integration_type: "THIRD_PARTY",
                third_party_details: {
                  features: %w(PAYMENT REFUND PARTNER_FEE DELAY_FUNDS_DISBURSEMENT ACCESS_MERCHANT_INFORMATION READ_SELLER_DISPUTE)
                }
              }
            }
          }
        ],
        products: [
          "EXPRESS_CHECKOUT"
        ],
        legal_consents: [
          {
            type: "SHARE_DATA_CONSENT",
            granted: true
          }
        ]
      }
    end
end
