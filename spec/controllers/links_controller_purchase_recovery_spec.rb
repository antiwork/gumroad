# frozen_string_literal: true

require "spec_helper"

describe LinksController, type: :controller do
  let(:seller) { create(:user) }
  let!(:product) { create(:product, user: seller) }
  let(:event_name) { "product_purchase_recovery_click" }
  let(:params) do
    { id: product.unique_permalink, event_name:, referrer: "https://instagram.com/", view_url: "/l/#{product.unique_permalink}" }
  end

  it "retains recovery clicks from anonymous visitors with the product and referrer" do
    cookies[:_gumroad_guid] = "recovery-visitor"

    expect { post :track_user_action, params:, as: :json }
      .to change { Event.where(event_name:).count }.by(1)

    expect(response).to be_successful
    expect(Event.last).to have_attributes(
      event_name:,
      user_id: nil,
      link_id: product.id,
      browser_guid: "recovery-visitor",
      referrer: "https://instagram.com/",
      view_url: "/l/#{product.unique_permalink}"
    )
  end

  it "does not record the seller's recovery clicks" do
    sign_in seller

    expect { post :track_user_action, params:, as: :json }.not_to change(Event, :count)

    expect(response).to be_successful
  end
end
