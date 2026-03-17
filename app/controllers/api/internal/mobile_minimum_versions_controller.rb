# frozen_string_literal: true

class Api::Internal::MobileMinimumVersionsController < Api::Internal::BaseController
  before_action -> { doorkeeper_authorize! :account }

  def show
    render json: {
      minimum_version: $redis.get(RedisKey.mobile_minimum_version),
      minimum_update_created_at: $redis.get(RedisKey.mobile_minimum_update_created_at),
    }
  end
end
