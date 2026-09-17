# frozen_string_literal: true

class DefaultAbandonedCartWorkflowGeneratorService
  include Rails.application.routes.url_helpers

  WORKFLOW_NAME = "Abandoned cart email"
  DEFAULT_NAME = "You left something in your cart"
  DELAY_HOURS = InstallmentRule::ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS / 1.hour

  def self.default_message(checkout_url:)
    "<p>When you're ready to buy, <a href=\"#{checkout_url}\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">complete checking out</a>.</p><#{Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME} />"
  end

  def initialize(seller:)
    @seller = seller
  end

  def generate
    return if seller.workflows.abandoned_cart_type.exists?

    ActiveRecord::Base.transaction do
      workflow = seller.workflows.abandoned_cart_type.create!(name: WORKFLOW_NAME)
      installment = workflow.installments.create!(
        name: DEFAULT_NAME,
        message: self.class.default_message(checkout_url: checkout_url(host: DOMAIN)),
        installment_type: workflow.workflow_type,
        json_data: workflow.json_data,
        seller_id: workflow.seller_id,
        send_emails: true,
      )
      installment.create_installment_rule!(time_period: InstallmentRule::HOUR, delayed_delivery_time: InstallmentRule::ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS)

      workflow.publish!
    end
  end

  private
    attr_reader :seller
end
