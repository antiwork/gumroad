# frozen_string_literal: true

# The launch card's one-tap abandoned-cart workflow. Abandoned-cart email is the one
# automation a seller without a completed payout cannot use, and it is the channel
# exempt from the lifetime-sales half of the email gate.
#
# The workflow is seller-level — its recipient type is "abandoned_cart", not "product" —
# and the scheduler matches a carted product to a workflow through the workflow's own
# product filters, so "for this product" means a filter that covers exactly this product.
class Marketing::AbandonedCart
  def initialize(product:, seller:)
    @product = product
    @seller = seller
  end

  def available? = seller.eligible_for_abandoned_cart_workflows?
  def enabled? = covering_workflow&.published_at.present?

  # What the seller sees before they touch the toggle: the email they are turning on, who
  # gets it, and the delay the existing cart workflow uses.
  def state
    {
      available:,
      blocked_reason:,
      enabled:,
      # A workflow that reaches this product but is not scoped to it is the account-wide
      # default, and the toggle then controls cart recovery for every product — the card
      # has to say so rather than let a product view imply a product-scoped switch.
      account_wide: workflow.present? && workflow.bought_products.blank? && workflow.bought_variants.blank?,
      subject: DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME,
      delay_hours: DefaultAbandonedCartWorkflowGeneratorService::DELAY_HOURS,
      workflow_url: workflow_url,
    }
  end

  # Idempotent: a seller who already has a workflow covering this product gets that one
  # published, not a second one beside it.
  def enable
    return :blocked unless available?
    return workflow if enabled?

    existing = covering_workflow
    return publish(existing) if existing

    create_and_publish
  end

  # Pausing is the workflow's own publish state: the workflow and its email are kept, so
  # the seller can turn it back on or edit it in Workflows.
  def pause
    return :blocked unless available?
    return if workflow.nil? || !enabled?

    workflow.unpublish!
    workflow
  end

  # The seller's abandoned-cart workflow that reaches this product, if there is one. The
  # workflow answers this itself, through the same rule the cart email scheduler uses, so
  # the two cannot disagree about which products a workflow covers.
  def covering_workflow
    @covering_workflow ||= seller.workflows.alive.abandoned_cart_type.filter_map do |workflow|
      workflow if workflow.abandoned_cart_products(only_product_and_variant_ids: true)
                       .any? { |product_id, _variant_ids| product_id == product.id }
    end.max_by(&:id)
  end

  private
    attr_reader :product, :seller

    def workflow = covering_workflow

    def blocked_reason
      return if available?
      return "Your account can't send emails while it's suspended." if seller.suspended?

      "Cart reminders turn on once you've received your first payout."
    end

    def default_message
      DefaultAbandonedCartWorkflowGeneratorService.default_message(
        checkout_url: Rails.application.routes.url_helpers.checkout_url(host: DOMAIN)
      )
    end

    def workflow_url
      workflow = self.workflow
      return if workflow.nil?

      Rails.application.routes.url_helpers.workflow_emails_path(workflow.external_id)
    end

    def publish(workflow)
      workflow.publish!
      workflow
    end

    def create_and_publish
      workflow = nil
      ActiveRecord::Base.transaction do
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
        # publish! refuses a non-abandoned-cart workflow for a seller below the email gate,
        # so this only succeeds because the workflow carries the abandoned-cart exemption.
        workflow.publish!
      end
      workflow
    end
end
