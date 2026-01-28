# frozen_string_literal: true

class MakeUtmLinkVisitsCountryCodeNullable < ActiveRecord::Migration[4.2]
  def change
    change_column_null :utm_link_visits, :country_code, true
  end
end
