# frozen_string_literal: true

require "spec_helper"

# The payout form's IBAN box shows COUNTRY_IBAN_PLACEHOLDERS as its example. Each carries "00" check
# digits, which fail mod-97, so it is never a real account; with the real pair filled in it is a value
# the country's bank-account model saves. The form refuses the literal (payoutAccountNumbers.test.ts).
describe "IBAN account-number placeholders" do
  placeholders = File.read(Rails.root.join("app/javascript/utils/payoutAccountNumbers.ts"))
    .then { |source| source[/COUNTRY_IBAN_PLACEHOLDERS[^{]*\{(.*?)\n\};/m, 1] }
    .scan(/^\s*([A-Z]{2}): "([A-Z0-9]+)",$/)
    .to_h

  def user_in(alpha2)
    User.new.tap { allow(_1).to receive(:compliance_country_code).and_return(alpha2) }
  end

  def mod97(iban)
    (iban[4..] + iban[0, 4]).chars.map { _1.to_i(36).to_s }.join.to_i % 97
  end

  def with_check_digits(iban)
    iban[0, 2] + format("%02d", 98 - mod97(iban[0, 2] + "00" + iban[4..])) + iban[4..]
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

  def account_number_errors(alpha2, iban)
    bank_account = model_class_for(alpha2).new(account_number: iban)
    bank_account.send(:validate_account_number)
    bank_account.errors[:base]
  end

  it "has a placeholder for every country that renders the IBAN box, and no others" do
    expect(placeholders.keys).to match_array(iban_countries)
  end

  placeholders.each do |alpha2, iban|
    it "gives #{alpha2} an example that fails mod-97 but that its model accepts once check digits are filled in" do
      expect(iban).to start_with("#{alpha2}00")
      expect(model_class_for(alpha2)).to be_present

      expect(mod97(iban)).not_to eq(1)
      expect(Ibandit::IBAN.new(iban).valid?).to be(false)

      filled = with_check_digits(iban)
      expect(mod97(filled)).to eq(1)
      expect(account_number_errors(alpha2, filled)).to be_empty
    end
  end
end
