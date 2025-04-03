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
end
