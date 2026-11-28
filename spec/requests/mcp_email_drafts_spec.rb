# frozen_string_literal: true

require "spec_helper"

describe "MCP email and workflow drafts" do
  before do
    @seller = create(:user)
    @app = create(:oauth_application, owner: create(:user))
    @product = create(:product, user: @seller, name: "Field notes", price_cents: 1900)
    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @seller.id, scopes: "edit_emails")
    # The audience count reads Elasticsearch; these specs are about the MCP tools, not the count.
    allow(AudienceMember).to receive(:filter_count).and_return(0)
  end

  def call_tool(name, arguments = {})
    post "/muse/v1/mcp",
         params: { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name:, arguments: } }.to_json,
         headers: { "CONTENT_TYPE" => "application/json", "HOST" => DOMAIN, "ACCEPT" => "application/json, text/event-stream", "Authorization" => "Bearer #{@token.token}" }
    response.parsed_body
  end

  def content(body) = body.dig("result", "structuredContent")
  def tool_error(body) = body.dig("result", "isError") && body.dig("result", "content", 0, "text")

  describe "create_draft_email" do
    it "saves a draft to everyone without sending it" do
      expect(SendPostBlastEmailsJob).not_to receive(:perform_async)

      email = content(call_tool("create_draft_email", { subject: "New chapter", body: "<p>It is out.</p>" }))["email"]

      expect(email).to include("subject" => "New chapter", "audience" => "everyone", "state" => "draft")
      expect(email["edit_url"]).to end_with("/emails/#{email["id"]}/edit")
      installment = Installment.find_by_external_id(email["id"])
      expect(installment).to have_attributes(seller: @seller, message: "<p>It is out.</p>", published_at: nil, ready_to_publish: false)
      expect(PostEmailBlast.count).to eq(0)
    end

    it "writes to the buyers of one product" do
      email = content(call_tool("create_draft_email", { subject: "Update", body: "<p>Hi</p>", audience: "product", product_id: @product.unique_permalink }))["email"]

      expect(email).to include("audience" => "product", "product_id" => @product.external_id)
      expect(Installment.find_by_external_id(email["id"]).bought_products).to eq([@product.unique_permalink])
    end

    it "asks for a product when the audience is product" do
      expect(call_tool("create_draft_email", { subject: "Update", body: "<p>Hi</p>", audience: "product" }).dig("error", "message")).to eq("product_id is required for audience product")
    end

    it "refuses another creator's product" do
      other = create(:product)

      expect(tool_error(call_tool("create_draft_email", { subject: "Update", body: "<p>Hi</p>", audience: "product", product_id: other.unique_permalink }))).to eq("The product was not found.")
    end

    it "needs the edit_emails scope" do
      @token.update!(scopes: "edit_products")

      expect(call_tool("create_draft_email", { subject: "Update", body: "<p>Hi</p>" }).dig("error", "message")).to include("edit_emails")
      expect(Installment.count).to eq(0)
    end
  end

  describe "update_draft_email" do
    it "changes the subject and body of a draft" do
      id = content(call_tool("create_draft_email", { subject: "Draft", body: "<p>One</p>" }))["email"]["id"]

      email = content(call_tool("update_draft_email", { id:, subject: "Final", body: "<p>Two</p>" }))["email"]

      expect(email).to include("subject" => "Final", "state" => "draft")
      expect(Installment.find_by_external_id(id).message).to eq("<p>Two</p>")
    end

    it "leaves a sent email alone" do
      sent = create(:installment, seller: @seller, installment_type: Installment::AUDIENCE_TYPE, name: "Sent", published_at: 1.day.ago)

      expect(tool_error(call_tool("update_draft_email", { id: sent.external_id, subject: "Changed" }))).to eq("This email is published. Change it in Gumroad.")
      expect(sent.reload.name).to eq("Sent")
    end
  end

  describe "list_emails" do
    it "lists the creator's emails by state" do
      draft_id = content(call_tool("create_draft_email", { subject: "Draft", body: "<p>One</p>" }))["email"]["id"]
      create(:installment, seller: @seller, installment_type: Installment::AUDIENCE_TYPE, name: "Sent", published_at: 1.day.ago)

      expect(content(call_tool("list_emails"))["emails"].map { _1["subject"] }).to contain_exactly("Draft", "Sent")
      expect(content(call_tool("list_emails", { state: "draft" }))["emails"].map { _1["id"] }).to eq([draft_id])
    end
  end

  describe "create_draft_workflow" do
    let(:emails) do
      [
        { subject: "Welcome", body: "<p>Thanks for buying.</p>", delay_amount: 0, delay_unit: "hour" },
        { subject: "Tips", body: "<p>Three tips.</p>", delay_amount: 3, delay_unit: "day" }
      ]
    end

    it "saves an unpublished workflow with its emails in order" do
      workflow = content(call_tool("create_draft_workflow", { name: "Onboarding", audience: "product", product_id: @product.unique_permalink, emails: }))["workflow"]

      expect(workflow).to include("name" => "Onboarding", "audience" => "product", "product_id" => @product.external_id, "published" => false)
      expect(workflow["emails"].map { _1.slice("subject", "delay_amount", "delay_unit") }).to eq([
                                                                                                   { "subject" => "Welcome", "delay_amount" => 0, "delay_unit" => "hour" },
                                                                                                   { "subject" => "Tips", "delay_amount" => 3, "delay_unit" => "day" }
                                                                                                 ])
      record = Workflow.find_by_external_id(workflow["id"])
      expect(record).to have_attributes(seller: @seller, published_at: nil, link: @product)
      expect(record.alive_installments.map(&:published_at)).to all(be_nil)
    end

    it "defaults to all customers" do
      workflow = content(call_tool("create_draft_workflow", { name: "Onboarding", emails: }))["workflow"]

      expect(workflow["audience"]).to eq("customers")
    end

    it "saves nothing when an email is invalid" do
      body = call_tool("create_draft_workflow", { name: "Onboarding", emails: [emails.first.merge(delay_unit: "year")] })

      expect(body.dig("error", "message")).to eq("emails[0].delay_unit must be one of: hour, day, week, month")
      expect(Workflow.count).to eq(0)
    end

    it "lists it in list_workflows" do
      id = content(call_tool("create_draft_workflow", { name: "Onboarding", emails: }))["workflow"]["id"]

      workflows = content(call_tool("list_workflows"))["workflows"]
      expect(workflows.map { _1["id"] }).to eq([id])
      expect(workflows.first["edit_url"]).to include("/workflows/#{id}/emails")
    end
  end
end
