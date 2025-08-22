# frozen_string_literal: true

module Affiliate::Cookies
  extend ActiveSupport::Concern

  AFFILIATE_COOKIE_NAME_PREFIX = "_gumroad_affiliate_id_"

  class_methods do
    def by_cookies(cookies)
      in_order_of(:id, ids_from_cookies(cookies))
    end

    def ids_from_cookies(cookies)
      cookies
        .sort_by { |cookie| -cookie[1].to_i }.map(&:first)
        .filter_map do |cookie_name|
          next unless cookie_name&.starts_with?(AFFILIATE_COOKIE_NAME_PREFIX)
          next unless (cookie_id = extract_cookie_id_from_cookie_name(cookie_name))

          decrypt_cookie_id(cookie_id)
        end
    end

    def extract_cookie_id_from_cookie_name(cookie_name)
      CGI.unescape(cookie_name).delete_prefix(AFFILIATE_COOKIE_NAME_PREFIX)
    end

    # Decrypts cookie ID back to raw affiliate ID
    # Handles both padded (ABC123==) and unpadded (ABC123) base64 formats for backward compatibility
    def decrypt_cookie_id(cookie_id)
      ObfuscateIds.decrypt(cookie_id)
    end
  end

  def cookie_key
    "#{AFFILIATE_COOKIE_NAME_PREFIX}#{cookie_id}"
  end

  def cookie_id
    ObfuscateIds.encrypt(id, padding: false)
  end
end
