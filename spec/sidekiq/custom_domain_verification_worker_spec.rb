# frozen_string_literal: true

require "spec_helper"

describe CustomDomainVerificationWorker do
  let!(:valid_custom_domain) { create(:custom_domain) }
  let!(:invalid_custom_domain) { create(:custom_domain, state: "unverified", failed_verification_attempts_count: 2) }
  let!(:deleted_custom_domain) { create(:custom_domain, deleted_at: 2.days.ago) }
  let(:valid_verification_service) { double(process: true, domains_resolving_to_gumroad: [valid_custom_domain.domain]) }
  let(:invalid_verification_service) { double(process: false, domains_resolving_to_gumroad: []) }

  before do
    allow(CustomDomainVerificationService)
      .to receive(:new)
      .with(domain: valid_custom_domain.domain)
      .and_return(valid_verification_service)

    allow(CustomDomainVerificationService)
      .to receive(:new)
      .with(domain: invalid_custom_domain.domain)
      .and_return(invalid_verification_service)
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

  it "caches whether the configured hostname strictly resolves to Gumroad" do
    described_class.new.perform(valid_custom_domain.id)

    expect(Rails.cache.read(valid_custom_domain.send(:routability_cache_key))).to be(true)
  end

  it "caches false when only the configured hostname's counterpart resolves to Gumroad" do
    allow(valid_verification_service)
      .to receive(:domains_resolving_to_gumroad)
      .and_return(["www.#{valid_custom_domain.domain}"])

    described_class.new.perform(valid_custom_domain.id)

    expect(Rails.cache.read(valid_custom_domain.send(:routability_cache_key))).to be(false)
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
