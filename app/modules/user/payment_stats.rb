# frozen_string_literal: true

# Mixin contains stats helpers for use on Users, relevant to the internal payments team at Gumroad.
# The numbers in this stats module should unlikely be displayed to the Creator. For example, most
# stats within relate to transaction total values and not the values received or earned by Creators.
#
# See the User::Stats module for analytics and other stats that might be displayed to the Creator.
module User::PaymentStats
  # Public: Calculates the average sale price the user has had over the last year.
  # If there have been no sales, zero is returned.
  def average_transaction_amount_cents
    sales_in_last_year = sales.non_free.where(created_at: 1.year.ago..Time.current)
    average = sales_in_last_year.average(:price_cents)
    (average || 0).to_i
  end

  # Public: The transaction volume processed for the user in the last year.
  def transaction_volume_in_the_last_year
    transaction_volume_since(1.year.ago)
  end

  # Public: The transaction volume processed for the user since the time given.
  def transaction_volume_since(since)
    sales.paid.where("purchases.created_at > ?", since).sum(:price_cents)
  end

  # Public: Calculates the projected annual transaction volume.
  # This will be the same as volume made over the last year, unless the Creator has not been
  # active for the last year, then it will be guestimated for the period starting at their
  # first transaction.
  def projected_annual_transaction_volume
    first_sale = sales.successful.non_free.first
    return 0 if first_sale.nil?

    period_selling_seconds = Time.current - first_sale.created_at
    volume_period_seconds = [period_selling_seconds, 1.year].min
    (transaction_volume_in_the_last_year * 1.year / volume_period_seconds).to_i
  end

  def max_payment_amount_cents
    payments.order(amount_cents: :desc).first.try(:amount_cents) || 0
  end
end
