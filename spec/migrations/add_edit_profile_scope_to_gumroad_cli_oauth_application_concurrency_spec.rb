# frozen_string_literal: true

require "spec_helper"
require "timeout"
require Rails.root.join("db/migrate/20261206000001_add_edit_profile_scope_to_gumroad_cli_oauth_application").to_s

describe AddEditProfileScopeToGumroadCliOauthApplication, "rollback concurrency" do
  self.use_transactional_tests = false

  before do
    @seller = create(:user)
    @oauth_application = create(
      :oauth_application,
      owner: @seller,
      uid: described_class::CLI_CLIENT_ID,
      scopes: "account edit_profile",
      confidential: false,
      device_authorization_enabled: true
    )
  end

  after do
    next if @oauth_application.nil?

    OauthDeviceAuthorization.where(oauth_application_id: @oauth_application.id).delete_all
    Doorkeeper::AccessToken.where(application_id: @oauth_application.id).delete_all
    Doorkeeper::AccessGrant.where(application_id: @oauth_application.id).delete_all
    @oauth_application.delete
    @seller.delete
  end

  it "rejects a device authorization that waits for the rollback application lock" do
    migration = described_class.new
    device_authorizations_swept = Queue.new
    release_rollback = Queue.new
    request_waiting_for_application = Queue.new
    migration_thread = nil
    request_thread = nil

    allow(migration).to receive(:revoke_scope_from_device_authorizations).and_wrap_original do |method, *args|
      method.call(*args)
      device_authorizations_swept << true
      release_rollback.pop
    end
    allow_any_instance_of(OauthApplication).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      if Thread.current[:device_code_request] && method.receiver.id == @oauth_application.id
        request_waiting_for_application << true
      end
      method.call(*args, &block)
    end

    begin
      migration_thread = start_worker { migration.down }
      wait_for(device_authorizations_swept)

      request_thread = start_worker do
        Thread.current[:device_code_request] = true
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! DOMAIN
        session.post(
          "/oauth/device/code",
          params: { client_id: @oauth_application.uid, scope: "edit_profile" },
          headers: { "REMOTE_ADDR" => "203.0.113.10", "HTTP_USER_AGENT" => "Gumroad CLI" }
        )
        [session.response.status, session.response.parsed_body]
      ensure
        Thread.current[:device_code_request] = nil
      end

      wait_for(request_waiting_for_application)
      expect(request_thread).to be_alive
    ensure
      release_rollback << true
    end

    migration_thread.value
    status, body = request_thread.value

    expect(status).to eq(400)
    expect(body).to include("error" => "invalid_scope")
    expect(OauthDeviceAuthorization.where(oauth_application_id: @oauth_application.id)).to be_empty
  ensure
    migration_thread&.kill if migration_thread&.alive?
    request_thread&.kill if request_thread&.alive?
  end

  it "rejects a refresh that waits for the rollback application lock" do
    access_token = create(
      "doorkeeper/access_token",
      application: @oauth_application,
      resource_owner_id: @seller.id,
      scopes: "account edit_profile",
      use_refresh_token: true
    )
    migration = described_class.new
    access_tokens_swept = Queue.new
    release_rollback = Queue.new
    request_waiting_for_application = Queue.new
    migration_thread = nil
    request_thread = nil

    allow(migration).to receive(:revoke_scope).and_wrap_original do |method, records, *args, **kwargs|
      method.call(records, *args, **kwargs)
      if records.table_name == Doorkeeper::AccessToken.table_name
        access_tokens_swept << true
        release_rollback.pop
      end
    end
    allow_any_instance_of(Doorkeeper.config.application_model).to receive(:with_lock).and_wrap_original do |method, *args, &block|
      if Thread.current[:refresh_token_request] && method.receiver.id == @oauth_application.id
        request_waiting_for_application << true
      end
      method.call(*args, &block)
    end

    begin
      migration_thread = start_worker { migration.down }
      wait_for(access_tokens_swept)

      request_thread = start_worker do
        Thread.current[:refresh_token_request] = true
        session = ActionDispatch::Integration::Session.new(Rails.application)
        session.host! DOMAIN
        session.post(
          "/oauth/token",
          params: {
            grant_type: "refresh_token",
            refresh_token: access_token.refresh_token,
            client_id: @oauth_application.uid,
            scope: "account edit_profile"
          }
        )
        [session.response.status, session.response.parsed_body]
      ensure
        Thread.current[:refresh_token_request] = nil
      end

      wait_for(request_waiting_for_application)
      expect(request_thread).to be_alive
    ensure
      release_rollback << true
    end

    migration_thread.value
    status, body = request_thread.value

    expect(status).to eq(400)
    expect(body).to include("error" => "invalid_scope")
    expect(access_token.reload.scopes.to_s).to eq("account")
    edit_profile_tokens = Doorkeeper::AccessToken
      .where(application_id: @oauth_application.id)
      .where("scopes LIKE ?", "%edit_profile%")
    expect(edit_profile_tokens).to be_empty
  ensure
    migration_thread&.kill if migration_thread&.alive?
    request_thread&.kill if request_thread&.alive?
  end

  def start_worker(&block)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection(&block)
    end
  end

  def wait_for(queue)
    Timeout.timeout(5) { queue.pop }
  end
end
