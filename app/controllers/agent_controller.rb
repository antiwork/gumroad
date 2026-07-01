# frozen_string_literal: true

# Renders the conversational "Agent" dashboard tab.
class AgentController < Sellers::BaseController
  before_action :authenticate_user!

  layout "inertia"

  def index
    authorize current_seller, :use_store_agent?

    set_meta_tag(title: "Agent")
    render inertia: "Agent/Index", props: AgentPresenter.new(pundit_user:).index_props
  end
end
