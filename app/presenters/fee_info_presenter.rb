# frozen_string_literal: true

class FeeInfoPresenter
  SUMMARY = "Your fees depend on how buyers find your product:"

  attr_reader :seller, :country_code

  def initialize(seller:, country_code:)
    @seller = seller
    @country_code = country_code
  end

  # Payout method does not change how a sale is charged: every sale on Gumroad's merchant account pays the same processor fee.
  def merchant_account_fee_info
    processor_fee = "#{format_percent(Purchase::PROCESSOR_FEE_PER_THOUSAND)}% + #{Purchase::PROCESSOR_FIXED_FEE_CENTS}¢ processing fee"
    breakdown(
      direct_sales: "#{gumroad_fee} Gumroad fee + #{processor_fee}",
      discover_sales: "#{discover_fee}, processing fee included",
    )
  end

  def connect_account_fee_info
    return { summary: "You pay a 0% Gumroad fee on all sales.", items: [] } if country_code == Compliance::Countries::BRA.alpha2

    breakdown(direct_sales: "#{gumroad_fee} Gumroad fee", discover_sales: "#{discover_fee} Gumroad fee")
  end

  private
    def breakdown(direct_sales:, discover_sales:)
      {
        summary: SUMMARY,
        items: [
          { label: "Direct sales", value: direct_sales },
          { label: "Discover sales", value: discover_sales },
        ],
      }
    end

    def gumroad_fee
      @gumroad_fee ||= "#{format_percent(seller.gumroad_fee_per_thousand)}% + #{Purchase::GUMROAD_FIXED_FEE_CENTS}¢"
    end

    def discover_fee
      "#{format_percent(Purchase::GUMROAD_DISCOVER_FEE_PER_THOUSAND)}%"
    end

    def format_percent(per_thousand)
      percent = (per_thousand / 10.0).round(1)
      percent.to_i == percent ? percent.to_i : percent
    end
end
