# frozen_string_literal: true

describe UserCustomDomainRequestService do
  describe "#valid?" do
    let(:request) { double("request") }

    it "returns false when request is from Gumroad domain" do
      allow(request).to receive(:host).and_return("app.test.gumroad.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(false)
    end

    it "returns false when request is from Discover domain" do
      allow(request).to receive(:host).and_return("test.gumroad.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(false)
    end

    it "returns true when request is from a custom domain" do
      allow(request).to receive(:host).and_return("example.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(true)
    end

    it "returns true when request is from Gumroad subdomain" do
      allow(request).to receive(:host).and_return("example.test.gumroad.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(true)
    end

    it "returns false when request is a product custom domain" do
      create(:custom_domain, user: nil, product: create(:product), domain: "product.com")
      allow(request).to receive(:host).and_return("product.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(false)
    end

    it "returns false when request is a product custom domain with a www prefix" do
      create(:custom_domain, user: nil, product: create(:product), domain: "product.com")
      allow(request).to receive(:host).and_return("www.product.com")
      expect(UserCustomDomainRequestService.valid?(request)).to eq(false)
    end
  end
end
