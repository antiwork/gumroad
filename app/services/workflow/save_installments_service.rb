# frozen_string_literal: true

class Workflow::SaveInstallmentsService
  include InstallmentRuleHelper

  attr_reader :errors, :old_and_new_installment_id_mapping

  def initialize(seller:, params:, workflow:, preview_email_recipient:)
    @seller = seller
    @params = params
    @workflow = workflow
    @preview_email_recipient = preview_email_recipient
    @errors = nil
    @old_and_new_installment_id_mapping = {}
  end

  def process
    if params[:installments].nil?
      workflow.errors.add(:base, "Installments data is required")
      @errors = workflow.errors
      return [false, errors]
    end

    if workflow.abandoned_cart_type? && params[:installments].size != 1
      workflow.errors.add(:base, "An abandoned cart workflow can only have one email.")
      @errors = workflow.errors
      return [false, errors]
    end

    begin
      ActiveRecord::Base.transaction do
        if @workflow.has_never_been_published?
          @workflow.update!(send_to_past_customers: params[:send_to_past_customers])
        end

        delete_removed_installments

        params[:installments].each do |installment_params|
          installment = workflow.installments.alive.find_by_external_id(installment_params[:id]) || workflow.installments.build
          installment.name = installment_params[:name]
          installment.message = installment_params[:message]
          if workflow.abandoned_cart_type? && installment.message.exclude?(Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME)
            installment.message += "<#{Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME} />"
          end
          installment.message = SaveContentUpsellsService.new(seller:, content: installment.message, old_content: installment.message_was).from_html
          installment.send_emails = true
          inherit_workflow_info(installment)
          installment.save!

          SaveFilesService.perform(installment, { files: installment_params[:files] || [] }.with_indifferent_access)

          save_installment_rule_and_reschedule_installment(installment, installment_params)

          installment.send_preview_email(preview_email_recipient) if installment_params[:send_preview_email]

          @old_and_new_installment_id_mapping[installment_params[:id]] = installment.external_id
        end

        workflow.publish! if params[:save_action_name] == Workflow::SAVE_AND_PUBLISH_ACTION
        workflow.unpublish! if params[:save_action_name] == Workflow::SAVE_AND_UNPUBLISH_ACTION
      end
    rescue ActiveRecord::RecordInvalid => e
      @errors = e.record.errors
    rescue Installment::InstallmentInvalid, Installment::PreviewEmailError => e
      workflow.errors.add(:base, e.message)
      @errors = workflow.errors
    end

    [errors.nil?, errors]
  end

  private
    attr_reader :params, :seller, :workflow, :preview_email_recipient

    def delete_removed_installments
      deleted_external_ids = workflow.installments.alive.map(&:external_id) - params[:installments].pluck(:id)
      workflow.installments.by_external_ids(deleted_external_ids).find_each do |installment|
        installment.mark_deleted!
        installment.installment_rule&.mark_deleted!
      end
    end

    def inherit_workflow_info(installment)
      if installment.new_record? || workflow.has_never_been_published?
        installment.installment_type = workflow.workflow_type
        installment.json_data = workflow.json_data
        installment.seller_id = workflow.seller_id
        installment.link_id = workflow.link_id
        installment.base_variant_id = workflow.base_variant_id
        installment.is_for_new_customers_of_workflow = !workflow.send_to_past_customers
      end

      installment.published_at = workflow.published_at
      installment.workflow_installment_published_once_already = workflow.first_published_at.present?
    end

    def save_installment_rule_and_reschedule_installment(installment, installment_params)
      rule = installment.installment_rule || installment.build_installment_rule
      rule.time_period = installment_params[:time_period]
      new_delayed_delivery_time = convert_to_seconds(installment_params[:time_duration], installment_params[:time_period])
      old_delayed_delivery_time = rule.delayed_delivery_time

      # only reschedule new jobs if delivery time changes
      if old_delayed_delivery_time == new_delayed_delivery_time
        rule.save!
        return
      end

      rule.delayed_delivery_time = new_delayed_delivery_time
      rule.save!

      if installment.published_at.present? && params[:save_action_name] == Workflow::SAVE_ACTION
        installment.workflow.schedule_installment(installment, old_delayed_delivery_time:)
      end
    end
end
