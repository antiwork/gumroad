# frozen_string_literal: true

class Onetime::CompileGumroadDailyAnalyticsFromBeginning
  def self.process
    start_date = GUMROAD_STARTED_DATE
    end_date = Date.today

    (start_date..end_date).each do |date|
      GumroadDailyAnalytic.import(date)
    end
  end
end
