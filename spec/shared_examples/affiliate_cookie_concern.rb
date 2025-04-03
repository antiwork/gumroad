# frozen_string_literal: true

require "spec_helper"
require "ipaddr"

RSpec.shared_examples_for "AffiliateCookie concern" do
  before do
    @frozen_time = Time.current
    travel_to(@frozen_time)
  end

  it "sets affiliate cookie" do
    make_request
    expected_cookie_options = {
      expires: direct_affiliate.class.cookie_lifetime.from_now.utc,
      value: @frozen_time.to_i.to_s,
      httponly: true,
      domain: determine_domain(request.url)
    }
    cookie = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate.cookie_key)
    expected_cookie_options.each do |key, value|
      expect(cookie.send(key)).to eq(value)
    end
  end

  it "does not set affiliate cookie if affiliate is not alive and is affiliated to other creators" do
    direct_affiliate_2 = create(:direct_affiliate, affiliate_user: direct_affiliate.affiliate_user, seller: create(:user))
    direct_affiliate_3 = create(:direct_affiliate, affiliate_user: direct_affiliate.affiliate_user, seller: create(:user))
    direct_affiliate.mark_deleted!
    make_request

    cookie_1 = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate.cookie_key)
    cookie_2 = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_2.cookie_key)
    cookie_3 = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_3.cookie_key)

    expect(cookie_1).to be(nil)
    expect(cookie_2).to be(nil)
    expect(cookie_3).to be(nil)
  end

  context "when direct affiliate is deleted and other direct affiliates exist" do
    it "sets affiliate cookie to last alive direct affiliate" do
      direct_affiliate.update!(deleted_at: Time.current)
      direct_affiliate_2 = create(:direct_affiliate, affiliate_user: direct_affiliate.affiliate_user, seller: direct_affiliate.seller, created_at: 1.hour.ago)
      create(:product_affiliate, product: direct_affiliate.products.last, affiliate: direct_affiliate_2, affiliate_basis_points: 20_00)

      make_request
      expected_cookie_options = {
        expires: direct_affiliate_2.class.cookie_lifetime.from_now.utc,
        value: @frozen_time.to_i.to_s,
        httponly: true,
        domain: determine_domain(request.url)
      }
      cookie = parse_cookie(response.header["Set-Cookie"], request.url, direct_affiliate_2.cookie_key)
      expected_cookie_options.each do |key, value|
        expect(cookie.send(key)).to eq(value)
      end
    end
  end

  private
    # Cannot stub `#cookies` to check if the arguments passed are correct as other parts of the app use encrypted
    # cookies (i.e. current_seller_id) which will not work with a simple Hash object stubbed
    # As browsers do not include cookie attributes in requests to the server — they only send the cookie's name and
    # value - the alternative is to actually retrieve the cookie from the Set-Cookie response header
    #
    def parse_cookie(set_cookie, origin_url, cookie_name)
      set_cookie
        .split("\n")
        .map { |cookie_string| HTTP::Cookie.parse(cookie_string, origin_url) }
        .flatten
        .find { |cookie| CGI.unescape(cookie.name) == cookie_name }
    end

    def determine_domain(url)
      uri = Addressable::URI.parse(url)
      IPAddr.new(uri.host)
      uri.host
    rescue IPAddr::InvalidAddressError
      uri.domain
    end
end
