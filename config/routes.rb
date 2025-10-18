# frozen_string_literal: true

require "api_domain_constraint"
require "product_custom_domain_constraint"
require "user_custom_domain_constraint"
require "gumroad_domain_constraint"
require "discover_domain_constraint"
require "discover_taxonomy_constraint"
require "sidekiq/cron/web"
require "sidekiq_unique_jobs/web"

if defined?(Sidekiq::Pro)
  require "sidekiq/pro/web"
else
  require "sidekiq/web"
end

Rails.application.routes.draw do
  get "/healthcheck" => "healthcheck#index"
  get "/healthcheck/sidekiq" => "healthcheck#sidekiq"

  use_doorkeeper do
    controllers applications: "oauth/applications"
    controllers authorized_applications: "oauth/authorized_applications"
    controllers authorizations: "oauth/authorizations"
    controllers tokens: "oauth/tokens"
  end

  # third party analytics (near the top to matches constraint first)
  constraints(host: /#{THIRD_PARTY_ANALYTICS_DOMAIN}/o) do
    get "/:link_id", to: "third_party_analytics#index", as: :third_party_analytics
    get "/(*path)", to: "application#e404_page"
  end

  # API routes used in both api.gumroad.com and gumroad.com/api
  def api_routes
    scope "v2", module: "v2", as: "v2" do
      resources :licenses, only: [] do
        collection do
          post :verify
          put :enable
          put :disable
          put :decrement_uses_count
        end
      end

      get "/user", to: "users#show"
      resources :links, path: "products", only: [:index, :show, :update, :create, :destroy] do
        resources :custom_fields, only: [:index, :create, :update, :destroy]
        resources :offer_codes, only: [:index, :create, :show, :update, :destroy]
        resources :variant_categories, only: [:index, :create, :show, :update, :destroy] do
          resources :variants, only: [:index, :create, :show, :update, :destroy]
        end
        resources :skus, only: [:index]
        resources :subscribers, only: [:index]
        member do
          put "disable"
          put "enable"
        end
      end
      resources :sales, only: [:index, :show] do
        member do
          put :mark_as_shipped
          put :refund
          post :resend_receipt
        end
      end
      resources :payouts, only: [:index, :show]
      resources :subscribers, only: [:show]

      put "/resource_subscriptions", to: "resource_subscriptions#create"
      delete "/resource_subscriptions/:id", to: "resource_subscriptions#destroy"
      get "/resource_subscriptions", to: "resource_subscriptions#index"
    end
  end

  def product_tracking_routes(named_routes: true)
    resources :links, only: :create do
      member do
        # Conditionally defining named routed since we can define it only once.
        # Defining it again leads to an error.
        if named_routes
          post :track_user_action, as: :track_user_action
          post :increment_views, as: :increment_views
        else
          post :track_user_action
          post :increment_views
        end
      end
    end
  end

  def product_info_and_purchase_routes(named_routes: true)
    product_tracking_routes(named_routes:)

    get "/offer_codes/compute_discount", to: "offer_codes#compute_discount"
    get "/products/search", to: "links#search"

    if named_routes
      get "/braintree/client_token", to: "braintree#client_token", as: :braintree_client_token
      get "/purchases/:id/generate_invoice", to: "purchases#generate_invoice", as: :generate_invoice_by_buyer
      get "/purchases/:id/generate_invoice/confirm", to: "purchases#confirm_generate_invoice", as: :confirm_generate_invoice
      post "/purchases/:id/send_invoice", to: "purchases#send_invoice", as: :send_invoice
    else
      get "/braintree/client_token", to: "braintree#client_token"
      get "/purchases/:id/generate_invoice/confirm", to: "purchases#confirm_generate_invoice"
      get "/purchases/:id/generate_invoice", to: "purchases#generate_invoice"
      post "/purchases/:id/send_invoice", to: "purchases#send_invoice"
    end

    post "/braintree/generate_transient_customer_token", to: "braintree#generate_transient_customer_token"

    resource :paypal, controller: :paypal, only: [] do
      collection do
        post :billing_agreement_token
        post :billing_agreement
        post :order
        get :fetch_order
        post :update_order
      end
    end

    post "/events/track_user_action", to: "events#create"

    resources :purchases, only: [] do
      member do
        post :confirm
      end
    end

    resources :orders, only: [:create] do
      member do
        post :confirm
      end
    end

    namespace :stripe do
      resources :setup_intents, only: :create
    end

    post "/shipments/verify_shipping_address", to: "shipments#verify_shipping_address"

    # discover/autocomplete_search
    get "/discover_search_autocomplete", to: "discover/search_autocomplete#search"
    delete "/discover_search_autocomplete", to: "discover/search_autocomplete#delete_search_suggestion"

    put "/links/:id/sections", to: "links#update_sections"
  end

  constraints DiscoverDomainConstraint do
    get "/", to: "home#about"

    get "/discover", to: "discover#index"
    get "/discover/recommended_products", to: "discover#recommended_products", as: :discover_recommended_products
    namespace :discover do
      resources :recommended_wishlists, only: [:index]
    end

    product_info_and_purchase_routes

    constraints DiscoverTaxonomyConstraint do
      get "/*taxonomy", to: "discover#index", as: :discover_taxonomy
    end

    get "/animation(*path)", to: redirect { |_, req| req.fullpath.sub("animation", "3d") }
  end

  # embeddable js
  scope "js" do
    get "/gumroad", to: "embedded_javascripts#overlay"
    get "/gumroad-overlay", to: "embedded_javascripts#overlay"
    get "/gumroad-embed", to: "embedded_javascripts#embed"
    get "/gumroad-multioverlay", to: "embedded_javascripts#overlay"
  end

  # UTM link tracking
  get "/u/:permalink", to: "utm_link_tracking#show"

  # Configure redirections in development environment
  if Rails.env.development? || Rails.env.test?
    # redirect SHORT_DOMAIN to DOMAIN
    constraints(host_with_port: SHORT_DOMAIN) do
      match "/(*path)" => redirect { |_params, request| "#{UrlService.domain_with_protocol}/l#{request.fullpath}" }, via: [:get, :post]
    end
  end

  constraints ApiDomainConstraint do
    scope module: "api", as: "api" do
      api_routes
      scope "mobile", module: "mobile", as: "mobile" do
        devise_scope :user do
          post "forgot_password", to: "/user/passwords#create"
        end
        get "/purchases/index", to: "purchases#index"
        get "/purchases/search", to: "purchases#search"
        get "/purchases/purchase_attributes/:id", to: "purchases#purchase_attributes"
        post "/purchases/:id/archive", to: "purchases#archive"
        post "/purchases/:id/unarchive", to: "purchases#unarchive"
        get "/url_redirects/get_url_redirect_attributes/:id", to: "url_redirects#url_redirect_attributes"
        get "/url_redirects/fetch_placeholder_products", to: "url_redirects#fetch_placeholder_products"
        get "/url_redirects/stream/:token/:product_file_id", to: "url_redirects#stream", as: :stream_video
        get "/url_redirects/hls_playlist/:token/:product_file_id/index.m3u8", to: "url_redirects#hls_playlist", as: :hls_playlist
        get "/url_redirects/download/:token/:product_file_id", to: "url_redirects#download", as: :download_product_file
        get "/subscriptions/subscription_attributes/:id", to: "subscriptions#subscription_attributes", as: :subscription_attributes
        get "/preorders/preorder_attributes/:id", to: "preorders#preorder_attributes", as: :preorder_attributes
        resources :sales, only: [:show] do
          member do
            patch :refund
          end
        end
        resources :analytics, only: [] do
          collection do
            get :data_by_date
            get :revenue_totals
            get :by_date
            get :by_state
            get :by_referral
            get :products
          end
        end
        resources :devices, only: :create
        resources :installments, only: :show
        resources :consumption_analytics, only: [:create], format: :json
        resources :media_locations, only: [:create], format: :json
        resources :sessions, only: [:create], format: :json
        resources :feature_flags, only: [:show], format: :json
      end

      namespace :internal do
        resources :home_page_numbers, only: :index
        namespace :helper do
          post :webhook, to: "webhook#handle"

          resources :users, only: [] do
            collection do
              get :user_info
              post :create_appeal
              post :user_suspension_info
              post :send_reset_password_instructions
              post :update_email
              post :update_two_factor_authentication_enabled
            end
          end

          resources :purchases, only: [] do
            collection do
              post :refund_last_purchase
              post :resend_last_receipt
              post :resend_all_receipts
              post :resend_receipt_by_number
              post :search
              post :reassign_purchases
              post :auto_refund_purchase
              post :refund_taxes_only
            end
          end

          resources :payouts, only: [:index, :create]
          resources :instant_payouts, only: [:index, :create]
          resources :openapi, only: :index
        end

        namespace :iffy do
          post :webhook, to: "webhook#handle"
        end

        namespace :grmc do
          post :webhook, to: "webhook#handle"
        end
      end
    end
  end

  get "/s3_utility/cdn_url_for_blob", to: "s3_utility#cdn_url_for_blob"
  get "/s3_utility/current_utc_time_string", to: "s3_utility#current_utc_time_string"
  get "/s3_utility/generate_multipart_signature", to: "s3_utility#generate_multipart_signature"

  constraints GumroadDomainConstraint do
    get "/about", to: "home#about"
    get "/features", to: "home#features"
    get "/pricing", to: "home#pricing"
    get "/terms", to: "home#terms"
    get "/prohibited", to: "home#prohibited"
    get "/privacy", to: "home#privacy"
    get "/taxes", to: redirect("/pricing", status: 301)
    get "/hackathon", to: "home#hackathon"
    get "/small-bets", to: "home#small_bets"
    resource :github_stars, only: [:show]

    namespace :gumroad_blog, path: "blog" do
      root to: "posts#index"
      resources :posts, only: [:index, :show], param: :slug, path: "p"
    end

    namespace :help_center, path: "help" do
      root to: "articles#index"

      # Custom singular `path` name for backwards compatibility with old routes
      # for SEO.
      resources :articles, only: [:index, :show], param: :slug, path: "article"
      resources :categories, only: [:show], param: :slug, path: "category"
    end

    get "/ifttt/v1/status" => "api/v2/users#ifttt_status"
    get "/ifttt/v1/oauth2/authorize/:code(.:format)" => "oauth/authorizations#show"
    get "/ifttt/v1/oauth2/authorize(.:format)" => "oauth/authorizations#new"
    post "/ifttt/v1/oauth2/token(.:format)" => "oauth/tokens#create"
    get "/ifttt/v1/user/info" => "api/v2/users#show", is_ifttt: true
    post "/ifttt/v1/triggers/sale" => "api/v2/users#ifttt_sale_trigger"

    get "/notion/oauth2/authorize(.:format)" => "oauth/notion/authorizations#new"
    post "/notion/oauth2/token(.:format)" => "oauth/tokens#create"
    post "/notion/unfurl" => "api/v2/notion_unfurl_urls#create"
    delete "/notion/unfurl" => "api/v2/notion_unfurl_urls#destroy"

    # legacy routes
    get "users/password/new" => redirect("/login")

    # /robots.txt
    get "/robots.:format" => "robots#index"

    # users (logins/signups and other goodies)
    devise_for(:users,
               controllers: {
                 sessions: "logins",
                 registrations: "signup",
                 confirmations: "confirmations",
                 omniauth_callbacks: "user/omniauth_callbacks",
                 passwords: "user/passwords"
               })

    devise_scope :user do
      get "signup", to: "signup#new", as: :signup
      post "signup", to: "signup#create"
      post "save_to_library", to: "signup#save_to_library", as: :save_to_library
      post "add_purchase_to_library", to: "users#add_purchase_to_library", as: :add_purchase_to_library

      get "login", to: "logins#new"
      get "/oauth/login" => "logins#new"

      post "login", to: "logins#create"
      get "logout", to: "logins#destroy" # TODO: change the method to DELETE to conform to REST
      post "forgot_password", to: "user/passwords#create"
      scope "/users" do
        get "/check_twitter_link", to: "users/oauth#check_twitter_link"
        get "/unsubscribe/:id", to: "users#email_unsubscribe", as: :user_unsubscribe
        get "/unsubscribe_review_reminders", to: "users#unsubscribe_review_reminders", as: :user_unsubscribe_review_reminders
        get "/subscribe_review_reminders", to: "users#subscribe_review_reminders", as: :user_subscribe_review_reminders
      end
    end

    namespace :sellers do
      resource "switch", only: :create, controller: "switch"
    end

    resources :test_pings, only: [:create]

    # followers
    resources :followers, only: [:index, :destroy], format: :json do
      collection do
        get "search"
      end
    end

    post "/follow_from_embed_form", to: "followers#from_embed_form", as: :follow_user_from_embed_form
    post "/follow", to: "followers#create", as: :follow_user
    get "/follow/:id/cancel", to: "followers#cancel", as: :cancel_follow
    get "/follow/:id/confirm", to: "followers#confirm", as: :confirm_follow

    namespace :affiliate_requests do
      resource :onboarding_form, only: [:update], controller: :onboarding_form do
        get :show, to: redirect("/affiliates/onboarding")
      end
    end
    resources :affiliate_requests, only: [:update] do
      member do
        get :approve
        get :ignore
      end
      collection do
        post :approve_all
      end
    end
    resources :affiliates, only: [:index] do
      member do
        get :subscribe_posts
        get :unsubscribe_posts
      end
      collection do
        get :export
      end
    end
    resources :collaborators, only: [:index]
    # Routes handled by react-router. Non-catch-all routes are declared to
    # generate URL helpers.
    get "/collaborators/incomings", to: "collaborators#index"
    get "/collaborators/*other", to: "collaborators#index"

    get "/affiliates/*other", to: "affiliates#index" # route handled by react-router
    get "/workflows/*other", to: "workflows#index" # route handled by react-router
    get "/emails/*other", to: "emails#index" # route handled by react-router
    get "/dashboard/utm_links/*other", to: "utm_links#index" # route handled by react-router
    get "/communities/*other", to: "communities#index" # route handled by react-router

    get "/a/:affiliate_id", to: "affiliate_redirect#set_cookie_and_redirect", as: :affiliate_redirect
    get "/a/:affiliate_id/:unique_permalink", to: "affiliate_redirect#set_cookie_and_redirect", as: :affiliate_product
    post "/links/:id/send_sample_price_change_email", to: "links#send_sample_price_change_email", as: :sample_membership_price_change_email

    namespace :global_affiliates do
      resources :product_eligibility, only: [:show], param: :url, constraints: { url: /.*/ }
    end

    resources :tags, only: [:index]

    draw(:admin)

    post "/settings/store_facebook_token", to: "users/oauth#async_facebook_store_token", as: :ajax_facebook_access_token

    get "/settings/async_twitter_complete", to: "users/oauth#async_twitter_complete", as: :async_twitter_complete

    # user account settings stuff
    resource :settings, only: [] do
      resources :applications, only: [] do
        resources :access_tokens, only: :create, controller: "oauth/access_tokens"
      end
      get :profiles, to: redirect("/settings")
      resource :connections, only: [] do
        member do
          post :unlink_twitter
        end
      end
    end
    namespace :settings do
      resource :main, only: %i[show update], path: "", controller: "main" do
        post :resend_confirmation_email
      end
      resource :password, only: %i[show update], controller: "password"
      resource :profile, only: %i[show update], controller: "profile"
      resource :third_party_analytics, only: %i[show update], controller: "third_party_analytics"
      resource :advanced, only: %i[show update], controller: "advanced"
      resources :authorized_applications, only: :index
      resource :payments, only: %i[show update] do
        resource :verify_document, only: :create, controller: "payments/verify_document"
        resource :verify_identity, only: %i[show create], controller: "payments/verify_identity"
        get :remediation
        get :verify_stripe_remediation
        post :set_country
        post :opt_in_to_au_backtax_collection
        get :paypal_connect
        post :remove_credit_card
      end
      resource :stripe, controller: :stripe, only: [] do
        collection do
          post :disconnect
        end
      end
      resource :team, only: %i[show], controller: "team"
      namespace :team do
        scope format: true, constraints: { format: :json } do
          resources :invitations, only: %i[create update destroy] do
            get :accept, on: :member, format: nil
            put :resend_invitation, on: :member
            put :restore, on: :member
          end
          resources :members, only: %i[index update destroy] do
            put :restore, on: :member
          end
        end
      end
      resource :dismiss_ai_product_generation_promo, only: [:create]
    end

    resources :stripe_account_sessions, only: :create

    namespace :checkout do
      resources :discounts, only: %i[index create update destroy] do
        get :paged, on: :collection
        get :statistics, on: :member
      end
      resources :upsells, only: %i[index create update destroy] do
        get :paged, on: :collection
        get :cart_item, on: :collection
        get :statistics, on: :member

        scope module: :upsells do
          resource :pause, only: [:create, :destroy]
        end
      end
      namespace :upsells do
        resources :products, only: [:index, :show]
      end
      resource :form, only: %i[show update], controller: :form
    end

    resources :recommended_products, only: :index

    # purchases
    resources :purchases, only: [:update] do
      member do
        get :receipt
        get :confirm_receipt_email
        get :subscribe
        get :unsubscribe
        post :confirm
        post :change_can_contact
        post :resend_receipt
        post :send_invoice
        put :refund
        put :revoke_access
        put :undo_revoke_access
      end

      get :export, on: :collection
      # TODO: Remove when `:react_customers_page` is enabled
      post :export, on: :collection
      resources :pings, controller: "purchases/pings", only: [:create]
      resource :product, controller: "purchases/product", only: [:show]
      resources :variants, controller: "purchases/variants", param: :variant_id, only: [:update]
      resource :dispute_evidence, controller: "purchases/dispute_evidence", only: %i[show update]
    end

    resources :orders, only: [:create] do
      member do
        post :confirm
      end
    end

    # service charges
    resources :service_charges, only: :create do
      member do
        post :confirm
        get :generate_service_charge_invoice
        post :resend_receipt
        post :send_invoice
      end
    end

    # Two-Factor Authentication
    get "/two-factor", to: "two_factor_authentication#new", as: :two_factor_authentication

    # Enforce stricter formats to restrict people from bypassing Rack::Attack by using different formats in URL.
    scope format: true, constraints: { format: :json } do
      post "/two-factor", to: "two_factor_authentication#create"
      post "/two-factor/resend_authentication_token", to: "two_factor_authentication#resend_authentication_token", as: :resend_authentication_token
    end

    scope format: true, constraints: { format: :html } do
      get "/two-factor/verify", to: "two_factor_authentication#verify", as: :verify_two_factor_authentication
    end

    # library
    get "/library", to: "library#index", as: :library
    get "/library/purchase/:id", to: "library#index", as: :library_purchase
    get "/library/purchase/:purchase_id/update/:id", to: "posts#redirect_from_purchase_id", as: :redirect_from_purchase_id
    patch "/library/purchase/:id/archive", to: "library#archive", as: :library_archive
    patch "/library/purchase/:id/unarchive", to: "library#unarchive", as: :library_unarchive
    patch "/library/purchase/:id/delete", to: "library#delete", as: :library_delete

    # customers
    get "/customers/sales", controller: "customers", action: "customers_paged", format: "json", as: :sales_paged
    get "/customers", controller: "customers", action: "index", format: "html", as: :customers
    get "/customers/paged", controller: "customers", action: "paged", format: "json"
    get "/customers/:link_id", controller: "customers", action: "index", format: "html", as: :customers_link_id
    post "/customers/import", to: "customers#customers_import", as: :customers_import
    post "/customers/import_manually_entered_emails", to: "customers#customers_import_manually_entered_emails", as: :customers_import_manually_entered_emails
    get "/customers/charges/:purchase_id", to: "customers#customer_charges", as: :customer_charges
    get "/customers/customer_emails/:purchase_id", to: "customers#customer_emails", as: :customer_emails
    get "/customers/missed_posts/:purchase_id", to: "customers#missed_posts", as: :missed_posts
    get "/customers/product_purchases/:purchase_id", to: "customers#product_purchases", as: :product_purchases
    # imported customers
    get "/imported_customers", to: "imported_customers#index", as: :imported_customers
    delete "/imported_customers/:id", to: "imported_customers#destroy", as: :destroy_imported_customer
    get "/imported_customers/unsubscribe/:id", to: "imported_customers#unsubscribe", as: :unsubscribe_imported_customer

    # dropbox files
    get "/dropbox_files", to: "dropbox_files#index", as: "dropbox_files"
    post "/dropbox_files/create", to: "dropbox_files#create", as: "create_dropbox_file"
    post "/dropbox_files/cancel_upload/:id", to: "dropbox_files#cancel_upload", as: "cancel_dropbox_file_upload"

    get "/purchases" => redirect("/library")
    get "/purchases/search", to: "purchases#search"

    resources :checkout, only: [:index]

    resources :licenses, only: [:update]

    post "/preorders/:id/charge_preorder", to: "purchases#charge_preorder", as: "charge_preorder"

    resources :attachments, only: [:create]

    # users
    get "/users/current_user_data", to: "users#current_user_data", as: :current_user_data

    post "/users/deactivate", to: "users#deactivate", as: :deactivate_account

    # Used in Webflow site to change Login button to Dashboard button for signed in users
    get "/users/session_info", to: "users#session_info", as: :user_session_info

    post "/customer_surcharge/", to: "customer_surcharge#calculate_all", as: :customer_surcharges

    # links
    get "/l/product-name/offer-code" => redirect("/guide/basics/reach-your-audience#offers")

    get "/oauth_completions/stripe", to: "oauth_completions#stripe"

    resource :offer_codes, only: [] do
      get :compute_discount
    end

    resources :bundles, only: [:show, :update] do
      member do
        get "*other", to: "bundles#show"
        post :update_purchases_content
      end

      collection do
        get :products
        get :create_from_email
      end
    end

    resources :links, except: [:edit, :show, :update, :new] do
      resources :asset_previews, only: [:create, :destroy]

      resources :thumbnails, only: [:create, :destroy]
      resources :variants, only: [:index], controller: "products/variants"
      resource :mobile_tracking, only: [:show], path: "in_app", controller: "products/mobile_tracking"
      member do
        post :update
        post :publish
        post :unpublish
        post :increment_views
        post :track_user_action
        put :sections, action: :update_sections
      end
    end

    resources :product_duplicates, only: [:create, :show], format: :json
    put "/product_reviews/set", to: "product_reviews#set", format: :json
    resources :product_reviews, only: [:index, :show]
    resources :product_review_responses, only: [:update, :destroy], format: :json
    resources :product_review_videos, only: [] do
      scope module: :product_review_videos do
        resource :stream, only: [:show]
        resources :streaming_urls, only: [:index]
      end
    end
    namespace :product_review_videos do
      resource :upload_context, only: [:show]
    end

    resources :calls, only: [:update]

    resources :purchase_custom_fields, only: [:create]
    resources :commissions, only: [:update] do
      member do
        post :complete
      end
    end

    namespace :user do
      resource :invalidate_active_sessions, only: :update
    end

    get "/memberships/paged", to: "links#memberships_paged", as: :memberships_paged

    namespace :products do
      resources :affiliated, only: [:index]
      resources :collabs, only: [:index] do
        collection do
          get :products_paged
          get :memberships_paged
        end
      end
      resources :archived, only: %i[index create destroy] do
        collection do
          get :products_paged
          get :memberships_paged
        end
      end
    end

    resources :products, only: [:new], controller: "links" do
      scope module: :products, format: true, constraints: { format: :json } do
        resources :other_refund_policies, only: :index
        resources :remaining_call_availabilities, only: :index
      end
    end

    # TODO: move these within resources :products block above
    get "/products/paged", to: "links#products_paged", as: :products_paged
    get "/products/:id/edit", to: "links#edit", as: :edit_link
    get "/products/:id/edit/*other", to: "links#edit"
    get "/products/:id/card", to: "links#card", as: :product_card
    get "/products/search", to: "links#search"

    namespace :integrations do
      resources :circle, only: [], format: :json do
        collection do
          get :communities, as: :communities
          get :space_groups, as: :space_groups
          get :communities_and_space_groups, as: :communities_and_space_groups
        end
      end

      resources :discord, only: [], format: :json do
        collection do
          get :oauth_redirect
          get :server_info
          get :join_server
          get :leave_server
        end
      end

      resources :zoom, only: [] do
        collection do
          get :account_info
          get :oauth_redirect
        end
      end

      resources :google_calendar, only: [] do
        collection do
          get :account_info
          get :calendar_list
          get :oauth_redirect
        end
      end
    end

    get "/links/:id/edit" => redirect("/products/%{id}/edit")

    post "/products/:id/release_preorder", to: "links#release_preorder", as: :release_preorder


    get "/dashboard" => "dashboard#index", as: :dashboard
    get "/dashboard/customers_count" => "dashboard#customers_count", as: :dashboard_customers_count
    get "/dashboard/total_revenue" => "dashboard#total_revenue", as: :dashboard_total_revenue
    get "/dashboard/active_members_count" => "dashboard#active_members_count", as: :dashboard_active_members_count
    get "/dashboard/monthly_recurring_revenue" => "dashboard#monthly_recurring_revenue", as: :dashboard_monthly_recurring_revenue
    get "/dashboard/download_tax_form" => "dashboard#download_tax_form", as: :dashboard_download_tax_form

    get "/products", to: "links#index", as: :products
    get "/l/:id", to: "links#show", defaults: { format: "html" }, as: :short_link
    get "/l/:id/:code", to: "links#show", defaults: { format: "html" }, as: :short_link_offer_code
    get "/cart_items_count", to: "links#cart_items_count"

    get "/products/:id" => redirect("/l/%{id}")
    get "/product/:id" => redirect("/l/%{id}")
    get "/products/:id/:code" => redirect("/l/%{id}/%{code}")
    get "/product/:id/:code" => redirect("/l/%{id}/%{code}")

    # events
    post "/events/track_user_action", to: "events#create"

    # product files utility
    get "/product_files_utility/external_link_title", to: "product_files_utility#external_link_title", as: :external_link_title
    get "/product_files_utility/product_files/:product_id", to: "product_files_utility#download_product_files", as: :download_product_files
    get "/product_files_utility/folder_archive/:folder_id", to: "product_files_utility#download_folder_archive", as: :download_folder_archive

    # analytics
    get "/analytics" => redirect("/dashboard/sales")
    get "/dashboard/sales", to: "analytics#index", as: :sales_dashboard
    get "/analytics/data/by_date", to: "analytics#data_by_date", as: "analytics_data_by_date"
    get "/analytics/data/by_state", to: "analytics#data_by_state", as: "analytics_data_by_state"
    get "/analytics/data/by_referral", to: "analytics#data_by_referral", as: "analytics_data_by_referral"

    # audience
    get "/audience" => redirect("/dashboard/audience")
    get "/dashboard/audience", to: "audience#index", as: :audience_dashboard
    get "/audience/data/by_date/:start_time/:end_time", to: "audience#data_by_date", as: "audience_data_by_date"
    post "/audience/export", to: "audience#export", as: :audience_export
    get "/dashboard/consumption" => redirect("/dashboard/audience")

    # invoices
    get "/purchases/:id/generate_invoice/confirm", to: "purchases#confirm_generate_invoice"
    get "/purchases/:id/generate_invoice", to: "purchases#generate_invoice"

    # preorder
    post "/purchases/:id/cancel_preorder_by_seller", to: "purchases#cancel_preorder_by_seller", as: :cancel_preorder_by_seller

    # subscriptions
    get "/subscriptions/cancel_subscription/:id", to: redirect(path: "/subscriptions/%{id}/manage")
    get "/subscriptions/:id/cancel_subscription", to: redirect(path: "/subscriptions/%{id}/manage")
    get "/subscriptions/:id/edit_card", to: redirect(path: "/subscriptions/%{id}/manage")
    resources :subscriptions, only: [] do
      member do
        get :manage
        get :magic_link
        post :send_magic_link
        post :unsubscribe_by_user
        post :unsubscribe_by_seller
        put :update, to: "purchases#update_subscription"
      end
    end

    # posts
    post "/posts/:id/increment_post_views", to: "posts#increment_post_views", as: :increment_post_views
    post "/posts/:id/send_for_purchase/:purchase_id", to: "posts#send_for_purchase", as: :send_for_purchase

    # communities
    get "/communities(/:seller_id/:community_id)", to: "communities#index", as: :community

    # emails
    get "/emails", to: "emails#index", as: :emails
    get "/posts", to: redirect("/emails")

    # workflows
    get "/workflows", to: "workflows#index", as: :workflows

    # utm links
    get "/utm_links" => redirect("/dashboard/utm_links")
    get "/dashboard/utm_links", to: "utm_links#index", as: :utm_links_dashboard

    # shipments
    post "/shipments/verify_shipping_address", to: "shipments#verify_shipping_address", as: :verify_shipping_address
    post "/shipments/:purchase_id/mark_as_shipped", to: "shipments#mark_as_shipped", as: :mark_as_shipped

    # balances
    get "/payouts", to: "balance#index", as: :balance
    get "/payouts/payments", to: "balance#payments_paged", as: :payments_paged
    resources :instant_payouts, only: [:create]
    namespace :payouts do
      resources :exportables, only: [:index]
      resources :exports, only: [:create]
    end

    # wishlists
    namespace :wishlists do
      resources :following, only: [:index]
    end
    resources :wishlists, only: [:index, :create, :update, :destroy] do
      resources :products, only: [:create], controller: "wishlists/products"
      resource :followers, only: [:destroy], controller: "wishlists/followers" do
        get :unsubscribe
      end
    end

    resources :reviews, only: [:index]

    resources :support, only: [:index] do
      collection do
        post :create_unauthenticated_ticket
      end
    end

    # url redirects
    get "/r/:id/expired", to: "url_redirects#expired", as: :url_redirect_expired_page
    get "/r/:id/rental_expired", to: "url_redirects#rental_expired_page", as: :url_redirect_rental_expired_page
    get "/r/:id/membership_inactive", to: "url_redirects#membership_inactive_page", as: :url_redirect_membership_inactive_page
    get "/r/:id/check_purchaser", to: "url_redirects#check_purchaser", as: :url_redirect_check_purchaser
    get "/r/:id/:product_file_id/stream.smil", to: "url_redirects#smil", as: :url_redirect_smil_for_product_file
    get "/r/:id/:product_file_id/index.m3u8", to: "url_redirects#hls_playlist", as: :hls_playlist_for_product_file
    get "/r/:id", to: "url_redirects#show", as: :url_redirect
    get "/r/:id/product_files", to: "url_redirects#download_product_files", as: :url_redirect_download_product_files
    get "/zip/:id", to: "url_redirects#download_archive", as: :url_redirect_download_archive
    get "/r/:id/:product_file_id/:subtitle_file_id", to: "url_redirects#download_subtitle_file", as: :url_redirect_download_subtitle_file
    get "/s/:id", to: "url_redirects#stream", as: :url_redirect_stream_page
    get "/s/:id/:product_file_id", to: "url_redirects#stream", as: :url_redirect_stream_page_for_product_file
    get "/latest_media_locations/:id", to: "url_redirects#latest_media_locations", as: :url_redirect_latest_media_locations
    get "/audio_durations/:id", to: "url_redirects#audio_durations", as: :url_redirect_audio_durations
    get "/media_urls/:id", to: "url_redirects#media_urls", as: :url_redirect_media_urls

    get "/read", to: "library#index"
    get "/read/:id", to: "url_redirects#read", as: :url_redirect_read
    get "/read/:id/:product_file_id", to: "url_redirects#read", as: :url_redirect_read_for_product_file

    get "/d/:id", to: "url_redirects#download_page", as: :url_redirect_download_page
    get "/confirm", to: "url_redirects#confirm_page", as: :confirm_page
    post "/confirm-redirect", to: "url_redirects#confirm"
    post "/r/:id/send_to_kindle", to: "url_redirects#send_to_kindle", as: :send_to_kindle
    post "/r/:id/change_purchaser", to: "url_redirects#change_purchaser", as: :url_redirect_change_purchaser

    get "crossdomain", to: "public#crossdomain"

    get "/api", to: "public#api"

    # old API route
    namespace "api" do
      api_routes
    end

    # developers pages
    scope "developers" do
      get "/", to: "public#developers", as: "developers"
    end

    scope "api" do
      get "/", to: "public#api"
    end

    # React Router routes
    scope module: :api, defaults: { format: :json } do
      namespace :internal do
        resources :affiliates, only: [:index, :show, :create, :update, :destroy] do
          collection do
            get :onboarding
          end
          get :statistics, on: :member
        end

        resources :collaborators, only: [:index, :new, :create, :edit, :update, :destroy] do
          scope module: :collaborators do
            resources :invitation_acceptances, only: [:create]
            resources :invitation_declines, only: [:create]
          end
        end
        namespace :collaborators do
          resources :incomings, only: [:index]
        end

        resources :workflows, only: [:index, :new, :create, :edit, :update, :destroy] do
          put :save_installments, on: :member
        end
        resources :installments, only: [:index, :new, :edit, :create, :update, :destroy] do
          member do
            resource :audience_count, only: [:show], controller: "installments/audience_counts", as: :installment_audience_count
            resource :preview_email, only: [:create], controller: "installments/preview_emails", as: :installment_preview_email
          end
          collection do
            resource :recipient_count, only: [:show], controller: "installments/recipient_counts", as: :installment_recipient_count
          end
        end
        resource :cart, only: [:update]
        resources :products, only: [:show] do
          resources :product_posts, only: [:index]
          resources :existing_product_files, only: [:index]
        end
        resources :utm_links, only: [:index, :new, :create, :edit, :update, :destroy] do
          collection do
            resource :unique_permalink, only: [:show], controller: "utm_links/unique_permalinks", as: :utm_link_unique_permalink
            resources :stats, only: [:index], controller: "utm_links/stats", as: :utm_links_stats
          end
        end
        resources :product_public_files, only: [:create]
        resources :communities, only: [:index] do
          resources :chat_messages, only: [:index, :create, :update, :destroy], controller: "communities/chat_messages", as: "chat_messages"
          resource :last_read_chat_message, only: [:create], controller: "communities/last_read_chat_messages"
          resource :notification_setting, only: [:update], controller: "communities/notification_settings", as: "notification_setting"
        end

        resources :product_review_videos, only: [] do
          scope module: :product_review_videos do
            resources :approvals, only: [:create]
            resources :rejections, only: [:create]
          end
        end

        resources :ai_product_details_generations, only: [:create]
      end
    end

    post "/working-webhook", to: "public#working_webhook"

    get "/ping", to: "public#ping", as: "ping"
    get "/webhooks", to: redirect("/ping")
    get "/widgets", to: "public#widgets", as: "widgets"
    get "/overlay" => redirect("/widgets")
    get "/embed" => redirect("/widgets")
    get "/modal" => redirect("/widgets")
    get "/button" => redirect("/widgets")
    get "/charge", to: "public#charge", as: "charge"
    get "/license-key-lookup", to: "public#license_key_lookup"
    get "/charge_data", to: "public#charge_data", as: :charge_data
    get "/paypal_charge_data", to: "public#paypal_charge_data", as: :paypal_charge_data
    get "/CHARGE" => redirect("/charge")

    # discover
    get "/discover", to: "discover#index"
    get "/discover/categories",          to: "discover#categories"
    get "/discover_search_autocomplete", to: "discover/search_autocomplete#search"

    root to: "public#home"

    resources :consumption_analytics, only: [:create], format: :json
    resources :media_locations, only: [:create], format: :json

    # webhook providers
    post "/stripe-webhook", to: "foreign_webhooks#stripe"
    post "/stripe-connect-webhook", to: "foreign_webhooks#stripe_connect"
    post "/paypal-webhook", to: "foreign_webhooks#paypal"
    post "/sendgrid-webhook", to: "foreign_webhooks#sendgrid"
    post "/sns-webhook", to: "foreign_webhooks#sns"
    post "/sns-mediaconvert-webhook", to: "foreign_webhooks#mediaconvert"
    post "/sns-aws-config-webhook", to: "foreign_webhooks#sns_aws_config"
    post "/grmc-webhook", to: "foreign_webhooks#grmc"
    post "/resend-webhook", to: "foreign_webhooks#resend"

    # secure redirect
    get "/secure_url_redirect", to: "secure_redirect#new", as: :secure_url_redirect
    post "/secure_url_redirect", to: "secure_redirect#create"

    # TODO (chris): review and replace usage of routes below with UserCustomDomainConstraint routes
    get "/:username", to: "users#show", as: "user"
    get "/:username/follow", to: "followers#new", as: "follow_user_page"
    get "/:username/p/:slug", to: "posts#show", as: :view_post
    get "/:username/posts_paginated", to: "users/posts#paginated", as: "user_posts_paginated"
    get "/:username/posts", to: redirect("/%{username}")
    get "/:username/subscribe_preview", to: "users#subscribe_preview", as: :user_subscribe_preview
    get "/:username/updates", to: redirect("/%{username}/posts")
    get "/:username/affiliates", to: "affiliate_requests#new", as: :new_affiliate_request

    # braintree
    get "/braintree/client_token", to: "braintree#client_token"
    post "/braintree/generate_transient_customer_token", to: "braintree#generate_transient_customer_token", as: :generate_braintree_transient_customer_token

    resource :paypal, controller: :paypal, only: [] do
      collection do
        get :connect
        post :disconnect
        post :billing_agreement_token
        post :billing_agreement
        post :order
        get :fetch_order
        post :update_order
      end
    end

    namespace :stripe do
      resources :setup_intents, only: :create
    end

    namespace :custom_domain do
      resources :verifications, only: :create, path: "verify"
    end

    # test endpoints used by pingdom and alike
    get "/_/test/outgoing_traffic", to: "test#outgoing_traffic"

    get "/(*path)", to: "application#e404_page" unless Rails.env.development?
  end

  # The following constraints will only catch non-gumroad domains as any domain owned by gumroad will be caught by the GumroadDomainConstraint
  constraints ProductCustomDomainConstraint do
    product_tracking_routes(named_routes: false)
    get "/", to: "links#show", defaults: { format: "html" }
  end

  constraints UserCustomDomainConstraint do
    product_info_and_purchase_routes(named_routes: false)
    devise_scope :user do
      post "signup", to: "signup#create"
      post "save_to_library", to: "signup#save_to_library"
      post "add_purchase_to_library", to: "users#add_purchase_to_library"
    end
    post "/posts/:id/increment_post_views", to: "posts#increment_post_views"
    get "/p/:slug", to: "posts#show", as: :custom_domain_view_post
    get "/:username/posts_paginated", to: "users/posts#paginated"
    get "/posts", to: redirect("/")
    get "/posts/:post_id/comments", to: "comments#index", as: :custom_domain_post_comments
    post "/posts/:post_id/comments", to: "comments#create", as: :custom_domain_create_post_comment
    put "/posts/:post_id/comments/:id", to: "comments#update", as: :custom_domain_update_post_comment
    delete "/posts/:post_id/comments/:id", to: "comments#destroy", as: :custom_domain_delete_post_comment
    get "/affiliates", to: "affiliate_requests#new", as: :custom_domain_new_affiliate_request
    post "/affiliate_requests", to: "affiliate_requests#create", as: :custom_domain_create_affiliate_request
    get "/updates", to: redirect("/posts")
    get "/l/:id", to: "links#show", defaults: { format: "html" }
    get "/l/:id/:code", to: "links#show", defaults: { format: "html" }
    get "/subscribe", to: "users#subscribe", as: :custom_domain_subscribe
    get "/follow", to: redirect("/subscribe")
    get "/coffee", to: "users#coffee", as: :custom_domain_coffee

    # url redirects
    get "/r/:id/expired", to: "url_redirects#expired", as: :custom_domain_url_redirect_expired_page
    get "/r/:id/rental_expired", to: "url_redirects#rental_expired_page", as: :custom_domain_url_redirect_rental_expired_page
    get "/r/:id/membership_inactive", to: "url_redirects#membership_inactive_page", as: :custom_domain_url_redirect_membership_inactive_page
    get "/r/:id/check_purchaser", to: "url_redirects#check_purchaser", as: :custom_domain_url_redirect_check_purchaser
    get "/r/:id/:product_file_id/stream.smil", to: "url_redirects#smil", as: :custom_domain_url_redirect_smil_for_product_file
    get "/r/:id/:product_file_id/index.m3u8", to: "url_redirects#hls_playlist", as: :custom_domain_hls_playlist_for_product_file
    get "/r/:id", to: "url_redirects#show", as: :custom_domain_url_redirect
    get "/r/:id/product_files", to: "url_redirects#download_product_files", as: :custom_domain_url_redirect_download_product_files
    get "/zip/:id", to: "url_redirects#download_archive", as: :custom_domain_url_redirect_download_archive
    get "/r/:id/:product_file_id/:subtitle_file_id", to: "url_redirects#download_subtitle_file", as: :custom_domain_url_redirect_download_subtitle_file
    get "/s/:id", to: "url_redirects#stream", as: :custom_domain_url_redirect_stream_page
    get "/s/:id/:product_file_id", to: "url_redirects#stream", as: :custom_domain_url_redirect_stream_page_for_product_file

    get "/read", to: "library#index"
    get "/read/:id", to: "url_redirects#read", as: :custom_domain_url_redirect_read
    get "/read/:id/:product_file_id", to: "url_redirects#read", as: :custom_domain_url_redirect_read_for_product_file

    get "/d/:id", to: "url_redirects#download_page", as: :custom_domain_download_page
    get "/confirm", to: "url_redirects#confirm_page", as: :custom_domain_confirm_page
    post "/confirm-redirect", to: "url_redirects#confirm"
    post "/r/:id/send_to_kindle", to: "url_redirects#send_to_kindle", as: :custom_domain_send_to_kindle
    post "/r/:id/change_purchaser", to: "url_redirects#change_purchaser", as: :custom_domain_url_redirect_change_purchaser

    get "/library", to: "library#index"
    patch "/library/purchase/:id/archive", to: "library#archive"
    patch "/library/purchase/:id/unarchive", to: "library#unarchive"

    resources :products, only: [] do
      scope module: :products, format: true, constraints: { format: :json } do
        resources :remaining_call_availabilities
      end
    end

    namespace :integrations do
      resources :discord, only: [], format: :json do
        collection do
          get :oauth_redirect
          get :join_server
          get :leave_server
        end
      end
    end

    namespace :settings do
      resource :profile, only: %i[update], controller: "profile" do
        resources :products, only: :show, controller: "profile/products"
      end
    end

    resource :follow, controller: "followers", only: :create do
      member do
        get "/:id/cancel", to: "followers#cancel"
        get "/:id/confirm", to: "followers#confirm"
      end
    end

    resources :consumption_analytics, only: [:create], format: :json
    resources :media_locations, only: [:create], format: :json

    resources :purchases, only: [:update] do
      member do
        post :resend_receipt
      end
    end

    resources :wishlists, only: [:index, :create, :show, :update] do
      resources :products, only: [:create, :destroy, :index], controller: "wishlists/products"
      resource :followers, only: [:create, :destroy], controller: "wishlists/followers"
    end

    resources :profile_sections, only: [:create, :update, :destroy]

    get "/", to: "users#show"
  end

  put "/product_reviews/set", to: "product_reviews#set", format: :json

  resources :product_reviews, only: [:index, :show]
  resources :product_review_responses, only: [:update, :destroy], format: :json
  resources :product_review_videos, only: [] do
    scope module: :product_review_videos do
      resource :stream, only: [:show]
      resources :streaming_urls, only: [:index]
    end
  end
  namespace :product_review_videos do
    resource :upload_context, only: [:show]
  end

  namespace :checkout do
    namespace :upsells do
      resources :products, only: [:index, :show]
    end
  end

  get "/(*path)", to: "application#e404_page" unless Rails.env.development?
end
