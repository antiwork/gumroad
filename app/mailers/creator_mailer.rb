# frozen_string_literal: true

class CreatorMailer < ApplicationMailer
  helper MailerHelper
  helper ApplicationHelper
  helper CurrencyHelper
  layout "layouts/email"

  def gumroad_day_fee_saved(seller_id:, to_email: nil)
    @announcement = true

    seller = User.find(seller_id)
    email = to_email.presence || seller.email

    @fee_saved_amount = seller.gumroad_day_saved_fee_amount
    return unless @fee_saved_amount.present?

    mail to: email, subject: "You saved #{@fee_saved_amount} in fees on Gumroad Day!"
  end

  def year_in_review(seller:, year:, analytics_data:, payout_csv_url: nil, recipient: nil)
    @seller = seller
    @year = year
    @analytics_data = analytics_data
    @payout_csv_url = payout_csv_url
    email = recipient.presence || seller.email

    mail to: email, subject: "Your #{year} in review"
  end

  def bundles_marketing(seller_id:, bundles: [])
    seller = User.find(seller_id)
    @currency_type = seller.currency_type
    @bundles = bundles
    mail to: seller.form_email, subject: "Join top creators who have sold over $300,000 of bundles"
  end
end
