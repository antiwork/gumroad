# frozen_string_literal: true

require "spec_helper"

describe RegionalVatIdValidationService do
  it "returns false instead of raising when the vendor connection times out" do
    allow_any_instance_of(AbnValidationService).to receive(:process).and_raise(Net::ReadTimeout)

    expect(described_class.new("51824753556", country_code: Compliance::Countries::AUS.alpha2).process).to be(false)
  end

  it "returns false when the vendor host cannot be resolved" do
    allow_any_instance_of(GstValidationService).to receive(:process).and_raise(SocketError)

    expect(described_class.new("202012345A", country_code: Compliance::Countries::SGP.alpha2).process).to be(false)
  end

  it "returns false when the vendor refuses the connection" do
    allow_any_instance_of(AbnValidationService).to receive(:process).and_raise(Errno::ECONNREFUSED)

    expect(described_class.new("51824753556", country_code: Compliance::Countries::AUS.alpha2).process).to be(false)
  end

  it "retries the vendor on the next call instead of caching the failure" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    ok = { "valid" => true, "active" => true }
    calls = [-> { raise Net::ReadTimeout }, -> { ok }]
    allow(HTTParty).to receive(:post) { calls.shift.call }
    service = described_class.new("51824753556", country_code: Compliance::Countries::AUS.alpha2)

    expect(service.process).to be(false)
    expect(service.process).to be(true)
    expect(HTTParty).to have_received(:post).twice
  end

  it "does not swallow programming errors" do
    allow_any_instance_of(AbnValidationService).to receive(:process).and_raise(NoMethodError)

    expect do
      described_class.new("51824753556", country_code: Compliance::Countries::AUS.alpha2).process
    end.to raise_error(NoMethodError)
  end
end
