# frozen_string_literal: true

class SupportController < Sellers::BaseController
  def index
    authorize :support

    e404 if helper_widget_host.blank?

    @title = "Support"
    @props = {
      host: helper_widget_host,
      session: helper_session,
    }
  end
end
