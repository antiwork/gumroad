# frozen_string_literal: true

class Sellers::BaseController < ApplicationController
  before_action :authenticate_user!
  after_action :verify_authorized

  private
    # Returns the path only if it is a safe relative path (internal redirect). Use for redirect_to params
    # to prevent open-redirect attacks. Rejects protocol-relative (//) and absolute URLs.
    def safe_redirect_path(value)
      path = value.to_s.strip
      path if path.present? && path.start_with?("/") && !path.start_with?("//")
    end
end
