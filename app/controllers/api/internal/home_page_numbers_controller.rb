# frozen_string_literal: true

class Api::Internal::HomePageNumbersController < Api::Internal::BaseController
  include ActionView::Helpers::NumberHelper

  def index
    home_page_numbers = Rails.cache.fetch("homepage_numbers", expires_in: 1.day) do
      {
        prev_week_payout_usd: "$#{number_with_delimiter(prev_week_payout_usd)}"
      }
    end

    render json: home_page_numbers
  end

  private
    def prev_week_payout_usd
      $redis.get(RedisKey.prev_week_payout_usd)
    rescue *REDIS_TRANSPORT_ERRORS
      # The same value an unset key gives: the figure renders blank rather than 500ing the page.
      nil
    end
end
