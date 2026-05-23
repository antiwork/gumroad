# frozen_string_literal: true

require "test_helper"

class ServicesSafeRedirectPathServiceTest < ActiveSupport::TestCase



  context_ "SafeRedirectPathService" do
    before do
      @request = OpenStruct.new(host: "test.gumroad.com")
    end

    let(:service) { SafeRedirectPathService.new(@path, @request) }

  context_ "#process" do
  context_ "when path has a subdomain host" do
        before do
          @path = "https://username.test.gumroad.com:31337/123"
          stub_const("ROOT_DOMAIN", "test.gumroad.com")
        end

  context_ "when subdomain host is allowed" do
  test "returns path" do
            expect(service.process).to eq @path
          end
        end

  context_ "when subdomain host is not allowed" do
          let(:service) { SafeRedirectPathService.new(@path, @request, allow_subdomain_host: false) }

  test "returns relative path" do
            expect(service.process).to eq "/123"
          end
        end
      end

  context_ "when hosts of request and path are same" do
  test "returns path" do
          @request = OpenStruct.new(host: "test2.gumroad.com")
          @path = "https://test2.gumroad.com/123"

          expect(service.process).to eq @path
        end
      end

  context_ "when path is a relative path" do
  test "returns path" do
          @path = "/test3"

          expect(service.process).to eq @path
        end
      end

  context_ "when safety conditions aren't met" do
  test "returns parsed path" do
          @path = "http://example.com/test?a=b"

          expect(service.process).to eq "/test?a=b"
        end
      end

  context_ "when path is an escaped external url" do
  test "clears the parsed path" do
          @path = "////evil.org"
          expect(service.process).to eq "/evil.org"
        end

  test "decodes the parsed path" do
          @path = "///%2Fevil.org"
          expect(service.process).to eq "/evil.org"
        end
      end

  context_ "when domain contains regex special characters" do
        before do
          stub_const("ROOT_DOMAIN", "gumroad.com")
        end

  test "does not match malicious domains that try to exploit unescaped dots" do
          @path = "https://attacker.gumroadXcom/malicious"
          expect(service.process).to eq "/malicious"
        end

  test "correctly matches legitimate subdomains" do
          @path = "https://user.gumroad.com/legitimate"
          expect(service.process).to eq @path
        end
      end

  context_ "when there is only a query parameter" do
  test "does not prepend unnecessary forward slash" do
          @path = "?query=param"
          expect(service.process).to eq "?query=param"
        end
      end

  context_ "when path is nil" do
  test "raises TypeError" do
          @path = nil
          expect { service.process }.to raise_error(TypeError)
        end
      end

  context_ "when path is an empty string" do
  test "raises an error" do
          @path = ""
          expect { service.process }.to raise_error(URI::InvalidURIError)
        end
      end
    end
  end
end
