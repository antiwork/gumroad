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

    it "enques job for generating SSL certificate" do
      expect(CustomDomain).to receive(:certificate_absent_or_older_than).with(@obj.send(:renew_in))
      expect(@custom_domain).to receive(:generate_ssl_certificate)

      @obj.process
    end
  end
end
