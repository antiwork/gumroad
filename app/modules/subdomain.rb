# frozen_string_literal: true

module Subdomain
  USERNAME_REGEXP = /[a-z0-9-]+/

  class << self
    def find_seller_by_request(request)
      find_seller_by_hostname(request.host)
    end

    def from_username(username)
      return if username.blank?

      "#{username.tr("_", "-")}.#{ROOT_DOMAIN}"
    end

    def find_seller_by_hostname(hostname)
      if (match = subdomain_regex.match(hostname))
        subdomain = match[:subdomain]

        return User.alive.find_by(external_id: subdomain) if /^[0-9]+$/.match?(subdomain)

        # Convert hyphens to underscores before looking up with usernames.
        # Related conversation: https://git.io/JJgBN
        User.alive.find_by(username: subdomain.tr("-", "_"))
      end
    end

    def subdomain_request?(hostname)
      subdomain_regex.match?(hostname)
    end

    private
      def subdomain_regex
        # Strip port from ROOT_DOMAIN in development and test environments since request.host doesn't contain port.
        domain = if Rails.env.development? || Rails.env.test?
          URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host
        else
          ROOT_DOMAIN
        end

        # Allows lowercase letters, numbers and hyphens (to support usernames with underscores).
        # Subdomain should contain at least one letter.
        /\A(?<subdomain>#{USERNAME_REGEXP.source})\.#{Regexp.escape(domain)}\z/
      end
  end
end
