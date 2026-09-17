# frozen_string_literal: true

require "spec_helper"

describe Marketing::MetricsStatistics do
  it "matches a known two-sided normal tail for two proportions" do
    a = described_class.proportion(60, 100)
    b = described_class.proportion(40, 100)
    expect(described_class.two_proportion(a, b)).to be_within(0.000001).of(0.004677735)
  end

  it "uses Student t rather than the normal approximation for small revenue samples" do
    a = described_class.sample([1, 2, 3])
    b = described_class.sample([4, 5, 6])
    expect(described_class.welch(a, b)).to be_within(0.000001).of(0.021311641)
    expect(described_class.welch(b, a)).to eq(described_class.welch(a, b))
  end

  it "returns unavailable for insufficient samples and handles constant samples" do
    empty = described_class.proportion(0, 0)
    expect(described_class.two_proportion(empty, empty)).to be_nil
    expect(described_class.welch(described_class.sample([1]), described_class.sample([2]))).to be_nil
    same = described_class.sample([1, 1])
    expect(described_class.welch(same, same)).to eq(1.0)
    expect(described_class.welch(same, described_class.sample([2, 2]))).to eq(0.0)
  end
end
