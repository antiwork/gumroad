# frozen_string_literal: true

require "spec_helper"

# Follow-up to gumroad#6927 (gumroad-private#1777): three gaps Greptile found once the marked
# rejection note was live in production.
describe StripeMerchantAccountManager, ".record_account_rejection_note" do
  let(:user) { create(:user) }

  def rejection(message, param, code: nil)
    Stripe::InvalidRequestError.new(message, param, code:)
  end

  it "records only the support-only breadcrumb for a bank-account rejection, which has its own seller messaging" do
    expect(ErrorNotifier).not_to receive(:notify)

    described_class.record_account_rejection_note(
      user, rejection("We couldn't find the bank for that BIC", "bank_account[routing_number]")
    )

    notes = user.comments.with_type_payout_note.alive
    expect(notes.count).to eq(1)
    expect(notes.first.json_data[PayoutNoteVisibility::SELLER_VISIBLE_FLAG]).to eq(false)
  end

  it "records both notes for a rejection payout_setup_rejection_seller_message handles" do
    create(:user_compliance_info, user:, country: "Colombia")

    described_class.record_account_rejection_note(
      user, rejection("Invalid value for individual[id_number]", "individual[id_number]")
    )

    seller_note = user.latest_payout_setup_rejection_note
    expect(seller_note).to be_present
    expect(seller_note.content).to include("Tax ID")
  end
end

describe "User::Comments#latest_payout_setup_rejection_note" do
  let(:user) { create(:user) }

  it "finds the marked note even when 25 newer payout notes exist" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: { StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true }
    )
    PayoutNoteVisibility::MAX_NOTES_SCANNED.times do
      user.add_payout_note(content: "Your payout was skipped because your balance was below the minimum.")
    end

    expect(user.latest_payout_setup_rejection_note).to be_present
  end
end

describe StripeMerchantAccountManager, ".clear_stale_payout_setup_rejection_notes" do
  let(:user) { create(:user) }

  it "deletes the marked note once the rejected field is resubmitted and accepted" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "id_number",
      }
    )

    described_class.send(:clear_stale_payout_setup_rejection_notes, user, resolved_fields: ["id_number"])

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end

  it "leaves the note in place when an unrelated field was the one resubmitted" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "id_number",
      }
    )

    described_class.send(:clear_stale_payout_setup_rejection_notes, user, resolved_fields: ["address"])

    expect(user.latest_payout_setup_rejection_note).to be_present
  end

  it "clears a note with no recorded field on any success, same as before this fix" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the details you entered.",
      seller_visible: true,
      json_data: { StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true }
    )

    described_class.send(:clear_stale_payout_setup_rejection_notes, user, resolved_fields: ["address"])

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end

  it "leaves other payout notes alone" do
    unrelated = user.add_payout_note(content: "Your payout was skipped because your balance was below the minimum.")

    described_class.send(:clear_stale_payout_setup_rejection_notes, user, resolved_fields: :all)

    expect(unrelated.reload.deleted_at).to be_nil
  end

  it "clears a note rejected on a compound field like dob when only its leaf keys were resubmitted (Greptile finding on round 2)" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the date of birth you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "dob",
      }
    )
    submitted_fields = described_class.send(
      :submitted_field_names, individual: { dob: { day: 2, month: 3, year: 1990 } }
    )

    described_class.send(:clear_stale_payout_setup_rejection_notes, user, resolved_fields: submitted_fields)

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end
end

# update_account is the code path that resolves a prior rejection: a successful call to Stripe
# means the field it once refused now goes through — but only if THAT field was on the payload.
# Guards against the mutant that deletes the clear_stale_payout_setup_rejection_notes call from
# that method's success path, and against widening it back to an unscoped clear.
describe StripeMerchantAccountManager, "#update_account clearing a resolved rejection note", :vcr do
  let(:user) { create(:user) }
  let!(:user_compliance_info) { create(:user_compliance_info, user:) }
  let!(:tos_agreement) { create(:tos_agreement, user:) }
  let!(:merchant_account) { described_class.create_account(user, passphrase: "1234") }

  before do
    original_stripe_account_retrieve = Stripe::Account.method(:retrieve)
    allow(Stripe::Account).to receive(:retrieve).with(merchant_account.charge_processor_merchant_id) do |*args|
      stripe_account = original_stripe_account_retrieve.call(*args)
      stripe_account["metadata"]["user_compliance_info_id"] = user_compliance_info.external_id
      stripe_account
    end
  end

  it "clears the marked rejection note when the field it named is resubmitted and accepted" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "id_number",
      }
    )
    create(:user_compliance_info, user:, individual_tax_id: "111223333")

    described_class.update_account(user, passphrase: "1234")

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end

  it "leaves the marked rejection note when an unrelated field was the only one accepted", :vcr do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: {
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true,
        StripeMerchantAccountManager::PAYOUT_SETUP_REJECTED_FIELD_KEY => "id_number",
      }
    )
    create(:user_compliance_info, user:, city: "Palo Alto")

    described_class.update_account(user, passphrase: "1234")

    expect(user.latest_payout_setup_rejection_note).to be_present
  end
end
