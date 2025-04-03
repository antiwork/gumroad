# frozen_string_literal: true

module RecurringService::Tiers
  include ActionView::Helpers::NumberHelper

  def monthly_tier_amount(customer_count)
    case customer_count
    when 0..999
      10
    when 1000..1999
      25
    when 2000..4999
      50
    when 5000..9999
      75
    when 10_000..14_999
      100
    when 15_000..24_999
      150
    when 25_000..49_999
      200
    else
      250
    end
  end

  def monthly_tier_amount_cents(customer_count)
    monthly_tier_amount(customer_count) * 100
  end
end
