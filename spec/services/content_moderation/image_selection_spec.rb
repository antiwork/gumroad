# frozen_string_literal: true

require "spec_helper"

RSpec.describe ContentModeration::ImageSelection do
  let(:urls) { 40.times.map { |n| "https://cdn.example.com/#{n}.png" } }

  describe ".ordered" do
    it "returns every URL" do
      expect(described_class.ordered(urls).sort).to eq(urls.sort)
    end

    it "returns the same order every time, so a retry moderates the same images" do
      expect(3.times.map { described_class.ordered(urls) }.uniq.size).to eq(1)
    end

    it "does not return document order, so images cannot be parked past a cap" do
      expect(described_class.ordered(urls)).not_to eq(urls)
    end

    it "orders a URL independently of the other URLs present, so adding an image cannot displace one" do
      before = described_class.ordered(urls)
      after = described_class.ordered(urls + ["https://cdn.example.com/late.png"])

      expect(after.reject { |url| url == "https://cdn.example.com/late.png" }).to eq(before)
    end
  end

  describe ".bounded" do
    it "takes the first `limit` of the deterministic order" do
      expect(described_class.bounded(urls, 5)).to eq(described_class.ordered(urls).first(5))
    end

    it "returns everything, untouched, when the set already fits" do
      short = urls.first(3)

      expect(described_class.bounded(short, 5)).to eq(short)
    end

    it "picks the same subset on every call" do
      expect(3.times.map { described_class.bounded(urls, 5) }.uniq.size).to eq(1)
    end
  end
end
