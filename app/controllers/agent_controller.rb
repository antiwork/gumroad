# frozen_string_literal: true

# Renders the "Agent" dashboard tab: onboarding for a creator's own AI assistant (Claude,
# ChatGPT or Muse) through Gumroad's MCP server.
class AgentController < Sellers::BaseController
  before_action :authenticate_user!

  layout "inertia"

  def index
    authorize current_seller, :view_store_agent?

    set_meta_tag(title: "Agent")
    render inertia: "Agent/Index", props: AgentOnboardingPresenter.new(pundit_user:).index_props
  end
end
