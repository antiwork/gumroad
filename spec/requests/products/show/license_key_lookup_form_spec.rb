# frozen_string_literal: true

require "spec_helper"

describe "License key lookup form", :js, :sidekiq_inline, type: :system do
  include ActiveJob::TestHelper

  let(:seller) { create(:named_user) }
  let(:email) { "buyer@example.com" }
  let(:wanted_product) { create(:product, user: seller, name: "Photo Editor Pro", unique_permalink: "photoed") }
  let(:other_product) { create(:product, user: seller, name: "Unrelated Course") }
  let!(:wanted_purchase) { create(:purchase, link: wanted_product, email:, price_cents: 100, fee_cents: 30) }
  let!(:other_purchase) { create(:purchase, link: other_product, email:, price_cents: 100, fee_cents: 30) }

  it "emails only the named product when the buyer narrows the lookup" do
    visit license_key_lookup_path

    fill_in "What email address did you use?", with: email
    fill_in "Which product? (optional, name/permalink/URL)", with: "Photo Editor"
    perform_enqueued_jobs do
      first("button", text: "Search").click
      expect(page).to have_text("We were able to find a match!")
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([email])
    expect(mail.body.encoded).to include(wanted_product.name)
    expect(mail.body.encoded).not_to include(other_product.name)
  end

  it "emails every purchase, unchanged, when the product field is left blank" do
    visit license_key_lookup_path

    fill_in "What email address did you use?", with: email
    perform_enqueued_jobs do
      first("button", text: "Search").click
      expect(page).to have_text("We were able to find a match!")
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.body.encoded).to include(wanted_product.name)
    expect(mail.body.encoded).to include(other_product.name)
  end
end
