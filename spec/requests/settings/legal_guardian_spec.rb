# frozen_string_literal: true

require "spec_helper"

# End-to-end coverage of what a 13-17 year old creator actually does: open payout settings, find the
# legal-guardian form, fill it in, and have their payouts unblock.
#
# Driven through the real page rather than the endpoint because the whole point of this change is
# that the surface exists — the payout gate shipped alongside it strands a minor with no action
# available if the form does not render for exactly the sellers it must. A request spec would pass
# with the section conditioned out of the page.
describe("Legal guardian payout setup", type: :system, js: true) do
  # 15 today, derived from the current date. A literal birthday would age past 18 and turn every
  # example here into an adult-seller example that silently asserts nothing.
  let(:minor_birthday) { 15.years.ago.to_date }
  let(:seller) { create(:user, name: "Ari") }

  before { login_as seller }

  def fill_in_guardian_details
    fill_in "Guardian's first name", with: "Dana"
    fill_in "Guardian's last name", with: "Okafor"
    fill_in "Guardian's email", with: "dana@example.com"
    fill_in "Guardian's phone number", with: "4155550123"
    fill_in_guardian_birthday Date.new(1984, 6, 2)
    fill_in "Guardian's address", with: "1 Market St"
    fill_in "Guardian's city", with: "San Francisco"
    select "California", from: "Guardian's state"
    fill_in "Guardian's ZIP code", with: "94107"
    fill_in "Guardian's Social Security number", with: "000000000"
    check "My guardian has read and accepts the Stripe Connected Account Agreement."
  end

  # A native date input takes keystrokes in the order the browser renders its segments, not an ISO
  # string — passing "1984-06-02" leaves the field empty and the form reports a missing birthday.
  def fill_in_guardian_birthday(date)
    fill_in "Guardian's date of birth", with: date.strftime("%m%d%Y")
  end

  describe "a US seller aged 13-17" do
    before do
      create(:user_compliance_info, user: seller, birthday: minor_birthday)
      create(:balance, user: seller, amount_cents: 200_00, date: 3.days.ago)
    end

    it "adds a guardian and their payouts unblock" do
      visit settings_payments_path

      expect(page).to have_text("Legal guardian")
      expect(page).to have_text("Your payouts are on hold until your guardian's details are complete")

      fill_in_guardian_details
      click_on "Add guardian"

      expect(page).to have_alert(text: "Your legal guardian's details are saved")
      # The notice flipping is the seller-visible proof the requirement is satisfied, and it is read
      # from the same predicate the payout gate reads — so this assertion and the one below cannot
      # disagree.
      expect(page).to have_text("Your guardian's details are complete and your payouts are running normally")

      guardian = seller.guardians.alive.sole
      expect(guardian.full_name).to eq("Dana Okafor")
      expect(guardian.has_completed_info?).to be(true)
      # Attached to the seller's LIVE compliance revision, which is what the payout gate reads. A
      # saved guardian nothing points at would leave payouts blocked with the form claiming success.
      expect(seller.reload.alive_user_compliance_info.guardian).to eq(guardian)
      # The requirement this page exists to satisfy, read through the same predicate the payout gate
      # reads. Not is_user_payable itself: this seller has no payout route set up, so that stays false
      # for reasons a guardian cannot fix and the assertion would pass before the form was even filled
      # in. Whether the gate honours this predicate is covered in spec/business/payments/payouts.
      expect(seller.alive_user_compliance_info.has_completed_payout_compliance_info?).to be(true)
    end

    it "records the guardian's own acceptance of our payment partner's terms, with when and from where" do
      visit settings_payments_path
      fill_in_guardian_details
      click_on "Add guardian"
      expect(page).to have_alert(text: "Your legal guardian's details are saved")

      guardian = seller.guardians.alive.sole
      # All three, because our payment partner takes them together and drops the whole acceptance
      # block if any is missing — leaving an account that looks ready here and stalls there.
      expect(guardian.stripe_tos_accepted).to be(true)
      expect(guardian.stripe_tos_accepted_at).to be_present
      expect(guardian.stripe_tos_ip).to be_present
      expect(guardian.has_accepted_terms?).to be(true)
    end

    it "keeps payouts blocked when the guardian is saved without accepting the terms" do
      visit settings_payments_path

      fill_in "Guardian's first name", with: "Dana"
      fill_in "Guardian's last name", with: "Okafor"
      fill_in "Guardian's email", with: "dana@example.com"
      fill_in_guardian_birthday Date.new(1984, 6, 2)
      fill_in "Guardian's address", with: "1 Market St"
      fill_in "Guardian's city", with: "San Francisco"
      select "California", from: "Guardian's state"
      fill_in "Guardian's ZIP code", with: "94107"
      fill_in "Guardian's Social Security number", with: "000000000"
      click_on "Add guardian"

      expect(page).to have_alert(text: "Your legal guardian's details are saved")
      expect(page).to have_text("Your payouts are on hold until your guardian's details are complete")
      expect(seller.guardians.alive.sole.has_completed_info?).to be(false)
      expect(seller.reload.alive_user_compliance_info.has_completed_payout_compliance_info?).to be(false)
    end

    it "rejects a guardian who is under 18 themselves" do
      visit settings_payments_path

      fill_in_guardian_details
      fill_in_guardian_birthday 16.years.ago.to_date
      click_on "Add guardian"

      expect(page).to have_text("The legal guardian must be at least 18 years old.")
      expect(seller.guardians.alive).to be_empty
    end

    it "prefills the form on a later visit and never renders the stored tax identifier" do
      guardian = create(:guardian, user: seller, first_name: "Dana", last_name: "Okafor",
                                   individual_tax_id: "123456789")
      seller.alive_user_compliance_info.update!(guardian_id: guardian.id)

      visit settings_payments_path

      expect(page).to have_field("Guardian's first name", with: "Dana")
      expect(page).to have_field("Guardian's last name", with: "Okafor")
      # Write-only from the seller's side: the stored identifier is encrypted with a key a web
      # request cannot read back, so the field starts empty and the page only says one is on file.
      expect(page).to have_field("Guardian's Social Security number", with: "")
      expect(page).to have_text("On file. Enter a new number only if you need to replace it.")
      expect(page.html).not_to include("123456789")
    end

    it "keeps the guardian's tax identifier when the form is saved without a new one" do
      guardian = create(:guardian, user: seller, city: "Oakland", individual_tax_id: "000000000")
      seller.alive_user_compliance_info.update!(guardian_id: guardian.id)

      visit settings_payments_path
      # Prefilled from the stored guardian, so the old value has to be cleared rather than typed over.
      fill_in "Guardian's city", with: "Berkeley", fill_options: { clear: :backspace }
      click_on "Save guardian"

      expect(page).to have_alert(text: "Your legal guardian's details are saved")
      guardian.reload
      expect(guardian.city).to eq("Berkeley")
      # An empty field means "keep what is on file". Sending the blank would silently make a
      # complete guardian incomplete and re-block payouts the seller had already fixed.
      expect(guardian.has_individual_tax_id?).to be(true)
      expect(guardian.has_completed_info?).to be(true)
    end
  end

  describe "a seller aged 13-17 in a country with no guardian path" do
    before do
      create(:user_compliance_info, user: seller, birthday: minor_birthday,
                                    country: "Brazil", state: "SP", zip_code: "01000-000")
    end

    # No form at all, rather than a form that cannot help: our payment partner has no legal-guardian
    # route here, so asking would collect an adult's identity details for a verification that cannot
    # succeed.
    it "explains that payouts start at 18 and does not ask for a guardian" do
      visit settings_payments_path

      expect(page).to have_text("Our payment partner cannot verify a seller under 18 in your country")
      expect(page).to have_text("payouts will start once you turn 18")
      expect(page).not_to have_field("Guardian's first name")
    end
  end

  describe "an adult seller" do
    before { create(:user_compliance_info, user: seller, birthday: 30.years.ago.to_date) }

    it "is never shown the guardian form" do
      visit settings_payments_path

      # Anchored on copy the page really renders, so a page that failed to load cannot pass this by
      # simply not containing the guardian section either.
      expect(page).to have_text("Payout method")
      expect(page).not_to have_text("Legal guardian")
      expect(page).not_to have_field("Guardian's first name")
    end
  end
end
