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

    [
      { currency: "eur", rate: "0.885", lower: 50, upper: 115, displayed_lower: "0.44", displayed_upper: "1.02" },
      { currency: "jpy", rate: "150", lower: 150, upper: 350, displayed_lower: "225", displayed_upper: "525" },
    ].each do |values|
      it "displays USD price bounds in the seller's #{values[:currency]} currency" do
        Redis::Namespace.new(:currencies, redis: $redis).set(values[:currency].upcase, values[:rate])
        seller.update!(currency_type: values[:currency])
        workflow.update!(paid_more_than_cents: values[:lower], paid_less_than_cents: values[:upper])

        props = described_class.new(seller:, workflow:).edit_page_react_props.fetch(:workflow)

        expect(props[:paid_more_than]).to eq(values[:displayed_lower])
        expect(props[:paid_less_than]).to eq(values[:displayed_upper])
        expect(props[:price_filter_currency]).to eq(values[:currency])
        expect(props[:price_filters_available]).to be(true)
        expect(workflow.reload.paid_more_than_cents).to eq(values[:lower])
        expect(workflow.paid_less_than_cents).to eq(values[:upper])
      end
    end

    it "uses one cached exchange rate for both displayed bounds" do
      seller.update!(currency_type: "eur")
      workflow.update!(paid_more_than_cents: 9990, paid_less_than_cents: 9991)
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with("currencies:EUR").and_return("0.885", "0.884")

      props = described_class.new(seller:, workflow:).edit_page_react_props.fetch(:workflow)

      expect(props[:paid_more_than]).to eq("88.41")
      expect(props[:paid_less_than]).to eq("88.42")
    end

    it "shows stored USD bounds as unavailable for editing when the seller's exchange rate is missing" do
      seller.update!(currency_type: "eur")
      workflow.update!(paid_more_than_cents: 50, paid_less_than_cents: 115)
      Redis::Namespace.new(:currencies, redis: $redis).del("EUR")
      expect(workflow).not_to receive(:query_rate)

      props = described_class.new(seller:, workflow:).edit_page_react_props.fetch(:workflow)

      expect(props[:price_filter_currency]).to eq("usd")
      expect(props[:price_filters_available]).to be(false)
      expect(props[:paid_more_than]).to eq("0.50")
      expect(props[:paid_less_than]).to eq("1.15")
    end

    it "keeps stored USD bounds readable when the rate cache cannot be reached" do
      seller.update!(currency_type: "eur")
      workflow.update!(paid_more_than_cents: 50, paid_less_than_cents: 115)
      allow($redis).to receive(:get).and_call_original
      allow($redis).to receive(:get).with("currencies:EUR").and_raise(RedisClient::CannotConnectError.new("Unavailable"))
      expect(workflow).not_to receive(:query_rate)

      props = described_class.new(seller:, workflow:).edit_page_react_props.fetch(:workflow)

      expect(props[:price_filter_currency]).to eq("usd")
      expect(props[:price_filters_available]).to be(false)
      expect(props[:paid_more_than]).to eq("0.50")
      expect(props[:paid_less_than]).to eq("1.15")
    end

    it "does not read exchange rates for the shared workflow list and email props" do
      seller.update!(currency_type: "eur")
      workflow.update!(paid_more_than_cents: 50)
      expect(workflow).not_to receive(:cached_rate)
      expect(workflow).not_to receive(:get_rate)

      expect(described_class.new(seller:, workflow:).workflow_props[:paid_more_than]).to eq("0.50")
    end

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
