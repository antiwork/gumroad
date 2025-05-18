# frozen_string_literal: true

class Admin::LinksController < Admin::BaseController
  before_action :fetch_product_by_general_permalink, except: %i[purchases views_count sales_stats]
  before_action :fetch_product, only: %i[views_count sales_stats]

  def show
    @title = @product.name
  end

  def purchases
    product_id = params[:id].to_i
    product = Link.find_by(id: product_id)

    if parse_boolean(params[:is_affiliate_user])
      affiliate_user = User.find(params[:user_id])
      sales = Purchase.where(link_id: product_id, affiliate_id: affiliate_user.direct_affiliate_accounts.select(:id))
    else
      sales = product.sales
    end

    @purchases = sales.where("purchase_state IN ('preorder_authorization_successful', 'preorder_concluded_unsuccessfully', 'successful', 'failed', 'not_charged')").exclude_not_charged_except_free_trial
    @purchases = @purchases.order("created_at DESC, id DESC").page_with_kaminari(params[:page]).per(params[:per_page])

    respond_to do |format|
      purchases_json = @purchases.as_json(admin_review: true)
      format.json { render json: { purchases: purchases_json, page: params[:page].to_i } }
    end
  end

  def views_count
    render layout: false
  end

  def sales_stats
    render layout: false
  end

  private
    def fetch_product_by_general_permalink
      @product = Link.find_by(id: params[:id])
      return redirect_to admin_product_path(@product.unique_permalink) if @product

      @product_matches = Link.by_general_permalink(params["id"])

      if @product_matches.size > 1
        @title = "Multiple products matched"
        render "multiple_matches"
        return
      else
        @product = @product_matches.first || e404
      end

      if @product && @product.unique_permalink != params["id"]
        redirect_to admin_product_path(@product.unique_permalink)
      end
    end

    def fetch_product
      @product = Link.where(id: params[:id]).or(Link.where(unique_permalink: params[:id])).first
      @product || e404
    end

    def unpublish_or_delete_product!(product)
      product.is_tiered_membership? ? product.unpublish! : product.delete!
    end

    def parse_boolean(value)
      value == "true" ? true : false
    end
end
