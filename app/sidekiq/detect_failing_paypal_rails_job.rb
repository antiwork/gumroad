# frozen_string_literal: true

class DetectFailingPaypalRailsJob
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 1, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 30.minutes

  AUTHOR_NAME = "failing-paypal-rail"
  LOOKBACK = 7.days
  MIN_FAILED_ATTEMPTS = 20
  DEDUP_WINDOW = LOOKBACK
  PAYEE_ERROR_CODES = [PurchaseErrorCode::PAYPAL_PAYEE_COMPLIANCE_VIOLATION].freeze
  PAYEE_STRIPE_ERROR_CODES = [PurchaseErrorCode::PAYPAL_MERCHANT_ACCOUNT_RESTRICTED].freeze

  def perform
    now = Time.current
    window = (now - LOOKBACK)..now
    account_ids = connected_paypal_accounts.pluck(:id)
    seller_ids = connected_paypal_accounts.pluck(:user_id)
    # seller_id keeps the query on the (seller_id, purchase_state, created_at) index.
    scope = Purchase.paypal.where(created_at: window, seller_id: seller_ids)
    failed_counts = scope.failed
                            .where(merchant_account_id: account_ids)
                            .merge(Purchase.where(error_code: PAYEE_ERROR_CODES).or(Purchase.where(stripe_error_code: PAYEE_STRIPE_ERROR_CODES)))
                            .group(:merchant_account_id)
                            .having("COUNT(*) >= ?", MIN_FAILED_ATTEMPTS)
                            .count
    return if failed_counts.empty?

    # merchant_account_id is unindexed, so narrow to the failing accounts' sellers before filtering on it.
    failing_seller_ids = connected_paypal_accounts.where(id: failed_counts.keys).pluck(:user_id)
    completed_ids = Purchase.paypal.where(created_at: window, seller_id: failing_seller_ids)
                            .all_success_states
                            .where(merchant_account_id: failed_counts.keys)
                            .distinct
                            .pluck(:merchant_account_id)

    connected_paypal_accounts.where(id: failed_counts.keys - completed_ids).find_each do |merchant_account|
      note_failing_rail(merchant_account, failed_counts.fetch(merchant_account.id))
    rescue StandardError => e
      # One account's failure must not stop the remaining accounts from being noted.
      ErrorNotifier.notify(e, context: { merchant_account_id: merchant_account.id, user_id: merchant_account.user_id })
    end
  end

  private
    def connected_paypal_accounts
      MerchantAccount.paypal.alive.charge_processor_alive.where.not(user_id: nil)
    end

    def note_failing_rail(merchant_account, failed_count)
      user = merchant_account.user
      return if user.nil?

      marker = "(#{merchant_account.charge_processor_merchant_id})"
      content = "PayPal account #{marker} had #{failed_count} failed PayPal payee-side purchase attempts and no completed " \
                "purchases in the last #{LOOKBACK.in_days.to_i} days. Review the connected PayPal rail."

      user.with_lock do
        next if user.comments
                    .with_type_note
                    .where(author_name: AUTHOR_NAME)
                    .where("content LIKE ?", "%#{Comment.sanitize_sql_like(marker)}%")
                    .where("created_at > ?", DEDUP_WINDOW.ago)
                    .exists?

        user.comments.create!(author_name: AUTHOR_NAME, comment_type: Comment::COMMENT_TYPE_NOTE, content:)
      end
    end
end
