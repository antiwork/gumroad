# frozen_string_literal: true

require "spec_helper"

describe ContactingCreatorMailer do
  let(:custom_mailer_route_helper) do
    Class.new(ActionMailer::Base) do
      include CustomMailerRouteBuilder
    end.new
  end

  it "uses SUPPORT_EMAIL_WITH_NAME as default from address" do
    expect(described_class.default[:from]).to eq(ApplicationMailer::SUPPORT_EMAIL_WITH_NAME)
  end

  describe "cannot pay" do
    before { @payment = create(:payment) }

    it "sends notice to the payment user" do
      mail = ContactingCreatorMailer.cannot_pay(@payment.id)
      expect(mail.to).to eq [@payment.user.email]
      expect(mail.subject).to eq("We were unable to pay you.")
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end
  end

  describe "purchase refunded" do
    it "sends notification to the seller about refunded purchase" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)

      mail = ContactingCreatorMailer.purchase_refunded(purchase.id)
      expect(mail.to).to eq [purchase.seller.email]
      expect(mail.subject).to eq("A sale has been refunded")
      expect(mail.body.encoded).to include "test@example.com's purchase of Digital Membership for $10 has been refunded."
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end
  end

  describe "purchase refunded for fraud" do
    it "sends notification to the seller about purchase refunded for fraud" do
      purchase = create(:purchase, link: create(:product, name: "Digital Membership"), email: "test@example.com", price_cents: 10_00)

      mail = ContactingCreatorMailer.purchase_refunded_for_fraud(purchase.id)
      expect(mail.to).to eq [purchase.seller.email]
      expect(mail.subject).to eq("Fraud was detected on your Gumroad account.")
      expect(mail.body.encoded).to include "Our risk team has detected a fraudulent transaction on one of your products, using a stolen card."
      expect(mail.body.encoded).to include "We have refunded test@example.com's purchase of Digital Membership for $10."
      expect(mail.body.encoded).to include "We're doing our best to protect you, and no further action needs to be taken on your part."
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end
  end

  describe "chargeback notice" do
    let(:seller) { create(:named_seller) }

    context "for a dispute on Purchase" do
      let(:purchase) { create(:purchase, link: create(:product, user: seller)) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "sends chargeback notice correctly" do
        mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
        expect(mail.to).to eq [seller.email]
        expect(mail.subject).to eq "A sale has been disputed"

        expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
        expect(mail.body.encoded).to include "We have deducted the amount from your balance, and are looking into it for you."
        expect(mail.body.encoded).to include "We fight every dispute. If we succeed, you will automatically be re-credited the full amount. This process takes up to 75 days."
        expect(mail.body.encoded).not_to include "Any additional information you can provide"
      end

      context "when the seller is contacted to submit evidence" do
        let!(:dispute_evidence) do
          create(:dispute_evidence, dispute:)
        end

        it "includes copy to submit evidence" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
          expect(mail.subject).to eq "🚨 Urgent: Action required for resolving disputed sale"

          expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
          expect(mail.body.encoded).to include "Any additional information you can provide in the next 72 hours will help us win on your behalf."
          expect(mail.body.encoded).to include "Submit additional information"
        end
      end

      context "when the purchase was done via a PayPal Connect account" do
        before do
          purchase.update!(charge_processor_id: PaypalChargeProcessor.charge_processor_id)
        end

        it "includes copy about PayPal's dispute process" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

          expect(mail.body.encoded).to include "A customer of yours (#{purchase.email}) has disputed their purchase of #{purchase.link.name} for #{purchase.formatted_disputed_amount}."
          expect(mail.body.encoded).to include "Unfortunately, we’re unable to fight disputes on purchases via PayPal Connect since we don’t have access to your PayPal account."
        end
      end
    end

    context "for a dispute on Charge" do
      let(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge.purchases << create(:purchase, link: create(:product, user: seller))
        charge
      end

      let(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }

      it "sends chargeback notice correctly" do
        mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
        expect(mail.to).to eq [seller.email]
        expect(mail.subject).to eq "A sale has been disputed"

        expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
        charge.disputed_purchases.each do |purchase|
          expect(mail.body.encoded).to include purchase.link.name
        end
        expect(mail.body.encoded).to include "We have deducted the amount from your balance, and are looking into it for you."
        expect(mail.body.encoded).to include "We fight every dispute. If we succeed, you will automatically be re-credited the full amount. This process takes up to 75 days."
        expect(mail.body.encoded).not_to include "Any additional information you can provide"
      end

      context "when the seller is contacted to submit evidence" do
        let!(:dispute_evidence) do
          create(:dispute_evidence_on_charge, dispute:)
        end

        it "includes copy to submit evidence" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)
          expect(mail.subject).to eq "🚨 Urgent: Action required for resolving disputed sale"

          expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
          charge.disputed_purchases.each do |purchase|
            expect(mail.body.encoded).to include purchase.link.name
          end
          expect(mail.body.encoded).to include "Any additional information you can provide in the next 72 hours will help us win on your behalf."
          expect(mail.body.encoded).to include "Submit additional information"
        end
      end

      context "when the purchase was done via a PayPal Connect account" do
        before do
          charge.update!(processor: PaypalChargeProcessor.charge_processor_id)
        end

        it "includes copy about PayPal's dispute process" do
          mail = ContactingCreatorMailer.chargeback_notice(dispute.id)

          expect(mail.body.encoded).to include "A customer of yours (#{charge.customer_email}) has disputed their purchase of the following items for #{charge.formatted_disputed_amount}."
          charge.disputed_purchases.each do |purchase|
            expect(mail.body.encoded).to include purchase.link.name
          end
          expect(mail.body.encoded).to include "Unfortunately, we’re unable to fight disputes on purchases via PayPal Connect since we don’t have access to your PayPal account."
        end
      end
    end
  end

  describe "negative_revenue_sale_failure", :vcr do
    before do
      product = create(:product, price_cents: 100, user: create(:user, email: "seller@gr.co"))
      affiliate = create(:direct_affiliate, affiliate_basis_points: 7500, products: [product])
      allow_any_instance_of(Purchase).to receive(:determine_affiliate_balance_cents).and_return(90)
      @purchase = create(:purchase, link: product, seller: product.user, affiliate:, save_card: false, chargeable: create(:chargeable))
      @purchase.process!
    end

    it "sends the correct sale failure email" do
      mail = ContactingCreatorMailer.negative_revenue_sale_failure(@purchase.id)

      expect(mail.to).to eq ["seller@gr.co"]
      expect(mail.subject).to eq "A sale failed because of negative net revenue"
      expect(mail.body.encoded).to include "A customer (#{@purchase.email}) attempted to purchase your product (#{@purchase.link.name}) for #{@purchase.formatted_display_price}."
      expect(mail.body.encoded).to include "But the purchase was blocked because your net revenue from it was not positive."
      expect(mail.body.encoded).to include "You should either increase the sale price of your product, or reduce the applicable discount and/or affiliate commission."
    end
  end

  describe "preorder_release_reminder" do
    let(:preorder_link) { create(:preorder_link) }
    let(:product) { preorder_link.link }
    let(:seller) { product.user }

    context "for a physical product" do
      before do
        product.update!(is_physical: true, require_shipping: true)
      end
      it "sends the email with the the correct text" do
        email = ContactingCreatorMailer.preorder_release_reminder(product.id)

        expect(email.to).to eq [seller.form_email]
        expect(email.subject).to eq "Your pre-order will be released shortly"

        expect(email.body.encoded).to include "Your pre-order, #{product.name} will be released on"
        expect(email.body.encoded).to include "Charges will occur at that time."
        expect(email.body.encoded).to include "Your customers will be excited for #{product.name} to ship shortly after they are charged."
        expect(email.body.encoded).to_not include "You will need to upload a file before its release, or we won't be able to release the product and charge your customers"
      end
    end

    context "for a non-physical product" do
      context "when the product does not have delivery content saved" do
        before do
          allow_any_instance_of(Link).to receive(:has_content?).and_return(false)
        end
        it "sends the email with the the correct text" do
          email = ContactingCreatorMailer.preorder_release_reminder(product.id)

          expect(email.to).to eq [seller.form_email]
          expect(email.subject).to eq "Your pre-order will be released shortly"

          expect(email.body.encoded).to include "Your pre-order, #{product.name} is scheduled for a release on"
          expect(email.body.encoded).to include "You will need to"
          expect(email.body.encoded).to include "upload files or specify a redirect URL"
          expect(email.body.encoded).to include "before its release, or we won't be able to release the product and charge your customers."
        end
      end

      context "when the product has delivery content saved" do
        before do
          allow_any_instance_of(Link).to receive(:has_content?).and_return(true)
        end
        it "sends the email with the the correct text" do
          email = ContactingCreatorMailer.preorder_release_reminder(product.id)

          expect(email.to).to eq [seller.form_email]
          expect(email.subject).to eq "Your pre-order will be released shortly"

          expect(email.body.encoded).to include "Your pre-order, #{product.name} will be released on"
          expect(email.body.encoded).to include "Once released all credit cards will be charged."
          expect(email.body.encoded).to_not include "You will need to upload a file before its release, or we won't be able to release the product and charge your customers"
        end
      end
    end
  end

  describe "remind" do
    before do
      @user = create(:user, email: "blah@example.com")
      allow_any_instance_of(User).to receive(:secure_external_id).and_return("sample-secure-id")
    end

    it "sends out a reminder" do
      mail = ContactingCreatorMailer.remind(@user.id)
      expect(mail.to).to eq ["blah@example.com"]
      expect(mail.subject).to eq "Please add a payment account to Gumroad."
      expect(mail.body.encoded).to include user_unsubscribe_url(id: "sample-secure-id", email_type: :product_update)
    end
  end

  describe "seller_update" do
    before do
      @user = create(:user)
      allow_any_instance_of(User).to receive(:secure_external_id).and_return("sample-secure-id")
      end_of_period = Date.today.beginning_of_week(:sunday).to_datetime
      @start_of_period = end_of_period - 7.days
    end

    it "sends an update to the seller" do
      mail = ContactingCreatorMailer.seller_update(@user.id)
      expect(mail.subject).to eq "Your last week."
      expect(mail.to).to eq [@user.email]
      expect(mail.body.encoded).to include user_unsubscribe_url(id: "sample-secure-id", email_type: :seller_update)
    end

    describe "subscriptions" do
      before do
        @user = create(:user)
        @product = create(:subscription_product, user: @user)
        @product_subscription1 = create(:subscription, link: @product)
      end

      it "renders properly" do
        @product_subscription2 = create(:subscription, link: @product)
        link2 = create(:subscription_product, user: @user)
        link2_subscription1 = create(:subscription, link: link2)
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: true, link: @product, created_at: @start_of_period + 1.hour)
        create(:purchase, subscription_id: @product_subscription2.id, is_original_subscription_purchase: true, link: @product, created_at: @start_of_period + 1.hour)
        create(:purchase, subscription_id: link2_subscription1.id, is_original_subscription_purchase: true, link: link2, created_at: 17.days.ago)
        create(:purchase, subscription_id: link2_subscription1.id, is_original_subscription_purchase: false, link: link2, created_at: @start_of_period + 1.hour)

        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include @product.name
        expect(mail.body).to include "2 new subscriptions"
        expect(mail.body).to include link2.name
        expect(mail.body).to include "1 existing subscription"
      end

      it "does not show any new subscriptions" do
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: true, link: @product, created_at: 19.days.ago)
        create(:purchase, subscription_id: @product_subscription1.id, is_original_subscription_purchase: false, link: @product, created_at: @start_of_period + 1.hour)

        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include @product.name
        expect(mail.body).to include "1 existing subscription"
        expect(mail.body).to_not include "new subscription"
      end
    end

    describe "sales" do
      before do
        @user = create(:user)
        @product = create(:product, user: @user, is_recurring_billing: false, created_at: @start_of_period - 2.hours)
        @product2 = create(:product, user: @user, is_recurring_billing: false, created_at: @start_of_period - 2.hours)
        2.times { create(:purchase, link: @product, created_at: @start_of_period + 1.hour) }
        create(:purchase, link: @product, created_at: 5.minutes.ago)
        create(:purchase, link: @product2, created_at: @start_of_period + 1.hour)
        create(:purchase, link: @product2, created_at: @start_of_period + 1.hour, chargeback_date: DateTime.current)
      end

      it "renders properly" do
        mail = ContactingCreatorMailer.seller_update(@user.id)
        expect(mail.subject).to eq "Your last week."
        expect(mail.to).to eq [@user.email]
        expect(mail.body).to include "$0.21" # 3 not-chargebacked purchases * 7¢ each.
        expect(mail.body).to include @product.name
        expect(mail.body).to include "2 sales"
        expect(mail.body).to include @product2.name
        expect(mail.body).to include "1 sale"
      end
    end
  end

  describe "credit_notification" do
    before do
      @user = create(:user)
    end

    it "notifies user about credit to their account" do
      mail = ContactingCreatorMailer.credit_notification(@user.id, 200)
      expect(mail.to).to eq [@user.email]
      expect(mail.subject).to eq "You've received Gumroad credit!"
      expect(mail.body.encoded).to include "$2"
    end
  end

  describe "gumroad_day_credit_notification" do
    before do
      @user = create(:user)
    end

    it "notifies user about credit to their account" do
      mail = ContactingCreatorMailer.gumroad_day_credit_notification(@user.id, 200)
      expect(mail.to).to eq [@user.email]
      expect(mail.subject).to eq "You've received Gumroad credit!"
      expect(mail.body.encoded).to include "$2"
    end
  end

  describe "notify" do
    let(:seller) { create(:user, email: "seller@example.com") }
    let(:buyer) { create(:user, email: "buyer@example.com") }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, link: product, seller: product.user) }

    before do
      Feature.activate(:send_sales_notifications_to_creator_app)
    end

    def expect_push_alert(seller_id, text)
      expect(PushNotificationWorker).to have_enqueued_sidekiq_job(seller_id,
                                                                  Device::APP_TYPES[:creator],
                                                                  text, nil, {}, "chaching.wav")
    end

    it "uses SUPPORT_EMAIL as from address" do
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end

    it "works normally" do
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{product.name} for #{purchase.formatted_total_price}"
      expect(mail.to).to eq([seller.email])

      expect_push_alert(seller.id, mail.subject)
    end

    it "works for $0 purchases" do
      product = create(:product, user: seller, price_cents: 0, customizable_price: true)
      purchase = create(:purchase, link: product, seller: product.user, stripe_transaction_id: nil, stripe_fingerprint: nil)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New download of #{product.name}"

      expect_push_alert(seller.id, mail.subject)
    end

    it "works without a purchaser" do
      purchase.create_url_redirect!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{product.name} for #{purchase.formatted_total_price}"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not work without a buyer email" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase, link:, purchaser: buyer, seller: link.user)
      expect(purchase.update(email: nil)).to be(false)
    end

    it "includes discover notice and sets the referrer to Gumroad Discover" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, was_discover_fee_charged: true, referrer: UrlService.discover_domain_with_protocol)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "<a href=\"#{UrlService.discover_domain_with_protocol}\" target=\"_blank\">Gumroad Discover</a>"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Direct when the referrer URL equals 'direct'" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "direct")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "Direct"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Profile when the referrer URL is from the seller's profile" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "https://#{seller.username}.gumroad.com")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include "<a href=\"https://#{seller.username}.gumroad.com\" target=\"_blank\">Profile</a>"

      expect_push_alert(seller.id, mail.subject)
    end

    it "sets the referrer to Twitter when the referrer URL is from twitter" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", referrer: "https://twitter.com/")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Referrer"
      expect(mail.body.encoded).to include '<a href="https://twitter.com/" target="_blank">Twitter</a>'

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes quantity if greater than 1" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, quantity: 3)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Quantity"
      expect(mail.body.encoded).to include "3"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, shipping cost, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller)
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, quantity: 3, shipping_cents: 400, price_cents: 500)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "Shipping"
      expect(mail.body.encoded).to include "$4"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$5"
      expect(mail.body.encoded).to include "Shipping address"
      expect(mail.body.encoded).to include "barnabas"
      expect(mail.body.encoded).to include "123 barnabas street"
      expect(mail.body.encoded).to include "barnabasville, CA 94114"
      expect(mail.body.encoded).to include "United States"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero tax, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "Sales tax"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero VAT, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate, country: "DE"))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "EU VAT"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, nonzero VAT inclusive, and total transaction" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 40,
                        price_cents: 140,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: false,
                        zip_tax_rate: create(:zip_tax_rate, country: "DE"))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to include "EU VAT (included)"
      expect(mail.body.encoded).to include "$0.40"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1.40"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not include tax if it is 0" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:product, user: seller)
      purchase = create(:purchase,
                        link:,
                        purchaser: buyer,
                        seller: link.user,
                        quantity: 1,
                        tax_cents: 0,
                        price_cents: 100,
                        was_purchase_taxable: true,
                        was_tax_excluded_from_price: true,
                        zip_tax_rate: create(:zip_tax_rate))
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "$1"
      expect(mail.body.encoded).to_not include "Sales tax"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "$1"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes product price, shipping cost, and total transaction for jpy" do
      seller = create(:user, email: "bob@gumroad.com")
      buyer = create(:user, email: "bob2@gumroad.com")
      link = create(:physical_product, user: seller, price_currency_type: "jpy")
      purchase = create(:physical_purchase, link:, purchaser: buyer, seller: link.user, shipping_cents: 400, price_cents: 528, displayed_price_cents: 100, displayed_price_currency_type: "jpy")
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.subject).to eq "New sale of #{link.name} for #{purchase.formatted_total_price}"
      expect(mail.body.encoded).to include "Product price"
      expect(mail.body.encoded).to include "¥100"
      expect(mail.body.encoded).to include "Shipping"
      expect(mail.body.encoded).to include "¥314"
      expect(mail.body.encoded).to include "Order total"
      expect(mail.body.encoded).to include "¥414"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes discount information" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 500)
      offer_code = create(:percentage_offer_code, products: [product], name: "Black Friday", amount_percentage: 10)
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", offer_code:)
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Discount"
      expect(mail.body.encoded).to include "Black Friday (10% off)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes upsell information without offer code" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller)
      upsell = create(:upsell, product:, name: "Complete course", seller:)
      upsell_variant = create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second)
      upsell_purchase = create(:upsell_purchase, upsell:, upsell_variant:)
      mail = ContactingCreatorMailer.notify(upsell_purchase.purchase.id)
      expect(mail.body.encoded).to include "Upsell"
      expect(mail.body.encoded).to include "Complete course"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes upsell information with offer code" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller, price_cents: 1000)
      offer_code = create(:percentage_offer_code, user: seller, products: [product], amount_percentage: 20)
      upsell = create(:upsell, product:, name: "Complete course", seller:, offer_code:)
      upsell_variant = create(:upsell_variant, upsell:, selected_variant: product.alive_variants.first, offered_variant: product.alive_variants.second)
      upsell_purchase = create(:upsell_purchase, upsell:, upsell_variant:)
      mail = ContactingCreatorMailer.notify(upsell_purchase.purchase.id)
      expect(mail.body.encoded).to include "Upsell"
      expect(mail.body.encoded).to include "Complete course (20% off)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes variant information" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product_with_digital_versions, user: seller)
      variant = product.variant_categories_alive.first.variants.first
      purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", variant_attributes: [variant])
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Variant"
      expect(mail.body.encoded).to include "(Untitled 1)"

      expect_push_alert(seller.id, mail.subject)
    end

    context "when the product is a membership product" do
      it "includes tier information" do
        seller = create(:user, email: "bob@gumroad.com")
        product = create(:membership_product_with_preset_tiered_pricing, user: seller)
        purchase = create(:membership_purchase, link: product, email: "ibuy@gumroad.com", variant_attributes: [product.default_tier])
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Tier"
        expect(mail.body.encoded).to include "(First Tier)"

        expect_push_alert(seller.id, mail.subject)
      end
    end

    it "includes the affiliate commission information when 'apply_to_all_products' is true" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:, affiliate_basis_points: 5_00, apply_to_all_products: true)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Affiliate email"
      expect(mail.body.encoded).to include affiliate_user.form_email
      expect(mail.body.encoded).to include "Affiliate commission"
      expect(mail.body.encoded).to include "$0.50 (5%)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "includes the product commission information when 'apply_to_all_products' is false" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 10_00)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:, apply_to_all_products: false)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to include "Affiliate email"
      expect(mail.body.encoded).to include affiliate_user.form_email
      expect(mail.body.encoded).to include "Affiliate commission"
      expect(mail.body.encoded).to include "$1 (10%)"

      expect_push_alert(seller.id, mail.subject)
    end

    it "does not include affiliate information when price is $0" do
      seller = create(:user, email: "bob@gumroad.com")
      product = create(:product, user: seller, price_cents: 0, customizable_price: true)
      affiliate_user = create(:affiliate_user)
      direct_affiliate = create(:direct_affiliate, affiliate_user:, seller:)
      create(:product_affiliate, product:, affiliate: direct_affiliate, affiliate_basis_points: 10_00)
      purchase = create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", purchase_state: "in_progress", affiliate: direct_affiliate)
      purchase.process!
      purchase.update_balance_and_mark_successful!
      mail = ContactingCreatorMailer.notify(purchase.id)
      expect(mail.body.encoded).to_not include "Affiliate commission"

      expect_push_alert(seller.id, mail.subject)
    end

    context "for a collab product" do
      let(:product) { create(:product, price_cents: 20_00) }
      let(:seller) { product.user }
      let(:collaborator) { create(:collaborator) }
      let(:purchase) { create(:purchase_in_progress, link: product, email: "ibuy@gumroad.com", affiliate: collaborator) }

      before do
        create(:product_affiliate, affiliate: collaborator, product:, affiliate_basis_points: 50_00)
        purchase.process!
        purchase.update_balance_and_mark_successful!
      end

      it "includes the collaborator information" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Collaborator email"
        expect(mail.body.encoded).to include collaborator.affiliate_user.form_email
        expect(mail.body.encoded).to include "Collaborator commission"
        expect(mail.body.encoded).to include "$10 (50%)"
      end
    end

    context "when send_creator_notifications_to_consumer_app feature flag is enabled" do
      before do
        Feature.activate(:send_sales_notifications_to_consumer_app)
      end

      it "sends sale notification to both creator and consumer apps" do
        mail = ContactingCreatorMailer.notify(purchase.id)

        expect_push_alert(seller.id, mail.subject)
        expect(PushNotificationWorker).to have_enqueued_sidekiq_job(seller.id,
                                                                    Device::APP_TYPES[:consumer],
                                                                    mail.subject, nil, {}, "chaching.wav")
      end
    end

    context "when the purchase is a gift" do
      it "adds a row displaying the giftee's email" do
        seller = create(:user, email: "bob@gumroad.com")
        product = create(:product, user: seller)
        purchase = create(:purchase, link: product, email: "ibuy@gumroad.com", is_gift_sender_purchase: true)
        create(:gift, gifter_email: "ibuy@gumroad.com", giftee_email: "giftee@gumroad.com", link: @product, gifter_purchase: purchase)
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Giftee email"
        expect(mail.body.encoded).to include "giftee@gumroad.com"

        expect_push_alert(seller.id, mail.subject)
      end
    end

    context "when the purchase is via staff picks" do
      before do
        purchase.update!(recommended_by: RecommendationType::GUMROAD_STAFF_PICKS_RECOMMENDATION)
      end

      it "includes subheading about staff picks" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "via Staff picks in <a href=\"#{UrlService.discover_domain_with_protocol}\" target=\"_blank\">Discover</a>"
      end
    end


    context "when the purchase is via more like this" do
      before do
        purchase.update!(was_product_recommended: true, recommended_by: RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, referrer: "gumroad.com")
      end

      it "includes subheading about more like this" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "via More like this recommendations"
      end

      it "includes more like this as the referrer" do
        mail = ContactingCreatorMailer.notify(purchase.id)
        expect(mail.body.encoded).to include "Referrer"
        expect(mail.body.encoded).to include '<a href="gumroad.com" target="_blank">Gumroad Product Recommendations</a>'
      end
    end

    describe "subscription purchases" do
      context "for original purchase" do
        it "renders the correct subject" do
          purchase = create(:membership_purchase)

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to match(/^You have a new subscriber for /)

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end

      context "for recurring purchase" do
        it "renders the correct subject" do
          purchase = create(:recurring_membership_purchase, is_original_subscription_purchase: false)

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to eq("New recurring charge for #{purchase.link.name} of #{purchase.formatted_total_price}")

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end

      context "for upgrade purchase" do
        it "renders the correct subject" do
          purchase = create(:recurring_membership_purchase, is_original_subscription_purchase: false)
          purchase.is_upgrade_purchase = true
          purchase.save!

          mail = ContactingCreatorMailer.notify(purchase.id)
          expect(mail.subject).to eq("A subscriber has upgraded their subscription for #{purchase.link.name} and was charged #{purchase.formatted_total_price}")

          expect_push_alert(purchase.seller.id, mail.subject)
        end
      end
    end

    describe "test purchases" do
      it "works without a purchase" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "bob@gumroad.com", link.id)
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works without a purchase with variants" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "another@gumroad.com", link.id, nil, %w[blue small])
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works without a purchase with shipping info" do
        seller = create(:user)
        link = create(:product, user: seller, require_shipping: true)
        shipping_info = { full_name: "Jim Banshee", street_address: "40 Queensdale Boulevard", zip_code: 12_345,
                          city: "Dalesfieldvilleton City", country: "USA", state: "Iowa" }
        mail = ContactingCreatorMailer.notify(nil, false, "yetanother@gumroad.com", link.id, nil, nil, shipping_info)
        expect(mail.subject).to eq "New sale of #{link.name} for #{link.price_formatted}"

        expect_push_alert(seller.id, mail.subject)
      end

      it "works with a price range" do
        seller = create(:user)
        link = create(:product, user: seller)
        mail = ContactingCreatorMailer.notify(nil, false, "blue@gumroad.com", link.id, 400, nil, nil)
        expect(mail.subject).to eq "New sale of #{link.name} for $4"

        expect_push_alert(seller.id, mail.subject)
      end

      describe "payment notification settings" do
        before do
          @user = create(:user, email: "blah@gumroad.com")
          @link = create(:product, user: @user)
          @purchase = create(:purchase, link: @link, seller: @link.user)
        end

        context "with default notification settings" do
          it "sends email and push notification" do
            mail = ContactingCreatorMailer.notify(@purchase.id)
            expect(mail.subject).to eq "New sale of #{@link.name} for #{@purchase.formatted_total_price}"
            expect(mail.to).to eq(["blah@gumroad.com"])
            expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])

            expect_push_alert(@user.id, mail.subject)
          end
        end

        context "with email notifications disabled" do
          before do
            @user.enable_payment_email = false
            @user.save!
          end

          it "does not sends email but sends push notification" do
            mail = ContactingCreatorMailer.notify(@purchase.id)
            expect(mail.message).to be_a(ActionMailer::Base::NullMail)

            expect_push_alert(@user.id, "New sale of #{@link.name} for #{@purchase.formatted_total_price}")
          end

          context "with push notifications disabled" do
            before do
              @user.enable_payment_push_notification = false
              @user.save!
            end

            it "does not sends email or push notifications" do
              mail = ContactingCreatorMailer.notify(@purchase.id)
              expect(mail.message).to be_a(ActionMailer::Base::NullMail)

              expect(PushNotificationWorker.jobs.size).to eq(0)
            end
          end
        end
      end
    end

    describe "pre-orders" do
      it "delivers notification with pre order subject" do
        creator = create(:user)
        product = create(:product, user: creator)
        purchase = create(:preorder_authorization_purchase, link: product, seller: product.user)
        mail = ContactingCreatorMailer.notify(purchase.id, true)
        expect(mail.subject).to eq "New pre-order of #{product.name} for #{purchase.formatted_total_price}"

        expect_push_alert(creator.id, mail.subject)
      end
    end

    describe "coffee products" do
      it "excludes quantity and variant from email" do
        product = create(:coffee_product)
        purchase = create(:purchase, link: product, seller: product.user)
        mail = ContactingCreatorMailer.notify(purchase.id, true)
        expect(mail.body.encoded).to_not include "Quantity"
        expect(mail.body.encoded).to_not include "Variant"
      end
    end

    describe "call products" do
      let(:variant_category) { call.link.variant_categories.first }

      context "call that starts and ends on the same day" do
        let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("2023-05-15 14:30 UTC"), end_time: DateTime.parse("2023-05-15 15:30 UTC")) }

        before do
          call.purchase.update!(variant_attributes: [create(:variant, name: "60 minutes", duration_in_minutes: 60, variant_category:)])
        end

        it "includes call information in the email" do
          mail = ContactingCreatorMailer.notify(call.purchase.id)

          expect(mail.body.encoded).to include("Call schedule")
          expect(mail.body.encoded).to include("07:30 AM - 08:30 AM PDT")
          expect(mail.body.encoded).to include("Monday, May 15th, 2023")
          expect(mail.body.encoded).to include("Duration")
          expect(mail.body.encoded).to include("60 minutes")
          expect(mail.body.encoded).not_to include("Quantity")
          expect(mail.body.encoded).not_to include("Variant")
        end
      end

      context "call that spans multiple days" do
        let(:call) { create(:call, :skip_validation, start_time: DateTime.parse("2023-05-15 22:30 PDT"), end_time: DateTime.parse("2023-05-16 01:30 PDT")) }

        before do
          call.purchase.update!(variant_attributes: [create(:variant, name: "3 hours", duration_in_minutes: 180, variant_category:)])
        end

        it "includes call information for multi-day calls" do
          mail = ContactingCreatorMailer.notify(call.purchase.id)

          expect(mail.body.encoded).to include("Call schedule")
          expect(mail.body.encoded).to include("10:30 PM - 01:30 AM PDT")
          expect(mail.body.sanitized).to include("Monday, May 15th, 2023 - Tuesday, May 16th, 2023")
          expect(mail.body.encoded).to include("Duration")
          expect(mail.body.encoded).to include("3 hours")
        end
      end
    end

    context "purchase with tip", :vcr do
      before { purchase.create_tip(value_cents: 100, value_usd_cents: 100) }

      it "includes the tip details" do
        mail = ContactingCreatorMailer.notify(purchase.id)

        expect(mail.body.sanitized).to include("$1 The Works of Edgar Gumstein")
        expect(mail.body.sanitized).to include("Tip $1")
      end
    end

    context "commission deposit purchase", :vcr do
      let(:commission) { create(:commission) }

      it "includes the commission details" do
        mail = ContactingCreatorMailer.notify(commission.deposit_purchase.id)

        expect(mail.subject).to eq ("New sale of The Works of Edgar Gumstein for $2")
        expect(mail.body.sanitized).to include("$2 The Works of Edgar Gumstein")
        expect(mail.body.sanitized).to include("Deposit paid $1")
      end
    end

    it "includes the UTM link driven sale details" do
      utm_link = create(:utm_link, seller: purchase.seller, utm_source: "twitter", utm_medium: "social", utm_campaign: "gumroad-day", utm_term: "gumroad-day-123", utm_content: "gumroad-day-56")
      create(:utm_link_driven_sale, purchase:, utm_link:)

      mail = ContactingCreatorMailer.notify(purchase.id)

      body = mail.body.sanitized
      expect(body).to include("UTM link driven sale")
      expect(body).to include("Link: #{utm_link.title}")
      expect(body).to include("Source: twitter")
      expect(body).to include("Medium: social")
      expect(body).to include("Campaign: gumroad-day")
      expect(body).to include("Term: gumroad-day-123")
      expect(body).to include("Content: gumroad-day-56")
      expect(mail.body.encoded).to have_link("UTM link", href: utm_link.utm_url)
      expect(mail.body.encoded).to have_link(utm_link.title, href: utm_links_dashboard_url(query: utm_link.title))
    end
  end

  describe "subscription_cancelled" do
    context "memberships" do
      before do
        @product = create(:product, subscription_duration: "monthly")
        @subscriber = create(:user)
        @subscription = create(:subscription, link: @product, user: @subscriber)
        @purchase = create(:purchase, link: @product, is_original_subscription_purchase: true, subscription: @subscription)
      end

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_cancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include @product.name
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_cancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been canceled."
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include subscription.link.name
      end
    end
  end

  describe "subscription_autocancelled" do
    context "memberships" do
      before do
        @product = create(:product)
        @subscriber = create(:user)
        @subscription = create(:subscription, link: @product, user: @subscriber)
      end

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
      end

      it "includes the purchase failure if available" do
        purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, stripe_error_code: "2000", card_type: CardType::PAYPAL, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, PayPal gave us this error message for the last failure:"
      end

      it "includes non-paypal purchase failure if available" do
        purchase = create(:purchase, is_original_subscription_purchase: true, link: @product, stripe_error_code: "2000", card_type: CardType::MASTERCARD, subscription: @subscription)
        purchase.update_attribute(:purchase_state, "failed")
        mail = ContactingCreatorMailer.subscription_autocancelled(@subscription.id)
        expect(mail.subject).to eq "A subscription has been canceled."
        expect(mail.body.encoded).to include @product.name
        expect(mail.body.encoded).to include @subscriber.email
        expect(mail.body.encoded).to include purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, your card issuer gave us this error message for the last failure:"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_autocancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paused."
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include subscription.email
      end

      it "includes the purchase failure if available" do
        installment_plan_purchase.update_columns(
          purchase_state: "failed",
          stripe_error_code: "2000",
          card_type: CardType::PAYPAL
        )
        mail = ContactingCreatorMailer.subscription_autocancelled(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paused."
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include installment_plan_purchase.formatted_error_code
        expect(mail.body.encoded).to include "For reference, PayPal gave us this error message for the last failure:"
      end
    end
  end

  describe "subscription_downgraded" do
    it "has the correct text" do
      product = create(:membership_product_with_preset_tiered_pricing)
      new_tier = product.tiers.last
      purchase = create(:membership_purchase, link: product, variant_attributes: [product.default_tier])
      subscription = purchase.subscription
      plan_change = subscription.subscription_plan_changes.create!(tier: new_tier, perceived_price_cents: 1599, recurrence: "yearly")
      downgrade_date = subscription.end_time_of_subscription.in_time_zone(subscription.user.timezone).to_fs(:formatted_date_full_month)

      mail = ContactingCreatorMailer.subscription_downgraded(subscription.id, plan_change.id)

      expect(mail.subject).to eq "A subscription has been downgraded."
      expect(mail.body.encoded).to include "has elected to downgrade their subscription to #{product.name}"
      expect(mail.body.encoded).to include new_tier.name
      expect(mail.body.encoded).to include downgrade_date
    end
  end

  describe "subscription_restarted" do
    context "memberships" do
      it "has the correct text" do
        product = create(:membership_product_with_preset_tiered_pricing)
        purchase = create(:membership_purchase, link: product, variant_attributes: [product.default_tier])
        subscription = purchase.subscription

        mail = ContactingCreatorMailer.subscription_restarted(subscription.id)

        expect(mail.subject).to eq "A subscription has been restarted."
        expect(mail.body.encoded).to include "has restarted their subscription to #{product.name}"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_restarted(subscription.id)
        expect(mail.subject).to eq "An installment plan has been restarted."
        expect(mail.body.encoded).to include "has restarted their installment plan for #{subscription.link.name}"
      end
    end
  end

  describe "subscription_product_deleted" do
    context "memberships" do
      let(:product) { create(:subscription_product) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_product_deleted(product.id)
        expect(mail.subject).to eq "Subscriptions have been canceled"
        expect(mail.body.encoded).to include "Subscriptions for product #{product.name} have been canceled due to the deletion of the product"
      end
    end

    context "installment plans" do
      let(:product) { create(:product) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_product_deleted(product.id)
        expect(mail.subject).to eq "Installment plans have been canceled"
        expect(mail.body.encoded).to include "Installment plans for product #{product.name} have been canceled due to the deletion of the product"
      end
    end
  end

  describe "subscription_ended" do
    context "memberships" do
      let(:membership_purchase) { create(:membership_purchase) }
      let(:subscription) { membership_purchase.subscription }
      let(:product) { subscription.link }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "A subscription has ended."
        expect(mail.body.encoded).to include "A subscription to #{product.name} has expired for your subscriber #{subscription.email}"
      end
    end

    context "installment plans" do
      let(:installment_plan_purchase) { create(:installment_plan_purchase) }
      let(:subscription) { installment_plan_purchase.subscription }

      it "has the correct text" do
        mail = ContactingCreatorMailer.subscription_ended(subscription.id)
        expect(mail.subject).to eq "An installment plan has been paid in full."
        expect(mail.body.encoded).to include subscription.email
        expect(mail.body.encoded).to include subscription.link.name
        expect(mail.body.encoded).to include "has completed all their installment payments for"
      end
    end
  end

  describe "unremovable_discord_member" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:purchase) { create(:purchase, seller:, link: product) }

    it "has the correct subject and content" do
      mail = ContactingCreatorMailer.unremovable_discord_member("000000000000000000", "Server Name", purchase.id)

      expect(mail.subject).to eq "We were unable to remove a Discord member from your server"
      expect(mail.body.encoded).to include "Unremovable Discord member"
      expect(mail.body.encoded).to include product.name
      expect(mail.body.encoded).to include "We were unable to remove the member because they have a Discord role which is higher than the Gumroad bot's role on the server."
    end
  end

  describe "unstampable_pdf_notification" do
    let(:product) { create(:product) }

    it "has the correct subject and content" do
      mail = ContactingCreatorMailer.unstampable_pdf_notification(product.id)

      expect(mail.subject).to eq "We were unable to stamp your PDF"
      expect(mail.body.encoded).to include "We were unable to stamp your PDF"
      expect(mail.body.encoded).to include product.name
      expect(mail.body.encoded).to include edit_link_url(product)
    end
  end

  describe "chargeback_lost_no_refund_policy" do
    let(:seller) { create(:user) }

    context "for a dispute on Purchase" do
      let(:product) { create(:product, user: seller) }
      let!(:purchase) { create(:purchase, seller:, link: product) }
      let(:dispute) { create(:dispute_formalized, purchase:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)
        expect(mail.subject).to eq "A dispute has been lost"
        expect(mail.body.encoded).to include "Unfortunately, we weren't able to win the dispute initiated by" \
          " one of your customers (#{purchase.email}) for their purchase of " \
          "<a target=\"_blank\" href=\"#{product.long_url}\">#{product.name}</a> for #{purchase.formatted_disputed_amount}."
        expect(mail.body.encoded).to include product.link.name
        expect(mail.body.encoded).to include purchase.formatted_display_price
        expect(mail.body.encoded).to include product.long_url
        expect(mail.body.encoded).to include edit_link_url(product)
      end
    end

    context "for a dispute on Charge" do
      let(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge
      end

      let(:dispute) { create(:dispute_formalized_on_charge, purchase: nil, charge:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id)

        expect(mail.subject).to eq "A dispute has been lost"
        expect(mail.body.encoded).to include "Unfortunately, we weren't able to win the dispute initiated by" \
          " one of your customers (#{charge.customer_email}) for their purchase of the following items for #{charge.formatted_disputed_amount}."
        charge.disputed_purchases.each do |purchase|
          expect(mail.body.encoded).to include purchase.link.name
          expect(mail.body.encoded).to include purchase.formatted_display_price
          expect(mail.body.encoded).to include purchase.link.long_url
        end

        product_without_refund_policy = charge.first_product_without_refund_policy
        expect(mail.body.encoded).to include "We noticed that #{product_without_refund_policy.name} currently doesn't have a refund policy."
        expect(mail.body.encoded).to include edit_link_url(product_without_refund_policy)
      end
    end
  end

  describe "chargeback_won" do
    let!(:seller) { create(:user) }

    context "for a dispute on Purchase" do
      let!(:purchase) { create(:purchase, seller:, link: create(:product, user: seller)) }
      let!(:dispute) { create(:dispute, purchase:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_won(dispute.id)

        expect(mail.subject).to eq "A dispute has been won"
        expect(mail.body.encoded).to include "We have won a dispute against #{purchase.email}'s purchase of " \
          "#{purchase.link.name} for #{purchase.formatted_disputed_amount} on your behalf. Your account has been credited the full amount."
        expect(mail.body.encoded).to include purchase.link.name
        expect(mail.body.encoded).to include purchase.formatted_display_price
      end
    end

    context "for a dispute on Charge" do
      let!(:charge) do
        charge = create(:charge, seller:)
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge.purchases << create(:purchase, seller:, link: create(:product, user: seller))
        charge
      end

      let!(:dispute) { create(:dispute_on_charge, purchase: nil, charge:) }

      it "has the correct text" do
        mail = ContactingCreatorMailer.chargeback_won(dispute.id)

        expect(mail.subject).to eq "A dispute has been won"
        expect(mail.body.encoded).to include "We have won a dispute against #{charge.customer_email}'s purchase of " \
          "the following items for #{charge.formatted_disputed_amount} on your behalf. Your account has been credited the full amount."
        charge.disputed_purchases.each do |p|
          expect(mail.body.encoded).to include p.link.name
          expect(mail.body.encoded).to include p.formatted_display_price
        end
      end
    end
  end

  describe "preorder_summary" do
    before do
      @product = create(:product, price_cents: 600, is_in_preorder_state: false)
      @preorder_product = create(:preorder_product_with_content, link: @product)
      @preorder_product.update(release_at: Time.current) # bypassed the creation validation
      @good_card = build(:chargeable)
      @good_card_but_cant_charge = build(:chargeable_success_charge_decline)
    end

    describe "physical preorders" do
      before do
        @product.update(is_physical: true, require_shipping: true, name: "Physical Preorder")
        @product.shipping_destinations << ShippingDestination.new(country_code: Compliance::Countries::USA.alpha2, one_item_rate_cents: 4_00, multiple_items_rate_cents: 2_00)
        @preorder_product.update(url: nil)
      end

      it "sends the correct summary email", :vcr do
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include "The buyer has been charged, and they&#39;re ready to have Physical Preorder shipped to them."
        expect(mail.body.encoded).to_not include "Unfortunately"
      end

      it "includes the copy for the failed charges in the email", :vcr do
        # Successfully charged preorder:
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        # Preorder with failed charge
        authorization_purchase = build(:purchase,
                                       link: @product,
                                       chargeable: @good_card_but_cant_charge,
                                       purchase_state: "in_progress",
                                       is_preorder_authorization: true,
                                       full_name: "Edgar Gumstein",
                                       street_address: "123 Gum Road",
                                       country: "United States",
                                       state: "CA",
                                       city: "San Francisco",
                                       zip_code: "94107")
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include "The buyer has been charged, and they&#39;re ready to have Physical Preorder shipped to them."
        expect(mail.body.encoded).to include "Once corrected, the sale will appear in your account and Physical Preorder can be shipped to them."
        str = "Unfortunately, a customer&#39;s credit card was declined. We have sent an email asking them to update their information. " \
              "Once corrected, the sale will appear in your account and Physical Preorder can be shipped to them."
        expect(mail.body.encoded).to include str
      end

      it "does not send email if the preorder had no sales", :vcr do
        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq nil
      end
    end

    describe "digital preorders" do
      it "sends the correct summary email", :vcr do
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to_not include "Unfortunately"
      end

      it "includes the copy for the failed charges in the email", :vcr do
        # Successfully charged preorder:
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card, purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!
        preorder.mark_charge_successful

        # Preorder with failed charge
        authorization_purchase = build(:purchase, link: @product, chargeable: @good_card_but_cant_charge,
                                                  purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = @preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder.charge!

        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq "Your pre-order was successfully released!"
        expect(mail.body.encoded).to include "from 1 pre-order"
        expect(mail.body.encoded).to include ERB::Util.html_escape("Unfortunately, a customer's credit card")
        expect(mail.body.encoded).to include authorization_purchase.email
      end

      it "does not send email if the preorder had no sales", :vcr do
        mail = ContactingCreatorMailer.preorder_summary(@preorder_product.id)
        expect(mail.subject).to eq nil
      end
    end
  end

  describe "user_sales_data" do
    it "contains the correct text, attachment, and attributes" do
      user = create(:user)
      file = Tempfile.new(["TestSales", ".csv"])
      mail = ContactingCreatorMailer.user_sales_data(user.id, file)
      expect(mail.body.encoded).to include "Your requested data"
      expect(mail.body.encoded).to include "We've attached the customer data you requested to this email."
      expect(mail.attachments.size).to eq(1)
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq("Here's your customer data!")
    end
  end

  describe "payout_data" do
    let(:recipient) { create(:user) }
    let(:attachment_name) { "payout_data_#{SecureRandom.hex}.csv" }
    let(:extension) { "csv" }
    let(:tempfile) { Tempfile.new }

    context "when file can be attached directly" do
      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: tempfile, url: nil }
        )
      end

      it "contains the correct attachment and attributes" do
        mail = ContactingCreatorMailer.payout_data(attachment_name, extension, tempfile, recipient.id)

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to eq("Here's your payout data!")
        expect(mail.attachments.size).to eq(1)
        expect(mail.attachments[attachment_name]).to be_present
      end
    end

    context "when file is too large and a URL is provided instead" do
      let(:download_url) { "https://example.com/download/payout_data.csv" }

      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: nil, url: download_url }
        )
      end

      it "contains the download URL in the email body" do
        mail = ContactingCreatorMailer.payout_data(attachment_name, extension, tempfile, recipient.id)

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to eq("Here's your payout data!")
        expect(mail.attachments).to be_empty
        expect(mail.body.encoded).to include(download_url)
      end
    end
  end

  describe ".affiliates_data" do
    before do
      @recipient = create(:user)
      @filename = "affiliates-export-#{SecureRandom.hex}.csv"
      @tempfile = Tempfile.new
      @tempfile.puts "csv content"
    end

    let(:mail) do
      described_class.affiliates_data(
        recipient: @recipient,
        tempfile: @tempfile,
        filename: @filename,
      )
    end

    it "contains the correct attachment and attributes" do
      expect(mail.to).to eq([@recipient.email])
      expect(mail.subject).to include("Here is your affiliates data")
      expect(mail.attachments.size).to eq(1)
      expect(mail.attachments.first.body.raw_source).to eq("csv content\r\n")
    end

    context "when attachment size is above threshold" do
      before do
        stub_const("MailerAttachmentOrLinkService::MAX_FILE_SIZE", 1.byte)
      end

      it "contains a link instead of an attachment" do
        expect(mail.to).to eq([@recipient.email])
        expect(mail.subject).to include("Here is your affiliates data")
        expect(mail.attachments.size).to eq(0)
        expect(mail.body).to include(@filename)
        expect(Nokogiri::HTML(mail.body.encoded).text).to include("Please click this link")
      end
    end
  end

  describe ".subscribers_data" do
    let(:recipient) { create(:user) }
    let(:filename) { "subscribers-export-#{SecureRandom.hex}.csv" }
    let(:tempfile) { Tempfile.new }

    before do
      tempfile.puts "csv content"
    end

    it "contains the correct attachment and attributes" do
      mail = ContactingCreatorMailer.subscribers_data(
        recipient: recipient,
        tempfile: tempfile,
        filename: filename,
      )

      expect(mail.to).to eq([recipient.email])
      expect(mail.subject).to include("Here is your subscribers data")
      expect(mail.attachments.size).to eq(1)
      expect(mail.attachments.first.body.raw_source).to eq("csv content\r\n")
    end

    context "when attachment size is above threshold" do
      let(:download_url) { "https://example.com/download/subscribers_data.csv" }

      before do
        allow_any_instance_of(MailerAttachmentOrLinkService).to receive(:perform).and_return(
          { file: nil, url: download_url }
        )
      end

      it "contains a link instead of an attachment" do
        mail = ContactingCreatorMailer.subscribers_data(
          recipient: recipient,
          tempfile: tempfile,
          filename: filename,
        )

        expect(mail.to).to eq([recipient.email])
        expect(mail.subject).to include("Here is your subscribers data")
        expect(mail.attachments.size).to eq(0)
        expect(mail.body).to have_link("link", href: download_url)
      end
    end
  end

  describe "video_transcode_failed" do
    before do
      @user = create(:user, name: "Person")
      @product = create(:product, user: @user, name: "A Tale of Two Links")
      @product_file = create(:product_file, link: @product, display_name: "A Tale of Two Products")
      @product_file_two = create(:product_file, link: @product)
    end

    it "has the correct text when product file has display_name set" do
      mail = ContactingCreatorMailer.video_transcode_failed(@product_file.id)

      expect(mail.subject).to eq("A video failed to transcode.")
      expect(mail.to).to eq([@user.email])
      expect(mail.body.encoded).to include @product_file.s3_filename
      expect(mail.body.encoded).to include "Please try re-encoding it locally on your computer and uploading it again."
    end

    it "has the correct text when product file does not have display_name set" do
      mail = ContactingCreatorMailer.video_transcode_failed(@product_file_two.id)

      expect(mail.subject).to eq("A video failed to transcode.")
      expect(mail.to).to eq([@user.email])
      expect(mail.body.encoded).to include @product_file.link.name
      expect(mail.body.encoded).to include "Please try re-encoding it locally on your computer and uploading it again."
    end
  end

  describe "tax_form_1099k" do
    it "has the correct subject and body with form download url included" do
      creator = create(:user)
      year = Date.current.year

      form_download_url = "https://www.gumroad.com"
      mail = ContactingCreatorMailer.tax_form_1099k(creator.id, year, form_download_url)

      expect(mail.subject).to eq "Get your 1099-K form for #{year}"
      expect(mail.to).to eq [creator.email]
      expect(mail.body.encoded).to include "Your 1099-K form for #{year} is ready to download"
      expect(mail.body.encoded).to include "The 1099-K is a purely informational form that summarizes the payments that were made to your account during #{year} and is designed to help you report your taxes."
      expect(mail.body.encoded).to include "Our payment processor, Stripe, files a copy electronically with the IRS."
      expect(mail.body).to have_link("Download form", href: form_download_url)
      expect(mail.body.encoded).to include "You can also download it from your <a href=\"#{dashboard_url(host: UrlService.domain_with_protocol)}\">Gumroad dashboard</a> at any time."
    end
  end

  describe "tax_form_1099misc" do
    it "has the correct subject and body with form download url included" do
      creator = create(:user)
      year = Date.current.year

      form_download_url = "https://www.gumroad.com"
      mail = ContactingCreatorMailer.tax_form_1099misc(creator.id, year, form_download_url)

      expect(mail.subject).to eq "Get your 1099-MISC form for #{year}"
      expect(mail.to).to eq [creator.email]
      expect(mail.body.encoded).to include "Your 1099-MISC form for #{year} is ready to download"
      expect(mail.body.encoded).to include "The 1099-MISC is a purely informational form that summarizes the commissions you earned as an affiliate during #{year} and is designed to help you report your taxes."
      expect(mail.body.encoded).to include "Our payment processor, Stripe, files a copy electronically with the IRS."
      expect(mail.body).to have_link("Download form", href: form_download_url)
      expect(mail.body.encoded).to include "You can also download it from your <a href=\"#{dashboard_url(host: UrlService.domain_with_protocol)}\">Gumroad dashboard</a> at any time."
    end
  end

  describe "#singapore_identity_verification_reminder" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)

      mail = ContactingCreatorMailer.singapore_identity_verification_reminder(creator.id, Time.new(2023, 10, 10))

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Complete the identity verification to avoid account closure"
      expect(mail.body.encoded).to include "In accordance with Singapore’s Payment Services Act, our payment processor Stripe requires extra verification for Singapore-based accounts."
      expect(mail.body.encoded).to include "https://gumroad.com/settings/payments"
      expect(mail.body.encoded).to include "After the deadline on October 10, 2023, your current balance will be forfeited."
    end
  end

  describe "#stripe_document_verification_failed" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)
      stripe_error_reason = "The document might have been altered so it could not be verified."

      mail = ContactingCreatorMailer.stripe_document_verification_failed(creator.id, stripe_error_reason)

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Document Verification Failed"
      expect(mail.body.encoded).to include "Sorry about this! We ran into the following issue when trying to verify the document you uploaded on your payout settings page:"
      expect(mail.body.encoded).to include stripe_error_reason
      expect(mail.body.encoded).to include "Please upload a valid document at:"
      expect(mail.body.encoded).to include settings_payments_url
    end
  end

  describe "#stripe_identity_verification_failed" do
    it "has the correct subject and body with payments settings page url included" do
      creator = create(:user)
      stripe_error_reason = "The identity information you entered cannot be verified. Please correct any errors or upload a document that matches the identity fields (e.g., name and date of birth) that you entered."

      mail = ContactingCreatorMailer.stripe_identity_verification_failed(creator.id, stripe_error_reason)

      expect(mail.to).to eq [creator.email]
      expect(mail.subject).to eq "[Action Required] Identity Verification Failed"
      expect(mail.body.encoded).to include "Sorry about this! We ran into the following issue when trying to verify the information entered on your payout settings page:"
      expect(mail.body.encoded).to include stripe_error_reason
      expect(mail.body.encoded).to include "Please make any required changes at:"
      expect(mail.body.encoded).to include settings_payments_url
    end
  end

  describe "#review_submitted" do
    let(:review) { create(:product_review) }

    it "has the correct subject and body" do
      mail = ContactingCreatorMailer.review_submitted(review.id)
      expect(mail.to).to eq([review.link.user.email])
      expect(mail.subject).to eq("#{review.purchase.email} reviewed #{review.link.name}")
      expect(mail.body.encoded).to have_text("New review")
      expect(mail.body.encoded).to have_text("#{review.purchase.email} reviewed")
      expect(mail.body.encoded).to have_link(review.link.name, href: review.link.long_url)
      expect(mail.body.encoded).to have_text(review.message)
      expect(mail.body.encoded).to have_selector("[aria-label='1 star']")
      expect(mail.body.encoded).to have_selector("img[src='#{ActionController::Base.helpers.asset_path("email/solid-star.png")}']", count: 1)
      expect(mail.body.encoded).to have_selector("img[src='#{ActionController::Base.helpers.asset_path("email/outline-star.png")}']", count: 4)
      expect(mail.body.encoded).to have_link("View all reviews", href: review.link.long_url)
    end

    context "no message" do
      before { review.update!(message: nil) }
      it "omits the quotation marks" do
        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.body.encoded).to_not have_text('""')
      end
    end

    context "when the review has a pending video" do
      let!(:pending_video) do
        create(
          :product_review_video,
          :pending_review,
          product_review: review,
          video_file: create(:video_file, :with_thumbnail)
        )
      end

      it "includes the video thumbnail" do
        mail = ContactingCreatorMailer.review_submitted(review.id)
        expect(mail.body.encoded).to have_selector("img[src='#{pending_video.video_file.thumbnail_url}']")
        expect(mail.body.encoded).to have_link("Review & approve video", href: customers_url(query: review.purchase.email))
      end
    end
  end

  describe "#upcoming_call_reminder" do
    describe "email content", :freeze_time do
      before { travel_to(Time.utc(2024, 5, 1)) }

      let!(:product) { create(:call_product, :available_for_a_year, name: "Portfolio review") }
      let!(:variant_category) { product.variant_categories.first }
      let!(:variant) { create(:variant, name: "60 minutes", duration_in_minutes: 60, variant_category:) }
      let!(:call) do
        create(
          :call,
          start_time: DateTime.parse("2024-05-02 10:00:00 PDT"),
          end_time: DateTime.parse("2024-05-02 11:00:00 PDT"),
          purchase: build(:call_purchase, link: product, variant_attributes: [variant])
        )
      end
      let!(:checkout_custom_fields) do
        [
          create(
            :purchase_custom_field,
            purchase: call.purchase,
            name: "Checkout custom field name",
            value: "Checkout custom field value"
          )
        ]
      end
      let!(:post_purchase_custom_field) do
        create(
          :purchase_custom_field,
          purchase: call.purchase,
          is_post_purchase: true,
          name: "Post purchase custom field name",
          value: "Post purchase custom field value"
        )
      end
      let!(:file_custom_field) do
        create(
          :purchase_custom_field,
          purchase: call.purchase,
          field_type: CustomField::TYPE_FILE,
          name: "File upload",
          value: "Post purchase custom field value"
        )
      end


      it "includes the correct information" do
        mail = ContactingCreatorMailer.upcoming_call_reminder(call.id)

        expect(mail.to).to eq([product.user.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body).to include("Your scheduled call with #{call.purchase.email} is tomorrow!")

        expect(mail.body.sanitized).to include("Checkout custom field name Checkout custom field value")
        expect(mail.body.sanitized).to include("Post purchase custom field name Post purchase custom field value")
        expect(mail.body).to_not include("File upload")

        expect(mail.body.sanitized).to include("Call schedule 10:00 AM - 11:00 AM PDT Thursday, May 2nd, 2024")
        expect(mail.body.sanitized).to include("Duration 60 minutes")
        expect(mail.body.sanitized).to include("Product Portfolio review")
      end
    end

    context "when the call is not eligible for reminder" do
      let(:call) { create(:call) }

      it "does not send the email" do
        allow_any_instance_of(Call).to receive(:eligible_for_reminder?).and_return(false)

        mail = ContactingCreatorMailer.upcoming_call_reminder(call.id)

        expect(mail.subject).to be_nil
      end
    end
  end

  describe "#stripe_remediation", :vcr do
    let!(:seller) { create(:named_seller) }
    let!(:user_compliance_info) { create(:user_compliance_info, user: seller) }
    let!(:bank_account) { create(:ach_account_stripe_succeed, user: seller) }
    let!(:tos_agreement) { create(:tos_agreement, user: seller) }
    let!(:stripe_connect_account_id) { StripeMerchantAccountManager.create_account(seller, passphrase: "1234").charge_processor_merchant_id }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-09-23")) do
        mail = ContactingCreatorMailer.stripe_remediation(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to eq("We need more information from you.")

        expect(mail.body.encoded).to include("To continue paying you out, we need some more information from you.")
        expect(mail.body.encoded).to include("This information is required by our banking partners for identity verification, to align with bank regulations, and to protect against fraud.")
        expect(mail.body.encoded).to include("Please provide the requested information before your next payout.")
        expect(mail.body.encoded).to have_link("Provide your information", href: remediation_settings_payments_url)
      end
    end
  end

  describe "#suspended_due_to_stripe_risk" do
    let(:seller) { create(:named_seller) }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-09-23")) do
        mail = ContactingCreatorMailer.suspended_due_to_stripe_risk(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
        expect(mail.subject).to eq("Your account has been suspended for being high risk")

        expect(mail.body.encoded).to include("Hey,")
        expect(mail.body.encoded).to include("We want to first thank you for choosing Gumroad. We're really excited to help you get paid for your work and grow your business.")
        expect(mail.body.encoded).to include("However, our banking partners have found your account to be a high risk, so we are temporarily suspending your account.")
        expect(mail.body.encoded).to include("Of course, we will pay you out your remaining balance. Your existing customers' purchases will not be affected by this.")
        expect(mail.body.encoded).to include("And you can contact our support team to get your account reviewed again.")
        expect(mail.body.encoded).to include("We're super sorry about the inconvenience!")
        expect(mail.body.encoded).to include("Sahil and the Gumroad team")
      end
    end
  end

  describe "product_level_refund_policies_reverted" do
    let(:seller) { create(:user) }

    it "sends the email correctly" do
      mail = ContactingCreatorMailer.product_level_refund_policies_reverted(seller.id)

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "Important: Refund policy changes effective immediately"
      expect(mail.body.encoded).to include "Hey #{seller.name_or_username},"
    end
  end

  describe "ping_endpoint_failure" do
    let(:seller) { create(:user, email: "seller@example.com") }
    let(:ping_url) { "https://example.com/webhook" }
    let(:response_code) { 500 }

    it "sends notification to the seller about failed ping endpoint" do
      mail = ContactingCreatorMailer.ping_endpoint_failure(seller.id, ping_url, response_code)

      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq "Webhook ping endpoint delivery failed"
      expect(mail.body.encoded).to include "https://example.com/****ook"
      expect(mail.body.encoded).to include response_code.to_s
      expect(mail.from).to eq([ApplicationMailer::SUPPORT_EMAIL])
    end

    it "includes seller information in the email" do
      mail = ContactingCreatorMailer.ping_endpoint_failure(seller.id, ping_url, response_code)

      expect(mail.body.encoded).to include seller.name_or_username
    end

    it "handles different response codes correctly" do
      [404, 500, 502, 503, 504].each do |code|
        mail = ContactingCreatorMailer.ping_endpoint_failure(seller.id, ping_url, code)

        expect(mail.body.encoded).to include code.to_s
        expect(mail.subject).to eq "Webhook ping endpoint delivery failed"
      end
    end

    it "handles different ping URLs correctly with redaction" do
      test_cases = [
        { url: "https://api.example.com/webhook", expected: "https://api.example.com/****ook" },
        { url: "http://localhost:3000/gumroad", expected: "http://localhost:3000/****oad" },
        { url: "https://mystore.com/notifications", expected: "https://mystore.com/*********ions" },
        { url: "https://example.com/a/b/c/webhook?token=secret", expected: "https://example.com/**********************cret" },
        { url: "https://example.com/short", expected: "https://example.com/****t" },
        { url: "https://example.com/a", expected: "https://example.com/*" },
        { url: "https://example.com/ab", expected: "https://example.com/**" },
        { url: "https://example.com/abc", expected: "https://example.com/***" },
        { url: "https://example.com/abcd", expected: "https://example.com/****" },
        { url: "https://example.com/abcde", expected: "https://example.com/****e" }
      ]

      test_cases.each do |test_case|
        mail = ContactingCreatorMailer.ping_endpoint_failure(seller.id, test_case[:url], response_code)

        expect(mail.body.encoded).to include test_case[:expected]
        expect(mail.body.encoded).not_to include test_case[:url] unless test_case[:url] == test_case[:expected]
      end
    end

    it "redacts URL path while preserving protocol and domain" do
      long_url = "https://api.example.com/v1/webhooks/12345/notifications?auth=secret123"
      mail = ContactingCreatorMailer.ping_endpoint_failure(seller.id, long_url, response_code)

      expect(mail.body.encoded).to include "https://api.example.com/******************************************t123"
      expect(mail.body.encoded).not_to include "secret123"
      expect(mail.body.encoded).not_to include "webhooks"
    end
  end

  describe "#flagged_for_explicit_nsfw_tos_violation" do
    let(:seller) { create(:named_seller) }

    it "has the correct subject and body" do
      travel_to(Date.parse("2024-03-28")) do
        mail = ContactingCreatorMailer.flagged_for_explicit_nsfw_tos_violation(seller.id)

        expect(mail.to).to eq([seller.email])
        expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
        expect(mail.subject).to eq("Your account has been temporarily suspended for selling sexually explicit / fetish-related content")

        expect(mail.body.encoded).to include("Hey,")
        expect(mail.body.encoded).to include("We want to first thank you for choosing Gumroad. We're really excited to help you get paid for your work and grow your business.")
        expect(mail.body.encoded).to include("However, due to more stringent banking regulations, we can no longer allow sexually explicit or fetish-oriented materials to be sold on Gumroad, and it looks like at least one of your products could be considered in violation of these rules.")
        expect(mail.body.encoded).to include("As a result, we've temporarily paused sales of the affected products and payouts for your account.")
        expect(mail.body.encoded).to include("Your account will be permanently suspended in 10 days, on 7 April, if your storefront is not updated to be compliant by then.")
        expect(mail.body.encoded).to include("Of course, we will pay you out your remaining balance. Your existing customers' purchases will not be affected by this.")
        expect(mail.body.encoded).to include("We're super sorry about the inconvenience!")
        expect(mail.body.encoded).to include("Sahil and the Gumroad team")
      end
    end
  end
end
