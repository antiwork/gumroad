# frozen_string_literal: true

class Settings::BeneficialOwnersController < Settings::BaseController
  before_action :authorize
  before_action :ensure_eligible

  def index
    render json: { beneficial_owners: StripeBeneficialOwnersManager.list(current_seller) }
  rescue Stripe::StripeError => e
    render_stripe_error(e)
  end

  def create
    owner = StripeBeneficialOwnersManager.create(current_seller, beneficial_owner_params)
    render json: { beneficial_owner: owner }, status: :created
  rescue StripeBeneficialOwnersManager::MissingRequiredFieldError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Stripe::InvalidRequestError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Stripe::StripeError => e
    render_stripe_error(e)
  end

  def update
    owner = StripeBeneficialOwnersManager.update(current_seller, params[:id], beneficial_owner_params)
    render json: { beneficial_owner: owner }
  rescue StripeBeneficialOwnersManager::MissingRequiredFieldError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Stripe::InvalidRequestError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Stripe::StripeError => e
    render_stripe_error(e)
  end

  def destroy
    result = StripeBeneficialOwnersManager.destroy(current_seller, params[:id])
    render json: result
  rescue StripeBeneficialOwnersManager::RepresentativeNotEditableError
    render json: { error: "This person is the account representative and cannot be removed here." }, status: :forbidden
  rescue Stripe::InvalidRequestError => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue Stripe::StripeError => e
    render_stripe_error(e)
  end

  private
    def authorize
      super([:settings, :payments, current_seller], :update?)
    end

    def ensure_eligible
      return if StripeBeneficialOwnersManager.eligible?(current_seller)
      render json: { error: "Beneficial owners can only be managed on business accounts using Gumroad-managed Stripe." }, status: :forbidden
    end

    def beneficial_owner_params
      params.require(:beneficial_owner).permit(
        :first_name, :last_name, :email, :phone, :id_number, :title,
        :owner, :director, :executive, :percent_ownership, :nationality,
        :first_name_kanji, :last_name_kanji, :first_name_kana, :last_name_kana,
        dob: [:day, :month, :year],
        address: [
          :line1, :line2, :city, :state, :postal_code, :country,
          :building_number, :building_number_kana, :street_address_kanji, :street_address_kana, :state_kana,
        ],
      )
    end

    def render_stripe_error(error)
      ErrorNotifier.notify(error)
      render json: { error: "We couldn't reach Stripe just now. Please try again in a moment." }, status: :bad_gateway
    end
end
