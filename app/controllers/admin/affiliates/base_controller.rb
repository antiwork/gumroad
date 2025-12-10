# frozen_string_literal: true

class Admin::Affiliates::BaseController < Admin::BaseController
  before_action :set_affiliate_user

  private
    def set_affiliate_user
      @affiliate_user = User.find_by_external_id!(params[:affiliate_external_id])
    end
end
