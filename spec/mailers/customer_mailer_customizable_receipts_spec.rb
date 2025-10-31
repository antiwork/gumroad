# frozen_string_literal: true

require "spec_helper"

describe CustomerMailer, "customizable receipts" do
  let(:seller) { create(:named_seller) }
  let(:product) { create(:product, user: seller) }
  let(:purchase) { create(:purchase, link: product, seller: seller) }

  before do
    purchase.create_url_redirect!
  end

  describe "custom receipt text" do
    context "when product has custom receipt text" do
      before do
        product.save_custom_receipt_text("Thank you for your purchase! Join our community at https://example.com")
      end

      it "includes the custom receipt text in the email" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s

        expect(html).to include("Message from creator:")
        expect(html).to include("Thank you for your purchase! Join our community at https://example.com")
      end

      it "preserves newlines in custom receipt text" do
        product.save_custom_receipt_text("Line 1\nLine 2\nLine 3")

        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        Nokogiri::HTML(html)

        expect(html).to include("Message from creator:")
        expect(html).to include("Line 1")
        expect(html).to include("Line 2")
        expect(html).to include("Line 3")
      end

      it "displays custom text with proper styling" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        custom_text_container = doc.css("div").find do |div|
          div.text.include?("Message from creator:")
        end

        expect(custom_text_container).to be_present
      end
    end

    context "when product does not have custom receipt text" do
      it "does not include the custom receipt text section" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s

        expect(html).not_to include("Message from creator:")
      end
    end

    context "when custom receipt text is empty string" do
      before do
        product.save_custom_receipt_text("")
      end

      it "does not include the custom receipt text section" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s

        expect(html).not_to include("Message from creator:")
      end
    end
  end

  describe "custom view content button text" do
    context "when product has custom button text" do
      before do
        product.save_custom_view_content_button_text("Join the community")
      end

      it "uses the custom button text" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        button_texts = doc.css("a").map(&:text).map(&:strip)
        expect(button_texts).to include("Join the community")
      end
    end

    context "when product does not have custom button text" do
      it "uses the default 'View content' text" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        button_texts = doc.css("a").map(&:text).map(&:strip)
        expect(button_texts).to include("View content")
      end
    end

    context "when custom button text is empty string" do
      before do
        product.save_custom_view_content_button_text("")
      end

      it "falls back to default 'View content' text" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        button_texts = doc.css("a").map(&:text).map(&:strip)
        expect(button_texts).to include("View content")
      end
    end

    context "when url_redirect is not present" do
      before do
        product.save_custom_view_content_button_text("Join the community")
        purchase.url_redirect&.destroy
      end

      it "does not render the button" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        button_texts = doc.css("a").map(&:text).map(&:strip)
        expect(button_texts).not_to include("Join the community")
      end
    end
  end

  describe "combined custom text and button" do
    context "when both custom text and button text are set" do
      before do
        product.save_custom_receipt_text("Welcome! Check out our Discord community.")
        product.save_custom_view_content_button_text("Join Discord")
      end

      it "includes both custom text and custom button" do
        mail = CustomerMailer.receipt(purchase.id)
        html = mail.html_part&.body&.to_s.presence || mail.body.to_s
        doc = Nokogiri::HTML(html)

        expect(html).to include("Message from creator:")
        expect(html).to include("Welcome! Check out our Discord community.")

        button_texts = doc.css("a").map(&:text).map(&:strip)
        expect(button_texts).to include("Join Discord")
      end
    end
  end

  describe "bundle purchases" do
    let(:bundle) { create(:product, user: seller, is_bundle: true, name: "Bundle product") }
    let(:bundle_purchase) { create(:purchase, link: bundle, seller: seller) }
    let!(:included_product) { create(:product, user: seller, name: "Included product") }
    let!(:bundle_product) { create(:bundle_product, bundle: bundle, product: included_product) }

    before do
      included_product.save_custom_receipt_text("Thanks for getting this product!")
      included_product.save_custom_view_content_button_text("Access content")
      bundle_purchase.create_artifacts_and_send_receipt!
    end

    it "shows custom text for each bundled product" do
      product_purchase = bundle_purchase.product_purchases.find_by(link: included_product)
      mail = CustomerMailer.receipt(product_purchase.id)
      html = mail.html_part&.body&.to_s.presence || mail.body.to_s

      expect(html).to include("Message from creator:")
      expect(html).to include("Thanks for getting this product!")
    end
  end

  describe "membership purchases" do
    let(:membership_product) { create(:membership_product, user: seller) }
    let(:membership_purchase) do
      create(
        :membership_purchase,
        link: membership_product,
        seller: seller,
        price_cents: 1998
      )
    end

    before do
      membership_product.save_custom_receipt_text("Welcome to the membership!")
      membership_product.save_custom_view_content_button_text("Access member area")
      membership_purchase.create_url_redirect!
    end

    it "includes custom text and button for membership purchases" do
      mail = CustomerMailer.receipt(membership_purchase.id)
      html = mail.html_part&.body&.to_s.presence || mail.body.to_s
      doc = Nokogiri::HTML(html)

      expect(html).to include("Message from creator:")
      expect(html).to include("Welcome to the membership!")

      button_texts = doc.css("a").map(&:text).map(&:strip)
      expect(button_texts).to include("Access member area")
    end
  end
end
