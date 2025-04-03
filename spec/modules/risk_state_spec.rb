# frozen_string_literal: true

require "spec_helper"
describe "RiskState" do
  before do
    @user = create(:user, verified: true)
    @product = create(:product, user: @user, created_at: 1.day.ago, price_cents: 1000, filegroup: "url", name: "tuhin")
    time_of_sale = Time.current
    @purchase = create(:purchase, created_at: time_of_sale, price_cents: @product.price_cents, link: @product,
                                  seller_id: @user.id, referrer: "direct", card_country: "blah")
    2.times do
      create(:purchase, created_at: time_of_sale, price_cents: @product.price_cents, link: @product, seller_id: @user.id, referrer: "direct")
      create(:purchase, created_at: time_of_sale, price_cents: @product.price_cents, link: @product, seller_id: @user.id, purchase_state: "failed")
      create(:purchase, created_at: time_of_sale, price_cents: @product.price_cents, link: @product,
                        seller_id: @user.id, stripe_status: "charge.disputed", referrer: "t.co")
      create(:purchase, created_at: time_of_sale, price_cents: @product.price_cents,
                        link: @product, seller_id: @user.id, stripe_status: "charge.refunded", referrer: "direct")
    end
  end

  describe "#get_ip_proxy_score" do
    before do
      @ip_address = "25.25.25.25"
      @key = "B3Ti8SeX3v6Z"
    end

    it "returns 0 if ip_address is nil" do
      expect(RiskState.get_ip_proxy_score(nil)).to eq 0.0
    end

    it "returns the score if the score exists" do
      WebMock.stub_request(:get, "https://minfraud.maxmind.com/app/ipauth_http?i=#{@ip_address}&l=#{@key}").to_return(body: "proxyScore=3.0")
      expect(RiskState.get_ip_proxy_score(@ip_address)).to eq 3.0
    end

    it "returns 0 if the score doens't exist" do
      WebMock.stub_request(:get, "https://minfraud.maxmind.com/app/ipauth_http?i=#{@ip_address}&l=#{@key}").to_return(body: "proxyScore=")
      expect(RiskState.get_ip_proxy_score(@ip_address)).to eq 0.0
    end

    it "returns 0 if the request times out" do
      WebMock.stub_request(:get, "https://minfraud.maxmind.com/app/ipauth_http?i=#{@ip_address}&l=#{@key}").to_return(exception: Timeout::Error)
      expect(RiskState.get_ip_proxy_score(@ip_address)).to eq 0.0
    end
  end
end
