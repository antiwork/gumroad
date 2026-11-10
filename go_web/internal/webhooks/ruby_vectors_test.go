package webhooks

// Generated with Ruby 3.4 and the Gemfile.lock versions of json, stripe, sendgrid-ruby,
// aws-sdk-sns, uri and actionpack. Keys and certificates here are test-only.

const (
	rubyStripeSecret    = "whsec_test_0123456789abcdef"
	rubyStripeTimestamp = 1792001956
	rubyStripePayload   = `{"id":"evt_1","object":"event","type":"charge.succeeded","account":"acct_1","data":{"object":{"object":"charge","id":"ch_1","amount":1000,"metadata":{},"tags":[1,null],"big":1e400}}}`
	rubyStripeHeader    = "t=1792001956,v1=cef7dd4f43d37ea12756337e751cc851130499aac2565ed16ac52625c4d238b8"
	// Stripe::Event#as_json of rubyStripePayload, through JSON.generate.
	rubyStripeAsJSON = `{"id":"evt_1","object":"event","type":"charge.succeeded","account":"acct_1","data":{"object":{"id":"ch_1","object":"charge","amount":1000,"metadata":{},"tags":[1,null],"big":null}}}`
)

// The second key signed rubySendgridBody; Ruby's verify_signature rejects it under the first.
const (
	rubySendgridKey1      = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE8uYZLdMw8mAAMf8tIQH7ul9zxvx3d20Cf635ggBN2Tp3xsjxlh1nStPdjoy4/hqRXYSYwLOy+aSUj05ovUNuWA=="
	rubySendgridKey2      = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaWgh2xa/GJy44eIuFSCni6Yd81A0PC0oGDAIohce1xB8VHsamNSkZ8drocGP1ORV8x3oFwPzYGQbQjuGv4KjSg=="
	rubySendgridTimestamp = "1792001956"
	rubySendgridBody      = `[{"email":"buyer@example.com","event":"delivered","sg_message_id":"abc123"}]`
	rubySendgridSignature = "MEYCIQDMUhIQOy/Hd2Ew4cM0rKjg2MB0OS/2/PTfEeGJK9aLZgIhANk/3Kytq7FKfiXDOUSQTlhDLflJInokECMhzDtfVN+1"
)

