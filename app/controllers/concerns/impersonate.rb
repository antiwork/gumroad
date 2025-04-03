# frozen_string_literal: true

# Handles impersonation for both web and mobile API
module Impersonate
  extend ActiveSupport::Concern
  include CurrentApiUser
  include LoggedInUser

  included do
    helper_method :impersonating_user, :impersonated_user, :impersonating?
  end

  def impersonate_user(user)
    reset_impersonated_user
    $redis.set(RedisKey.impersonated_user(current_user_from_api_or_web.id), user.id, ex: 7.days.to_i)
  end

  def stop_impersonating_user
    reset_impersonated_user
  end

  def impersonated_user
    return @_impersonated_user if defined?(@_impersonated_user)

    # Short-circuit to avoid a Redis query for non-team members
    # Note that if a team member becomes a non-team member while impersonating, the Redis key associated will stick
    # around until expiration
    return unless can_impersonate?

    @_impersonated_user = find_impersonated_user_from_redis
  end

  def find_impersonated_user_from_redis
    impersonated_user_id = $redis.get(RedisKey.impersonated_user(current_user_from_api_or_web.id))
    return if impersonated_user_id.nil?

    user = User.alive.find(impersonated_user_id)
    user if user.account_active?
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def impersonating?
    impersonated_user.present?
  end

  # Useful to direct emails that would normally go to the impersonated user, to the admin user instead.
  def impersonating_user
    current_user_from_api_or_web if impersonating?
  end

  private
    def current_user_from_api_or_web
      current_api_user || current_user
    end

    def can_impersonate? = current_user_from_api_or_web&.is_team_member?

    def reset_impersonated_user
      $redis.del(RedisKey.impersonated_user(current_user_from_api_or_web.id))
      remove_instance_variable(:@_impersonated_user) if defined?(@_impersonated_user)
    end
end
