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
    email = workflow && installments_for(workflow).first
    {
      available: available?,
      blocked_reason:,
      enabled: enabled?,
      can_toggle: can_toggle?,
      activation_token: activation_token(workflow),
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

  def enable(expected_activation_token: nil)
    return :blocked unless available?

    with_toggleable_workflow do |workflow|
      next workflow if workflow&.published_at.present?
      next :stale if expected_activation_token && expected_activation_token != activation_token(workflow)

      workflow ||= create_workflow
      workflow.publish!
      workflow
    end
  end

  def pause
    with_toggleable_workflow do |workflow|
      workflow&.unpublish!
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

    def with_toggleable_workflow
      # Product locking serializes creation; editors instead lock the workflow and its emails.
      product.with_lock do
        clear_preview
        next :blocked unless can_toggle?

        workflow = covering_workflow
        if workflow
          workflow.with_lock do
            @preview_installments = { workflow.id => workflow.installments.alive.order(:id).lock.to_a }
            next :stale unless workflow.alive? && workflow.abandoned_cart_type? && can_toggle?

            yield workflow
          end
        else
          yield nil
        end
      end
    ensure
      clear_preview
    end

    def clear_preview
      @covering_workflows = nil
      @preview_installments = nil
    end

    def installments_for(workflow)
      @preview_installments ||= {}
      @preview_installments[workflow.id] ||= workflow.installments.alive.order(:id).to_a
    end

    # Bind consent to saved targeting and raw content, not rendered catalog/asset data.
    def activation_token(workflow)
      Digest::SHA256.hexdigest({
        product_id: product.id,
        workflow_id: workflow&.id,
        filters: %i[bought_products bought_variants not_bought_products not_bought_variants].map do |filter|
          Array(workflow&.public_send(filter)).sort
        end,
        emails: workflow ? installments_for(workflow).map { [_1.id, _1.name, _1.message] } : [[nil, DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME, default_message]],
      }.to_json)
    end

    def can_toggle?
      return true if covering_workflows.empty?
      return false unless covering_workflows.one?

      workflow = covering_workflows.sole
      workflow.bought_products == [product.unique_permalink] &&
        workflow.bought_variants.blank? && workflow.not_bought_products.blank? && workflow.not_bought_variants.blank? &&
        installments_for(workflow).one?
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
