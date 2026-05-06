# frozen_string_literal: true

class Api::Mobile::EmailsController < Api::Mobile::BaseController
  before_action { doorkeeper_authorize! :mobile_api }
  before_action :authorize_index!, only: :index
  before_action :authorize_creator!, except: :index

  def audience_options
    render json: Api::Mobile::EmailAudiencePresenter.new(seller:).as_json
  end

  def index
    presenter = PaginatedInstallmentsPresenter.new(
      seller:,
      type: Installment::PUBLISHED,
      page: params[:page],
      query: params[:query],
    )
    render json: presenter.props
  end

  def create
    return render(json: { success: false, message: "Missing idempotency_key" }, status: :bad_request) if idempotency_key.blank?

    params[:installment][:shown_in_profile_sections] ||= [] if params[:installment].is_a?(ActionController::Parameters)

    reservation = InstallmentIdempotencyService.reserve(seller_id: seller.id, key: idempotency_key)
    case reservation
    when :in_flight
      return render(json: { success: false, message: "Publish in progress", retry_after: 5 }, status: :conflict)
    when Installment
      return render(json: { success: true, installment: installment_json(reservation) })
    end

    service = SaveInstallmentService.new(seller:, params:, preview_email_recipient: nil)
    if service.process
      InstallmentIdempotencyService.complete(seller_id: seller.id, key: idempotency_key, installment_id: service.installment.id)
      render json: { success: true, installment: installment_json(service.installment) }
    else
      InstallmentIdempotencyService.release(seller_id: seller.id, key: idempotency_key)
      render json: { success: false, message: service.error }, status: :unprocessable_entity
    end
  rescue StandardError => e
    InstallmentIdempotencyService.release(seller_id: seller.id, key: idempotency_key) if idempotency_key.present?
    raise e
  end

  private
    def pundit_user
      @_pundit_user ||= SellerContext.new(user: current_api_user, seller: current_api_user)
    end

    def seller
      @seller ||= current_api_user
    end

    def authorize_creator!
      authorize Installment, :create?
    rescue Pundit::NotAuthorizedError
      render json: { success: false, message: "This account can't compose emails." }, status: :forbidden
    end

    def authorize_index!
      authorize Installment, :index?
    rescue Pundit::NotAuthorizedError
      render json: { success: false, message: "This account can't view emails." }, status: :forbidden
    end

    def idempotency_key
      params[:idempotency_key]
    end

    def installment_json(installment)
      {
        external_id: installment.external_id,
        name: installment.name,
        installment_type: installment.installment_type,
        published_at: installment.published_at&.iso8601,
        message: installment.message
      }
    end
end
