# frozen_string_literal: true

# Allow requests from all origins to API domain
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "*"
    resource "*",
             headers: :any,
             methods: [:get, :post, :put, :delete],
             if: proc { |env| VALID_API_REQUEST_HOSTS.include?(env["HTTP_HOST"]) }
  end

  allow do
    origins VALID_CORS_ORIGINS
    resource "/users/session_info",
             headers: :any,
             methods: [:get]
  end

  if Rails.env.development? || Rails.env.test?
    allow do
      origins "*"
      resource "/assets/ABCFavorit-Regular*"
    end
  end
end
