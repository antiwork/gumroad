# frozen_string_literal: true

class Admin::UnreviewedUserPresenter
  include Rails.application.routes.url_helpers

  attr_reader :user

  def initialize(user)
    @user = user
  end

  def props
    {
      id: user.id,
      external_id: user.external_id,
      name: user.display_name,
      email: user.email,
      unpaid_balance_cents: user.total_balance_cents.to_i,
      revenue_sources: revenue_sources,
      admin_url: admin_user_path(user.external_id),
      created_at: user.created_at.iso8601
    }
  end

  private
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
