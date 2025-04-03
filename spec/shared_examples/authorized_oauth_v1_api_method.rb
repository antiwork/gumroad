# frozen_string_literal: true

require "spec_helper"

RSpec.shared_examples_for "authorized oauth v1 api method" do
  it "errors out if you aren't authenticated" do
    raise "no @action in before block of test" unless @action
    raise "no @params in before block of test" unless @params

    get @action, params: @params
    expect(response.status).to eq(401)
    expect(response.body.strip).to be_empty
  end
end

RSpec.shared_examples_for "authorized oauth v1 api method only for edit_products scope" do
  it "errors out if you aren't authenticated" do
    raise "no @action in before block of test" unless @action
    raise "no @params in before block of test" unless @params
    raise "no @app in before block of test" unless @app
    raise "no @user in before block of test" unless @user

    @token = create("doorkeeper/access_token", application: @app, resource_owner_id: @user.id, scopes: "view_public view_sales")
    get @action, params: @params.merge(access_token: @token.token)
    expect(response.status).to eq(403)
    expect(response.body.strip).to be_empty
  end
end
