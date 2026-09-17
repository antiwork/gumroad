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
  def enabled? = enabled_workflow.present?

  # What the seller sees before they touch the toggle: the email they are turning on, who
  # gets it, and the delay the existing cart workflow uses.
  def state
    {
      available: available?,
      blocked_reason:,
      enabled: enabled?,
      # A covering workflow that is not scoped to a product is the account-wide default, and
      # the toggle then controls cart recovery for every product — the card has to say so
      # rather than let a product view imply a product-scoped switch.
      account_wide: covering_workflows.any? { account_wide?(_1) },
      subject: DefaultAbandonedCartWorkflowGeneratorService::DEFAULT_NAME,
      delay_hours: DefaultAbandonedCartWorkflowGeneratorService::DELAY_HOURS,
      workflow_url: workflow_url,
    }
  end

  # Idempotent: a seller who already has a workflow covering this product gets that one
  # published, not a second one beside it.
  def enable
    return :blocked unless available?

    # Serialized on the product: two taps must not both miss the covering lookup and create a
    # workflow each, which the cart email scheduler would then send from both.
    result = nil
    product.with_lock do
      @covering_workflows = nil
      result = if (already = enabled_workflow)
        already
      elsif (existing = covering_workflow)
        publish(existing)
      else
        create_and_publish
      end
    end
    # The memo describes the world before this call, and the caller reads `state` next.
    @covering_workflows = nil
    result
  end

  # Turning cart recovery off covers EVERY published workflow that reaches the product, since
  # the scheduler sends from all of them and pausing one would leave the others emailing after
  # the seller switched the card off. Eligibility is deliberately not re-checked: a seller who
  # became ineligible (suspended, payout reversed) must still be able to stop live emails.
  def pause
    published = covering_workflows.select(&:published_at)
    return if published.empty?

    published.each(&:unpublish!)
    @covering_workflows = nil
    published.last
  end

  # Every alive abandoned-cart workflow of the seller that reaches this product, oldest first.
  # The workflow answers coverage itself, through the same rule the cart email scheduler uses,
  # so the two cannot disagree about which products a workflow covers.
  def covering_workflows
    @covering_workflows ||= seller.workflows.alive.abandoned_cart_type.select do |workflow|
      workflow.abandoned_cart_products(only_product_and_variant_ids: true)
              .any? { |product_id, _variant_ids| product_id == product.id }
    end.sort_by(&:id)
  end

  # The one the toggle reports on: a published covering workflow if there is one, else the newest.
  def covering_workflow = enabled_workflow || covering_workflows.last

  private
    attr_reader :product, :seller

    def enabled_workflow = covering_workflows.reverse.find(&:published_at)

    def account_wide?(workflow) = workflow.bought_products.blank? && workflow.bought_variants.blank?

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
      workflow = covering_workflow
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
