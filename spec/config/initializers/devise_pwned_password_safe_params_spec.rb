# frozen_string_literal: true

require "spec_helper"

describe "devise-pwned_password OAuth-safe after_set_user wrap" do
  let(:user) { build(:user) }
  let(:request_params) { ActiveSupport::HashWithIndifferentAccess.new }
  let(:request) { instance_double(ActionDispatch::Request, params: request_params) }
  let(:warden) { double("Warden::Proxy", request:, authenticated?: true) }

  before do
    allow(user).to receive(:password_pwned?).and_return(false)
  end

  def pwned_hook
    pair = Warden::Manager._after_set_user.find do |block, _conditions|
      block.source_location&.first&.include?("devise_pwned_password_safe_params.rb")
    end
    raise "pwned-password wrap not installed" unless pair

    pair[0]
  end

  def run_pwned_hook
    pwned_hook.call(user, warden, { scope: :user, event: :authentication })
  end

  it "replaces the gem after_set_user hook with the wrap" do
    sources = Warden::Manager._after_set_user.map { |block, _| block.source_location&.first }
    expect(sources.grep(/devise_pwned_password_safe_params\.rb/).size).to eq(1)
    expect(sources.grep(%r{devise/pwned_password/hooks/pwned_password})).to be_empty
  end

  it "does not 500 when params[:user] is a JSON string" do
    request_params["user"] = '{"email":"jane@example.com"}'

    expect { run_pwned_hook }.not_to raise_error
    expect(user).not_to have_received(:password_pwned?)
  end

  it "does not 500 when params[:user] is an Array" do
    request_params["user"] = ["not-a-hash"]

    expect { run_pwned_hook }.not_to raise_error
    expect(user).not_to have_received(:password_pwned?)
  end

  it "still checks pwned passwords when params[:user] is a Hash" do
    request_params["user"] = { "password" => "secret-pass" }

    run_pwned_hook

    expect(user).to have_received(:password_pwned?).with("secret-pass")
  end
end
