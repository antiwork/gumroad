# frozen_string_literal: true

require "spec_helper"

describe CustomDomainVerificationWorker do
  let!(:valid_custom_domain) { create(:custom_domain) }
  let!(:invalid_custom_domain) { create(:custom_domain, state: "unverified", failed_verification_attempts_count: 2) }
  let!(:deleted_custom_domain) { create(:custom_domain, deleted_at: 2.days.ago) }

  before do
    allow(CustomDomainVerificationService)
      .to receive(:new)
      .with(domain: valid_custom_domain.domain)
      .and_return(double(process: true))

    allow(CustomDomainVerificationService)
      .to receive(:new)
      .with(domain: invalid_custom_domain.domain)
      .and_return(double(process: false))
  end

  it "marks a valid custom domain as verified" do
    expect do
      described_class.new.perform(valid_custom_domain.id)
    end.to change { valid_custom_domain.reload.verified? }.from(false).to(true)
  end

  it "marks an invalid custom domain as unverified" do
    expect do
      expect do
        described_class.new.perform(invalid_custom_domain.id)
      end.to_not change { invalid_custom_domain.reload.verified? }
    end.to change { invalid_custom_domain.failed_verification_attempts_count }.from(2).to(3)
  end

  it "ignores verification of a deleted custom domain" do
    expect do
      described_class.new.perform(deleted_custom_domain.id)
    end.to_not change { deleted_custom_domain.reload }
  end

  it "ignores verification of custom domain with invalid domain names" do
    invalid_domain = build(:custom_domain, domain: "invalid_domain_name.test")
    invalid_domain.save(validate: false)

    expect do
      described_class.new.perform(invalid_domain.id)
    end.to_not change { invalid_domain.reload }
  end
end
