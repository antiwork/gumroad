# frozen_string_literal: true

class Api::V2::MetaController < Api::V2::BaseController
  before_action -> { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }

  API_DOCUMENTATION_URL = "https://app.gumroad.com/api"

  def show
    render_response(
      true,
      user: { id: current_resource_owner.external_id },
      token: {
        scopes: doorkeeper_token.scopes.to_a,
        application_name: doorkeeper_token.application&.name,
      },
      api: {
        version: "v2",
        documentation_url: API_DOCUMENTATION_URL,
      }
    )
  end
end
