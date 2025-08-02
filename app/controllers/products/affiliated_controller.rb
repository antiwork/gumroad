# frozen_string_literal: true

class Products::AffiliatedController < Sellers::BaseController
  before_action :authorize
  before_action :set_affiliate, only: [:approve, :deny, :revoke]

  def index
    @title = "Products"
    @props = AffiliatedProductsPresenter.new(current_seller,
                                             query: affiliated_products_params[:query],
                                             page: affiliated_products_params[:page],
                                             sort: affiliated_products_params[:sort])
                                        .affiliated_products_page_props
    respond_to do |format|
      format.html
      format.json { render json: @props }
    end
  end

  def approve
    if @affiliate.can_approve?
      @affiliate.approve!
      render json: { success: true, message: "Affiliate invitation approved!" }
    else
      render json: { success: false, error: "Cannot approve this invitation" }
    end
  rescue StateMachines::InvalidTransition => e
    render json: { success: false, error: e.message }
  end

  def deny
    if @affiliate.can_deny?
      @affiliate.deny!
      render json: { success: true, message: "Affiliate invitation denied" }
    else
      render json: { success: false, error: "Cannot deny this invitation" }
    end
  rescue StateMachines::InvalidTransition => e
    render json: { success: false, error: e.message }
  end

  def revoke
    if @affiliate.can_revoke?
      @affiliate.revoke!
      render json: { success: true, message: "Affiliate access revoked" }
    else
      render json: { success: false, error: "Cannot revoke this affiliate" }
    end
  rescue StateMachines::InvalidTransition => e
    render json: { success: false, error: e.message }
  end

  private
    def authorize
      super([:products, :affiliated])
    end

    def set_affiliate
      @affiliate = DirectAffiliate.find_by_external_id(params[:id])
      return render json: { success: false, error: "Affiliate not found" } unless @affiliate
      return render json: { success: false, error: "Unauthorized" } unless @affiliate.affiliate_user_id == current_seller.id
    end

    def affiliated_products_params
      params.permit(:query, :page, sort: [:key, :direction])
    end
end
