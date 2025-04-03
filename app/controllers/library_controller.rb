# frozen_string_literal: true

class LibraryController < Sellers::BaseController
  skip_before_action :check_suspended

  before_action :check_user_confirmed, only: [:index]
  before_action :set_body_id_as_app
  before_action :set_purchase, only: [:archive, :unarchive, :delete]

  RESEND_CONFIRMATION_EMAIL_TIME_LIMIT = 24.hours
  private_constant :RESEND_CONFIRMATION_EMAIL_TIME_LIMIT

  def index
    authorize Purchase

    @on_library_page = true
    @title = "Library"
    @body_class = "library-container"
    @purchase_results, @creator_counts, @bundles = LibraryPresenter.new(logged_in_user).library_cards
  end

  def archive
    authorize @purchase

    @purchase.is_archived = true
    @purchase.save!

    render json: {
      success: true
    }
  end

  def unarchive
    authorize @purchase

    @purchase.is_archived = false
    @purchase.save!

    render json: {
      success: true
    }
  end

  def delete
    authorize @purchase

    @purchase.is_deleted_by_buyer = true
    @purchase.save!

    render json: {
      success: true
    }
  end

  private
    def set_purchase
      @purchase = logged_in_user.purchases.find_by_external_id!(params[:id])
    end

    def check_user_confirmed
      return if logged_in_user.confirmed?

      if logged_in_user.confirmation_sent_at.blank? || logged_in_user.confirmation_sent_at < RESEND_CONFIRMATION_EMAIL_TIME_LIMIT.ago
        logged_in_user.send_confirmation_instructions
      end

      flash[:warning] = "Please check your email to confirm your address before you can see that."

      if Feature.active?(:custom_domain_download)
        redirect_to settings_main_url(host: DOMAIN), allow_other_host: true
      else
        redirect_to settings_main_path
      end
    end
end
