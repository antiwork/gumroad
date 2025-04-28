# frozen_string_literal: true

require "spec_helper"

RSpec.describe ResendEventInfo do
  before do
    Feature.activate(:resend)
    Feature.activate(:force_resend)
  end

  let(:email) { "to@example.com" }
  let(:resend_header_names) { MailerInfo::FIELD_NAMES.map { MailerInfo.header_name(_1) } }
  let(:mailer_headers) do
    mailer.message.header
      .filter_map { |f| f if f.name.in?(resend_header_names) }
      .map { |f| { "name" => f.name, "value" => f.value } }
  end

  def expect_headers_presence(*headers)
    expect(headers.map { MailerInfo.header_name(_1) }.sort).to eq(mailer_headers.map { _1["name"] }.sort)
  end

  describe ".from_event_json" do
    let(:event_json) do
      {
        "created_at" => "2025-01-02T00:14:12.391Z",
        "data" => {
          "created_at" => "2025-01-02 00:14:11.140106+00",
          "email_id" => "7409b6f1-56f1-4ba5-89f0-4364a08b246e",
          "from" => "\"Seller\" <noreply@staging.customers.gumroad.com>",
          "to" => [email],
          "headers" => mailer_headers,
          "subject" => "Test email"
        },
        "type" => "email.delivered"
      }
    end

    RSpec.shared_examples "with different event types" do
      it "handles bounce events" do
        event_json["type"] = "email.bounced"
        event_info = described_class.from_event_json(event_json)
        expect(event_info.type).to eq(:bounced)
      end

      it "handles spam complaint events" do
        event_json["type"] = "email.complained"
        event_info = described_class.from_event_json(event_json)
        expect(event_info.type).to eq(:complained)
      end

      it "handles opened events" do
        event_json["type"] = "email.opened"
        event_info = described_class.from_event_json(event_json)
        expect(event_info.type).to eq(:opened)
      end

      it "handles click events" do
        event_json["type"] = "email.clicked"
        event_json["data"]["click"] = {
          "link" => "https://example.com/product"
        }

        event_info = described_class.from_event_json(event_json)
        expect(event_info.type).to eq(:clicked)
        expect(event_info.click_url).to eq("https://example.com/product")
      end
    end

    context "with receipt email" do
      context "with purchase" do
        let(:purchase) { create(:purchase) }
        let(:mailer) { CustomerMailer.receipt(purchase.id) }

        it "includes purchase id and marks as receipt email" do
          event_info = described_class.from_event_json(event_json)
          expect_headers_presence(
            MailerInfo::FIELD_EMAIL_PROVIDER,
            MailerInfo::FIELD_ENVIRONMENT,
            MailerInfo::FIELD_CATEGORY,
            MailerInfo::FIELD_MAILER_CLASS,
            MailerInfo::FIELD_MAILER_METHOD,
            MailerInfo::FIELD_MAILER_ARGS,
            MailerInfo::FIELD_PURCHASE_ID,
          )
          expect(event_info.purchase_id).to eq(purchase.id.to_s)
          expect(event_info.mailer_class_and_method).to eq("CustomerMailer.receipt")
          expect(event_info.mailer_args).to eq("[#{purchase.id}]")
          expect(event_info).to be_for_receipt_email
          expect(event_info).not_to be_for_abandoned_cart_email
          expect(event_info).not_to be_for_installment_email
        end

        it_behaves_like "with different event types"

        context "with charge" do
          let(:seller) { create(:named_seller) }
          let(:product) { create(:product, user: seller, name: "Product One") }
          let(:purchase_one) { create(:purchase, link: product, seller: seller) }
          let(:product_two) { create(:product, user: seller, name: "Product Two") }
          let(:purchase_two) { create(:purchase, link: product_two, seller: seller) }
          let(:charge) { create(:charge, purchases: [purchase_one, purchase_two], seller: seller) }
          let(:order) { charge.order }

          before do
            charge.order.purchases << purchase_one
            charge.order.purchases << purchase_two
          end

          let(:mailer) { CustomerMailer.receipt(nil, charge.id) }

          it "includes charge id and marks as receipt email" do
            event_info = described_class.from_event_json(event_json)
            expect_headers_presence(
              MailerInfo::FIELD_EMAIL_PROVIDER,
              MailerInfo::FIELD_ENVIRONMENT,
              MailerInfo::FIELD_CATEGORY,
              MailerInfo::FIELD_MAILER_CLASS,
              MailerInfo::FIELD_MAILER_METHOD,
              MailerInfo::FIELD_MAILER_ARGS,
              MailerInfo::FIELD_CHARGE_ID,
            )
            expect(event_info.charge_id).to eq(charge.id.to_s)
            expect(event_info.mailer_class_and_method).to eq("CustomerMailer.receipt")
            expect(event_info.mailer_args).to eq("[nil, #{charge.id}]")
            expect(event_info).to be_for_receipt_email
            expect(event_info).not_to be_for_abandoned_cart_email
            expect(event_info).not_to be_for_installment_email
          end

          it_behaves_like "with different event types"
        end
      end
    end

    context "with preorder receipt email", :vcr do
      let(:preorder) do
        product = create(:product, price_cents: 600, is_in_preorder_state: false)
        preorder_product = create(:preorder_product_with_content, link: product)
        preorder_product.update(release_at: Time.current) # bypassed the creation validation
        authorization_purchase = build(:purchase, link: product, chargeable: build(:chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
        preorder = preorder_product.build_preorder(authorization_purchase)
        preorder.authorize!
        preorder.mark_authorization_successful
        preorder
      end
      let(:mailer) { CustomerMailer.preorder_receipt(preorder.id) }

      it "marks as receipt email" do
        event_info = described_class.from_event_json(event_json)
        expect_headers_presence(
          MailerInfo::FIELD_EMAIL_PROVIDER,
          MailerInfo::FIELD_ENVIRONMENT,
          MailerInfo::FIELD_CATEGORY,
          MailerInfo::FIELD_MAILER_CLASS,
          MailerInfo::FIELD_MAILER_METHOD,
          MailerInfo::FIELD_MAILER_ARGS,
          MailerInfo::FIELD_PURCHASE_ID,
        )
        expect(event_info.purchase_id).to eq(preorder.authorization_purchase.id.to_s)
        expect(event_info.mailer_class_and_method).to eq("CustomerMailer.preorder_receipt")
        expect(event_info.mailer_args).to eq("[#{preorder.id}]")
        expect(event_info).to be_for_receipt_email
        expect(event_info).not_to be_for_abandoned_cart_email
        expect(event_info).not_to be_for_installment_email
      end

      it_behaves_like "with different event types"
    end

    context "with abandoned cart email" do
      let(:cart) { create(:cart, user: nil, email: "guest@example.com") }
      let(:seller) { create(:user, name: "John Doe", username: "johndoe") }
      let!(:seller_workflow) { create(:abandoned_cart_workflow, seller: seller, published_at: 1.day.ago) }
      let!(:seller_products) { create_list(:product, 4, user: seller) { |product, i| product.update!(name: "S1 Product #{i + 1}") } }
      let(:mailer_args) { { seller_workflow.id => [seller.products.first.id] }.stringify_keys }
      let(:mailer) { CustomerMailer.abandoned_cart(cart.id, mailer_args) }
      let!(:cart_product) { create(:cart_product, cart: cart, product: seller.products.first) }

      before do
        cart.update!(updated_at: 2.days.ago)
      end

      it "includes workflow ids and marks as abandoned cart email" do
        event_info = described_class.from_event_json(event_json)
        expect_headers_presence(
          MailerInfo::FIELD_EMAIL_PROVIDER,
          MailerInfo::FIELD_ENVIRONMENT,
          MailerInfo::FIELD_CATEGORY,
          MailerInfo::FIELD_MAILER_CLASS,
          MailerInfo::FIELD_MAILER_METHOD,
          MailerInfo::FIELD_MAILER_ARGS,
          MailerInfo::FIELD_WORKFLOW_IDS,
        )
        expect(event_info.workflow_ids).to eq([seller_workflow.id.to_s])
        expect(event_info.mailer_class_and_method).to eq("CustomerMailer.abandoned_cart")
        expect(event_info.mailer_args).to eq("[#{cart.id}, {\"#{seller_workflow.id}\" => [#{seller.products.first.id}]}]")
        expect(event_info).to be_for_abandoned_cart_email
        expect(event_info).not_to be_for_receipt_email
        expect(event_info).not_to be_for_installment_email
      end

      it_behaves_like "with different event types"
    end
  end
end
