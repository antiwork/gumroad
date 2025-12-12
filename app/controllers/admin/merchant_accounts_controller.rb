# frozen_string_literal: true

class Admin::MerchantAccountsController < Admin::BaseController
  def show
    @merchant_account = MerchantAccount.find_by(id: params[:id]) || MerchantAccount.find_by(charge_processor_merchant_id: params[:id]) || e404
    @title = "Merchant Account #{@merchant_account.id}"
    render inertia: "Admin/MerchantAccounts/Show", props: { merchant_account: Admin::MerchantAccountPresenter.new(merchant_account: @merchant_account).props }
  end
end