// Aws::SNS::MessageVerifier#authentic? is true for all three with rubySNSCertPEM served at
// rubySNSCertURL. It is false once Message is changed or a Token is added to the
// Notification, and still true when the v2 Notification gets "Subject": [].
const (
	rubySNSCertURL = "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem"
	rubySNSCertPEM = `-----BEGIN CERTIFICATE-----
MIICsTCCAZmgAwIBAgIBATANBgkqhkiG9w0BAQsFADAcMRowGAYDVQQDDBFzbnMu
YW1hem9uYXdzLmNvbTAeFw0yMzExMTQyMjEzMjBaFw0zNjA3MTgxMzIwMDBaMBwx
GjAYBgNVBAMMEXNucy5hbWF6b25hd3MuY29tMIIBIjANBgkqhkiG9w0BAQEFAAOC
AQ8AMIIBCgKCAQEAy2sQAMg9r98oijKV+KFz42k2bIG44YzxE0ZNa9VtrY5sG1Gp
yS4zXub57YXJmLb59jgwKB20BnSQYEU77aHDClybde0jazcOAbAOEbB196Tq8N6m
QLy+DmAAaqiOEzURovJCWCp8GZWBUtTlUG0m2NsIThaJ+e7kmVyINKfKUPpP5nY+
1K7dDSud2NipOTm4vGtI/AqKwtAK7CxtQlrtDXGuPjaDn6byp2NdKOqOsPe9PxMA
jITC3kBunDCP9PK41F+Z72Nb78aa9ZC+jqvZ3nWf1sG43lKPxi+kzsp6VsqELhcT
IUHEFBPuNbYrFJ/u6H7KOwzKfTjvBPg/C0Iq0QIDAQABMA0GCSqGSIb3DQEBCwUA
A4IBAQBV6mFYhFp48JQM/XaKYKSj1Vr3Ovt0r1HssDO3a6cDUgAaiVkfSEJHAp3E
w8O7BltFf6lS+Y6tBK8LzOJu6x5CEaw41SNx79CTLEHPLBiFRIS6VA9PFEhjiArE
htiLvHSQjflS+J9boXN+ExpNIzBd+3872rg6/BLAhh/ME/7p+u9yFqdIADqin5nP
ARyl9mUGoI7MbZOKTC+YN8Mnl5Ouf6VJ8MXqtpX1EEeDwjoTtPWq2WgrlURo0znW
UVsCT6vNhi336F4lirw4cQV/VKRFQl60MxJt1M6Nc1ZGAIdxaQDn0sw4/yBDeGjd
jLKt56MNzdClyU3dIDBM0prX5L9E
-----END CERTIFICATE-----
`
	rubySNSNotificationV1 = `{"Type":"Notification","MessageId":"22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324","TopicArn":"arn:aws:sns:us-east-1:123456789012:MediaConvert","Subject":"MediaConvert Job State Change","Message":"{\"detail\":{\"jobId\":\"abcd\",\"status\":\"COMPLETE\"}}","Timestamp":"2026-10-14T18:19:15.254Z","SignatureVersion":"1","SigningCertURL":"https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem","UnsubscribeURL":"https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe","Signature":"Jo+Brzqua/GdpAiDnCwKuy8Z2GOAODk701h7rXHF3vt8n7yTXaNK13UnrB+uFige90ebopE4yyHjn2SZiCOsD5NHoDe3YJaLVyk8LJDWPQ0DjBTd832Pbz3bjmHEcvbZJbA29d/GIey01zzr1Xmr31O+k8qIK3CfRM2E+PScW0NzWLAOJbuJIP8edudYPWkcyTb71A9nioyloeyeb1hol53J9B6AajHeTEUoR5zKGuLQenRaipcgbE2mFZxWws/fvkuEpdyrvnzfdXcRfdCOCGumpg3Zk5VMD8PLVQZ7kMBrA9C7ap9veOaAyrZ+b0r3b9W1w3WvoSuJMhI4XRwFlQ=="}`
	rubySNSNotificationV2 = `{"Type":"Notification","MessageId":"22b80b92-fdea-4c2c-8f9d-bdfb0c7bf324","TopicArn":"arn:aws:sns:us-east-1:123456789012:MediaConvert","Message":"{\"detail\":{\"jobId\":\"abcd\",\"status\":\"COMPLETE\"}}","Timestamp":"2026-10-14T18:19:15.254Z","SignatureVersion":"2","SigningCertURL":"https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem","UnsubscribeURL":"https://sns.us-east-1.amazonaws.com/?Action=Unsubscribe","Signature":"LFGQ1rJChIO57bHb3ZJXd9CyyDqd6bF+d53b8ZeoDGCiFzdGqQQiYBZNnoK5bqvgteiaOjNKqnLZ51E//eRL1m9kkbbxsGicHt6smr0n0ILCnisjNxy9OkA1C3tgx2Qmqh7Q/q/Hann0f9FSb70nnyq92z3R/I0uxIZWVFykqNQVWjxgS9AowlkFnSI5EwOtvR5nKUU4oCFwJxterEVsCxArZYkjbtsqS1aXWRPXNJi93Docva/vFtRAMcqR6Ar7T0QLUg/L5aUGNqq+9IDYLaF58zt6CJo2rorG37tl0YZup7OVMXtvhharJvd7WvzLZFclvxVRRNyaFW7fi85oeA=="}`
	rubySNSConfirmation   = `{"Type":"SubscriptionConfirmation","MessageId":"165545c9-2a5c-472c-8df2-7ff2be2b3b1b","Token":"2336412f37f","TopicArn":"arn:aws:sns:us-east-1:123456789012:MediaConvert","Message":"You have chosen to subscribe to the topic","SubscribeURL":"https://sns.us-east-1.amazonaws.com/?Action=ConfirmSubscription&Token=2336412f37f","Timestamp":"2026-10-14T18:19:15.254Z","SignatureVersion":"1","SigningCertURL":"https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem","Signature":"rWEJcscbOA08jHcxpE2ZAQn794rB0gx7K7mNt1+A/r8YTGD/CMAKv70H2S1IQLwxMVMhgklrvqcm4y5YZenqO+l5X3jh6me9+AbG7yun66/aArCYUjctzMBPxuF5YW9lTffDVFJiY6RC2yg48Ma0RCU0cYLT2JvSBKBBTANaZSgEsJhdqvGxFQ2RhBFjYsrRx2N/FLKXQ6Jwnn0KNMegxgwhLvmZVdJ54hB+jG5ZnGdpW8eJsDivaSJLLiY4H8EQRu9tDKzP7vUda/AO+NT9/aDgCgPC32eTUZNWk8O2ZnLTLQgSvhwDyqQRcthbFePND/GgnqU7hiQPkogpXpI+Tg=="}`
)

