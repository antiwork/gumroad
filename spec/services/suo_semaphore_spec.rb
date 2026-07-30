# frozen_string_literal: true

describe SuoSemaphore do
  describe ".custom_domain_certificate" do
    it "bounds a custom domain's certificate-generation lock" do
      semaphore = described_class.custom_domain_certificate("store.example.com")

      expect(semaphore.key).to eq("locks:custom_domain:store.example.com:certificate")
      expect(semaphore.options[:stale_lock_expiration]).to eq(1.hour.to_i)
    end

    it "serializes an apex and www replacement that write the same certificate set" do
      original_domain = create(:custom_domain, domain: "example.com")
      original_domain.mark_deleted!
      replacement_domain = create(:custom_domain, domain: "www.example.com")
      original_semaphore = described_class.custom_domain_certificate(original_domain.domain)
      replacement_semaphore = described_class.custom_domain_certificate(replacement_domain.domain)
      original_lock_token = original_semaphore.lock

      expect(original_semaphore.key).to eq(replacement_semaphore.key)
      expect(replacement_semaphore.lock).to be_nil
    ensure
      original_semaphore&.unlock(original_lock_token)
    end
  end
end
