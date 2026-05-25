# frozen_string_literal: true

require "test_helper"

class MailerInfo::HeaderBuilderTest < ActiveSupport::TestCase
  MAILER_CLASS = "CustomerMailer"
  MAILER_METHOD = "test_email"
  MAILER_ARGS = ["test@example.com"].freeze

  test ".perform delegates to instance" do
    captured_perform = false
    fake_instance = Object.new
    fake_instance.define_singleton_method(:perform) { captured_perform = true; { "test" => "value" } }

    MailerInfo::HeaderBuilder.stub(:new, fake_instance) do
      MailerInfo::HeaderBuilder.perform(
        mailer_class: MAILER_CLASS,
        mailer_method: MAILER_METHOD,
        mailer_args: MAILER_ARGS,
        email_provider: MailerInfo::EMAIL_PROVIDER_SENDGRID
      )
    end

    assert captured_perform
  end

  def build_builder(method: MAILER_METHOD, args: MAILER_ARGS, provider: MailerInfo::EMAIL_PROVIDER_SENDGRID)
    MailerInfo::HeaderBuilder.new(
      mailer_class: MAILER_CLASS,
      mailer_method: method,
      mailer_args: args,
      email_provider: provider
    )
  end

  test "#build_for_sendgrid builds basic headers" do
    headers = build_builder.build_for_sendgrid
    smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
    assert_equal Rails.env, smtpapi["environment"]
    assert_equal [MAILER_CLASS, "#{MAILER_CLASS}.#{MAILER_METHOD}"], smtpapi["category"]
    assert_equal MAILER_CLASS, smtpapi["unique_args"]["mailer_class"]
    assert_equal MAILER_METHOD, smtpapi["unique_args"]["mailer_method"]
  end

  test "#build_for_sendgrid with receipt email includes purchase id" do
    purchase = purchases(:auto_invoice_enabled_purchase)
    headers = build_builder(method: SendgridEventInfo::RECEIPT_MAILER_METHOD, args: [purchase.id, nil]).build_for_sendgrid
    smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
    assert_equal purchase.id, smtpapi["unique_args"]["purchase_id"]
  end

  test "#build_for_sendgrid with preorder receipt email includes authorization purchase id" do
    preorder = preorders(:preorder_successful)
    auth_purchase = purchases(:auto_invoice_enabled_purchase)
    with_preorder_auth_stub(auth_purchase) do
      headers = build_builder(method: SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD, args: [preorder.id]).build_for_sendgrid
      smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
      assert_equal auth_purchase.id, smtpapi["unique_args"]["purchase_id"]
    end
  end

  test "#build_for_sendgrid with abandoned cart email includes workflow ids" do
    workflow_ids = { "1" => "test" }
    args = ["test@example.com", workflow_ids]
    headers = build_builder(method: EmailEventInfo::ABANDONED_CART_MAILER_METHOD, args: args).build_for_sendgrid
    smtpapi = JSON.parse(headers[MailerInfo::SENDGRID_X_SMTPAPI_HEADER])
    assert_nil smtpapi["unique_args"]["workflow_ids"]
    assert_equal args.inspect, smtpapi["unique_args"]["mailer_args"]
    assert_equal MAILER_CLASS, smtpapi["unique_args"]["mailer_class"]
    assert_equal EmailEventInfo::ABANDONED_CART_MAILER_METHOD, smtpapi["unique_args"]["mailer_method"]
  end

  test "#build_for_resend builds basic headers" do
    headers = build_builder(provider: MailerInfo::EMAIL_PROVIDER_RESEND).build_for_resend

    assert_equal MailerInfo::EMAIL_PROVIDER_RESEND, headers[MailerInfo.header_name(:email_provider)]
    assert_equal Rails.env, MailerInfo.decrypt(headers[MailerInfo.header_name(:environment)])
    assert_equal MAILER_CLASS, MailerInfo.decrypt(headers[MailerInfo.header_name(:mailer_class)])
    assert_equal MAILER_METHOD, MailerInfo.decrypt(headers[MailerInfo.header_name(:mailer_method)])
    assert_equal [MAILER_CLASS, "#{MAILER_CLASS}.#{MAILER_METHOD}"],
                 JSON.parse(MailerInfo.decrypt(headers[MailerInfo.header_name(:category)]))
  end

  test "#build_for_resend with receipt email includes purchase id" do
    purchase = purchases(:auto_invoice_enabled_purchase)
    headers = build_builder(
      method: SendgridEventInfo::RECEIPT_MAILER_METHOD,
      args: [purchase.id, nil],
      provider: MailerInfo::EMAIL_PROVIDER_RESEND
    ).build_for_resend
    encrypted_id = headers[MailerInfo.header_name(:purchase_id)]
    assert_equal purchase.id.to_s, MailerInfo.decrypt(encrypted_id)
  end

  test "#build_for_resend with preorder receipt email includes authorization purchase id" do
    preorder = preorders(:preorder_successful)
    auth_purchase = purchases(:auto_invoice_enabled_purchase)
    with_preorder_auth_stub(auth_purchase) do
      headers = build_builder(
        method: SendgridEventInfo::PREORDER_RECEIPT_MAILER_METHOD,
        args: [preorder.id],
        provider: MailerInfo::EMAIL_PROVIDER_RESEND
      ).build_for_resend
      encrypted_id = headers[MailerInfo.header_name(:purchase_id)]
      assert_equal auth_purchase.id.to_s, MailerInfo.decrypt(encrypted_id)
    end
  end

  test "#build_for_resend with abandoned cart email includes workflow ids" do
    workflow_ids = { "1" => "test" }
    args = ["test@example.com", workflow_ids]
    headers = build_builder(
      method: EmailEventInfo::ABANDONED_CART_MAILER_METHOD,
      args: args,
      provider: MailerInfo::EMAIL_PROVIDER_RESEND
    ).build_for_resend
    encrypted_ids = headers[MailerInfo.header_name(:workflow_ids)]
    assert_equal workflow_ids.keys.to_json, MailerInfo.decrypt(encrypted_ids)
  end

  test "#build_for_resend raises error with unexpected args for abandoned cart email" do
    assert_raises(ArgumentError) do
      build_builder(
        method: EmailEventInfo::ABANDONED_CART_MAILER_METHOD,
        args: ["test@example.com"],
        provider: MailerInfo::EMAIL_PROVIDER_RESEND
      ).build_for_resend
    end
  end

  test "#truncated_mailer_args truncates string arguments to 20 chars" do
    builder = build_builder(args: ["a" * 30, 123, { key: "value" }])
    assert_equal ["a" * 20, 123, { key: "value" }], builder.truncated_mailer_args
  end

  private
    def with_preorder_auth_stub(auth_purchase)
      # Use define_method + UnboundMethod restore (P-M9 pattern).
      # Earlier impl used Preorder.prepend(...) which permanently mutated
      # the class and leaked across tests (cancel_preorder_worker_test failures).
      original = Preorder.instance_method(:authorization_purchase)
      Preorder.define_method(:authorization_purchase) { auth_purchase }
      begin
        yield
      ensure
        Preorder.define_method(:authorization_purchase, original)
      end
    end
end
