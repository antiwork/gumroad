# frozen_string_literal: true

require "spec_helper"

# Checks that `authorize` is called with correct policy for each controller action
# Pulls all controller actions programmatically from Routes.
#
RSpec.shared_examples_for "authorize called for controller" do |policy_klass|
  controller_path = described_class.to_s.underscore.sub(/_?controller\z/, "")
  @all_routes ||= Rails.application.routes.routes.map do |route|
    OpenStruct.new(
      controller: route.defaults[:controller],
      action: route.defaults[:action],
      verb: route.verb.downcase.to_sym
    )
  end
  controller_action_infos = @all_routes.select { |route_info| route_info.controller == controller_path }

  controller_action_infos.each do |route_info|
    it_behaves_like "authorize called for action", route_info.verb, route_info.action do
      let(:policy_klass) { policy_klass }
    end
  end
end

# Checks that `authorize` is called with correct policy for a given action
# Accepted shared variables:
# * record (required)
# * policy_klass (optional)
# * policy_method (optional)
# * request_params (optional)
# * request_format (optional)
#
RSpec.shared_examples_for "authorize called for action" do |verb, action|
  it "calls authorize with correct arguments on #{verb}: #{action}" do
    klass = defined?(policy_klass) && policy_klass || Pundit::PolicyFinder.new(record).policy
    method = defined?(policy_method) ? policy_method : :"#{action}?"
    format = defined?(request_format) ? request_format : :html
    mocked_policy = instance_double(klass, method => false)
    allow(klass).to receive(:new).and_return(mocked_policy)

    public_send(verb, action, params: defined?(request_params) ? request_params : {}, as: format)
    expect(klass).to(
      have_received(:new).with(controller.pundit_user, record),
      "Expected #{klass} to be called via `authorize` with correct arguments"
    )
  end
end

# Sets `logged_in_user` as a different instance than `current_seller` for controller specs
# Accepted shared variable:
# * seller (required)
#
RSpec.shared_context "with user signed in with given role for seller" do |role|
  let(:user_with_role_for_seller) do
    identifier = "#{role}forseller"
    seller = create(:user, username: identifier, name: "#{role.to_s.humanize}ForSeller", email: "#{identifier}@example.com")
    seller
  end

  before do
    create(:team_membership, user: user_with_role_for_seller, seller:, role:)

    cookies.encrypted[:current_seller_id] = seller.id
    sign_in user_with_role_for_seller
  end
end

TeamMembership::ROLES.excluding(TeamMembership::ROLE_OWNER).each do |role|
  # Available shared contexts for controller specs:
  # include_context "with user signed in as accountant for seller"
  # include_context "with user signed in as admin for seller"
  # include_context "with user signed in as marketing for seller"
  # include_context "with user signed in as support for seller"
  #
  RSpec.shared_context "with user signed in as #{role} for seller" do
    include_context "with user signed in with given role for seller", role
  end
end

# Switches seller account to a different instance than `logged_in_user` for integration specs
# Accepted shared variable:
# * seller (required)
#
RSpec.shared_context "with switching account to user with given role for seller" do |options|
  let(:user_with_role_for_seller) do
    identifier = "#{options[:role]}forseller"
    seller = create(:user, username: identifier, name: "#{options[:role].to_s.humanize}ForSeller", email: "#{identifier}@example.com")
    seller
  end

  before do
    create(:team_membership, user: user_with_role_for_seller, seller:, role: options[:role])

    login_as user_with_role_for_seller
    visit(options[:host] ? settings_main_url(host: options[:host]) : settings_main_path)
    within "nav[aria-label='Main']" do
      toggle_disclosure(user_with_role_for_seller.name)
      choose(seller.display_name)
    end

    wait_for_ajax
    visit(options[:host] ? settings_main_url(host: options[:host]) : settings_main_path)

    within "nav[aria-label='Main']" do
      expect(page).to have_text(seller.display_name(prefer_email_over_default_username: true))
    end
  end
end

TeamMembership::ROLES.excluding(TeamMembership::ROLE_OWNER).each do |role|
  RSpec.shared_context "with switching account to user as #{role} for seller" do |options = {}|
    options.merge!(role:)

    # Available shared contexts for request specs:
    # include_context "with switching account to user as accountant for seller"
    # include_context "with switching account to user as admin for seller"
    # include_context "with switching account to user as marketing for seller"
    # include_context "with switching account to user as support for seller"
    #
    include_context "with switching account to user with given role for seller", options
  end
end
