# frozen_string_literal: true

require "spec_helper"

describe OauthApplication do
  describe "validity" do
    before do
      @user = create(:user)
    end

    it "does not validate name uniqueness" do
      create(:oauth_application, owner: @user, name: :foo)
      expect(build(:oauth_application, owner: @user, name: :foo)).to be_valid
    end

    it "allows 2 applications to be created with the same name" do
      create(:oauth_application, owner: @user, name: :foo)
      create(:oauth_application, owner: @user, name: :foo)
      expect(OauthApplication.count).to eq 2
    end

    it "allows applications to be created with affiliate_basis_points in an acceptable range" do
      create(:oauth_application, owner: @user, name: :foo, affiliate_basis_points: 1)
      create(:oauth_application, owner: @user, name: :foo, affiliate_basis_points: 6999)
      expect(OauthApplication.count).to eq 2
    end

    it "does not allow applications to be created with invalid affiliate_basis_points" do
      invalid_app_1 = build(:oauth_application, owner: @user, name: :foo, affiliate_basis_points: -1)
      expect(invalid_app_1).to be_invalid
      invalid_app_2 = build(:oauth_application, owner: @user, name: :foo, affiliate_basis_points: 7001)
      expect(invalid_app_2).to be_invalid
    end
  end

  describe "#validate_file" do
    it "saves with no icons attached" do
      oauth_application = create(:oauth_application)
      expect(oauth_application.save).to eq(true)
      expect(oauth_application.errors.full_messages).to be_empty
    end

    it "saves with a valid icon type attached" do
      oauth_application = create(:oauth_application)
      oauth_application.file.attach(fixture_file_upload("smilie.png"))
      expect(oauth_application.save).to eq(true)
      expect(oauth_application.errors.full_messages).to be_empty
    end

    it "errors with invalid icon type attached" do
      oauth_application = create(:oauth_application)
      oauth_application.file.attach(fixture_file_upload("test-svg.svg"))
      expect(oauth_application.save).to eq(false)
      expect(oauth_application.errors.full_messages).to eq(["Invalid image type for icon, please try again."])
    end
  end

  describe "Doorkeeper scopes" do
    before do
      @oauth_application = create(:oauth_application)
    end

    let(:doorkeeper_scopes) { Doorkeeper.configuration.scopes.map(&:to_sym) }
    let(:default_scopes) { Doorkeeper.configuration.default_scopes.map(&:to_sym) }
    let(:public_scopes) { Doorkeeper.configuration.public_scopes.map(&:to_sym) }
    let(:private_scopes) { %i[refund_sales mobile_api creator_api helper_api unfurl] }

    it "all public scopes are included in Doorkeeper's scopes" do
      public_scopes.each do |scope|
        expect(doorkeeper_scopes).to include(scope)
      end
    end

    it "all private scopes are included in Doorkeeper's scopes" do
      private_scopes.each do |scope|
        expect(doorkeeper_scopes).to include(scope)
      end
    end

    it "defines private scopes as neither public nor default" do
      expect(private_scopes).to match_array(doorkeeper_scopes - public_scopes - default_scopes)
    end

    it "includes public scopes in user-created applications" do
      public_scopes.each do |scope|
        expect(@oauth_application.scopes).to include(scope.to_s)
      end
    end

    it "does not include default scopes in user-created applications" do
      default_scopes.each do |scope|
        expect(@oauth_application.scopes).not_to include(scope.to_s)
      end
    end

    it "does not include private scopes in user-created applications" do
      private_scopes.each do |scope|
        expect(@oauth_application.scopes).not_to include(scope.to_s)
      end
    end
  end

  describe "#get_or_generate_access_token" do
    before do
      @oauth_application = create(:oauth_application)
    end

    it "generates new access token if none exist" do
      expect do
        access_token = @oauth_application.get_or_generate_access_token
        expect(access_token.scopes).to eq(Doorkeeper.configuration.public_scopes)
      end.to change(Doorkeeper::AccessToken, :count).by(1)
    end

    it "generates new access token if existing ones are revoked" do
      @oauth_application.get_or_generate_access_token
      Doorkeeper::AccessToken.revoke_all_for(@oauth_application.id, @oauth_application.owner)
      expect(@oauth_application.access_tokens.count).to eq(1)

      expect do
        access_token = @oauth_application.get_or_generate_access_token
        expect(access_token.revoked?).to be_falsey
      end.to change(Doorkeeper::AccessToken, :count).by(1)
    end

    it "returns an existing non-revoked access token if one exists" do
      @oauth_application.get_or_generate_access_token

      expect do
        @oauth_application.get_or_generate_access_token
      end.to_not change(Doorkeeper::AccessToken, :count)
    end

    context "when no access grant exists" do
      it "creates an access grant automatically" do
        expect(@oauth_application.access_grants.count).to eq(0)

        expect do
          @oauth_application.get_or_generate_access_token
        end.to change(Doorkeeper::AccessGrant, :count).by(1)

        expect(@oauth_application.access_grants.last.expires_in).to eq(60.years)
      end
    end

    context "when access grant already exists" do
      before do
        @oauth_application.get_or_generate_access_token # this will generate the access grant
      end

      it "does not create another access grant" do
        expect(@oauth_application.access_grants.count).to eq(1)

        expect do
          @oauth_application.get_or_generate_access_token
        end.to_not change(Doorkeeper::AccessGrant, :count)
      end
    end
  end

  describe "#mark_deleted!" do
    before do
      @oauth_application = create(:oauth_application)
      @oauth_application.get_or_generate_access_token
      create(:resource_subscription, oauth_application: @oauth_application)
    end

    it "marks connected resource subscription as deleted" do
      expect do
        @oauth_application.mark_deleted!
      end.to change { ResourceSubscription.alive.count }.by(-1)

      expect(@oauth_application.resource_subscriptions.alive.count).to eq(0)
    end

    it "revokes access grants" do
      expect do
        @oauth_application.mark_deleted!
      end.to change { @oauth_application.access_grants.where(revoked_at: nil).count }.by(-1)

      expect(@oauth_application.access_grants).to all be_revoked
    end

    it "marks multiple resource subscriptions as deleted in bulk" do
      create_list(:resource_subscription, 3, oauth_application: @oauth_application)

      expect do
        @oauth_application.mark_deleted!
      end.to change { @oauth_application.resource_subscriptions.alive.count }.from(4).to(0)

      @oauth_application.resource_subscriptions.each do |rs|
        expect(rs.deleted_at).to be_present
      end
    end

    it "revokes access tokens" do
      expect do
        @oauth_application.mark_deleted!
      end.to change { @oauth_application.access_tokens.where(revoked_at: nil).count }.by(-1)

      expect(@oauth_application.access_tokens).to all be_revoked
    end

    it "denies outstanding device authorizations" do
      pending_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        status: OauthDeviceAuthorization::STATUS_PENDING,
        device_code: "pending-deleted-app",
        user_code: "GRD-PEND-DEL1"
      )
      approved_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        status: OauthDeviceAuthorization::STATUS_APPROVED,
        device_code: "approved-deleted-app",
        user_code: "GRD-APPR-DEL1"
      )
      consumed_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        status: OauthDeviceAuthorization::STATUS_CONSUMED,
        device_code: "consumed-deleted-app",
        user_code: "GRD-CONS-DEL1"
      )
      denied_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        status: OauthDeviceAuthorization::STATUS_DENIED,
        denied_at: 1.day.ago,
        device_code: "denied-deleted-app",
        user_code: "GRD-DENY-DEL1"
      )

      @oauth_application.mark_deleted!

      expect(pending_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, denied_at: be_present)
      expect(approved_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, denied_at: be_present)
      expect(consumed_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_CONSUMED, denied_at: nil)
      expect(denied_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, denied_at: be_present)
    end
  end

  describe "#revoke_access_for" do
    before do
      @oauth_application = create(:oauth_application)

      @subscriber_1 = create(:user)
      create("doorkeeper/access_token", application: @oauth_application, resource_owner_id: @subscriber_1.id, scopes: "view_sales")
      create(:resource_subscription, oauth_application: @oauth_application, user: @subscriber_1)

      @subscriber_2 = create(:user)
      create("doorkeeper/access_token", application: @oauth_application, resource_owner_id: @subscriber_2.id, scopes: "view_sales")
      create(:resource_subscription, oauth_application: @oauth_application, user: @subscriber_2)
    end

    it "revokes user's access" do
      expect do
        @oauth_application.revoke_access_for(@subscriber_1)
      end.to change { Doorkeeper::AccessToken.where(revoked_at: nil).count }.by(-1)

      expect(OauthApplication.authorized_for(@subscriber_1).count).to eq(0)
      expect(OauthApplication.authorized_for(@subscriber_2).count).to eq(1)
    end

    it "removes resource subscriptions for the user" do
      expect do
        @oauth_application.revoke_access_for(@subscriber_1)
      end.to change { ResourceSubscription.alive.count }.by(-1)

      expect(@oauth_application.resource_subscriptions.where(user: @subscriber_1).alive.count).to eq(0)
      expect(@oauth_application.resource_subscriptions.where(user: @subscriber_2).alive.count).to eq(1)
    end

    it "denies approved device authorizations for the user" do
      pending_authorization_with_owner = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        resource_owner: @subscriber_1,
        status: OauthDeviceAuthorization::STATUS_PENDING,
        device_code: "pending-subscriber-1",
        user_code: "GRD-PEN1-0001"
      )
      approved_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        resource_owner: @subscriber_1,
        status: OauthDeviceAuthorization::STATUS_APPROVED,
        device_code: "approved-subscriber-1",
        user_code: "GRD-APP1-0001"
      )
      other_user_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        resource_owner: @subscriber_2,
        status: OauthDeviceAuthorization::STATUS_APPROVED,
        device_code: "approved-subscriber-2",
        user_code: "GRD-APP2-0001"
      )
      unauthenticated_pending_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        status: OauthDeviceAuthorization::STATUS_PENDING,
        device_code: "pending-unauthenticated",
        user_code: "GRD-PEND-0000"
      )

      @oauth_application.revoke_access_for(@subscriber_1)

      expect(pending_authorization_with_owner.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, denied_at: nil)
      expect(approved_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, denied_at: be_present)
      expect(other_user_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_APPROVED, denied_at: nil)
      expect(unauthenticated_pending_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_PENDING, denied_at: nil)
    end

    it "does not mint a device token if the client polls while access is being revoked" do
      device_authorization = create(
        :oauth_device_authorization,
        oauth_application: @oauth_application,
        resource_owner: @subscriber_1,
        status: OauthDeviceAuthorization::STATUS_APPROVED
      )
      poll_result = nil

      expect(Doorkeeper::AccessToken).to receive(:revoke_all_for).with(@oauth_application.id, @subscriber_1).and_wrap_original do |method, *args|
        expect do
          poll_result = device_authorization.reload.poll!(
            oauth_application: @oauth_application,
            ip_address: "203.0.113.20",
            user_agent: "RSpec"
          )
        end.not_to change { Doorkeeper::AccessToken.count }

        method.call(*args)
      end

      @oauth_application.revoke_access_for(@subscriber_1)

      expect(poll_result).to eq([OauthDeviceAuthorization::POLL_ACCESS_DENIED, nil])
      expect(device_authorization.reload).to have_attributes(status: OauthDeviceAuthorization::STATUS_DENIED, access_token: nil)
    end
  end
end
