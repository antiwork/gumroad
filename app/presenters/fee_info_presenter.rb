# frozen_string_literal: true

class FeeInfoPresenter
  SUMMARY = "All sales will incur fees based on how customers find your product:"

  attr_reader :seller, :country_code

  def initialize(seller:, country_code:)
    @seller = seller
    @country_code = country_code
  end

  def card_fee_info
    processor_fee_info("credit card fee")
  end

  def paypal_fee_info
    processor_fee_info("PayPal fee")
  end

  def connect_account_fee_info
    return { summary: "All sales will incur a 0% Gumroad fee.", items: [] } if country_code == Compliance::Countries::BRA.alpha2

    breakdown(direct_sales: gumroad_fee)
  end

  private
    def processor_fee_info(processor_fee_name)
      processor_fee = "#{format_percent(Purchase::PROCESSOR_FEE_PER_THOUSAND)}% + #{Purchase::PROCESSOR_FIXED_FEE_CENTS}¢ #{processor_fee_name}"
      breakdown(direct_sales: "#{gumroad_fee} Gumroad fee + #{processor_fee}")
    end

    def breakdown(direct_sales:)
      {
        summary: SUMMARY,
        items: [
          { label: "Direct sales", value: direct_sales },
          { label: "Discover sales", value: "#{format_percent(Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND)}% flat" },
        ],
      }
    end

    def gumroad_fee
      @gumroad_fee ||= "#{format_percent(seller.gumroad_fee_per_thousand)}% + #{Purchase::GUMROAD_FIXED_FEE_CENTS}¢"
    end

    def format_percent(per_thousand)
      percent = (per_thousand / 10.0).round(1)
      percent.to_i == percent ? percent.to_i : percent
    end
end
