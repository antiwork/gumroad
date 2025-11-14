# frozen_string_literal: true

class Admin::AffiliatesController < Admin::BaseController
  include Pagy::Backend
  include Admin::ListPaginatedUsers

  before_action :fetch_affiliate, only: [:show]
  before_action :clean_search_query, only: [:index]
  before_action :fetch_users_from_query, only: [:index]

  helper Pagy::UrlHelpers

  def index
    @title = "Affiliate results"
    @users = @users.joins(:direct_affiliate_accounts).distinct
    @users = @users.with_blocked_attributes_for(:form_email, :form_email_domain)

    list_paginated_users users: @users, template: "Admin/Affiliates/Index", legacy_template: "admin/affiliates/index", single_result_redirect_path: method(:admin_affiliate_path)
  end

  def show
    @title = "#{@affiliate_user.display_name} affiliate on Gumroad"
    respond_to do |format|
      format.html do
        render inertia: "Admin/Affiliates/Show",
               props: {
                 user: Admin::UserPresenter::Card.new(user: @affiliate_user, pundit_user:).props,
               }
      end
      format.json { render json: @affiliate_user }
    end
  end

  private
    def fetch_affiliate
      @affiliate_user = User.find_by(username: params[:id])
      @affiliate_user ||= User.find_by(id: params[:id])
      @affiliate_user ||= User.find_by_external_id(params[:id].gsub(/^ext-/, ""))

      e404 if @affiliate_user.nil? || @affiliate_user.direct_affiliate_accounts.blank?
    end

    def clean_search_query
      @raw_query = params[:query].strip
      @query = "%#{@raw_query}%"
    end

    def fetch_users_from_query
      @users = User.where(email: @raw_query).order(created_at: :desc, id: :desc) if EmailFormatValidator.valid?(@raw_query)
      @users ||= User.where("external_id = ? or email like ? or name like ?",
                            @raw_query, @query, @query).order(created_at: :desc, id: :desc)
    end
end
