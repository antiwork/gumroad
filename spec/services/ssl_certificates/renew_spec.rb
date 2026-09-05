# frozen_string_literal: true

require "spec_helper"

describe SslCertificates::Renew do
  before do
    stub_const("SslCertificates::Base::CONFIG_FILE",
               File.join(Rails.root, "spec", "support", "fixtures", "ssl_certificates.yml.erb"))

    @obj = SslCertificates::Renew.new
  end

  it "inherits from SslCertificates::Base" do
    expect(described_class).to be < SslCertificates::Base
  end

  describe "#process" do
    before do
      @custom_domain = create(:custom_domain, domain: "www.example.com")

      allow(CustomDomain).to receive(:certificate_absent_or_older_than)
        .with(@obj.send(:renew_in)).and_return([@custom_domain])
    end

    it "enqueues a job for each orderable domain, with a delay smeared across the hour" do
      expect(CustomDomain).to receive(:certificate_absent_or_older_than).with(@obj.send(:renew_in))
      expect(@custom_domain).to receive(:generate_ssl_certificate).with(delay: kind_of(Numeric))

      @obj.process
    end

    it "skips domains that cannot order a certificate" do
      allow(@custom_domain).to receive(:certificate_orderable?).and_return(false)
      expect(@custom_domain).not_to receive(:generate_ssl_certificate)

      @obj.process
    end

    it "spreads the enqueue delay within the fanout window" do
      allow(@obj).to receive(:rand).and_return(1234)
      expect(@custom_domain).to receive(:generate_ssl_certificate).with(delay: 1236)

      @obj.process
    end
  end
end
