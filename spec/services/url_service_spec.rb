# frozen_string_literal: true

require "spec_helper"

describe UrlService do
  describe "#domain_with_protocol" do
    it "returns domain with protocol" do
      expect(UrlService.domain_with_protocol).to eq "#{PROTOCOL}://#{DOMAIN}"
    end
  end

  describe "#api_domain_with_protocol" do
    it "returns domain with protocol" do
      expect(UrlService.api_domain_with_protocol).to eq "#{PROTOCOL}://#{API_DOMAIN}"
    end
  end

  describe "#short_domain_with_protocol" do
    it "returns short domain with protocol" do
      expect(UrlService.short_domain_with_protocol).to eq "#{PROTOCOL}://#{SHORT_DOMAIN}"
    end
  end

  describe "#root_domain_with_protocol" do
    it "returns root_domain with protocol" do
      expect(UrlService.root_domain_with_protocol).to eq "#{PROTOCOL}://#{ROOT_DOMAIN}"
    end
  end

  describe "#discover_domain_with_protocol" do
    it "returns path with procotol and domain" do
      expect(UrlService.discover_domain_with_protocol).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}"
    end
  end

  describe "#discover_full_path" do
    it "returns path with procotol and domain" do
      expect(UrlService.discover_full_path("/3d")).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}/3d"
    end

    it "returns path and query with procotol and domain" do
      expect(UrlService.discover_full_path("/3d", { tags: "tag-1" })).to eq "#{PROTOCOL}://#{DISCOVER_DOMAIN}/3d?tags=tag-1"
    end
  end

  describe "widget_product_link_base_url" do
    context "when user is not specified" do
      it "returns url with root domain" do
        expect(described_class.widget_product_link_base_url).to eq(UrlService.root_domain_with_protocol)
      end
    end

    context "when specified user does not have a username or a custom domain" do
      let(:user) { create(:user) }

      it "returns url with root domain" do
        expect(described_class.widget_product_link_base_url).to eq(UrlService.root_domain_with_protocol)
      end
    end

    context "when specified user does not have a custom domain" do
      let(:user) { create(:user) }

      it "returns user's subdomain URL" do
        expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
      end
    end

    context "when specified user does not have an active custom domain" do
      let(:user) { create(:user) }
      let!(:custom_domain) { create(:custom_domain, user:) }

      it "returns user's subdomain URL" do
        expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
      end
    end

    context "when specified user has an active custom domain" do
      let(:user) { create(:user) }
      let!(:custom_domain) { create(:custom_domain, domain: "www.example.com", user:, state: "verified") }

      before do
        custom_domain.set_ssl_certificate_issued_at!
      end

      context "when configured custom domain is www-prefixed but the domain pointed to our servers is not www-prefixed" do
        before do
          allow(CustomDomainVerificationService)
            .to receive(:new)
            .with(domain: custom_domain.domain)
            .and_return(double(domains_pointed_to_gumroad: ["example.com"]))
        end

        it "returns user's subdomain URL" do
          expect(described_class.widget_product_link_base_url(seller: user)).to eq(user.subdomain_with_protocol)
        end
      end

      context "when configured custom domain matches with the domain pointed to our servers" do
        before do
          allow(CustomDomainVerificationService)
            .to receive(:new)
            .with(domain: custom_domain.domain)
            .and_return(double(domains_pointed_to_gumroad: [custom_domain.domain]))
        end

        it "returns custom domain with protocol" do
          expect(described_class.widget_product_link_base_url(seller: user)).to eq("#{PROTOCOL}://#{custom_domain.domain}")
        end
      end
    end
  end

  describe "widget_script_base_url" do
    context "when user is not specified" do
      it "returns url with root domain" do
        expect(described_class.widget_script_base_url).to eq(UrlService.root_domain_with_protocol)
      end
    end

    context "when specified user does not have a custom domain" do
      let(:user) { create(:user) }

      it "returns url with root domain" do
        expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
      end
    end

    context "when specified user does not have an active custom domain" do
      let(:user) { create(:user) }
      let!(:custom_domain) { create(:custom_domain, user:) }

      it "returns url with root domain" do
        expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
      end
    end

    context "when specified user has an active custom domain" do
      let(:user) { create(:user) }
      let!(:custom_domain) { create(:custom_domain, domain: "www.example.com", user:, state: "verified") }

      before do
        custom_domain.set_ssl_certificate_issued_at!
      end

      context "when configured custom domain is www-prefixed but the domain pointed to our servers is not www-prefixed" do
        before do
          allow(CustomDomainVerificationService)
            .to receive(:new)
            .with(domain: custom_domain.domain)
            .and_return(double(domains_pointed_to_gumroad: ["example.com"]))
        end

        it "returns url with root domain" do
          expect(described_class.widget_script_base_url(seller: user)).to eq(UrlService.root_domain_with_protocol)
        end
      end

      context "when configured custom domain matches with the domain pointed to our servers" do
        before do
          allow(CustomDomainVerificationService)
            .to receive(:new)
            .with(domain: custom_domain.domain)
            .and_return(double(domains_pointed_to_gumroad: [custom_domain.domain]))
        end

        it "returns custom domain with protocol" do
          expect(described_class.widget_script_base_url(seller: user)).to eq("#{PROTOCOL}://#{custom_domain.domain}")
        end
      end
    end
  end
end
