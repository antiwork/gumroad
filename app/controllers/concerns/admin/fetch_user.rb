# frozen_string_literal: true

module Admin::FetchUser
  private
    def fetch_user
      @user = if user_param.include?("@")
        User.find_by(email: user_param)
      else
        User.where(username: user_param)
            .or(User.where(id: user_param))
            .or(User.where(external_id: user_param))
            .first
      end

      e404 unless @user
    end

    def user_param
      params[:id]
    end
end
