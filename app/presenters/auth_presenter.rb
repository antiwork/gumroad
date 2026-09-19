# frozen_string_literal: true

class AuthPresenter
  attr_reader :params, :application

  def initialize(params:, application:)
    @params = params
    @application = application
  end

  def login_props
    {
      email: params[:email] || retrieve_team_invitation_email(params[:next]),
      application_name: application&.name,
    }
  end

  def signup_props
    referrer = User.find_by_username(params[:referrer]) if params[:referrer].present?
    login_props.merge(
      referrer: referrer ? {
        id: referrer.external_id,
        name: referrer.name_or_username,
      } : nil,
      stats: signup_stats,
    )
  end

  private
    # Social proof only, so zeros are the degradation: the signup page must render through a
    # stalled read rather than 500.
    def signup_stats
      number_of_creators, total_made = $redis.mget(RedisKey.number_of_creators, RedisKey.total_made)
      { number_of_creators: number_of_creators.to_i, total_made: total_made.to_i }
    rescue Redis::BaseError, RedisClient::Error
      { number_of_creators: 0, total_made: 0 }
    end

    def retrieve_team_invitation_email(next_path)
      # Do not prefill email unless it matches the team invitation accept path
      return unless next_path&.start_with?("/settings/team/invitations")

      Rack::Utils.parse_nested_query(URI.parse(next_path.to_s).query).dig("email")
    end
end
