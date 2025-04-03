# frozen_string_literal: true

require "spec_helper"

describe User::Stats do
  let(:user) { create(:user) }
  let(:link) { create(:product, user:) }

  describe "average_transaction_amount_cents" do
    describe "no sales" do
      it "returns zero" do
        expect(user.average_transaction_amount_cents).to eq(0)
      end
    end

    describe "many sales" do
      before do
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
      end

      it "averages the transaction values" do
        expect(user.average_transaction_amount_cents).to eq(2_50)
      end
    end

    describe "many sales with a fractional average" do
      before do
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
        create(:purchase, link:, seller: link.user, price_cents: 6_00)
      end

      it "averages the transaction values and return an integer in cents" do
        expect(user.average_transaction_amount_cents).to eq(2_62)
      end
    end

    describe "many sales and some free" do
      before do
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
        create(:free_purchase, link:, seller: link.user)
      end

      it "averages the transaction values" do
        expect(user.average_transaction_amount_cents).to eq(2_50)
      end
    end

    describe "long time many sales" do
      before do
        travel_to(367.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 1_00)
        end
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
        create(:purchase, link:, seller: link.user, price_cents: 5_00)
      end

      it "sums up only the transaction values in the last year" do
        expect(user.average_transaction_amount_cents).to eq(3_50)
      end
    end
  end

  describe "transaction_volume_in_the_last_year" do
    before do
      travel_to(367.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
      end
      travel_to(300.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
      end
      travel_to(200.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
      end
      travel_to(100.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
      end
      create(:purchase, link:, seller: link.user, price_cents: 5_00)
    end

    it "sums up only the transaction values in the last year" do
      expect(user.transaction_volume_in_the_last_year).to eq(14_00)
    end
  end

  describe "transaction_volume_since" do
    before do
      travel_to(367.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 1_00)
      end
      travel_to(300.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 2_00)
      end
      travel_to(200.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 3_00)
      end
      travel_to(100.days.ago) do
        create(:purchase, link:, seller: link.user, price_cents: 4_00)
      end
      create(:purchase, link:, seller: link.user, price_cents: 5_00)
    end

    it "sums up only the transaction values in the period specified (6 months)" do
      expect(user.transaction_volume_since(6.months.ago)).to eq(9_00)
    end

    it "sums up only the transaction values in the period specified (3 months)" do
      expect(user.transaction_volume_since(3.months.ago)).to eq(5_00)
    end
  end

  describe "projected_annual_transaction_volume" do
    describe "no sales" do
      it "returns zero" do
        expect(user.projected_annual_transaction_volume).to eq(0)
      end
    end

    describe "long time creator" do
      before do
        travel_to(367.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 1_00)
        end
        travel_to(300.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 2_00)
        end
        travel_to(200.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 3_00)
        end
        travel_to(100.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 4_00)
        end
        create(:purchase, link:, seller: link.user, price_cents: 5_00)
      end

      it "sums up only the transaction values in the period specified" do
        expect(user.projected_annual_transaction_volume).to eq(14_00)
      end
    end

    describe "recent creator" do
      before do
        travel_to(200.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 3_00)
        end
        travel_to(100.days.ago) do
          create(:purchase, link:, seller: link.user, price_cents: 4_00)
        end
        create(:purchase, link:, seller: link.user, price_cents: 5_00)
      end

      it "sums up only the transaction values in the period specified" do
        expect(user.projected_annual_transaction_volume).to eq(21_91)
      end
    end
  end
end
