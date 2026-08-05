# frozen_string_literal: true

class PublicController < ApplicationController
  include ActionView::Helpers::NumberHelper

  before_action { opt_out_of_header(:csp) } # for the use of external JS on public pages

  before_action :set_on_public_page

  layout "inertia", only: [:widgets, :ping, :api, :charge, :license_key_lookup]

  def home
    redirect_to user_signed_in? ? after_sign_in_path_for(logged_in_user) : login_path
  end

  def widgets
    set_meta_tag(title: "Widgets")
    widget_presenter = WidgetPresenter.new(seller: current_seller)

    render inertia: "Public/Widgets", props: widget_presenter.widget_props
  end

  def charge
    set_meta_tag(title: "Why is there a charge on my account?")
    render inertia: "Public/Charge"
  end

  def charge_data
    purchases = Purchase.successful_gift_or_nongift.where("email = ?", params[:email])
    purchases = purchases.where("card_visual like ?", "%#{params[:last_4]}%") if params[:last_4].present? && params[:last_4].length == 4
    purchases = scope_by_year_and_month(purchases, params[:year], params[:month])
    if purchases.none?
      render json: { success: false }
    else
      CustomerMailer.grouped_receipt(purchases.ids).deliver_later(queue: "critical")
      render json: { success: true }
    end
  end

  def license_key_lookup_data
    all_purchases = Purchase.successful_gift_or_nongift.where("email = ?", params[:email])
    all_purchases = scope_by_year_and_month(all_purchases, params[:year], params[:month])
    purchases = all_purchases
    if params[:product_query].present?
      query = extract_permalink_from_query(params[:product_query].strip)
      scoped = all_purchases.joins(:link).where(
        "links.name LIKE ? OR links.unique_permalink = ? OR links.custom_permalink = ?",
        "%#{Purchase.sanitize_sql_like(query)}%", query, query
      )
      # Fall back to the full set rather than reporting `false` on no match: an unauthenticated
      # caller who already knows the email must not learn whether it purchased ANY specific
      # product from the response alone.
      purchases = scoped if scoped.exists?
    end
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
    set_meta_tag(title: "What is my license key?")
    render inertia: "Public/LicenseKeyLookup"
  end

  # api methods

  def api
    set_meta_tag(title: "API")
    render inertia: "Public/Api"
  end

  def ping
    set_meta_tag(title: "Ping")
    render inertia: "Public/Ping"
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

    # A buyer may paste the product's URL (any /l/:permalink form, with or without host)
    # rather than typing its name — take the last non-empty path segment as the permalink
    # candidate and fall through to the LIKE/permalink match unchanged if it doesn't parse.
    def extract_permalink_from_query(query)
      return query unless query.match?(%r{\Ahttps?://}i) || query.include?("/")

      path = URI.parse(query).path rescue query
      path.split("/").reverse.find(&:present?) || query
    end

    # Optional narrowing so a buyer who remembers roughly when they were charged doesn't
    # have to render every purchase on the account (gumroad-private#1869). Month is only
    # applied when year is also present — the frontend disables the month picker until a
    # year is chosen, but an unauthenticated GET can still send month alone.
    def scope_by_year_and_month(purchases, year, month)
      return purchases if year.blank?

      year_i = year.to_i
      return purchases if year_i < 2011 || year_i > Time.current.year

      if month.present? && (1..12).cover?(month.to_i)
        range_start = Time.utc(year_i, month.to_i)
        purchases.where(created_at: range_start...range_start.next_month)
      else
        range_start = Time.utc(year_i)
        purchases.where(created_at: range_start...range_start.next_year)
      end
    end
end
