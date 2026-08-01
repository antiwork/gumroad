# frozen_string_literal: true

# Rejects a BIC that names a country other than the account's own.
#
# Positions 5-6 of a BIC are its ISO 3166-1 alpha-2 country, and Stripe will not attach a foreign
# one as a local-currency external account — it fails, `stripe_bank_account_id` stays NULL, and the
# seller keeps a payout method in Settings that can never pay (gumroad-private#1476).
#
# Only BIC-SHAPED codes are judged. Several countries legitimately use numeric clearing codes in
# this column (1,502 healthy PH rows are numeric), so anything that is not a BIC is left to the
# country's own format validator.
module BicCountryValidation
  extend ActiveSupport::Concern

  BIC_FORMAT_REGEX = /\A[A-Za-z]{4}(?<country>[A-Za-z]{2})[A-Za-z0-9]{2}([A-Za-z0-9]{3})?\z/

  private
    def validate_bank_code_country(expected_country)
      match = BIC_FORMAT_REGEX.match(bank_code.to_s)
      return if match.nil?
      return if match[:country].casecmp?(expected_country)

      errors.add :base, "The bank code must be for a bank in #{Compliance::Countries.mapping[expected_country]}. " \
                        "#{bank_code} is registered in #{Compliance::Countries.mapping[match[:country].upcase] || match[:country].upcase}."
    end
end
