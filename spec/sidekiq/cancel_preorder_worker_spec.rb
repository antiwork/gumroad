# frozen_string_literal: true

require "spec_helper"

describe CancelPreorderWorker, :vcr do
  describe "perform" do
    it "cancels the preorder if it is in authorization_successful state but does not send notification emails" do
      product = create(:product)
      preorder_link = create(:preorder_link, link: product)
      preorder_link.update_attribute(:release_at, Time.current) # bypass validation
      authorization_purchase = build(:purchase, link: product, chargeable: build(:chargeable), purchase_state: "in_progress", is_preorder_authorization: true)
      preorder = preorder_link.build_preorder(authorization_purchase)
      preorder.authorize!
      preorder.mark_authorization_successful!
      expect(preorder.reload.state).to eq "authorization_successful"

      expect do
        expect do
          CancelPreorderWorker.new.perform(preorder.id)
        end.to_not have_enqueued_mail(CustomerLowPriorityMailer, :preorder_cancelled).with(preorder.id)
      end.to_not have_enqueued_mail(ContactingCreatorMailer, :preorder_cancelled).with(preorder.id)

      expect(preorder.reload.state).to eq "cancelled"
      expect(preorder.authorization_purchase.purchase_state).to eq "preorder_concluded_unsuccessfully"
    end

    it "does not cancel the preorder if it is not in authorization_successful state" do
      preorder_in_progress = create(:preorder, state: "in_progress")

      CancelPreorderWorker.new.perform(preorder_in_progress.id)
      expect(preorder_in_progress.reload.state).to eq "in_progress"

      preorder_charge_successful = create(:preorder, state: "charge_successful")

      CancelPreorderWorker.new.perform(preorder_charge_successful.id)
      expect(preorder_charge_successful.reload.state).to eq "charge_successful"
    end
  end
end
