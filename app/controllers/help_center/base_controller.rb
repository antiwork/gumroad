# frozen_string_literal: true

class HelpCenter::BaseController < ApplicationController
  layout "inertia"

  rescue_from ActiveHash::RecordNotFound, with: :redirect_to_help_center_root

  # Legacy `.html` help center URLs are still served and indexed next to the extension-less
  # canonical path, and the canonical tag on both copies is only a hint, so redirect permanently
  # to consolidate the ranking signal.
  before_action :redirect_html_suffixed_path, if: -> { request.get? }

  before_action do
    set_meta_tag(property: "og:type", content: "website")
    set_meta_tag(name: "twitter:card", content: "summary")
  end

  private
    def redirect_html_suffixed_path
      return unless request.path.end_with?(".html")

      canonical_path = request.path.delete_suffix(".html")
      canonical_path += "?#{request.query_string}" if request.query_string.present?

      redirect_to canonical_path, status: :moved_permanently
    end

    def redirect_to_help_center_root
      redirect_to help_center_root_path, status: :found
    end

    def help_center_presenter
      @help_center_presenter ||= HelpCenterPresenter.new(view_context: view_context)
    end
end
