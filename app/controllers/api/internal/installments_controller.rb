# frozen_string_literal: true

class Api::Internal::InstallmentsController < Api::Internal::BaseController
  before_action :authenticate_user!
  after_action :verify_authorized
  before_action :set_installment, only: %i[edit update destroy]
  before_action :authorize_user, only: %i[edit update destroy]

  def index
    authorize Installment

    render json: PaginatedInstallmentsPresenter.new(
      seller: current_seller,
      type: params[:type],
      page: params[:page],
      query: params[:query]
    ).props
  end

  def new
    authorize Installment

    render json: InstallmentPresenter.new(seller: current_seller).new_page_props(copy_from: params[:copy_from])
  end

  def edit
    render json: InstallmentPresenter.new(seller: current_seller, installment: @installment).edit_page_props
  end

  def create
    authorize Installment
    save_installment
  end

  def update
    save_installment
  end

  def destroy
    if @installment.mark_deleted
      @installment.installment_rule&.mark_deleted!

      render json: { success: true }
    else
      render json: { success: false, message: "Sorry, something went wrong. Please try again." }
    end
  end

  private
    def save_installment
      service = SaveInstallmentService.new(seller: current_seller, params:, installment: @installment, preview_email_recipient: impersonating_user || logged_in_user)
      if service.process
        render json: { installment_id: service.installment.external_id, full_url: service.installment.full_url }
      else
        render json: { message: service.error }, status: :unprocessable_entity
      end
    end

    def set_installment
      @installment = current_seller.installments.alive.find_by_external_id(params[:id])
      e404_json unless @installment
    end

    def authorize_user
      authorize @installment
    end
end
