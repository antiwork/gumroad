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

    # Allow cross-origin access to all webpack-generated files
    allow do
      origins ["gumroad.dev", "app.gumroad.dev"]
      resource "/packs/*",
               headers: :any,
               methods: [:get, :options],
               credentials: false
    end

    # Allow cross-origin access to all assets
    allow do
      origins ["gumroad.dev", "app.gumroad.dev"]
      resource "/assets/*",
               headers: :any,
               methods: [:get, :options],
               credentials: false
    end

    # Allow cross-origin access for all resources in development
    allow do
      origins ["gumroad.dev", "app.gumroad.dev"]
      resource "*",
               headers: :any,
               methods: [:get, :post, :put, :delete, :options],
               credentials: false
    end
  end
end
