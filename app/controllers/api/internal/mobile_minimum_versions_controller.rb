# frozen_string_literal: true

class Api::Internal::MobileMinimumVersionsController < Api::Internal::BaseController
  before_action -> { doorkeeper_authorize! :account }

  def show
    # Values for these keys can be set in Rails console to force all mobile app users to upgrade to a specific version.
    # It's very jarring UX to do this, so it should only be used sparingly when we fix critical bugs or introduce breaking changes.
    render json: {
      minimum_version: minimum_version,
      minimum_update_created_at: minimum_update_created_at,
    }
  end

  private
    # The app reads a nil version as "no forced upgrade", so a stalled read must degrade to that
    # rather than failing the check every client makes on launch.
    def minimum_version
      $redis.get(RedisKey.mobile_minimum_version)
    rescue Redis::BaseError, RedisClient::Error
      nil
    end

    def minimum_update_created_at
      $redis.get(RedisKey.mobile_minimum_update_created_at)
    rescue Redis::BaseError, RedisClient::Error
      nil
    end
end
