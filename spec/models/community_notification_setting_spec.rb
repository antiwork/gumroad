# frozen_string_literal: true

require "spec_helper"

RSpec.describe CommunityNotificationSetting do
  subject(:notification_setting) { build(:community_notification_setting) }

  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:seller).class_name("User") }
  end

  describe "validations" do
    it { is_expected.to validate_uniqueness_of(:user_id).scoped_to(:seller_id) }
    it { is_expected.to define_enum_for(:recap_frequency)
                          .with_values(daily: "daily", weekly: "weekly")
                          .backed_by_column_of_type(:string)
                          .with_prefix(:recap_frequency) }
  end
end
