# frozen_string_literal: true

module SocialShareUrlHelper
  def twitter_url(url, text)
    "https://twitter.com/intent/tweet?text=#{CGI.escape(text)}:%20#{url}"
  end
end
