Reported by Aditya Garud (garudaditya079@gmail.com, github.com/yashranaway) by email to hi@gumroad.com, forwarded to support@ by Sahil with "Investigate and fix". Gmail thread `1a17d6f5393330f7`.

## What was reported

Large payout exports (>10 MB) are uploaded to S3 and emailed as a 7-day presigned link. The object key was the emailed attachment name, `Payout of <date>.csv`, with nothing unique in it. Payouts are exported in batches, so every seller paid on a date shares that name; a second seller exporting within the week overwrote the object behind the first seller's link, and the first link then downloaded the second seller's file, which is that period's buyer names and emails. The multi-payout zip was worse: `Payouts.zip`, no date at all.

## What I verified

Confirmed by code read against `origin/main`, then reproduced with a spec that fails on `main`.

- `app/sidekiq/export_payout_data.rb` builds `"Payout of #{payment.created_at.to_date}.csv"` for a single payout and `"Payouts.zip"` for several, and passes it to the mailer as `filename`.
- `app/mailers/contacting_creator_mailer.rb#payout_data` hands that name to `MailerAttachmentOrLinkService` as `filename:`, which passes it to `ExpiringS3FileService`. With no `path:`, `@key = filename`, so over `MAX_FILE_SIZE` (10 MB) the key is the shared attachment name at the bucket root, presigned for `7.days`.
- Swept the sibling exports on the same service: `user_sales_data` (`user-sales-data/Sales_<id>_<epoch>_<hex>.csv`) and `tax_form_transaction_report` (`1099k-transaction-reports/1099-K-transactions_<year>_<id>_<hex>.csv`) already key uniquely; `affiliates_data` and `subscribers_data` pass filenames carrying the seller's username and a timestamp. `payout_data` was the only path taking the shared attachment name as the key.

Impact: two same-date payout exports over 10 MB served each other's buyer names and emails to the wrong seller for up to 7 days. Over 10 MB correlates with the largest sellers, i.e. the files with the most buyer rows.

## Fix shipped

PR #8683 `Upload large payout exports under a key unique to the recipient`, merged as ff18db1bda9, credited to the reporter as co-author. Key becomes `payout-data/Payouts_<recipient id>_<epoch>_<random hex>.<extension>`; the attachment name is unchanged, so the email looks the same.

Spec: `bundle exec rspec spec/mailers/contacting_creator_mailer_spec.rb -e "payout_data"` -> 4 examples, 0 failures. Both new examples fail with the mailer reverted to `origin/main`; the second one is the behavioural regression test (two over-size exports with the same attachment name produce two different keys), added after Greptile flagged that the first only asserted the constructor argument.

## Still open: were existing objects already overwritten?

The reporter's other point, which the fix does not address. The bucket root keys are `Payout of <date>.csv` and `Payouts.zip`, so today's listing can only show which dates were exported, not how many sellers wrote to them. Whether a past overwrite happened is answerable only if the bucket has versioning (then version counts per key show collisions) or server access logs / CloudTrail data events cover bucket writes. Without one of those, the exposure is unknowable retroactively and the honest statement is "we cannot say", not "nothing happened".

rung: Confirmed. Shared attachment name reused as the S3 object key for over-10 MB payout exports, in `ContactingCreatorMailer#payout_data`.

## Progress

- [x] Reproduce and confirm the shared key on current `main`
- [x] Sweep the other exports on `MailerAttachmentOrLinkService` for the same shape
- [x] Ship the unique key with a failing-first spec (#8683)
- [ ] Check S3 versioning and write access logs for the payout-export keys, to establish whether any past overwrite occurred
- [ ] If versioning exists, enumerate keys with more than one version and identify the affected dates
- [ ] Tell the reporter the outcome of the historical check, since they asked for it explicitly and are holding public disclosure until we have shipped
