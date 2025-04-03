# frozen_string_literal: true

module SocialShareUrlHelper
  def twitter_url(url, text)
    "https://twitter.com/intent/tweet?text=#{CGI.escape(text)}:%20#{url}"
  end

  def facebook_url(url, text = nil)
    share_url = "https://www.facebook.com/sharer/sharer.php?u=#{url}"
    share_url += "&quote=#{CGI.escape(text)}" if text.present?
    share_url
  end
end
