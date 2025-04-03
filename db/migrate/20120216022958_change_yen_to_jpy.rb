# frozen_string_literal: true

class ChangeYenToJpy < ActiveRecord::Migration
  def up
    User.find_each do |user|
      if user.currency_type == "yen"
        user.currency_type = "jpy"
      end
      user.save(validate: false)
    end

    Link.find_each do |link|
      if link.price_currency_type == "yen"
        link.price_currency_type = "jpy"
      end
      link.save(validation: false)
    end

    Purchase.find_each do |purchase|
      if purchase.displayed_price_currency_type == "yen"
        purchase.displayed_price_currency_type = "jpy"
      end
      purchase.save(validation: false)
    end
  end

  def down
    User.find_each do |user|
      if user.currency_type == "jpy"
        user.currency_type = "yen"
      end
      user.save(validate: false)
    end

    Link.find_each do |link|
      if link.price_currency_type == "jpy"
        link.price_currency_type = "yen"
      end
      link.save(validation: false)
    end

    Purchase.find_each do |purchase|
      if purchase.displayed_price_currency_type == "jpy"
        purchase.displayed_price_currency_type = "yen"
      end
      purchase.save(validation: false)
    end
  end
end
