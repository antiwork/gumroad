# frozen_string_literal: true

require "spec_helper"

describe "Buyer refund request", type: :system, js: true do
  let(:seller) { create(:user, name: "Jane Doe") }
  let(:purchase) { create(:purchase, link: create(:product, user: seller, name: "Watercolor brush pack")) }
  let(:page_link) { PurchaseRefundRequest.page_link(purchase) }

  before do
    Feature.activate_user(:buyer_refund_requests, seller)
    create(:purchase_refund_policy, purchase:, max_refund_period_in_days: 30)
  end

  it "sends a request from the receipt link and shows its status as it changes" do
    visit page_link
    expect(page).to have_selector("h2", text: "Request a refund")

    choose "The product wasn't as described"
    fill_in "Anything else Jane Doe should know? (optional)", with: "Two brushes are missing."
    expect do
      click_on "Send refund request"
      expect(page).to have_selector("h2", text: "Refund requested")
    end.to have_enqueued_mail(ContactingCreatorMailer, :refund_requested)
      .and have_enqueued_mail(CustomerLowPriorityMailer, :refund_request_received)
    expect(page).to have_text("We sent your request to Jane Doe.")
    expect(PurchaseRefundRequest.find_by(purchase:).message).to eq("Two brushes are missing.")

    travel_to(5.days.from_now) { PurchaseRefundRequests::EscalateOverdueJob.new.perform }
    visit page_link
    expect(page).to have_selector("h2", text: "Gumroad support is reviewing your request")

    purchase.update!(stripe_refunded: true)
    visit page_link
    expect(page).to have_selector("h2", text: "Refunded")
  end

  it "says why a purchase past its refund window can't be refunded here" do
    purchase.update!(created_at: 31.days.ago)

    visit page_link

    expect(page).to have_selector("h2", text: "Refund not available")
    expect(page).to have_text("The refund window for this purchase ended on")
    expect(page).not_to have_button("Send refund request")
  end
end
