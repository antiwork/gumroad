# frozen_string_literal: true

require "spec_helper"

describe "workflow email API routing" do
  def route_for(host, path, method)
    Rails.application.routes.recognize_path("https://#{host}#{path}", method:)
  end

  it "routes POST and PUT on both API mounts" do
    routes = [
      [API_DOMAIN, "/v2/workflows/workflow-id/emails"],
      [DOMAIN, "/api/v2/workflows/workflow-id/emails"],
    ]

    routes.each do |host, collection_path|
      expect(route_for(host, collection_path, :post)).to include(
        controller: "api/v2/workflows/emails",
        action: "create",
        workflow_id: "workflow-id",
      )
      expect(route_for(host, "#{collection_path}/email-id", :put)).to include(
        controller: "api/v2/workflows/emails",
        action: "update",
        workflow_id: "workflow-id",
        email_id: "email-id",
      )
    end
  end

  it "does not route PATCH on either API mount" do
    paths = [
      [API_DOMAIN, "/v2/workflows/workflow-id/emails/email-id"],
      [DOMAIN, "/api/v2/workflows/workflow-id/emails/email-id"],
    ]

    paths.each do |host, path|
      expect { route_for(host, path, :patch) }.to raise_error(ActionController::RoutingError)
    end
  end

  it "generates the API-domain collection and member paths" do
    helpers = Rails.application.routes.url_helpers

    expect(helpers.api_v2_workflow_emails_path("workflow-id")).to eq(
      "/v2/workflows/workflow-id/emails"
    )
    expect(helpers.api_v2_workflow_email_path("workflow-id", "email-id")).to eq(
      "/v2/workflows/workflow-id/emails/email-id"
    )
  end
end
