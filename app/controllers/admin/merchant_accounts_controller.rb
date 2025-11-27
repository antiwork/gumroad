# frozen_string_literal: true

class Admin::MerchantAccountsController < Admin::BaseController
  def show
    if params[:id].to_i.to_s == params[:id] && merchant_account = MerchantAccount.find_by(id: params[:id])
      return redirect_to admin_merchant_account_path(merchant_account.external_id)
    end

    @merchant_account = MerchantAccount.find_by_external_id(params[:id]) || MerchantAccount.find_by(charge_processor_merchant_id: params[:id]) || e404
    @title = "Merchant Account #{@merchant_account.id}"
    render inertia: "Admin/MerchantAccounts/Show", props: { merchant_account: Admin::MerchantAccountPresenter.new(merchant_account: @merchant_account).props }
  end
end
