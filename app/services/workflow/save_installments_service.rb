# frozen_string_literal: true

class Workflow::SaveInstallmentsService
  include InstallmentRuleHelper

  attr_reader :errors, :old_and_new_installment_id_mapping, :saved_installments

  def initialize(seller:, params:, workflow:, preview_email_recipient:, replace_all: true)
    @seller = seller
    @params = params
    @workflow = workflow
    @preview_email_recipient = preview_email_recipient
    @replace_all = replace_all
    @errors = nil
    @old_and_new_installment_id_mapping = {}
    @saved_installments = []
  end

  def process
    if params[:installments].nil?
      workflow.errors.add(:base, "Installments data is required")
      @errors = workflow.errors
      return [false, errors]
    end

    begin
      ActiveRecord::Base.transaction do
        workflow.lock!
        unless workflow.alive?
          workflow.errors.add(:base, "The workflow was not found.")
          @errors = workflow.errors
          raise ActiveRecord::Rollback
        end

        if workflow.abandoned_cart_type? && invalid_abandoned_cart_email_count?
          workflow.errors.add(:base, "An abandoned cart workflow can only have one email.")
          @errors = workflow.errors
          raise ActiveRecord::Rollback
        end

        if workflow.has_never_been_published? && (replace_all || params.key?(:send_to_past_customers))
          @workflow.update!(send_to_past_customers: params[:send_to_past_customers])
        end

        delete_removed_installments if replace_all

        params[:installments].each do |installment_params|
          installment = workflow.installments.alive.find_by_external_id(installment_params[:id])
          if installment.nil? && !replace_all && installment_params[:id].present?
            workflow.errors.add(:base, "The email was not found.")
            @errors = workflow.errors
            raise ActiveRecord::Rollback
          end

          installment ||= workflow.installments.build
          new_installment = installment.new_record?

          installment.name = installment_params[:name] if replace_all || new_installment || installment_params.key?(:name)
          if replace_all || new_installment || installment_params.key?(:message)
            installment.message = installment_params[:message]
            if workflow.abandoned_cart_type? && installment.message.exclude?(Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME)
              installment.message += "<#{Installment::PRODUCT_LIST_PLACEHOLDER_TAG_NAME} />"
            end
            installment.message = SaveContentUpsellsService.new(seller:, content: installment.message, old_content: installment.message_was).from_html
          end
          installment.send_emails = true if replace_all || new_installment
          inherit_workflow_info(installment)
          installment.save!

          if replace_all || installment_params.key?(:files)
            SaveFilesService.perform(installment, { files: installment_params[:files] || [] }.with_indifferent_access)
          end

          if !replace_all && new_installment && workflow.published_at.present?
            installment.publish!
          end

          if replace_all || installment.installment_rule.nil? || installment_params.key?(:time_duration) || installment_params.key?(:time_period)
            save_installment_rule_and_reschedule_installment(installment, installment_params)
          end

          installment.send_preview_email(preview_email_recipient) if installment_params[:send_preview_email]

          @old_and_new_installment_id_mapping[installment_params[:id]] = installment.external_id
          @saved_installments << installment
        end

        workflow.publish! if save_action_name == Workflow::SAVE_AND_PUBLISH_ACTION
        workflow.unpublish! if save_action_name == Workflow::SAVE_AND_UNPUBLISH_ACTION
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
    attr_reader :params, :seller, :workflow, :preview_email_recipient, :replace_all

    def save_action_name
      replace_all ? params[:save_action_name] : Workflow::SAVE_ACTION
    end

    def invalid_abandoned_cart_email_count?
      return params[:installments].size != 1 if replace_all

      final_count = workflow.installments.alive.count + params[:installments].count { _1[:id].blank? }
      final_count != 1
    end

    def delete_removed_installments
      deleted_external_ids = workflow.installments.alive.map(&:external_id) - params[:installments].pluck(:id)
      workflow.installments.by_external_ids(deleted_external_ids).find_each do |installment|
        installment.installment_rule&.advance_version!
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

      installment.published_at = workflow.published_at if replace_all
      if replace_all || installment.new_record?
        installment.workflow_installment_published_once_already = workflow.first_published_at.present?
      end
    end

    def save_installment_rule_and_reschedule_installment(installment, installment_params)
      rule = installment.installment_rule || installment.build_installment_rule
      # Hold the row lock before Redis marks the new version. Cache expiry then falls back to a blocked primary read.
      rule.lock! if rule.persisted?
      if replace_all
        new_time_period = installment_params[:time_period]
        new_delayed_delivery_time = convert_to_seconds(installment_params[:time_duration], new_time_period)
      else
        new_time_period = installment_params.key?(:time_period) ? installment_params[:time_period] : rule.time_period
        new_delayed_delivery_time = if installment_params.key?(:time_duration)
          convert_to_seconds(installment_params[:time_duration], new_time_period)
        else
          rule.delayed_delivery_time
        end
      end
      old_delayed_delivery_time = rule.delayed_delivery_time
      rule.time_period = new_time_period

      # only reschedule new jobs if delivery time changes
      if old_delayed_delivery_time == new_delayed_delivery_time
        rule.save!
        return
      end

      rule.delayed_delivery_time = new_delayed_delivery_time
      rule.save!

      if installment.published_at.present? && save_action_name == Workflow::SAVE_ACTION
        WorkflowInstallmentScheduleIntent.enqueue!(
          installment:,
          rule_version: rule.version,
          old_delayed_delivery_time:,
          cutoff_reference_time: Time.current
        )
      end
    end
end
