# frozen_string_literal: true

describe Checkout::FormPresenter do
  describe "#form_props" do
    let(:seller) { create(:named_seller) }
    let(:user) { create(:user) }
    let(:presenter) { described_class.new(pundit_user: SellerContext.new(user:, seller:)) }

    before do
      create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
    end

    it "returns the correct props" do
      expect(presenter.form_props)
        .to eq(
          {
            pages: ["discounts", "form", "upsells"],
            user: {
              display_offer_code_field: false,
              recommendation_type: User::RecommendationType::OWN_PRODUCTS,
              tipping_enabled: false,
              ach_payments_enabled: false,
              gifting_disabled: false,
            },
            cart_item: nil,
            card_product: nil,
            custom_fields: [],
            products: [],
            paypal_connect: {
              show_paypal_connect: false,
              allow_paypal_connect: true,
              unsupported_countries: PaypalMerchantAccountManager::COUNTRY_CODES_NOT_SUPPORTED_BY_PCP.map { |code| ISO3166::Country[code].common_name },
              email: nil,
              charge_processor_merchant_id: nil,
              charge_processor_verified: false,
              needs_email_confirmation: false,
              paypal_disconnect_allowed: true,
            },
            connect_account_fee_info_text: "All sales will incur fees based on how customers find your product:\n\n• Direct sales: 10% + 50¢\n• Discover sales: 30% flat\n",
          }
        )
    end

    context "when tipping is enabled for the user" do
      before do
        seller.update!(tipping_enabled: true)
      end

      it "returns true for tipping_enabled" do
        expect(presenter.form_props[:user][:tipping_enabled]).to eq(true)
      end
    end

    context "when the seller has opted into ACH payments" do
      before do
        seller.update!(ach_payments_enabled: true)
      end

      it "returns true for ach_payments_enabled" do
        expect(presenter.form_props[:user][:ach_payments_enabled]).to eq(true)
      end
    end

    context "when the seller has disabled gifting" do
      before do
        seller.update!(gifting_disabled: true)
      end

      it "returns true for gifting_disabled" do
        expect(presenter.form_props[:user][:gifting_disabled]).to eq(true)
      end
    end

    context "when the seller has the offer code field enabled" do
      before do
        seller.update!(display_offer_code_field: true)
      end

      it "returns the correct props" do
        expect(presenter.form_props[:user][:display_offer_code_field]).to eq(true)
      end
    end

    context "when the seller has an alive product" do
      let!(:product) { create(:product, user: seller) }

      it "includes it as a cart item, card product, and in the list of products" do
        props = presenter.form_props
        expect(props[:cart_item]).to eq(CheckoutPresenter.new(logged_in_user: nil, ip: nil).checkout_product(product, product.cart_item({}), {}).merge({ quantity: 1, url_parameters: {}, referrer: "" }))
        expect(props[:card_product]).to eq(ProductPresenter.card_for_web(product:))
        expect(props[:products]).to eq [{ id: product.external_id, name: product.name, archived: false }]
      end
    end

    context "when the seller has custom fields" do
      it "returns the correct props" do
        product = create(:product)
        field = create(:custom_field, seller:, products: [product])
        other_product = create(:product, user: seller, json_data: { custom_fields: [{ type: "text", name: "Field", required: true }] })
        other_field = create(:custom_field, seller:, products: [other_product])
        create(:custom_field, seller:, is_post_purchase: true)
        expect(presenter.form_props[:custom_fields]).to eq [
          { id: field.external_id, name: field.name, global: false, required: false, collect_per_product: false, type: field.type, products: [product.external_id] },
          { id: other_field.external_id, name: other_field.name, global: false, required: false, collect_per_product: false, type: other_field.type, products: [other_product.external_id] }
        ]
      end
    end

    describe "paypal_connect props" do
      let(:owner_presenter) { described_class.new(pundit_user: SellerContext.new(user: seller, seller:)) }

      context "when the seller is in a supported country and the user is the owner" do
        before do
          create(:user_compliance_info, user: seller)
        end

        it "shows the PayPal Connect section" do
          expect(owner_presenter.form_props[:paypal_connect][:show_paypal_connect]).to eq(true)
        end

        it "shows the PayPal Connect section to team members with the admin role" do
          # Team admins can manage payout settings (see #6067), which includes
          # connecting PayPal on the seller's behalf.
          expect(presenter.form_props[:paypal_connect][:show_paypal_connect]).to eq(true)
        end

        it "does not show the PayPal Connect section to team members without the admin role" do
          marketing_user = create(:user)
          create(:team_membership, user: marketing_user, seller:, role: TeamMembership::ROLE_MARKETING)
          marketing_presenter = described_class.new(pundit_user: SellerContext.new(user: marketing_user, seller:))

          expect(marketing_presenter.form_props[:paypal_connect][:show_paypal_connect]).to eq(false)
        end

        it "allows connecting only when the seller has payout information set up" do
          seller.update!(payment_address: "")
          expect(owner_presenter.form_props[:paypal_connect][:allow_paypal_connect]).to eq(false)

          seller.update!(payment_address: "seller-payouts@example.com")

          expect(described_class.new(pundit_user: SellerContext.new(user: seller, seller: seller.reload)).form_props[:paypal_connect][:allow_paypal_connect]).to eq(true)
        end
      end

      context "when the seller is in an unsupported country" do
        before do
          create(:user_compliance_info, user: seller, country: "India")
        end

        it "does not show the PayPal Connect section" do
          expect(owner_presenter.form_props[:paypal_connect][:show_paypal_connect]).to eq(false)
        end
      end

      context "when the seller has a connected PayPal merchant account" do
        before do
          create(:user_compliance_info, user: seller)
          seller.mark_compliant!(author_name: "ContentModeration")
          @paypal_connect_account = create(:merchant_account_paypal, user: seller, charge_processor_merchant_id: "B66YJBBNCRW6L", charge_processor_verified_at: Time.current)
          allow_any_instance_of(PaypalIntegrationRestApi).to receive(:get_merchant_account_by_merchant_id).and_return(double(parsed_response: { "primary_email" => "seller-paypal@example.com" }))
          allow(PaypalPartnerRestCredentials).to receive(:new).and_return(double(auth_token: "token"))
        end

        it "returns the merchant account details" do
          props = owner_presenter.form_props[:paypal_connect]
          expect(props[:charge_processor_merchant_id]).to eq(@paypal_connect_account.charge_processor_merchant_id)
          expect(props[:charge_processor_verified]).to eq(true)
          expect(props[:email]).to eq("seller-paypal@example.com")
        end

        it "does not call the PayPal API when the section is not shown" do
          expect(PaypalIntegrationRestApi).not_to receive(:new)

          marketing_user = create(:user)
          create(:team_membership, user: marketing_user, seller:, role: TeamMembership::ROLE_MARKETING)
          marketing_presenter = described_class.new(pundit_user: SellerContext.new(user: marketing_user, seller:))

          props = marketing_presenter.form_props[:paypal_connect]
          expect(props[:show_paypal_connect]).to eq(false)
          expect(props[:email]).to be_nil
        end

        context "when the PayPal API raises" do
          before do
            allow_any_instance_of(PaypalIntegrationRestApi).to receive(:get_merchant_account_by_merchant_id).and_raise(StandardError, "PayPal is down")
          end

          it "omits the email and still renders the rest of the props" do
            expect(ErrorNotifier).to receive(:notify).with(instance_of(StandardError))

            props = owner_presenter.form_props[:paypal_connect]
            expect(props[:email]).to be_nil
            expect(props[:show_paypal_connect]).to eq(true)
            expect(props[:charge_processor_merchant_id]).to eq(@paypal_connect_account.charge_processor_merchant_id)
          end
        end

        context "when the PayPal API returns an unusable response" do
          before do
            allow_any_instance_of(PaypalIntegrationRestApi).to receive(:get_merchant_account_by_merchant_id).and_return(double(parsed_response: nil))
          end

          it "omits the email without raising" do
            props = owner_presenter.form_props[:paypal_connect]
            expect(props[:email]).to be_nil
            expect(props[:show_paypal_connect]).to eq(true)
          end
        end
      end
    end
  end
end
