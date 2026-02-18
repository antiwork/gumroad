# frozen_string_literal: true
require "spec_helper"
require "shared_examples/authorize_called"
require "inertia_rails/rspec"

describe Products::ProductTabController, inertia: true do
  render_views
  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"
  let(:product) { create(:product, user: seller) }

  it "returns 409 when lock_version is stale" do
    product.update_columns(lock_version: product.lock_version + 1)
    patch :update, params: { id: product.unique_permalink, link: { name: "Tab B", lock_version: product.lock_version - 1 } }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("conflict")
  end

  it "returns lock_version in response on successful save" do
    patch :update, params: { id: product.unique_permalink, link: { name: "New Name", lock_version: product.lock_version } }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["lock_version"]).to eq(product.reload.lock_version)
  end
end

describe Products::ContentTabController, inertia: true do
  render_views
  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"
  let(:product) { create(:product, user: seller) }

  it "returns 409 when lock_version is stale" do
    product.update_columns(lock_version: product.lock_version + 1)
    patch :update, params: { id: product.unique_permalink, link: { preview_url: "", lock_version: product.lock_version - 1 } }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("conflict")
  end
end

describe Products::ReceiptTabController, inertia: true do
  render_views
  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"
  let(:product) { create(:product, user: seller) }

  it "returns 409 when lock_version is stale" do
    product.update_columns(lock_version: product.lock_version + 1)
    patch :update, params: { id: product.unique_permalink, link: { custom_receipt_text: "Thanks!", lock_version: product.lock_version - 1 } }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("conflict")
  end
end

describe Products::ShareTabController, inertia: true do
  render_views
  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"
  let(:product) { create(:product, user: seller) }

  it "returns 409 when lock_version is stale" do
    product.update_columns(lock_version: product.lock_version + 1)
    patch :update, params: { id: product.unique_permalink, link: { is_adult: false, lock_version: product.lock_version - 1 } }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("conflict")
  end
end

describe LinksController do
  let(:seller) { create(:named_seller) }
  include_context "with user signed in as admin for seller"
  let(:product) { create(:product, user: seller) }

  it "returns 409 on stale lock_version" do
    product  # force creation before mock
    allow_any_instance_of(Link).to receive(:save!).and_raise(ActiveRecord::StaleObjectError)
    post :update, params: { id: product.unique_permalink, link: { name: "Tab B", lock_version: product.lock_version } }
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body["error"]).to eq("conflict")
  end

  it "returns lock_version on successful save" do
    post :update, params: { id: product.unique_permalink, link: { name: "New Name", lock_version: product.lock_version } }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["lock_version"]).to eq(product.reload.lock_version)
  end
end
