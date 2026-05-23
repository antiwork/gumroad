# frozen_string_literal: true

require "test_helper"

class BacktaxAgreementTest < ActiveSupport::TestCase
  self.described_class = BacktaxAgreement



  context_ BacktaxAgreement do
  context_ "validation" do
  test "is valid with expected parameters" do
        expect(build(:backtax_agreement)).to be_valid
      end

  test "validates the presence of a signature" do
        expect(build(:backtax_agreement, signature: nil)).to be_invalid
      end

  test "validates the inclusion of jurisdiction within a certain set" do
        expect(build(:backtax_agreement, jurisdiction: "United States")).to be_invalid
      end
    end
  end
end
