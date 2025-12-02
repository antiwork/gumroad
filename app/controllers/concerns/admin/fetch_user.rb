# frozen_string_literal: true

module Admin::FetchUser
  private
    def fetch_user
      if user_param.to_i.to_s == user_param && user = User.find_by(id: user_param)
        new_path = request.fullpath.sub("/#{user_param}", "/#{user.external_id}")
        return redirect_to new_path
      end

      @user = if user_param.include?("@")
        User.find_by(email: user_param)
      else
        User.where(username: user_param)
            .or(User.where(external_id: user_param))
            .first
      end

      e404 unless @user
    end

    def user_param
      params[:id]
    end
end
