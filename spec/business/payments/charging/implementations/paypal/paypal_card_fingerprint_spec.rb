# frozen_string_literal: true

require "spec_helper"

describe PaypalCardFingerprint do
  describe "build_paypal_fingerprint" do
    describe "paypal account has an email address" do
      let(:email) { "jane.doe@gmail.com" }

      it "forms a fingerprint using the email" do
        expect(subject.build_paypal_fingerprint(email)).to eq("paypal_jane.doe@gmail.com")
      end
    end

    describe "paypal account has an invalidly formed address" do
      let(:email) { "jane.doe" }

      it "forms a fingerprint using the email" do
        expect(subject.build_paypal_fingerprint(email)).to eq("paypal_jane.doe")
      end
    end

    describe "paypal account has a whitespace email address" do
      let(:email) { "  " }

      it "returns nil" do
        expect(subject.build_paypal_fingerprint(email)).to be_nil
      end
    end

    describe "paypal account has no email address" do
      let(:email) { nil }

      it "returns nil" do
        expect(subject.build_paypal_fingerprint(email)).to be_nil
      end
    end
  end
end
