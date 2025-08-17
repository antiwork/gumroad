# frozen_string_literal: true

module Purchase::StateManagement
  extend ActiveSupport::Concern

  included do
    state_machine :state, initial: :in_progress do
      state :in_progress
      state :successful
      state :failed
      state :not_charged
      state :gift_receiver_purchase_successful
      state :preorder_authorization_successful
      state :test_successful

      event :mark_as_successful do
        transition [:in_progress, :failed] => :successful
      end

      event :mark_as_failed do
        transition [:in_progress, :successful] => :failed
      end

      event :mark_as_not_charged do
        transition :in_progress => :not_charged
      end

      event :mark_as_gift_receiver_successful do
        transition :in_progress => :gift_receiver_purchase_successful
      end

      event :mark_as_preorder_authorized do
        transition :in_progress => :preorder_authorization_successful
      end

      event :mark_as_test_successful do
        transition :in_progress => :test_successful
      end

      after_transition to: :successful do |purchase|
        purchase.execute_purchase_completion_handler
        purchase.charge_date = Time.current
      end

      after_transition to: :failed do |purchase|
        purchase.failed_at = Time.current
      end
    end

    scope :successful, -> { where(state: CHARGED_SUCCESS_STATES) }
    scope :failed, -> { where(state: "failed") }
    scope :in_progress, -> { where(state: "in_progress") }
    scope :not_charged, -> { where(state: "not_charged") }
  end

  def successful?
    ALL_SUCCESS_STATES_INCLUDING_TEST.include?(state)
  end

  def failed?
    state == "failed"
  end

  def in_progress?
    state == "in_progress"
  end

  def free_purchase?
    state == "not_charged"
  end

  def charged_successfully?
    CHARGED_SUCCESS_STATES.include?(state)
  end

  def counts_towards_reviews?
    COUNTS_REVIEWS_STATES.include?(state)
  end

  def can_be_refunded?
    successful? && !stripe_refunded? && !chargedback_not_reversed?
  end

  def requires_sca?
    requires_sca == true
  end

  def execute_purchase_completion_handler
    PurchaseCompletionHandler.new(self).execute
  end
end
