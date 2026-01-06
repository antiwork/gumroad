# frozen_string_literal: true

class AffiliatesController < Sellers::BaseController
  include Pagy::Backend

  PUBLIC_ACTIONS = %i[subscribe_posts unsubscribe_posts].freeze
  skip_before_action :authenticate_user!, only: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :set_direct_affiliate, only: PUBLIC_ACTIONS
  before_action :set_affiliate, only: %i[edit update destroy statistics]
  before_action :set_title
  before_action :hide_layouts, only: PUBLIC_ACTIONS

  layout "inertia", only: [:index, :onboarding, :new, :edit, :create, :update]

  def index
    authorize DirectAffiliate

    page = params[:page]&.to_i
    query = params[:query]
    sort_params = extract_sort_params

    presenter = AffiliatesPresenter.new(
      pundit_user,
      page:,
      query:,
      sort: sort_params,
      should_get_affiliate_requests: page.nil? || page == 1
    )
    affiliates_data = presenter.index_props

    if affiliates_data[:affiliates].empty? && affiliates_data[:affiliate_requests].empty? && (page.nil? || page == 1) && query.blank?
      return redirect_to onboarding_affiliates_path
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
    render inertia: "Affiliates/New", props: presenter.new_affiliate_props
  end

  def edit
    authorize @affiliate, :update?

    presenter = AffiliatesPresenter.new(pundit_user)
    render inertia: "Affiliates/Edit", props: presenter.edit_affiliate_props(@affiliate)
  end

  def subscribe_posts
    return e404 if @direct_affiliate.nil?

    @direct_affiliate.update_posts_subscription(send_posts: true)
  end

  def unsubscribe_posts
    return e404 if @direct_affiliate.nil?

    @direct_affiliate.update_posts_subscription(send_posts: false)
  end

  def statistics
    authorize @affiliate

    products = @affiliate.product_sales_info
    total_volume_cents = products.values.sum { _1[:volume_cents] }

    render json: { total_volume_cents:, products: }
  end

  def create
    authorize DirectAffiliate, :create?

    affiliate = DirectAffiliate.new
    result = process_affiliate_params(affiliate)

    if result[:success]
      redirect_to affiliates_path, notice: "Affiliate created successfully", status: :see_other
    else
      redirect_to new_affiliate_path, inertia: { errors: { base: [result[:message]] } }
    end
  end

  def update
    authorize @affiliate, :update?

    result = process_affiliate_params(@affiliate)

    if result[:success]
      redirect_to affiliates_path, notice: "Affiliate updated successfully", status: :see_other
    else
      redirect_to edit_affiliate_path(@affiliate), inertia: { errors: { base: [result[:message]] } }
    end
  end

  def destroy
    authorize @affiliate, :destroy?

    @affiliate.mark_deleted!
    AffiliateMailer.direct_affiliate_removal(@affiliate.id).deliver_later
    redirect_to affiliates_path, notice: "Affiliate deleted successfully"
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
    def set_title
      @title = "Affiliates"
    end

    def affiliate_params
      params.require(:affiliate).permit(:email, :destination_url, :fee_percent, :apply_to_all_products, products: [:id, :enabled, :fee_percent, :destination_url])
    end

    def process_affiliate_params(affiliate)
      affiliate_email = affiliate_params[:email]
      apply_to_all_products = affiliate_params[:apply_to_all_products]
      has_invalid_fee = (apply_to_all_products && affiliate_params[:fee_percent].blank?) || (!apply_to_all_products && affiliate_params[:products].any? { _1[:enabled] && _1[:fee_percent].blank? })
      return { success: false, message: "Invalid affiliate parameters" } if affiliate_email.blank? || has_invalid_fee

      affiliate_user = User.alive.find_by(email: affiliate_email)
      return { success: false, message: "The affiliate has not created a Gumroad account with this email address." } if affiliate_user.nil?
      return { success: false, message: "You found you. Good job. You can't be your own affiliate though." } if affiliate_user == current_seller
      return { success: false, message: "This user has disabled being added as an affiliate." } if affiliate_user.disable_affiliate_requests?

      return { success: false, message: "Please enable at least one product." } if !apply_to_all_products && affiliate_params[:products].none? { _1[:enabled] }

      affiliate_basis_points = affiliate_params[:fee_percent].to_i * 100
      if apply_to_all_products
        affiliates_presenter = AffiliatesPresenter.new(pundit_user)
        destination_urls_by_product_id = affiliate_params[:products].select { _1[:enabled] }
                                                                    .index_by { ObfuscateIds.decrypt_numeric(_1[:id].to_i) }
                                                                    .transform_values { _1[:destination_url] }
        enabled_affiliate_products = affiliates_presenter.self_service_affiliate_product_details.keys.map do
          {
            link_id: _1,
            affiliate_basis_points:,
            destination_url: destination_urls_by_product_id[_1]
          }
        end
      else
        enabled_affiliate_products = affiliate_params[:products].select { _1[:enabled] }.map do
          {
            link_id: current_seller.links.find_by_external_id_numeric(_1[:id].to_i).id,
            affiliate_basis_points: _1[:fee_percent].to_i * 100,
            destination_url: _1[:destination_url],
          }
        end
      end
      enabled_affiliate_product_ids = enabled_affiliate_products.map { _1[:link_id] }

      is_editing_affiliate = affiliate.persisted?
      existing_product_affiliates = affiliate&.product_affiliates.to_a
      is_editing_products = is_editing_affiliate && existing_product_affiliates.map { _1.link_id }.sort != enabled_affiliate_product_ids.sort

      existing_affiliates = current_seller.direct_affiliates.alive.joins(:products).where(affiliate_user_id: affiliate_user.id)
      existing_affiliates = existing_affiliates.where.not(id: affiliate.id) if is_editing_affiliate
      return { success: false, message: "This affiliate already exists." } if existing_affiliates.exists?

      keep_product_affiliates = []
      enabled_affiliate_products.each do |product|
        affiliate_product = existing_product_affiliates.find { _1.link_id == product[:link_id] } || affiliate.product_affiliates.build(product)
        if affiliate_product.persisted?
          is_editing_products = true unless affiliate_product.affiliate_basis_points == product[:affiliate_basis_points]
          affiliate.association(:product_affiliates).add_to_target(affiliate_product)
          affiliate_product.assign_attributes(product)
        end
        keep_product_affiliates << affiliate_product
      end
      product_affiliates_to_remove = existing_product_affiliates - keep_product_affiliates
      product_affiliates_to_remove.each(&:mark_for_destruction)

      existing_affiliate = current_seller.direct_affiliates.where(affiliate_user_id: affiliate_user.id).alive.last
      affiliate.affiliate_user = affiliate_user
      affiliate.seller = current_seller
      affiliate.destination_url = affiliate_params[:destination_url]
      affiliate.affiliate_basis_points = affiliate_params[:fee_percent].present? ? affiliate_basis_points : enabled_affiliate_products.map { _1[:affiliate_basis_points] }.min
      affiliate.apply_to_all_products = apply_to_all_products
      affiliate.send_posts = if existing_affiliate
        existing_affiliate.send_posts
      else
        true
      end
      affiliate.save

      return { success: false, message: affiliate.errors.full_messages.first } if affiliate.errors.present?

      if is_editing_products
        AffiliateMailer.notify_direct_affiliate_of_updated_products(affiliate.id).deliver_later
      end

      unless is_editing_affiliate
        affiliate.schedule_workflow_jobs
      end

      { success: true }
    end

    def set_direct_affiliate
      @direct_affiliate = DirectAffiliate.find_by_external_id(params[:id])
    end

    def set_affiliate
      @affiliate = current_seller.direct_affiliates.find_by_external_id(params[:id])
      e404 if @affiliate.nil?
    end

    def extract_sort_params
      column = params[:column]
      direction = params[:sort]

      return nil unless %w[affiliate_user_name products fee_percent volume_cents].include?(column)

      { key: column, direction: direction == "desc" ? "desc" : "asc" }
    end
end
