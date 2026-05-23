# frozen_string_literal: true

# Ref: https://eliotsykes.com/2017/03/08/realistic-error-responses/
# Useful for rendering true 404 responses in request specs, for example.
module ErrorResponses
  def respond_without_detailed_exceptions
    env_config = Rails.application.env_config
    original_show_exceptions = env_config["action_dispatch.show_exceptions"]
    original_show_detailed_exceptions = env_config["action_dispatch.show_detailed_exceptions"]
    env_config["action_dispatch.show_exceptions"] = true
    env_config["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    env_config["action_dispatch.show_exceptions"] = original_show_exceptions
    env_config["action_dispatch.show_detailed_exceptions"] = original_show_detailed_exceptions
  end
end
