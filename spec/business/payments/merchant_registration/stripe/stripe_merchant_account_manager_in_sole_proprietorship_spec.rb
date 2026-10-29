# frozen_string_literal: true

require "spec_helper"

# Stripe keeps an India sole-proprietorship account as an individual, so it has no accepted type
# for `company[tax_id]` there and refuses every save with `tax_id_invalid` (gumroad-private#4085).
describe StripeMerchantAccountManager, "company tax ID on an India sole proprietorship" do
  let(:user) { create(:user) }
  let(:passphrase) { GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD") }

  def company_hash_for(**attributes)
    info = create(:user_compliance_info_business, user:, **attributes)
    described_class.send(:company_hash, info, passphrase)[:company]
  end

  it "is not sent for an India sole proprietorship" do
    company = company_hash_for(
      business_country: "India",
      business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP,
      business_tax_id: "22AAAAA0000A1Z5"
    )

    expect(company).not_to have_key(:tax_id)
  end

  it "is still sent for an India company, which Stripe holds as a company" do
    company = company_hash_for(business_country: "India", business_type: "pvt_ltd", business_tax_id: "22AAAAA0000A1Z5")

    expect(company[:tax_id]).to eq("22AAAAA0000A1Z5")
  end

  it "is still sent for a sole proprietorship outside India" do
    company = company_hash_for(
      business_country: "United States",
      business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP,
      business_tax_id: "000000000"
    )

    expect(company[:tax_id]).to eq("000000000")
  end

  context "when an India company changes to a sole proprietorship" do
    let!(:tos_agreement) { create(:tos_agreement, user:) }
    let!(:merchant_account) { create(:merchant_account, user:, charge_processor_merchant_id: "acct_in_sole_prop_test") }
    let!(:company_info) do
      create(:user_compliance_info_business, user:, business_country: "India", business_type: "pvt_ltd", business_tax_id: "22AAAAA0000A1Z5")
    end
    let(:sent) { [] }

    before do
      create(:user_compliance_info_business,
             user:,
             business_country: "India",
             business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP,
             business_tax_id: "22AAAAA0000A1Z5")
      live_account = Stripe::Account.construct_from(
        id: "acct_in_sole_prop_test",
        object: "account",
        metadata: { "user_compliance_info_id" => company_info.external_id },
        capabilities: {},
        country: "IN",
        requirements: { currently_due: [], eventually_due: [], past_due: [] },
        future_requirements: { currently_due: [], past_due: [] },
        external_accounts: { object: "list", data: [] }
      )
      allow(Stripe::Account).to receive(:retrieve).and_return(live_account)
      allow(Stripe::Account).to receive(:list_persons).and_return(Stripe::StripeObject.construct_from(data: []))
      allow(Stripe::Account).to receive(:update) do |_account_id, params|
        sent << params
        live_account
      end
    end

    it "does not send the tax ID the earlier company record carried" do
      described_class.update_account(user, passphrase:)

      companies = sent.filter_map { |params| params[:company] if params.is_a?(Hash) }
      expect(companies).not_to be_empty
      expect(companies).to all(satisfy { |company| !company.key?(:tax_id) })
    end
  end
end

describe StripeMerchantAccountManager, ".clear_unresolvable_business_tax_id_notes" do
  let(:user) { create(:user) }

  def add_tax_id_rejection_note(user)
    user.add_payout_note(
      content: "Our payment partner couldn't accept the business tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "tax_id",
      }
    )
  end

  it "retires a business-tax-ID rejection note on an India sole proprietorship" do
    create(:user_compliance_info_business,
           user:,
           business_country: "India",
           business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP)
    add_tax_id_rejection_note(user)

    described_class.send(:clear_unresolvable_business_tax_id_notes, user)

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end

  it "leaves the note on an India company, where resubmitting the field can still resolve it" do
    create(:user_compliance_info_business, user:, business_country: "India", business_type: "pvt_ltd")
    note = add_tax_id_rejection_note(user)

    described_class.send(:clear_unresolvable_business_tax_id_notes, user)

    expect(note.reload.deleted_at).to be_nil
  end

  it "leaves a rejection note that named a different field" do
    create(:user_compliance_info_business,
           user:,
           business_country: "India",
           business_type: UserComplianceInfo::BusinessTypes::SOLE_PROPRIETORSHIP)
    note = user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "id_number",
      }
    )

    described_class.send(:clear_unresolvable_business_tax_id_notes, user)

    expect(note.reload.deleted_at).to be_nil
  end
end
