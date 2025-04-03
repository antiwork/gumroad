# frozen_string_literal: true

describe RenewCustomDomainSslCertificates do
  describe "#perform" do
    before do
      @obj_double = double("SslCertificates::Renew object")
      allow(SslCertificates::Renew).to receive(:new).and_return(@obj_double)
      allow(@obj_double).to receive(:process)
    end

    context "when the environment is production or staging" do
      before do
        allow(Rails.env).to receive(:production?).and_return(true)
      end

      it "invokes SslCertificates::Generate service" do
        expect(SslCertificates::Renew).to receive(:new)
        expect(@obj_double).to receive(:process)

        described_class.new.perform
      end
    end

    context "when the environment is not production or staging" do
      it "doesn't invoke SslCertificates::Generate service" do
        expect(SslCertificates::Renew).not_to receive(:new)
        expect(@obj_double).not_to receive(:process)

        described_class.new.perform
      end
    end
  end
end
