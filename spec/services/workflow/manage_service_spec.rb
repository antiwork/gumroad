# frozen_string_literal: true

require "spec_helper"

describe Workflow::ManageService do
  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    # create(:payment_completed, user: seller)
  end

  describe "#process" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }

    context "when workflow does not exist" do
      let(:params) { { name: "My workflow", permalink: product.unique_permalink, workflow_type: Workflow::PRODUCT_TYPE, send_to_past_customers: false } }

      it "creates a product workflow" do
        params[:send_to_past_customers] = true

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.name).to eq("My workflow")
        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.link).to eq(product)
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.published_at).to be_nil
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.send_to_past_customers).to be(true)
      end

      it "creates a variant workflow" do
        variant_category = create(:variant_category, link: product)
        variant = create(:variant, variant_category:)
        params[:workflow_type] = Workflow::VARIANT_TYPE
        params[:variant_external_id] = variant.external_id

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.name).to eq("My workflow")
        expect(workflow.workflow_type).to eq(Workflow::VARIANT_TYPE)
        expect(workflow.link).to eq(product)
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to eq(variant)
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.send_to_past_customers).to be(false)
      end

      it "creates a seller workflow" do
        params[:workflow_type] = Workflow::SELLER_TYPE

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::SELLER_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
      end

      it "creates an audience workflow" do
        params[:workflow_type] = Workflow::AUDIENCE_TYPE

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::AUDIENCE_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
      end

      it "creates a follower workflow" do
        params[:workflow_type] = Workflow::FOLLOWER_TYPE

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::FOLLOWER_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
      end

      it "creates an affiliate workflow" do
        params[:workflow_type] = Workflow::AFFILIATE_TYPE
        params[:affiliate_products] = [product.unique_permalink]

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::AFFILIATE_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.affiliate_products).to eq([product.unique_permalink])
      end

      it "creates a workflow with 'member_cancellation' trigger" do
        params[:workflow_trigger] = Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.link).to eq(product)
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to eq(Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER)
      end

      it "creates a workflow with the new customer trigger when 'workflow_type' is 'audience'" do
        params[:workflow_type] = Workflow::AUDIENCE_TYPE
        params[:workflow_trigger] = Workflow::MEMBER_CANCELLATION_WORKFLOW_TRIGGER

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::AUDIENCE_TYPE)
        expect(workflow.workflow_trigger).to be_nil
      end

      it "creates an abandoned cart workflow with a ready-made installment" do
        create(:payment_completed, user: seller)
        params.merge!(
            workflow_type: Workflow::ABANDONED_CART_TYPE,
            bought_products: ["F"],
          )

        expect do
          expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
        end.to change { Workflow.count }.from(0).to(1)
           .and change { Installment.count }.from(0).to(1)

        workflow = Workflow.last
        expect(workflow.workflow_type).to eq(Workflow::ABANDONED_CART_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.seller_id).to eq(seller.id)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.bought_products).to eq(["F"])
        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.installments.count).to eq(1)
        installment = workflow.installments.alive.sole
        expect(installment.name).to eq("You left something in your cart")
        expect(installment.message).to eq(%Q(<p>When you're ready to buy, <a href="#{Rails.application.routes.url_helpers.checkout_index_url(host: UrlService.domain_with_protocol)}" target="_blank" rel="noopener noreferrer nofollow">complete checking out</a>.</p><product-list-placeholder />))
        expect(installment.installment_type).to eq(Installment::ABANDONED_CART_TYPE)
        expect(installment.json_data).to eq(workflow.json_data)
        expect(installment.seller_id).to eq(workflow.seller_id)
        expect(installment.send_emails).to be(true)
        expect(installment.installment_rule.time_period).to eq(InstallmentRule::HOUR)
        expect(installment.installment_rule.delayed_delivery_time).to eq(24.hours)
      end

      it "returns error if seller is not eligible for abandoned cart workflows" do
        params[:workflow_type] = Workflow::ABANDONED_CART_TYPE

        expect do
          service = described_class.new(seller:, params:, product:, workflow: nil)
          expect(service.process).to eq([false, "You must have at least one completed payout to create an abandoned cart workflow"])
        end.not_to change { Workflow.count }
      end

      describe "filters" do
        before do
          params.merge!(
            bought_products: ["F"],
            paid_more_than: "",
            paid_less_than: "10",
            created_after: "2019-01-01",
            created_before: "2020-12-31",
            bought_from: "United States",
          )
        end

        it "creates a workflow with filters" do
          expect do
            expect(described_class.new(seller:, params:, product:, workflow: nil).process).to eq([true, nil])
          end.to change { Workflow.count }.from(0).to(1)

          workflow = Workflow.last
          expect(workflow.bought_products).to eq(["F"])
          expect(workflow.not_bought_products).to be_nil
          expect(workflow.bought_variants).to be_nil
          expect(workflow.not_bought_variants).to be_nil
          expect(workflow.paid_more_than_cents).to be_nil
          expect(workflow.paid_less_than_cents).to eq(1000)
          expect(workflow.affiliate_products).to be_nil
          expect(workflow.workflow_trigger).to be_nil
          timezone = ActiveSupport::TimeZone[seller.timezone]
          expect(workflow.created_after).to eq(timezone.parse("2019-01-01").as_json)
          expect(workflow.created_before).to eq(timezone.parse("2020-12-31").end_of_day.as_json)
          expect(workflow.bought_from).to eq("United States")
        end

        it "returns false if the paid filters are invalid" do
          params[:paid_more_than] = "10"
          params[:paid_less_than] = "5"

          expect do
            service = described_class.new(seller:, params:, product:, workflow: nil)
            expect(service.process).to eq([false, "Please enter valid paid more than and paid less than values."])
          end.not_to change { Workflow.count }
        end

        it "returns false if the date filters are invalid" do
          params[:created_after] = "2020-12-31"
          params[:created_before] = "2019-01-01"

          expect do
            service = described_class.new(seller:, params:, product:, workflow: nil)
            expect(service.process).to eq([false, "Please enter valid before and after dates."])
          end.not_to change { Workflow.count }
        end
      end
    end

    context "when workflow already exists" do
      let!(:workflow) { create(:workflow, seller:, link: product, workflow_type: Workflow::PRODUCT_TYPE) }
      let!(:installment1) { create(:workflow_installment, workflow:, name: "Installment 1") }
      let!(:installment2) { create(:workflow_installment, workflow:, name: "Installment 3", installment_type: Installment::PRODUCT_TYPE, deleted_at: 2.days.ago) }
      let(:params) { { name: "Updated workflow name", permalink: product.unique_permalink, workflow_type: Workflow::AFFILIATE_TYPE, affiliate_products: [product.unique_permalink], send_to_past_customers: false } }

      it "updates the workflow and its installments" do
        expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

        expect do
          expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
        end.to change { Workflow.count }.by(0)
           .and change { workflow.reload.name }.from(workflow.name).to("Updated workflow name")
           .and change { workflow.workflow_type }.from(Workflow::PRODUCT_TYPE).to(Workflow::AFFILIATE_TYPE)
            .and change { workflow.affiliate_products }.from(nil).to([product.unique_permalink])

        expect(workflow.link).to be_nil
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.published_at).to be_nil

        expect(installment1.reload.installment_type).to eq(Installment::AFFILIATE_TYPE)
        expect(installment1.json_data).to eq(workflow.json_data)
        expect(installment1.seller_id).to eq(workflow.seller_id)
        expect(installment1.link_id).to eq(workflow.link_id)
        expect(installment1.base_variant_id).to eq(workflow.base_variant_id)
        expect(installment1.is_for_new_customers_of_workflow).to eq(!workflow.send_to_past_customers)

        # Deleted installments are not touched
        expect(installment2.reload.installment_type).to eq(Installment::PRODUCT_TYPE)
      end

      it "updates the workflow name but ignores all other params if the workflow was previously published" do
        workflow.update!(first_published_at: 10.days.ago)
        params[:send_to_past_customers] = true

        expect do
          expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
        end.to change { Workflow.count }.by(0)
           .and change { workflow.reload.name }.from(workflow.name).to("Updated workflow name")

        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.link).to eq(product)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.send_to_past_customers).to be(false)
        expect(workflow.affiliate_products).to be_nil
      end

      context "when changing the workflow type to 'abandoned_cart'" do
        it "updates the workflow, deletes all existing installments and creates a ready-made abandoned cart installment" do
          params[:workflow_type] = Workflow::ABANDONED_CART_TYPE

          expect do
            expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
          end.to change { Workflow.count }.by(0)
             .and change { workflow.reload.workflow_type }.from(Workflow::PRODUCT_TYPE).to(Workflow::ABANDONED_CART_TYPE)
              .and change { workflow.installments.deleted.count }.by(1)

          expect(workflow.link).to be_nil
          expect(workflow.installments.alive.count).to eq(1)
          expect(installment1.reload).to be_deleted
          installment = workflow.installments.alive.sole
          expect(installment.name).to eq("You left something in your cart")
          expect(installment.message).to eq(%Q(<p>When you're ready to buy, <a href="#{Rails.application.routes.url_helpers.checkout_index_url(host: UrlService.domain_with_protocol)}" target="_blank" rel="noopener noreferrer nofollow">complete checking out</a>.</p><product-list-placeholder />))
          expect(installment.installment_type).to eq(Installment::ABANDONED_CART_TYPE)
          expect(installment.json_data).to eq(workflow.json_data)
          expect(installment.seller_id).to eq(workflow.seller_id)
          expect(installment.send_emails).to be(true)
        end
      end

      context "when changing the workflow type from 'abandoned_cart' to another type" do
        it "updates the workflow and deletes the abandoned cart installment" do
          workflow.update!(workflow_type: Workflow::ABANDONED_CART_TYPE)
          workflow.installments.alive.find_each(&:mark_deleted!)
          abandoned_cart_installment = create(:workflow_installment, workflow:, installment_type: Installment::ABANDONED_CART_TYPE)
          params[:workflow_type] = Workflow::PRODUCT_TYPE

          expect do
            expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
          end.to change { Workflow.count }.by(0)
             .and change { workflow.reload.workflow_type }.from(Workflow::ABANDONED_CART_TYPE).to(Workflow::PRODUCT_TYPE)
             .and change { workflow.installments.deleted.count }.by(1)

          expect(workflow.link).to eq(product)
          expect(workflow.installments.alive).to be_empty
          expect(abandoned_cart_installment.reload).to be_deleted
        end
      end

      it "updates the workflow filters" do
        workflow.update!(paid_more_than_cents: 50, bought_products: ["abc"], created_before: ActiveSupport::TimeZone[seller.timezone].parse("2025-05-10").end_of_day)

        params.merge!(
          workflow_type: Workflow::SELLER_TYPE,
          bought_products: ["F"],
          paid_more_than: "",
          paid_less_than: "10",
          created_after: "2019-01-01",
          created_before: "2020-12-31",
          bought_from: "United States",
          affiliate_products: [],
        )

        timezone = ActiveSupport::TimeZone[seller.timezone]

        expect do
          expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
        end.to change { Workflow.count }.by(0)
          .and change { workflow.reload.bought_products }.from(["abc"]).to(["F"])
          .and change { workflow.paid_more_than_cents }.from(50).to(nil)
          .and change { workflow.paid_less_than_cents }.from(nil).to(1000)
          .and change { workflow.created_after }.from(nil).to(timezone.parse("2019-01-01").as_json)
          .and change { workflow.created_before }.from(timezone.parse("2025-05-10").end_of_day.as_json).to(timezone.parse("2020-12-31").end_of_day.as_json)
          .and change { workflow.bought_from }.from(nil).to("United States")

        expect(workflow.not_bought_products).to be_nil
        expect(workflow.bought_variants).to be_nil
        expect(workflow.not_bought_variants).to be_nil
        expect(workflow.affiliate_products).to be_nil
        expect(workflow.workflow_trigger).to be_nil
      end

      it "updates the workflow and publishes it if the save action is 'save_and_publish'" do
        params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION
        create(:payment_completed, user: seller)
        expect_any_instance_of(Workflow).to receive(:schedule_installment).with(installment1)

        expect do
          expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
        end.to change { Workflow.count }.by(0)
           .and change { workflow.reload.name }.from(workflow.name).to("Updated workflow name")

        expect(workflow.workflow_type).to eq(Workflow::AFFILIATE_TYPE)
        expect(workflow.link).to be_nil
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.published_at).to be_present
        expect(workflow.first_published_at).to eq(workflow.published_at)
        expect(workflow.installments.alive.pluck(:published_at)).to eq([workflow.published_at])

        # Deleted installments are not touched
        expect(installment2.reload.installment_type).to eq(Installment::PRODUCT_TYPE)
        expect(installment2.reload.alive?).to be(false)
        expect(installment2.reload.published_at).to be_nil
      end

      it "updates the workflow and unpublishes it if the save action is 'save_and_unpublish'" do
        stripe_connect_account = create(:merchant_account_stripe_connect, user: seller)
        create(:purchase, seller:, link: product, merchant_account: stripe_connect_account)
        workflow.publish!

        params[:save_action_name] = Workflow::SAVE_AND_UNPUBLISH_ACTION
        params[:paid_less_than] = "50"

        expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

        expect do
          expect do
            expect do
              expect(described_class.new(seller:, params:, product:, workflow:).process).to eq([true, nil])
            end.to change { Workflow.count }.by(0)
              .and change { workflow.reload.name }.from(workflow.name).to("Updated workflow name")
              .and change { workflow.published_at }.from(kind_of(Time)).to(nil)
          end.not_to change { workflow.reload.first_published_at }
        end.not_to change { workflow.reload.paid_less_than_cents } # Does not update attributes other than 'name' as the workflow was previously published

        expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
        expect(workflow.link).to eq(product)
        expect(workflow.base_variant).to be_nil
        expect(workflow.workflow_trigger).to be_nil
        expect(workflow.published_at).to be_nil
        expect(workflow.first_published_at).to be_present
        expect(workflow.installments.alive.pluck(:published_at)).to eq([nil])
      end

      it "does not save changes while publishing the workflow if the seller's email is not confirmed" do
        stripe_connect_account = create(:merchant_account_stripe_connect, user: seller)
        create(:purchase, seller:, link: product, merchant_account: stripe_connect_account)
        seller.update!(confirmed_at: nil)

        params[:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

        expect do
          service = described_class.new(seller:, params:, product:, workflow:)
          expect(service.process).to eq([false, "You have to confirm your email address before you can do that."])
        end.not_to change { workflow.reload.name }
        expect(workflow.affiliate_products).to be_nil
      end

      it "returns an error if the paid filters are invalid" do
        params[:workflow_type] = Workflow::PRODUCT_TYPE
        params[:paid_more_than] = "10"
        params[:paid_less_than] = "5"

        expect do
          service = described_class.new(seller:, params:, product:, workflow:)
          expect(service.process).to eq([false, "Please enter valid paid more than and paid less than values."])
        end.not_to change { workflow.reload }
      end

      it "returns an error if the date filters are invalid" do
        params[:workflow_type] = Workflow::PRODUCT_TYPE
        params[:created_after] = "2020-12-31"
        params[:created_before] = "2019-01-01"

        expect do
          service = described_class.new(seller:, params:, product:, workflow:)
          expect(service.process).to eq([false, "Please enter valid before and after dates."])
        end.not_to change { workflow.reload }
      end
    end
  end
end
