# frozen_string_literal: true

module Purchase::Blockable
  extend ActiveSupport::Concern

  included do
    include AttributeBlockable

    attr_blockable :browser_guid
    attr_blockable :ip_address
    attr_blockable :email
    attr_blockable :paypal_email, object_type: :email
    attr_blockable :gifter_email, object_type: :email
    attr_blockable :charge_processor_fingerprint
    attr_blockable :purchaser_email, object_type: :email
    attr_blockable :recent_stripe_fingerprint, object_type: :charge_processor_fingerprint
    attr_blockable :email_domain
    attr_blockable :paypal_email_domain, object_type: :email_domain
    attr_blockable :gifter_email_domain, object_type: :email_domain
    attr_blockable :purchaser_email_domain, object_type: :email_domain

    delegate :email, to: :purchaser, prefix: true, allow_nil: true
  end

  # Max number of failed purchase card fingerprints before a buyer's browser guid gets banned
  MAX_NUMBER_OF_FAILED_FINGERPRINTS = 4

  CARD_TESTING_WATCH_PERIOD = 7.days
  private_constant :CARD_TESTING_WATCH_PERIOD

  CARD_TESTING_IP_ADDRESS_WATCH_PERIOD = 1.day
  private_constant :CARD_TESTING_IP_ADDRESS_WATCH_PERIOD

  CARD_TESTING_IP_ADDRESS_BLOCK_DURATION = 7.days
  private_constant :CARD_TESTING_IP_ADDRESS_BLOCK_DURATION

  IGNORED_ERROR_CODES = [PurchaseErrorCode::PERCEIVED_PRICE_CENTS_NOT_MATCHING,
                         PurchaseErrorCode::NOT_FOR_SALE,
                         PurchaseErrorCode::TEMPORARILY_BLOCKED_PRODUCT,
                         PurchaseErrorCode::BLOCKED_CHARGE_PROCESSOR_FINGERPRINT,
                         PurchaseErrorCode::BLOCKED_CUSTOMER_EMAIL_ADDRESS,
                         PurchaseErrorCode::BLOCKED_CUSTOMER_CHARGE_PROCESSOR_FINGERPRINT]
  private_constant :IGNORED_ERROR_CODES

  MAX_PURCHASER_AGE_FOR_SUSPENSION = 6.hours
  private_constant :MAX_PURCHASER_AGE_FOR_SUSPENSION

  def buyer_blocked?
    blocked_by_browser_guid? ||
      blocked_by_email? ||
      blocked_by_paypal_email? ||
      blocked_by_gifter_email? ||
      blocked_by_purchaser_email? ||
      blocked_by_ip_address? ||
      blocked_by_charge_processor_fingerprint? ||
      blocked_by_recent_stripe_fingerprint?
  end

  def block_buyer!(blocking_user_id: nil, comment_content: nil)
    block_by_browser_guid!(by_user_id: blocking_user_id)
    block_by_email!(by_user_id: blocking_user_id)
    block_by_paypal_email!(by_user_id: blocking_user_id)
    block_by_gifter_email!(by_user_id: blocking_user_id)
    block_by_purchaser_email!(by_user_id: blocking_user_id)
    block_by_ip_address!(by_user_id: blocking_user_id, expires_in: BlockedObject::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months)
    block_by_charge_processor_fingerprint!(by_user_id: blocking_user_id)
    block_by_recent_stripe_fingerprint!(by_user_id: blocking_user_id)

    blocking_user = User.find_by(id: blocking_user_id) if blocking_user_id.present?
    update!(is_buyer_blocked_by_admin: true) if blocking_user&.is_team_member?

    create_blocked_buyer_comments!(blocking_user:, comment_content:)
  end

  def unblock_buyer!
    unblock_by_browser_guid!
    unblock_by_email!
    unblock_by_paypal_email!
    unblock_by_gifter_email!
    unblock_by_purchaser_email!
    unblock_by_ip_address!
    unblock_by_charge_processor_fingerprint!
    unblock_by_recent_stripe_fingerprint!

    update!(is_buyer_blocked_by_admin: false) if is_buyer_blocked_by_admin?
  end

  def charge_processor_fingerprint
    stripe_charge_processor? ? stripe_fingerprint : card_visual
  end

  def pause_payouts_for_seller_based_on_chargeback_rate!
    return unless seller.present?
    return if [User::PAYOUT_PAUSE_SOURCE_ADMIN, User::PAYOUT_PAUSE_SOURCE_SYSTEM].include?(seller.payouts_paused_by_source)

    chargeback_stats = seller.lost_chargebacks
    chargeback_volume_percentage = chargeback_stats[:volume]
    return if chargeback_volume_percentage == "NA"

    volume_rate = chargeback_volume_percentage.to_f
    return if volume_rate <= User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS

    seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)
    seller.comments.create(
      content: "Payouts automatically paused due to chargeback rate (#{chargeback_volume_percentage}) exceeding #{User::MAX_CHARGEBACK_RATE_ALLOWED_FOR_PAYOUTS}% volume.",
      comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
      author_name: "pause_payouts_for_seller_based_on_chargeback_rate"
    )
  end

  private
    def recent_stripe_fingerprint
      Purchase.with_stripe_fingerprint
              .where("purchaser_id = ? or email = ?", purchaser_id, email)
              .last&.stripe_fingerprint
    end

    def blockable_emails_if_fraudulent_transaction
      [purchaser_email, paypal_email, email, gifter_email].compact_blank.uniq
    end

    [:purchaser_email, :paypal_email, :gifter_email, :email].each do |email_attribute|
      define_method("#{email_attribute}_domain") do
        send(email_attribute).presence && Mail::Address.new(send(email_attribute)).domain
      end
    end

    def blocked_by_email_domain_if_fraudulent_transaction?
      blocked_by_email_domain? || blocked_by_paypal_email_domain? || blocked_by_gifter_email_domain? || blocked_by_purchaser_email_domain?
    end

    def ban_fraudulent_buyer_browser_guid!
      return unless stripe_fingerprint

      unique_failed_fingerprints = Purchase.failed.select("distinct stripe_fingerprint").where(
        "browser_guid = ? and stripe_fingerprint is not null", browser_guid
      )
      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      BlockedObject.block!(BLOCKED_OBJECT_TYPES[:browser_guid], browser_guid, nil)
    end

    def ban_buyer_on_fraud_related_error_code!
      failure_code = stripe_error_code || error_code
      return if PurchaseErrorCode::FRAUD_RELATED_ERROR_CODES.exclude?(failure_code)

      block_buyer!
    end

    def suspend_buyer_on_fraudulent_card_decline!
      return if Feature.inactive?(:suspend_fraudulent_buyers)

      failure_code = stripe_error_code || error_code
      return unless failure_code == PurchaseErrorCode::CARD_DECLINED_FRAUDULENT
      return unless purchaser.present?
      return if purchaser.created_at < MAX_PURCHASER_AGE_FOR_SUSPENSION.ago

      purchaser.flag_for_fraud!(author_name: "fraudulent_purchases_blocker")
      purchaser.suspend_for_fraud!(author_name: "fraudulent_purchases_blocker")
    end

    def ban_card_testers!
      return unless stripe_fingerprint
      return if Feature.inactive?(:ban_card_testers)

      block_buyer_based_on_recent_failures!
      block_ip_address_based_on_recent_failures!
    end

    def block_buyer_based_on_recent_failures!
      unique_failed_fingerprints = Purchase.failed.stripe.with_stripe_fingerprint
                                           .select("distinct stripe_fingerprint")
                                           .where("email = ? or browser_guid = ?", email, browser_guid)
                                           .where(created_at: CARD_TESTING_WATCH_PERIOD.ago..)

      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      block_buyer!
    end

    def pause_payouts_for_seller_based_on_recent_failures!
      return if Feature.inactive?(:block_seller_based_on_recent_failures)
      return if IGNORED_ERROR_CODES.include?(error_code)

      failed_seller_purchases_watch_minutes,
      max_seller_failed_purchases_price_cents,
      seller_age_threshold_days = $redis.mget(
        RedisKey.failed_seller_purchases_watch_minutes,
        RedisKey.max_seller_failed_purchases_price_cents,
        RedisKey.seller_age_threshold_days
      )

      seller_age_threshold_days = seller_age_threshold_days.try(:to_i) || 730 # 2 years
      return if seller.created_at < seller_age_threshold_days.days.ago

      failed_seller_purchases_watch_minutes = failed_seller_purchases_watch_minutes.try(:to_i) || 60 # 1 hour
      max_seller_failed_purchases_price_cents = max_seller_failed_purchases_price_cents.try(:to_i) || 200_000 # $2000

      failed_seller_purchases = seller.sales.failed.with_stripe_fingerprint
                                       .where(created_at: failed_seller_purchases_watch_minutes.minutes.ago..)

      failed_price_cents = failed_seller_purchases.sum(:price_cents)
      if failed_price_cents > max_seller_failed_purchases_price_cents
        seller.update!(payouts_paused_internally: true, payouts_paused_by: User::PAYOUT_PAUSE_SOURCE_SYSTEM)

        failed_price_amount = MoneyFormatter.format(failed_price_cents, :usd, no_cents_if_whole: true, symbol: true)
        seller.comments.create(
          content: "Payouts paused due to high volume of failed purchases (#{failed_price_amount} USD in #{failed_seller_purchases_watch_minutes} minutes).",
          comment_type: Comment::COMMENT_TYPE_ON_PROBATION,
          author_name: "pause_payouts_for_seller_based_on_recent_failures"
        )
      end
    end

    def block_ip_address_based_on_recent_failures!
      return if BlockedObject.ip_address.find_active_object(ip_address).present?

      unique_failed_fingerprints = Purchase.failed.stripe.with_stripe_fingerprint
                                           .select("distinct stripe_fingerprint")
                                           .where("ip_address = ?", ip_address)
                                           .where(created_at: CARD_TESTING_IP_ADDRESS_WATCH_PERIOD.ago..)

      return if unique_failed_fingerprints.count < MAX_NUMBER_OF_FAILED_FINGERPRINTS

      BlockedObject.block!(
        BLOCKED_OBJECT_TYPES[:ip_address],
        ip_address,
        nil,
        expires_in: CARD_TESTING_IP_ADDRESS_BLOCK_DURATION
      )
    end

    def block_purchases_on_product!
      return if Feature.inactive?(:block_purchases_on_product)
      return if IGNORED_ERROR_CODES.include?(error_code)

      card_testing_product_watch_minutes,
      max_number_of_failed_purchases,
      card_testing_product_block_hours,
      max_number_of_failed_purchases_in_a_row,
      failed_purchases_in_a_row_watch_days = $redis.mget(
        RedisKey.card_testing_product_watch_minutes,
        RedisKey.card_testing_product_max_failed_purchases_count,
        RedisKey.card_testing_product_block_hours,
        RedisKey.card_testing_max_number_of_failed_purchases_in_a_row,
        RedisKey.card_testing_failed_purchases_in_a_row_watch_days
      )

      card_testing_product_watch_minutes = card_testing_product_watch_minutes.try(:to_i) || 10
      max_number_of_failed_purchases = max_number_of_failed_purchases.try(:to_i) || 60
      card_testing_product_block_hours = card_testing_product_block_hours.try(:to_i) || 6
      max_number_of_failed_purchases_in_a_row = max_number_of_failed_purchases_in_a_row.try(:to_i) || 10
      failed_purchases_in_a_row_watch_days = failed_purchases_in_a_row_watch_days.try(:to_i) || 2

      failed_purchase_attempts_count = link.sales
                                           .failed
                                           .not_recurring_charge
                                           .where("price_cents > 0")
                                           .where("error_code NOT IN (?) OR error_code IS NULL", IGNORED_ERROR_CODES)
                                           .where(created_at: card_testing_product_watch_minutes.minutes.ago..).count

      recent_purchases_failed_in_a_row = failed_purchases_count_redis_namespace.incr(failed_purchases_count_redis_key)
      failed_purchases_count_redis_namespace.expire(failed_purchases_count_redis_key, failed_purchases_in_a_row_watch_days.days.to_i)

      return if failed_purchase_attempts_count < max_number_of_failed_purchases \
             && recent_purchases_failed_in_a_row < max_number_of_failed_purchases_in_a_row

      BlockedObject.block!(
        BLOCKED_OBJECT_TYPES[:product],
        link_id,
        nil,
        expires_in: card_testing_product_block_hours.hours
      )
    end

    def block_fraudulent_free_purchases!
      return if total_transaction_cents.nonzero?

      free_purchases_watch_hours,
      max_allowed_free_purchases_of_same_product,
      fraudulent_free_purchases_block_hours = $redis.mget(
        RedisKey.free_purchases_watch_hours,
        RedisKey.max_allowed_free_purchases_of_same_product,
        RedisKey.fraudulent_free_purchases_block_hours
      )

      free_purchases_watch_hours = free_purchases_watch_hours&.to_i || 4
      max_allowed_free_purchases_of_same_product = max_allowed_free_purchases_of_same_product&.to_i || 2
      fraudulent_free_purchases_block_hours = fraudulent_free_purchases_block_hours&.to_i || 24 # 1 day

      recent_free_purchases_of_same_product = link.sales
                                                  .successful
                                                  .not_recurring_charge
                                                  .where(total_transaction_cents: 0)
                                                  .where(ip_address:)
                                                  .where(created_at: free_purchases_watch_hours.hours.ago..).count

      return if recent_free_purchases_of_same_product <= max_allowed_free_purchases_of_same_product

      BlockedObject.block!(
        BLOCKED_OBJECT_TYPES[:ip_address],
        ip_address,
        nil,
        expires_in: fraudulent_free_purchases_block_hours.hours
      )
    end

    def delete_failed_purchases_count
      failed_purchases_count_redis_namespace.del(failed_purchases_count_redis_key)
    end

    def failed_purchases_count_redis_key
      "product_#{link_id}"
    end

    def failed_purchases_count_redis_namespace
      @_failed_purchases_count_redis_namespace ||= Redis::Namespace.new(:failed_purchases_count, redis: $redis)
    end

    def create_blocked_buyer_comments!(blocking_user: nil, comment_content:)
      comment_params = { content: comment_content, comment_type: "note", author_id: blocking_user&.id || GUMROAD_ADMIN_ID }

      if comment_params[:content].blank?
        if blocking_user&.is_team_member?
          comment_params[:content] = "Buyer blocked by Admin (#{blocking_user.email})"
        elsif blocking_user.present?
          comment_params[:content] = "Buyer blocked by #{blocking_user.email}"
        else
          comment_params[:content] = "Buyer blocked"
        end
      end

      purchaser.comments.create!(comment_params.merge(purchase: self)) if purchaser.present?
      comments.create!(comment_params)
    end
end
