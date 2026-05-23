# frozen_string_literal: true

require "test_helper"

class CommunityNotificationSettingPresenterTest < ActiveSupport::TestCase
  self.described_class = CommunityNotificationSettingPresenter



  context_ CommunityNotificationSettingPresenter do
    let(:user) { create(:user) }
    let(:seller) { create(:user) }
    let(:settings) { create(:community_notification_setting, user:, seller:) }
    let(:presenter) { described_class.new(settings:) }

  context_ "#props" do
      subject(:props) { presenter.props }

  test "returns appropriate props" do
        expect(props).to eq(recap_frequency: "daily")
      end

  context_ "when recap frequency is weekly" do
        let(:settings) { create(:community_notification_setting, :weekly_recap, user:, seller:) }

  test "returns weekly recap frequency" do
          expect(props[:recap_frequency]).to eq("weekly")
        end
      end

  context_ "when recap frequency is not set" do
        let(:settings) { create(:community_notification_setting, :no_recap, user:, seller:) }

  test "returns nil recap frequency" do
          expect(props[:recap_frequency]).to be_nil
        end
      end
    end
  end
end
