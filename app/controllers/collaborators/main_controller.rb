# frozen_string_literal: true

class Collaborators::MainController < Collaborators::BaseController
  prepend_before_action :set_collaborator, only: [:edit, :update, :destroy]

  def index
    render inertia: "Collaborators/Index", props: CollaboratorsPresenter.new(seller: current_seller).index_props
  end

  def new
    render inertia: "Collaborators/New", props: CollaboratorPresenter.new(seller: current_seller).new_collaborator_props
  end

  def create
    response = Collaborator::CreateService.new(seller: current_seller, params: collaborator_params).process

    if response[:success]
      redirect_to collaborators_path, status: :see_other, notice: "Changes saved!"
    else
      redirect_to new_collaborator_path, inertia: inertia_errors(response[:collaborator]), alert: inertia_alert(response[:collaborator])
    end
  end

  def edit
    render inertia: "Collaborators/Edit", props: CollaboratorPresenter.new(seller: current_seller, collaborator: @collaborator).edit_collaborator_props
  end

  def update
    response = Collaborator::UpdateService.new(seller: current_seller, collaborator_id: params[:id], params: collaborator_params).process

    if response[:success]
      redirect_to collaborators_path, status: :see_other, notice: "Changes saved!"
    else
      redirect_to edit_collaborator_path(params[:id]), inertia: inertia_errors(response[:collaborator]), alert: inertia_alert(response[:collaborator])
    end
  end

  def destroy
    super do
      redirect_to collaborators_path, status: :see_other, notice: "The collaborator was removed successfully."
    end
  end


  private
    def collaborator_params
      params.require(:collaborator).permit(:email, :apply_to_all_products, :percent_commission, :dont_show_as_co_creator, products: [:id, :percent_commission, :dont_show_as_co_creator])
    end

    def inertia_alert(collaborator)
      collaborator.errors.to_hash.transform_values(&:to_sentence)[:base]
    end
end
