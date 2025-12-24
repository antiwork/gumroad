# frozen_string_literal: true

concern :commentable do
  resources :comments, only: [:index, :create]
end

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
      concerns :commentable

      resource :impersonator, only: [:create, :destroy]
      resources :payouts, only: [:index] do
        collection do
          post :pause
          post :resume
        end
      end
      resources :email_changes, only: :index
      resources :merchant_accounts, only: :index
      resource :payout_info, only: :show
      resources :latest_posts, only: :index
      resources :stats, only: :index
      resources :products, only: :index do
        scope module: :products do
          resources :tos_violation_flags, only: [:index, :create]
          resources :purchases, only: :index
        end
      end
      resources :guids, only: [:index]
    end
    member do
      post :add_credit
      post :mass_transfer_purchases
      post :probation_with_reminder
      post :refund_balance
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

  resources :affiliates, only: [] do
    resources :products, only: [:index], module: :affiliates do
      resources :purchases, only: :index, module: :products
    end
  end

  resource :block_email_domains, only: [:show, :update]
  resource :unblock_email_domains, only: [:show, :update]
  resource :suspend_users, only: [:show, :update]
  resource :refund_queue, only: [:show]
  resources :unreviewed_users, only: [:index]

  resources :affiliates, only: [:index, :show], defaults: { format: "html" }

  get "links/:id", to: redirect("/admin/products/%{id}"), as: :link

  resources :products, controller: "links", only: [:show, :destroy] do
    member do
      post :restore
      post :publish
      delete :unpublish
      post :is_adult
      get "/file/:product_file_id/access", to: "links#access_product_file", as: :admin_access_product_file
      get :legacy_purchases
      get :views_count
      get :sales_stats
      get :access_product_file
      post :flag_seller_for_tos_violation
      get :generate_url_redirect
      get :join_discord
      get :join_discord_redirect
    end
    scope module: :products do
      concerns :commentable

      resource :details, controller: "details", only: [:show]
      resource :info, only: [:show]
      resource :staff_picked, controller: "staff_picked", only: [:create]
      resources :purchases, only: [:index] do
        collection do
          post :mass_refund_for_fraud
        end
      end
    end
  end

  resources :comments, only: :create

  resources :purchases, only: [:show], param: :external_id do
    scope module: :purchases do
      concerns :commentable
    end
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
      post :undelete
    end
  end

  resources :sales_reports, only: [:index, :create]

  resources :merchant_accounts, only: [:show], param: :external_id do
    member do
      get :live_attributes
    end
  end

  # Payouts
  post "/paydays/pay_user/:id", to: "paydays#pay_user", as: :pay_user
  resources :payouts, only: [:show] do
    member do
      post :retry
      post :cancel
      post :fail
      post :sync
    end
  end

  # Search
  namespace :search do
    resources :users, only: :index
    resources :purchases, only: :index
  end
  get "/search_purchases", to: "search/purchases#index", as: :legacy_search_purchases # old URL for backward compatibility

  # Compliance
  resources :guids, only: [:show]
  scope module: "compliance" do
    resources :cards, only: [] do
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
  end
end
