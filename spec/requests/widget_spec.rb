# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe "Widget Page scenario", js: true, type: :system do
  context "when no user is logged in" do
    before do
      @demo_product = create(:product, user: create(:named_user), unique_permalink: "demo")
    end

    it "allows to copy overlay code for the demo product" do
      visit("/widgets")

      expect(page).to have_field("Widget code", with: %(<script src="#{UrlService.root_domain_with_protocol}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@demo_product.long_url}">Buy on</a>))

      copy_button = find_button("Copy embed code")
      copy_button.hover
      expect(page).to have_content("Copy to Clipboard")

      copy_button.click
      expect(page).to have_content("Copied!")
    end

    it "allows creator to copy embed code of the product" do
      visit("/widgets")
      select_tab("Embed")

      expect(page).to have_field("Widget code", with: %(<script src="#{UrlService.root_domain_with_protocol}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@demo_product.long_url}">Loading...</a></div>))
      copy_button = find_button("Copy embed code")
      copy_button.hover
      expect(page).to have_content("Copy to Clipboard")

      copy_button.click
      expect(page).to have_content("Copied!")
    end
  end

  context "when seller is logged in" do
    before :each do
      @creator = create(:affiliate_user)
      @product = create(:product, user: @creator)
      @affiliated_product = create(:product, name: "The Minimalist Entrepreneur")
      @direct_affiliate = create(:direct_affiliate, affiliate_user: @creator, seller: @affiliated_product.user, products: [@affiliated_product])
      @base_url = UrlService.root_domain_with_protocol

      login_as(@creator)
    end

    it "allows creator to copy overlay code of the product" do
      visit("/widgets")

      within_section "Share your product", section_element: :section  do
        expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}">Buy on</a>))

        expect(page).not_to have_content("Copy to Clipboard")
        copy_button = find_button("Copy embed code")
        copy_button.hover
        expect(page).to have_content("Copy to Clipboard")

        copy_button.click
        expect(page).to have_content("Copied!")

        # Hover somewhere else to trigger mouseout
        first("textarea").hover
        expect(page).not_to have_content("Copy to Clipboard")
        expect(page).not_to have_content("Copied!")

        copy_button.hover
        expect(page).to have_content("Copy to Clipboard")
      end
    end

    it "allows creator to copy embed code of the product" do
      visit("/widgets")

      within_section "Share your product", section_element: :section do
        select_tab("Embed")
        expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@product.long_url}">Loading...</a></div>))

        copy_button = find_button("Copy embed code")
        expect(copy_button).not_to have_tooltip(text: "Copy to Clipboard")
        copy_button.hover
        expect(copy_button).to have_tooltip(text: "Copy to Clipboard")

        copy_button.click
        expect(page).to have_content("Copied!")

        # Hover somewhere else to trigger mouseout
        first("textarea").hover
        expect(page).not_to have_content("Copy to Clipboard")
        expect(page).not_to have_content("Copied!")

        copy_button.hover
        expect(copy_button).to have_tooltip(text: "Copy to Clipboard")
      end
    end

    it "allows creator to select products" do
      visit("/widgets")

      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}">Buy on</a>))

      select(@affiliated_product.name, from: "Choose your product")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@direct_affiliate.referral_url_for_product(@affiliated_product)}">Buy on</a>))

      select(@product.name, from: "Choose your product")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}">Buy on</a>))

      select_tab("Embed")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@product.long_url}">Loading...</a></div>))

      select(@affiliated_product.name, from: "Choose your product")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@direct_affiliate.referral_url_for_product(@affiliated_product)}">Loading...</a></div>))

      select(@product.name, from: "Choose your product")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@product.long_url}">Loading...</a></div>))
    end

    it "allows creator to configure the overlay settings" do
      visit("/widgets")

      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}">Buy on</a>))

      check "Send directly to checkout page"
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}" data-gumroad-overlay-checkout="true">Buy on</a>))

      # Overlay code with custom text
      fill_in("Button text", with: "Custom Overlay Button Text")
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}" data-gumroad-overlay-checkout="true">Custom Overlay Button Text</a>))

      uncheck "Send directly to checkout page"
      expect(page).to have_field("Widget code", with: %(<script src="#{@base_url}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@product.long_url}">Custom Overlay Button Text</a>))
    end

    context "when creator has an active custom domain that correctly points to our servers" do
      let!(:creator_custom_domain) { create(:custom_domain, user: @creator, state: "verified") }
      let!(:affiliated_product_creator_custom_domain) { create(:custom_domain, user: @direct_affiliate.seller, state: "verified") }
      let(:expected_base_url_for_affiliated_products) { @base_url }
      let(:expected_base_url_for_own_products) { "#{PROTOCOL}://#{creator_custom_domain.domain}" }

      before do
        creator_custom_domain.set_ssl_certificate_issued_at!
        affiliated_product_creator_custom_domain.set_ssl_certificate_issued_at!

        allow(CustomDomainVerificationService)
          .to receive(:new)
          .with(domain: creator_custom_domain.domain)
          .and_return(double(domains_pointed_to_gumroad: [creator_custom_domain.domain]))
        allow(CustomDomainVerificationService)
          .to receive(:new)
          .with(domain: affiliated_product_creator_custom_domain.domain)
          .and_return(double(domains_pointed_to_gumroad: [affiliated_product_creator_custom_domain.domain]))
      end

      it "shows widget installation codes with custom domain for own products and with root domain for affiliated products" do
        visit("/widgets")

        # Overlay code for own product
        expect(page).to have_field("Widget code", with: %(<script src="#{expected_base_url_for_own_products}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{short_link_url(@product, host: expected_base_url_for_own_products)}">Buy on</a>))

        # Overlay code for an affiliated product
        select(@affiliated_product.name, from: "Choose your product")
        expect(page).to have_field("Widget code", with: %(<script src="#{expected_base_url_for_affiliated_products}/js/gumroad.js"></script>\n<a class="gumroad-button" href="#{@direct_affiliate.referral_url_for_product(@affiliated_product)}">Buy on</a>))

        select_tab("Embed")

        # Embed code for an affiliated product
        expect(page).to have_field("Widget code", with: %(<script src="#{expected_base_url_for_affiliated_products}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{@direct_affiliate.referral_url_for_product(@affiliated_product)}">Loading...</a></div>))

        # Embed code for own product
        select(@product.name, from: "Choose your product")
        expect(page).to have_field("Widget code", with: %(<script src="#{expected_base_url_for_own_products}/js/gumroad-embed.js"></script>\n<div class="gumroad-product-embed"><a href="#{short_link_url(@product, host: expected_base_url_for_own_products)}">Loading...</a></div>))
      end
    end
  end

  describe "Subscribe form" do
    let(:seller) { create(:named_seller) }
    let!(:product) { create(:product, user: seller) }

    context "with seller as logged_in_user" do
      before do
        login_as(seller)
      end

      context "with seller as current_seller" do
        it "allows copying the follow page URL" do
          visit widgets_path
          copy_button = find_button("Copy link")
          copy_button.hover
          expect(copy_button).to have_tooltip(text: "Copy link")
          copy_button.click
          expect(copy_button).to have_tooltip(text: "Copied!")
        end

        it "allows copying the follow form embed HTML" do
          visit widgets_path
          within_section "Subscribe form", section_element: :section  do
            expect(page).to have_field("Subscribe form embed code", text: seller.external_id)
            copy_button = find_button("Copy embed code")
            copy_button.hover
            expect(copy_button).to have_tooltip(text: "Copy to Clipboard")
            copy_button.click
            expect(copy_button).to have_tooltip(text: "Copied!")
          end
        end

        it "allows previewing follow form embed" do
          visit widgets_path
          within_section "Subscribe form", section_element: :section  do
            fill_in "Your email address", with: "test@gumroad.com"
            click_on "Follow"
          end
          wait_for_ajax
          expect(seller.reload.followers.last.email).to eq("test@gumroad.com")
        end
      end
    end

    context "with switching account to user as admin for seller" do
      include_context "with switching account to user as admin for seller"

      it "uses seller's external id" do
        visit widgets_path
        within_section "Subscribe form", section_element: :section  do
          expect(page).to have_field("Subscribe form embed code", text: seller.external_id)
        end
      end
    end
  end
end
