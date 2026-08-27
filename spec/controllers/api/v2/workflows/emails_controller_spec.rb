# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorized_oauth_v1_api_method"

describe Api::V2::Workflows::EmailsController do
  EMAIL_RESPONSE_KEYS = %w[
    id subject message audience_type product_id state published_at send_emails delay sent_count
    open_count open_rate click_count click_rate created_at updated_at
  ].freeze

  before do
    @user = create(:user, email: "seller@example.com")
    @app = create(:oauth_application, owner: create(:user))
  end

  def create_access_token(scopes)
    create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes:)
  end

  def expect_successful_email_response
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body.keys).to contain_exactly("success", "email")
    expect(response.parsed_body["success"]).to be(true)
    expect(response.parsed_body.fetch("email").keys).to contain_exactly(*EMAIL_RESPONSE_KEYS)
  end

  def expect_bad_request(message)
    expect(response).to have_http_status(:bad_request)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("status" => 400, "error" => message)
  end

  def expect_missing_record(name)
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq(
      "success" => false,
      "message" => "The #{name} was not found."
    )
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

    it "adds one email without replacing siblings, changing workflow state, or querying analytics" do
      token = create_access_token("edit_emails")
      existing_email = create(:workflow_installment, workflow: @workflow, seller: @user, link: nil)
      published_at = @workflow.published_at
      allow(EmailEngagementDynamoStore).to receive(:summaries).and_raise("analytics unavailable")

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

      expect_successful_email_response
      expect(response.parsed_body.fetch("email")).to include(
        "id" => created_email.external_id,
        "subject" => "Week four",
        "message" => "<p>Keep going.</p>",
        "state" => Installment::DRAFT,
        "delay" => { "amount" => 4, "unit" => InstallmentRule::WEEK },
        "sent_count" => 0,
        "open_count" => nil,
        "open_rate" => nil,
        "click_count" => nil,
        "click_rate" => nil,
      )
    end

    it "activates and schedules a new email on a published workflow without changing workflow state" do
      token = create_access_token("edit_emails")
      published_at = 2.days.ago.change(usec: 0)
      @workflow.update!(published_at:, first_published_at: published_at)

      expect do
        post @action, params: @params.merge(access_token: token.token)
      end.to change(WorkflowInstallmentScheduleIntent, :count).by(1)

      created_email = @workflow.installments.alive.sole
      expect(created_email.published_at).to be > published_at
      expect(created_email).to be_workflow_installment_published_once_already
      expect(@workflow.reload.published_at).to eq(published_at)
      expect_successful_email_response
      expect(response.parsed_body.dig("email", "state")).to eq(Installment::PUBLISHED)
    end

    it "does not add an email to an abandoned cart workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:abandoned_cart_workflow, seller: @user)

      expect do
        post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)
      end.not_to change { workflow.installments.alive.count }

      expect_bad_request("Emails cannot be added to abandoned cart workflows.")
    end

    it "does not add an email to another seller's workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:audience_workflow, seller: create(:user))

      post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)

      expect_missing_record("workflow")
      expect(workflow.installments.alive).to be_empty
    end

    it "does not add an email after the workflow product changes owner" do
      token = create_access_token("edit_emails")
      product = create(:product)
      workflow = create(:workflow, seller: @user, link: product, workflow_type: Workflow::PRODUCT_TYPE)

      post @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)

      expect_missing_record("workflow")
      expect(workflow.installments.alive).to be_empty
    end

    it "requires every create parameter" do
      token = create_access_token("edit_emails")

      Api::V2::Workflows::EmailsController::WRITE_PARAMS.each do |name|
        post @action, params: @params.except(name).merge(access_token: token.token)

        expect_bad_request("#{name} is required.")
      end
      expect(@workflow.installments.alive).to be_empty
    end

    it "rejects invalid subjects and bodies" do
      token = create_access_token("edit_emails")
      invalid_values = [
        [@params.merge(subject: "  "), "subject must be a non-empty string."],
        [@params.merge(subject: ["Invalid subject"]), "subject must be a non-empty string."],
        [@params.merge(body: { html: "<p>Body</p>" }), "body must be a string."],
      ]

      invalid_values.each do |request_params, message|
        post @action, params: request_params.merge(access_token: token.token)

        expect_bad_request(message)
      end
      expect(@workflow.installments.alive).to be_empty
    end

    it "rejects invalid delays" do
      token = create_access_token("edit_emails")
      invalid_delays = [
        [@params.merge(delay_amount: -1), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_amount: 1.5), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_amount: "1.5"), "delay_amount must be a non-negative integer."],
        [@params.merge(delay_unit: "year"), "delay_unit must be one of: hour, day, week, month."],
        [@params.merge(delay_amount: "01720440", delay_unit: InstallmentRule::HOUR), "delay is too large."],
        [
          @params.merge(
            delay_amount: Api::V2::Workflows::EmailsController::MAX_DELAY_SECONDS + 1,
            delay_unit: InstallmentRule::HOUR
          ),
          "delay is too large.",
        ],
      ]

      invalid_delays.each do |request_params, message|
        post @action, params: request_params.merge(access_token: token.token)

        expect_bad_request(message)
      end
      expect(@workflow.installments.alive).to be_empty
    end

    it "rejects every workflow state parameter even when its value is false or null" do
      token = create_access_token("edit_emails")
      values = [true, false, nil]

      Api::V2::Workflows::EmailsController::WORKFLOW_STATE_PARAMS.each_with_index do |name, index|
        post @action, params: @params.merge(access_token: token.token, name => values[index % values.size])

        expect_bad_request("#{name} cannot be changed through this endpoint.")
      end
      expect(@workflow.installments.alive).to be_empty
    end

    it "grants create access with the account scope used by the CLI" do
      token = create_access_token("account")

      post @action, params: @params.merge(access_token: token.token)

      expect_successful_email_response
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
        customer_count: 12,
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

    it "updates only supplied fields without replacing siblings, files, state, or querying analytics" do
      token = create_access_token("edit_emails")
      sibling = create(:workflow_installment, workflow: @workflow, seller: @user, link: nil)
      file = create(:product_file, installment: @email, link: nil)
      allow(EmailEngagementDynamoStore).to receive(:summaries).and_raise("analytics unavailable")

      put @action, params: @params.merge(access_token: token.token)

      expect(@email.reload).to have_attributes(name: "Original subject", message: "<p>Updated body</p>")
      expect(@email.installment_rule).to have_attributes(
        delayed_delivery_time: 1.day.to_i,
        time_period: InstallmentRule::DAY,
      )
      expect(@email.alive_product_files).to contain_exactly(file)
      expect(sibling.reload).to be_alive

      expect_successful_email_response
      expect(response.parsed_body.fetch("email")).to include(
        "id" => @email.external_id,
        "subject" => "Original subject",
        "message" => "<p>Updated body</p>",
        "delay" => { "amount" => 1, "unit" => InstallmentRule::DAY },
        "sent_count" => 12,
        "open_count" => nil,
        "open_rate" => nil,
        "click_count" => nil,
        "click_rate" => nil,
      )
    end

    it "reschedules a published email after a delay change without changing publication state" do
      token = create_access_token("edit_emails")
      workflow_published_at = 2.days.ago.change(usec: 0)
      email_published_at = 1.day.ago.change(usec: 0)
      @workflow.update!(published_at: workflow_published_at, first_published_at: workflow_published_at)
      @email.update!(published_at: email_published_at, workflow_installment_published_once_already: true)
      @email.update_column(:updated_at, 3.days.ago)

      expect do
        put @action, params: @params.except(:body).merge(
          access_token: token.token,
          delay_amount: 2,
          delay_unit: InstallmentRule::WEEK,
        )
      end.to change(WorkflowInstallmentScheduleIntent, :count).by(1)

      expect(@email.reload.installment_rule).to have_attributes(
        delayed_delivery_time: 2.weeks.to_i,
        time_period: InstallmentRule::WEEK,
      )
      expect(@email.published_at).to eq(email_published_at)
      expect(@workflow.reload.published_at).to eq(workflow_published_at)
      expect_successful_email_response
      expect(response.parsed_body.dig("email", "state")).to eq(Installment::PUBLISHED)
      expect(Time.zone.parse(response.parsed_body.dig("email", "updated_at"))).to be_within(0.001).of(
        @email.installment_rule.updated_at
      )
    end

    it "does not update an email through another workflow" do
      token = create_access_token("edit_emails")
      workflow = create(:audience_workflow, seller: @user)

      expect do
        put @action, params: @params.merge(access_token: token.token, workflow_id: workflow.external_id)
      end.not_to change { workflow.installments.alive.count }

      expect_missing_record("email")
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not update through an unknown workflow" do
      token = create_access_token("edit_emails")

      expect do
        put @action, params: @params.merge(access_token: token.token, workflow_id: "unknown")
      end.not_to change(Installment, :count)

      expect_missing_record("workflow")
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not create an email for an unknown email ID" do
      token = create_access_token("edit_emails")

      expect do
        put @action, params: @params.merge(access_token: token.token, email_id: "unknown")
      end.not_to change { @workflow.installments.alive.count }

      expect_missing_record("email")
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "does not update a deleted email" do
      token = create_access_token("edit_emails")
      @email.update!(deleted_at: Time.current)

      put @action, params: @params.merge(access_token: token.token)

      expect_missing_record("email")
    end

    it "requires at least one write parameter" do
      token = create_access_token("edit_emails")

      put @action, params: @params.except(:body).merge(access_token: token.token)

      expect_bad_request("Provide at least one of: subject, body, delay_amount, or delay_unit.")
    end

    it "rejects invalid sparse values and partial delays" do
      token = create_access_token("edit_emails")
      invalid_values = [
        [@params.merge(subject: ""), "subject must be a non-empty string."],
        [@params.merge(body: ["Invalid body"]), "body must be a string."],
        [@params.except(:body).merge(delay_amount: 2), "delay_amount and delay_unit must be provided together."],
        [@params.except(:body).merge(delay_unit: InstallmentRule::DAY), "delay_amount and delay_unit must be provided together."],
      ]

      invalid_values.each do |request_params, message|
        put @action, params: request_params.merge(access_token: token.token)

        expect_bad_request(message)
      end
      expect(@email.reload.message).to eq("<p>Original body</p>")
      expect(@email.installment_rule.delayed_delivery_time).to eq(1.day.to_i)
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

      expect_bad_request("delay cannot be changed for abandoned cart workflows.")
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

      expect_successful_email_response
      expect(email.reload.message).to eq("<p>Complete your purchase.</p><product-list-placeholder></product-list-placeholder>")
    end

    it "rejects every workflow state parameter even when its value is false or null" do
      token = create_access_token("edit_emails")
      values = [true, false, nil]

      Api::V2::Workflows::EmailsController::WORKFLOW_STATE_PARAMS.each_with_index do |name, index|
        put @action, params: @params.merge(access_token: token.token, name => values[index % values.size])

        expect_bad_request("#{name} cannot be changed through this endpoint.")
      end
      expect(@email.reload.message).to eq("<p>Original body</p>")
    end

    it "rejects malformed upsell data in the body" do
      token = create_access_token("edit_emails")
      product = create(:product, user: @user)

      put @action, params: @params.merge(
        access_token: token.token,
        body: %(<upsell-card productid="#{product.external_id}" discount="{"></upsell-card>),
      )

      expect_bad_request("Content contains invalid upsell data.")
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

      expect_bad_request("Content contains invalid upsell data.")
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

      expect_bad_request("The offered product must belong to the current seller.")
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

      expect_bad_request("The email was not found.")
    end

    it "grants update access with the account scope used by the CLI" do
      token = create_access_token("account")

      put @action, params: @params.merge(access_token: token.token)

      expect_successful_email_response
      expect(@email.reload.message).to eq("<p>Updated body</p>")
    end
  end
end
