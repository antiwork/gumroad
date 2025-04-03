# Manage webhooks for Gumroad partner account

### Generate access token

```
curl <https://api.paypal.com/v1/oauth2/token> \\
  -H "Accept: application/json" \\
  -H "Accept-Language: en_US" \\
  -u "<client_id>:<client_secret>" \\
  -d "grant_type=client_credentials"
```

### Fetch Webhooks

```
curl -v -X GET <https://api.paypal.com/v1/notifications/webhooks> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>"
```

### Register Webhook

```
curl -v -X POST <https://api.paypal.com/v1/notifications/webhooks> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>" \\
-d '{
  "url": "https://<URL>/paypal-webhook",
  "event_types": [
  {
    "name": "CHECKOUT.ORDER.PROCESSED"
  }
  ]
}'
```

### Update Webhook

List of all the required Paypal webhooks is maintained here.

```
curl -v -X PATCH <https://api.paypal.com/v1/notifications/webhooks/><webhook-id> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>" \\
-d '[
  {
  "op": "replace",
  "path": "/event_types",
  "value": [
    {
      "name": "CHECKOUT.ORDER.PROCESSED"
    },
    {
      "name":"CUSTOMER.DISPUTE.CREATED"
    },
    {
      "name":"CUSTOMER.DISPUTE.RESOLVED"
    },
    {
      "name":"CUSTOMER.DISPUTE.UPDATED"
    },
    {
      "name": "MERCHANT.PARTNER-CONSENT.REVOKED"
    },
    {
      "name": "PAYMENT.CAPTURE.COMPLETED"
    },
    {
      "name": "PAYMENT.CAPTURE.DENIED"
    },
    {
      "name":"PAYMENT.CAPTURE.PENDING"
    },
    {
      "name": "PAYMENT.CAPTURE.REFUNDED"
    },
    {
      "name":"PAYMENT.CAPTURE.REVERSED"
    },
    {
      "name":"PAYMENT.ORDER.CREATED"
    },
    {
      "name": "PAYMENT.REFERENCED-PAYOUT-ITEM.COMPLETED"
    }
  ]
  }
]'
```

### Delete Webhook

```
curl -v -X DELETE <https://api.paypal.com/v1/notifications/webhooks/><webhook-id> \\
-H "Content-Type:application/json" \\
-H "Authorization: Bearer <access_token>"
```

# Links related to Paypal's Instant Payment Notification(IPN) feature

IPN simulator Guide

https://developer.paypal.com/docs/classic/ipn/integration-guide/IPNSimulator/

(IPN) settings (Live)

https://www.paypal.com/cgi-bin/customerprofileweb?cmd=_profile-ipn-notify

IPN Simulator

https://developer.paypal.com/developer/ipnSimulator/

Site to view sample webhook data

[https://webhook.site](https://webhook.site/)

IPN history

https://www.paypal.com/us/cgi-bin/webscr?cmd=_display-ipns-history

# Orders API sample application setup Instructions

1. Clone repo - https://github.com/sharang-d/orders
2. Create file `paypal.rb` in config/initializers/
3. Add POST endpoint in the application to handle webhook notifications
4. Change webhook URL in Paypal Developer account.
   1. Login [paypal@gumroad.com](mailto:paypal@gumroad.com) account
   2. Go to dashboard
   3. Click on `My Apps & Credentials`
   4. Under `REST API apps` section Click on `Gumroad` Application.
   5. Under `Sandbox Webhooks` section Add webhook URL of your application.

`paypal.rb`

```
PAYPAL_ENDPOINT = "<https://api-3t.sandbox.paypal.com/nvp>"
PAYPAL_REST_ENDPOINT = "<https://api.sandbox.paypal.com>"
PAYPAL_ENV = "sandbox"
PAYPAL_CLIENT_ID = "AQiKjZAqXGcN_oU8wh-RKelv6Nf3IrWVY9J9rrhz1pF7aqiyZjutSdG75I6ahd3zJe1ThpklFp5jNman"
PAYPAL_CLIENT_SECRET = "EPnNdtAW6jsUleHWQmjsFNef37f1GGWLwtJx3uO2PRdbENAFxTgW1WA1V83MVYvSrRrkH0tXNevE0CJ_"
PAYPAL_LIB_MODE = "sandbox"
PAYPAL_URL = "<https://www.sandbox.paypal.com>"
PAYPAL_MERCHANT_ID = "5SCHBGJUCTP2U"
PAYPAL_USER_EMAIL = "paypal-facilitator@gumroad.com"
PAYPAL_USER = "paypal-facilitator_api1.gumroad.com"
PAYPAL_PASS = "1383112423"
PAYPAL_SIGNATURE = "AFcWxV21C7fd0v3bYYYRCpSSRl31A9TRhGDrqj7x7lF9P6NGOruW.7ak"

PayPal::SDK.configure(
  :mode => PAYPAL_ENV,
  :client_id => PAYPAL_CLIENT_ID,
  :client_secret => PAYPAL_CLIENT_SECRET,
  :username => PAYPAL_USER,
  :password => PAYPAL_PASS,
  :signature => PAYPAL_SIGNATURE
)
```

[PayPal Connect test accounts](https://www.notion.so/PayPal-Connect-test-accounts-43bc5312793a44e4a44d9503ca921f34?pvs=21)
