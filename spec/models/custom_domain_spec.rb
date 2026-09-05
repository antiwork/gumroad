# frozen_string_literal: true

require "spec_helper"

describe CustomDomain do
  # The real production config, not spec/support/fixtures/ssl_certificates.yml.erb, and read
  # directly rather than through SslCertificates::Base — Base fetches Rails.env and the real
  # config has no "test" key, so instantiating it here raises KeyError.
  def ssl_certificates_config
    YAML.load(ERB.new(File.read(Rails.root.join("config", "ssl_certificates.yml.erb"))).result, aliases: true)
  end

  def production_renew_in
    ssl_certificates_config.fetch("production").fetch("renew_in").seconds
  end

  describe "#validate_domain_format" do
    context "with a valid domain name" do
      before do
        @valid_domains = ["example.com", "example-store2.com", "test.example.com", "test-store.example.com"]
      end
      it "saves the domain" do
        @valid_domains.each do |valid_domain|
          domain = build(:custom_domain, domain: valid_domain)
          expect(domain.valid?).to eq true
        end
      end
    end

    context "with an invalid domain name" do
      before do
        @invalid_domains = [nil, "", "test_store.example.com", "http:www.example.com", "www.example.com/test",
                            "example", "example.", "example.com.", "example domain.com", "example@example.com",
                            "example.com.", "example..com", "sub.example...com", "-example.com", "example-.com",
                            "sub.-example.com", "127.0.0.1", "2001:db8:3333:4444:5555:6666:7777:8888"]
      end

      it "throws an ActiveRecord::RecordInvalid error" do
        @invalid_domains.each do |invalid_domain|
          domain = build(:custom_domain, domain: invalid_domain)

          expect { domain.save! }.to raise_error(ActiveRecord::RecordInvalid)
          expect(domain.errors[:base].first).to eq("#{invalid_domain} is not a valid domain name.")
        end
      end
    end

    context "with a persisted record whose domain fails the current validation" do
      it "still allows soft-deleting the record" do
        # Rows saved before a validation existed can carry domains that fail
        # it now. Deleting such a record must not raise — deletion is exactly
        # how a seller or admin removes the broken domain.
        domain = build(:custom_domain, domain: "example..com")
        domain.save(validate: false)

        expect { domain.mark_deleted! }.not_to raise_error
        expect(domain.reload.deleted?).to eq(true)
      end
    end
  end

  describe "#validate_domain_is_allowed" do
    before do
      stub_const("ROOT_DOMAIN", "gumroad.com")
      stub_const("DOMAIN", "gumroad.com")
      stub_const("SHORT_DOMAIN", "gum.co")
      stub_const("API_DOMAIN", "api.gumroad.com")
      stub_const("DISCOVER_DOMAIN", "discover.gumroad.com")
      stub_const("INTERNAL_GUMROAD_DOMAIN", "gumroad.net")
    end

    context "when the domain name matches one of the forbidden domain names" do
      before do
        @invalid_domains = [
          DOMAIN, ROOT_DOMAIN, SHORT_DOMAIN, API_DOMAIN, DISCOVER_DOMAIN,
          "subdomain.#{DOMAIN}", "subdomain.#{ROOT_DOMAIN}", "subdomain.#{SHORT_DOMAIN}",
          "subdomain.#{API_DOMAIN}", "subdomain.#{DISCOVER_DOMAIN}", "subdomain.#{INTERNAL_GUMROAD_DOMAIN}"
        ]
      end

      it "marks the record as invalid" do
        @invalid_domains.each do |invalid_domain|
          domain = build(:custom_domain, domain: invalid_domain)

          expect(domain.valid?).to eq(false)
          expect(domain.errors[:base].first).to eq("#{invalid_domain} is not a valid domain name.")
        end
      end
    end

    context "when the domain doesn't match with any of the forbidden root domain names" do
      before do
        @valid_domains = ["test#{ROOT_DOMAIN}", "test#{SHORT_DOMAIN}"]
      end

      it "marks the record as valid" do
        @valid_domains.each do |valid_domain|
          domain = build(:custom_domain, domain: valid_domain)

          expect(domain.valid?).to eq(true)
        end
      end
    end
  end

  describe "saving a domain that another user has already saved" do
    before do
      create(:custom_domain, domain: "www.example.com")
    end

    context "when the domain is the same" do
      before do
        @domain = build(:custom_domain, domain: "www.example.com")
      end

      context "when the custom domain is validated" do
        it "throws an ActiveRecord::RecordInvalid error" do
          expect { @domain.save! }.to raise_error(ActiveRecord::RecordInvalid)
          expect(@domain.errors[:base].first).to eq("The custom domain is already in use.")
        end
      end
    end

    context "when the domain is the same except www. is not included" do
      before do
        @domain = build(:custom_domain, domain: "example.com")
      end

      it "throws an ActiveRecord::RecordInvalid error" do
        expect { @domain.save! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(@domain.errors[:base].first).to eq("The custom domain is already in use.")
      end
    end
  end

  describe "saving a domain that does not have an associated user" do
    let(:domain) { build(:custom_domain, domain: "www.example.com", user: nil, product:) }

    context "when the domain has an associated product" do
      let(:product) { create(:product) }

      it "marks the record as valid" do
        expect(domain.valid?).to eq(true)
      end
    end

    context "when the domain does not have an associated product" do
      let(:product) { nil }

      it "throws an ActiveRecord::RecordInvalid error" do
        expect { domain.save! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(domain.errors[:base].first).to eq("Requires an associated user or product.")
      end
    end
  end

  describe "stripped_fields" do
    it "strips leading and trailing spaces and downcases domain on save" do
      custom_domain = create(:custom_domain, domain: "  www.Example.com  ")

      expect(custom_domain.domain).to eq "www.example.com"
    end
  end

  describe "#set_ssl_certificate_issued_at" do
    it "sets ssl_certificate_issued_at" do
      time = Time.current
      domain = create(:custom_domain, domain: "www.example.com")

      travel_to(time) do
        domain.set_ssl_certificate_issued_at!
      end

      expect(domain.reload.ssl_certificate_issued_at.to_i).to eq time.to_i
    end
  end

  describe "#generate_ssl_certificate" do
    before do
      @domain = create(:custom_domain, domain: "www.example.com")
    end

    it "invokes GenerateSslCertificate worker on create" do
      expect(GenerateSslCertificate).to have_enqueued_sidekiq_job(anything)

      create(:custom_domain, domain: "example3.com")
    end

    it "invokes GenerateSslCertificate worker on save when the domain is changed" do
      expect(GenerateSslCertificate).to have_enqueued_sidekiq_job(@domain.id)

      @domain.domain = "example2.com"
      @domain.save!
    end

    it "doesn't invoke GenerateSslCertificate worker on save when the domain is not changed" do
      expect(GenerateSslCertificate).to have_enqueued_sidekiq_job(@domain.id)

      @domain.save!
    end

    it "applies the renewal dedupe lock only when asked" do
      GenerateSslCertificate.clear

      @domain.generate_ssl_certificate
      expect(GenerateSslCertificate.jobs.last).not_to include("lock")

      @domain.generate_ssl_certificate(dedupe: true)
      expect(GenerateSslCertificate.jobs.last).to include(
        "lock" => "until_executing", "on_conflict" => "log", "lock_ttl" => 3.hours.to_i
      )
    end
  end

  describe "#certificate_orderable?" do
    before do
      @domain = create(:custom_domain, domain: "www.example.com")
      Rails.cache.clear
    end

    it "returns true for a structurally valid domain with no negative cache" do
      expect(@domain.certificate_orderable?).to eq true
    end

    it "returns false for a domain whose order was recently cached as failed" do
      Rails.cache.write("domain_check_www.example.com", false)
      expect(@domain.certificate_orderable?).to eq false
    end

    it "returns false for a name Let's Encrypt rejects outright" do
      @domain.domain = "domains.example..com"
      @domain.save(validate: false)

      expect(@domain.certificate_orderable?).to eq false
    end

    it "returns false for a domain under a forbidden suffix" do
      stub_const("ROOT_DOMAIN", "gumroad.com")
      stub_const("DOMAIN", "gumroad.com")
      stub_const("SHORT_DOMAIN", "gumroad.com")
      stub_const("API_DOMAIN", "api.gumroad.com")
      stub_const("DISCOVER_DOMAIN", "discover.gumroad.com")
      stub_const("INTERNAL_GUMROAD_DOMAIN", "internal.gumroad.com")

      @domain.domain = "test.gumroad.com"
      @domain.save(validate: false)

      expect(@domain.certificate_orderable?).to eq false
    end
  end

  describe "#reset_ssl_certificate_issued_at" do
    before do
      @domain = create(:custom_domain, domain: "www.example.com")
      @domain.set_ssl_certificate_issued_at!
    end

    it "resets ssl_certificate_issued_at on save if the domain is changed" do
      @domain.set_routability!(true)
      @domain.domain = "example2.com"
      @domain.save!

      expect(@domain.reload.ssl_certificate_issued_at).to be_nil
      expect(@domain.routable).to be_nil
      expect(@domain.routability_checked_at).to be_nil
    end

    it "doesn't reset ssl_certificate_issued_at on save if the domain is not changed" do
      @domain.save!

      expect(@domain.reload.ssl_certificate_issued_at).not_to be_nil
    end
  end

  describe "#convert_to_lowercase" do
    it "converts characters of domain to lower case" do
      domain = create(:custom_domain, domain: "Store.Example.com")

      expect(domain.domain).to eq "store.example.com"
    end
  end

  describe "#reset_ssl_certificate_issued_at!" do
    it "resets ssl_certificate_issued_at" do
      domain = create(:custom_domain, domain: "www.example.com")
      domain.set_ssl_certificate_issued_at!
      domain.reset_ssl_certificate_issued_at!

      expect(domain.reload.ssl_certificate_issued_at).to be_nil
    end
  end

  describe "#has_valid_certificate?" do
    before do
      @renew_in = 80.days
    end

    it "returns true if certificate issued time is within renewal time" do
      domain = create(:custom_domain, domain: "www.example.com")

      travel_to(79.days.ago) do
        domain.set_ssl_certificate_issued_at!
      end

      expect(domain.reload.has_valid_certificate?(@renew_in)).to be true
    end

    it "returns false if certificate issued time is not within renewal time" do
      domain = create(:custom_domain, domain: "www.example.com")

      travel_to(81.days.ago) do
        domain.set_ssl_certificate_issued_at!
      end

      expect(domain.reload.has_valid_certificate?(@renew_in)).to be false
    end

    it "returns false if ssl_certificate_issued_at is nil" do
      domain = create(:custom_domain, domain: "www.example.com")

      expect(domain.ssl_certificate_issued_at).to be_nil
      expect(domain.has_valid_certificate?(@renew_in)).to eq(false)
    end
  end

  describe "#strictly_routable?" do
    let(:custom_domain) { create(:custom_domain, :verified_with_certificate) }

    it "returns a current positive result without scheduling DNS verification" do
      custom_domain.set_routability!(true)

      expect(custom_domain.strictly_routable?).to be(true)
      expect(RefreshCustomDomainRoutabilityWorker).not_to have_enqueued_sidekiq_job(custom_domain.id)
    end

    it "returns a current negative result without scheduling DNS verification" do
      custom_domain.set_routability!(false)

      expect(custom_domain.strictly_routable?).to be(false)
      expect(RefreshCustomDomainRoutabilityWorker).not_to have_enqueued_sidekiq_job(custom_domain.id)
    end

    it "falls back and schedules one refresh when the result is unknown" do
      expect(custom_domain.strictly_routable?).to be(false)

      expect(RefreshCustomDomainRoutabilityWorker).to have_enqueued_sidekiq_job(custom_domain.id).once
    end

    it "serves a stale positive result while scheduling a refresh" do
      custom_domain.set_routability!(true)
      custom_domain.update_column(:routability_checked_at, 7.hours.ago)

      expect(custom_domain.strictly_routable?).to be(true)

      expect(RefreshCustomDomainRoutabilityWorker).to have_enqueued_sidekiq_job(custom_domain.id).once
    end

    it "does not use a positive result after the certificate expires" do
      custom_domain.set_routability!(true)
      # Past the certificate's real lifetime, not merely past a week — a week-old
      # certificate is still valid, and so is one that renewal is merely due for.
      custom_domain.update_columns(ssl_certificate_issued_at: (CustomDomain::CERTIFICATE_LIFETIME + 1.day).ago)

      expect(custom_domain.strictly_routable?).to be(false)
      expect(RefreshCustomDomainRoutabilityWorker).not_to have_enqueued_sidekiq_job(custom_domain.id)
    end

    it "does not apply a DNS result after the domain changes" do
      checked_domain = custom_domain.domain
      custom_domain.update!(domain: "new.example.com")

      expect(custom_domain.set_routability!(true, checked_domain:)).to be(false)
      expect(custom_domain.reload.routability_checked_at).to be_nil
    end

    it "does not activate a certificate generated for the previous domain" do
      checked_domain = custom_domain.domain
      custom_domain.update!(domain: "new.example.com")

      expect(custom_domain.activate_with_routability!(true, checked_domain:)).to be(false)
      expect(custom_domain.reload.ssl_certificate_issued_at).to be_nil
      expect(custom_domain.routability_checked_at).to be_nil
    end

    it "does not let an older observation overwrite a newer result" do
      newer_observation = Time.current.change(usec: 0)
      older_observation = newer_observation - 1.minute
      custom_domain.set_routability!(false, observed_at: newer_observation)

      expect(custom_domain.set_routability!(true, observed_at: older_observation)).to be(false)
      expect(custom_domain.reload).not_to be_routable
      expect(custom_domain.routability_checked_at).to eq(newer_observation)
    end

    it "records successful certificate issuance without overwriting a newer routability result" do
      newer_observation = Time.current.change(usec: 0)
      older_observation = newer_observation - 1.minute
      custom_domain.set_routability!(false, observed_at: newer_observation)
      custom_domain.update_column(:ssl_certificate_issued_at, nil)

      expect(custom_domain.activate_with_routability!(true, observed_at: older_observation)).to be(true)
      expect(custom_domain.reload.ssl_certificate_issued_at).to be_present
      expect(custom_domain).not_to be_routable
      expect(custom_domain.routability_checked_at).to eq(newer_observation)
    end
  end

  describe "scopes" do
    before do
      @domain1 = create(:custom_domain, domain: "www.example1.com")
      @domain1.update_column(:ssl_certificate_issued_at, 15.days.ago)

      @domain2 = create(:custom_domain, domain: "www.example2.com")
      @domain2.update_column(:ssl_certificate_issued_at, 5.days.ago)

      # ssl_certificate_issued_at is nil
      @domain3 = create(:custom_domain, domain: "www.example3.com")

      @domain4 = create(:custom_domain, domain: "example4.com", state: "verified")
    end

    describe ".certificate_absent_or_older_than" do
      it "returns the certificates older than the given date" do
        expect(CustomDomain.alive.certificate_absent_or_older_than(10.days)).to match_array [@domain3, @domain1, @domain4]
      end
    end

    describe ".certificates_younger_than" do
      it "returns the certificates younger than the given date" do
        expect(CustomDomain.alive.certificates_younger_than(10.days)).to eq [@domain2]
      end
    end

    describe ".verified" do
      it "returns the verified domains" do
        expect(described_class.verified).to match_array([@domain4])
      end
    end

    describe ".unverified" do
      it "returns the unverified domains" do
        expect(described_class.unverified).to match_array([@domain1, @domain2, @domain3])
      end
    end
  end

  describe "#verify" do
    let(:domain) { create(:custom_domain) }

    context "when the domain is correctly configured" do
      before do
        allow_any_instance_of(CustomDomainVerificationService)
          .to receive(:process)
          .and_return(true)
      end

      context "when the domain is already marked as verified" do
        before do
          domain.mark_verified
        end

        it "does nothing" do
          expect { domain.verify }.to_not change { domain.verified? }
        end
      end

      context "when domain is unverified" do
        before do
          domain.failed_verification_attempts_count = 2
        end

        it "marks the domain as verified and resets 'failed_verification_attempts_count' to 0" do
          expect do
            domain.verify
          end.to change { domain.verified? }.from(false).to(true)
           .and change { domain.failed_verification_attempts_count }.from(2).to(0)
        end
      end
    end

    context "when the domain is not configured correctly" do
      before do
        allow_any_instance_of(CustomDomainVerificationService)
          .to receive(:process)
          .and_return(false)
      end

      context "when the domain is previously marked as verified" do
        before do
          domain.mark_verified
        end

        it "marks the domain as unverified and increments 'failed_verification_attempts_count'" do
          expect do
            expect do
              domain.verify
            end.to change { domain.verified? }.from(true).to(false)
             .and change { domain.failed_verification_attempts_count }.from(0).to(1)
          end
        end
      end

      context "when the domain is already marked as unverified" do
        before do
          domain.failed_verification_attempts_count = 1
        end

        it "increments 'failed_verification_attempts_count'" do
          expect do
            expect do
              expect do
                domain.verify
              end.to_not change { domain.verified? }
            end.to change { domain.failed_verification_attempts_count }.from(1).to(2)
          end
        end

        context "when verification failure attempts count reaches the maximum allowed threshold during the domain verification" do
          before do
            domain.failed_verification_attempts_count = 2
          end

          it "increments 'failed_verification_attempts_count'" do
            expect do
              expect do
                expect do
                  domain.verify
                end.to_not change { domain.verified? }
              end.to change { domain.failed_verification_attempts_count }.from(2).to(3)
            end
          end
        end

        context "when verification failure attempts count has been already equal to or over the maximum allowed threshold before verifying the domain" do
          before do
            domain.failed_verification_attempts_count = 3
          end

          it "does nothing" do
            expect do
              expect do
                expect do
                  domain.verify
                end.to_not change { domain.verified? }
              end.to_not change { domain.failed_verification_attempts_count }
            end
          end
        end

        context "when called with 'allow_incrementing_failed_verification_attempts_count: false' option" do
          before do
            domain.failed_verification_attempts_count = 2
          end

          it "does not increment 'failed_verification_attempts_count'" do
            expect do
              expect do
                expect do
                  domain.verify(allow_incrementing_failed_verification_attempts_count: false)
                end.to_not change { domain.verified? }
              end.to_not change { domain.failed_verification_attempts_count }
            end
          end
        end
      end
    end
  end

  describe "#exceeding_max_failed_verification_attempts?" do
    let(:domain) { create(:custom_domain) }

    context "when verification failure attempts count exceeds the maximum allowed threshold" do
      before do
        domain.failed_verification_attempts_count = 3
      end

      it "returns true" do
        expect(domain.exceeding_max_failed_verification_attempts?).to eq(true)
      end
    end

    context "when verification failure attempts count does not exceed the maximum allowed threshold" do
      before do
        domain.failed_verification_attempts_count = 2
      end

      it "returns false" do
        expect(domain.exceeding_max_failed_verification_attempts?).to eq(false)
      end
    end
  end

  describe "#active?" do
    context "when domain is not verified" do
      let(:domain) { create(:custom_domain) }

      it "returns false" do
        expect(domain.active?).to eq(false)
      end
    end

    context "when domain is verified but does not have a valid certificate" do
      let(:domain) { create(:custom_domain, state: "verified") }

      it "returns false" do
        expect(domain.active?).to eq(false)
      end
    end

    context "when domain is verified and has a valid certificate" do
      let(:domain) { create(:custom_domain, state: "verified") }

      before do
        domain.set_ssl_certificate_issued_at!
      end

      it "returns true" do
        expect(domain.active?).to eq(true)
      end
    end

    context "when the certificate is older than a week but well within its lifetime" do
      let(:domain) { create(:custom_domain, state: "verified") }

      before do
        # Certificates are only regenerated every renew_in (75 days in production), so a
        # 30-day-old certificate is the normal steady state, not a stale one. The old
        # 1.week window called this inactive and dropped the seller back to their subdomain.
        domain.update!(ssl_certificate_issued_at: 30.days.ago)
      end

      it "returns true" do
        expect(domain.active?).to eq(true)
      end
    end

    context "when renewal is due but the replacement certificate has not been issued yet" do
      let(:domain) { create(:custom_domain, state: "verified") }
      let(:renew_in) { production_renew_in }

      before do
        # Renewal is queued asynchronously and can be rate-limited for days. The existing
        # certificate is still valid the whole time, so routing must stay up.
        domain.update!(ssl_certificate_issued_at: (renew_in + 1.day).ago)
      end

      it "keeps routing on the custom domain" do
        expect(CustomDomain.certificate_absent_or_older_than(renew_in)).to include(domain)
        expect(domain.active?).to eq(true)
      end
    end

    context "when the certificate has outlived its lifetime" do
      let(:domain) { create(:custom_domain, state: "verified") }

      before do
        domain.update!(ssl_certificate_issued_at: (CustomDomain::CERTIFICATE_LIFETIME + 1.day).ago)
      end

      it "returns false" do
        expect(domain.active?).to eq(false)
      end
    end
  end

  describe "CERTIFICATE_LIFETIME" do
    it "leaves renewal room ahead of expiry in every configured environment" do
      settings_by_env = ssl_certificates_config

      expect(settings_by_env).to be_present
      settings_by_env.each do |env, settings|
        expect(settings.fetch("renew_in").seconds).to be < CustomDomain::CERTIFICATE_LIFETIME,
                                                      "#{env} renew_in must start renewal before the certificate expires"
      end
    end
  end

  describe "find_by_host" do
    context "when the host matches the domain exactly" do
      before do
        @domain = create(:custom_domain, domain: "www.example.com")
      end

      it "returns the domain" do
        expect(CustomDomain.find_by_host("www.example.com")).to eq(@domain)
      end
    end

    context "when the host has the www. subdomain and the domain is the root domain" do
      before do
        @domain = create(:custom_domain, domain: "example.com")
      end

      it "returns the domain" do
        expect(CustomDomain.find_by_host("www.example.com")).to eq(@domain)
      end
    end

    context "when the domain has the www. subdomain and the host is the root domain" do
      before do
        @domain = create(:custom_domain, domain: "www.example.com")
      end

      it "returns the domain" do
        expect(CustomDomain.find_by_host("example.com")).to eq(@domain)
      end
    end

    context "when the host has a subdomain that is not www. and the domain is the root domain" do
      before do
        @domain = create(:custom_domain, domain: "example.com")
      end

      it "returns nil" do
        expect(CustomDomain.find_by_host("store.example.com")).to be_nil
      end
    end

    context "when the host is the root domain and the domain has a subdomain that is not www." do
      before do
        @domain = create(:custom_domain, domain: "store.example.com")
      end

      it "returns nil" do
        expect(CustomDomain.find_by_host("example.com")).to be_nil
      end
    end
  end
end
