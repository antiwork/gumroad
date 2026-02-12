# frozen_string_literal: true

class Subscriptions::MagicLinkPresenter
  def initialize(subscription:)
    @subscription = subscription
  end

  def magic_link_props
    unique_emails = @subscription.emails.map do |source, email|
      { email: EmailRedactorService.redact(email), source: } unless email.nil?
    end.compact.uniq { |email| email[:email] }

    {
      subscription_id: @subscription.external_id,
      is_installment_plan: @subscription.is_installment_plan,
      user_emails: unique_emails,
      product_name: @subscription.link.name
    }
  end
end
