# frozen_string_literal: true

class AchAccount < BankAccount
  include AchAccount::AccountType
  BANK_ACCOUNT_TYPE = "ACH"

  before_validation :set_default_account_type, on: :create, if: ->(ach_account) { ach_account.account_type.nil? }

  validate :validate_bank_name
  validate :validate_routing_number
  validate :validate_account_number
  validates :account_type, inclusion: { in: AccountType.all }

  def routing_number=(routing_number)
    self.bank_number = routing_number
  end

  def bank_name
    bank = Bank.find_by(routing_number: bank_number)
    return bank.name if bank.present?

    super
  end

  # Public: Format account type for ACH providers.
  # Returns single character representing account type
  def account_type_for_csv
    account_type ? account_type[0] : "c"
  end

  def bank_account_type
    BANK_ACCOUNT_TYPE
  end

  private
    def validate_bank_name
      return unless bank_name.present? && ["GREEN DOT BANK", "METABANK MEMPHIS"].include?(bank_name)

      errors.add :base, "Sorry, we don't support that bank account provider."
    end

    def validate_routing_number
      errors.add :base, "The routing number is invalid." unless self.class.routing_number_valid?(routing_number)
    end

    def validate_account_number
      return unless account_number_changed? && !self.class.account_number_valid?(account_number.decrypt(GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD")))

      errors.add :base, "The account number is invalid."
    end

    def set_default_account_type
      self.account_type = AchAccount::AccountType::CHECKING
    end

    def self.routing_number_valid?(routing_number)
      /^\d{9}$/.match(routing_number).present? && routing_number_check_digit_valid?(routing_number)
    end

    def self.routing_number_check_digit_valid?(routing_number)
      # Ref: https://en.wikipedia.org/wiki/Routing_transit_number#Check_digit
      check_digit =
        (
          7 * (routing_number[0].to_i + routing_number[3].to_i + routing_number[6].to_i) +
          3 * (routing_number[1].to_i + routing_number[4].to_i + routing_number[7].to_i) +
          9 * (routing_number[2].to_i + routing_number[5].to_i)
        ) % 10
      check_digit == routing_number[8].to_i
    end

    def self.account_number_valid?(account_number)
      /^\d{1,17}$/.match(account_number).present?
    end
end
