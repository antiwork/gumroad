# frozen_string_literal: true

class Api::Internal::CollaboratorsController < Api::Internal::BaseController
  before_action :authenticate_user!
  before_action :set_collaborator, only: %i[edit update destroy]
  before_action :authorize_user
  after_action :verify_authorized

  def index
    render json: CollaboratorsPresenter.new(seller: pundit_user.seller).index_props
  end

  def new
    render json: CollaboratorPresenter.new(seller: pundit_user.seller).new_collaborator_props
  end

  def create
    response = Collaborator::CreateService.new(seller: current_seller, params: collaborator_params).process
    render json: response, status: response[:success] ? :created : :unprocessable_entity
  end

  def edit
    render json: CollaboratorPresenter.new(seller: pundit_user.seller, collaborator: @collaborator).edit_collaborator_props
  end

  def update
    response = Collaborator::UpdateService.new(seller: current_seller, collaborator_id: params[:id], params: collaborator_params).process
    render json: response, status: response[:success] ? :ok : :unprocessable_entity
  end

  def destroy
    @collaborator.mark_deleted!

    if current_seller == @collaborator.seller
      AffiliateMailer.collaboration_ended_by_seller(@collaborator.id).deliver_later
    elsif current_seller == @collaborator.affiliate_user
      AffiliateMailer.collaboration_ended_by_affiliate_user(@collaborator.id).deliver_later
    end

    head :no_content
  end

  private
    def collaborator_params
      params.require(:collaborator).permit(:email, :apply_to_all_products, :percent_commission, :dont_show_as_co_creator, products: [:id, :percent_commission, :dont_show_as_co_creator])
    end

    def authorize_user
      if @collaborator.present?
        authorize @collaborator
      else
        authorize Collaborator
      end
    end

    def set_collaborator
      @collaborator = Collaborator.alive.find_by_external_id(params[:id]) || e404
    end
end
