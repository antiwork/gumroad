# frozen_string_literal: true

class CollaboratorsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_meta, only: [:index]
  after_action :verify_authorized

  def index
    authorize Collaborator
    render inertia: "Collaborators/index",
           props: inertia_props
  end

  private
    def set_meta
      @title = "Collaborators"
    end
end
