# frozen_string_literal: true

class ConfirmationsController < Devise::ConfirmationsController
  include PageMeta::Base

  before_action :set_default_page_title
  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  helper_method :erb_meta_tags

  def show
    @user = User.find_or_initialize_with_error_by(:confirmation_token, params[:confirmation_token])

    if @user.errors.present?
      flash[:alert] = "You have already been confirmed."
      return redirect_to root_url
    end

    if @user.confirm
      sign_in @user
      logged_in_user.reload

      invalidate_active_sessions_except_the_current_session!

      flash[:notice] = "Your account has been successfully confirmed!"
      redirect_to after_confirmation_path_for(:user, @user)
    else
      redirect_to root_url
    end
  end

  def after_confirmation_path_for(_resource_name, user)
    helpers.signed_in_user_home(user)
  end
end
