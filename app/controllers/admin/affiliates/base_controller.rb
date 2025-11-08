# frozen_string_literal: true

class Admin::Affiliates::BaseController < Admin::BaseController
  before_action :set_affiliate_user

  private
    def set_affiliate_user
      @affiliate_user = User.find(params[:affiliate_id])
    end
end
