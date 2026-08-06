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

  it "deletes the marked note once payout setup succeeds, so a later stale-payout-account lookup does not find it" do
    user.add_payout_note(
      content: "Our payment partner couldn't accept the Tax ID you entered.",
      seller_visible: true,
      json_data: { StripeMerchantAccountManager::PAYOUT_SETUP_REJECTION_NOTE_FLAG => true }
    )

    described_class.send(:clear_stale_payout_setup_rejection_notes, user)

    expect(user.latest_payout_setup_rejection_note).to be_nil
  end

  it "leaves other payout notes alone" do
    unrelated = user.add_payout_note(content: "Your payout was skipped because your balance was below the minimum.")

    described_class.send(:clear_stale_payout_setup_rejection_notes, user)

    expect(unrelated.reload.deleted_at).to be_nil
  end
end
