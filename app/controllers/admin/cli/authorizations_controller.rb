# frozen_string_literal: true

class Admin::Cli::AuthorizationsController < Admin::BaseController
  CALLBACK_URL_PATTERN = %r{\Ahttp://(127\.0\.0\.1|localhost):\d+(/.*)?\z}

  def show
    authorization_request = authorization_request_params
    return render_invalid_authorization_request unless valid_authorization_request?(authorization_request)

    set_meta_tag(title: "Authorize CLI")

    render inertia: "Admin/Cli/Authorizations/Show", props: authorization_request.merge(
      actor: serialize_actor(current_user),
      authorization_request: signed_authorization_request(authorization_request),
      authorize_path: admin_cli_authorize_path
    )
  end

  def create
    authorization_request = verified_authorization_request
    return render_invalid_authorization_request unless valid_authorization_request?(authorization_request)
    return render_invalid_authorization_request unless authorization_request_matches_params?(authorization_request)

    authorization_code = AdminApiAuthorizationCode.create_for!(
      actor_user: current_user,
      code_challenge: authorization_request[:code_challenge]
    )

    redirect_to callback_url_with_authorization_code(authorization_request[:callback], authorization_code, authorization_request[:state]),
                allow_other_host: true,
                status: :see_other
  end

  private
    def authorization_request_params
      params.permit(:callback, :state, :code_challenge).to_h.with_indifferent_access
    end

    def valid_authorization_request?(authorization_request)
      authorization_request.present? &&
        authorization_request[:callback].to_s.match?(CALLBACK_URL_PATTERN) &&
        authorization_request[:state].present? &&
        authorization_request[:code_challenge].present?
    end

    def authorization_request_matches_params?(authorization_request)
      authorization_request_params.slice(:callback, :state, :code_challenge) == authorization_request.slice(:callback, :state, :code_challenge)
    end

    def signed_authorization_request(authorization_request)
      authorization_request_verifier.generate(authorization_request.slice(:callback, :state, :code_challenge))
    end

    def verified_authorization_request
      payload = authorization_request_verifier.verified(params[:authorization_request].to_s)
      return nil unless payload.is_a?(Hash)

      payload.with_indifferent_access
    end

    def authorization_request_verifier
      Rails.application.message_verifier("admin_cli_authorization")
    end

    def callback_url_with_authorization_code(callback, authorization_code, state)
      uri = URI.parse(callback)
      query_params = Rack::Utils.parse_nested_query(uri.query).merge("code" => authorization_code, "state" => state)
      uri.query = query_params.to_query
      uri.to_s
    end

    def serialize_actor(actor)
      {
        name: actor.name.presence || actor.email,
        email: actor.email
      }
    end

    def render_invalid_authorization_request
      render plain: "Invalid CLI authorization request", status: :unprocessable_entity
    end
end
