# frozen_string_literal: true

class Admin::UnreviewedUserPresenter
  include Rails.application.routes.url_helpers

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def props
    {
      external_id: user.external_id,
      name: user.display_name,
      email: user.email,
      unpaid_balance_cents: user.total_balance_cents.to_i,
      revenue_sources: revenue_sources,
      payout_method: payout_method,
      account_age_days: account_age_days,
      admin_url: admin_user_path(user.external_id),
      created_at: user.created_at.iso8601
    }
  end

  private
    def account_age_days
      (Date.current - user.created_at.to_date).to_i
    end

    def payout_method
      if user.has_stripe_account_connected?
        "Stripe Connect"
      elsif user.active_bank_account.present?
        "Stripe"
      elsif user.has_paypal_account_connected?
        "PayPal Connect"
      elsif user.payment_address.present?
        "PayPal"
      end
    end

    def revenue_sources
      types = []

      if user.balances.unpaid.joins(:successful_sales).exists?
        types << "sales"
      end

      if user.balances.unpaid.joins(successful_affiliate_credits: :affiliate)
            .where(affiliates: { type: "Collaborator" }).exists?
        types << "collaborator"
      end

      if user.balances.unpaid.joins(successful_affiliate_credits: :affiliate)
            .where.not(affiliates: { type: "Collaborator" }).exists?
        types << "affiliate"
      end

      if user.balances.unpaid.joins(:credits).exists?
        types << "credit"
      end

      types
    end
end
