# frozen_string_literal: true

require "spec_helper"

describe "License key lookup", type: :request do
  include ActiveJob::TestHelper

  let(:email) { "buyer@example.com" }
  let(:wanted_product) { create(:product, name: "Photo Editor Pro", unique_permalink: "photoed", is_licensed: true) }
  let(:other_product) { create(:product, name: "Unrelated Course", is_licensed: true) }
  let!(:wanted_purchase) { create(:purchase, link: wanted_product, email:, price_cents: 100, fee_cents: 30) }
  let!(:other_purchase) { create(:purchase, link: other_product, email:, price_cents: 100, fee_cents: 30) }
  let!(:wanted_license) { create(:license, link: wanted_product, purchase: wanted_purchase) }
  let!(:other_license) { create(:license, link: other_product, purchase: other_purchase) }

  before do
    host! DOMAIN
    ActionMailer::Base.deliveries.clear
  end

  def delivered_receipt
    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    ActionMailer::Base.deliveries.last
  end

  it "emails only the queried product's license key when the product name is given" do
    get license_key_lookup_data_path, params: { email:, product_query: "Photo Editor" }

    expect(response.parsed_body["success"]).to be(true)
    mail = delivered_receipt
    expect(mail.to).to eq([email])
    body = mail.body.encoded
    expect(body).to include(wanted_license.serial)
    expect(body).not_to include(other_license.serial)
  end

  it "emails only the queried product's license key when the permalink is given" do
    get license_key_lookup_data_path, params: { email:, product_query: "photoed" }

    expect(response.parsed_body["success"]).to be(true)
    body = delivered_receipt.body.encoded
    expect(body).to include(wanted_license.serial)
    expect(body).not_to include(other_license.serial)
  end

  it "emails every license key when no product query is given" do
    get license_key_lookup_data_path, params: { email: }

    expect(response.parsed_body["success"]).to be(true)
    body = delivered_receipt.body.encoded
    expect(body).to include(wanted_license.serial)
    expect(body).to include(other_license.serial)
  end

  it "falls back to the full set when the query matches nothing the buyer bought" do
    get license_key_lookup_data_path, params: { email:, product_query: "never bought this" }

    expect(response.parsed_body["success"]).to be(true)
    body = delivered_receipt.body.encoded
    expect(body).to include(wanted_license.serial)
    expect(body).to include(other_license.serial)
  end

  it "sends nothing and reports false for an email with no purchases" do
    get license_key_lookup_data_path, params: { email: "nobody@example.com" }

    expect(response.parsed_body["success"]).to be(false)
    perform_enqueued_jobs
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end
