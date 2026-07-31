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

    # Two tabs can both pass the `alive` lookup above, so the transition itself has to be the gate:
    # a conditional UPDATE lets exactly one request win, and only the winner mails the seller and
    # reports success. The loser 404s like any other stale row.
    #
    # It also skips validations, deliberately: this is a state transition, not a creation, and a
    # legacy row that no longer satisfies today's rules (basis points out of range, no destination
    # URL and no seller username) would otherwise raise and leave the affiliate with no exit — the
    # thing this endpoint exists for.
    now = Time.current
    removed = DirectAffiliate.alive.where(id: @direct_affiliate.id).update_all(deleted_at: now, updated_at: now)
    e404 if removed.zero?

    @direct_affiliate.reload
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
                                      sort: affiliated_products_params[:sort],
                                      # Only admins can end an affiliation, while four roles can view
                                      # the page — without this the other three get a Remove button
                                      # that always fails.
                                      can_remove_affiliations: Pundit.policy!(pundit_user, [:products, :affiliated, DirectAffiliate]).destroy?)
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
