# frozen_string_literal: true

require "spec_helper"

describe HexColorValidator do
  let(:model) do
    Class.new do
      include ActiveModel::Validations
      attr_accessor :color
      validates :color, hex_color: true

      def self.name = "HexColorValidatable"
    end
  end

  def valid?(value)
    record = model.new
    record.color = value
    record.valid?
  end

  it "accepts a six-digit hex colour in either case" do
    expect(valid?("#ff90e8")).to be(true)
    expect(valid?("#FF90E8")).to be(true)
  end

  it "rejects shorthand, missing hashes, and non-hex characters" do
    ["#fff", "ff90e8", "#ff90e", "#ff90e88", "#gggggg", "", nil].each do |value|
      expect(valid?(value)).to be(false), "expected #{value.inspect} to be rejected"
    end
  end

  # These values are interpolated straight into the storefront stylesheet, so a value that smuggles
  # a newline past the anchors lands in the rendered CSS. Ruby's $ matches before a trailing
  # newline, which is why the anchors must be \A and \z.
  it "rejects a value that hides CSS after a newline" do
    expect(valid?("#ffffff\nbody{display:none}")).to be(false)
    expect(valid?("#ffffff\n")).to be(false)
    expect(valid?("#ffffff\n} body { display: none } .x {")).to be(false)
    expect(valid?("\n#ffffff")).to be(false)
  end
end
