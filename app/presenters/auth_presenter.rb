# frozen_string_literal: true

class AuthPresenter
  attr_reader :params, :application

  # A presenter is rebuilt on every request, so the last values this process actually read live on
  # the class. A stalled read serves those instead of rendering zeros in the signup copy.
  LAST_SIGNUP_STATS = {}

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
    number_of_creators, total_made = signup_stats
    login_props.merge(
      referrer: referrer ? {
        id: referrer.external_id,
        name: referrer.name_or_username,
      } : nil,
      stats: {
        number_of_creators: number_of_creators.to_i,
        total_made: total_made.to_i,
      },
    )
  end

  private
    # `stats` is not optional in the signup page, so a stalled read cannot be answered by leaving
    # it out. Serve what this process last read; before the first successful read there is nothing
    # to serve, and an unset key already reads as zero.
    def signup_stats
      number_of_creators, total_made = $redis.mget(RedisKey.number_of_creators, RedisKey.total_made)
      LAST_SIGNUP_STATS.replace(number_of_creators:, total_made:)
      [number_of_creators, total_made]
    rescue *REDIS_TRANSPORT_ERRORS
      [LAST_SIGNUP_STATS[:number_of_creators], LAST_SIGNUP_STATS[:total_made]]
    end

    def retrieve_team_invitation_email(next_path)
      # Do not prefill email unless it matches the team invitation accept path
      return unless next_path&.start_with?("/settings/team/invitations")

      Rack::Utils.parse_nested_query(URI.parse(next_path.to_s).query).dig("email")
    end
end
