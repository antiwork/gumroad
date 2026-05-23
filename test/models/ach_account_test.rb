# frozen_string_literal: true

require "test_helper"

class AchAccountTest < ActiveSupport::TestCase
  self.described_class = AchAccount



  context_ AchAccount do
  context_ "#routing_number" do
      let(:ach_account) { build(:ach_account) }

  context_ "is valid" do
        before do
          expect(described_class).to receive(:routing_number_valid?).and_return(true)
        end

  test "does not valid" do
          expect(ach_account).to be_valid
        end
      end

  context_ "is invalid" do
        before do
          expect(described_class).to receive(:routing_number_valid?).and_return(false)
        end

  test "is not valid" do
          expect(ach_account).not_to be_valid
        end
      end
    end

  context_ "#account_number" do
      let(:ach_account) { build(:ach_account) }

  context_ "is valid" do
        before do
          expect(described_class).to receive(:account_number_valid?).and_return(true)
        end

  test "does not valid" do
          expect(ach_account).to be_valid
        end
      end

  context_ "is invalid" do
        before do
          expect(described_class).to receive(:account_number_valid?).and_return(false)
        end

  test "is not valid" do
          expect(ach_account).not_to be_valid
        end
      end
    end

  context_ "account types" do
  test "allows checking account types" do
        ach = build(:ach_account, account_type: AchAccount::AccountType::CHECKING)
        expect(ach).to be_valid
        expect(ach.account_type).to eq(AchAccount::AccountType::CHECKING)
      end
  test "allows savings account types" do
        ach = build(:ach_account, account_type: AchAccount::AccountType::SAVINGS)
        expect(ach).to be_valid
        expect(ach.account_type).to eq(AchAccount::AccountType::SAVINGS)
      end
  test "invalidates other account types" do
        ach = build(:ach_account, account_type: "evil_account_type")
        expect(ach).not_to be_valid
      end
  test "translates a nil account type to the default (checking)" do
        ach = build(:ach_account, account_type: nil)
        expect(ach).to be_valid
        expect(ach.account_type).to eq(AchAccount::AccountType::CHECKING)
      end
    end

  context_ ".routing_number_valid?" do
  context_ "is 9 numerics" do
        let(:routing_number) { "121000497" }

  test "returns true" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(true)
        end
      end

  context_ "is nil" do
        let(:routing_number) { nil }

  test "returns false" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(false)
        end
      end

  context_ "is 9 numerics plus whitespace" do
        let(:routing_number) { "121000497 " }

  test "returns false" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(false)
        end
      end

  context_ "is 9 alphanumerics" do
        let(:routing_number) { "12100049a" }

  test "returns false" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(false)
        end
      end

  context_ "is > 9 numerics" do
        let(:routing_number) { "1210004971" }

  test "returns false" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(false)
        end
      end

  context_ "is < 9 numerics" do
        let(:routing_number) { "12100049" }

  test "returns false" do
          expect(described_class.routing_number_valid?(routing_number)).to eq(false)
        end
      end
    end

  context_ ".routing_number_check_digit_valid?" do
  context_ "valid check digit" do
        let(:valid_routing_numbers) do
          [
            "121000497",
            "110000000",
            # Some of US Bank's Routing Numbers
            "122105155",
            "082000549",
            "121122676",
            "122235821",
            "102101645",
            "102000021",
            "123103729",
            "071904779",
            "081202759",
            "074900783",
            "104000029",
            "073000545",
            "101000187",
            "042100175",
            "083900363",
            "091215927",
            "091300023",
            "091000022",
            "081000210",
            "101200453",
            "092900383",
            "104000029",
            "121201694",
            "107002312",
            "091300023",
            "041202582",
            "042000013",
            "123000220",
            "091408501",
            "064000059",
            "124302150",
            "125000105",
            "075000022",
            "307070115",
            "091000022",
            # Some of WellsFargo's Routing Numbers
            "125200057",
            "121042882",
            "321270742"
          ]
        end

        let(:routing_number) { "121000497" }

  test "returns true" do
          valid_routing_numbers.each do |valid_routing_number|
            expect(described_class.routing_number_check_digit_valid?(valid_routing_number)).to eq(true)
          end
        end
      end

  context_ "invalid check digit" do
  context_ "example" do
          let(:routing_number) { "121000498" }

  test "returns false" do
            expect(described_class.routing_number_check_digit_valid?(routing_number)).to eq(false)
          end
        end

  context_ "example" do
          let(:routing_number) { "110000001" }

  test "returns false" do
            expect(described_class.routing_number_check_digit_valid?(routing_number)).to eq(false)
          end
        end
      end
    end

  context_ ".account_number_valid?" do
  context_ "is 1 numerics" do
        let(:account_number) { "1" }

  test "returns true" do
          expect(described_class.account_number_valid?(account_number)).to eq(true)
        end
      end

  context_ "is 10 numerics" do
        let(:account_number) { "1234567890" }

  test "returns true" do
          expect(described_class.account_number_valid?(account_number)).to eq(true)
        end
      end

  context_ "is 17 numerics" do
        let(:account_number) { "12345678901234567" }

  test "returns true" do
          expect(described_class.account_number_valid?(account_number)).to eq(true)
        end
      end

  context_ "is nil" do
        let(:account_number) { nil }

  test "returns false" do
          expect(described_class.account_number_valid?(account_number)).to eq(false)
        end
      end

  context_ "is 10 numerics plus whitespace" do
        let(:account_number) { "1234567890 " }

  test "returns false" do
          expect(described_class.account_number_valid?(account_number)).to eq(false)
        end
      end

  context_ "is 10 alphanumerics" do
        let(:account_number) { "123456789a" }

  test "returns false" do
          expect(described_class.account_number_valid?(account_number)).to eq(false)
        end
      end

  context_ "is > 17 numerics" do
        let(:account_number) { "12345678901234567890" }

  test "returns false" do
          expect(described_class.account_number_valid?(account_number)).to eq(false)
        end
      end

  context_ "is < 1 numerics" do
        let(:account_number) { "" }

  test "returns false" do
          expect(described_class.account_number_valid?(account_number)).to eq(false)
        end
      end
    end

  context_ "#validate_bank_name" do
  test "disallows records with bank name 'GREEN DOT BANK'" do
        ach_account = build(:ach_account,
                            bank_number: create(:bank, routing_number: "121000497", name: "GREEN DOT BANK").routing_number)

        expect(ach_account).not_to be_valid
        expect(ach_account.errors.full_messages.to_sentence).to eq("Sorry, we don't support that bank account provider.")
      end

  test "disallows records with bank name 'METABANK MEMPHIS'" do
        ach_account = build(:ach_account,
                            bank_number: create(:bank, routing_number: "121000497", name: "METABANK MEMPHIS").routing_number)

        expect(ach_account).not_to be_valid
        expect(ach_account.errors.full_messages.to_sentence).to eq("Sorry, we don't support that bank account provider.")
      end

  test "allows records with any other bank name" do
        ach_account = build(:ach_account)

        expect(ach_account).to be_valid
      end
    end
  end
end
