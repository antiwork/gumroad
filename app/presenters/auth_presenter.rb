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
      recaptcha_site_key: GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY"),
    }
  end

  def signup_props
    referrer = User.find_by_username(params[:referrer]) if params[:referrer].present?
    number_of_creators, total_made = $redis.mget(RedisKey.number_of_creators, RedisKey.total_made)
    login_props.merge(
      recaptcha_site_key: GlobalConfig.get("RECAPTCHA_SIGNUP_SITE_KEY"),
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
    def retrieve_team_invitation_email(next_path)
      # Do not prefill email unless it matches the team invitation accept path
      return unless next_path&.start_with?("/settings/team/invitations")

      Rack::Utils.parse_nested_query(URI.parse(next_path.to_s).query).dig("email")
    end
end
