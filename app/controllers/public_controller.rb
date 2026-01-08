# frozen_string_literal: true

class PublicController < ApplicationController
  include ActionView::Helpers::NumberHelper

  before_action { opt_out_of_header(:csp) } # for the use of external JS on public pages

  before_action :hide_layouts, only: [:thank_you]
  before_action :set_on_public_page

  layout "inertia", only: [:widgets, :ping, :api]

  def home
    redirect_to user_signed_in? ? after_sign_in_path_for(logged_in_user) : login_path
  end

  def widgets
    @title = "Widgets"
    widget_presenter = WidgetPresenter.new(seller: current_seller)

    render inertia: "Public/Widgets", props: widget_presenter.widget_props
  end

  def charge
    @title = "Why is there a charge on my account?"
  end

  def charge_data
    purchases = Purchase.successful_gift_or_nongift.where("email = ?", params[:email])
    purchases = purchases.where("card_visual like ?", "%#{params[:last_4]}%") if params[:last_4].present? && params[:last_4].length == 4
    if purchases.none?
      render json: { success: false }
    else
      CustomerMailer.grouped_receipt(purchases.ids).deliver_later(queue: "critical")
      render json: { success: true }
    end
  end

  def paypal_charge_data
    return render json: { success: false } if params[:invoice_id].nil?

    purchase = Purchase.find_by_external_id(params[:invoice_id])
    if purchase.nil?
      render json: { success: false }
    else
      SendPurchaseReceiptJob.set(queue: purchase.link.has_stampable_pdfs? ? "default" : "critical").perform_async(purchase.id)
      render json: { success: true }
    end
  end

  def license_key_lookup
    @title = "What is my license key?"
  end

  # api methods

  def api
    @title = "API"
    render inertia: "Public/Api"
  end

  def ping
    @title = "Ping"

    render inertia: "Public/Ping"
  end

  def thank_you
    @title = "Thank you!"
  end

  def working_webhook
    render plain: "http://www.gumroad.com"
  end

  def crossdomain
    respond_to :xml
  end

  private
    def set_on_public_page
      @body_class = "public"
    end
end
