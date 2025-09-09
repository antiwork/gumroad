# frozen_string_literal: true

class Subscription < ApplicationRecord
  class DoubleChargeAttemptError < GumroadRuntimeError
    def initialize(subscription_id, purchase_id)
      super("Attempted to double charge subscription: #{subscription_id}, while purchase #{purchase_id} was in progress")
    end
  end

  class UpdateFailed < StandardError; end

  has_paper_trail
  include ExternalId
  include FlagShihTzu
  include Subscription::PingNotification
  include Purchase::Searchable::SubscriptionCallbacks
  include AfterCommitEverywhere

  # time allowed after card declined for buyer to have a successful charge before ending the subscription
  ALLOWED_TIME_BEFORE_FAIL_AND_UNSUBSCRIBE = 5.days
  # time before subscription fails to send reminder about card declined
  CHARGE_DECLINED_REMINDER_EMAIL = 2.days
  # time before free trial expires to send reminder email
  FREE_TRIAL_EXPIRING_REMINDER_EMAIL = 2.days
  # time to access membership manage page after requesting magic link
  TOKEN_VALIDITY = 24.hours

  module ResubscriptionReason
    PAYMENT_ISSUE_RESOLVED = "payment_issue_resolved"
  end

  has_flags 1 => :is_test_subscription,
            2 => :cancelled_by_buyer,
            3 => :cancelled_by_admin,
            4 => :flat_fee_applicable,
            5 => :is_resubscription_pending_confirmation,
            6 => :mor_fee_applicable,
            7 => :is_installment_plan,
            :column => "flags",
            :flag_query_mode => :bit_operator,
            check_for_column: false

  belongs_to :link, optional: true
  belongs_to :user, optional: true
  belongs_to :seller, class_name: "User"
  belongs_to :credit_card, optional: true
  belongs_to :last_payment_option, class_name: "PaymentOption", optional: true

  has_many :purchases
  has_one :original_purchase, -> { is_original_subscription_purchase.not_is_archived_original_subscription_purchase }, class_name: "Purchase"
  has_one :true_original_purchase, -> { is_original_subscription_purchase.order(:id) }, class_name: "Purchase"
  has_one :last_successful_purchase, -> { successful.order(created_at: :desc) }, class_name: "Purchase"
  has_many :url_redirects
  has_many :payment_options
  has_many :subscription_plan_changes
  has_one :latest_plan_change, -> { alive.order(created_at: :desc) }, class_name: "SubscriptionPlanChange"
  has_one :latest_applicable_plan_change, -> { alive.currently_applicable.order(created_at: :desc) }, class_name: "SubscriptionPlanChange"
  has_one :offer_code, through: :original_purchase
  has_many :subscription_events

  before_validation :assign_seller, on: :create

  validate :must_have_payment_option
  validate :installment_plans_cannot_be_cancelled_by_buyer

  before_create :enable_flat_fee
  before_create :enable_mor_fee
  after_create :update_last_payment_option
  after_save :create_interruption_event, if: -> { deactivated_at_previously_changed? }
  after_create :create_interruption_event, if: -> { deactivated_at.present? } # needed in addition to the `after_save`. See https://github.com/gumroad/web/pull/26305#discussion_r1336425626
  after_commit :send_ended_notification_webhook, if: Proc.new { |subscription|
    subscription.deactivated_at.present? &&
      subscription.deactivated_at_previously_changed? &&
      subscription.deactivated_at_previous_change.first.nil?
  }

  attr_writer :price

  # An active subscription is one that should be delivered content to and counted towards customer count. Subscriptions that are pending cancellation
  # are active subscriptions.
  scope :active, lambda {
    where("subscriptions.flags & ? = 0 and failed_at is null and ended_at is null and (cancelled_at is null or cancelled_at > ?)",
          flag_mapping["flags"][:is_test_subscription], Time.current)
  }
  scope :active_without_pending_cancel, -> {
    where("subscriptions.flags & ? = 0 and failed_at is null and ended_at is null and cancelled_at is null",
          flag_mapping["flags"][:is_test_subscription])
  }

  delegate :custom_fields, to: :original_purchase, allow_nil: true
  delegate :original_offer_code, to: :original_purchase, allow_nil: true

  def as_json(*)
    json = {
      id: external_id,
      email:,
      product_id: link.external_id,
      product_name: link.name,
      user_id: user.try(:external_id),
      user_email: user.try(:email),
      purchase_ids: purchases.for_sales_api.map(&:external_id),
      created_at:,
      user_requested_cancellation_at:,
      charge_occurrence_count:,
      recurrence:,
      cancelled_at:,
      ended_at:,
      failed_at:,
      free_trial_ends_at:,
      status:
    }

    json[:license_key] = license_key if license_key.present?

    json
  end

  # An alive subscription is always an active subscription. However, since there are 3 states to a subscription (active, pending cancellation, and
  # ended), there are few instances where we want pending cancellation subscriptions to not be considered alive and in those instances, the caller
  # sets include_pending_cancellation as false and those subscriptions will not be considered alive. This is named different from active to avoid confusion.
  def alive?(include_pending_cancellation: true)
    return false if failed_at.present? || ended_at.present?
    return true if cancelled_at.nil?

    include_pending_cancellation && cancelled_at.future?
  end

  def alive_at?(time)
    start_time = true_original_purchase.created_at
    end_time = next_event_at(:deactivated, start_time) || deactivated_at

    while start_time do
      return true if end_time.nil? && time > start_time
      return true if end_time.present? && time >= start_time && time <= end_time

      start_time = next_event_at(:restarted, end_time)
      end_time = next_event_at(:deactivated, start_time) || deactivated_at
    end

    false
  end

  def grant_access_to_product?
    if is_installment_plan?
      !cancelled_or_failed?
    else
      alive? || !link.block_access_after_membership_cancellation
    end
  end

  def license_key
    @_license_key ||= original_purchase.license_key
  end

  def credit_card_to_charge
    return if is_test_subscription?

    if credit_card.present?
      credit_card
    elsif user.present?
      user.credit_card
    end
  end

  def installments
    # do not include workflow installments as that is gathered separately for the library view since it depends on date of purchase and workflow timeline
    installments = link.installments.not_workflow_installment.alive.published.where("published_at >= ?", created_at)
    installments = installments.where("published_at <= ?", cancelled_at) if cancelled_at.present?
    installments = installments.where("published_at <= ?", failed_at) if failed_at.present?

    # The buyer's library should include the last installment that was published before they subscribed
    last_installment_before_subscription_began = nil
    if link.should_include_last_post
      last_installment_before_subscription_began =
        link.installments.alive.published.where("published_at < ?", created_at).order("published_at DESC").first
    end
    last_installment_before_subscription_began ? installments.to_a.unshift(last_installment_before_subscription_began) : installments
  end

  def email
    user&.form_email.presence || (gift? ? true_original_purchase.giftee_email : original_purchase.email)
  end

  def emails
    {
      subscription: email,
      purchase: gift? ? true_original_purchase.giftee_email : original_purchase.email,
      user: user&.email,
    }
  end

  def price
    payment_option = last_payment_option || fetch_last_payment_option
    payment_option.price
  end

  def current_subscription_price_cents
    if is_installment_plan
      original_purchase.minimum_paid_price_cents
    else
      discount_applies_to_next_charge? ?
        original_purchase.displayed_price_cents :
        original_purchase.displayed_price_cents_before_offer_code(include_deleted: true)
    end
  end

  def current_plan_displayed_price_cents
    # For PWYW subscriptions, show tier minimum price if tier price is less than
    # current subscription price. Otherwise, show current subscription price.
    if tier&.customizable_price? && tier_price.present? && tier_price.price_cents <= current_subscription_price_cents
      tier_price.price_cents
    else
      original_purchase.displayed_price_cents_before_offer_code || original_purchase.displayed_price_cents
    end
  end

  def update_last_payment_option
    self.last_payment_option = fetch_last_payment_option
    save! if persisted?
  end

  def build_purchase(override_params: {}, from_failed_charge_email: false)
    perceived_price_cents = override_params.delete(:perceived_price_cents)
    perceived_price_cents ||= current_subscription_price_cents
    is_upgrade_purchase = override_params.delete(:is_upgrade_purchase)

    purchase_params = { price_range: perceived_price_cents / (link.single_unit_currency? ? 1 : 100.0),
                        perceived_price_cents:,
                        email:,
                        full_name: original_purchase.full_name,
                        street_address: original_purchase.street_address,
                        country: original_purchase.country,
                        state: original_purchase.state,
                        zip_code: original_purchase.zip_code,
                        city: original_purchase.city,
                        ip_address: original_purchase.ip_address,
                        ip_state: original_purchase.ip_state,
                        ip_country: original_purchase.ip_country,
                        browser_guid: original_purchase.browser_guid,
                        variant_attributes: original_purchase.variant_attributes,
                        subscription: self,
                        referrer: original_purchase.referrer,
                        quantity: original_purchase.quantity,
                        was_product_recommended: original_purchase.was_product_recommended,
                        is_installment_payment: original_purchase.is_installment_payment }
    purchase_params.merge!(override_params)
    purchase = Purchase.new(purchase_params)
    purchase.variant_attributes = original_purchase.variant_attributes

    purchase.offer_code = original_purchase.offer_code if discount_applies_to_next_charge?

    purchase.purchaser = user
    purchase.link = link
    purchase.seller = original_purchase.seller
    purchase.credit_card_zipcode = original_purchase.credit_card_zipcode
    if !from_failed_charge_email
      if credit_card_id.present?
        purchase.credit_card_id = credit_card_id
      elsif purchase.purchaser.present? && purchase.purchaser_card_supported?
        purchase.credit_card_id = purchase.purchaser.credit_card_id
      end
    end
    purchase.affiliate = original_purchase.affiliate if original_purchase.affiliate.try(:eligible_for_credit?)
    purchase.is_upgrade_purchase = is_upgrade_purchase if is_upgrade_purchase
    get_vat_id_from_original_purchase(purchase)
    purchase
  end

  def process_purchase!(purchase, from_failed_charge_email = false, off_session: true)
    purchase.ensure_completion do
      purchase.process!(off_session:)
      error_messages = purchase.errors.messages.dup
      if purchase.errors.present? || purchase.error_code.present? || purchase.stripe_error_code.present?
        unless from_failed_charge_email
          if purchase.has_payment_network_error?
            schedule_charge(1.hour.from_now)
          else
            if purchase.has_payment_error?
              CustomerLowPriorityMailer.subscription_card_declined(id).deliver_later(queue: "low")
              ChargeDeclinedReminderWorker.perform_in(ALLOWED_TIME_BEFORE_FAIL_AND_UNSUBSCRIBE - CHARGE_DECLINED_REMINDER_EMAIL, id)
            else
              CustomerLowPriorityMailer.subscription_charge_failed(id).deliver_later(queue: "low")
            end
            schedule_charge(1.day.from_now) if purchase.has_retryable_payment_error?
          end
        end

        # schedule for termination 5 days after subscription is overdue for a charge
        UnsubscribeAndFailWorker.perform_in(terminate_by > (Time.current + 1.minute) ? terminate_by : 1.minute, id)
        purchase.mark_failed!
      elsif purchase.in_progress? && purchase.charge_intent.is_a?(StripeChargeIntent) && (purchase.charge_intent&.processing? || purchase.charge_intent.requires_action?)
        # For recurring charges on Indian cards, the charge goes into processing state for 26 hours.
        # We'll receive a webhook once the charge succeeds/fails, and we'll transition the purchase
        # to terminal (successful/failed) state when we receive that webhook.
        # Check back later to see if the purchase has been completed. If not, transition to a failed state.
        FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
      else
        handle_purchase_success(purchase)
      end

      purchase.save!
      error_messages.each do |key, messages|
        messages.each do |message|
          purchase.errors.add(key, message)
        end
      end
      purchase
    end
  end

  def handle_purchase_success(purchase, succeeded_at: nil)
    purchase.succeeded_at = succeeded_at if succeeded_at.present?
    purchase.update_balance_and_mark_successful!
    original_purchase.update!(should_exclude_product_review: false) if original_purchase.should_exclude_product_review?
    self.credit_card_id = purchase.credit_card_id
    save!
    create_purchase_event(purchase)
    if purchase.was_product_recommended
      recommendation_type = original_purchase.recommended_purchase_info.try(:recommendation_type)
      original_link = original_purchase.recommended_purchase_info.try(:recommended_by_link)
      RecommendedPurchaseInfo.create!(purchase:,
                                      recommended_link: link,
                                      recommended_by_link: original_link,
                                      recommendation_type:,
                                      is_recurring_purchase: true,
                                      discover_fee_per_thousand: original_purchase.discover_fee_per_thousand)
    end
  end

  def handle_purchase_failure(purchase)
    CustomerLowPriorityMailer.subscription_card_declined(id).deliver_later(queue: "low")
    ChargeDeclinedReminderWorker.perform_in(ALLOWED_TIME_BEFORE_FAIL_AND_UNSUBSCRIBE - CHARGE_DECLINED_REMINDER_EMAIL, id)
    # schedule for termination 5 days after subscription is overdue for a charge
    UnsubscribeAndFailWorker.perform_in(terminate_by > (Time.current + 1.minute) ? terminate_by : 1.minute, id)
    purchase.mark_failed!
  end

  # Public: Charge the user and create a new purchase
  # Returns the new `Purchase` object
  def charge!(override_params: {}, from_failed_charge_email: false, off_session: true)
    purchase = build_purchase(override_params:, from_failed_charge_email:)
    process_purchase!(purchase, from_failed_charge_email, off_session:)
  end

  def schedule_charge(scheduled_time)
    RecurringChargeWorker.perform_at(scheduled_time, id)
    Rails.logger.info("Scheduled RecurringChargeWorker(#{id}) to run at #{scheduled_time}")
  end

  def schedule_renewal_reminder
    return unless send_renewal_reminders?
    RecurringChargeReminderWorker.perform_at(send_renewal_reminder_at, id)
  end

  def send_renewal_reminders?
    Feature.active?(:membership_renewal_reminders, seller)
  end

  def unsubscribe_and_fail!
    with_lock do
      return if failed_at.present?

      self.failed_at = Time.current
      self.deactivate!
      CustomerLowPriorityMailer.subscription_autocancelled(id).deliver_later(queue: "low")
      ContactingCreatorMailer.subscription_autocancelled(id).deliver_later(queue: "critical") if seller.enable_payment_email?
      send_cancelled_notification_webhook
    end
  end

  def cancel!(by_seller: true, by_admin: false)
    with_lock do
      return if cancelled_at.present?

      self.user_requested_cancellation_at = Time.current
      self.cancelled_at = end_time_of_subscription
      self.cancelled_by_buyer = !by_seller
      self.cancelled_by_admin = by_admin
      save!

      if cancelled_by_buyer?
        CustomerLowPriorityMailer.subscription_cancelled(id).deliver_later(queue: "low")
        ContactingCreatorMailer.subscription_cancelled_by_customer(id).deliver_later(queue: "critical") if seller.enable_payment_email?
      else
        CustomerLowPriorityMailer.subscription_cancelled_by_seller(id).deliver_later(queue: "low")
        ContactingCreatorMailer.subscription_cancelled(id).deliver_later(queue: "critical") if seller.enable_payment_email?
      end

      send_cancelled_notification_webhook
    end
  end

  def deactivate!
    self.deactivated_at = Time.current
    save!
    original_purchase&.remove_from_audience_member_details

    after_commit do
      DeactivateIntegrationsWorker.perform_async(original_purchase.id)
    end
    schedule_member_cancellation_workflow_jobs if cancelled?
  end

  # Cancels subscription immediately, cancelled_at is now instead of at end of billing period. There are 2 cases for this,
  # product deletion and chargeback(by_buyer). If chargeback, don't send the email and mark cancelled_by_buyer as true.
  def cancel_effective_immediately!(by_buyer: false)
    with_lock do
      self.user_requested_cancellation_at = Time.current
      self.cancelled_at = Time.current
      self.cancelled_by_buyer = by_buyer
      self.deactivate!

      send_cancelled_notification_webhook
      CustomerLowPriorityMailer.subscription_product_deleted(id).deliver_later(queue: "low") unless by_buyer
    end
  end

  def end_subscription!
    with_lock do
      return if ended_at.present?

      self.ended_at = Time.current
      self.deactivate!

      CustomerLowPriorityMailer.subscription_ended(id).deliver_later(queue: "low")
      ContactingCreatorMailer.subscription_ended(id).deliver_later(queue: "critical") if seller.enable_payment_email?
    end
  end

  # creates a new original subscription purchase & archives the existing one.
  # Any changes to the subscription made here must be reverted in `Subscription::UpdaterService#restore_original_purchase`
  def update_current_plan!(new_variants:, new_price:, new_quantity: nil, perceived_price_cents: nil, is_applying_plan_change: false, skip_preparing_for_charge: false)
    raise Subscription::UpdateFailed, "Installment plans cannot be updated." if is_installment_plan?
    raise Subscription::UpdateFailed, "Changing plans for fixed-length subscriptions is not currently supported." if has_fixed_length?

    ActiveRecord::Base.transaction do
      payment_option = last_payment_option

      # build new original subscription purchase
      new_purchase = build_purchase(override_params: { is_original_subscription_purchase: true,
                                                       email: original_purchase.email,
                                                       is_free_trial_purchase: original_purchase.is_free_trial_purchase })
      # avoid failing `Purchase#variants_available` validation if reverting back to the original set of variants & those variants are unavailable
      new_purchase.original_variant_attributes = original_purchase.variant_attributes
      # avoid failing `Purchase#price_not_too_low` validation if reverting back to the original subscription price & price has been deleted
      new_purchase.original_price = price
      # avoid `Purchase#not_double_charged` and sold out validations
      new_purchase.is_updated_original_subscription_purchase = true
      # avoid price validation failures when applying a pre-existing plan change (i.e. a downgrade)
      new_purchase.is_applying_plan_change = is_applying_plan_change
      # avoid preparing chargeable, in cases where we simply want to calculate the new price
      new_purchase.skip_preparing_for_charge = skip_preparing_for_charge
      new_purchase.variant_attributes = link.is_tiered_membership? ? new_variants : original_purchase.variant_attributes
      new_purchase.is_original_subscription_purchase = true
      new_purchase.perceived_price_cents = perceived_price_cents
      new_purchase.price_range = perceived_price_cents.present? ? perceived_price_cents / (link.single_unit_currency? ? 1 : 100.0) : nil
      new_purchase.business_vat_id = original_purchase.purchase_sales_tax_info&.business_vat_id
      new_purchase.quantity = new_quantity if new_quantity.present?
      original_purchase.purchase_custom_fields.each { new_purchase.purchase_custom_fields << _1.dup }

      license = original_purchase.license
      license.purchase = new_purchase if license.present?

      # update price
      self.price = new_price
      payment_option.price = new_price
      payment_option.save!

      # archive old original subscription purchase
      original_purchase.is_archived_original_subscription_purchase = true
      original_purchase.save!

      if new_purchase.offer_code.present? && original_discount = original_purchase.purchase_offer_code_discount
        new_purchase.build_purchase_offer_code_discount(offer_code: new_purchase.offer_code, offer_code_amount: original_discount.offer_code_amount,
                                                        offer_code_is_percent: original_discount.offer_code_is_percent,
                                                        pre_discount_minimum_price_cents: new_purchase.minimum_paid_price_cents_per_unit_before_discount)
      end

      if original_purchase.recommended_purchase_info.present?
        original_recommended_purchase_info = original_purchase.recommended_purchase_info
        new_purchase.build_recommended_purchase_info({
                                                       recommended_link_id: original_recommended_purchase_info.recommended_link_id,
                                                       recommended_by_link_id: original_recommended_purchase_info.recommended_by_link_id,
                                                       recommendation_type: original_recommended_purchase_info.recommendation_type,
                                                       discover_fee_per_thousand: original_recommended_purchase_info.discover_fee_per_thousand,
                                                       is_recurring_purchase: original_recommended_purchase_info.is_recurring_purchase
                                                     })
      end

      # update price, fees, etc. on new purchase
      new_purchase.prepare_for_charge!
      raise Subscription::UpdateFailed, new_purchase.errors.full_messages.first if new_purchase.errors.present?

      # update email infos once new_purchase is successfully saved
      email_infos = original_purchase.email_infos
      email_infos.each { |email| email.update!(purchase_id: new_purchase.id) }

      # update the purchase associated with comments
      Comment.where(purchase: original_purchase).update_all(purchase_id: new_purchase.id)

      # new original subscription purchase will never be charged and should not
      # be treated as a 'successful' purchase in most instances
      if new_purchase.is_test_purchase?
        new_purchase.mark_test_successful!
      elsif !new_purchase.not_charged?
        new_purchase.mark_not_charged!
      end
      new_purchase.create_url_redirect!
      create_purchase_event(new_purchase, template_purchase: original_purchase)

      new_purchase
    end
  end

  def for_tier?(product_tier)
    tier == product_tier || latest_plan_change&.tier == product_tier
  end

  def cancelled_or_failed?
    cancelled_at.present? || failed_at.present?
  end

  def ended?
    ended_at.present?
  end

  def pending_cancellation?
    alive? && cancelled_at.present?
  end

  def cancelled?(treat_pending_cancellation_as_live: true)
    !alive?(include_pending_cancellation: treat_pending_cancellation_as_live) && cancelled_at.present?
  end

  def deactivated?
    deactivated_at.present?
  end

  def cancelled_by_seller?
    cancelled?(treat_pending_cancellation_as_live: false) && !cancelled_by_buyer?
  end

  def first_successful_charge
    successful_purchases.first
  end

  def last_successful_charge
    successful_purchases.last
  end

  def last_successful_charge_at
    last_successful_charge&.succeeded_at
  end

  def last_purchase
    last_successful_charge || purchases.is_free_trial_purchase.last
  end

  def last_purchase_at
    last_purchase&.succeeded_at || last_purchase&.created_at
  end

  def end_time_of_subscription
    return free_trial_ends_at if free_trial_ends_at.present? && last_purchase&.is_free_trial_purchase?
    return end_time_of_last_paid_period if end_time_of_last_paid_period.present? && end_time_of_last_paid_period > Time.current
    return Time.current if purchases.last.chargedback_not_reversed_or_refunded? || last_purchase_at.nil?

    last_purchase_at + period
  end

  def end_time_of_last_paid_period
    if last_successful_not_reversed_or_refunded_charge_at.present?
      last_successful_not_reversed_or_refunded_charge_at + period
    else
      free_trial_ends_at
    end
  end

  def expected_completion_time
    return nil unless has_fixed_length?

    end_time_of_last_paid_period + period * remaining_charges_count
  end

  def send_renewal_reminder_at
    [end_time_of_subscription - BasePrice::Recurrence.renewal_reminder_email_days(recurrence), Time.current].max
  end

  def overdue_for_charge?
    end_time_of_subscription <= Time.current
  end

  def seconds_overdue_for_charge
    return 0 unless overdue_for_charge? && end_time_of_last_paid_period.present?
    (Time.current - end_time_of_last_paid_period).to_i
  end

  def has_a_charge_in_progress?
    purchases.in_progress.exists?
  end

  # How much of a discount the user will receive when upgrading to a more
  # expensive plan, based on the time remaining in the current billing period.
  # Defaults to calculating time remaining as of the end of today.
  def prorated_discount_price_cents(calculate_as_of: Time.current.end_of_day)
    return 0 if last_successful_charge_at.nil?

    seconds_since_last_billed = calculate_as_of - last_successful_charge_at
    percent_of_current_period_remaining = [(current_billing_period_seconds - seconds_since_last_billed), 0].max / current_billing_period_seconds
    (percent_of_current_period_remaining * original_purchase.displayed_price_cents).round
  end

  def current_billing_period_seconds
    return 0 unless last_purchase_at.present?
    (end_time_of_subscription - last_purchase_at).to_i
  end

  def formatted_end_time_of_subscription
    formatted_time = end_time_of_subscription
    formatted_time = formatted_time.in_time_zone(user.timezone) if user
    formatted_time.to_fs(:formatted_date_full_month)
  end

  def recurrence
    if is_installment_plan
      last_payment_option.installment_plan.recurrence
    else
      price.recurrence
    end
  end

  def period
    BasePrice::Recurrence.seconds_in_recurrence(recurrence)
  end

  def subscription_mobile_json_data
    return nil unless alive?

    json_data = link.as_json(mobile: true)
    subscription_data = {
      subscribed_at: created_at,
      external_id:,
      recurring_amount: original_purchase.formatted_display_price
    }
    json_data[:subscription_data] = subscription_data
    purchase = original_purchase
    if purchase
      json_data[:purchase_id] = purchase.external_id
      json_data[:purchased_at] = purchase.created_at
      json_data[:user_id] = purchase.purchaser.external_id if purchase.purchaser
      json_data[:can_contact] = purchase.can_contact
    end
    json_data[:updates_data] = updates_mobile_json_data
    json_data
  end

  def updates_mobile_json_data
    original_purchase.product_installments.map { |installment| installment.installment_mobile_json_data(purchase: original_purchase, subscription: self) }
  end

  # Returns true if no new charge is needed else false
  def resubscribe!
    with_lock do
      now = Time.current
      pending_cancellation = cancelled_at.present? && cancelled_at > now
      is_deactivated = deactivated_at.present?

      self.user_requested_cancellation_at = nil
      self.cancelled_at = nil
      self.deactivated_at = nil
      self.cancelled_by_admin = false
      self.cancelled_by_buyer = false
      self.failed_at = nil unless pending_cancellation
      save!
      original_purchase&.add_to_audience_member_details

      if is_deactivated
        # Calculate by how much time do we need to delay the workflow installments
        send_delay = (now - last_deactivated_at).to_i

        original_purchase.reschedule_workflow_installments(send_delay:)

        after_commit do
          ActivateIntegrationsWorker.perform_async(original_purchase.id)
        end
      end

      pending_cancellation ? true : false
    end
  end

  def last_resubscribed_at
    if defined?(@_last_resubscribed_at)
      @_last_resubscribed_at
    else
      @_last_resubscribed_at = subscription_events.restarted
                                                  .order(occurred_at: :desc)
                                                  .take
                                                  &.occurred_at
    end
  end

  def last_deactivated_at
    return deactivated_at if deactivated_at.present?

    if defined?(@_last_deactivated_at)
      @_last_deactivated_at
    else
      @_last_deactivated_at = subscription_events.deactivated
                                                 .order(occurred_at: :desc)
                                                 .take
                                                 &.occurred_at
    end
  end

  def send_restart_notifications!(reason = nil)
    CustomerMailer.subscription_restarted(id, reason).deliver_later(queue: "critical")
    ContactingCreatorMailer.subscription_restarted(id).deliver_later(queue: "critical")
    send_restarted_notification_webhook
  end

  def resubscribed?
    last_resubscribed_at.present? && last_deactivated_at.present?
  end

  def has_fixed_length?
    charge_occurrence_count.present?
  end

  def charges_completed?
    has_fixed_length? && purchases.successful.count == charge_occurrence_count
  end

  def remaining_charges_count
    has_fixed_length? ? charge_occurrence_count - purchases.successful.count : 0
  end

  # Certain events should transition the subscription from pending cancellation to cancelled thus not allowing the customer access to updates.
  def cancel_immediately_if_pending_cancellation!
    with_lock do
      return unless pending_cancellation?

      self.cancelled_at = Time.current
      self.deactivate!
    end
  end

  def termination_date
    (ended_at || cancelled_at || failed_at || deactivated_at).try(:to_date)
  end

  def termination_reason
    return unless deactivated_at.present?

    if failed_at.present?
      "failed_payment"
    elsif ended_at.present?
      "fixed_subscription_period_ended"
    elsif cancelled_at.present?
      "cancelled"
    end
  end

  def send_cancelled_notification_webhook
    send_notification_webhook(resource_name: ResourceSubscription::CANCELLED_RESOURCE_NAME)
  end

  def send_ended_notification_webhook
    send_notification_webhook(resource_name: ResourceSubscription::SUBSCRIPTION_ENDED_RESOURCE_NAME)
  end

  def send_restarted_notification_webhook
    params = {
      restarted_at: Time.current.as_json
    }

    send_notification_webhook(resource_name: ResourceSubscription::SUBSCRIPTION_RESTARTED_RESOURCE_NAME, params:)
  end

  def create_interruption_event
    event_type = deactivated_at.present? ? :deactivated : :restarted
    return if subscription_events.order(:occurred_at, :id).last&.event_type == event_type.to_s

    subscription_events.create!(event_type:, occurred_at: deactivated_at || Time.current)
  end

  def send_updated_notifification_webhook(plan_change_type:, old_recurrence:, new_recurrence:, old_tier:, new_tier:, old_price:, new_price:, effective_as_of:, old_quantity:, new_quantity:)
    return unless plan_change_type.in?(["upgrade", "downgrade"])

    params = {
      type: plan_change_type,
      effective_as_of: effective_as_of&.as_json,
      old_plan: {
        tier: { id: old_tier.external_id, name: old_tier.name },
        recurrence: old_recurrence,
        price_cents: old_price,
        quantity: old_quantity,
      },
      new_plan: {
        tier: { id: new_tier.external_id, name: new_tier.name },
        recurrence: new_recurrence,
        price_cents: new_price,
        quantity: new_quantity,
      }
    }
    send_notification_webhook(resource_name: ResourceSubscription::SUBSCRIPTION_UPDATED_RESOURCE_NAME, params:)
  end

  def tier
    original_purchase.tier
  end

  def has_free_trial?
    free_trial_ends_at.present?
  end

  def in_free_trial?
    has_free_trial? && free_trial_ends_at > Time.current
  end

  def free_trial_ended?
    return unless has_free_trial?
    free_trial_ends_at <= Time.current
  end

  def free_trial_end_date_formatted
    return unless has_free_trial?
    free_trial_ends_at.to_fs(:formatted_date_full_month)
  end

  def pending_failure?
    alive? && purchases.order(:created_at).last&.failed?
  end

  def status
    if deactivated_at.present?
      termination_reason
    elsif pending_failure?
      "pending_failure"
    elsif pending_cancellation?
      "pending_cancellation"
    else
      "alive"
    end
  end

  def should_exclude_product_review_on_charge_reversal?
    has_free_trial? && !original_purchase.should_exclude_product_review? && !first_successful_charge&.allows_review?
  end

  def alive_or_restartable?
    !ended? && !cancelled_by_seller?
  end

  def discount_applies_to_next_charge?
    return true if is_installment_plan

    duration_in_billing_cycles = original_purchase.purchase_offer_code_discount&.duration_in_billing_cycles
    return true if duration_in_billing_cycles.blank?

    purchases.successful.count < duration_in_billing_cycles
  end

  def cookie_key
    "subscription_#{external_id_numeric}"
  end

  def refresh_token
    update!(token: SecureRandom.hex(24), token_expires_at: TOKEN_VALIDITY.from_now)
    token
  end

  def gift?
    true_original_purchase.is_gift_sender_purchase?
  end

  private
    def send_notification_webhook(resource_name:, params: nil)
      args = [5.seconds, nil, nil, resource_name, id]
      args << params.deep_stringify_keys if params.present?
      PostToPingEndpointsWorker.perform_in(*args)
    end

    def installment_plans_cannot_be_cancelled_by_buyer
      return unless is_installment_plan?
      return unless cancelled_at_changed?(from: nil)

      errors.add(:base, "Installment plans cannot be cancelled by the customer") if cancelled_by_buyer?
    end

    def must_have_payment_option
      errors.add(:base, "Subscription must have at least one PaymentOption") if payment_options.blank?
    end

    def successful_purchases
      is_test_subscription ? purchases.test_successful : purchases.successful
    end

    def last_successful_not_reversed_or_refunded_charge_at
      successful_purchases.not_fully_refunded.not_chargedback_or_chargedback_reversed.order(succeeded_at: :desc).first&.succeeded_at
    end

    def tier_price
      return nil unless original_purchase.link.is_tiered_membership? && tier.present?
      tier.prices.alive.is_buy.find_by(recurrence:)
    end

    def create_purchase_event(purchase, template_purchase: nil)
      original_purchase_event = Event.find_by(purchase_id: (template_purchase || original_purchase).id)
      return nil if original_purchase_event.nil?

      purchase_event = original_purchase_event.dup
      purchase_event.assign_attributes(
        purchase_id: purchase.id,
        is_recurring_subscription_charge: !purchase.is_original_subscription_purchase && !purchase.is_upgrade_purchase,
        purchase_state: purchase.purchase_state,
        price_cents: purchase.price_cents,
        card_visual: purchase.card_visual,
        card_type: purchase.card_type,
        billing_zip: purchase.zip_code
      )

      purchase_event.save!
      purchase_event
    end

    def fetch_last_payment_option
      payment_options.alive.last
    end

    def get_vat_id_from_original_purchase(purchase)
      if original_purchase.purchase_sales_tax_info&.business_vat_id
        purchase.business_vat_id = original_purchase.purchase_sales_tax_info.business_vat_id
      elsif original_purchase.refunds.where("gumroad_tax_cents > 0").where("amount_cents = 0").exists?
        purchase.business_vat_id = original_purchase.refunds.where("gumroad_tax_cents > 0").where("amount_cents = 0").first.business_vat_id
      end
    end

    def schedule_member_cancellation_workflow_jobs
      return if alive? || !cancelled?

      workflows = seller.workflows.alive.seller_or_product_or_variant_type
      workflows.each do |workflow|
        next unless workflow.member_cancellation_trigger?
        next unless workflow.applies_to_purchase?(original_purchase)

        workflow.installments.alive.each do |installment|
          installment_rule = installment.installment_rule
          next if installment_rule.nil?

          SendWorkflowInstallmentWorker.perform_at(deactivated_at + installment_rule.delayed_delivery_time,
                                                   installment.id, installment_rule.version, nil, nil, nil, id)
        end
      end
    end

    def terminate_by
      paid_through = end_time_of_last_paid_period || created_at
      paid_through + ALLOWED_TIME_BEFORE_FAIL_AND_UNSUBSCRIBE
    end

    def next_event_at(event_type, time)
      return if time.nil?

      cached_subscription_events.detect { |event| event.event_type.to_s == event_type.to_s && event.occurred_at > time }&.occurred_at
    end

    def cached_subscription_events
      @_cached_subscription_events ||= subscription_events.order(occurred_at: :asc).to_a
    end

    def enable_flat_fee
      self.flat_fee_applicable = true
    end

    def enable_mor_fee
      self.mor_fee_applicable = true
    end

    def assign_seller
      self.seller_id = link.user_id
    end
end
