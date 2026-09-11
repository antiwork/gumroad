# frozen_string_literal: true

require "spec_helper"

describe "devise-pwned_password OAuth-safe after_set_user wrap" do
  let(:user_class) do
    Class.new do
      def self.pwned_password_check_on_sign_in
        true
      end
    end
  end

  let(:user) do
    instance = Object.new
    klass = user_class
    instance.define_singleton_method(:class) { klass }
    instance.define_singleton_method(:password_pwned?) do |password|
      @pwned_password_checked = password
      false
    end
    instance.define_singleton_method(:pwned_password_checked) { @pwned_password_checked }
    instance
  end

  let(:request_params) { ActiveSupport::HashWithIndifferentAccess.new }

  let(:auth) do
    request = instance_double(ActionDispatch::Request, params: request_params)
    Object.new.tap do |proxy|
      proxy.define_singleton_method(:request) { request }
      proxy.define_singleton_method(:session) { @session ||= {} }
      proxy.define_singleton_method(:authenticated?) { |_scope| true }
    end
  end

  def run_after_set_user
    Warden::Manager._run_callbacks(:after_set_user, user, auth, { scope: :user, event: :authentication })
  end

  it "does not 500 when params[:user] is a JSON string" do
    request_params["user"] = '{"email":"jane@example.com"}'

    expect { run_after_set_user }.not_to raise_error
    expect(user.pwned_password_checked).to be_nil
  end

  it "does not 500 when params[:user] is an Array" do
    request_params["user"] = ["not-a-hash"]

    expect { run_after_set_user }.not_to raise_error
    expect(user.pwned_password_checked).to be_nil
  end

  it "still checks pwned passwords when params[:user] is a Hash" do
    request_params["user"] = { "password" => "secret-pass" }

    expect { run_after_set_user }.not_to raise_error
    expect(user.pwned_password_checked).to eq("secret-pass")
  end
end
