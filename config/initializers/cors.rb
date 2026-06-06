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
    origins "*"
    resource "/l/*.json",
             headers: :any,
             methods: [:get]
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
      resource "/fonts/ABCFavorit-Regular*"
    end
  end

  if Rails.env.development?
    # Allow XHRs across *.localhost subdomains (e.g. localhost:3000 fetching
    # seller.localhost:3000) since each subdomain is its own browser origin.
    # In production the equivalent path doesn't run cross-origin in normal flows,
    # so this rule intentionally stays dev-only.
    allow do
      origins(/\Ahttps?:\/\/(?:[a-z0-9-]+\.)*localhost(?::\d+)?\z/)
      resource "*",
               headers: :any,
               methods: [:get, :post, :put, :patch, :delete, :options],
               credentials: true
    end
  end

  if ENV["CUSTOM_DOMAIN"].present?
    allow do
      origins ENV["CUSTOM_DOMAIN"]
      resource "*",
               headers: :any,
               methods: [:get, :post, :put, :patch, :delete, :options],
               credentials: true
    end
  end
end
