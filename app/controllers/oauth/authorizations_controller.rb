# frozen_string_literal: true

class Oauth::AuthorizationsController < Doorkeeper::AuthorizationsController
  before_action :hide_layouts
  before_action :default_to_authorization_code
  before_action :hide_from_search_results

  private
    def hide_layouts
      @hide_layouts = true
    end

    def hide_from_search_results
      headers["X-Robots-Tag"] = "noindex"
    end

    def default_to_authorization_code
      params[:response_type] = "code" if params[:response_type].blank?
    end
end
