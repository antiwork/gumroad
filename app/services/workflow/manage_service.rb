# frozen_string_literal: true

class Workflow::ManageService
  include Rails.application.routes.url_helpers

  attr_reader :workflow, :error

  def initialize(seller:, params:, product:, workflow:)
    @seller = seller
    @params = params
    @product = product
    @workflow = workflow || build_workflow
    @error = nil
  end

  def process
    workflow.name = params[:name]

    if workflow.new_record? && params[:workflow_type] == Workflow::ABANDONED_CART_TYPE && !seller.eligible_for_abandoned_cart_workflows?
      workflow.errors.add(:base, "You must have at least one completed payout to create an abandoned cart workflow")
      return [false, workflow.errors.full_messages.first]
    end

    if workflow.has_never_been_published?
      workflow.workflow_type = params[:workflow_type]
      workflow.base_variant = params[:workflow_type] == Workflow::VARIANT_TYPE ? BaseVariant.find_by_external_id(params[:variant_external_id]) : nil
      workflow.link = product_or_variant_type? ? product : nil
      workflow.send_to_past_customers = params[:send_to_past_customers]
      workflow.add_and_validate_filters(params, seller)
      if workflow.errors.any?
        return [false, workflow.errors.full_messages.first]
      end
    end

    begin
      ActiveRecord::Base.transaction do
        was_just_created = workflow.new_record?
        workflow.save!

        if workflow.abandoned_cart_type? && (was_just_created || workflow.installments.alive.where(installment_type: Installment::ABANDONED_CART_TYPE).none?)
          workflow.installments.alive.find_each(&:mark_deleted!) unless was_just_created

          installment = workflow.installments.create!(
            name: "You left something in your cart",
            message: "<p>When you're ready to buy, <a href=\"#{checkout_url(host: DOMAIN)}\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">complete checking out</a>.</p><#{Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME} />",
            installment_type: workflow.workflow_type,
            json_data: workflow.json_data,
            seller_id: workflow.seller_id,
            send_emails: true,
          )
          installment.create_installment_rule!(time_period: InstallmentRule::HOUR, delayed_delivery_time: InstallmentRule::ABANDONED_CART_DELAYED_DELIVERY_TIME_IN_SECONDS)
        end

        if !was_just_created && !workflow.abandoned_cart_type?
          workflow.installments.alive.where(installment_type: Installment::ABANDONED_CART_TYPE).find_each(&:mark_deleted!)
        end

        sync_installments! if workflow.has_never_been_published?
        unless was_just_created
          workflow.publish! if params[:save_action_name] == Workflow::SAVE_AND_PUBLISH_ACTION
          workflow.unpublish! if params[:save_action_name] == Workflow::SAVE_AND_UNPUBLISH_ACTION
        end
      end
    rescue ActiveRecord::RecordInvalid => e
      @error = e.record.errors.full_messages.first
    rescue Installment::InstallmentInvalid => e
      workflow.errors.add(:base, e.message)
      @error = workflow.errors.full_messages.first
    end

    [error.nil?, error]
  end

  private
    attr_reader :params, :seller, :product

    def sync_installments!
      workflow.installments.alive.find_each do |installment|
        installment.installment_type = workflow.workflow_type
        installment.json_data = workflow.json_data
        installment.seller_id = workflow.seller_id
        installment.link_id = workflow.link_id
        installment.base_variant_id = workflow.base_variant_id
        installment.is_for_new_customers_of_workflow = !workflow.send_to_past_customers
        installment.save!
      end
    end

    def build_workflow
      if product_or_variant_type?
        product.workflows.build(seller: product.user)
      else
        seller.workflows.build
      end
    end

    def product_or_variant_type?
      [Workflow::PRODUCT_TYPE, Workflow::VARIANT_TYPE].include?(params[:workflow_type])
    end
end
