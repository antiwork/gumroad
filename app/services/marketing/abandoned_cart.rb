# frozen_string_literal: true

class Marketing::AbandonedCart
  def initialize(product:, seller:)
    @product = product
    @seller = seller
  end

  def available? = seller.eligible_for_abandoned_cart_workflows?
  def enabled? = covering_workflows.any?(&:published_at)

  def state
    workflow = covering_workflow
    email = workflow&.installments&.alive&.first
    {
      available: available?,
      blocked_reason:,
      enabled: enabled?,
      can_toggle: can_toggle?,
      subject: email&.subject || DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME,
      message: can_toggle? ? preview_message(workflow, email) : nil,
      delay_hours: DefaultAbandonedCartWorkflowGeneratorService::DELAY_HOURS,
      workflows: covering_workflows.map do |record|
        {
          name: record.name,
          url: Rails.application.routes.url_helpers.workflow_emails_path(record.external_id),
          scope: workflow_scope(record),
          enabled: record.published_at.present?,
        }
      end,
    }
  end

  def enable
    return :blocked unless available?

    # The lookup and creation share a lock so concurrent requests cannot create duplicate reminders.
    product.with_lock do
      @covering_workflows = nil
      return :blocked unless can_toggle?

      workflow = covering_workflow || create_workflow
      workflow.publish!
      @covering_workflows = nil
      workflow
    end
  end

  def pause
    product.with_lock do
      @covering_workflows = nil
      return :blocked unless can_toggle?

      workflow = covering_workflow
      workflow&.unpublish!
      @covering_workflows = nil
      workflow
    end
  end

  def covering_workflows
    @covering_workflows ||= seller.workflows.alive.abandoned_cart_type.select do |workflow|
      workflow.abandoned_cart_products(only_product_and_variant_ids: true)
              .any? { |product_id, _variant_ids| product_id == product.id }
    end.sort_by(&:id)
  end

  def covering_workflow = covering_workflows.last

  private
    attr_reader :product, :seller

    def can_toggle?
      return true if covering_workflows.empty?
      return false unless covering_workflows.one?

      workflow = covering_workflows.sole
      workflow.bought_products == [product.unique_permalink] &&
        workflow.bought_variants.blank? && workflow.not_bought_products.blank? && workflow.not_bought_variants.blank? &&
        workflow.installments.alive.one?
    end

    def workflow_scope(workflow)
      if workflow.bought_products.blank? && workflow.bought_variants.blank? && workflow.not_bought_products.blank? && workflow.not_bought_variants.blank?
        return "All products"
      end

      names = workflow.abandoned_cart_products.map { _1[:name] }.to_sentence
      workflow.bought_variants.present? || workflow.not_bought_variants.present? ? "Selected versions of #{names}" : names
    end

    def blocked_reason
      return "Manage shared or overlapping reminders in Workflows." unless can_toggle?
      return if available?
      return "Your account can't send emails while it's suspended." if seller.suspended?

      "Available after your first payout."
    end

    def default_message
      DefaultAbandonedCartWorkflowGeneratorService.default_message(
        checkout_url: Rails.application.routes.url_helpers.checkout_url(host: DOMAIN)
      )
    end

    def preview_message(workflow, email)
      workflow ||= seller.workflows.abandoned_cart_type.new(bought_products: [product.unique_permalink])
      email ||= seller.installments.new(message: default_message)
      email.message_with_inline_abandoned_cart_products(products: workflow.abandoned_cart_products)
    end

    def create_workflow
      workflow = seller.workflows.abandoned_cart_type.create!(
        name: DefaultAbandonedCartWorkflowGeneratorService::WORKFLOW_NAME,
        bought_products: [product.unique_permalink],
      )
      workflow.installments.create!(
        name: DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME,
        message: default_message,
        installment_type: workflow.workflow_type,
        json_data: workflow.json_data,
        seller_id: workflow.seller_id,
        send_emails: true,
      ).create_installment_rule!(time_period: InstallmentRule::HOUR,
                                 delayed_delivery_time: InstallmentRule::ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS)
      workflow
    end
end
