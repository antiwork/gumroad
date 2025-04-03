# frozen_string_literal: true

class StripeCreateMerchantAccountsWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default

  PERIOD_INDICATING_USER_IS_ACTIVE = 3.months
  private_constant :PERIOD_INDICATING_USER_IS_ACTIVE

  def perform
    # Create Stripe accounts for users that have user compliance info, in the countries above, and who have bank accounts and have agreed to the TOS.
    # Will not create accounts if a user has a merchant account that's been marked as deleted, because we don't want users to have
    # many Stripe accounts and there's probably a good reason we've taken them off Stripe Connect.

    sql = <<~SQL
      WITH cte AS (
        SELECT * FROM users
        WHERE
          users.user_risk_state IN ("compliant", "not_reviewed")
      )
      SELECT distinct(cte.id) FROM cte
      INNER JOIN user_compliance_info
        ON user_compliance_info.user_id = cte.id
        AND user_compliance_info.deleted_at IS NULL
      INNER JOIN bank_accounts
        ON bank_accounts.user_id = cte.id
        AND bank_accounts.deleted_at IS NULL
      INNER JOIN tos_agreements
        ON tos_agreements.user_id = cte.id
      INNER JOIN balances
        ON balances.user_id = cte.id
        AND balances.created_at > "#{PERIOD_INDICATING_USER_IS_ACTIVE.ago.to_formatted_s(:db)}"
      LEFT JOIN merchant_accounts
        ON merchant_accounts.user_id = cte.id
      WHERE
        merchant_accounts.id IS NULL
    SQL

    user_ids = ApplicationRecord.connection.execute(sql).to_a.flatten
    User.where(id: user_ids).each do |user|
      next unless user.native_payouts_supported?
      CreateStripeMerchantAccountWorker.perform_async(user.id)
    end
  end
end
