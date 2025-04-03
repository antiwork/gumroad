# frozen_string_literal: true

describe ExpireRentalPurchasesWorker do
  describe "#perform" do
    before do
      @purchase_1 = create(:purchase, is_rental: true)
      create(:url_redirect, purchase: @purchase_1, is_rental: true, created_at: 32.days.ago)
    end

    it "updates only rental purchases" do
      purchase_2 = create(:purchase, is_rental: false)
      create(:url_redirect, purchase: purchase_2, is_rental: true, created_at: 32.days.ago)

      described_class.new.perform

      expect(@purchase_1.reload.rental_expired).to eq(true)
      expect(purchase_2.reload.rental_expired).to eq(nil)
    end

    it "updates only rental purchases with rental url redirects past expiry dates" do
      purchase_2 = create(:purchase, is_rental: true)
      purchase_3 = create(:purchase, is_rental: true)
      purchase_4 = create(:purchase, is_rental: true)
      create(:url_redirect, purchase: purchase_2, is_rental: true, created_at: 20.days.ago)
      create(:url_redirect, purchase: purchase_3, is_rental: true, rental_first_viewed_at: 80.hours.ago)
      create(:url_redirect, purchase: purchase_4, is_rental: true, rental_first_viewed_at: 50.hours.ago)

      described_class.new.perform

      expect(@purchase_1.reload.rental_expired).to eq(true)
      expect(purchase_2.reload.rental_expired).to eq(false)
      expect(purchase_3.reload.rental_expired).to eq(true)
      expect(purchase_4.reload.rental_expired).to eq(false)
    end
  end
end
