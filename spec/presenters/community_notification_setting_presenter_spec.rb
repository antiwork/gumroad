# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityNotificationSettingPresenter do
  let(:user) { create(:user) }
  let(:seller) { create(:user) }
  let(:settings) { create(:community_notification_setting, user:, seller:) }
  let(:presenter) { described_class.new(settings:) }

  describe "#props" do
    subject(:props) { presenter.props }

    it "returns appropriate props" do
      expect(props).to eq(recap_frequency: "daily")
    end

    context "when recap frequency is weekly" do
      let(:settings) { create(:community_notification_setting, :weekly_recap, user:, seller:) }

      it "returns weekly recap frequency" do
        expect(props[:recap_frequency]).to eq("weekly")
      end
    end

    context "when recap frequency is not set" do
      let(:settings) { create(:community_notification_setting, :no_recap, user:, seller:) }

      it "returns nil recap frequency" do
        expect(props[:recap_frequency]).to be_nil
      end
    end
  end
end
