# frozen_string_literal: true

class DefaultAbandonedCartWorkflowGeneratorService
  include Rails.application.routes.url_helpers

  def initialize(seller:)
    @seller = seller
  end

  def generate
    return if seller.workflows.abandoned_cart_type.exists?

    ActiveRecord::Base.transaction do
      workflow = seller.workflows.abandoned_cart_type.create!(name: "Abandoned cart")
      installment = workflow.installments.create!(
        name: "You left something in your cart",
        message: "<p>When you're ready to buy, <a href=\"#{checkout_url(host: DOMAIN)}\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">complete checking out</a>.</p><#{Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME} />",
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
