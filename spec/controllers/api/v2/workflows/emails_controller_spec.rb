# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::Workflows::EmailsController do
  before do
    @user = create(:user, email: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_access_token(scopes)
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes:)
  end

  describe "POST 'create'" do
    before do
      @action = :create
      @workflow = create(:audience_workflow, seller: @user, send_to_past_customers: true)
      @params = {
        workflow_id: @workflow.external_id,
        subject: "Week four",
        body: "<p>Keep going.</p>",
        delay_amount: "4",
        delay_unit: InstallmentRule::WEEK,
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    it "adds one email without replacing the existing emails or changing workflow state" do
      token = create_access_token("edit_emails")
      existing_email = create(:workflow_installment, workflow: @workflow, seller: @user, link: nil)
      published_at = @workflow.published_at

      post @action, params: @params.merge(access_token: token.token)

      created_email = @workflow.installments.alive.where.not(id: existing_email.id).sole
      expect(created_email).to have_attributes(
        name: "Week four",
        message: "<p>Keep going.</p>",
        installment_type: Workflow::AUDIENCE_TYPE,
        seller_id: @user.id,
        link_id: nil,
        published_at: nil,
      )
      expect(created_email).to be_send_emails
      expect(created_email).not_to be_workflow_installment_published_once_already
      expect(created_email.installment_rule).to have_attributes(
        delayed_delivery_time: 4.weeks.to_i,
        time_period: InstallmentRule::WEEK,
      )
      expect(existing_email.reload).to be_alive
      expect(@workflow.reload.published_at).to eq(published_at)
      expect(@workflow).to be_send_to_past_customers
      expect(response.parsed_body["email"]).to include(
        "id" => created_email.external_id,
        "subject" => "Week four",
        "message" => "<p>Keep going.</p>",
        "state" => Installment::DRAFT,
        "delay" => { "amount" => 4, "unit" => InstallmentRule::WEEK },
        "open_count" => nil,
        "click_count" => nil,
      )
    end

    it "does not query analytics after the email commits" do
      token = create_access_token("edit_emails")
      allow(CreatorEmailOpenEvent).to receive(:collection).and_raise("analytics unavailable")
      allow(CreatorEmailClickSummary).to receive(:in).and_raise("analytics unavailable")

      post @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body["success"]).to be(true)
      expect(@workflow.installments.alive.count).to eq(1)
    end

    it "activates a new email when the workflow is published without changing workflow state" do
      token = create_access_token("edit_emails")
      published_at = 2.days.ago
      @workflow.update!(published_at:, first_published_at: published_at)
      published_at = @workflow.reload.published_at
      expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async).with(kind_of(Integer), 1, nil, kind_of(String))

      post @action, params: @params.merge(access_token: token.token)

      created_email = @workflow.installments.alive.sole
      expect(created_email.published_at).to be > published_at
      expect(created_email).to be_workflow_installment_published_once_already
      expect(@workflow.reload.published_at).to eq(published_at)
      expect(response.parsed_body.dig("email", "state")).to eq(Installment::PUBLISHED)
    end

    it "does not add an email to an abandoned cart workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:abandoned_cart_workflow, seller: @user)

      expect do
        post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)
      end.not_to change { workflow.installments.alive.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("Emails cannot be added to abandoned cart workflows.")
    end

    it "does not add an email to another seller's workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:audience_workflow, seller: create(:user))

      post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)

      expect(response.parsed_body).to eq({
        success: false,
        message: "The workflow was not found.",
      }.as_json)
      expect(workflow.installments.alive).to be_empty
    end

    it "does not add an email after the workflow product changes owner" do
      token = create_access_token("edit_emails")
      product = create(:product)
      workflow = create(:workflow, seller: @user, link: product, workflow_type: Workflow::PRODUCT_TYPE)

      post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)

      expect(response.parsed_body).to eq({
        success: false,
        message: "The workflow was not found.",
      }.as_json)
      expect(workflow.installments.alive).to be_empty
    end

    it "rejects incomplete and invalid delays" do
      token = create_access_token("edit_emails")
      invalid_delays = [
        [@params.except(:delay_unit), "delay_unit is required."],
        [@params.merge(delay_amount: -1), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_amount: 1.5), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_amount: "1.5"), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_unit: "year"), "delay_unit must be one of: hour, day, week, month."],
        [@params.merge(delay_amount: "01720440", delay_unit: InstallmentRule::HOUR), "delay is too large."],
        [@params.merge(delay_amount: Api::V2::Workflows::EmailsController::MAX_DELAY_SECONDS + 1, delay_unit: InstallmentRule::HOUR), "delay is too large."],
      ]

      invalid_delays.each do |request_params, error|
        post @action, params: request_params.merge(access_token: token.token)

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["error"]).to eq(error)
      end
      expect(@workflow.installments.alive).to be_empty
    end

    it "rejects workflow state parameters" do
      token = create_access_token("edit_emails")

      post @action, params: @params.merge(access_token: token.token, publish: true)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("publish cannot be changed through this endpoint.")
      expect(@workflow.installments.alive).to be_empty
    end

    it "grants create access with the account scope used by the CLI" do
      token = create_access_token("account")

      post @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body["success"]).to be(true)
      expect(@workflow.installments.alive.count).to eq(1)
    end
  end

  describe "PUT 'update'" do
    before do
      @action = :update
      @workflow = create(:audience_workflow, seller: @user)
      @email = create(
        :workflow_installment,
        workflow: @workflow,
        seller: @user,
        link: nil,
        name: "Original subject",
        message: "<p>Original body</p>",
      )
      @email.installment_rule.update!(delayed_delivery_time: 1.day.to_i, time_period: InstallmentRule::DAY)
      @params = {
        workflow_id: @workflow.external_id,
        email_id: @email.external_id,
        body: "<p>Updated body</p>",
      }
    end

    it_behaves_like "authorized oauth v1 api method"
    it_behaves_like "authorized oauth v1 api method only for edit_emails scope"

    it "updates only the supplied fields and preserves siblings and files" do
      token = create_access_token("edit_emails")
      sibling = create(:workflow_installment, workflow: @workflow, seller: @user, link: nil)
      file = create(:product_file, installment: @email, link: nil)

      put @action, params: @params.merge(access_token: token.token)

      expect(@email.reload).to have_attributes(name: "Original subject", message: "<p>Updated body</p>")
      expect(@email.installment_rule).to have_attributes(
        delayed_delivery_time: 1.day.to_i,
        time_period: InstallmentRule::DAY,
      )
      expect(@email.alive_product_files).to contain_exactly(file)
      expect(sibling.reload).to be_alive
      expect(response.parsed_body["email"]).to include(
        "id" => @email.external_id,
        "subject" => "Original subject",
        "message" => "<p>Updated body</p>",
        "delay" => { "amount" => 1, "unit" => InstallmentRule::DAY },
      )
    end

    it "reschedules a published email when its delay changes" do
      token = create_access_token("edit_emails")
      workflow_published_at = 2.days.ago.change(usec: 0)
      email_published_at = 1.day.ago.change(usec: 0)
      @workflow.update!(published_at: workflow_published_at, first_published_at: workflow_published_at)
      @email.update!(published_at: email_published_at, workflow_installment_published_once_already: true)
      expected_rule_version = @email.installment_rule.version + 1
      expect(ScheduleWorkflowInstallmentJob).to receive(:perform_async)
        .with(@email.id, expected_rule_version, 1.day.to_i, kind_of(String))

      put @action, params: @params.except(:body).merge(
        access_token: token.token,
        delay_amount: 2,
        delay_unit: InstallmentRule::WEEK,
      )

      expect(@email.reload.installment_rule).to have_attributes(
        delayed_delivery_time: 2.weeks.to_i,
        time_period: InstallmentRule::WEEK,
      )
      expect(@email.published_at).to eq(email_published_at)
      expect(@workflow.reload.published_at).to eq(workflow_published_at)
      expect(response.parsed_body.dig("email", "state")).to eq(Installment::PUBLISHED)
    end

    it "does not update an email through another workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:audience_workflow, seller: @user)

      expect do
        put @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)
      end.not_to change { workflow.installments.alive.count }

      expect(response.parsed_body).to eq({
        success: false,
        message: "The email was not found.",
      }.as_json)
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not update through an unknown workflow" do
      token = create_access_token("edit_emails")

      expect do
        put @action, params: @params.merge(access_token: token.token, workflow_id: "unknown")
      end.not_to change(Installment, :count)

      expect(response.parsed_body).to eq({
        success: false,
        message: "The workflow was not found.",
      }.as_json)
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not create an email for an unknown email ID" do
      token = create_access_token("edit_emails")

      expect do
        put @action, params: @params.merge(access_token: token.token, email_id: "unknown")
      end.not_to change { @workflow.installments.alive.count }

      expect(response.parsed_body).to eq({
        success: false,
        message: "The email was not found.",
      }.as_json)
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not update a deleted email" do
      token = create_access_token("edit_emails")
      @email.update!(deleted_at: Time.current)

      put @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body).to eq({
        success: false,
        message: "The email was not found.",
      }.as_json)
    end

    it "requires at least one write parameter" do
      token = create_access_token("edit_emails")

      put @action, params: @params.except(:body).merge(access_token: token.token)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("Provide at least one of: subject, body, delay_amount, or delay_unit.")
    end

    it "rejects a partial delay" do
      token = create_access_token("edit_emails")

      put @action, params: @params.except(:body).merge(access_token: token.token, delay_amount: 2)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("delay_amount and delay_unit must be provided together.")
      expect(@email.reload.installment_rule.delayed_delivery_time).to eq(1.day.to_i)
    end

    it "rejects a delay change for an abandoned cart workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:abandoned_cart_workflow, seller: @user)
      email = workflow.installments.alive.sole
      create(:installment_rule, installment: email, delayed_delivery_time: 0)

      put @action, params: {
        access_token: token.token,
        workflow_id: workflow.external_id,
        email_id: email.external_id,
        delay_amount: 2,
        delay_unit: InstallmentRule::HOUR,
      }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("delay cannot be changed for abandoned cart workflows.")
      expect(email.reload.installment_rule.delayed_delivery_time).to eq(0)
    end

    it "updates the body of an abandoned cart email" do
      token = create_access_token("edit_emails")
      workflow = create(:abandoned_cart_workflow, seller: @user)
      email = workflow.installments.alive.sole
      create(:installment_rule, installment: email, delayed_delivery_time: 0)

      put @action, params: {
        access_token: token.token,
        workflow_id: workflow.external_id,
        email_id: email.external_id,
        body: "<p>Complete your purchase.</p><product-list-placeholder />",
      }

      expect(response.parsed_body["success"]).to be(true)
      expect(email.reload.message).to eq("<p>Complete your purchase.</p><product-list-placeholder></product-list-placeholder>")
    end

    it "rejects workflow state parameters" do
      token = create_access_token("edit_emails")

      put @action, params: @params.merge(access_token: token.token, state: Installment::DRAFT)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("state cannot be changed through this endpoint.")
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "rejects malformed upsell data in the body" do
      token = create_access_token("edit_emails")
      product = create(:product, user: @user)

      put @action, params: @params.merge(
        access_token: token.token,
        body: %(<upsell-card productid="#{product.external_id}" discount="{"></upsell-card>),
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("Content contains invalid upsell data.")
      expect(@email.reload.message).to eq("<p>Original body</p>")
      expect(@user.upsells).to be_empty
    end

    it "rejects invalid upsell data in the body" do
      token = create_access_token("edit_emails")
      product = create(:product, user: @user)

      put @action, params: @params.merge(
        access_token: token.token,
        body: %(<upsell-card productid="#{product.external_id}" discount="1"></upsell-card>),
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("Content contains invalid upsell data.")
      expect(@email.reload.message).to eq("<p>Original body</p>")
      expect(@user.upsells).to be_empty
    end

    it "rejects an upsell product owned by another seller" do
      token = create_access_token("edit_emails")
      product = create(:product)

      put @action, params: @params.merge(
        access_token: token.token,
        body: %(<upsell-card productid="#{product.external_id}"></upsell-card>),
      )

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("The offered product must belong to the current seller.")
      expect(@email.reload.message).to eq("<p>Original body</p>")
      expect(@user.upsells).to be_empty
    end

    it "does not recreate an email deleted before the workflow lock" do
      token = create_access_token("edit_emails")
      allow_any_instance_of(Workflow).to receive(:lock!).and_wrap_original do |method|
        @email.update!(deleted_at: Time.current)
        method.call
      end

      expect do
        put @action, params: @params.merge(access_token: token.token)
      end.not_to change { @workflow.installments.count }

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["error"]).to eq("The email was not found.")
    end

    it "grants update access with the account scope used by the CLI" do
      token = create_access_token("account")

      put @action, params: @params.merge(access_token: token.token)

      expect(response.parsed_body["success"]).to be(true)
      expect(@email.reload.message).to eq("<p>Updated body</p>")
    end
  end
end
