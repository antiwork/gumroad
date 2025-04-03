# frozen_string_literal: true

class RpushFcmAppService
  attr_reader :name

  def initialize(name:)
    @name = name
  end

  def first_or_create!
    first || create!
  end

  private
    def first
      Rpush::Fcm::App.all.select { |app| app.name == name }.first
    end

    def create!
      app = Rpush::Fcm::App.new(name:,
                                json_key:,
                                firebase_project_id:,
                                connections: 1)

      app.save!
      app
    end

    def json_key
      GlobalConfig.get("RPUSH_CONSUMER_FCM_JSON_KEY")
    end

    def firebase_project_id
      GlobalConfig.get("RPUSH_CONSUMER_FCM_FIREBASE_PROJECT_ID")
    end
end
