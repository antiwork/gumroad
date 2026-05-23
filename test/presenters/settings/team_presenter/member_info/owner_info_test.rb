# frozen_string_literal: true

require "test_helper"

class SettingsTeamPresenterMemberInfoOwnerInfoTest < ActiveSupport::TestCase
  self.described_class = Settings::TeamPresenter::MemberInfo::OwnerInfo



  context_ Settings::TeamPresenter::MemberInfo::OwnerInfo do
    let(:seller) { create(:named_seller) }

  context_ ".build_owner_info" do
  test "returns correct info" do
        info = Settings::TeamPresenter::MemberInfo.build_owner_info(seller)
        expect(info.to_hash).to eq({
                                     type: "owner",
                                     id: seller.external_id,
                                     role: "owner",
                                     name: seller.display_name,
                                     email: seller.form_email,
                                     avatar_url: seller.avatar_url,
                                     is_expired: false,
                                     options: [{
                                       id: "owner",
                                       label: "Owner"
                                     }],
                                     leave_team_option: nil
                                   })
      end
    end
  end
end
