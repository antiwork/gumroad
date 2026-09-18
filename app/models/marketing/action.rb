# frozen_string_literal: true

class Marketing::Action < ApplicationRecord
  include ExternalId

  class ConfirmationChanged < StandardError; end

  # Post text is copy + blank line + link; X counts every URL as 23 characters.
  X_URL_LENGTH = 23
  MAX_POST_LENGTH = 280
  MAX_COPY_LENGTH = MAX_POST_LENGTH - X_URL_LENGTH - 2

  TERMINAL_STATUSES = %w[posted failed cancelled].freeze
  X_WRITE_PERMISSION_MISSING = "x_write_permission_missing"

  belongs_to :user
  belongs_to :link
  belongs_to :utm_link, optional: true

  enum :channel, Marketing::Channel.action_channels, validate: true

  before_validation :set_idempotency_key, on: :create

  validates :idempotency_key, presence: true, uniqueness: true
  validates :copy, presence: true, length: { maximum: MAX_COPY_LENGTH }

  state_machine(:status, initial: :recommended) do
    event :approve do
      transition [:recommended, :approved] => :approved
    end
    event :queue do
      transition approved: :queued
    end
    event :mark_posted do
      transition queued: :posted
    end
    event :mark_failed do
      transition [:approved, :queued] => :failed
    end
    # A connection that cannot write costs the seller nothing already posted, and
    # reconnecting fixes it, so the action stays open instead of going terminal.
    event :require_reconnect do
      transition [:approved, :queued] => :approved
    end
    event :cancel do
      # Not from :queued: the claim has already been committed and the outbound call
      # cannot be recalled, so a cancellation there would only hide a post that still lands.
      transition [:recommended, :approved] => :cancelled
    end
    # A gate the seller can still clear (lifetime sales, a completed payout). Blocking
    # stays open rather than terminal: a closed row would mint a fresh action, and a
    # fresh reason, on every later look at the card.
    event :mark_blocked do
      transition [:recommended, :approved] => :blocked
    end
    event :clear_block do
      transition blocked: :recommended
    end

    before_transition to: :approved, do: ->(action) { action.approved_at = Time.current }
    before_transition to: :queued, do: ->(action) { action.queued_at = Time.current }
    before_transition to: :posted, do: ->(action) { action.posted_at = Time.current }
  end

  scope :open, -> { where.not(status: TERMINAL_STATUSES) }
  # Still worth a reconnect nudge: open, still blocked on write permission, not yet emailed.
  scope :awaiting_reconnect, -> { open.where(error_code: X_WRITE_PERMISSION_MISSING) }
  scope :alive_for_reconnect_notice, -> { awaiting_reconnect.where(reconnect_notified_at: nil) }

  # One open action per (user, product, channel); retries land on the same row.
  def self.find_or_create_open!(user:, link:, channel:)
    link.with_lock do
      open.find_by(user:, link:, channel:) || new(user:, link:, channel:).tap { |action| yield(action); action.save! }
    end
  end

  def approve_copy(confirmation_token:, **attributes)
    with_lock do
      verify_confirmation!(confirmation_token)
      apply_copy_approval(**attributes)
    end
  end

  # The session-authenticated web flow confirms through its own approval UI.
  def approve_copy_from_web(**attributes)
    with_lock { apply_copy_approval(**attributes) }
  end

  def api_idempotency_key = Digest::SHA256.hexdigest(idempotency_key)

  def confirmation_token
    Digest::SHA256.hexdigest([idempotency_key, post_text, user.twitter_handle].to_json)
  end

  def verify_confirmation!(token)
    user.reload
    raise ConfirmationChanged, "The post changed. Review it and confirm again." unless token.is_a?(String) && token.present? && token == confirmation_token
  end

  def terminal? = TERMINAL_STATUSES.include?(status)

  def post_text
    [copy, utm_link&.short_url].compact.join("\n\n")
  end

  def as_json(_options = {})
    {
      id: external_id,
      idempotency_key: api_idempotency_key,
      confirmation_token:,
      channel:,
      status:,
      copy:,
      post_text:,
      link_url: utm_link&.short_url,
      external_url:,
      error_code:,
      approved_at:,
      posted_at:,
    }
  end

  private
    def apply_copy_approval(**attributes)
      return :claimed if queued? || posted?

      self.copy = attributes[:copy] if attributes.key?(:copy)
      return :invalid if copy_changed? && !valid?
      return :approved if approve

      :closed
    end

    def set_idempotency_key
      self.idempotency_key ||= "#{user_id}:#{link_id}:#{channel}:#{SecureRandom.hex(8)}"
    end
end
