# frozen_string_literal: true

require "spec_helper"

# Checks that a collaborator on a product can access the endpoint
# Accepted shared variables:
# * product (required)
# * request_params (optional)
# * request_format (optional)
# * response_status (optional)
# * response_attributes (optional)

RSpec.shared_examples_for "collaborator can access" do |verb, action|
  it "allows a collaborator to access #{verb} /#{action}" do
    collaborator = create(:collaborator, seller: product.user, products: [product])

    sign_in collaborator.affiliate_user

    as = defined?(request_format) ? request_format : :html
    params = defined?(request_params) ? request_params : {}
    status = defined?(response_status) ? response_status : 200

    public_send(verb, action, params:, as:)

    expect(response.status).to eq status
    expect(JSON.parse(response.body)).to include(response_attributes) if defined?(response_attributes)
  end
end
