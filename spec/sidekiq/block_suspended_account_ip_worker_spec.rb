# frozen_string_literal: true

describe BlockSuspendedAccountIpWorker do
  describe "#perform" do
    before do
      @user = create(:user, last_sign_in_ip: "10.2.2.2")
      @user1 = create(:user, last_sign_in_ip: "10.2.2.2")
      @no_ip_user = create(:user, last_sign_in_ip: nil)
    end

    it "adds the sellers ip to the BlockedObject table if last_sign_in_ip is present" do
      described_class.new.perform(@user.id)

      blocked_object = BlockedObject.find_by(object_value: @user.last_sign_in_ip)
      expect(blocked_object).to_not be(nil)
      expect(blocked_object.expires_at).to eq(
        blocked_object.blocked_at + BlockedObject::IP_ADDRESS_BLOCKING_DURATION_IN_MONTHS.months
      )
    end

    it "does nothing if last_sign_in_ip is not present" do
      described_class.new.perform(@no_ip_user.id)

      expect(BlockedObject.find_by(object_value: @no_ip_user.last_sign_in_ip)).to be(nil)
    end

    it "does nothing if there is a compliant user with same last_sign_in_ip" do
      @user1.mark_compliant!(author_name: "iffy")

      described_class.new.perform(@user.id)

      expect(BlockedObject.find_by(object_value: @user.last_sign_in_ip)).to be(nil)
    end
  end
end
