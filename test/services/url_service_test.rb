# frozen_string_literal: true

require "test_helper"

class UrlServiceTest < ActiveSupport::TestCase
  self.described_class = UrlService



  context_ UrlService do
  context_ "#domain_with_protocol" do
  test "returns domain with protocol" do
        expect(UrlService.domain_with_protocol).to eq "#{PROTOCOL}://#{DOMAIN}"
      end
    end

  context_ "#api_domain_with_protocol" do
  test "returns domain with protocol" do
        expect(UrlService.api_domain_with_protocol).to eq "#{PROTOCOL}://#{API_DOMAIN}"
      end
    end

  context_ "#short_domain_with_protocol" do
  test "returns short domain with protocol" do
        expect(UrlService.short_domain_with_protocol).to eq "#{PROTOCOL}://#{SHORT_DOMAIN}"
      end
    end

  context_ "#root_domain_with_protocol" do
  test "returns root_domain with protocol" do
        expect(UrlService.root_domain_with_protocol).to eq "#{PROTOCOL}://#{ROOT_DOMAIN}"
      end
    end

  context_ "#discover_domain_with_protocol" do
  test "returns path with procotol and domain" do
        expect(UrlService.discover_domain_with_protocol).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}"
      end
    end

  context_ "#discover_full_path" do
  test "returns path with procotol and domain" do
        expect(UrlService.discover_full_path("/3d")).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}/3d"
      end

  test "returns path and query with procotol and domain" do
        expect(UrlService.discover_full_path("/3d", { tags: "tag-1" })).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}/3d?tags=tag-1"
      end
    end

  context_ "widget_product_link_base_url" do
  context_ "when user is not specified" do
  test "returns url with root domain" do
          expect(described_class.widget_product_link_base_url).to eq(UrlService.root_domain_with_protocol)
        end
      end

  context_ "when specified user does not have a username or a custom domain" do
        let(:user) { create(:user) }

  test "returns url with root domain" do
          expect(described_class.widget_product_link_base_url).to eq(UrlService.root_domain_with_protocol)
        end
      end

  context_ "when specified user does not have a custom domain" do
        let(:user) { create(:user) }

  test "returns user's subdomain URL" do
          expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
        end
      end

  context_ "when specified user does not have an active custom domain" do
        let(:user) { create(:user) }
        let!(:custom_domain) { create(:custom_domain, user:) }

  test "returns user's subdomain URL" do
          expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
        end
      end

  context_ "when specified user has an active custom domain" do
        let(:user) { create(:user) }
        let!(:custom_domain) { create(:custom_domain, domain: "www.example.com", user:, state: "verified") }

        before do
          custom_domain.set_ssl_certificate_issued_at!
        end

  context_ "when configured custom domain is www-prefixed but the domain pointed to our servers is not www-prefixed" do
          before do
            allow(CustomDomainVerificationService)
              .to receive(:new)
              .with(domain: custom_domain.domain)
              .and_return(double(domains_pointed_to_gumroad: ["example.com"]))
          end

  test "returns user's subdomain URL" do
            expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
          end
        end

  context_ "when configured custom domain matches with the domain pointed to our servers" do
          before do
            allow(CustomDomainVerificationService)
              .to receive(:new)
              .with(domain: custom_domain.domain)
              .and_return(double(domains_pointed_to_gumroad: [custom_domain.domain]))
          end

  test "returns custom domain with protocol" do
            expect(described_class.widget_product_link_base_url(seller: user)).to eq("#{PROTOCOL}://#{custom_domain.domain}")
          end
        end
      end
    end

  context_ "widget_script_base_url" do
  context_ "when user is not specified" do
  test "returns url with root domain" do
          expect(described_class.widget_script_base_url).to eq(UrlService.root_domain_with_protocol)
        end
      end

  context_ "when specified user does not have a custom domain" do
        let(:user) { create(:user) }

  test "returns url with root domain" do
          expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
        end
      end

  context_ "when specified user does not have an active custom domain" do
        let(:user) { create(:user) }
        let!(:custom_domain) { create(:custom_domain, user:) }

  test "returns url with root domain" do
          expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
        end
      end

  context_ "when specified user has an active custom domain" do
        let(:user) { create(:user) }
        let!(:custom_domain) { create(:custom_domain, domain: "www.example.com", user:, state: "verified") }

        before do
          custom_domain.set_ssl_certificate_issued_at!
        end

  context_ "when configured custom domain is www-prefixed but the domain pointed to our servers is not www-prefixed" do
          before do
            allow(CustomDomainVerificationService)
              .to receive(:new)
              .with(domain: custom_domain.domain)
              .and_return(double(domains_pointed_to_gumroad: ["example.com"]))
          end

  test "returns url with root domain" do
            expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
          end
        end

  context_ "when configured custom domain matches with the domain pointed to our servers" do
          before do
            allow(CustomDomainVerificationService)
              .to receive(:new)
              .with(domain: custom_domain.domain)
              .and_return(double(domains_pointed_to_gumroad: [custom_domain.domain]))
          end

  test "returns custom domain with protocol" do
            expect(described_class.widget_script_base_url(seller: user)).to eq("#{PROTOCOL}://#{custom_domain.domain}")
          end
        end
      end
    end
  end
end
