# frozen_string_literal: true

require("spec_helper")

describe("Third party analytics", type: :system, js: true) do
  before do
    @user = create(:user)
    @product = create(:product, user: @user)
    @product2 = create(:product, user: @user)
    @product_without_3pa = create(:product)
  end

  context "on product page" do
    context "when the product has no third-party analytics" do
      it "doesn't load the third-party analytics iframe" do
        visit @product_without_3pa.long_url
        expect(page).to_not have_selector("iframe[aria-label='Third-party analytics']", visible: false)
      end
    end

    context "when the product has product third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: @product, location: "product")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the product has global third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: @product, location: "all")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the user has product third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: nil, location: "product")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the user has global third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: nil, location: "all")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end
  end

  context "after checkout" do
    context "when the product has no third-party analytics" do
      it "doesn't load the third-party analytics iframe" do
        visit @product_without_3pa.long_url
        add_to_cart(@product_without_3pa)
        check_out(@product_without_3pa)
        expect(page).to_not have_selector("iframe[aria-label='Third-party analytics']", visible: false)
      end
    end

    context "when the product has receipt third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: @product, location: "receipt")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        add_to_cart(@product)
        check_out(@product)
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the product has global third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: @product, location: "all")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        add_to_cart(@product)
        check_out(@product)
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the user has receipt third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: nil, location: "receipt")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        add_to_cart(@product)
        check_out(@product)
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when the user has global third-party analytics" do
      before do
        create(:third_party_analytic, user: @user, link: nil, location: "all")
      end

      it "loads the third-party analytics iframe" do
        visit @product.long_url
        add_to_cart(@product)
        check_out(@product)
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}']", visible: false)
      end
    end

    context "when an authenticated user purchases multiple products" do
      before do
        @product3 = create(:product, user: @user)
        create(:third_party_analytic, user: @user, link: @product)
        create(:third_party_analytic, user: @user, link: @product2)
        create(:third_party_analytic, user: @user, link: @product3, location: "product")
        @buyer = create(:user)
        login_as @buyer
      end

      it "loads all applicable third-party analytics iframes" do
        visit @product.long_url
        add_to_cart(@product)
        visit @product2.long_url
        add_to_cart(@product2)
        visit @product3.long_url
        add_to_cart(@product3)
        check_out(@product3, logged_in_user: @buyer)

        expect(page).to have_alert(text: "Your purchase was successful! We sent a receipt to #{@buyer.email}.")
        expect(page.current_path).to eq("/library")
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product.unique_permalink}'][src*='/#{@product.unique_permalink}?location=receipt&purchase_id=#{URI.encode_www_form_component(@product.sales.sole.external_id)}']", visible: false)
        expect(page).to have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product2.unique_permalink}'][src*='#{@product2.unique_permalink}?location=receipt&purchase_id=#{URI.encode_www_form_component(@product2.sales.sole.external_id)}']", visible: false)
        expect(page).to_not have_selector("iframe[aria-label='Third-party analytics'][data-permalink='#{@product3.unique_permalink}']", visible: false)
      end
    end
  end

  describe "Google Analytics cross-domain tracking" do
    it "preserves the `_gl` search parameter on the checkout page" do
      visit "#{@product.long_url}?_gl=thing"
      add_to_cart(@product)
      wait_for_ajax

      query = Rack::Utils.parse_query(URI.parse(page.current_url).query)
      # Ensure that the other query parameters have been cleared out
      expect(query["quantity"]).to be_nil
      expect(query["_gl"]).to eq("thing")
    end
  end
end
