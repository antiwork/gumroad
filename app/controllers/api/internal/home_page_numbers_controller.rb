# frozen_string_literal: true

class Api::Internal::HomePageNumbersController < Api::Internal::BaseController
  include ActionView::Helpers::NumberHelper

  def index
    home_page_numbers = Rails.cache.read("homepage_numbers")
    return render json: home_page_numbers if home_page_numbers.present?

    home_page_numbers = { prev_week_payout_usd: "$#{number_with_delimiter(prev_week_payout_usd)}" }
    # A stalled read is served uncached: degrading the figure must not publish it on the homepage for
    # a day. An unset key is a successful read of a blank figure and is cached exactly as before.
    Rails.cache.write("homepage_numbers", home_page_numbers, expires_in: 1.day) unless @payout_read_stalled
    render json: home_page_numbers
  end

  private
    def prev_week_payout_usd
      @payout_read_stalled = false
      $redis.get(RedisKey.prev_week_payout_usd)
    rescue *REDIS_TRANSPORT_ERRORS
      @payout_read_stalled = true
      # The same value an unset key gives: the figure renders blank rather than 500ing the page.
      nil
    end
end
