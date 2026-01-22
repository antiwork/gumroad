# frozen_string_literal: true

require "spec_helper"

describe AffiliateMailer do
  describe "#notify_affiliate_of_sale" do
    let(:seller) { create(:named_user) }
    let(:product_name) { "Affiliated Product" }
    let(:purchaser_email) { generate(:email) }

    shared_examples "notifies affiliate of a sale" do
      it "sends email to affiliate" do
        product = create(:product, user: seller, name: product_name)
        purchase = create(:purchase, affiliate:, link: product, seller:, email: purchaser_email)
        mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
        expect(mail.to).to eq([affiliate.affiliate_user.form_email])
        expect(mail.subject).to include(email_subject)
        expect(mail.body.encoded).to include(email_body)
        expect(mail.body.encoded).to include("Thanks for being part of the team and helping make another sale happen!")
      end

      context "for a subscription purchase" do
        it "tells them they will receive a commission for recurring charges" do
          product = create(:membership_product, user: seller)
          purchase = create(:membership_purchase, affiliate:, link: product, seller:)
          mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
          expect(mail.body.encoded).to include "You&#39;ll continue to receive a commission once a month as long as the subscription is active."
        end
      end

      context "for a free trial purchase" do
        it "clarifies when they will receive their affiliate credits" do
          product = create(:membership_product, :with_free_trial_enabled, user: seller)
          purchase = create(:free_trial_membership_purchase, affiliate:, link: product, seller:)
          formatted_amount = MoneyFormatter.format(purchase.affiliate_credit_cents, :usd, no_cents_if_whole: true, symbol: true)
          mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
          expect(mail.body.encoded).to include "Your commission rate: #{affiliate.affiliate_percentage}%"
          expect(mail.body.encoded).to include "Your earnings (after fees): #{formatted_amount}"
          expect(mail.body.encoded).to include "If the subscriber continues with their subscription after their free trial has expired on #{purchase.subscription.free_trial_end_date_formatted}, we'll add your commission to your balance"
        end
      end
    end

    context "for a direct affiliate" do
      let(:affiliate) { create(:direct_affiliate, seller:) }
      let(:email_subject) { "You helped #{seller.name_or_username} make a sale" }
      let(:email_body) { "Great news - #{seller.name_or_username} just sold a copy of #{product_name} to #{purchaser_email} thanks to your referral." }

      it_behaves_like "notifies affiliate of a sale"

      it "shows the correct affiliate commission for the purchased product" do
        product = create(:product, user: seller, name: product_name, price_cents: 10_00)
        create(:product_affiliate, product:, affiliate:, affiliate_basis_points: 25_00)
        purchase = create(:purchase, affiliate:, link: product, seller:, email: purchaser_email, affiliate_credit_cents: 2_50)

        mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
        expect(mail.to).to eq([affiliate.affiliate_user.form_email])
        expect(mail.subject).to include(email_subject)
        expect(mail.body.encoded).to include(email_body)
        expect(mail.body.encoded).to include("We've added your commission to your balance.")
        expect(mail.body.encoded).to include "Purchase amount: $10"
        expect(mail.body.encoded).to include "Your commission rate: 25%"
        expect(mail.body.encoded).to include "Your earnings (after fees): $1.97"
      end
    end

    context "for a global affiliate" do
      let(:affiliate) { create(:user).global_affiliate }
      let(:email_subject) { "🎉 You earned a commission!" }
      let(:email_body) { "Great news - #{seller.name_or_username} just sold a copy of #{product_name} thanks to your referral." }

      it_behaves_like "notifies affiliate of a sale"
    end

    context "for a collaborator" do
      let(:product) { create(:product, user: seller, name: product_name, price_cents: 20_00) }
      let(:collaborator) { create(:collaborator, seller:, affiliate_basis_points: 40_00, products: [product]) }
      let(:purchase) { create(:purchase_in_progress, affiliate: collaborator, link: product, seller:) }

      before do
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      it "notifies collaborator of a sale" do
        mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
        expect(mail.to).to eq([collaborator.affiliate_user.form_email])
        expect(mail.subject).to include("New sale of #{product_name} for $20")
        expect(mail.body.encoded).to include("You made a sale!")
        expect(mail.body.encoded).to include "Product price"
        expect(mail.body.encoded).to include "$20"
        expect(mail.body.encoded).to include "Your cut"
        expect(mail.body.encoded).to include "$8"
        expect(mail.body.encoded).to include "Quantity"
        expect(mail.body.encoded).to include "1"
      end

      it "includes variant information if the purchase is for a variant" do
        purchase.variant_attributes = [
          create(:variant, variant_category: create(:variant_category, link: product), name: "Blue"),
          create(:variant, variant_category: create(:variant_category, link: product), name: "Small"),
        ]

        mail = AffiliateMailer.notify_affiliate_of_sale(purchase.id)
        expect(mail.body.encoded).to include "Variants"
        expect(mail.body.encoded).to include "(Blue, Small)"
      end
    end
  end

  describe "#notify_direct_affiliate_of_updated_products" do
    it "sends email to affiliate" do
      seller = create(:named_user)
      product = create(:product, name: "Gumbot bits", user: seller)
      product_2 = create(:product, name: "The Gumroad Handbook", user: seller)
      create(:product, name: "Unaffiliated product that we ignore", user: seller)
      affiliate = create(:direct_affiliate, seller:)
      create(:product_affiliate, product:, affiliate:)
      create(:product_affiliate, product: product_2, affiliate:, affiliate_basis_points: 30_00)
      create(:product, name: "The Road of Gum", user: seller)

      mail = AffiliateMailer.notify_direct_affiliate_of_updated_products(affiliate.id)
      expect(mail.to).to eq([affiliate.affiliate_user.form_email])
      expect(mail.subject).to include("#{seller.name} just updated your affiliated products")

      body = mail.body.encoded.split("<body>").pop
      mail_plaintext = ActionView::Base.full_sanitizer.sanitize(body).gsub("\r\n", " ").gsub(/\s{2,}/, " ").strip
      expect(mail_plaintext).to_not include("The Road of Gum")
      expect(mail_plaintext).to include("Gumbot bits - Your commission: 10%")
      expect(mail_plaintext).to include("The Gumroad Handbook - Your commission: 30%")
      expect(mail_plaintext).to include("You can now share the products linked below with your audience. For every sale you make, you will get a percentage of the total sale as your commission.")
      expect(mail_plaintext).to include("You can direct them to this link: #{affiliate.referral_url}, or share the individual links listed above.")
    end
  end

  describe "#direct_affiliate_removal" do
    it "sends email to affiliate" do
      seller = create(:named_user)
      direct_affiliate = create(:direct_affiliate, seller:)

      mail = AffiliateMailer.direct_affiliate_removal(direct_affiliate.id)
      expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
      expect(mail.subject).to include("#{seller.name} just updated your affiliate status")
      expect(mail.body.encoded).to include("#{seller.name} has removed you from their affiliate program. If you feel this was done accidentally, please reach out to #{seller.name} directly.")
      expect(mail.body.encoded).to include("Thanks for being a part of the team.")
    end
  end

  describe "#collaboration_ended_by_affiliate_user" do
    it "sends email to seller" do
      seller = create(:user, name: "Seller")
      affiliate_user = create(:user, name: "Affiliate User")
      collaborator = create(:collaborator, seller:, affiliate_user:)

      mail = AffiliateMailer.collaboration_ended_by_affiliate_user(collaborator.id)
      expect(mail.to).to eq([seller.form_email])
      expect(mail.cc).to eq([affiliate_user.form_email])
      expect(mail.subject).to include("Affiliate User has ended your collaboration")
      expect(mail.body.encoded).to include("Affiliate User has ended your collaboration. They no longer have access to your product(s), or future earnings.")
    end
  end

  describe "#direct_affiliate_invitation" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }

    before { create(:product, name: "Unaffiliated product that we ignore", user: seller) }

    context "when affiliate has just a single product" do
      context "when affiliate destination URL is set" do
        it "sends email to affiliate with the affiliated product's URL and destination URL" do
          direct_affiliate = create(:direct_affiliate, seller:, destination_url: "https://example.com")
          create(:product_affiliate, product:, affiliate: direct_affiliate, destination_url: "https://example2.com")

          mail = AffiliateMailer.direct_affiliate_invitation(direct_affiliate.id)
          expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
          expect(mail.cc).to eq([direct_affiliate.seller.form_email])
          expect(mail.subject).to include("#{seller.name} has added you as an affiliate.")
          expect(mail.body.encoded).to include("For every sale you make, you will get 10% of the total sale as your commission.")
          expect(mail.body.encoded.squish).to include(%(You can direct them to this link: <a clicktracking="off" href="#{direct_affiliate.referral_url}">#{direct_affiliate.referral_url}</a> — after they click, we'll redirect them to <a clicktracking="off" href="#{direct_affiliate.final_destination_url(product:)}">#{direct_affiliate.final_destination_url(product:)}</a>.))
          expect(mail.body.encoded).to include("Or, if you'd like to share the product, you can use this link:")
        end
      end

      context "when affiliate destination URL is not set" do
        it "sends email to affiliate with the affiliated product's URL" do
          direct_affiliate = create(:direct_affiliate, seller:)
          create(:product_affiliate, product:, affiliate: direct_affiliate, destination_url: "https://example2.com")

          mail = AffiliateMailer.direct_affiliate_invitation(direct_affiliate.id)
          expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
          expect(mail.cc).to eq([direct_affiliate.seller.form_email])
          expect(mail.subject).to include("#{seller.name} has added you as an affiliate.")
          expect(mail.body.encoded).to include("For every sale you make, you will get 10% of the total sale as your commission.")
          expect(mail.body.encoded.squish).to include(%(You can direct them to this link: <a clicktracking="off" href="#{direct_affiliate.referral_url_for_product(product)}">#{direct_affiliate.referral_url_for_product(product)}</a>))
          expect(mail.body.encoded).to_not include("— after they click, we'll redirect them to")
        end
      end
    end

    context "when affiliate has multiple products" do
      it "sends email to affiliate with the affiliated products' URLs" do
        product_two = create(:product, name: "Gumbot bits", user: seller)
        direct_affiliate = create(:direct_affiliate, seller:)
        create(:product_affiliate, product:, affiliate: direct_affiliate, destination_url: "https://example.com")
        create(:product_affiliate, product: product_two, affiliate_basis_points: 5_00, affiliate: direct_affiliate, destination_url: "https://example2.com")

        mail = AffiliateMailer.direct_affiliate_invitation(direct_affiliate.id)
        expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
        expect(mail.cc).to eq([direct_affiliate.seller.form_email])
        expect(mail.subject).to include("#{seller.name} has added you as an affiliate.")
        expect(mail.body.encoded.squish).to include(%(You can direct them to this link: <a clicktracking="off" href="#{direct_affiliate.referral_url}">#{direct_affiliate.referral_url}</a> — after they click, we'll redirect them to <a clicktracking="off" href="#{seller.subdomain_with_protocol}">#{seller.subdomain_with_protocol}</a>))

        body = mail.body.encoded.split("<body>").pop
        mail_plaintext = ActionView::Base.full_sanitizer.sanitize(body).gsub("\r\n", " ").gsub(/\s{2,}/, " ").strip
        expect(mail_plaintext).to include("For every sale you make, you will get 5 - 10% of the total sale as your commission.")
        expect(mail_plaintext).to include("Or, if you'd like to share individual products, you can use these links:")
        expect(mail_plaintext).to include("#{product.name} - Your commission: 10%")
        expect(mail_plaintext).to include("Gumbot bits - Your commission: 5%")
      end
    end

    context "when prevent_sending_invitation_email_to_seller param is true" do
      it "doesn't send the email to seller" do
        direct_affiliate = create(:direct_affiliate, seller:, products: [product])

        mail = AffiliateMailer.direct_affiliate_invitation(direct_affiliate.id, true)
        expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
        expect(mail.cc).to be_nil
      end
    end
  end

  describe "#notify_direct_affiliate_of_new_product" do
    it "sends email to affiliate" do
      seller = create(:named_user)
      direct_affiliate = create(:direct_affiliate, seller:)
      product = create(:product, user: seller)
      create(:product_affiliate, product:, affiliate: direct_affiliate)

      mail = AffiliateMailer.notify_direct_affiliate_of_new_product(direct_affiliate.id, product.id)
      expect(mail.to).to eq([direct_affiliate.affiliate_user.form_email])
      expect(mail.subject).to include("#{seller.name} has added you as an affiliate to #{product.name}")
      expect(mail.body.encoded).to include("You are now able to share #{product.name} with your audience. For every sale you make, you will get 10% of the total sale as your commission.")
    end
  end

  describe "#collaborator_creation" do
    let(:seller) { create(:named_user) }
    let(:collaborator) { create(:collaborator, seller:) }

    it "sends email to collaborator" do
      product_affiliate = create(:product_affiliate, affiliate: collaborator, product: create(:product, user: seller, name: "Product", price_cents: 500))
      mail = AffiliateMailer.collaborator_creation(collaborator.id)
      expect(mail.to).to eq([collaborator.affiliate_user.form_email])
      subject = "#{seller.name} has added you as a collaborator on Gumroad"
      expect(mail.subject).to eq(subject)

      expect(mail.body.encoded).to have_text("Product")
      expect(mail.body.encoded).to have_link(product_affiliate.product.long_url, href: product_affiliate.product.long_url)
      expect(mail.body.encoded).to have_text("Price")
      expect(mail.body.encoded).to have_text("$5")
      expect(mail.body.encoded).to have_text("Your cut")
      expect(mail.body.encoded).to have_text("10% ($0.50)")

      expect(mail.body.encoded).to have_link("Log in to Gumroad")
    end

    context "when the collaborator has more than 5 products" do
      let!(:product_affiliates) do
        build_list(:product_affiliate, 6, affiliate: collaborator) do |product_affiliate, i|
          product_affiliate.product = create(:product, user: seller, name: "Product #{i}")
          product_affiliate.save!
        end
      end

      it "sends email to collaborator and truncates the product list" do
        mail = AffiliateMailer.collaborator_creation(collaborator.id)
        expect(mail.to).to eq([collaborator.affiliate_user.form_email])
        subject = "#{seller.name} has added you as a collaborator on Gumroad"
        expect(mail.subject).to eq(subject)
        expect(mail.body.encoded).to have_text(subject)

        expect(mail.body.encoded).to have_text("What is a collaborator?")
        expect(mail.body.encoded).to have_text("A collaborator is someone who has contributed to the creation of a product and therefore earns a percentage of its sales.")

        expect(mail.body.encoded).to have_text("How much will I earn?")

        product_affiliates.take(5).map(&:product).each_with_index do |product, i|
          expect(mail.body.encoded).to have_text("Product #{i}")
          expect(mail.body.encoded).to have_link(product.long_url, href: product.long_url)
          expect(mail.body.encoded).to have_text("Price")
          expect(mail.body.encoded).to have_text("$1")
          expect(mail.body.encoded).to have_text("Your cut")
          expect(mail.body.encoded).to have_text("10% ($0.10)")
        end

        expect(mail.body.encoded).to have_link("Log in to see 1 more", href: products_collabs_url)
      end
    end
  end

  describe "#collaborator_update" do
    let(:seller) { create(:named_user) }
    let(:collaborator) { create(:collaborator, seller:) }

    it "sends email to collaborator" do
      product_affiliate = create(:product_affiliate, affiliate: collaborator, product: create(:product, user: seller, name: "Product", price_cents: 500))
      mail = AffiliateMailer.collaborator_update(collaborator.id)
      expect(mail.to).to eq([collaborator.affiliate_user.form_email])
      subject = "#{seller.name} has updated your collaborator status on Gumroad"
      expect(mail.subject).to eq(subject)

      expect(mail.body.encoded).to have_text("Product")
      expect(mail.body.encoded).to have_link(product_affiliate.product.long_url, href: product_affiliate.product.long_url)
      expect(mail.body.encoded).to have_text("Price")
      expect(mail.body.encoded).to have_text("$5")
      expect(mail.body.encoded).to have_text("Your cut")
      expect(mail.body.encoded).to have_text("10% ($0.50)")

      expect(mail.body.encoded).to have_link("Log in to Gumroad")
    end

    context "when the collaborator has more than 5 products" do
      let!(:product_affiliates) do
        build_list(:product_affiliate, 6, affiliate: collaborator) do |product_affiliate, i|
          product_affiliate.product = create(:product, user: seller, name: "Product #{i}")
          product_affiliate.save!
        end
      end

      it "sends email to collaborator and truncates the product list" do
        mail = AffiliateMailer.collaborator_update(collaborator.id)
        expect(mail.to).to eq([collaborator.affiliate_user.form_email])
        subject = "#{seller.name} has updated your collaborator status on Gumroad"
        expect(mail.subject).to eq(subject)
        expect(mail.body.encoded).to have_text(subject)

        expect(mail.body.encoded).to_not have_text("What is a collaborator?")

        expect(mail.body.encoded).to have_text("How much will I earn?")

        product_affiliates.take(5).map(&:product).each_with_index do |product, i|
          expect(mail.body.encoded).to have_text("Product #{i}")
          expect(mail.body.encoded).to have_link(product.long_url, href: product.long_url)
          expect(mail.body.encoded).to have_text("Price")
          expect(mail.body.encoded).to have_text("$1")
          expect(mail.body.encoded).to have_text("Your cut")
          expect(mail.body.encoded).to have_text("10% ($0.10)")
        end

        expect(mail.body.encoded).to have_link("Log in to see 1 more", href: products_collabs_url)
      end
    end
  end

  describe "#collaboration_ended_by_seller" do
    let(:seller) { create(:named_user) }
    let(:collaborator) { create(:collaborator, seller:) }

    it "sends email to collaborator" do
      mail = AffiliateMailer.collaboration_ended_by_seller(collaborator.id)
      expect(mail.to).to eq([collaborator.affiliate_user.form_email])
      expect(mail.subject).to include("#{seller.name} just updated your collaborator status")
      expect(mail.body.encoded).to include("#{seller.name} has removed you as a collaborator. If you feel this was done accidentally, please reach out to #{seller.name} directly.")
    end
  end

  describe "#collaborator_invited" do
    let(:seller) { create(:named_user) }
    let(:collaborator) { create(:collaborator, seller:) }

    it "sends email to collaborator" do
      product_affiliate = create(:product_affiliate, affiliate: collaborator, product: create(:product, user: seller, name: "Product", price_cents: 500))

      mail = AffiliateMailer.collaborator_invited(collaborator.id)

      expect(mail.to).to eq([collaborator.affiliate_user.form_email])
      expect(mail.subject).to eq("#{seller.name} has invited you to collaborate on Gumroad")

      expect(mail.body.encoded).to have_text("Product")
      expect(mail.body.encoded).to have_link(product_affiliate.product.long_url, href: product_affiliate.product.long_url)
      expect(mail.body.encoded).to have_text("Price")
      expect(mail.body.encoded).to have_text("$5")
      expect(mail.body.encoded).to have_text("Your cut")
      expect(mail.body.encoded).to have_text("10% ($0.50)")

      expect(mail.body.encoded).to have_link("Respond to this invitation", href: collaborators_incomings_url)
    end

    context "when the collaborator has more than 5 products" do
      let!(:product_affiliates) do
        build_list(:product_affiliate, 6, affiliate: collaborator) do |product_affiliate, i|
          product_affiliate.product = create(:product, user: seller, name: "Product #{i}")
          product_affiliate.save!
        end
      end

      it "sends email to collaborator and truncates the product list" do
        mail = AffiliateMailer.collaborator_invited(collaborator.id)

        expect(mail.to).to eq([collaborator.affiliate_user.form_email])

        subject = "#{seller.name} has invited you to collaborate on Gumroad"
        expect(mail.subject).to eq(subject)
        expect(mail.body.encoded).to have_text(subject)

        expect(mail.body.encoded).to have_text("What is a collaborator?")
        expect(mail.body.encoded).to have_text("A collaborator is someone who has contributed to the creation of a product and therefore earns a percentage of its sales.")

        expect(mail.body.encoded).to have_text("How much will I earn?")

        product_affiliates.take(5).map(&:product).each_with_index do |product, i|
          expect(mail.body.encoded).to have_text("Product #{i}")
          expect(mail.body.encoded).to have_link(product.long_url, href: product.long_url)
          expect(mail.body.encoded).to have_text("Price")
          expect(mail.body.encoded).to have_text("$1")
          expect(mail.body.encoded).to have_text("Your cut")
          expect(mail.body.encoded).to have_text("10% ($0.10)")
        end

        expect(mail.body.encoded).to have_text("And 1 more product...")

        expect(mail.body.encoded).to have_link("Respond to this invitation", href: collaborators_incomings_url)
      end
    end
  end


  describe "#collaborator_invitation_accepted" do
    let(:collaborator) { create(:collaborator) }

    it "sends email to the seller" do
      mail = AffiliateMailer.collaborator_invitation_accepted(collaborator.id)
      expect(mail.to).to eq([collaborator.seller.form_email])
      expect(mail.subject).to include("#{collaborator.affiliate_user.name} accepted your invitation to collaborate on Gumroad")
    end
  end

  describe "#collaborator_invitation_declined" do
    let(:collaborator) { create(:collaborator) }

    it "sends email to the seller" do
      mail = AffiliateMailer.collaborator_invitation_declined(collaborator.id)
      expect(mail.to).to eq([collaborator.seller.form_email])
      expect(mail.subject).to include("#{collaborator.affiliate_user.name} declined your invitation to collaborate on Gumroad")
    end
  end
end
