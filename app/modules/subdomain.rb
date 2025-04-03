# frozen_string_literal: true

module Subdomain
  USERNAME_REGEXP = /[a-z0-9-]+/

  class << self
    def find_seller_by_request(request)
      find_seller_by_hostname(request.host)
    end

    def find_seller_by_hostname(hostname)
      if subdomain_request?(hostname)
        subdomain = ActionDispatch::Http::URL.extract_subdomains(hostname, 1)[0]

        return User.alive.find_by(external_id: subdomain) if /^[0-9]+$/.match?(subdomain)

        # Convert hyphens to underscores before looking up with usernames.
        # Related conversation: https://git.io/JJgBN
        User.alive.find_by(username: subdomain.tr("-", "_"))
      end
    end

    def from_username(username)
      return unless username.present?
      "#{username.tr("_", "-")}.#{ROOT_DOMAIN}"
    end

    private
      def subdomain_request?(hostname)
        # Strip port from ROOT_DOMAIN in development and test environments since request.host doesn't contain port.
        domain = if Rails.env.development? || Rails.env.test?
          URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host
        else
          ROOT_DOMAIN
        end

        # Allows lowercase letters, numbers and hyphens (to support usernames with underscores).
        # Subdomain should contain at least one letter.
        hostname =~ /\A#{USERNAME_REGEXP.source}.#{domain}\z/
      end
  end
end
