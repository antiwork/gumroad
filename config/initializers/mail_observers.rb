# frozen_string_literal: true

Rails.application.configure do
  config.action_mailer.observers = %w[EmailDeliveryObserver]
  # Cleans invisible characters off recipient addresses just before delivery, so accounts whose
  # stored address was saved before we started refusing those characters can receive mail again.
  config.action_mailer.interceptors = %w[InvisibleCharacterRecipientSanitizer]
end
