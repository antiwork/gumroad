# frozen_string_literal: true

module Affiliate::Cookies
  extend ActiveSupport::Concern

  included do
    AFFILIATE_COOKIE_NAME_PREFIX = "_gumroad_affiliate_id_"
  end

  module ClassMethods
    def by_cookies(cookies)
      by_cookie_ids(cookie_ids_from_cookies(cookies))
    end

    def cookie_ids_from_cookies(cookies)
      cookies
        .sort_by { |cookie| -cookie[1].to_i }.map(&:first)
        .filter_map do |cookie_name|
          next unless cookie_name.starts_with?(AFFILIATE_COOKIE_NAME_PREFIX)

          CGI.unescape(cookie_name).delete_prefix(AFFILIATE_COOKIE_NAME_PREFIX)
        end
    end

    def by_cookie_ids(cookie_ids)
      where(id: decrypt_cookie_ids(cookie_ids))
    end

    def decrypt_cookie_ids(cookie_ids)
      Array.wrap(cookie_ids).map { |encrypted_cookie_id| decrypt_cookie_id(encrypted_cookie_id) }
    end

    # Decrypts cookie ID back to raw affiliate ID
    # Handles both padded (ABC123==) and unpadded (ABC123) base64 formats for backward compatibility
    def decrypt_cookie_id(encrypted_cookie_id)
      ObfuscateIds.decrypt(encrypted_cookie_id)
    end
  end

  def cookie_key
    "#{AFFILIATE_COOKIE_NAME_PREFIX}#{to_encrypted_cookie_id}"
  end

  def to_encrypted_cookie_id
    ObfuscateIds.encrypt(id, padding: false)
  end
end
