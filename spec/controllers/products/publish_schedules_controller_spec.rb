# frozen_string_literal: true

require "spec_helper"
require "shared_examples/sellers_base_controller_concern"
require "shared_examples/authorize_called"

describe Products::PublishSchedulesController do
  it_behaves_like "inherits from Sellers::BaseController"

  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller, draft: true) }

  include_context "with user signed in as admin for seller"

  before { Feature.activate_user(:scheduled_product_publishing, seller) }

  def local(hours) = (Time.current + hours.hours).in_time_zone(seller.timezone_id).strftime("%Y-%m-%dT%H:%M")

  it "creates, then cancels a schedule" do
    post :create, params: { link_id: product.unique_permalink, local_time: local(2) }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["publish_schedule"]["status"]).to eq("scheduled")

    delete :destroy, params: { link_id: product.unique_permalink }
    expect(response).to have_http_status(:ok)
    expect(product.reload.publish_schedule).to be_nil
  end

  it "refuses a second schedule while one is pending" do
    create(:product_publish_schedule, product:)
    post :create, params: { link_id: product.unique_permalink, local_time: local(2) }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body["error_message"]).to match(/already has a schedule/)
  end

  it "does not cancel a schedule the job has claimed" do
    schedule = create(:product_publish_schedule, product:, status: "publishing", claimed_at: Time.current)
    delete :destroy, params: { link_id: product.unique_permalink }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(schedule.reload.status).to eq("publishing")
  end

  it "returns the validation message for a too-soon time" do
    post :create, params: { link_id: product.unique_permalink, local_time: local(0) }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "404s for another seller's product" do
    post :create, params: { link_id: create(:product, draft: true).unique_permalink, local_time: local(2) }
    expect(response).to have_http_status(:not_found)
  end

  it "dismisses a failure banner" do
    create(:product_publish_schedule, product:, status: "failed", failure_message: "x")
    delete :destroy, params: { link_id: product.unique_permalink }
    expect(response).to have_http_status(:ok)
    expect(product.reload.publish_schedule).to be_nil
  end
end
