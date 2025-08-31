# frozen_string_literal: true

class Api::Internal::AffiliatesController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_affiliate, only: %i[show update destroy]
  after_action :verify_authorized

  def index
    authorize DirectAffiliate

    should_get_affiliate_requests = params[:should_get_affiliate_requests] == "true" ? true : false
    render json: AffiliatesPresenter.new(pundit_user, query: params[:query], page: paged_params[:page], sort: paged_params[:sort], should_get_affiliate_requests:).index_props
  end

  def onboarding
    authorize DirectAffiliate, :index?

    render json: AffiliatesPresenter.new(pundit_user).onboarding_props
  end

  def show
    authorize @affiliate

    render json: @affiliate.affiliate_info.merge(products: @affiliate.products_data)
  end

  def statistics
    affiliate = current_seller.direct_affiliates.find_by_external_id!(params[:id])
    authorize affiliate

    products = affiliate.product_sales_info

    total_volume_cents = products.values.sum { _1[:volume_cents] }

    render json: { total_volume_cents:, products:  }
  end

  def create
    authorize DirectAffiliate

    add_or_edit_affiliate
  end

  def update
    authorize @affiliate

    add_or_edit_affiliate(@affiliate)
  end

  def destroy
    authorize @affiliate

    @affiliate.mark_deleted!
    AffiliateMailer.direct_affiliate_removal(@affiliate.id).deliver_later
    render json: { success: true, id: @affiliate.external_id }
  end

  private
    def paged_params
      params.permit(:page, sort: [:key, :direction])
    end

    def set_affiliate
      @affiliate = current_seller.direct_affiliates.find_by_external_id(params[:id]) if params[:id].present?
      e404_json if @affiliate.nil?
    end

    def add_or_edit_affiliate(affiliate = nil)
      affiliate ||= DirectAffiliate.new
      affiliate_email = affiliate_params[:email]
      apply_to_all_products = affiliate_params[:apply_to_all_products]
      has_invalid_fee = (apply_to_all_products && affiliate_params[:fee_percent].blank?) || (!apply_to_all_products && affiliate_params[:products].any? { _1[:enabled] && _1[:fee_percent].blank? })
      return render json: { success: false } if affiliate_email.blank? || has_invalid_fee

      affiliate_user = User.alive.find_by(email: affiliate_email)
      return render json: { success: false, message: "The affiliate has not created a Gumroad account with this email address." } if affiliate_user.nil?
      return render json: { success: false, message: "You found you. Good job. You can't be your own affiliate though." } if affiliate_user == current_seller
      return render json: { success: false, message: "This user has disabled being added as an affiliate." } if affiliate_user.disable_affiliate_requests?

      return render json: { success: false, message: "Please enable at least one product." } if !apply_to_all_products && affiliate_params[:products].none? { _1[:enabled] }

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
      return render json: { success: false, message: "This affiliate already exists." } if existing_affiliates.exists?

      keep_product_affiliates = []
      enabled_affiliate_products.each do |product|
        affiliate_product = existing_product_affiliates.find { _1.link_id == product[:link_id] } || affiliate.product_affiliates.build(product)
        if affiliate_product.persisted?

          # Re-send updated products email notification to affiliate if individual product fee percentage has changed
          is_editing_products = true unless affiliate_product.affiliate_basis_points == product[:affiliate_basis_points]

          # TODO (raul): remove once https://github.com/rails/rails/issues/17466 is fixed
          #   Ensures changed association is saved when calling +affiliate.save+.
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

      return render json: { success: false, message: affiliate.errors.full_messages.first } if affiliate.errors.present?

      if is_editing_products
        AffiliateMailer.notify_direct_affiliate_of_updated_products(affiliate.id).deliver_later
      end

      unless is_editing_affiliate
        affiliate.schedule_workflow_jobs
      end

      render json: { success: true }
    end

    def affiliate_params
      params.require(:affiliate).permit(:id, :email, :destination_url, :fee_percent, :apply_to_all_products, products: [:id, :enabled, :fee_percent, :destination_url])
    end
end
