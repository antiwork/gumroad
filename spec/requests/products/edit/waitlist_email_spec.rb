# frozen_string_literal: true

require "spec_helper"

describe "Product edit waitlist email", type: :system, js: true do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product_with_pdf_file, user: seller, name: "Snooze Bar") }

  before do
    2.times { create(:waitlist_entry, product:, follower: create(:active_follower, user: seller)) }
    create(:waitlist_entry, product:, follower: create(:follower, user: seller))
    index_model_records(AudienceMember)
    login_as(seller)
  end

  it "takes the seller from the Share tab to a draft addressed to the waitlist" do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)

    visit "#{edit_link_path(product.unique_permalink)}/share"
    expect(page).to have_text("2 people asked to hear when Snooze Bar launches.")
    click_on "Email your waitlist"

    expect(page).to have_field("Title", with: "Snooze Bar is out now")
    within :fieldset, "Joined the waitlist for" do
      expect(page).to have_button("Snooze Bar")
    end
    expect(page).to have_text("Audience 2 / 2", normalize_ws: true)

    visit "#{edit_link_path(product.unique_permalink)}/share"
    expect(page).to have_text("Your email to your waitlist is a draft.")
    expect(page).to have_button("Review the draft")
    expect(page).not_to have_button("Email your waitlist")
  end

  it "saves unsaved product edits before it leaves the editor" do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)

    visit edit_link_path(product.unique_permalink)
    fill_in "Name", with: "Snooze Bar 2", fill_options: { clear: :backspace }
    select_tab "Share"
    click_on "Email your waitlist"

    expect(page).to have_field("Title", with: "Snooze Bar 2 is out now")
    expect(product.reload.name).to eq("Snooze Bar 2")
  end

  it "saves unsaved product edits before it opens an existing draft" do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
    email = WaitlistLaunchEmail.new(product:).find_or_create_email!

    visit edit_link_path(product.unique_permalink)
    fill_in "Name", with: "Snooze Bar 2", fill_options: { clear: :backspace }
    select_tab "Share"
    click_on "Review the draft"

    expect(page).to have_current_path(edit_email_path(email.external_id))
    expect(product.reload.name).to eq("Snooze Bar 2")
  end

  it "tells a seller who cannot send emails yet why" do
    visit "#{edit_link_path(product.unique_permalink)}/share"

    expect(page).to have_text("You can email your waitlist once you've made at least $100 in sales and received a payout.")
    expect(page).not_to have_button("Email your waitlist")
  end

  it "keeps the reason in view when a draft already exists" do
    WaitlistLaunchEmail.new(product:).find_or_create_email!

    visit "#{edit_link_path(product.unique_permalink)}/share"

    expect(page).to have_text("Your email to your waitlist is a draft.")
    expect(page).to have_text("You can email your waitlist once you've made at least $100 in sales and received a payout.")
  end

  it "shows nothing on an unpublished product" do
    product.unpublish!

    visit "#{edit_link_path(product.unique_permalink)}/share"

    expect(page).to have_text("Share")
    expect(page).not_to have_text("Your waitlist")
  end
end
