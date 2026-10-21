# IRAS APEX migration

Singapore GST validation switches to APEX when `IRAS_APEX_API_KEY` is present at application boot. An absent key retains the existing API Marketplace integration while account onboarding is completed. This is a rollout mechanism, not a fallback after API Marketplace retires: APEX failures never retry the old API.

## Obtain access

1. Appoint a Corppass administrator. Overseas companies without a Singapore UEN can [register as a foreign entity](https://ask.gov.sg/corppass/questions/cm1q0y3r20065wdnwqqzqxopi), using their home-country business registration number. The administrator must provide company registration/address documents and their own identity document, then personally activate their account. The [application](https://www.corppass.gov.sg/corppass/registration/nonuen/nonsingpass/registrationdetails) lists current document requirements and processing time.
2. Have the administrator assign the developer the **APEX Cloud** e-Service. Follow the [IRAS onboarding guide](https://file.go.gov.sg/apexonboarding-apikey.pdf). Have the company's existing IRAS GST/tax reference available; ask IRAS Digital Partnerships to confirm the applicable APEX organization eligibility or agency endorsement if needed.
3. Create a sandbox application and generate its API key. [Request Check GST Register access](https://form.gov.sg/68aad7cb32e5abb778bb7c0b), obtain approval, and subscribe the application to the sandbox API.
4. Complete IRAS's sandbox tests before requesting a separate production application, key and subscription. Sandbox and production credentials are distinct. Never use production for testing.

The public GST lookup e-Service is a manual fallback. Its CAPTCHA makes it unsuitable as a replacement for automated API access.

## Verify in sandbox

Configure the sandbox key as `IRAS_APEX_API_KEY` in a private environment file or the environment's Rails credential `iras_apex_api_key`; do not commit it. `GlobalConfig` gives environment variables precedence over Rails credentials, including an empty environment value, so remove the empty template variable when using credentials. Restart the application after changing the key.

In a nonproduction Rails console, verify only the selected endpoint and the presence of the key:

```ruby
[IRAS_ENDPOINT, IRAS_APEX_API_KEY.present?]
GstValidationService.new("T9100001B").process
GstValidationService.new("95000002K").process
```

Expect the sandbox endpoint, `true`, then registered (`true`) and deregistered (`false`) validation results. Follow the remaining cases in the [API v2 specification](https://file.go.gov.sg/iras-check-gst-register-api.pdf). Sandbox is limited to 100 requests/hour.

The request is `POST https://sandbox.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered`, with `x-apex-apikey`, JSON content headers and `{"regID":"T9100001B"}`. Neither IBM headers nor `clientID` are sent. Only `returnCode == "10"` together with `data.Status == "Registered"` validates an ID.

Run the focused specs:

```sh
DISABLE_SPRING=1 bin/rspec spec/config/iras_spec.rb spec/services/gst_validation_service_spec.rb spec/services/regional_vat_id_validation_service_spec.rb
```

The existing invoice VCR recordings exercise API Marketplace. Once sandbox access is available, regenerate the four GST invoice examples in `spec/controllers/purchases/invoices_controller_spec.rb` with the sandbox key configured, following [the recording instructions](testing.md#vcr-cassettes). Do not rewrite recordings or replace those interactions with stubs. The APEX key is filtered from new recordings by `spec_helper`.

## Production cutover

After sandbox approval and production subscription, store the production APEX key in the production secret store as `IRAS_APEX_API_KEY` / `iras_apex_api_key` and restart deployed processes. Production selects `https://public.api.gov.sg/iras/GSTListing/v1/SearchGSTRegistered`; every other environment selects sandbox. Verify configuration without logging the key or buyer tax IDs, and monitor normal Singapore validation traffic and vendor errors.

Validation results are cached for ten minutes and separated by endpoint so old API results cannot mask the cutover. Removing the key and restarting reselects API Marketplace only while that service is still operational. After successful cutover, revoke the old IBM credentials and remove the legacy integration in a follow-up. Until the new key and subscription are in place, this code alone does not complete the migration.
