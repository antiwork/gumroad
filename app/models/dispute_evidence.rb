# frozen_string_literal: true

class DisputeEvidence < ApplicationRecord
  def self.create_from_dispute!(dispute)
    DisputeEvidence::CreateFromDisputeService.new(dispute).perform!
  end

  has_paper_trail

  include ExternalId, TimestampStateFields

  delegate :disputable, to: :dispute

  stripped_fields \
    :customer_purchase_ip,
    :customer_email,
    :customer_name,
    :billing_address,
    :product_description,
    :refund_policy_disclosure,
    :cancellation_policy_disclosure,
    :shipping_address,
    :shipping_carrier,
    :shipping_tracking_number,
    :uncategorized_text,
    :cancellation_rebuttal,
    :refund_refusal_explanation,
    :reason_for_winning

  timestamp_state_fields :created, :seller_contacted, :seller_submitted, :resolved

  belongs_to :dispute

  SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS = 72
  EVIDENCE_REMINDER_LEAD_TIME = 24.hours
  STRIPE_MAX_COMBINED_FILE_SIZE = 5_000_000.bytes
  MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE = 1_000_000.bytes
  # Bounds the inline merge work in Purchases::DisputeEvidenceController#update; Stripe still
  # receives a single merged customer_communication_file.
  MAX_CUSTOMER_COMMUNICATION_FILES = 10
  ALLOWED_FILE_CONTENT_TYPES = %w[image/jpeg image/png application/pdf].freeze

  RESOLUTIONS = %w(unknown submitted rejected).freeze
  RESOLUTIONS.each do |resolution|
    self.const_set("RESOLUTION_#{resolution.upcase}", resolution)
  end

  has_one_attached :cancellation_policy_image
  has_one_attached :refund_policy_image
  has_one_attached :receipt_image
  has_one_attached :customer_communication_file

  validates_presence_of :dispute
  validates :cancellation_rebuttal, :reason_for_winning, :refund_refusal_explanation, length: { maximum: 3_000 }
  validate :customer_communication_file_size
  validate :customer_communication_file_type
  validate :all_files_size_within_limit

  def policy_disclosure=(value)
    policy_disclosure_attribute = for_subscription_purchase? ? :cancellation_policy_disclosure : :refund_policy_disclosure
    self.assign_attributes(policy_disclosure_attribute => value)
  end

  def policy_image
    for_subscription_purchase? ? cancellation_policy_image : refund_policy_image
  end

  def for_subscription_purchase?
    @_subscription_purchase ||= disputable.disputed_purchases.any? { _1.subscription.present? }
  end

  def customer_communication_file_size
    return unless customer_communication_file.attached?
    return if customer_communication_file.byte_size <= customer_communication_file_max_size

    errors.add(:base, "The file exceeds the maximum size allowed.")
  end

  def customer_communication_file_type
    return unless customer_communication_file.attached?
    return if customer_communication_file.content_type.in?(ALLOWED_FILE_CONTENT_TYPES)

    errors.add(:base, "Invalid file type.")
  end

  # Hours the seller has left, from a stamp — display copy only (UI and email hour counts).
  # Rounded, so it reads 0 up to ~29 minutes before seller_response_due_at actually arrives;
  # anything gating a save or a submission must use window_open? below instead.
  def self.hours_left_in_window(seller_contacted_at)
    return 0 if seller_contacted_at.nil?

    (SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS - (Time.current - seller_contacted_at) / 1.hour).round
  end

  # Hours the seller has left to keep working on their statement. A saved statement does not close
  # this: nothing reaches Stripe until the window elapses, so the seller may revise until then.
  # Zero once the row is resolved, which is when the submission is actually spent.
  def hours_left_to_submit_evidence
    return 0 if resolved_at.present?

    self.class.hours_left_in_window(seller_contacted? ? seller_contacted_at : nil)
  end

  def self.seller_response_due_at(seller_contacted_at)
    return if seller_contacted_at.nil?

    seller_contacted_at + SUBMIT_EVIDENCE_WINDOW_DURATION_IN_HOURS.hours
  end

  # Exact comparison against the deadline, for anything that gates a save or a submission.
  # hours_left_in_window rounds for display and closes the window up to 29 minutes early —
  # this is what the permission and submission checks must use instead.
  def self.window_open?(seller_contacted_at)
    due_at = seller_response_due_at(seller_contacted_at)
    due_at.present? && Time.current < due_at
  end

  def self.seller_response_reminder_at(seller_contacted_at)
    seller_response_due_at(seller_contacted_at)&.-(EVIDENCE_REMINDER_LEAD_TIME)
  end

  def seller_response_due_at
    self.class.seller_response_due_at(seller_contacted_at)
  end

  def self.schedule_due_soon_reminder(dispute_id:, seller_contacted_at:, resolved_at:)
    return unless accepting_evidence?(seller_contacted_at:, resolved_at:)

    reminder_at = seller_response_reminder_at(seller_contacted_at)
    return unless reminder_at&.future?

    DisputeEvidenceDueSoonReminderJob.perform_at(reminder_at, dispute_id)
  rescue => e
    ErrorNotifier.notify("DisputeEvidence: could not schedule evidence reminder for dispute #{dispute_id}: #{e.class} #{e.message}")
  end

  # The only state that closes the form. A saved statement does not: nothing is forwarded until the
  # window elapses, so the seller may keep revising and every notice must keep linking them back.
  def self.evidence_submission_closed?(resolved_at:)
    resolved_at.present?
  end

  # May we ask this seller for a statement and link them to the form? Requires an OPEN window:
  # check_if_needs_redirect bounces an unstamped row too, so a nil stamp is not permission to ask.
  # A seller who already saved one is still accepting: they may revise until the window closes.
  #
  # Takes raw column values so a caller holding them without a trustworthy record can still ask —
  # the sweep must not #reload mid-transaction (see claim_seller_contacted_window!).
  def self.accepting_evidence?(seller_contacted_at:, resolved_at:)
    return false if evidence_submission_closed?(resolved_at:)

    seller_contacted_at.present? && window_open?(seller_contacted_at)
  end

  # Is the notice itself still worth sending, whether or not we may ask for evidence? A dispute with
  # no evidence surface at all (PayPal, Stripe Connect) never gets a window and still needs its
  # plain notice, so an unstamped row is accepted here and refused by accepting_evidence?.
  def self.notice_worth_sending?(seller_contacted_at:, resolved_at:)
    return false if evidence_submission_closed?(resolved_at:)

    seller_contacted_at.nil? || window_open?(seller_contacted_at)
  end

  def accepting_evidence?
    self.class.accepting_evidence?(seller_contacted_at:, resolved_at:)
  end

  # Opens the seller's evidence window, and returns whether this caller is the one that opened it.
  #
  # Two paths open it — formalization and CreateMissingDisputeEvidenceJob — and they can run against
  # one row at the same time. Both must claim through here rather than checking seller_contacted? and
  # then writing: the sweep backdates the stamp to land its submission before the processor's cutoff,
  # so a stale check elsewhere would replace that with a fresh full-length window and submit too
  # late. The condition lives in the WHERE, so the loser writes nothing and keeps the winner's window.
  #
  # Deliberately does not reload: the sweep runs this inside the transaction that creates the record
  # and its attachments, and reloading there resets the attachment associations before ActiveStorage's
  # after_commit upload, so the blobs would never reach storage. Read the stamp back with a fresh
  # query rather than #reload on this object.
  def claim_seller_contacted_window!(at: Time.current)
    self.class.where(id:, seller_contacted_at: nil, resolved_at: nil)
        .update_all(seller_contacted_at: at, updated_at: Time.current)
        .positive?
  end

  def all_files_size_within_limit
    all_files_size = receipt_image.byte_size.to_i +
      policy_image.byte_size.to_i +
      customer_communication_file.byte_size.to_i

    return if STRIPE_MAX_COMBINED_FILE_SIZE >= all_files_size

    errors.add(:base, "Uploaded files exceed the maximum size allowed by Stripe.")
  end

  def customer_communication_file_max_size
    @_customer_communication_file_max_size = STRIPE_MAX_COMBINED_FILE_SIZE -
      receipt_image.byte_size.to_i -
      policy_image.byte_size.to_i
  end

  def policy_image_max_size
    @_policy_image_max_size = STRIPE_MAX_COMBINED_FILE_SIZE -
      MINIMUM_RECOMMENDED_CUSTOMER_COMMUNICATION_FILE_SIZE -
      receipt_image.byte_size.to_i
  end
end
