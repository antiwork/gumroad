# frozen_string_literal: true

class RpushApnsAppService
  attr_reader :name

  def initialize(name:)
    @name = name
  end

  def first_or_create!
    first || create!
  end

  private
    def first
      Rpush::Apns2::App.all.select { |app| app.name == name }.first
    end

    def create!
      certificate = File.read(Rails.root.join("config",
                                              "certs",
                                              certificate_name))

      app = Rpush::Apns2::App.new(name:,
                                  certificate:,
                                  environment: app_environment,
                                  password:,
                                  connections: 1)
      app.save!
      app
    end

    def creator_app?
      @name == Device::APP_TYPES[:creator]
    end

    def certificate_name
      if creator_app?
        "#{app_environment}_com.GRD.iOSCreator.pem"
      else
        "#{app_environment}_com.GRD.Gumroad.pem"
      end
    end

    def password
      creator_app? ? GlobalConfig.get("RPUSH_APN_CERT_CREATOR_PASSWORD") : GlobalConfig.get("RPUSH_APN_CERT_BUYER_PASSWORD")
    end

    def app_environment
      (Rails.env.staging? || Rails.env.production?) ? "production" : "development"
    end
end
