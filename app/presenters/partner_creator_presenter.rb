# frozen_string_literal: true

# Public identity of a partner creator: the partner's own user ID plus the creator's public
# Gumroad profile. No email, balance or sales data.
class PartnerCreatorPresenter
  def initialize(partner_creator:)
    @partner_creator = partner_creator
  end

  def props
    user = partner_creator.user

    {
      external_user_id: partner_creator.external_user_id,
      name: user.name_or_username,
      avatar_url: user.avatar_url,
      profile_url: user.profile_url,
    }
  end

  private
    attr_reader :partner_creator
end
