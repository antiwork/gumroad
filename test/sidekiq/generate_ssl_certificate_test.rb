# frozen_string_literal: true

require "test_helper"

class GenerateSslCertificateTest < ActiveSupport::TestCase
  self.described_class = GenerateSslCertificate


  context_ GenerateSslCertificate do
  context_ "#perform" do
      before do
        @custom_domain = create(:custom_domain, domain: "www.example.com")
        @obj_double = double("SslCertificates::Generate object")
        allow(SslCertificates::Generate).to receive(:new).with(@custom_domain).and_return(@obj_double)
        allow(@obj_double).to receive(:process)
      end

  context_ "when the environment is production or staging" do
        before do
          allow(Rails.env).to receive(:production?).and_return(true)
        end

  context_ "when the custom domain is not deleted" do
  test "invokes SslCertificates::Generate service" do
            expect(SslCertificates::Generate).to receive(:new).with(@custom_domain)
            expect(@obj_double).to receive(:process)

            described_class.new.perform(@custom_domain.id)
          end
        end

  context_ "when the custom domain is deleted" do
          before do
            @custom_domain.mark_deleted!
          end

  test "doesn't invoke SslCertificates::Generate service" do
            expect(SslCertificates::Generate).not_to receive(:new).with(@custom_domain)

            described_class.new.perform(@custom_domain.id)
          end
        end
      end

  context_ "when the environment is not production or staging" do
  test "doesn't invoke SslCertificates::Generate service" do
          expect(SslCertificates::Generate).not_to receive(:new).with(@custom_domain)
          expect(@obj_double).not_to receive(:process)

          described_class.new.perform(@custom_domain.id)
        end
      end
    end
  end
end
