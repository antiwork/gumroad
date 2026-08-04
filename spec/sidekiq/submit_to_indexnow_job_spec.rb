# frozen_string_literal: true

require "spec_helper"

describe SubmitToIndexnowJob do
  let(:key) { "a" * 32 }
  let(:product) { create(:product) }

  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(GlobalConfig).to receive(:get).with("INDEXNOW_KEY").and_return(key)
  end

  it "submits the product URLs to the IndexNow API" do
    stub = stub_request(:post, described_class::ENDPOINT)
      .with(
        headers: { "Content-Type" => "application/json; charset=utf-8" },
        body: hash_including(
          "host" => URI(product.long_url).host,
          "key" => key,
          "urlList" => [product.long_url]
        )
      )
      .to_return(status: 200)

    described_class.new.perform([product.id])

    expect(stub).to have_been_requested
  end

  it "deduplicates URLs before submitting" do
    stub = stub_request(:post, described_class::ENDPOINT)
      .with(body: hash_including("urlList" => [product.long_url]))
      .to_return(status: 200)

    described_class.new.perform([product.id, product.id])

    expect(stub).to have_been_requested
  end

  it "logs the response code and URL count" do
    stub_request(:post, described_class::ENDPOINT).to_return(status: 202)

    expect(Rails.logger).to receive(:info).with("SubmitToIndexnowJob response=202 urls=1")

    described_class.new.perform([product.id])
  end

  context "when the key is not configured" do
    let(:key) { nil }

    it "does not submit anything" do
      described_class.new.perform([product.id])

      expect(WebMock).not_to have_requested(:post, described_class::ENDPOINT)
    end
  end

  context "when no products are found" do
    it "does not submit anything" do
      described_class.new.perform([])

      expect(WebMock).not_to have_requested(:post, described_class::ENDPOINT)
    end
  end

  context "when a product uses a seller subdomain" do
    it "submits using the seller's host, not the root domain" do
      seller_host = URI(product.long_url).host

      stub = stub_request(:post, described_class::ENDPOINT)
        .with(body: hash_including("host" => seller_host, "urlList" => [product.long_url]))
        .to_return(status: 200)

      described_class.new.perform([product.id])

      expect(stub).to have_been_requested
      expect(seller_host).not_to eq(DOMAIN)
    end
  end

  context "when the IndexNow API responds with a failure status" do
    it "raises so Sidekiq retries the job" do
      stub_request(:post, described_class::ENDPOINT).to_return(status: 503)

      expect { described_class.new.perform([product.id]) }.to raise_error(/IndexNow submission failed: 503/)
    end
  end
end
