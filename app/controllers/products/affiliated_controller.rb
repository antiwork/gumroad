# frozen_string_literal: true

class Products::AffiliatedController < Sellers::BaseController
  before_action :authorize_index, only: [:index]
  before_action :set_direct_affiliate, only: [:destroy]

  layout "inertia", only: [:index]

  def index
    set_meta_tag(title: "Products")
    props = page_props
    respond_to do |format|
      format.html { render inertia: "Products/Affiliated/Index", props: }
      format.json { render json: props }
    end
  end

  def destroy
    authorize [:products, :affiliated, @direct_affiliate]

    @direct_affiliate.mark_deleted!
    AffiliateMailer.direct_affiliate_removal_by_affiliate_user(@direct_affiliate.id).deliver_later

    # The affiliation covers every product the seller enabled, so the headline stats move too, not
    # just the listed rows. Returning the whole page props lets the client repaint both at once.
    render json: page_props
  end

  private
    def authorize_index
      authorize [:products, :affiliated]
    end

    def page_props
      AffiliatedProductsPresenter.new(current_seller,
                                      query: affiliated_products_params[:query],
                                      page: affiliated_products_params[:page],
                                      sort: affiliated_products_params[:sort])
                                 .affiliated_products_page_props
    end

    # Only direct affiliations are removable here. A GlobalAffiliate row is the user's own
    # Gumroad Affiliates enrollment, not something a seller added them to, and it is left
    # through that section instead. Scoped to the current seller so someone else's affiliation
    # is indistinguishable from a bad id; the policy is the second gate on the same fact.
    def set_direct_affiliate
      @direct_affiliate = DirectAffiliate.alive.where(affiliate_user: current_seller).find_by_external_id(params[:id]) || e404
    end

    def affiliated_products_params
      params.permit(:query, :page, sort: [:key, :direction])
    end
end
