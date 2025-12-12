# frozen_string_literal: true

class AffiliatesController < Sellers::BaseController
  include Pagy::Backend

  PUBLIC_ACTIONS = %i[subscribe_posts unsubscribe_posts].freeze
  skip_before_action :authenticate_user!, only: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :set_direct_affiliate, only: PUBLIC_ACTIONS
  before_action :set_meta
  before_action :hide_layouts, only: PUBLIC_ACTIONS

  layout "inertia", only: [:index, :onboarding, :new, :edit]

  def index
    authorize DirectAffiliate

    page = params[:page]&.to_i || 1
    query = params[:query]
    sort_params = extract_sort_params

    presenter = AffiliatesPresenter.new(
      pundit_user,
      page:,
      query:,
      sort: sort_params,
      should_get_affiliate_requests: true
    )
    affiliates_data = presenter.index_props

    if affiliates_data[:affiliates].empty? && affiliates_data[:affiliate_requests].empty? && page == 1 && query.blank?
      redirect_to onboarding_affiliates_path and return
    end

    render inertia: "Affiliates/Index", props: affiliates_data
  end

  def onboarding
    authorize DirectAffiliate, :index?

    presenter = AffiliatesPresenter.new(pundit_user)
    render inertia: "Affiliates/Onboarding", props: presenter.onboarding_props
  end

  def new
    authorize DirectAffiliate, :create?

    presenter = AffiliatesPresenter.new(pundit_user)
    products = presenter.onboarding_props[:products].map do |product|
      product.merge(enabled: false, fee_percent: nil, referral_url: "", destination_url: nil)
    end

    render inertia: "Affiliates/New", props: {
      products:,
      affiliates_disabled_reason: presenter.onboarding_props[:affiliates_disabled_reason]
    }
  end

  def edit
    @affiliate = current_seller.direct_affiliates.find_by_external_id(params[:id])
    return e404 if @affiliate.nil?

    authorize @affiliate, :update?

    presenter = AffiliatesPresenter.new(pundit_user)
    affiliate_data = @affiliate.affiliate_info.merge(products: @affiliate.products_data)

    render inertia: "Affiliates/Edit", props: {
      affiliate: affiliate_data,
      affiliates_disabled_reason: presenter.onboarding_props[:affiliates_disabled_reason]
    }
  end

  def subscribe_posts
    return e404 if @direct_affiliate.nil?

    @direct_affiliate.update_posts_subscription(send_posts: true)
  end

  def unsubscribe_posts
    return e404 if @direct_affiliate.nil?

    @direct_affiliate.update_posts_subscription(send_posts: false)
  end

  def export
    authorize DirectAffiliate, :index?

    result = Exports::AffiliateExportService.export(
      seller: current_seller,
      recipient: impersonating_user || current_seller,
    )

    if result
      send_file result.tempfile.path, filename: result.filename
    else
      flash[:warning] = "You will receive an email with the data you've requested."
      redirect_back(fallback_location: affiliates_path)
    end
  end

  private
    def set_meta
      @title = "Affiliates"
      @on_affiliates_page = true
    end

    def set_direct_affiliate
      @direct_affiliate = DirectAffiliate.find_by_external_id(params[:id])
    end

    def extract_sort_params
      column = params[:column]
      direction = params[:sort]

      return nil unless %w[affiliate_user_name products fee_percent volume_cents].include?(column)

      { key: column, direction: direction == "desc" ? "desc" : "asc" }
    end
end

