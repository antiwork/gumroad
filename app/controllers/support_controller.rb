# frozen_string_literal: true

class SupportController < ApplicationController
  include HelperWidget

  layout "inertia"

  def index
    return redirect_to help_center_root_path unless user_signed_in?

    e404 if helper_widget_host.blank?

    render inertia: "Support/Index", props: {
      host: helper_widget_host,
      session: helper_session,
    }
  end

  private
    def set_default_page_title
      set_meta_tag(title: "Support")
    end
end
