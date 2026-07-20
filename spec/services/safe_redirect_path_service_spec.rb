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

    context "when path uses a backslash to disguise an external host" do
      it "treats the backslash as a path separator like browsers do and returns a relative path on the current host" do
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
        @path = "https://evil.com\\@username.test.gumroad.com/l/ggocri"

        expect(service.process).to eq "/@username.test.gumroad.com/l/ggocri"
      end
    end

    context "when path uses a percent-encoded backslash to disguise an external host" do
      it "treats the decoded backslash as a path separator like browsers do and returns a relative path on the current host" do
        stub_const("ROOT_DOMAIN", "test.gumroad.com")
        @path = "https://evil.com%5C@username.test.gumroad.com/l/ggocri"

        expect(service.process).to eq "/@username.test.gumroad.com/l/ggocri"
      end
    end

    context "when a same-host path has a backslash in the query string" do
      it "preserves the backslash because browsers do not treat it as a separator in the query" do
        @request = OpenStruct.new(host: "test2.gumroad.com")
        @path = "https://test2.gumroad.com/search?q=C:\\foo"

        expect(service.process).to eq "https://test2.gumroad.com/search?q=C:\\foo"
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

    context "when path is a bare relative path without a leading slash" do
      it "prepends a slash so the redirect stays on the current host" do
        @path = "dashboard"
        expect(service.process).to eq "/dashboard"
      end

      it "prepends a slash and preserves the query string" do
        @path = "library?sort=recent"
        expect(service.process).to eq "/library?sort=recent"
      end
    end

    context "when there is only a query parameter" do
      it "does not prepend unnecessary forward slash" do
        @path = "?query=param"
        expect(service.process).to eq "?query=param"
      end
    end

    context "when path is nil" do
      it "raises TypeError" do
        @path = nil
        expect { service.process }.to raise_error(TypeError)
      end
    end

    context "when path is an empty string" do
      it "raises an error" do
        @path = ""
        expect { service.process }.to raise_error(URI::InvalidURIError)
      end
    end
  end
end
