# frozen_string_literal: true

require "spec_helper"
require "shared_examples/with_workflow_form_context"

describe WorkflowPresenter do
  let(:seller) { create(:named_seller) }

  describe "#new_page_react_props" do
    it_behaves_like "with workflow form 'context' in response" do
      let(:user) { seller }
      let(:result) { described_class.new(seller:).new_page_react_props }
    end
  end

  describe "#edit_page_react_props" do
    it_behaves_like "with workflow form 'context' in response" do
      let(:user) { seller }
      let(:result) { described_class.new(seller:, workflow: create(:workflow, link: nil, seller:, workflow_type: Workflow::SELLER_TYPE)).edit_page_react_props }
    end

    it "returns the 'workflow' in response" do
      workflow = create(:workflow, seller:)
      props = described_class.new(seller:, workflow:).edit_page_react_props
      expect(props[:workflow]).to be_present
    end
  end

  describe "#workflow_props" do
    let(:seller) { create(:named_seller) }
    let(:product) { create(:product, user: seller) }
    let(:workflow) { create(:workflow, seller:, link: product) }

    it "includes the necessary workflow details" do
      props = described_class.new(seller:, workflow:).workflow_props

      expect(props).to match(a_hash_including(
        name: "my workflow",
        external_id: workflow.external_id,
        workflow_type: "product",
        workflow_trigger: nil,
        recipient_name: "The Works of Edgar Gumstein",
        published: false,
        first_published_at: nil,
        send_to_past_customers: false
      ))
      expect(props.keys).to_not include(:abandoned_cart_products, :seller_has_products)
    end

    it "includes 'abandoned_cart_products' for an abandoned cart workflow" do
      workflow.update!(workflow_type: Workflow::ABANDONED_CART_TYPE)

      presenter = described_class.new(seller:, workflow:)
      expect(presenter.workflow_props).to include(abandoned_cart_products: workflow.abandoned_cart_products)
    end

    it "includes 'seller_has_products' for an abandoned cart workflow" do
      workflow.update!(workflow_type: Workflow::ABANDONED_CART_TYPE)

      presenter = described_class.new(seller:, workflow:)
      expect(presenter.workflow_props).to include(seller_has_products: true)
    end

    context "when the workflow is published" do
      before do
        workflow.update!(published_at: DateTime.current, first_published_at: 2.days.ago, send_to_past_customers: true)
      end

      it "includes the necessary workflow details" do
        props = described_class.new(seller:, workflow:).workflow_props

        expect(props).to match(a_hash_including(
          name: "my workflow",
          external_id: workflow.external_id,
          workflow_type: "product",
          workflow_trigger: nil,
          recipient_name: "The Works of Edgar Gumstein",
          published: true,
          first_published_at: be_present,
          send_to_past_customers: true
        ))
      end
    end

    context "when the workflow has installments" do
      let(:installment1) { create(:installment, link: product, workflow:, published_at: 1.day.ago, name: "1 day") }
      let(:installment2) { create(:installment, link: product, workflow:, published_at: Time.current, name: "5 hours") }
      let(:installment3) { create(:installment, link: product, workflow:, published_at: Time.current, name: "1 hour") }

      before do
        create(:installment_rule, installment: installment1, delayed_delivery_time: 1.day)
        create(:installment_rule, installment: installment2, delayed_delivery_time: 5.hours)
        create(:installment_rule, installment: installment3, delayed_delivery_time: 1.hour)
      end

      it "returns installments in order of which ones will be delivered first" do
        props = described_class.new(seller:, workflow:).workflow_props

        expect(props[:installments]).to eq([
                                             {
                                               name: "1 hour", message: installment3.message,
                                               files: [],
                                               published_at: installment3.published_at,
                                               updated_at: installment3.updated_at,
                                               published_once_already: true,
                                               member_cancellation: false,
                                               external_id: installment3.external_id,
                                               stream_only: false,
                                               call_to_action_text: nil,
                                               call_to_action_url: nil,
                                               new_customers_only: false,
                                               streamable: false,
                                               sent_count: nil,
                                               click_count: 0,
                                               open_count: 0,
                                               click_rate: nil,
                                               open_rate: nil,
                                               send_emails: true,
                                               shown_on_profile: false,
                                               installment_type: "product",
                                               paid_more_than_cents: nil,
                                               paid_less_than_cents: nil,
                                               allow_comments: true,
                                               display_type: "published",
                                               unique_permalink: product.unique_permalink,
                                               delayed_delivery_time_duration: 1,
                                               delayed_delivery_time_period: "hour",
                                               displayed_delayed_delivery_time_period: "Hour"
                                             },
                                             {
                                               name: "5 hours",
                                               message: installment2.message,
                                               files: [],
                                               published_at: installment2.published_at,
                                               updated_at: installment2.updated_at,
                                               published_once_already: true,
                                               member_cancellation: false,
                                               external_id: installment2.external_id,
                                               stream_only: false,
                                               call_to_action_text: nil,
                                               call_to_action_url: nil,
                                               new_customers_only: false,
                                               streamable: false,
                                               sent_count: nil,
                                               click_count: 0,
                                               open_count: 0,
                                               click_rate: nil,
                                               open_rate: nil,
                                               send_emails: true,
                                               shown_on_profile: false,
                                               installment_type: "product",
                                               paid_more_than_cents: nil,
                                               paid_less_than_cents: nil,
                                               allow_comments: true,
                                               display_type: "published",
                                               unique_permalink: product.unique_permalink,
                                               delayed_delivery_time_duration: 5,
                                               delayed_delivery_time_period: "hour",
                                               displayed_delayed_delivery_time_period: "Hours"
                                             },
                                             {
                                               name: "1 day",
                                               message: installment1.message,
                                               files: [],
                                               published_at: installment1.published_at,
                                               updated_at: installment1.updated_at,
                                               published_once_already: true,
                                               member_cancellation: false,
                                               external_id: installment1.external_id,
                                               stream_only: false,
                                               call_to_action_text: nil,
                                               call_to_action_url: nil,
                                               new_customers_only: false,
                                               streamable: false,
                                               sent_count: nil,
                                               click_count: 0,
                                               open_count: 0,
                                               click_rate: nil,
                                               open_rate: nil,
                                               send_emails: true,
                                               shown_on_profile: false,
                                               installment_type: "product",
                                               paid_more_than_cents: nil,
                                               paid_less_than_cents: nil,
                                               allow_comments: true,
                                               display_type: "published",
                                               unique_permalink: product.unique_permalink,
                                               delayed_delivery_time_duration: 24,
                                               delayed_delivery_time_period: "hour",
                                               displayed_delayed_delivery_time_period: "Hours"
                                             }
                                           ])
      end
    end
  end
end
