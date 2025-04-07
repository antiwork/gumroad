# frozen_string_literal: true

Rails.application.config.lograge.custom_options = lambda do |event|
  params = { remote_ip: event.payload[:remote_ip] }
  headers = event.payload[:headers]
  uuid = event.payload[:uuid]

  payload_params = event.payload[:params]

  if payload_params.present?
    if payload_params["controller"] == "logins" && payload_params["action"] == "create"
      if payload_params["user"]
        params[:login_identifier] = payload_params["user"]["login_identifier"]
        params[:login] = payload_params["user"]["login"]
      end
    end

    if payload_params["controller"] == "signup" && payload_params["action"] == "create"
      if payload_params["user"]
        params[:email] = payload_params.dig("user", "email")
        params[:buyer_signup] = payload_params.dig("user", "buyer_signup")
        params["g-recaptcha-response"] = payload_params["g-recaptcha-response"]
      end
    end
  end

  { "params" => params, "headers" => headers, "uuid" => uuid }
end
