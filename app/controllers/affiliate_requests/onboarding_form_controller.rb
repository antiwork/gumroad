# frozen_string_literal: true

class AffiliateRequests::OnboardingFormController < Sellers::BaseController
  before_action :authenticate_user!
  before_action :set_published_products, only: [:update]

  def update
    authorize [:affiliate_requests, :onboarding_form]

    user_product_external_ids = @published_products.map(&:external_id_numeric)
    user_product_params = permitted_params[:products].filter { |product| user_product_external_ids.include?(product[:id].to_i) }

    if disabling_all_products_while_having_pending_requests?(user_product_params)
      message = "You need to have at least one product enabled since there are some pending affiliate requests"
      if request.inertia?
        return redirect_to onboarding_affiliates_path, alert: message
      else
        return render json: { success: false, error: message }
      end
    end

    SelfServiceAffiliateProduct.bulk_upsert!(user_product_params, current_seller.id)

    current_seller.update!(disable_global_affiliate: permitted_params[:disable_global_affiliate])

    if request.inertia?
      redirect_to onboarding_affiliates_path, notice: "Changes saved!"
    else
      render json: { success: true }
    end
  rescue ActiveRecord::RecordInvalid => e
    if request.inertia?
      redirect_to onboarding_affiliates_path, alert: e.message
    else
      render json: { success: false, error: e.message }
    end
  rescue => e
    logger.error e.full_message
    if request.inertia?
      redirect_to onboarding_affiliates_path, alert: "Something went wrong"
    else
      render json: { success: false }
    end
  end

  private
    def set_published_products
      @published_products = current_seller.links.alive.order("created_at DESC")
    end

    def permitted_params
      params.permit(:disable_global_affiliate, products: [:id, :enabled, :fee_percent, :destination_url, :name])
    end

    def disabling_all_products_while_having_pending_requests?(user_product_params)
      return false if user_product_params.any? { |product| product[:enabled] }

      current_seller.affiliate_requests.unattended_or_approved_but_awaiting_requester_to_sign_up.any?
    end
end
