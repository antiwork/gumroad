# frozen_string_literal: true

require "spec_helper"

describe ChargeableVisual do
  describe "is_cc_visual" do
    describe "visual is a credit card" do
      let(:visual) { "**** **** **** 4242" }

      it "returns true" do
        expect(described_class.is_cc_visual(visual)).to eq(true)
      end
    end

    describe "visual is a weird credit card" do
      let(:visual) { "***A **** **** 4242" }

      it "returns false" do
        expect(described_class.is_cc_visual(visual)).to eq(false)
      end
    end

    describe "visual is an email address" do
      let(:visual) { "hi@gumroad.com" }

      it "returns false" do
        expect(described_class.is_cc_visual(visual)).to eq(false)
      end
    end
  end

  describe "build_visual" do
    it "formats all types properly based on card number length" do
      expect(described_class.build_visual("4242", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual("242", 16)).to eq "**** **** **** *242"
      expect(described_class.build_visual("4000 0000 0000 4242", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual("4242", 15)).to eq "**** ****** *4242"
      expect(described_class.build_visual("4242", 14)).to eq "**** ****** 4242"
      expect(described_class.build_visual("4242", 20)).to eq "**** **** **** 4242"
    end

    it "filters out everything but numbers" do
      expect(described_class.build_visual("-42-42", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual(" 4+2@4 2", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual("4%2$4!2", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual("4_2*4&2", 16)).to eq "**** **** **** 4242"
      expect(described_class.build_visual("4%2B4a2", 16)).to eq "**** **** **** 4242"
    end
  end
end
