# frozen_string_literal: true

namespace :admin do
  get "/", to: "base#index"
  get :impersonate, to: "base#impersonate"
  delete :unimpersonate, to: "base#unimpersonate"
  get :redirect_to_stripe_dashboard, to: "base#redirect_to_stripe_dashboard", as: :redirect_to_stripe_dashboard
  get "helper_actions/impersonate/:user_id", to: "helper_actions#impersonate", as: :impersonate_helper_action
  get "helper_actions/stripe_dashboard/:user_id", to: "helper_actions#stripe_dashboard", as: :stripe_dashboard_helper_action

  get "action_call_dashboard", to: "action_call_dashboard#index"

  resources :users, only: [:show, :destroy], defaults: { format: "html" } do
    scope module: :users do
      resource :impersonator, only: [:create, :destroy]
      resources :payouts, only: [:index, :show], shallow: true do
        collection do
          post :pause
          post :resume
          post :sync_all
        end
        member do
          post :retry
          post :cancel
          post :fail
          post :sync
        end
      end
    end
    resources :service_charges, only: :index
    member do
      post :add_credit
      post :mass_transfer_purchases
      post :probation_with_reminder
      post :refund_balance
      get :stats
      post :verify
      post :enable
      post :create_stripe_managed_account
      post :update_email
      post :reset_password
      post :confirm_email
      post :invalidate_active_sessions
      post :disable_paypal_sales
      post :mark_compliant
      post :mark_compliant_from_iffy
      post :suspend_for_fraud
      post :suspend_for_fraud_from_iffy
      post :flag_for_explicit_nsfw_tos_violation_from_iffy
      post :suspend_for_tos_violation
      post :put_on_probation
      post :flag_for_fraud
      post :set_custom_fee
      post :toggle_adult_products
    end
  end

  get "/users/:user_id/guids", to: "compliance/guids#index", as: :compliance_guids

  resource :block_email_domains, only: [:show, :update]
  resource :unblock_email_domains, only: [:show, :update]
  resource :suspend_users, only: [:show, :update]

  resources :affiliates, only: [:index, :show], defaults: { format: "html" }

  resources :links, only: [:show], defaults: { format: "html" } do
    member do
      get :access_product_file
      post :flag_seller_for_tos_violation
      get :generate_url_redirect
      post :is_adult
      post :publish
      post :unpublish
      get :join_discord
      get :join_discord_redirect
    end
  end

  resources :products, controller: "links", only: [:show, :destroy] do
    member do
      get "/file/:product_file_id/access", to: "links#access_product_file", as: :admin_access_product_file
      get :purchases
      get :views_count
      get :sales_stats
      post :restore
    end
    resource :staff_picked, only: [:create], controller: "products/staff_picked"
  end

  resources :payouts, only: [:index]
  resources :comments, only: :create

  resources :purchases, only: [:show] do
    member do
      post :refund
      post :refund_for_fraud
      post :refund_taxes_only
      post :cancel_subscription
      post "change_risk_state/:state", to: "purchases#change_risk_state", as: :change_risk_state
      post :resend_receipt
      post :sync_status_with_charge_processor
      post :update_giftee_email
      post :block_buyer
      post :unblock_buyer
    end
  end

  resources :sales_reports, only: [:index, :create]

  resources :merchant_accounts, only: [:show] do
    member do
      get :live_attributes
    end
  end

  # Payouts
  resources :payments, controller: "users/payouts", only: [:show]

  post "/paydays/pay_user/:id", to: "paydays#pay_user", as: :pay_user

  # Search
  get "/search_users", to: "search#users", as: :search_users
  get "/search_purchases", to: "search#purchases", as: :search_purchases

  # Compliance
  scope module: "compliance" do
    resources :guids, only: [:show]
    resources :cards, only: [:index] do
      collection do
        post :refund
      end
    end
  end

  constraints(lambda { |request| request.env["warden"].authenticate? && request.env["warden"].user.is_team_member? }) do
    mount SidekiqWebCSP.new(Sidekiq::Web) => :sidekiq, as: :sidekiq_web
    mount FlipperCSP.new(Flipper::UI.app(Flipper)) => :features, as: :flipper_ui
  end

  scope module: "users" do
    post :block_ip_address
    get :refund_queue
  end
end
