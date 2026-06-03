# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe("Resend to non-openers flow", :js, type: :system) do
  include EmailHelpers

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, name: "Sample product", user: seller) }
  let!(:installment) do
    create(:published_installment, seller:, link: product, installment_type: "product",
                                   name: "Product update", message: "Hello customers", shown_on_profile: false)
  end
  let!(:blast) { create(:post_email_blast, post: installment, completed_at: 1.day.ago) }

  # Three buyers were emailed; one opened, two did not -> 2 non-openers.
  let!(:opened_purchase) { create(:purchase, link: product, seller:, email: "opened@example.com") }
  let!(:unopened_purchase_1) { create(:purchase, link: product, seller:, email: "miss1@example.com") }
  let!(:unopened_purchase_2) { create(:purchase, link: product, seller:, email: "miss2@example.com") }

  include_context "with switching account to user as admin for seller"

  before do
    seller.update!(timezone: "UTC")
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)

    create(:creator_contacting_customers_email_info_opened, installment:, purchase: opened_purchase)
    create(:creator_contacting_customers_email_info_sent, installment:, purchase: unopened_purchase_1)
    create(:creator_contacting_customers_email_info_sent, installment:, purchase: unopened_purchase_2)
  end

  it "resends a published email to the recipients who have not opened it" do
    visit emails_path

    expect(page).to have_tab_button("Published", open: true)
    find(:table_row, { "Subject" => "Product update" }).click

    expect(page).to have_button("Resend to non-openers")
    click_on "Resend to non-openers"

    within_modal "Resend to non-openers?" do
      expect(page).to have_text("2 people who were emailed but haven't opened it yet")
      click_on "Resend"
    end

    expect(page).to have_alert(text: "Resending to 2 people who haven't opened this yet.")

    resend_blast = installment.blasts.where(recipient_filter: "unopened").sole
    expect(resend_blast.recipient_filter).to eq("unopened")
    expect(SendPostBlastEmailsJob).to have_enqueued_sidekiq_job(resend_blast.id)
    expect(installment.blasts.count).to eq(2)
  end

  it "disables the resend when everyone who was emailed has already opened it" do
    CreatorContactingCustomersEmailInfo.where(installment_id: installment.id).update_all(state: "opened", opened_at: Time.current)

    visit emails_path

    find(:table_row, { "Subject" => "Product update" }).click
    click_on "Resend to non-openers"

    within_modal "Resend to non-openers?" do
      expect(page).to have_text("Everyone who was emailed has already opened this.")
      expect(page).to have_button("Resend", disabled: true)
      click_on "Cancel"
    end

    expect(installment.blasts.where(recipient_filter: "unopened")).to be_empty
    expect(SendPostBlastEmailsJob).not_to have_enqueued_sidekiq_job(anything)
  end

  it "does not offer the resend for a follower email with no per-recipient open tracking" do
    follower_installment = create(:published_installment, seller:, link: nil, installment_type: "follower", name: "Follower update")
    create(:post_email_blast, post: follower_installment, completed_at: 1.day.ago)

    visit emails_path

    find(:table_row, { "Subject" => "Follower update" }).click

    expect(page).to have_button("View email")
    expect(page).to_not have_button("Resend to non-openers")
  end

  it "lists each prior non-opener resend on the email sheet" do
    create(:post_email_blast, post: installment, recipient_filter: "unopened", requested_at: 2.hours.ago, started_at: 2.hours.ago, completed_at: 1.hour.ago, delivery_count: 2)

    visit emails_path
    find(:table_row, { "Subject" => "Product update" }).click

    expect(page).to have_text("Resends to non-openers")
    expect(page).to have_text("2 emailed")
  end
end
