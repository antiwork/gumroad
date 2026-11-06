# frozen_string_literal: true

# Tombstone for the mobile app's old "Agent" chat tab. Shipped app builds still call
# GET /api/mobile/agent/meta when the tab mounts, so this endpoint stays and tells them the chat is
# gone instead of returning a routing error. Shipped builds read `enabled`, `greeting` and `suggestions`
# and, with `enabled` false, show their own "isn't available" state; `available` and `notice` are for
# builds that know them.
# The tab itself is removed in the next app release, after which this controller can go too.
class Api::Mobile::AgentController < Api::Mobile::BaseController
  NOTICE = "The Agent tab is gone. Connect Claude or ChatGPT to your store at gumroad.com/mcp."

  before_action { doorkeeper_authorize! :mobile_api }

  # GET /mobile/agent/meta
  def meta
    render json: { success: true, enabled: false, greeting: "", suggestions: [], available: false, notice: NOTICE }
  end
end
