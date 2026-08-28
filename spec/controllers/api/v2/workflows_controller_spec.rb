# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::WorkflowsController do
  before do
    @user = create(:user, email: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_access_token(scopes)
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes:)
  end

  describe "GET 'index'" do
    before do
      @action = :index
      @params = {}
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    it "returns alive workflows for the seller in newest-first order" do
      token = create_access_token("edit_emails")
      older_workflow = create(:audience_workflow, seller: @user, name: "Older", created_at: 2.hours.ago)
      newer_workflow = create(:product_workflow, seller: @user, name: "Newer", created_at: 1.hour.ago, paid_more_than_cents: 100)
      create(:workflow_installment, workflow: newer_workflow, seller: @user, link: newer_workflow.link)
      create(:audience_workflow, seller: @user, deleted_at: Time.current)
      create(:audience_workflow, seller: create(:user))
      presented_workflows = []
      allow(Api::WorkflowPresenter).to receive(:new).and_wrap_original do |original, workflow:, **options|
        presented_workflows << workflow
        original.call(workflow:, **options)
      end

      get @action, params: { access_token: token.token }

      expect(response.parsed_body["success"]).to be(true)
      expect(presented_workflows).to all(satisfy { _1.association(:seller).loaded? })
      expected_ids = [newer_workflow.external_id, older_workflow.external_id]
      expect(response.parsed_body["workflows"].map { _1["id"] }).to eq(expected_ids)
      expect(response.parsed_body["workflows"].first).to include(
        "name" => "Newer",
        "audience_type" => Workflow::PRODUCT_TYPE,
        "product_id" => newer_workflow.link.external_id,
        "state" => Installment::DRAFT,
        "emails_count" => 1,
      )
      expect(response.parsed_body["workflows"].first).not_to have_key("emails")
    end

    it "grants list access with the account scope used by the CLI" do
      token = create_access_token("account")
      create(:audience_workflow, seller: @user)

      get @action, params: { access_token: token.token }

      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body["workflows"].size).to eq(1)
    end
  end

  describe "GET 'show'" do
    before do
      @action = :show
      @workflow = create(
        :audience_workflow,
        seller: @user,
        name: "Onboarding",
        published_at: 3.days.ago,
        first_published_at: 4.days.ago,
        send_to_past_customers: true,
      )
      @params = { id: @workflow.external_id }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    it "caches ordered email stats without writing event-owned keys" do
      token = create_access_token("edit_emails")
      later_email = create(
        :workflow_installment,
        workflow: @workflow,
        seller: @user,
        link: nil,
        name: "Later",
        message: "<p>Later body</p>",
        customer_count: 20,
      )
      later_email.installment_rule.update!(delayed_delivery_time: 2.weeks.to_i, time_period: InstallmentRule::WEEK)
      first_email = create(
        :workflow_installment,
        workflow: @workflow,
        seller: @user,
        link: nil,
        name: "First",
        message: "<p>First body</p>",
        customer_count: 10,
      )
      first_email.installment_rule.update!(delayed_delivery_time: 2.days.to_i, time_period: InstallmentRule::DAY)
      create(:workflow_installment, workflow: @workflow, seller: @user, link: nil, deleted_at: Time.current)

      4.times do |index|
        EmailEngagementDynamoStore.record_open(
          installment_id: first_email.id,
          mailer_method: "WorkflowMailer.first_#{index}",
          mailer_args: index.to_s,
        )
      end
      EmailEngagementDynamoStore.record_open(
        installment_id: later_email.id,
        mailer_method: "WorkflowMailer.later",
        mailer_args: "later",
      )
      2.times do |index|
        EmailEngagementDynamoStore.record_click(
          installment_id: first_email.id, mailer_method: "WorkflowMailer.first_#{index}",
          mailer_args: index.to_s, click_url: "https://example&#46;com"
        )
      end
      EmailEngagementDynamoStore.record_click(
        installment_id: later_email.id, mailer_method: "WorkflowMailer.later",
        mailer_args: "later", click_url: "https://example&#46;com"
      )
      [first_email, later_email].each do |email|
        Rails.cache.delete(email.key_for_cache(:unique_open_count))
        Rails.cache.delete(email.key_for_cache(:unique_click_count))
      end
      expect(EmailEngagementDynamoStore).to receive(:summaries).twice.and_call_original

      get @action, params: @params.merge(access_token: token.token)
      expect(Rails.cache.read(first_email.key_for_cache(:unique_open_count))).to be_nil
      expect(Rails.cache.read(first_email.key_for_cache(:unique_click_count))).to be_nil
      expect(Rails.cache.read("api_workflow_#{first_email.key_for_cache(:unique_open_count)}")).to eq(4)
      expect(Rails.cache.read("api_workflow_#{first_email.key_for_cache(:unique_click_count)}")).to eq(2)

      Rails.cache.write(first_email.key_for_cache(:unique_open_count), 5)
      get @action, params: @params.merge(access_token: token.token)

      workflow_json = response.parsed_body.fetch("workflow")
      expect(response.parsed_body["success"]).to be(true)
      expect(workflow_json).to include(
        "id" => @workflow.external_id,
        "name" => "Onboarding",
        "audience_type" => Workflow::AUDIENCE_TYPE,
        "state" => Installment::PUBLISHED,
        "send_to_past_customers" => true,
        "emails_count" => 2,
      )
      expect(workflow_json["emails"].map { _1["id"] }).to eq([first_email.external_id, later_email.external_id])
      expect(workflow_json["emails"].first).to include(
        "subject" => "First",
        "message" => "<p>First body</p>",
        "audience_type" => Workflow::AUDIENCE_TYPE,
        "product_id" => nil,
        "send_emails" => true,
        "delay" => { "amount" => 2, "unit" => InstallmentRule::DAY },
        "sent_count" => 10,
        "open_count" => 4,
        "open_rate" => 40.0,
        "click_count" => 2,
        "click_rate" => 20.0,
      )
      expect(workflow_json["emails"].second).to include(
        "delay" => { "amount" => 2, "unit" => InstallmentRule::WEEK },
        "sent_count" => 20,
        "open_count" => 1,
        "open_rate" => 5.0,
        "click_count" => 1,
        "click_rate" => 5.0,
      )
    end

    it "returns zero counts and null rates before an email has sent" do
      token = create_access_token("edit_emails")
      email = create(:workflow_installment, workflow: @workflow, seller: @user, link: nil, customer_count: nil)
      Rails.cache.delete(email.key_for_cache(:unique_open_count))
      Rails.cache.delete(email.key_for_cache(:unique_click_count))

      get @action, params: @params.merge(access_token: token.token)

      email_json = response.parsed_body.dig("workflow", "emails").sole
      expect(email_json).to include(
        "id" => email.external_id,
        "sent_count" => 0,
        "open_count" => 0,
        "open_rate" => nil,
        "click_count" => 0,
        "click_rate" => nil,
      )
    end

    it "does not return another seller's workflow" do
      token = create_access_token("edit_emails")
      other_workflow = create(:audience_workflow, seller: create(:user))

      get @action, params: { access_token: token.token, id: other_workflow.external_id }

      expect(response.parsed_body).to eq({
        success: false,
        message: "The workflow was not found.",
      }.as_json)
    end

    it "does not return a deleted workflow" do
      token = create_access_token("edit_emails")
      @workflow.update!(deleted_at: Time.current)

      get @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body).to eq({
        success: false,
        message: "The workflow was not found.",
      }.as_json)
    end

    it "grants detail access with the account scope used by the CLI" do
      token = create_access_token("account")

      get @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body["success"]).to be(true)
      expect(response.parsed_body.dig("workflow", "id")).to eq(@workflow.external_id)
    end
  end
end
