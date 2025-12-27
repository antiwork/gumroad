# frozen_string_literal: true

class Admin::UnreviewedUsersService
  MINIMUM_BALANCE_CENTS = 1000
  DEFAULT_CUTOFF_DATE = "2024-01-01"
  MAX_CACHED_USERS = 1000

  def cutoff_date
    @cutoff_date ||= self.class.cutoff_date
  end

  def self.cutoff_date
    date_str = $redis.get(RedisKey.unreviewed_users_cutoff_date) || DEFAULT_CUTOFF_DATE
    Date.parse(date_str)
  end

  def count
    base_scope.count.size
  end

  def users_with_unpaid_balance(limit: nil)
    scope = base_scope
      .order(Arel.sql("SUM(balances.amount_cents) DESC"))
      .select("users.*, SUM(balances.amount_cents) AS total_balance_cents")

    limit ? scope.limit(limit) : scope
  end

  def self.cached_users_data
    data = $redis.get(RedisKey.unreviewed_users_data)
    return nil unless data

    JSON.parse(data, symbolize_names: true)
  end

  def self.cache_users_data!
    service = new
    users = service.users_with_unpaid_balance(limit: MAX_CACHED_USERS)

    users_data = users.map do |user|
      Admin::UnreviewedUserPresenter.new(user).props
    end

    cache_payload = {
      users: users_data,
      total_count: service.count,
      cutoff_date: service.cutoff_date.to_s,
      cached_at: Time.current.iso8601
    }

    $redis.set(RedisKey.unreviewed_users_data, cache_payload.to_json)
    cache_payload
  end

  private
    def base_scope
      User
        .joins(:balances)
        .where(user_risk_state: "not_reviewed")
        .where("users.created_at >= ?", cutoff_date)
        .merge(Balance.unpaid)
        .group("users.id")
        .having("SUM(balances.amount_cents) > ?", MINIMUM_BALANCE_CENTS)
    end
end
