# frozen_string_literal: true

class Admin::Users::EmailChangesController < Admin::Users::BaseController
  before_action :fetch_user

  def index
    render json: {
      email_changes: @user.versions_for(:email, :payment_address),
      fields: %w(email payment_address)
    }
  end
end