// Kernel#Integer; "" marks an ArgumentError or TypeError.
var rubyIntegerResults = map[string]string{
	"1792001956":           "1792001956",
	"010":                  "8",
	" 12 ":                 "12",
	"0x10":                 "16",
	"1_0":                  "10",
	"":                     "",
	"1e3":                  "",
	"+5":                   "5",
	"0b11":                 "3",
	"0d19":                 "19",
	"08":                   "",
	"0_7":                  "7",
	"1__0":                 "",
	"_1":                   "",
	"1_":                   "",
	"0x_1":                 "",
	"12\n":                 "12",
	"-3":                   "-3",
	"0_":                   "",
	"00":                   "0",
	"0 ":                   "0",
	"+-1":                  "",
	"1 2":                  "",
	"\t7":                  "7",
	"7\u0000":              "",
	"0o17":                 "15",
	"0O17":                 "15",
	"0X1f":                 "31",
	"-0x10":                "-16",
	"0b":                   "",
	"0x":                   "",
	"-":                    "",
	"0d":                   "",
	"0B1":                  "1",
	"007":                  "7",
	"\u000b12\f":           "12",
	"99999999999999999999": "99999999999999999999",
	"-0":                   "0",
	"0b2":                  "",
	"1_000_000":            "1000000",
}

// Base64.decode64, re-encoded with Base64.strict_encode64.
var rubyDecode64Results = map[string]string{
	"":           "",
	"QUJD":       "QUJD",
	"QU JD":      "QUJD",
	"QUJ=D":      "QUI=",
	"Q=UJD":      "QUJD",
	"QUI":        "QUI=",
	"QQ":         "QQ==",
	"Q":          "",
	"QUJDRA==":   "QUJDRA==",
	"QUJDRA":     "QUJDRA==",
	"QU\nJD":     "QUJD",
	"!!QUJD!!":   "QUJD",
	"QUJD=QUJD":  "QUJDQUJD",
	"QU=JD":      "QQ==",
	"QUJ D":      "QUJD",
	"==QUJD":     "QUJD",
	"Q===":       "",
	"QU==JD":     "QQ==",
	"-_QUJD":     "QUJD",
	"QUJDR":      "QUJD",
	"QUJDRA=":    "QUJDRA==",
	"QUJDRA==QQ": "QUJDRA==",
}

var rubyExtnameResults = map[string]string{
	"/a.pem":     ".pem",
	"a.pem/":     ".pem",
	"/a.pem//":   ".pem",
	".pem":       "",
	"/x/.pem":    "",
	"a.":         ".",
	"a..pem":     ".pem",
	"/a.pem.":    ".",
	"a.PEM":      ".PEM",
	"":           "",
	"/":          "",
	"..pem":      "",
	"/x/..pem":   "",
	"a/b":        "",
	"/a.b/c":     "",
	"/a.b/c.pem": ".pem",
	"...":        "",
	"/.a.pem":    ".pem",
}

// String#blank?
var rubyBlankResults = map[string]bool{
	" ":      true,
	"\u00a0": true,
	"\u2003": true,
	"\u200b": false,
	"\ufeff": false,
	"\u3000": true,
	"\u0085": true,
	"\u000b": true,
	"\u001c": false,
	"a":      false,
	"":       true,
	" \t\n":  true,
}

type rubyURIResult struct {
	scheme, host, path, query, requestURI *string
	port                                  int
}

func ptr(s string) *string { return &s }

