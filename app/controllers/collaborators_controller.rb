# frozen_string_literal: true

class CollaboratorsController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  layout "inertia", only: [:index]

  def index
    authorize Collaborator

    @title = "Collaborators"
    render inertia: "Collaborators/Index"
  end
end
