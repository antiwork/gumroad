# frozen_string_literal: true

require "test_helper"

class PaypalCardFingerprintTest < ActiveSupport::TestCase
  self.described_class = PaypalCardFingerprint



  context_ PaypalCardFingerprint do
  context_ "build_paypal_fingerprint" do
  context_ "paypal account has an email address" do
        let(:email) { "jane.doe@gmail.com" }

  test "forms a fingerprint using the email" do
          expect(subject.build_paypal_fingerprint(email)).to eq("paypal_jane.doe@gmail.com")
        end
      end

  context_ "paypal account has an invalidly formed address" do
        let(:email) { "jane.doe" }

  test "forms a fingerprint using the email" do
          expect(subject.build_paypal_fingerprint(email)).to eq("paypal_jane.doe")
        end
      end

  context_ "paypal account has a whitespace email address" do
        let(:email) { "  " }

  test "returns nil" do
          expect(subject.build_paypal_fingerprint(email)).to be_nil
        end
      end

  context_ "paypal account has no email address" do
        let(:email) { nil }

  test "returns nil" do
          expect(subject.build_paypal_fingerprint(email)).to be_nil
        end
      end
    end
  end
end
