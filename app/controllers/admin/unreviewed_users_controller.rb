# frozen_string_literal: true

class Admin::UnreviewedUsersController < Admin::BaseController
  include Pagy::Backend

  RECORDS_PER_PAGE = 100
  MINIMUM_BALANCE_CENTS = 1000
  DEFAULT_CUTOFF_YEARS = 2

  def index
    @title = "Unreviewed users"

    @total_count = unreviewed_users_base_scope.count.size

    pagination, users = pagy(
      unreviewed_users_with_unpaid_balance,
      limit: params[:per_page] || RECORDS_PER_PAGE,
      page: params[:page]
    )

    render inertia: "Admin/UnreviewedUsers/Index",
           props: {
             users: users.map { |user_data| user_props(user_data) },
             pagination: PagyPresenter.new(pagination).props,
             total_count: @total_count,
             cutoff_date: cutoff_date.to_s
           }
  end

  private
    def cutoff_date
      if params[:cutoff_date].present?
        Date.parse(params[:cutoff_date])
      else
        DEFAULT_CUTOFF_YEARS.years.ago.to_date
      end
    rescue ArgumentError
      DEFAULT_CUTOFF_YEARS.years.ago.to_date
    end

    def unreviewed_users_base_scope
      User
        .joins(:balances)
        .where(user_risk_state: "not_reviewed")
        .where("users.created_at >= ?", cutoff_date)
        .merge(Balance.unpaid)
        .group("users.id")
        .having("SUM(balances.amount_cents) > ?", MINIMUM_BALANCE_CENTS)
    end

    def unreviewed_users_with_unpaid_balance
      unreviewed_users_base_scope
        .order(Arel.sql("SUM(balances.amount_cents) DESC"))
        .select("users.*, SUM(balances.amount_cents) AS total_balance_cents")
    end

    def user_props(user)
      {
        id: user.id,
        external_id: user.external_id,
        name: user.display_name,
        email: user.email,
        unpaid_balance_cents: user.total_balance_cents.to_i,
        revenue_sources: revenue_sources_for_user(user),
        admin_url: admin_user_path(user.external_id),
        created_at: user.created_at.iso8601
      }
    end

    def revenue_sources_for_user(user)
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
