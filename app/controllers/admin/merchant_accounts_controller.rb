# frozen_string_literal: true

class Admin::MerchantAccountsController < Admin::BaseController
  def show
    @merchant_account = MerchantAccount.find_by_external_id(params[:external_id]) || MerchantAccount.find_by(charge_processor_merchant_id: params[:external_id]) || e404
    @title = "Merchant Account #{@merchant_account.id}"
    render inertia: "Admin/MerchantAccounts/Show", props: { merchant_account: Admin::MerchantAccountPresenter.new(merchant_account: @merchant_account).props }
  end
end
