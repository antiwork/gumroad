# frozen_string_literal: true

require("spec_helper")

describe("Product checkout - with affiliate", type: :system, js: true) do
  def set_affiliate_cookie
    browser = Capybara.current_session.driver.browser
    browser.manage.add_cookie(name: CGI.escape(affiliate.cookie_key), value: {
      value: Time.current.to_i,
      expires: affiliate.class.cookie_lifetime.from_now,
      httponly: true,
      domain: :all
    }.to_json)
  end

  shared_examples "credits the affiliate via a query param in the URL" do
    it "credits the affiliate for an eligible product purchase" do
      visit short_link_path(product.unique_permalink, param_name => affiliate.external_id_numeric)
      complete_purchase(product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq affiliate
      expect(purchase.affiliate_credit_cents).to eq 79
    end

    it "adds the affiliate's cookie and links to the cart product if the affiliate is alive" do
      visit short_link_path(product.unique_permalink, param_name => affiliate.external_id_numeric)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).to be_present

      add_to_cart(product)
      Selenium::WebDriver::Wait.new.until { Cart.alive.one? }
      expect(Cart.first.cart_products.first).to have_attributes(product:, affiliate:)
    end

    it "does not add the affiliate's cookie if the affiliate is deleted" do
      affiliate.mark_deleted!
      visit short_link_path(product.unique_permalink, param_name => affiliate.external_id_numeric)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).not_to be_present
    end

    it "does not credit the affiliate for an ineligible product purchase" do
      visit short_link_path(ineligible_product.unique_permalink, param_name => affiliate.external_id_numeric)
      complete_purchase(ineligible_product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq nil
      expect(purchase.affiliate_credit_cents).to eq 0
    end
  end

  shared_examples "credits the affiliate via query params in the URL" do
    context "`affiliate_id` query param" do
      it_behaves_like "credits the affiliate via a query param in the URL" do
        subject(:param_name) { "affiliate_id" }
      end
    end

    context "`a` query param" do
      it_behaves_like "credits the affiliate via a query param in the URL" do
        subject(:param_name) { "a" }
      end
    end
  end

  shared_examples "credits the affiliate via their affiliate referral URL" do
    it "credits the affiliate for an eligible product purchase" do
      visit affiliate.referral_url_for_product(product)
      complete_purchase(product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq affiliate
      expect(purchase.affiliate_credit_cents).to eq 79
    end

    it "adds the affiliate's cookie if the affiliate is alive" do
      visit affiliate.referral_url_for_product(product)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).to be_present
      expect(affiliate_cookie[:expires]).to be_within(5.minutes).of(cookie_expiry)
    end

    it "does not add the affiliate's cookie if the affiliate is deleted" do
      affiliate.mark_deleted!
      visit affiliate.referral_url_for_product(product)
      affiliate_cookie = Capybara.current_session.driver.browser.manage.all_cookies.find do |cookie|
        cookie[:name] == CGI.escape(affiliate.cookie_key)
      end
      expect(affiliate_cookie).not_to be_present
    end
  end

  shared_examples "credits the affiliate via affiliate cookie" do
    it "credits the affiliate for an eligible product purchase" do
      visit short_link_path(product.unique_permalink)
      add_to_cart(product)
      set_affiliate_cookie
      check_out(product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq affiliate
      expect(purchase.affiliate_credit_cents).to eq 79
    end

    it "does not credit the affiliate for an ineligible product purchase" do
      visit short_link_path(ineligible_product.unique_permalink)
      add_to_cart(ineligible_product)
      set_affiliate_cookie
      check_out(ineligible_product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq nil
      expect(purchase.affiliate_credit_cents).to eq 0
    end
  end

  let(:product) { create(:product, :recommendable, price_cents: 1000) }
  let(:seller) { product.user }

  context "for a direct affiliate" do
    let(:ineligible_product) { create(:product, user: seller, price_cents: 2000) }
    let(:affiliate) { create(:direct_affiliate, seller:, products: [product], affiliate_basis_points: 1000) }
    let(:cookie_expiry) { 30.days.from_now.to_datetime }

    it_behaves_like "credits the affiliate via affiliate cookie"
    it_behaves_like "credits the affiliate via query params in the URL"
    it_behaves_like "credits the affiliate via their affiliate referral URL"

    it "redirects the user to an eligible product page from an ineligible product referral URL" do
      visit affiliate.referral_url_for_product(ineligible_product)
      expect(current_path).to eq short_link_path(product)
    end
  end

  context "for a global affiliate" do
    let(:ineligible_product) { create(:product, price_cents: 2000) }
    let(:affiliate) { create(:user).global_affiliate }
    let(:cookie_expiry) { 7.days.from_now.to_datetime }

    it_behaves_like "credits the affiliate via affiliate cookie"
    it_behaves_like "credits the affiliate via query params in the URL"
    it_behaves_like "credits the affiliate via their affiliate referral URL"

    it "does not credit the affiliate for an ineligible product purchase via the affiliate referral URL" do
      visit affiliate.referral_url_for_product(ineligible_product)
      complete_purchase(ineligible_product)

      purchase = Purchase.last
      expect(purchase.affiliate).to eq nil
      expect(purchase.affiliate_credit_cents).to eq 0
    end

    it "associates the affiliate with the product" do
      expect do
        visit affiliate.referral_url_for_product(product)
        complete_purchase(product)
      end.to change { product.reload.global_affiliates.where(id: affiliate.id).count }.from(0).to(1)
    end

    it "does not associate the affiliate with the product if it is already associated" do
      product.affiliates << affiliate
      expect do
        visit affiliate.referral_url_for_product(product)
        complete_purchase(product)
      end.not_to change { product.reload.global_affiliates.where(id: affiliate.id).count }
    end

    context "when purchase is made via Discover" do
      it "credits the affiliate if the seller participates in Discover" do
        visit short_link_path(product.unique_permalink, affiliate_id: affiliate.external_id_numeric, recommended_by: "discover")
        complete_purchase(product, recommended_by: "discover", affiliate_id: affiliate.external_id_numeric)

        purchase = Purchase.last

        expect(purchase.affiliate).to eq affiliate
        expect(purchase.affiliate_credit_cents).to eq 70
      end

      it "does not credit the affiliate if the seller has opted out of Discover" do
        visit short_link_path(ineligible_product.unique_permalink, affiliate_id: affiliate.external_id_numeric, recommended_by: "discover")
        complete_purchase(ineligible_product, recommended_by: "discover", affiliate_id: affiliate.external_id_numeric)

        purchase = Purchase.last

        expect(purchase.affiliate).to eq nil
      end
    end
  end

  context "with multiple affiliate cookies" do
    it "credits the latest eligible affiliate" do
      product = create(:product, :recommendable, user: seller, price_cents: 1000)
      last_affiliate = create(:direct_affiliate, seller: product.user)
      create(:product_affiliate, product:, affiliate: last_affiliate, affiliate_basis_points: 2000)
      travel_to 2.days.ago do
        visit short_link_path(product.unique_permalink, affiliate_id: create(:direct_affiliate, seller:, products: [product]).external_id_numeric)
      end
      travel_to 1.day.ago do
        visit short_link_path(product.unique_permalink, affiliate_id: last_affiliate.external_id_numeric)
      end
      visit short_link_path(product.unique_permalink, affiliate_id: create(:direct_affiliate).external_id_numeric)

      complete_purchase(product)

      purchase = Purchase.last
      expect(purchase.affiliate_id).to eq last_affiliate.id
      expect(purchase.affiliate_credit_cents).to eq 158
    end
  end
end
