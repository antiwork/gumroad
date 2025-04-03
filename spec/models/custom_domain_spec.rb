# frozen_string_literal: true

require "spec_helper"

describe CustomDomain do
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
                            "example.com.", "127.0.0.1", "2001:db8:3333:4444:5555:6666:7777:8888"]
      end

      it "throws an ActiveRecord::RecordInvalid error" do
        @invalid_domains.each do |invalid_domain|
          domain = build(:custom_domain, domain: invalid_domain)

          expect { domain.save! }.to raise_error(ActiveRecord::RecordInvalid)
          expect(domain.errors[:base].first).to eq("#{invalid_domain} is not a valid domain name.")
        end
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
  end

  describe "#reset_ssl_certificate_issued_at" do
    before do
      @domain = create(:custom_domain, domain: "www.example.com")
      @domain.set_ssl_certificate_issued_at!
    end

    it "resets ssl_certificate_issued_at on save if the domain is changed" do
      @domain.domain = "example2.com"
      @domain.save!

      expect(@domain.reload.ssl_certificate_issued_at).to be_nil
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
