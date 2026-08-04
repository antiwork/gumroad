# frozen_string_literal: true

require "spec_helper"

describe GenerateMerchantCenterFeedWorker do
  it "generates the feed with the given product cap" do
    service = instance_double(MerchantCenterFeedService)
    expect(MerchantCenterFeedService).to receive(:new).and_return(service)
    expect(service).to receive(:generate).with(max_products: 500)

    described_class.new.perform(500)
  end

  it "defaults to the service's safety cap" do
    service = instance_double(MerchantCenterFeedService)
    expect(MerchantCenterFeedService).to receive(:new).and_return(service)
    expect(service).to receive(:generate).with(max_products: MerchantCenterFeedService::DEFAULT_MAX_PRODUCTS)

    described_class.new.perform
  end
end
