# frozen_string_literal: true

require "spec_helper"

# The payout form's IBAN box shows COUNTRY_IBAN_PLACEHOLDERS as its example. A seller copying that
# shape has to end up with a value the country's bank-account model saves.
describe "IBAN account-number placeholders" do
  placeholders = File.read(Rails.root.join("app/javascript/utils/payoutAccountNumbers.ts"))
    .then { |source| source[/COUNTRY_IBAN_PLACEHOLDERS[^{]*\{(.*?)\n\};/m, 1] }
    .scan(/^\s*([A-Z]{2}): "([A-Z0-9]+)",$/)
    .to_h

  def user_in(alpha2)
    User.new.tap { allow(_1).to receive(:compliance_country_code).and_return(alpha2) }
  end

  let(:iban_countries) { Compliance::Countries.mapping.keys.select { user_in(_1).country_supports_iban? } }

  # A country-specific model wins over EuropeanBankAccount (Monaco has its own), matching the form.
  def model_class_for(alpha2)
    country_model = (UpdatePayoutMethod.bank_account_types.values.map { _1[:class] } - [EuropeanBankAccount]).find do |klass|
      klass.new.country == alpha2
    rescue StandardError
      false
    end
    country_model || (EuropeanBankAccount if user_in(alpha2).signed_up_from_europe?)
  end

  it "has a placeholder for every country that renders the IBAN box, and no others" do
    expect(placeholders.keys).to match_array(iban_countries)
  end

  placeholders.each do |alpha2, iban|
    it "gives #{alpha2} a placeholder its bank-account model accepts" do
      expect(iban).to start_with(alpha2)
      klass = model_class_for(alpha2)
      expect(klass).to be_present

      bank_account = klass.new(account_number: iban)
      bank_account.send(:validate_account_number)
      expect(bank_account.errors[:base]).to be_empty
    end
  end
end
