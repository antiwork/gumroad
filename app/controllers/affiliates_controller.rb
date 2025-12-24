# frozen_string_literal: true

class AffiliatesController < ApplicationController
  include Pagy::Backend

  PUBLIC_ACTIONS = %i[subscribe_posts unsubscribe_posts].freeze
  before_action :authenticate_user!, except: PUBLIC_ACTIONS
  after_action :verify_authorized, except: PUBLIC_ACTIONS

  before_action :set_direct_affiliate, only: PUBLIC_ACTIONS
  before_action :set_meta, only: %i[index subscribe_posts unsubscribe_posts]
  before_action :hide_layouts, only: PUBLIC_ACTIONS

  def index
    authorize DirectAffiliate
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

    seller = seller_for_export

    result = Exports::AffiliateExportService.export(
      seller:,
      recipient: impersonating_user || seller,
    )

    if result
      send_file result.tempfile.path, filename: result.filename
    else
      flash[:warning] = "You will receive an email with the data you've requested."
      redirect_back(fallback_location: affiliates_path)
    end
  end

  private
    # When impersonating, we must use logged_in_user (the impersonated user), not current_seller.
    # See PurchasesController#seller_for_export for detailed explanation.
    def seller_for_export
      return current_seller unless impersonating?

      if current_seller != logged_in_user
        Rails.logger.warn(
          "[Impersonation] Seller mismatch during affiliate export: " \
          "current_seller=#{current_seller.id}, logged_in_user=#{logged_in_user.id}"
        )
      end

      logged_in_user
    end

    def set_meta
      @title = "Affiliates"
      @on_affiliates_page = true
    end

    def set_direct_affiliate
      @direct_affiliate = DirectAffiliate.find_by_external_id(params[:id])
    end
end
