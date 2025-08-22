# frozen_string_literal: true

class SupportController < Sellers::BaseController
  def index
    authorize :support

    @title = "Support"
    @props = {
      host: helper_widget_host,
      session: helper_session,
    }
  end
end
