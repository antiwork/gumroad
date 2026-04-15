# frozen_string_literal: true

module Admin
  class HelperActionsController < BaseController
    before_action :load_user

    def impersonate
      redirect_to admin_impersonate_path(user_identifier: @user.external_id)
    end

    def stripe_dashboard
      merchant_account = @user.merchant_accounts.alive.stripe.first

      if merchant_account&.charge_processor_merchant_id
        redirect_to "https://dashboard.stripe.com/connect/accounts/#{merchant_account.charge_processor_merchant_id}", allow_other_host: true
      else
        head :not_found
      end
    end

    private
      def load_user
        @user = User.find_by!(external_id: params[:user_external_id])
      rescue ActiveRecord::RecordNotFound
        head :not_found
      end
  end
end
