# frozen_string_literal: true

module CurrentSeller
  extend ActiveSupport::Concern

  included do
    helper_method :current_seller

    before_action :verify_current_seller
  end

  def current_seller
    return unless user_signed_in?

    @_current_seller ||= find_seller_from_cookie(cookies.encrypted[:current_seller_id]) || reset_current_seller
  end

  def switch_seller_account(team_membership)
    team_membership.update!(last_accessed_at: Time.current)
    cookies.permanent.encrypted[:current_seller_id] = {
      value: team_membership.seller_id,
      domain: :all
    }
  end

  private
    def find_seller_from_cookie(seller_id)
      return if seller_id.nil?

      User.alive.find_by_id(seller_id)
    end

    def verify_current_seller
      # Do not destroy the cookie if the user is not signed in to remember last seller account selected
      return unless user_signed_in?

      reset_current_seller unless valid_seller?(current_seller)
    end

    def valid_seller?(seller)
      return false unless seller.present?
      return false unless logged_in_user.member_of?(seller)

      true
    end

    def reset_current_seller
      cookies.delete(:current_seller_id, domain: :all)
      # Change the seller for current request
      @_current_seller = logged_in_user
    end
end
