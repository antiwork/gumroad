# frozen_string_literal: true

require "spec_helper"
require "inertia_rails/rspec"

describe Purchases::InvoicesController, :vcr, type: :controller, inertia: true do
  context "within consumer area" do
    describe "GET new" do
      let(:date) { Time.find_zone("UTC").local(2024, 04, 10) }
      let(:seller) { create(:named_seller) }
      let(:product_one) { create(:product, user: seller, name: "Product One") }
      let(:purchase_one) { create(:purchase, created_at: date, link: product_one) }
      let(:purchase) { purchase_one }
      let(:params) { { purchase_id: purchase.external_id, email: purchase.email } }

      describe "for Purchase" do
        it "renders inertia page and adds X-Robots-Tag response header to avoid page indexing" do
          invoice_presenter = InvoicePresenter.new(purchase)
          get :new, params: params

          expect(response).to be_successful
          expect(response.headers["X-Robots-Tag"]).to eq("noindex")
          expect(inertia.component).to eq("Purchases/Invoices/New")
          expect(assigns(:_new_invoice_presenter).send(:chargeable)).to eq(purchase)
          expect(inertia.props[:form_data]).to eq(invoice_presenter.invoice_generation_form_data_props)
          expect(inertia.props[:form_metadata]).to eq(invoice_presenter.invoice_generation_form_metadata_props)
          expect(controller.send(:page_title)).to eq("Generate invoice")
        end
      end

      describe "for Charge" do
        let(:product_two) { create(:product, user: seller, name: "Product Two") }
        let(:purchase_two) { create(:purchase, created_at: date, link: product_two) }
        let(:charge) { create(:charge, seller:, purchases: [purchase_one, purchase_two]) }
        let(:order) { charge.order }

        before do
          order.purchases << [purchase_one, purchase_two]
          order.update!(created_at: date)
        end

        it "assigns the charge as the chargeable for the presenter" do
          get :new, params: params
          expect(assigns(:_new_invoice_presenter).send(:chargeable)).to eq(charge)
        end

        context "when the second purchase is used as a param" do
          let(:purchase) { purchase_two }

          it "assigns the charge as the chargeable for the presenter" do
            get :new, params: params
            expect(assigns(:_new_invoice_presenter).send(:chargeable)).to eq(charge)
          end
        end

        context "when the email does not match with purchase's email" do
          context "when the email is not present in params" do
            it "redirects to email confirmation path" do
              get :new, params: { purchase_id: purchase.external_id }

              expect(response).to redirect_to(confirm_purchase_invoice_path(purchase.external_id))
              expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
            end
          end

          context "when the email is present in params" do
            it "redirects to email confirmation path" do
              get :new, params: { purchase_id: purchase.external_id, email: "wrong-email@example.com" }

              expect(response).to redirect_to(confirm_purchase_invoice_path(purchase.external_id))
              expect(flash[:alert]).to eq("Incorrect email address. Please try again.")
            end
          end
        end
      end
    end

    describe "POST create" do
      render_views

      let(:date) { Time.find_zone("UTC").local(2024, 04, 10) }
      let(:seller) { create(:named_seller) }
      let(:product_one) { create(:product, user: seller, name: "Product One") }
      let(:purchase_one) { create(:purchase, created_at: date, link: product_one) }
      let(:purchase) { purchase_one }
      let(:payload) do
        {
          purchase_id: purchase.external_id,
          email: purchase.email,
          address_fields: {
            full_name: "Sri Raghavan",
            street_address: "367 Hermann St",
            city: "San Francisco",
            state: "CA",
            zip_code: "94103",
            country_code: "US"
          }
        }
      end

      before :each do
        @s3_obj_public_url = "#{AWS_S3_ENDPOINT}/#{S3_BUCKET}/attachment/manual.pdf"

        s3_obj_double = double
        allow(s3_obj_double).to receive(:presigned_url).and_return(@s3_obj_public_url)

        allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf) do |purchase, pdf|
          @generated_pdf = pdf
          s3_obj_double
        end
      end

      describe "for Purchase" do
        it "assigns the purchase as the chargeable" do
          post :create, params: payload
          expect(assigns(:chargeable)).to eq(purchase)
        end

        describe "when user is issuing an invoice" do
          it "redirects to invoice page with success notice" do
            post :create, params: payload

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)

            request.headers["X-Inertia"] = "true"
            request.headers["X-Inertia-Partial-Component"] = "Purchases/Invoices/New"
            request.headers["X-Inertia-Partial-Data"] = "invoice_file_url"
            get :new, params: { purchase_id: purchase.external_id, email: purchase.email }

            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(inertia.props["invoice_file_url"]).to eq(@s3_obj_public_url)
            expect(session["invoice_file_url_#{purchase.external_id}"]).to be_nil
          end

          it "redirects with error alert if the process fails" do
            allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_raise("error")

            post :create, params: payload

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(flash[:alert]).to eq("Sorry, something went wrong.")
          end

          it "raises routing error if purchase doesn't exist" do
            expect do
              post :create, params: payload.merge!(purchase_id: "invalid")
            end.to raise_error(ActionController::RoutingError)
          end

          it "generates a PDF invoice with the purchase and payload details" do
            post :create, params: payload

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("United States")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end

          it "generates a PDF invoice with the purchase and payload details for non-US country" do
            post :create, params: payload.deep_merge(address_fields: { country_code: "JP" })

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Japan")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end

          it "generates a PDF invoice with the purchase and payload details for direct sales to AU customers" do
            allow_any_instance_of(Link).to receive(:is_physical?).and_return(true)
            allow_any_instance_of(Purchase).to receive(:country).and_return("Australia")

            post :create, params: payload.deep_merge(address_fields: { country_code: "AU" })

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include(purchase.seller.display_name)
            expect(pdf_text).to include(purchase.seller.email)
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("Australia")
            expect(pdf_text).to include(purchase.email)
            expect(pdf_text).to include(purchase.link.name)
            expect(pdf_text).to include(purchase.formatted_non_refunded_total_transaction_amount)
            expect(pdf_text).to include(purchase.quantity.to_s)
            expect(pdf_text).not_to include("Additional notes")
          end
        end

        context "when user provides additional notes" do
          it "includes additional notes in the invoice" do
            post :create, params: payload.merge(additional_notes: "Very important custom information.")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Additional notes")
            expect(pdf_text).to include("Very important custom information.")
          end
        end

        describe "when user provides a vat id" do
          before do
            @zip_tax_rate = create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false)
            @purchase = create(:purchase_in_progress, zip_tax_rate: @zip_tax_rate, chargeable: create(:chargeable))
            @purchase.process!
            @purchase.mark_successful!
            @purchase.gumroad_tax_cents = 20
            @purchase.save!
          end

          it "refunds tax" do
            post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. VAT has also been refunded.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax when provided an invalid vat id" do
            post :create, params: payload.merge(vat_id: "EU123456789", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid ABN id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "51824753556", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. GST has also been refunded.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid ABN id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "11111111111", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid GST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "T9100001B", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. GST has also been refunded.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid GST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "T9100001C", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "refunds tax for a valid QST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::CAN.alpha2, state_code: QUEBEC)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "1002092821TQ0001", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. QST has also been refunded.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last.total_transaction_cents).to be(20)
          end

          it "does not refund tax for an invalid QST id" do
            purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::CAN.alpha2, state_code: QUEBEC)
            @purchase.update!(purchase_sales_tax_info:)

            post :create, params: payload.merge(vat_id: "NR00005576", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last).to eq nil
          end

          it "does not refund tax but still send receipt if already refunded" do
            @purchase.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
            expect(Refund.count).to be(1)

            post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: @purchase.external_id, email: @purchase.email)

            expect(response).to redirect_to(new_purchase_invoice_path(@purchase.external_id, email: @purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. VAT has also been refunded.")
            expect(session["invoice_file_url_#{@purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.count).to be(1)
          end
        end

        context "when the email param is not set" do
          it "redirects to the email confirmation path" do
            post :create, params: payload.except(:email)

            expect(response).to redirect_to(confirm_purchase_invoice_path(purchase.external_id))
            expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
          end
        end
      end

      describe "for Charge" do
        let(:product_two) { create(:product, user: seller, name: "Product Two") }
        let(:purchase_two) { create(:purchase, created_at: date, link: product_two) }
        let(:charge) { create(:charge, seller:, purchases: [purchase_one, purchase_two]) }
        let(:order) { charge.order }

        before do
          order.purchases << [purchase_one, purchase_two]
          order.update!(created_at: date)
        end

        it "assigns the charge as the chargeable" do
          post :create, params: payload
          expect(assigns(:chargeable)).to eq(charge)
        end

        context "when the second purchase is used as a param" do
          let(:purchase) { purchase_two }

          it "assigns the charge as the chargeable" do
            post :create, params: payload
            expect(assigns(:chargeable)).to eq(charge)
          end
        end

        describe "when user is issuing an invoice" do
          it "redirects to invoice page with success notice" do
            post :create, params: payload

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)

            request.headers["X-Inertia"] = "true"
            request.headers["X-Inertia-Partial-Component"] = "Purchases/Invoices/New"
            request.headers["X-Inertia-Partial-Data"] = "invoice_file_url"
            get :new, params: { purchase_id: purchase.external_id, email: purchase.email }

            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(inertia.props["invoice_file_url"]).to eq(@s3_obj_public_url)
            expect(session["invoice_file_url_#{purchase.external_id}"]).to be_nil
          end

          it "redirects with error alert if the process fails" do
            allow_any_instance_of(Purchase).to receive(:upload_invoice_pdf).and_raise("error")

            post :create, params: payload

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(flash[:alert]).to eq("Sorry, something went wrong.")
          end

          it "raises routing error if purchase doesn't exist" do
            expect do
              post :create, params: payload.merge!(purchase_id: "invalid")
            end.to raise_error(ActionController::RoutingError)
          end

          it "generates a PDF invoice with the charge and payload details" do
            post :create, params: payload

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Apr 10, 2024")
            expect(pdf_text).to include(purchase.external_id_numeric.to_s)
            expect(pdf_text).to include("Sri Raghavan")
            expect(pdf_text).to include("367 Hermann St")
            expect(pdf_text).to include("San Francisco")
            expect(pdf_text).to include("CA")
            expect(pdf_text).to include("94103")
            expect(pdf_text).to include("United States")
            expect(pdf_text).to include(charge.order.email)
            expect(pdf_text).to match(/Product One.*\$1/)
            expect(pdf_text).to include("Product Two $1")
            expect(pdf_text).to include("Payment Total $2")
            expect(pdf_text).not_to include("Additional notes")
          end
        end

        context "when user provides additional notes" do
          it "includes additional notes in the invoice" do
            post :create, params: payload.merge(additional_notes: "Very important custom information.")

            reader = PDF::Reader.new(StringIO.new(@generated_pdf))
            expect(reader.pages.size).to be(1)

            pdf_text = reader.page(1).text.squish
            expect(pdf_text).to include("Additional notes")
            expect(pdf_text).to include("Very important custom information.")
          end
        end

        describe "when user provides a vat id" do
          let(:zip_tax_rate) { create(:zip_tax_rate, combined_rate: 0.20, is_seller_responsible: false) }
          let(:purchase_one) do
            purchase = create(:purchase_in_progress, zip_tax_rate: zip_tax_rate, chargeable: create(:chargeable), link: product_one)
            purchase.process!
            purchase.mark_successful!
            purchase.update!(gumroad_tax_cents: 20, was_purchase_taxable: true)
            purchase
          end
          let(:purchase_two) do
            purchase = create(:purchase_in_progress, zip_tax_rate: zip_tax_rate, chargeable: create(:chargeable), link: product_two)
            purchase.process!
            purchase.mark_successful!
            purchase.update!(gumroad_tax_cents: 20, was_purchase_taxable: true)
            purchase
          end

          it "refunds tax" do
            expect(Refund.count).to be(0)
            expect do
              post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: purchase.external_id)
            end.to change(Refund, :count).by(2)

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically. VAT has also been refunded.")
            expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
            expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
          end

          it "does not refund tax when provided an invalid vat id" do
            expect do
              post :create, params: payload.merge(vat_id: "EU123456789", purchase_id: purchase.external_id)
            end.to_not change(Refund, :count)

            expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
            expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
            expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
          end

          context "with a valid ABN id" do
            before do
              purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::AUS.alpha2)
              purchase.update!(purchase_sales_tax_info:)
              purchase_two.update!(purchase_sales_tax_info:)
            end

            it "refunds tax" do
              expect do
                post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: purchase.external_id)
              end.to change(Refund, :count).by(2)

              expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
              expect(flash[:notice]).to include("The invoice will be downloaded automatically.")
              expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
              expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
            end

            context "with an invalid ABN id" do
              it "does not refund tax" do
                expect do
                  post :create, params: payload.merge(vat_id: "11111111111", purchase_id: purchase.external_id)
                end.to_not change(Refund, :count)

                expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
                expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
                expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
              end
            end
          end

          context "with a valid GST id" do
            before do
              purchase_sales_tax_info = PurchaseSalesTaxInfo.new(country_code: Compliance::Countries::SGP.alpha2)
              purchase.update!(purchase_sales_tax_info:, was_purchase_taxable: true)
            end

            it "refunds tax" do
              expect do
                post :create, params: payload.merge(vat_id: "T9100001B", purchase_id: purchase.external_id)
              end.to change(Refund, :count).by(2)

              expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
              expect(flash[:notice]).to eq("The invoice will be downloaded automatically. GST has also been refunded.")
              expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
              expect(Refund.last(2).sum(&:total_transaction_cents)).to be(40)
            end

            context "with an invalid GST id" do
              it "does not refund tax" do
                expect do
                  post :create, params: payload.merge(vat_id: "T9100001C", purchase_id: purchase.external_id)
                end.to_not change(Refund, :count)

                expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
                expect(flash[:notice]).to eq("The invoice will be downloaded automatically.")
                expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
              end
            end
          end

          context "when already refunded" do
            before do
              purchase.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
              purchase_two.refund_gumroad_taxes!(refunding_user_id: nil, note: "note")
            end

            it "does not refund tax" do
              expect(Refund.count).to be(2)
              expect do
                post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: purchase.external_id)
              end.to_not change(Refund, :count)

              expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
              expect(flash[:notice]).to eq("The invoice will be downloaded automatically. VAT has also been refunded.")
              expect(session["invoice_file_url_#{purchase.external_id}"]).to eq(@s3_obj_public_url)
            end
          end

          context "when purchase is not successful" do
            before do
              purchase.update_attribute(:purchase_state, "in_progress")
              purchase_two.update_attribute(:purchase_state, "in_progress")
            end

            it "returns error if purchase is not successful" do
              post :create, params: payload.merge(vat_id: "IE6388047V", purchase_id: purchase.external_id)

              expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
              expect(flash[:alert]).to eq("Your purchase has not been completed by PayPal yet. Please try again soon.")
              expect(Refund.count).to be(0)
            end
          end
        end
      end
    end

    describe "GET confirm" do
      let(:purchase) { create(:purchase) }

      it "returns success" do
        get :confirm, params: { purchase_id: purchase.external_id }

        expect(response).to be_successful
        expect(inertia.component).to eq("Purchases/Invoices/Confirm")
      end
    end

    describe "POST confirm_email" do
      let(:purchase) { create(:purchase) }

      it "redirects to invoice page with correct email" do
        post :confirm_email, params: { purchase_id: purchase.external_id, email: purchase.email }

        expect(response).to redirect_to(new_purchase_invoice_path(purchase.external_id, email: purchase.email))
      end

      it "redirects back with error for incorrect email" do
        post :confirm_email, params: { purchase_id: purchase.external_id, email: "wrong@example.com" }

        expect(response).to redirect_to(confirm_purchase_invoice_path(purchase.external_id))
        expect(flash[:alert]).to eq("Incorrect email address. Please try again.")
      end

      it "redirects back with warning when email is missing" do
        post :confirm_email, params: { purchase_id: purchase.external_id }

        expect(response).to redirect_to(confirm_purchase_invoice_path(purchase.external_id))
        expect(flash[:warning]).to eq("Please enter the purchase's email address to generate the invoice.")
      end
    end
  end
end
