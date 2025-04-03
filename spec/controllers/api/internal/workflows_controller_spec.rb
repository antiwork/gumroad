# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/authentication_required"
require "shared_examples/with_workflow_form_context"

describe Api::Internal::WorkflowsController do
  let(:seller) { create(:user) }

  before do
    allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE)
    create(:payment_completed, user: seller)
  end

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authentication required for action", :get, :index

    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { Workflow }
    end

    it "returns the seller's workflows" do
      product = create(:product, user: seller)
      workflow1 = create(:workflow, link: product, seller:, workflow_type: Workflow::FOLLOWER_TYPE, created_at: 1.day.ago)
      _workflow2 = create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE, deleted_at: DateTime.current)
      workflow3 = create(:workflow, link: product, seller:)
      workflow4 = create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE)

      get :index, format: :json

      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys).to match_array(workflows: [
                                                                        WorkflowPresenter.new(seller:, workflow: workflow3).workflow_props,
                                                                        WorkflowPresenter.new(seller:, workflow: workflow4).workflow_props,
                                                                        WorkflowPresenter.new(seller:, workflow: workflow1).workflow_props,
                                                                      ])
    end
  end

  describe "GET new" do
    it_behaves_like "authentication required for action", :get, :new

    it_behaves_like "authorize called for action", :get, :new do
      let(:record) { Workflow }
    end

    it_behaves_like "with workflow form 'context' in response" do
      let(:user) { seller }
      let(:result) do
        get :new, format: :json
        expect(response).to be_successful
        response.parsed_body.deep_symbolize_keys
      end
    end
  end

  describe "POST create" do
    it_behaves_like "authentication required for action", :post, :create

    it_behaves_like "authorize called for action", :post, :create do
      let(:record) { Workflow }
    end

    let(:product) { create(:product, user: seller) }
    let(:params) { { link_id: product.unique_permalink, workflow: { name: "My workflow", permalink: product.unique_permalink, workflow_type: Workflow::PRODUCT_TYPE, bought_products: ["F"], paid_more_than: "", paid_less_than: "10", created_after: "2019-01-01", created_before: "2020-12-31", bought_from: "United States", send_to_past_customers: false, save_action_name: Workflow::SAVE_ACTION } } }

    it "creates a workflow with the filters" do
      expect do
        post :create, params:, format: :json, as: :json
      end.to change { Workflow.count }.by(1)

      workflow = Workflow.last
      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["workflow_id"]).to eq(workflow.external_id)
      expect(workflow.name).to eq("My workflow")
      expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
      expect(workflow.link).to eq(product)
      expect(workflow.seller_id).to eq(seller.id)
      expect(workflow.published_at).to be_nil
      expect(workflow.base_variant).to be_nil
      expect(workflow.workflow_trigger).to be_nil
      expect(workflow.send_to_past_customers).to be(false)
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

    it "creates a workflow but does not publish it if the save action is 'save_and_publish'" do
      params[:workflow][:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

      expect do
        post :create, params:, format: :json, as: :json
      end.to change { Workflow.count }.by(1)

      expect(Workflow.last.published_at).to be_nil
    end

    it "returns an error if a filter is invalid" do
      params[:workflow][:paid_more_than] = "10"
      params[:workflow][:paid_less_than] = "5"

      expect do
        post :create, params:, format: :json, as: :json
      end.not_to change { Workflow.count }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("Please enter valid paid more than and paid less than values.")
    end

    it "raises an error if the product is not found" do
      params[:link_id] = "abc"

      expect do
        post :create, params:, format: :json, as: :json
      end.to raise_error(ActionController::RoutingError, "Not Found")
    end
  end

  describe "GET edit" do
    let(:workflow) { create(:workflow, seller:, link: nil, workflow_type: Workflow::SELLER_TYPE) }

    it_behaves_like "authentication required for action", :get, :edit do
      let(:request_params) { { id: workflow.external_id } }
    end

    it_behaves_like "authorize called for action", :get, :edit do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id } }
    end

    it_behaves_like "with workflow form 'context' in response" do
      let(:user) { seller }
      let(:result) do
        get :edit, params: { id: workflow.external_id }, format: :json
        expect(response).to be_successful
        response.parsed_body.deep_symbolize_keys
      end
    end

    it "returns the 'workflow' in response" do
      get :edit, params: { id: workflow.external_id }, format: :json

      expect(response).to be_successful
      expect(response.parsed_body.deep_symbolize_keys[:workflow]).to eq(WorkflowPresenter.new(seller:, workflow: workflow).workflow_props)
    end

    it "returns an error if the workflow belongs to a different seller" do
      workflow = create(:abandoned_cart_workflow)
      get :edit, params: { id: workflow.external_id }, format: :json

      expect(response).to have_http_status(:not_found)
      expect(response.parsed_body).to eq("success" => false, "error" => "Not found")
    end
  end

  describe "PUT update" do
    let(:product) { create(:product, user: seller) }
    let!(:workflow) { create(:workflow, seller:, link: product, workflow_type: Workflow::PRODUCT_TYPE) }
    let!(:installment1) { create(:workflow_installment, workflow:, name: "Installment 1") }
    let(:params) { { id: workflow.external_id, link_id: product.unique_permalink, workflow: { name: "My workflow", permalink: product.unique_permalink, workflow_type: Workflow::SELLER_TYPE, save_action_name: Workflow::SAVE_ACTION } } }

    it_behaves_like "authentication required for action", :put, :update do
      let(:request_params) { params }
    end

    it_behaves_like "authorize called for action", :put, :update do
      let(:record) { workflow }
      let(:request_params) { params }
    end

    it "updates the workflow and its installments" do
      workflow.update!(paid_more_than_cents: 50, bought_products: ["abc"], created_before: ActiveSupport::TimeZone[seller.timezone].parse("2025-05-10").end_of_day)

      params[:workflow].merge!(
        bought_products: ["F"],
        paid_more_than: "",
        paid_less_than: "10",
        created_after: "2019-01-01",
        created_before: "2020-12-31",
        bought_from: "United States",
        affiliate_products: [],
      )

      timezone = ActiveSupport::TimeZone[seller.timezone]

      expect_any_instance_of(Workflow).to_not receive(:schedule_installment)

      expect do
        put :update, params:, format: :json, as: :json
      end.to change { Workflow.count }.by(0)
        .and change { workflow.reload.name }.from(workflow.name).to("My workflow")
        .and change { workflow.workflow_type }.from(Workflow::PRODUCT_TYPE).to(Workflow::SELLER_TYPE)
        .and change { workflow.reload.bought_products }.from(["abc"]).to(["F"])
        .and change { workflow.link }.from(product).to(nil)
        .and change { workflow.paid_more_than_cents }.from(50).to(nil)
        .and change { workflow.paid_less_than_cents }.from(nil).to(1000)
        .and change { workflow.created_after }.from(nil).to(timezone.parse("2019-01-01").as_json)
        .and change { workflow.created_before }.from(timezone.parse("2025-05-10").end_of_day.as_json).to(timezone.parse("2020-12-31").end_of_day.as_json)
        .and change { workflow.bought_from }.from(nil).to("United States")

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      expect(response.parsed_body["workflow_id"]).to eq(workflow.external_id)
      expect(workflow.published_at).to be_nil
      expect(workflow.not_bought_products).to be_nil
      expect(workflow.bought_variants).to be_nil
      expect(workflow.not_bought_variants).to be_nil
      expect(workflow.affiliate_products).to be_nil
      expect(workflow.workflow_trigger).to be_nil

      expect(installment1.reload.installment_type).to eq(Workflow::SELLER_TYPE)
      expect(installment1.json_data).to eq(workflow.json_data)
      expect(installment1.seller_id).to eq(workflow.seller_id)
      expect(installment1.link_id).to eq(workflow.link_id)
      expect(installment1.base_variant_id).to eq(workflow.base_variant_id)
      expect(installment1.is_for_new_customers_of_workflow).to eq(!workflow.send_to_past_customers)
      expect(installment1.published_at).to be_nil
    end

    it "only updates the workflow name and ignores other params if the workflow was previously published" do
      workflow.update!(first_published_at: 10.days.ago)
      params[:workflow][:send_to_past_customers] = true

      put :update, params:, format: :json, as: :json

      expect(workflow.reload.name).to eq("My workflow")
      expect(workflow.workflow_type).to eq(Workflow::PRODUCT_TYPE)
      expect(workflow.affiliate_products).to be_nil
      expect(workflow.send_to_past_customers).to be(false)
    end

    it "updates the workflow and publishes it if the save action is 'save_and_publish'" do
      params[:workflow][:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(installment1)

      put :update, params:, format: :json, as: :json

      expect(workflow.reload.published_at).to be_present
      expect(workflow.first_published_at).to eq(workflow.published_at)
      expect(workflow.installments.alive.pluck(:published_at).uniq).to eq([workflow.published_at])
    end

    it "returns an error while publishing a workflow if the seller is not eligible to send emails" do
      allow_any_instance_of(User).to receive(:sales_cents_total).and_return(Installment::MINIMUM_SALES_CENTS_VALUE - 1)

      params[:workflow][:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      put :update, params:, format: :json, as: :json

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("You cannot publish a workflow until you have made at least $100 in sales and received a payout")
      expect(workflow.reload.published_at).to be_nil
    end

    it "updates the workflow and unpublishes it if the save action is 'save_and_unpublish'" do
      workflow.publish!

      params[:workflow][:save_action_name] = Workflow::SAVE_AND_UNPUBLISH_ACTION
      params[:workflow][:name] = "My workflow (edited)"
      params[:workflow][:paid_less_than] = "20"

      expect do
        expect do
          expect do
            put :update, params:, format: :json, as: :json
          end.to change { workflow.reload.name }.from("my workflow").to("My workflow (edited)")
            .and change { workflow.published_at }.from(kind_of(Time)).to(nil)
            .and change { workflow.installments.alive.pluck(:published_at).uniq }.from([kind_of(Time)]).to([nil])
        end.not_to change { workflow.reload.first_published_at }
      end.not_to change { workflow.reload.paid_less_than_cents } # Does not update attributes other than 'name' as the workflow was previously published
    end

    it "returns an error if filters are invalid" do
      params[:workflow][:workflow_type] = Workflow::PRODUCT_TYPE
      params[:workflow][:created_after] = "2020-12-31"
      params[:workflow][:created_before] = "2019-01-01"

      expect do
        put :update, params:, format: :json, as: :json
      end.not_to change { workflow.reload }

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("Please enter valid before and after dates.")
    end
  end

  describe "DELETE destroy" do
    let(:workflow) { create(:workflow, seller:, workflow_type: Workflow::SELLER_TYPE) }

    it_behaves_like "authentication required for action", :delete, :destroy do
      let(:request_params) { { id: workflow.external_id } }
    end

    it_behaves_like "authorize called for action", :delete, :destroy do
      let(:record) { workflow }
      let(:request_params) { { id: workflow.external_id } }
    end

    it "marks the workflow as deleted" do
      expect do
        delete :destroy, params: { id: workflow.external_id }, format: :json
      end.to change { workflow.reload.deleted_at }.from(nil).to(be_within(5.seconds).of(DateTime.current))

      expect(response).to be_successful
      expect(response.parsed_body).to eq("success" => true)
    end
  end

  describe "PUT save_installments" do
    let(:product) { create(:product, user: seller) }
    let(:workflow) { create(:workflow, seller:, link: product, workflow_type: Workflow::PRODUCT_TYPE) }
    let!(:installment1) { create(:installment, workflow:, name: "Installment 1") }
    let!(:installment2) { create(:installment, workflow:, name: "Installment 2") }
    let(:new_installment_temporary_id) { SecureRandom.uuid }
    let(:params) { { id: workflow.external_id, workflow: { send_to_past_customers: false, save_action_name: Workflow::SAVE_ACTION, installments: [{ id: installment1.external_id, name: "Installment 1 (edited)", message: "Message 1", time_period: "hour", time_duration: 1, send_preview_email: false, files: [] }, { id: new_installment_temporary_id, name: "New installment", message: "Lorem ipsum", time_period: "week", time_duration: 1, send_preview_email: true, files: [] }] } } }

    it_behaves_like "authentication required for action", :put, :save_installments do
      let(:request_params) { params }
    end

    it_behaves_like "authorize called for action", :put, :save_installments do
      let(:record) { workflow }
      let(:request_params) { params }
    end

    def save_installments_and_perform_common_assertions
      expect do
        put :save_installments, params:, format: :json, as: :json
      end.to change { workflow.installments.count }.by(1)
        .and change { workflow.installments.alive.count }.by(0)
        .and change { installment1.reload.name }.from("Installment 1").to("Installment 1 (edited)")
        .and change { installment2.reload.deleted_at.present? }.from(false).to(true)

      expect(response).to be_successful
      expect(response.parsed_body["success"]).to eq(true)
      new_installment = workflow.installments.last
      expect(response.parsed_body["old_and_new_installment_id_mapping"]).to eq(
        installment1.external_id => installment1.external_id,
        new_installment_temporary_id => new_installment.external_id,
      )
      workflow_response = response.parsed_body["workflow"].deep_symbolize_keys
      expect(workflow_response[:installments].size).to eq(2)
      expect(workflow_response[:installments]).to match_array([
                                                                a_hash_including(
                                                                  external_id: installment1.external_id,
                                                                  name: "Installment 1 (edited)",
                                                                  message: "Message 1",
                                                                  delayed_delivery_time_duration: 1,
                                                                  delayed_delivery_time_period: "hour",
                                                                ),
                                                                a_hash_including(
                                                                  external_id: new_installment.external_id,
                                                                  name: "New installment",
                                                                  message: "Lorem ipsum",
                                                                  delayed_delivery_time_duration: 1,
                                                                  delayed_delivery_time_period: "week",
                                                                )
                                                              ])
    end

    it "saves the installments" do
      expect(PostSendgridApi).to receive(:process).with(post: an_instance_of(Installment), recipients: [{ email: controller.logged_in_user.email }], preview: true)

      save_installments_and_perform_common_assertions
    end

    it "saves the installments and publishes the workflow if the save action is 'save_and_publish'" do
      params[:workflow][:save_action_name] = Workflow::SAVE_AND_PUBLISH_ACTION

      expect_any_instance_of(Workflow).to receive(:schedule_installment).with(an_instance_of(Installment)).twice

      save_installments_and_perform_common_assertions

      expect(workflow.reload.published_at).to be_present
      expect(workflow.first_published_at).to eq(workflow.published_at)
      expect(workflow.installments.alive.pluck(:published_at).uniq).to eq([workflow.published_at])
    end

    it "updates the workflow and unpublishes it if the save action is 'save_and_unpublish'" do
      workflow.publish!

      params[:workflow][:save_action_name] = Workflow::SAVE_AND_UNPUBLISH_ACTION

      expect do
        expect do
          save_installments_and_perform_common_assertions
        end.to change { workflow.reload.published_at }.from(kind_of(Time)).to(nil)
          .and change { workflow.installments.alive.pluck(:published_at).uniq }.from([kind_of(Time)]).to([nil])
      end.not_to change { workflow.first_published_at }

      expect(workflow.installments.alive.pluck(:published_at).uniq).to eq([nil])
    end

    it "returns an error if an installment is invalid" do
      params[:workflow][:installments] = [
        { id: SecureRandom.uuid, name: "Installment 1", message: "", time_period: "hour", time_duration: 1, send_preview_email: false, files: [] },
      ]

      expect do
        put :save_installments, params:, format: :json, as: :json
      end.not_to change { workflow.installments.alive.count }

      expect(response.parsed_body["success"]).to eq(false)
      expect(response.parsed_body["message"]).to eq("Please include a message as part of the update.")
    end
  end
end
