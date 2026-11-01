# frozen_string_literal: true

class Workflow < ApplicationRecord
  has_paper_trail

  include ActionView::Helpers::NumberHelper, ExternalId, Deletable, JsonData, WithFiltering, FlagShihTzu,
          Workflow::AbandonedCartProducts

  has_flags 1 => :send_to_past_customers,
            column: "flags",
            flag_query_mode: :bit_operator,
            check_for_column: false

  belongs_to :link, optional: true
  belongs_to :seller, class_name: "User", optional: true
  belongs_to :base_variant, optional: true
  has_many :installments
  has_many :alive_installments, -> { alive }, class_name: "Installment"
  has_many :alive_installments_in_delivery_order, -> { alive.joins(:installment_rule).order("installment_rules.delayed_delivery_time ASC", :id) },
           class_name: "Installment", inverse_of: :workflow

  attr_json_data_accessor :workflow_trigger
  attr_json_data_accessor :workflow_trigger_post_id

  validates_presence_of :seller
  validate :opened_no_click_trigger_has_a_post, if: :opened_no_click_trigger?

  MEMBER_CANCELLATION_WORKFLOW_TRIGGER = "member_cancellation"
  OPENED_NO_CLICK_WORKFLOW_TRIGGER = "opened_no_click"
  OPENED_NO_CLICK_HOUR_DELAY_ERROR = "An opened, no click email waits in days, weeks, or months. Its emails go out once a day."

  # The trigger watches one of the seller's own posts, so the filter is a JSON path read.
  scope :opened_no_click_trigger, -> { where("workflows.json_data->>'$.workflow_trigger' = ?", OPENED_NO_CLICK_WORKFLOW_TRIGGER) }
  SAVE_ACTION = "save"
  SAVE_AND_PUBLISH_ACTION = "save_and_publish"
  SAVE_AND_UNPUBLISH_ACTION = "save_and_unpublish"

  scope :published, -> { where.not(published_at: nil) }

  def recipient_type_audience?
    audience_type?
  end

  def applies_to_purchase?(purchase, **filter_options)
    return false if product_type? && link_id != purchase.link_id
    return false if variant_type? && !purchase.variant_attributes.include?(base_variant)
    purchase_passes_filters(purchase, **filter_options)
  end

  def new_customer_trigger?
    workflow_trigger.nil?
  end

  def member_cancellation_trigger?
    workflow_trigger == MEMBER_CANCELLATION_WORKFLOW_TRIGGER
  end

  def opened_no_click_trigger?
    workflow_trigger == OPENED_NO_CLICK_WORKFLOW_TRIGGER
  end

  # The email whose opens start this workflow's clock. Resolved through the same scope the
  # composer's "has not clicked" picker offers, so a post that was deleted or unpublished
  # afterwards reads as absent and the trigger stops firing instead of erroring.
  def workflow_trigger_post
    return nil if workflow_trigger_post_id.blank?

    seller.installments.emailed_posts.find_by_external_id(workflow_trigger_post_id)
  end

  def targets_variant?(variant)
    (variant_type? && base_variant_id == variant.id) || (bought_variants.present? && bought_variants.include?(variant.external_id))
  end

  def mark_deleted!
    self.class.transaction do
      lock!
      self.deleted_at = Time.current
      installments.each do |installment|
        rule = installment.installment_rule
        rule&.advance_version!
        installment.mark_deleted!
        rule&.mark_deleted!
      end
      save!
    end
  end

  def publish!
    with_transition_lock do
      next true if published_at.present?

      if !abandoned_cart_type? && !seller.eligible_to_send_emails?
        errors.add(:base, "You cannot publish a workflow until you have made at least #{Money.from_cents(Installment::MINIMUM_SALES_CENTS_VALUE).format(no_cents: true)} in total earnings and received a payout")
        raise ActiveRecord::RecordInvalid.new(self)
      end

      # Emails saved under another trigger can still wait hours.
      if opened_no_click_trigger? && installments.alive.joins(:installment_rule).where(installment_rules: { time_period: InstallmentRule::HOUR }).exists?
        errors.add(:base, OPENED_NO_CLICK_HOUR_DELAY_ERROR)
        raise ActiveRecord::RecordInvalid.new(self)
      end

      self.published_at = DateTime.current.change(usec: 0)
      self.first_published_at ||= published_at
      installments_to_schedule = []
      installments.alive.find_each do |installment|
        rule = installment.installment_rule
        rule&.advance_version!
        installment.publish!(published_at:)
        installments_to_schedule << [installment, rule.version] if rule.present? && !installment.abandoned_cart_type?
      end
      save!
      installments_to_schedule.each do |installment, rule_version|
        WorkflowInstallmentScheduleIntent.enqueue!(
          installment:,
          rule_version:,
          old_delayed_delivery_time: nil,
          cutoff_reference_time: published_at,
          expected_published_at: published_at
        )
      end
      true
    end
  end

  def unpublish!
    with_transition_lock do
      next true if published_at.nil?

      self.published_at = nil
      installments.alive.find_each do |installment|
        installment.installment_rule&.advance_version!
        installment.unpublish!
      end
      save!
    end
  end

  def has_never_been_published?
    first_published_at.nil?
  end

  def schedule_installment(installment, old_delayed_delivery_time: nil, cutoff_reference_time: Time.current, reschedule_on_stale: false, minimum_rule_version: nil, schedule_intent_token: nil, schedule_intent_fanout_token: nil)
    return :not_applicable if installment.abandoned_cart_type?
    return :not_applicable unless alive?
    return :not_applicable unless installment.published?

    delay_edit_recovery = reschedule_on_stale && old_delayed_delivery_time.present?

    if member_cancellation_trigger?
      if delay_edit_recovery
        args = [installment.id, old_delayed_delivery_time, cutoff_reference_time.iso8601]
        with_intent = minimum_rule_version.present? || schedule_intent_token.present? || schedule_intent_fanout_token.present?
        args << minimum_rule_version if with_intent
        args << schedule_intent_token if schedule_intent_token.present? || schedule_intent_fanout_token.present?
        args << schedule_intent_fanout_token if schedule_intent_fanout_token.present?
        job_id = SendWorkflowEmailsToPastCanceledMembersJob.perform_async(*args)
        return job_id.present? ? :enqueued : :not_enqueued
      elsif send_to_past_customers?
        args = [installment.id]
        with_intent = schedule_intent_token.present? || schedule_intent_fanout_token.present?
        args.concat([nil, nil, minimum_rule_version]) if minimum_rule_version.present? || with_intent
        args.concat([schedule_intent_token, schedule_intent_fanout_token]) if with_intent
        job_id = SendWorkflowEmailsToPastCanceledMembersJob.perform_async(*args)
        return job_id.present? ? :enqueued : :not_enqueued
      end
      return :not_applicable
    end

    if opened_no_click_trigger?
      # New opens are the daily scan's job, which needs no schedule intent; a publish (or a
      # delay edit) only has to cover the opens that already happened. Returning
      # :not_applicable releases the intent once that pass is queued.
      if delay_edit_recovery
        # A shortened delay makes opens that were still waiting under the old delay due at once, and
        # by then they are older than the daily scan's lookback, so the edit runs its own pass over
        # them. The extra LOOKBACK re-covers sends the old rule's scans queued, which the rule-version
        # check now drops. Like the member-cancellation recovery, this runs whatever past recipients says.
        opened_after = cutoff_reference_time - old_delayed_delivery_time - SendWorkflowEmailsToOpenedNonClickersJob::LOOKBACK
        job_id = SendWorkflowEmailsToOpenedNonClickersJob.perform_async(installment.id, nil, opened_after.iso8601, minimum_rule_version)
        return job_id.present? ? :not_applicable : :not_enqueued
      end

      return :not_applicable unless send_to_past_customers?

      job_id = SendWorkflowEmailsToOpenedNonClickersJob.perform_async(installment.id, nil, nil, minimum_rule_version)
      return job_id.present? ? :not_applicable : :not_enqueued
    end

    return :not_applicable unless new_customer_trigger?
    # don't schedule the installment if it is only for new customers/followers and it hasn't been scheduled before (old_delayed_delivery_time is nil)
    return :not_applicable if old_delayed_delivery_time.nil? && installment.is_for_new_customers_of_workflow

    # earliest_valid_time is:
    #   `installment.published_at` if the installment is for new customers only
    #   `nil` if the installment is being published for the first time and is not for new customers only,
    #   the time based off old_delayed_delivery_time if the installment has already been published before (at least once).
    # We only want the purchases and/or followers created after earliest_valid_time because the specified
    # installment has not been delivered to them and needs to be (re-)scheduled.
    earliest_valid_time = if old_delayed_delivery_time.nil?
      nil
    elsif installment.is_for_new_customers_of_workflow && installment.published_at >= cutoff_reference_time - old_delayed_delivery_time.seconds
      installment.published_at
    else
      cutoff_reference_time - old_delayed_delivery_time.seconds
    end

    args = [installment.id, earliest_valid_time&.iso8601]
    with_intent = schedule_intent_token.present? || schedule_intent_fanout_token.present?
    args << delay_edit_recovery if delay_edit_recovery || minimum_rule_version.present? || with_intent
    args << minimum_rule_version if minimum_rule_version.present? || with_intent
    args.concat([schedule_intent_token, schedule_intent_fanout_token]) if with_intent
    SendWorkflowPostEmailsJob.perform_async(*args).present? ? :enqueued : :not_enqueued
  end

  private
    # The trigger has nothing to watch without an email, and a workflow that watches nothing would
    # silently never send. Only a newly picked email has to resolve: one deleted later must not block
    # unrelated edits.
    def opened_no_click_trigger_has_a_post
      picked = new_record? || json_data_in_database.to_h["workflow_trigger_post_id"] != workflow_trigger_post_id
      return if workflow_trigger_post_id.present? && (!picked || seller.nil? || workflow_trigger_post.present?)

      errors.add(:base, "Pick one of your sent emails as the trigger for this workflow.")
    end

    def with_transition_lock
      self.class.transaction do
        # An update acquires the same row lock when a callback leaves the workflow dirty.
        save! if has_changes_to_save?
        lock!
        yield
      end
    end
end
