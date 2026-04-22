# frozen_string_literal: true

module User::Risk
  extend ActiveSupport::Concern

  PAYMENT_REMINDER_RISK_STATES = %w[flagged_for_tos_violation not_reviewed compliant].freeze
  SUSPENDED_STATES = %w[suspended_for_tos_violation suspended_for_fraud].freeze
  INCREMENTAL_ENQUEUE_BALANCE = 100_00
  PROBATION_WITH_REMINDER_DAYS = 30
  PROBATION_REVIEW_DAYS = 2
  MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS = 3.0

  def enable_refunds!
    self.refunds_disabled = false
    save!
  end

  def disable_refunds!
    self.refunds_disabled = true
    save!
  end

  def flagged_for_explicit_nsfw?
    flagged_for_tos_violation? && tos_violation_reason == Compliance::EXPLICIT_NSFW_TOS_VIOLATION_REASON
  end

  def flag_for_explicit_nsfw_tos_violation!(options)
    transaction do
      update!(tos_violation_reason: Compliance::EXPLICIT_NSFW_TOS_VIOLATION_REASON)

      comment_content = "All products were unpublished because this user was selling prohibited content."
      flag_for_tos_violation!(options.merge(bulk: true, content: comment_content))

      ContactingCreatorMailer.flagged_for_explicit_nsfw_tos_violation(id).deliver_later(queue: "default")

      links.alive.find_each do |product|
        product.unpublish!(is_unpublished_by_admin: true)
      end
    end
  end

  def suspend_due_to_stripe_risk
    transaction do
      update!(tos_violation_reason: "Stripe reported high risk")
      suspend_for_tos_violation!(author_name: "stripe_risk", bulk: true, skip_generic_suspension_email: true) unless suspended?
      links.alive.find_each do |product|
        product.unpublish!(is_unpublished_by_admin: true)
      end
      comments.create!(
        author_name: "stripe_risk",
        comment_type: Comment::COMMENT_TYPE_SUSPENSION_NOTE,
        content: "Suspended because of high risk reported by Stripe"
      )
      ContactingCreatorMailer.suspended_due_to_stripe_risk(id).deliver_later
    end
  end

  def not_verified?
    !verified
  end

  def send_suspension_email(transition)
    return if transition.args.first&.dig(:skip_generic_suspension_email)
    return unless Feature.active?(:account_suspended_email)

    ContactingCreatorMailer.account_suspended(id).deliver_later
  end

  def disable_links_and_tell_chat
    links.each do |link|
      link.update(banned_at: Time.current)
    end
  end

  def enable_links_and_tell_chat
    links.each do |link|
      link.update(banned_at: nil)
    end
  end

  def suspend_sellers_other_accounts(transition)
    return if transition.args.first&.dig(:skip_transition_callback) == __method__

    SuspendAccountsWithPaymentAddressWorker.perform_in(5.seconds, id)
  end

  def block_seller_ip!
    BlockSuspendedAccountIpWorker.perform_in(5.seconds, id)
  end

  def enable_sellers_other_accounts(transition)
    return if transition.args.first&.dig(:skip_transition_callback) == __method__

    enable_accounts_with_same_payment_address
    enable_accounts_with_same_stripe_fingerprint
  end

  def enable_accounts_with_same_payment_address
    return if payment_address.blank?

    User.where(payment_address:).where.not(id:).each do |user|
      user.mark_compliant!(author_name: "enable_sellers_other_accounts", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as payment address #{payment_address} is now unblocked (from User##{id})", skip_transition_callback: :enable_sellers_other_accounts)
    end
  end

  def enable_accounts_with_same_stripe_fingerprint
    fingerprints = bank_accounts.where.not(stripe_fingerprint: [nil, ""]).distinct.pluck(:stripe_fingerprint)
    return if fingerprints.empty?

    user_ids_with_same_fingerprint = BankAccount.alive
      .where(stripe_fingerprint: fingerprints)
      .where.not(user_id: id)
      .distinct
      .pluck(:user_id)

    User.where(id: user_ids_with_same_fingerprint).each do |user|
      matching_fingerprint = (fingerprints & user.alive_bank_accounts.pluck(:stripe_fingerprint)).first
      user.mark_compliant!(author_name: "enable_sellers_other_accounts", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as bank account fingerprint #{matching_fingerprint} is now unblocked (from User##{id})", skip_transition_callback: :enable_sellers_other_accounts)
    end
  end

  def unblock_seller_ip!
    BlockedObject.unblock!(last_sign_in_ip) if last_sign_in_ip.present?
  end

  def delete_custom_domain!
    return if custom_domain.nil?
    return if custom_domain.deleted?

    custom_domain.mark_deleted!
  end

  def suspended?
    suspended_for_tos_violation? || suspended_for_fraud?
  end
  alias_method :suspended, :suspended?

  def flagged?
    flagged_for_tos_violation? || flagged_for_fraud?
  end

  def suspended_by_admin?
    return false unless suspended?

    last_suspension_comment = comments
      .where(comment_type: Comment::COMMENT_TYPE_SUSPENDED)
      .order(:created_at)
      .last

    last_suspension_comment&.author_id.present?
  end

  def add_user_comment(transition)
    params = transition.args.first
    raise ArgumentError, "first transition argument must include an author_id or author_name" if !params || (!params[:author_id] && !params[:author_name])

    author_name = params[:author_name] || User.find(params[:author_id])&.name_or_username
    date = Time.current.to_fs(:formatted_date_full_month)
    content = case transition.to_name
              when :compliant
                "Marked compliant by #{author_name} on #{date}"
              when :not_reviewed
                "Marked \"Not Reviewed\" by #{author_name} on #{date}"
              when :on_probation
                "Probated (payouts suspended) by #{author_name} on #{date}"
              when :flagged_for_tos_violation
                params[:product_id].present? ?
                  "Flagged for a policy violation by #{author_name} on #{date} for product named '#{Link.find(params[:product_id]).name}'" :
                  "Flagged for a policy violation by #{author_name} on #{date}"
              when :suspended_for_tos_violation
                "Suspended for a policy violation by #{author_name} on #{date}"
              when :flagged_for_fraud
                "Flagged for fraud by #{author_name} on #{date}"
              when :suspended_for_fraud
                "Suspended for fraud by #{author_name} on #{date}"
              else
                transition.to_name.to_s.humanize
    end
    comment_type = case transition.to_name
                   when :compliant
                     Comment::COMMENT_TYPE_COMPLIANT
                   when :not_reviewed
                     Comment::COMMENT_TYPE_NOT_REVIEWED
                   when :on_probation
                     Comment::COMMENT_TYPE_ON_PROBATION
                   when :flagged_for_fraud, :flagged_for_tos_violation
                     Comment::COMMENT_TYPE_FLAGGED
                   when :suspended_for_fraud, :suspended_for_tos_violation
                     Comment::COMMENT_TYPE_SUSPENDED
                   else
                     transition.to_name.slice(/[^_]*/)
    end
    comments.create!(
      content: params[:content] || content,
      author_id: params[:author_id],
      author_name: params[:author_name],
      comment_type:
    )
  end

  def add_product_comment(transition)
    params = transition.args.first
    return if params && params[:bulk]
    raise ArgumentError, "first transition argument must include a product_id" if !params || !params[:product_id]

    action_taken = transition.to_name.to_s.humanize
    action_reason = tos_violation_reason
    product = Link.find_by(id: params[:product_id])
    product.comments.create!(
      content: params[:content] || "#{action_taken} as #{action_reason}",
      author_id: params[:author_id],
      author_name: params[:author_name],
      comment_type: transition.to_name.slice(/[^_]*/)
    )
  end

  PAYOUTS_STATUSES = %w[paused payable].freeze
  PAYOUTS_STATUSES.each do |status|
    self.const_set("PAYOUTS_STATUS_#{status.upcase}", status)
  end

  def payouts_status
    @_account_with_paused_payouts_state ||= \
      if payouts_paused?
        PAYOUTS_STATUS_PAUSED
      else
        PAYOUTS_STATUS_PAYABLE
      end
  end

  PAYOUT_PAUSE_SOURCES = %w[stripe admin system user].freeze
  PAYOUT_PAUSE_SOURCES.each do |source|
    self.const_set("PAYOUT_PAUSE_SOURCE_#{source.upcase}", source)
  end

  class_methods do
  end
end
