# frozen_string_literal: true

# Handles a court-order ("restraint") notice from Stripe about a seller's connected account
# (gumroad-private#3598). Stripe has already paused the account by the time the notice reaches us;
# what is left is to tell the seller and to keep the handling recorded. The seller notice is written
# at most once per notice key, so a retry on the mail side cannot double-send it.
class StripeRestraintNoticeService
  class InvalidNoticeError < StandardError; end
  class UserNotFoundError < StandardError; end
  class AmbiguousUserError < StandardError; end

  ACCOUNT_ID_FORMAT = /\Aacct_[A-Za-z0-9]+\z/
  COMMENT_PREFIX = "Stripe court order notice"

  Result = Struct.new(:user_external_id, :email, :comment_id, :already_sent, :rendered_email, keyword_init: true)

  class << self
    # A notice names a Stripe account, not a Gumroad user. Exactly one live user with an email
    # address may own that account; anything else is surfaced to the caller rather than guessed at.
    def resolve_user!(stripe_account_id)
      account_id = stripe_account_id.to_s.strip
      raise InvalidNoticeError, "stripe_account_id must look like acct_..." unless ACCOUNT_ID_FORMAT.match?(account_id)

      user_ids = MerchantAccount.alive.stripe.where(charge_processor_merchant_id: account_id).distinct.pluck(:user_id).compact.uniq
      users = User.alive.where(id: user_ids).where.not(email: [nil, ""]).order(:id)
      raise UserNotFoundError, "no live user with an email address for #{account_id}" if users.empty?
      raise AmbiguousUserError, "#{account_id} maps to #{users.count} live users" if users.count > 1

      users.first
    end

    # dry_run returns the matched user and the rendered email and writes nothing, so the notice can
    # be compared against the original mail before sending is switched on.
    def call(stripe_account_id:, firm_name:, firm_email:, notice_key:, dry_run: true)
      firm_name = firm_name.to_s.strip
      firm_email = firm_email.to_s.strip
      notice_key = notice_key.to_s.strip
      raise InvalidNoticeError, "firm_name is required" if firm_name.blank?
      raise InvalidNoticeError, "firm_email is required" if firm_email.blank?
      raise InvalidNoticeError, "notice_key is required" if notice_key.blank?

      user = resolve_user!(stripe_account_id)

      if dry_run
        return Result.new(
          user_external_id: user.external_id,
          email: user.email,
          comment_id: nil,
          already_sent: user.comments.exists?(idempotency_key: notice_key),
          rendered_email: rendered_email(user:, firm_name:, firm_email:),
        )
      end

      comment = User::CreateAdminCommentService.new(
        user:,
        content: comment_content(stripe_account_id: stripe_account_id.to_s.strip, firm_name:, firm_email:, notice_key:),
        idempotency_key: notice_key,
      ).perform
      sent_now = comment.previously_new_record?
      MerchantRegistrationMailer.stripe_restraint_notice(user.id, firm_name, firm_email).deliver_later if sent_now

      Result.new(
        user_external_id: user.external_id,
        email: user.email,
        comment_id: comment.id,
        already_sent: !sent_now,
        rendered_email: nil,
      )
    end

    # The comment doubles as the idempotency guard's comparison value, so it carries no timestamp:
    # a retry of the same notice has to produce byte-identical content.
    def comment_content(stripe_account_id:, firm_name:, firm_email:, notice_key:)
      "#{COMMENT_PREFIX} #{notice_key} for #{stripe_account_id}: the seller was told their payouts " \
        "are paused and was pointed to #{firm_name} <#{firm_email}>."
    end

    private
      def rendered_email(user:, firm_name:, firm_email:)
        message = MerchantRegistrationMailer.stripe_restraint_notice(user.id, firm_name, firm_email)

        {
          to: Array(message.to).first,
          from: Array(message.from).first,
          reply_to: Array(message.reply_to).first,
          subject: message.subject,
          body: message.body.encoded,
        }
      end
  end
end
