# frozen_string_literal: true

# Renders the conversational "Agent" dashboard tab.
class AgentController < Sellers::BaseController
  before_action :authenticate_user!

  layout "inertia"

  def index
    # Authorizes the ROLE only. A seller under the earned-access bar still gets the page, in a
    # locked state that states the bar — the mutating agent endpoints authorize use_store_agent?.
    authorize current_seller, :view_store_agent?

    set_meta_tag(title: "Agent")
    render inertia: "Agent/Index", props: AgentPresenter.new(pundit_user:).index_props
  end
end
