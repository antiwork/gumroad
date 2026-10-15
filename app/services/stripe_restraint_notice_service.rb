# frozen_string_literal: true

# Tells a seller that Stripe paused their account under a court order (gumroad-private#3598). The
# notice comment records the request; StripeRestraintNoticeEmailJob adds an acceptance comment once
# the mail service takes the email. Until then the notice is pending and each call queues it again.
class StripeRestraintNoticeService
  class Error < StandardError
    attr_reader :status

    def initialize(message, status:)
      super(message)
      @status = status
    end
  end

  STRIPE_ACCOUNT_ID_FORMAT = /\Aacct_[A-Za-z0-9]{1,100}\z/
  # A single bare address: no display name, comments, quoting or list separators.
  FIRM_EMAIL_FORMAT = /\A[A-Za-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+\z/
  NOTICE_KEY_FORMAT = /\A[\x21-\x7E]{1,200}\z/
  MAX_FIRM_NAME_LENGTH = 200
  MAX_FIRM_EMAIL_LENGTH = 254
  # Line breaks and invisible formatting characters such as bidi overrides.
  UNSAFE_CHARACTERS = /[\p{Cc}\p{Cf}]/
  NOTICE_KEY_PREFIX = "stripe_restraint_notice"
  ACCEPTED_KEY_PREFIX = "stripe_restraint_notice_accepted"
  QUEUE_FAILED_MESSAGE = "The notice email could not be queued"

  Result = Struct.new(:status, :user, :comment, :accepted, :mail, keyword_init: true)

  # Keyed by the notice comment's id, so no notice key can produce another notice's marker.
  def self.accepted_key(notice_comment)
    "#{ACCEPTED_KEY_PREFIX}:#{notice_comment.id}"
  end

  def initialize(stripe_account_id:, firm_name:, firm_email:, notice_key:, author_id: GUMROAD_ADMIN_ID)
    @stripe_account_id = string_param(stripe_account_id).strip
    @firm_name = string_param(firm_name).strip
    @firm_email = string_param(firm_email).strip
    @notice_key = string_param(notice_key)
    @author_id = author_id
  end

  def user
    @_user ||= begin
      validate!
      resolve_user
    end
  end

  # Reads only, so a dry run shows what a real call would do without changing anything.
  def preview
    comment = user.comments.find_by(idempotency_key: notice_key_digest)
    ensure_same_notice!(comment) if comment
    accepted = comment && user.comments.find_by(idempotency_key: self.class.accepted_key(comment))
    mail = MerchantRegistrationMailer.stripe_restraint_notice(user.id, firm_name, firm_email).message
    Result.new(status: :dry_run, user:, comment:, accepted:, mail:)
  end

  def perform
    seller = user
    ApplicationRecord.transaction do
      # Locks the seller before the comments, the same order as StripeRestraintNoticeEmailJob. The
      # locking reads see rows committed after a caller's transaction began.
      seller.lock!
      comment = seller.comments.lock.find_by(idempotency_key: notice_key_digest)
      ensure_same_notice!(comment) if comment
      accepted = comment && seller.comments.lock.find_by(idempotency_key: self.class.accepted_key(comment))
      next Result.new(status: :already_sent, user: seller, comment:, accepted:) if accepted

      ensure_reachable!(seller)
      if comment.nil?
        comment = User::CreateAdminCommentService.new(user: seller, content:, idempotency_key: notice_key_digest, author_id:).perform
        raise Error.new(comment.errors.full_messages.to_sentence, status: :unprocessable_entity) unless comment.persisted?
      end

      # Pushed before commit, so a failed or refused push rolls a new comment back. A pending comment
      # stays, and the next call queues it again; that also recovers a job lost after a push.
      queue_email!(seller, comment)
      Result.new(status: :queued, user: seller, comment:, accepted: nil)
    end
  end

  private
    attr_reader :stripe_account_id, :firm_name, :firm_email, :notice_key, :author_id

    def string_param(value)
      value.is_a?(String) ? value : ""
    end

    def validate!
      invalid!("stripe_account_id must be a Stripe account id (acct_...)") unless stripe_account_id.match?(STRIPE_ACCOUNT_ID_FORMAT)
      invalid!("firm_name is required") if firm_name.empty?
      invalid!("firm_name is too long") if firm_name.length > MAX_FIRM_NAME_LENGTH
      invalid!("firm_name contains control characters") if firm_name.match?(UNSAFE_CHARACTERS)
      invalid!("firm_email must be a single email address") unless firm_email.length <= MAX_FIRM_EMAIL_LENGTH && firm_email.match?(FIRM_EMAIL_FORMAT)
      invalid!("notice_key must be 1-200 printable characters without spaces") unless notice_key.match?(NOTICE_KEY_FORMAT)
    end

    def invalid!(message)
      raise Error.new(message, status: :unprocessable_entity)
    end

    def resolve_user
      # The column's collation ignores case; Stripe ids do not.
      owner_ids = MerchantAccount.stripe.where(charge_processor_merchant_id: stripe_account_id)
                                 .pluck(:charge_processor_merchant_id, :user_id)
                                 .group_by(&:first).fetch(stripe_account_id, [])
                                 .filter_map(&:last).uniq
      raise Error.new("No Gumroad account uses Stripe account #{stripe_account_id}", status: :not_found) if owner_ids.empty?

      live_owners = User.alive.where(id: owner_ids).to_a
      raise Error.new("The Gumroad account for #{stripe_account_id} is deleted", status: :unprocessable_entity) if live_owners.empty?
      raise Error.new("Stripe account #{stripe_account_id} belongs to more than one live Gumroad account", status: :conflict) if live_owners.size > 1

      seller = live_owners.sole
      ensure_reachable!(seller)
      seller
    end

    def ensure_reachable!(seller)
      raise Error.new("The Gumroad account for #{stripe_account_id} is deleted", status: :unprocessable_entity) if seller.deleted?
      raise Error.new("The Gumroad account for #{stripe_account_id} has no email address", status: :unprocessable_entity) if seller.email.blank?
    end

    def ensure_same_notice!(comment)
      return if comment.content == Comment.normalize_content(content)

      raise Error.new("notice_key was already used for a different notice", status: :conflict)
    end

    def queue_email!(seller, comment)
      jid = StripeRestraintNoticeEmailJob.perform_async(seller.id, comment.id, firm_name, firm_email)
      raise Error.new(QUEUE_FAILED_MESSAGE, status: :service_unavailable) if jid.nil?
    rescue RedisClient::Error
      raise Error.new(QUEUE_FAILED_MESSAGE, status: :service_unavailable)
    end

    # Hashed because the column's collation ignores case, and keys that differ only by case are
    # different notices.
    def notice_key_digest
      "#{NOTICE_KEY_PREFIX}:#{Digest::SHA256.hexdigest(notice_key)}"
    end

    def content
      "Stripe court order notice for #{stripe_account_id}: Stripe paused this account's payouts under a court order. " \
        "Queued an email to the seller with the law firm's contact: #{firm_name} (#{firm_email}). Notice key: #{notice_key}"
    end
end
