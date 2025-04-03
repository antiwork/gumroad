# frozen_string_literal: true

module Affiliate::DestinationUrlValidations
  extend ActiveSupport::Concern

  included do
    validate :destination_url_validation

    private
      def destination_url_validation
        return if destination_url.blank?

        errors.add(:base, "The destination url you entered is invalid.") unless /\A#{URI.regexp([%w[http https]])}\z/.match?(destination_url)
      end
  end
end