// URI.parse; nil marks URI::InvalidURIError.
var rubyURIResults = map[string]*rubyURIResult{
	"https://sns.us-east-1.amazonaws.com/SimpleNotificationService-0123456789abcdef.pem": {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/SimpleNotificationService-0123456789abcdef.pem"), query: nil, requestURI: ptr("/SimpleNotificationService-0123456789abcdef.pem")},
	"": {scheme: nil, host: nil, port: 0, path: ptr(""), query: nil, requestURI: nil},
	"HTTPS://SNS.us-east-1.amazonaws.com/a.pem":                    {scheme: ptr("https"), host: ptr("SNS.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://sns.us-east-1.amazonaws.com/a b.pem":                  nil,
	"https://user:pw@sns.us-east-1.amazonaws.com:8443/a.pem?x=1#f": {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 8443, path: ptr("/a.pem"), query: ptr("x=1"), requestURI: ptr("/a.pem?x=1")},
	"https:/a.pem":                                         {scheme: ptr("https"), host: nil, port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://sns.us-east-1.amazonaws.com":                  {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr(""), query: nil, requestURI: ptr("/")},
	"https://sns.us-east-1.amazonaws.com/a.pem/":           {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem/"), query: nil, requestURI: ptr("/a.pem/")},
	"https://[::1]/a.pem":                                  {scheme: ptr("https"), host: ptr("[::1]"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://[zz]/a.pem":                                   nil,
	"https://[v1.x]/a.pem":                                 {scheme: ptr("https"), host: ptr("[v1.x]"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://sns.us-east-1.amazonaws.com/a.pem\n":          nil,
	"https://sns.us-east-1.amazonaws.com/\u00e9.pem":       nil,
	"https://sns.us-east-1.amazonaws.com/a|b.pem":          nil,
	"https://sns.us-east-1.amazonaws.com/a.pem?q=a b":      {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: ptr("q=a%20b"), requestURI: ptr("/a.pem?q=a%20b")},
	"https://sns.us-east-1.amazonaws.com/a.pem?q=%zz":      nil,
	"https://sns.us-east-1.amazonaws.com/a.pem?q=%z1":      {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: ptr("q=%z1"), requestURI: ptr("/a.pem?q=%z1")},
	"https://sns.us-east-1.amazonaws.com/a.pem?q=a\tb\"<>": {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: ptr("q=ab%22%3C%3E"), requestURI: ptr("/a.pem?q=ab%22%3C%3E")},
	"https://sns.us-east-1.amazonaws.com:/a.pem":           {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://sns.us-east-1.amazonaws.com:x/a.pem":          nil,
	"https://sns.us-east-1.amazonaws.com:0443/a.pem":       {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"//sns.us-east-1.amazonaws.com/a.pem":                  {scheme: nil, host: ptr("sns.us-east-1.amazonaws.com"), port: 0, path: ptr("/a.pem"), query: nil, requestURI: nil},
	"https:a.pem":                                          {scheme: ptr("https"), host: nil, port: 443, path: nil, query: nil, requestURI: nil},
	"https:a.pem?%zz":                                      {scheme: ptr("https"), host: nil, port: 443, path: nil, query: nil, requestURI: nil},
	"a.pem":                                                {scheme: nil, host: nil, port: 0, path: ptr("a.pem"), query: nil, requestURI: nil},
	"https://sns.us-east-1.amazonaws.com/a\\b.pem":         nil,
	"https://sns.us-east-1.amazonaws.com/a%2.pem":          nil,
	"https://sns.us-east-1.amazonaws.com/a%20.pem":         {scheme: ptr("https"), host: ptr("sns.us-east-1.amazonaws.com"), port: 443, path: ptr("/a%20.pem"), query: nil, requestURI: ptr("/a%20.pem")},
	"https://1.2.3.4/a.pem":                                {scheme: ptr("https"), host: ptr("1.2.3.4"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://1.2.3.4.5/a.pem":                              {scheme: ptr("https"), host: ptr("1.2.3.4.5"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://[::ffff:1.2.3.4]/a.pem":                       {scheme: ptr("https"), host: ptr("[::ffff:1.2.3.4]"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://[1:2:3:4:5:6:7:8]/a.pem":                      {scheme: ptr("https"), host: ptr("[1:2:3:4:5:6:7:8]"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://[::1:2:3:4:5:6:7]/a.pem":                      {scheme: ptr("https"), host: ptr("[::1:2:3:4:5:6:7]"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://h/a.pem#f g":                                  nil,
	"https://h/a.pem#f?/":                                  {scheme: ptr("https"), host: ptr("h"), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"1https://h/a.pem":                                     nil,
	"https://h@/a.pem":                                     {scheme: ptr("https"), host: ptr(""), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"https://a@b@h/a.pem":                                  nil,
	"https://h/a.pem?x#y#z":                                nil,
	"https:///a.pem":                                       {scheme: ptr("https"), host: ptr(""), port: 443, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
	"http://sns.us-east-1.amazonaws.com/a.pem":             {scheme: ptr("http"), host: ptr("sns.us-east-1.amazonaws.com"), port: 80, path: ptr("/a.pem"), query: nil, requestURI: ptr("/a.pem")},
}

// JSON.generate(params.to_unsafe_hash.to_hash) in a Rails 8.1.3.1 ForeignWebhooksController
// for an application/json POST of body to /sendgrid-webhook plus query.
var railsSendgridParams = map[string]struct{ body, query, args string }{
	"batch":                 {body: `[{"email":"buyer@example.com","event":"delivered","sg_message_id":"abc123","category":["a",null],"n":1.50,"t":1792001956}]`, query: "", args: `{"_json":[{"email":"buyer@example.com","event":"delivered","sg_message_id":"abc123","category":["a"],"n":1.5,"t":1792001956}],"controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"_json":[{"email":"buyer@example.com","event":"delivered","sg_message_id":"abc123","category":["a"],"n":1.5,"t":1792001956}]}}`},
	"query":                 {body: `[{"event":"open"}]`, query: "?a=1&b[c]=2&a=3", args: `{"_json":[{"event":"open"}],"a":"3","b":{"c":"2"},"controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"_json":[{"event":"open"}]}}`},
	"body action":           {body: `{"action":"x","controller":"y","events":[1]}`, query: "", args: `{"action":"sendgrid","controller":"foreign_webhooks","events":[1],"foreign_webhook":{"action":"x","controller":"y","events":[1]}}`},
	"wrapper taken":         {body: `{"foreign_webhook":"kept","e":1}`, query: "", args: `{"foreign_webhook":"kept","e":1,"controller":"foreign_webhooks","action":"sendgrid"}`},
	"query over body":       {body: `{"e":"body","utf8":"x"}`, query: "?e=query", args: `{"e":"query","utf8":"x","controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"e":"body"}}`},
	"object dup keys":       {body: `{"b":1,"a":2,"b":3}`, query: "", args: `{"b":3,"a":2,"controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"b":3,"a":2}}`},
	"scalar":                {body: `"str"`, query: "", args: `{"_json":"str","controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"_json":"str"}}`},
	"escaped action":        {body: `{"\u0061ction":"x","contr\u006fller":"y","events":[1]}`, query: "", args: `{"action":"sendgrid","controller":"foreign_webhooks","events":[1],"foreign_webhook":{"action":"x","controller":"y","events":[1]}}`},
	"escaped action, array": {body: `[{"\u0061ction":"x"}]`, query: "", args: `{"_json":[{"action":"x"}],"controller":"foreign_webhooks","action":"sendgrid","foreign_webhook":{"_json":[{"action":"x"}]}}`},
}

// The PayPal-* headers every railsPaypalRequests POST carries.
var rubyPaypalHeaders = map[string]string{
	"Paypal-Transmission-Id":   "69cd13f0-d67a-11e5-baa3-778b53f4ae55",
	"Paypal-Transmission-Sig":  "lmI95Jx3Y9nhR5SJWlHVIWpg4AgFk7n9bCHSRxbrd8A9zrhdu2rMyFrmz+Zjh3s3boXB07VXCXUZy/UFzUlnGJn0wDugt7FlSvdKeIJenLRemUxYCPVoEZzg9VFNqOa48gMkvF+XTpxBeUx/kWy6B5cp7GkT2+pOowfRK7OaynuxUoKW3JcMWw272VKjLTtTAShncla7tGF+55rxyt2KNZIIqxNMJ48RDZheGU5w1npu9dZHnPgTXB9iomeVRoD8O/jhRpnKsGrDschyNdkeh81BJJMH4Ctc6lnCCquoP/GzCzz33MMsNdid7vL/NIWaCsekQpW26FpWPi/tfj8nLA==",
	"Paypal-Cert-Url":          "https://api.paypal.com/v1/notifications/certs/CERT-360caa42-fca2a594-a5cafa77",
	"Paypal-Auth-Algo":         "SHA256withRSA",
	"Paypal-Transmission-Time": "2026-11-10T08:12:10Z",
}

const rubyPaypalWebhookID = "1JE4291016473214C"

// ForeignWebhooksController#paypal in Rails 8.1.3.1, for a POST of body to /paypal-webhook
// plus query with rubyPaypalHeaders: args is JSON.generate of the job argument, "" where
// that raises, and event is the webhook_event PaypalWebhookVerifier sends after
// rubyPaypalVerificationPrefix, "" where it sends nothing.
const rubyPaypalVerificationPrefix = `{"auth_algo":"SHA256withRSA","cert_url":"https://api.paypal.com/v1/notifications/certs/CERT-360caa42-fca2a594-a5cafa77","transmission_id":"69cd13f0-d67a-11e5-baa3-778b53f4ae55","transmission_sig":"lmI95Jx3Y9nhR5SJWlHVIWpg4AgFk7n9bCHSRxbrd8A9zrhdu2rMyFrmz+Zjh3s3boXB07VXCXUZy/UFzUlnGJn0wDugt7FlSvdKeIJenLRemUxYCPVoEZzg9VFNqOa48gMkvF+XTpxBeUx/kWy6B5cp7GkT2+pOowfRK7OaynuxUoKW3JcMWw272VKjLTtTAShncla7tGF+55rxyt2KNZIIqxNMJ48RDZheGU5w1npu9dZHnPgTXB9iomeVRoD8O/jhRpnKsGrDschyNdkeh81BJJMH4Ctc6lnCCquoP/GzCzz33MMsNdid7vL/NIWaCsekQpW26FpWPi/tfj8nLA==","transmission_time":"2026-11-10T08:12:10Z","webhook_id":"1JE4291016473214C","webhook_event":`

var railsPaypalRequests = map[string]struct{ contentType, query, body, args, event string }{
	"capture":              {`application/json`, ``, `{"id": "WH-2WR32451HC0233532-67976317FL4543714", "event_version": "1.0", "create_time": "2026-11-10T08:12:09.123Z", "resource_type": "capture", "event_type": "PAYMENT.CAPTURE.COMPLETED", "summary": "Payment completed for $ 7.47 USD", "resource": {"id": "42311647XV020574X", "amount": {"currency_code": "USD", "value": "7.47"}, "final_capture": true, "invoice_id": null, "links": [{"href": "https://api.paypal.com/v2/payments/captures/42311647XV020574X", "rel": "self", "method": "GET"}]}, "links": []}`, `{"id":"WH-2WR32451HC0233532-67976317FL4543714","event_version":"1.0","create_time":"2026-11-10T08:12:09.123Z","resource_type":"capture","event_type":"PAYMENT.CAPTURE.COMPLETED","summary":"Payment completed for $ 7.47 USD","resource":{"id":"42311647XV020574X","amount":{"currency_code":"USD","value":"7.47"},"final_capture":true,"invoice_id":null,"links":[{"href":"https://api.paypal.com/v2/payments/captures/42311647XV020574X","rel":"self","method":"GET"}]},"links":[]}`, `{"id":"WH-2WR32451HC0233532-67976317FL4543714","event_version":"1.0","create_time":"2026-11-10T08:12:09.123Z","resource_type":"capture","event_type":"PAYMENT.CAPTURE.COMPLETED","summary":"Payment completed for $ 7.47 USD","resource":{"id":"42311647XV020574X","amount":{"currency_code":"USD","value":"7.47"},"final_capture":true,"invoice_id":null,"links":[{"href":"https://api.paypal.com/v2/payments/captures/42311647XV020574X","rel":"self","method":"GET"}]},"links":[]}`},
	"raw characters":       {`application/json`, ``, "{\"event_type\":\"PAYMENT.CAPTURE.REFUNDED\",\"summary\":\"<b>&</b>\",\"s\":\"café \\/ \u2028\u2029 😀 \\\"q\\\" \\\\ \\t\\u0001\",\"raw\":\"é\",\"n\":-0,\"f\":1E+2,\"g\":0.1e-5,\"e\":1.0,\"x\":1.10,\"t\":true,\"z\":null}", "{\"event_type\":\"PAYMENT.CAPTURE.REFUNDED\",\"summary\":\"<b>&</b>\",\"s\":\"café / \u2028\u2029 😀 \\\"q\\\" \\\\ \\t\\u0001\",\"raw\":\"é\",\"n\":0,\"f\":100.0,\"g\":0.000001,\"e\":1.0,\"x\":1.1,\"t\":true,\"z\":null}", `{"event_type":"PAYMENT.CAPTURE.REFUNDED","summary":"\u003cb\u003e\u0026\u003c/b\u003e","s":"café / \u2028\u2029 😀 \"q\" \\ \t\u0001","raw":"é","n":0,"f":100.0,"g":0.000001,"e":1.0,"x":1.1,"t":true,"z":null}`},
	"unicode escapes":      {`application/json`, ``, `{"event_type":"PAYMENT.CAPTURE.REFUNDED","s":"\u00e9 \ud83d\ude00 \u2028 \u003c \/"}`, "{\"event_type\":\"PAYMENT.CAPTURE.REFUNDED\",\"s\":\"é 😀 \u2028 < /\"}", `{"event_type":"PAYMENT.CAPTURE.REFUNDED","s":"é 😀 \u2028 \u003c /"}`},
	"infinity":             {`application/json`, ``, `{"event_type":"PAYMENT.CAPTURE.COMPLETED","resource":{"rate":1e400}}`, ``, `{"event_type":"PAYMENT.CAPTURE.COMPLETED","resource":{"rate":null}}`},
	"merchant with query":  {`application/json`, `?format=json&x=1&event_type=ignored`, `{"event_type":"MERCHANT.ONBOARDING.COMPLETED","resource":{"merchant_id":"ABC"},"action":"x","controller":"y","foreign_webhook":"z","format":"f"}`, `{"event_type":"ignored","resource":{"merchant_id":"ABC"},"x":"1"}`, `{"event_type":"MERCHANT.ONBOARDING.COMPLETED","resource":{"merchant_id":"ABC"},"action":"x","controller":"y","foreign_webhook":"z","format":"f"}`},
	"dispute":              {`application/json`, ``, `{"event_type":"CUSTOMER.DISPUTE.CREATED","resource":{"dispute_id":"PP-D-1","disputed_transactions":[{"seller_transaction_id":"1"}],"dispute_amount":{"value":"10.00"}},"empty":{},"list":[1,2.50,"a"]}`, `{"event_type":"CUSTOMER.DISPUTE.CREATED","resource":{"dispute_id":"PP-D-1","disputed_transactions":[{"seller_transaction_id":"1"}],"dispute_amount":{"value":"10.00"}},"empty":{},"list":[1,2.5,"a"]}`, `{"event_type":"CUSTOMER.DISPUTE.CREATED","resource":{"dispute_id":"PP-D-1","disputed_transactions":[{"seller_transaction_id":"1"}],"dispute_amount":{"value":"10.00"}},"empty":{},"list":[1,2.5,"a"]}`},
	"legacy ipn":           {`application/x-www-form-urlencoded`, ``, `txn_type=masspay&payment_status=Completed&masspay_txn_id_1=7&unique_id_1=12&payer_email=pay%40example.com&charset=UTF-8`, `{"txn_type":"masspay","payment_status":"Completed","masspay_txn_id_1":"7","unique_id_1":"12","payer_email":"pay@example.com","charset":"UTF-8"}`, ``},
	"form with event_type": {`application/x-www-form-urlencoded`, ``, `event_type=PAYMENT.CAPTURE.REFUNDED&resource[id]=1&resource[amount]=a%26b`, `{"event_type":"PAYMENT.CAPTURE.REFUNDED","resource":{"id":"1","amount":"a&b"}}`, `{"event_type":"PAYMENT.CAPTURE.REFUNDED","resource":{"id":"1","amount":"a\u0026b"}}`},
	"empty json body":      {`application/json`, `?event_type=PAYMENT.CAPTURE.DENIED&a[]=1`, ``, `{"event_type":"PAYMENT.CAPTURE.DENIED","a":["1"]}`, `{"event_type":"PAYMENT.CAPTURE.DENIED","a":["1"]}`},
	"text body":            {`text/plain`, `?event_type=PAYMENT.CAPTURE.DENIED`, `not json`, `{"event_type":"PAYMENT.CAPTURE.DENIED"}`, `{"event_type":"PAYMENT.CAPTURE.DENIED"}`},
}
