# frozen_string_literal: true

require "spec_helper"

# Stripe's rejections quote the value they refused without ever naming the rule, and everything
# outside the postal-code and bank-directory lanes used to reach the seller as that raw message or
# not at all (gumroad-private#1777).
describe StripeMerchantAccountManager, ".payout_setup_rejection_seller_message" do
  let(:user) { create(:user) }

  def rejection(message, param, code: nil)
    Stripe::InvalidRequestError.new(message, param, code:)
  end

  it "names the field in the settings form's own words, not Stripe's parameter path" do
    create(:user_compliance_info, user:, country: "Colombia")

    message = described_class.payout_setup_rejection_seller_message(
      rejection("Invalid value for individual[id_number]", "individual[id_number]"), user
    )

    expect(message).to include("couldn't accept the Tax ID you entered")
    expect(message).not_to include("individual[id_number]")
    expect(message).to include("stops you publishing new products")
  end

  it "states the US-number rule for a US individual account, which Stripe's own message omits" do
    create(:user_compliance_info, user:, country: "United States")

    message = described_class.payout_setup_rejection_seller_message(
      rejection('"+573006330866" is not a valid phone number', "individual[phone]"), user
    )

    expect(message).to include("couldn't accept the phone number you entered")
    expect(message).to include("has to be a US number")
  end

  # The rule is Stripe's, and it only applies to US individual and sole-proprietorship accounts, so
  # asserting it anywhere else would send the seller to change a field that was already correct.
  it "does not state the US-number rule for a non-US account" do
    create(:user_compliance_info, user:, country: "Colombia")

    message = described_class.payout_setup_rejection_seller_message(
      rejection('"+573006330866" is not a valid phone number', "individual[phone]"), user
    )

    expect(message).to include("couldn't accept the phone number you entered")
    expect(message).not_to include("US number")
  end

  it "does not state the US-number rule for a US company, which Stripe does not apply it to" do
    create(:user_compliance_info_business, user:, country: "United States",
                                           business_type: UserComplianceInfo::BusinessTypes::LLC)

    message = described_class.payout_setup_rejection_seller_message(
      rejection('"+573006330866" is not a valid phone number', "individual[phone]"), user
    )

    expect(message).not_to include("US number")
  end

  # Stripe names this field `ssn_last_4`, not `id_number`, and its own wording for the two
  # differs — so the label lookup has to know both spellings.
  it "names a rejected SSN last 4 as the Tax ID the seller typed" do
    create(:user_compliance_info, user:, country: "United States")

    message = described_class.payout_setup_rejection_seller_message(
      rejection("Invalid SSN last 4. 0000 is not an allowed value.", "individual[ssn_last_4]"), user
    )

    expect(message).to include("couldn't accept the Tax ID you entered")
  end

  it "falls back to a generic sentence for a rejection carrying no param" do
    create(:user_compliance_info, user:)

    message = described_class.payout_setup_rejection_seller_message(
      rejection("Something is wrong. Please contact us if this continues.", nil), user
    )

    expect(message).to include("couldn't accept the details you entered")
  end

  it "names the address for a Japanese address Stripe cannot find, which carries no param" do
    create(:user_compliance_info, user:, country: "Japan")

    message = described_class.payout_setup_rejection_seller_message(
      rejection("Invalid address for Japan. We cannot find an address with town of 梅田 for postal_code 530-0001.", nil), user
    )

    expect(message).to include("couldn't accept the address you entered")
  end

  # Stripe names the key inside an address sub-hash, while the form shows one Address field, so the
  # lookup has to answer for the whole block instead of falling through to the generic sentence.
  it "names the address for a rejection inside the address sub-hash" do
    create(:user_compliance_info, user:, country: "Pakistan")

    message = described_class.payout_setup_rejection_seller_message(
      rejection('Invalid string: "…"; must be at most 200 characters', "individual[address][line1]"), user
    )

    expect(message).to include("couldn't accept the address you entered")
    expect(message).to include("It has to be 200 characters or fewer.")
  end

  it "names the business address for a company address rejection" do
    create(:user_compliance_info_business, user:, country: "Pakistan",
                                           business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP)

    message = described_class.payout_setup_rejection_seller_message(
      rejection('Invalid string: "…"; must be at most 200 characters', "company[address][line1]"), user
    )

    expect(message).to include("couldn't accept the address you entered")
  end

  # Stripe states the cap only inside the message it refuses with, so a seller over it re-saves the
  # same value and reads the same sentence back.
  it "states no cap for a rejection whose message carries none" do
    create(:user_compliance_info, user:, country: "United States")

    message = described_class.payout_setup_rejection_seller_message(
      rejection("Invalid SSN last 4. 0000 is not an allowed value.", "individual[ssn_last_4]"), user
    )

    expect(message).not_to include("characters or fewer")
  end

  # These two already have dedicated seller-facing copy and their own retry loops; a second message
  # here would compete with the branch the controller checks first.
  it "returns nothing for a postal-code rejection" do
    expect(
      described_class.payout_setup_rejection_seller_message(
        rejection("Invalid postal code", "individual[address][postal_code]", code: "postal_code_invalid"), user
      )
    ).to be_nil
  end

  it "returns nothing for a bank-account rejection" do
    expect(
      described_class.payout_setup_rejection_seller_message(
        rejection("We couldn't find the bank for that BIC", "bank_account[routing_number]"), user
      )
    ).to be_nil
  end

  # An APIConnectionError means Stripe never reached a verdict, so blaming the seller's data would
  # send them editing a field that is fine.
  it "returns nothing for an error that is not a rejection of the seller's input" do
    expect(
      described_class.payout_setup_rejection_seller_message(
        Stripe::APIConnectionError.new("connection failed"), user
      )
    ).to be_nil
  end

  it "tells the seller a no-verdict failure was not a rejection of their details" do
    expect(described_class.no_verdict_seller_message(Stripe::APIError.new("An unknown error occurred")))
      .to include("Nothing you entered was rejected")
    expect(described_class.no_verdict_seller_message(rejection("Invalid value", "individual[id_number]"))).to be_nil
  end
end
