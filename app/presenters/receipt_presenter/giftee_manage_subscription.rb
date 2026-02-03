# frozen_string_literal: true

class ReceiptPresenter::GifteeManageSubscription
  include ActionView::Helpers::UrlHelper
  include BasePrice::Recurrence

  def initialize(chargeable)
    @chargeable = chargeable
  end

  def note
    @_note ||= begin
      return unless gifted_subscription?

      subscription = chargeable.gift_received.gifter_purchase.subscription
      return unless subscription.present?

      url = Rails.application.routes.url_helpers.manage_subscription_url(
        subscription.external_id,
        { host: UrlService.domain_with_protocol },
      )

      "Your gift includes a #{single_period_indicator(subscription.recurrence)} membership. If you wish to continue your membership, you can visit #{link_to("subscription settings", url, target: "_blank")}.".html_safe
    end
  end

  private
    attr_reader :chargeable

    def gifted_subscription?
      chargeable.is_a?(Purchase) && chargeable.is_gift_receiver_purchase && chargeable.link.is_recurring_billing
    end
end
