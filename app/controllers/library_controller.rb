# frozen_string_literal: true

class LibraryController < Sellers::BaseController
  layout "inertia"

  skip_before_action :check_suspended

  before_action :check_user_confirmed, only: [:index]
  before_action :set_purchase, only: [:archive, :unarchive, :delete]

  RESEND_CONFIRMATION_EMAIL_TIME_LIMIT = 24.hours
  private_constant :RESEND_CONFIRMATION_EMAIL_TIME_LIMIT

  MAX_TRACKED_PURCHASE_ANALYTICS = 50
  private_constant :MAX_TRACKED_PURCHASE_ANALYTICS

  def index
    authorize Purchase

    set_meta_tag(title: "Library")
    purchase_results, creator_counts, bundles = LibraryPresenter.new(logged_in_user).library_cards

    render inertia: "Library/Index", props: {
      results: purchase_results,
      creators: creator_counts,
      bundles:,
      purchase_analytics: purchase_analytics_props,
    }
  end

  def archive
    authorize @purchase

    @purchase.update!(is_archived: true)

    redirect_to library_path, notice: "Product archived!", status: :see_other
  end

  def unarchive
    authorize @purchase

    @purchase.update!(is_archived: false)

    redirect_to library_path, notice: "Product unarchived!", status: :see_other
  end

  def delete
    authorize @purchase

    @purchase.update!(is_deleted_by_buyer: true)

    redirect_to library_path, notice: "Product deleted!", status: :see_other
  end

  private
    def purchase_analytics_props
      raw_ids = params[:purchase_id]
      external_ids = (raw_ids.is_a?(Array) ? raw_ids : Array(raw_ids))
        .select { |id| id.is_a?(String) }
        .first(MAX_TRACKED_PURCHASE_ANALYTICS)
      return {} if external_ids.empty?

      logged_in_user.purchases.by_external_ids(external_ids).each_with_object({}) do |purchase, props|
        analytics = PurchaseSellerAnalyticsPresenter.new(purchase).props
        props[purchase.external_id] = analytics if analytics
      end
    end

    def set_purchase
      @purchase = logged_in_user.purchases.find_by_external_id!(params[:id])
    end

    def check_user_confirmed
      return if logged_in_user.confirmed?

      if logged_in_user.confirmation_sent_at.blank? || logged_in_user.confirmation_sent_at < RESEND_CONFIRMATION_EMAIL_TIME_LIMIT.ago
        # resend_confirmation_instructions clears any stale SendGrid suppression
        # on the address first, so this resend can't be silently dropped.
        logged_in_user.resend_confirmation_instructions
      end

      flash[:warning] = "Please check your email to confirm your address before you can see that."

      if Feature.active?(:custom_domain_download)
        redirect_to settings_main_url(host: DOMAIN), allow_other_host: true
      else
        redirect_to settings_main_path
      end
    end
end
