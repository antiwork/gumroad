# frozen_string_literal: true

require "test_helper"

class ChargeableVisualTest < ActiveSupport::TestCase
  self.described_class = ChargeableVisual



  context_ ChargeableVisual do
  context_ "is_cc_visual" do
  context_ "visual is a credit card" do
        let(:visual) { "**** **** **** 4242" }

  test "returns true" do
          expect(described_class.is_cc_visual(visual)).to eq(true)
        end
      end

  context_ "visual is a weird credit card" do
        let(:visual) { "***A **** **** 4242" }

  test "returns false" do
          expect(described_class.is_cc_visual(visual)).to eq(false)
        end
      end

  context_ "visual is an email address" do
        let(:visual) { "hi@gumroad.com" }

  test "returns false" do
          expect(described_class.is_cc_visual(visual)).to eq(false)
        end
      end
    end

  context_ "build_visual" do
  test "formats all types properly based on card number length" do
        expect(described_class.build_visual("4242", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual("242", 16)).to eq "**** **** **** *242"
        expect(described_class.build_visual("4000 0000 0000 4242", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual("4242", 15)).to eq "**** ****** *4242"
        expect(described_class.build_visual("4242", 14)).to eq "**** ****** 4242"
        expect(described_class.build_visual("4242", 20)).to eq "**** **** **** 4242"
      end

  test "filters out everything but numbers" do
        expect(described_class.build_visual("-42-42", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual(" 4+2@4 2", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual("4%2$4!2", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual("4_2*4&2", 16)).to eq "**** **** **** 4242"
        expect(described_class.build_visual("4%2B4a2", 16)).to eq "**** **** **** 4242"
      end
    end
  end
end
