# frozen_string_literal: true

require "spec_helper"

describe "SafeRedirectPathService" do
  before do
    @request = OpenStruct.new(host: "test.gumroad.com")
  end

  let(:service) { SafeRedirectPathService.new(@path, @request) }

  describe "#process" do
    context "when path has a subdomain host" do
      before do
        @path = "https://username.test.gumroad.com:31337/123"
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
      end

      context "when subdomain host is allowed" do
        it "returns path" do
          expect(service.process).to eq @path
        end
      end

      context "when subdomain host is not allowed" do
        let(:service) { SafeRedirectPathService.new(@path, @request, allow_subdomain_host: false) }

        it "returns relative path" do
          expect(service.process).to eq "/123"
        end
      end
    end

    context "when hosts of request and path are same" do
      it "returns path" do
        @request = OpenStruct.new(host: "test2.gumroad.com")
        @path = "https://test2.gumroad.com/123"

        expect(service.process).to eq @path
      end
    end

    context "when path is a relative path" do
      it "returns path" do
        @path = "/test3"

        expect(service.process).to eq @path
      end
    end

    context "when safety conditions aren't met" do
      it "returns parsed path" do
        @path = "http://example.com/test?a=b"

        expect(service.process).to eq "/test?a=b"
      end
    end

    context "when path is an escaped external url" do
      it "clears the parsed path" do
        @path = "////evil.org"
        expect(service.process).to eq "/evil.org"
      end

      it "decodes the parsed path" do
        @path = "///%2Fevil.org"
        expect(service.process).to eq "/evil.org"
      end
    end

    context "when domain contains regex special characters" do
      before do
        stub_const("ROOT_DOMAIN", "gumroad.com")
      end

      it "does not match malicious domains that try to exploit unescaped dots" do
        @path = "https://attacker.gumroadXcom/malicious"
        expect(service.process).to eq "/malicious"
      end

      it "correctly matches legitimate subdomains" do
        @path = "https://user.gumroad.com/legitimate"
        expect(service.process).to eq @path
      end
    end

    context "when there is only a query parameter" do
      it "does not prepend unnecessary forward slash" do
        @path = "?query=param"
        expect(service.process).to eq "?query=param"
      end
    end
  end
end
