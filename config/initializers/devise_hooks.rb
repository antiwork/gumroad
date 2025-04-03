# frozen_string_literal: true

Warden::Manager.after_set_user except: :fetch do |user, warden, options|
  warden.session[:last_sign_in_at] = DateTime.current.to_i
end
