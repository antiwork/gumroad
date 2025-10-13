# frozen_string_literal: true

class CollaboratorsController < Sellers::BaseController
  layout "inertia", only: [:index]

  def index
    authorize Collaborator

    @title = "Collaborators"
    render inertia: "Collaborators/Index"
  end
end
