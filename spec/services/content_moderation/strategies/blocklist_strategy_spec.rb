# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::Strategies::BlocklistStrategy, :vcr do
  before do
    allow(GlobalConfig).to receive(:get).and_call_original
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(false)
    described_class.reset_yaml_cache!
  end

  after do
    described_class.reset_yaml_cache!
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
    expect(result.reasoning).to eq(["Matched blocked word: secret"])
  end

  it "uses word boundaries when matching" do
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("art")

    result = described_class.new(text: "partial article only").perform

    expect(result.status).to eq("compliant")
    expect(result.reasoning).to eq([])
  end

  it "reads words from the YAML file when present" do
    allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(true)
    allow(YAML).to receive(:load_file).with(described_class::YAML_PATH).and_return("blocklist" => ["yamlword"])
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("")

    result = described_class.new(text: "this contains yamlword in it").perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to eq(["Matched blocked word: yamlword"])
  end

  it "caches the YAML contents across calls" do
    allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(true)
    expect(YAML).to receive(:load_file).with(described_class::YAML_PATH).once.and_return("blocklist" => ["word"])
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("")

    described_class.new(text: "word").perform
    described_class.new(text: "word").perform
    described_class.new(text: "word").perform
  end

  it "unions YAML and GlobalConfig entries and deduplicates" do
    allow(File).to receive(:exist?).with(described_class::YAML_PATH).and_return(true)
    allow(YAML).to receive(:load_file).with(described_class::YAML_PATH).and_return("blocklist" => ["yamlword", "shared"])
    allow(GlobalConfig).to receive(:get).with("CONTENT_MODERATION_BLOCKLIST").and_return("envword, Shared")

    result = described_class.new(text: "mentions yamlword and envword and shared once").perform

    expect(result.status).to eq("flagged")
    expect(result.reasoning).to contain_exactly(
      "Matched blocked word: yamlword",
      "Matched blocked word: shared",
      "Matched blocked word: envword",
    )
  end
end
