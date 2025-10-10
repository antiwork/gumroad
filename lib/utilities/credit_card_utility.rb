# frozen_string_literal: true

class CreditCardUtility
  CARD_TYPE_NAMES = {
    "Visa" => CardType::VISA,
    "American Express" => CardType::AMERICAN_EXPRESS,
    "MasterCard" => CardType::MASTERCARD,
    "Discover" => CardType::DISCOVER,
    "JCB" => CardType::JCB,
    "Diners Club" => CardType::DINERS_CLUB
  }.freeze

  CARD_TYPE_DEFAULT_LENGTHS = {
    CardType::UNKNOWN => 16,
    CardType::VISA => 16,
    CardType::AMERICAN_EXPRESS => 15,
    CardType::MASTERCARD => 16,
    CardType::DISCOVER => 16,
    CardType::JCB => 16,
    CardType::DINERS_CLUB => 14,
    CardType::UNION_PAY => 16,
  }.freeze

  class << self
    def card_types_for_react
      CARD_TYPE_NAMES.map { |name, id| { id:, name: } }
    end

    def extract_month_and_year(date)
      date = date.delete(" ")
      if date.split("/").length == 2
        month = date.split("/")[0]
        year = date.split("/")[1]
      elsif date.length == 4
        month = date[0..1]
        year = date[2..3]
      elsif date.length == 5
        month = date[0..1]
        year = date[3..4]
      end

      [month, year]
    end
  end
end
