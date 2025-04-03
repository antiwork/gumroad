# frozen_string_literal: true

class Oauth::TokensController < Doorkeeper::TokensController
  include LogrageHelper

  private
    def strategy
      # default to authorization code
      params[:grant_type] = "authorization_code" if params[:grant_type].blank?
      super
    end
end
