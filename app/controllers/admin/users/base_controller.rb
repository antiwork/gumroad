# frozen_string_literal: true

class Admin::Users::BaseController < Admin::BaseController
  include Admin::FetchUser

  protected
    def user_param
      params[:user_id]
    end
end
