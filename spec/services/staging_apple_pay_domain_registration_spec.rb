# frozen_string_literal: true

require "spec_helper"

describe StagingApplePayDomainRegistration do
  describe ".applicable?" do
    it "is false outside staging branch deployments" do
      expect(described_class.applicable?).to eq(false)
    end

    context "on a staging branch deployment with a custom domain" do
      before do
        allow(Rails.env).to receive(:staging?).and_return(true)
        stub_const("ENV", ENV.to_h.merge("BRANCH_DEPLOYMENT" => "true", "CUSTOM_DOMAIN" => "my-branch.apps.staging.gumroad.org"))
      end

      it "is true" do
        expect(described_class.applicable?).to eq(true)
      end

      it "is false without a custom domain" do
        stub_const("ENV", ENV.to_h.merge("CUSTOM_DOMAIN" => nil))

        expect(described_class.applicable?).to eq(false)
      end
    end
  end

  describe ".register!" do
    before do
      stub_const("ENV", ENV.to_h.merge("CUSTOM_DOMAIN" => "my-branch.apps.staging.gumroad.org"))
      allow(Stripe::PaymentMethodDomain).to receive(:create).with(domain_name: "my-branch.apps.staging.gumroad.org").and_return(double(id: "pmd_123"))
      allow(Stripe::PaymentMethodDomain).to receive(:validate).with("pmd_123").and_return(pm_domain)
    end

    context "when Apple Pay is active on the domain" do
      let(:pm_domain) { double(id: "pmd_123", apple_pay: double(status: "active")) }

      it "returns an active result" do
        result = described_class.register!

        expect(result.active?).to eq(true)
        expect(result.message).to eq("Apple Pay on my-branch.apps.staging.gumroad.org: active")
      end
    end

    context "when Apple Pay is inactive on the domain" do
      let(:pm_domain) do
        double(
          id: "pmd_123",
          apple_pay: double(status: "inactive", status_details: double(error_message: "Domain verification failed")),
        )
      end

      it "returns an inactive result with Stripe's error message" do
        result = described_class.register!

        expect(result.active?).to eq(false)
        expect(result.message).to eq("Apple Pay on my-branch.apps.staging.gumroad.org: inactive — Domain verification failed")
      end
    end
  end
end
