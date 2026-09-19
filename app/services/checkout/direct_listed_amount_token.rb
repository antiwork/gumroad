# frozen_string_literal: true

# Signs the exact direct-listed amount that mounted the Payment Element. Prepare compares this
# server-issued snapshot with the final purchase calculation before creating a PaymentIntent, so
# an offer that changes while checkout is open fails through the existing recoverable refresh path.
class Checkout::DirectListedAmountToken
  TTL = 30.minutes
  PURPOSE = "checkout_direct_listed_amount"
  CENT_FIELDS = %w[price_cents tip_cents tax_cents shipping_cents total_cents].freeze

  class << self
    def issue(allocations:, sellers:, currency:)
      normalized = normalize_allocations(allocations)
      return nil if normalized.blank? || currency.blank?

      verifier.generate(
        {
          "allocations" => normalized,
          "currency" => currency.to_s.downcase,
          "sellers" => seller_ids(sellers),
        },
        purpose: PURPOSE,
        expires_in: TTL,
      )
    end

    def verify(token, sellers:, currency:)
      return nil if token.blank?

      payload = verifier.verified(token.to_s, purpose: PURPOSE)
      return nil unless payload.is_a?(Hash)
      return nil unless payload["sellers"] == seller_ids(sellers)
      return nil unless payload["currency"] == currency.to_s.downcase

      normalize_allocations(payload["allocations"])
    end

    private
      def normalize_allocations(allocations)
        return nil unless allocations.is_a?(Array) && allocations.present?

        allocations.map do |allocation|
          return nil unless allocation.respond_to?(:to_h)

          allocation = allocation.to_h.stringify_keys
          permalink = allocation["permalink"]
          return nil unless permalink.is_a?(String) && permalink.present?
          return nil unless CENT_FIELDS.all? { allocation[_1].is_a?(Integer) && allocation[_1] >= 0 }

          { "permalink" => permalink }.merge(CENT_FIELDS.index_with { allocation[_1] })
        end
      end

      def seller_ids(sellers) = Array(sellers).compact.map(&:id).uniq.sort
      def verifier = Rails.application.message_verifier(PURPOSE)
  end
end
