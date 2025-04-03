# frozen_string_literal: true

class Settings::TeamPresenter::MemberInfo::OwnerInfo < Settings::TeamPresenter::MemberInfo
  attr_reader :user

  def initialize(user)
    @user = user
  end

  def to_hash
    role = TeamMembership::ROLE_OWNER
    {
      type: Settings::TeamPresenter::MemberInfo::TYPE_OWNER,
      id: user.external_id,
      role:,
      name: user.display_name,
      email: user.form_email,
      avatar_url: user.avatar_url,
      is_expired: false,
      options: build_options(role),
      leave_team_option: nil
    }
  end

  private
    def build_options(role)
      [{ id: role, label: role.capitalize }]
    end
end
