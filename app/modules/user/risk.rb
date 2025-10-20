# frozen_string_literal: true

module User::Risk
  extend ActiveSupport::Concern

  IFFY_ENDPOINT = "http://internal-production-iffy-live-internal-1668548970.us-east-1.elb.amazonaws.com"

  PAYMENT_REMINDER_RISK_STATES = %w[flagged_for_tos_violation not_reviewed compliant].freeze
  INCREMENTAL_ENQUEUE_BALANCE = 100_00
  COUNTRIES_THAT_DO_NOT_HAVE_ZIPCODES = [
    # Country Codes: http://en.wikipedia.org/wiki/ISO_3166-1_alpha-2
    "ie" # Ireland
  ].freeze
  PROBATION_WITH_REMINDER_DAYS = 30
  PROBATION_REVIEW_DAYS = 2
  MAX_REFUND_QUEUE_SIZE = 10000
  MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS = 3.0

  def self.contact_iffy_risk_analysis(iffy_request_parameters)
    return nil unless Rails.env.production?
    return nil if iffy_request_parameters.blank?
    return nil if iffy_request_parameters[:is_multi_buy]
    return nil if iffy_request_parameters[:card_country] && COUNTRIES_THAT_DO_NOT_HAVE_ZIPCODES.include?(iffy_request_parameters[:card_country].downcase)

    begin
      iffy_call_timeout = determine_iffy_call_timeout
      iffy_response = HTTParty.post("#{IFFY_ENDPOINT}/people/buyer_info", body: iffy_request_parameters, timeout: iffy_call_timeout)
    rescue StandardError
      Rails.logger.info("iffy_fraud_check_timed_out")
      return nil
    end
    if iffy_response.code == 200
      Rails.logger.info("iffy_fraud_check_succeeded, require_zip=#{iffy_response['require_zip']}")
      iffy_response
    else
      Rails.logger.info("iffy_fraud_check_failed, response_code=#{iffy_response.code}")
      nil
    end
  end

  DEFAULT_IFFY_CALL_TIMEOUT = 0.4.seconds

  def self.determine_iffy_call_timeout
    if $redis.present?
      redis_iffy_timeout_value = $redis.get("iffy_zipcode_request_timeout")
      iffy_call_timeout = if redis_iffy_timeout_value.present?
        redis_iffy_timeout_value.to_f
      else
        DEFAULT_IFFY_CALL_TIMEOUT
      end
    else
      iffy_call_timeout = DEFAULT_IFFY_CALL_TIMEOUT
    end
    iffy_call_timeout
  end

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
      flag_for_tos_violation!(author_name: "stripe_risk", bulk: true) unless flagged_for_tos_violation? || on_probation? || suspended?
      suspend_for_tos_violation!(author_name: "stripe_risk", bulk: true) unless suspended?
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

  def log_suspension_time_to_mongo
    Mongoer.async_write(MongoCollections::USER_SUSPENSION_TIME, "user_id" => id, "suspended_at" => Time.current.to_s)
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

  def suspend_sellers_other_accounts
    SuspendAccountsWithPaymentAddressWorker.perform_in(5.seconds, id)
  end

  def block_seller_ip!
    BlockSuspendedAccountIpWorker.perform_in(5.seconds, id)
  end

  def enable_sellers_other_accounts
    return if payment_address.blank?

    User.where(payment_address:).where.not(id:).each do |user|
      user.mark_compliant!(author_name: "enable_sellers_other_accounts", content: "Marked compliant automatically on #{Time.current.to_fs(:formatted_date_full_month)} as payment address #{payment_address} is now unblocked")
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

  def form_email_block
    BlockedObject.email.find_active_object(email)
  end

  def form_email_domain_block
    BlockedObject.email_domain.find_active_object(form_email_domain)
  end

  def add_user_comment(transition)
    params = transition.args.first
    raise ArgumentError, "first transition argument must include an author_id or author_name" if !params || (!params[:author_id] && !params[:author_name])

    author_name = params[:author_name] || User.find(params[:author_id])&.name_or_username
    date = Time.current.to_fs(:formatted_date_full_month)
    content = case transition.to_name
              when :compliant
                "Marked compliant by #{author_name} on #{date}"
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
    def refund_queue(from_date = 7.days.ago)
      user_ids = MONGO_DATABASE[MongoCollections::USER_SUSPENSION_TIME]
        .find(suspended_at: { "$gte": from_date.utc.to_s })
        .limit(MAX_REFUND_QUEUE_SIZE)
        .map { |record| record["user_id"] }

      User.where(id: user_ids, user_risk_state: "suspended_for_fraud")
        .joins(:balances)
        .merge(Balance.unpaid)
        .group(:user_id)
        .having("SUM(amount_cents) > 0")
        .order(updated_at: :desc)
    end
  end
end
