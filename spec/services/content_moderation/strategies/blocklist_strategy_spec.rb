# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::Strategies::BlocklistStrategy do
  before do
    allow(GlobalConfig).to receive(:get).and_call_original
  end

  it "returns compliant when the blocklist is empty" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("")

    result = described_class.new(text: "some text").perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
  end

  it "flags content containing blocked words" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("blocked, forbidden")

    result = described_class.new(text: "This blocked phrase should match").perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["Matched blocked word: blocked"])
  end

  it "matches blocked words case insensitively" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("SeCrEt")

    result = described_class.new(text: "a SECRET appears here").perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["Matched blocked word: SeCrEt"])
  end

  it "uses word boundaries when matching" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("art")

    result = described_class.new(text: "partial article only").perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
  end
end
