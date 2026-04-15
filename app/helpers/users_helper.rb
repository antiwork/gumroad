# frozen_string_literal: true

module UsersHelper
  def allowed_avatar_extensions
    User::ALLOWED_AVATAR_EXTENSIONS.map { |extension| ".#{extension}" }.join(",")
  end

  def signed_in_user_home(user, next_url: nil, include_host: false)
    return next_url if next_url.present?
    host = UrlService.domain_with_protocol
    if user.is_buyer?
      if include_host
        return library_url(host:)
      else
        return library_path
      end
    end

    if include_host
      dashboard_url(host:)
    else
      dashboard_path
    end
  end
end
