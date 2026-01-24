# frozen_string_literal: true

require "spec_helper"

describe "Communities Inertia Endpoints", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:seller) { create(:user) }
  let(:product) { create(:product, user: seller, community_chat_enabled: true) }
  let!(:community) { create(:community, seller:, resource: product) }

  before do
    Feature.activate_user(:communities, seller)
    sign_in seller
  end

  it "renders Inertia component for /communities" do
    get "/communities"
    expect(response).to be_successful
    expect(response.headers["Vary"]).to include("Accept")
    expect(response.body).to include("Communities/Index")
  end

  it "renders Inertia component for /communities/:id" do
    get "/communities/#{community.external_id}"
    expect(response).to be_successful
    expect(response.headers["Vary"]).to include("Accept")
    expect(response.body).to include("Communities/Show")
  end

  it "renders Inertia component for /communities/:seller_id/:community_iid" do
    get "/communities/#{seller.id}/#{community.external_id}"
    expect(response).to be_successful
    expect(response.headers["Vary"]).to include("Accept")
    expect(response.body).to include("Communities/Show")
  end
end
