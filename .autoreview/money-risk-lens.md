# Domain lens: admin web UI removal touching payout/chargeback/payment surfaces

This PR deletes the Gumroad admin WEB UI (controllers, views, JS) while claiming to KEEP the
programmatic `Api::Internal::Admin::*` surface the CLI depends on. Several deleted files sit on
money/risk paths: `admin/payouts_controller.rb`, `admin/scheduled_payouts_controller.rb`,
`admin/users/payout_infos_controller.rb`, `admin/users/payouts_controller.rb`,
`admin/payment_presenter.rb`, `admin_mailer/chargeback_notify.html.erb`,
`admin_mailer/low_balance_notify.html.erb`. Review with these numbered checks:

1. **No live caller left behind.** For every deleted `Admin::*` controller/presenter/service, grep
   `app/`, `lib/`, and the KEPT `Api::Internal::Admin::*` controllers for references. A kept
   controller silently `render`-ing a deleted view or calling a deleted presenter is a 500 on the
   CLI's live path, not a web-only regression.
2. **Chargeback / low-balance mailer views kept?** `admin_mailer/chargeback_notify.html.erb` and
   `admin_mailer/low_balance_notify.html.erb` are listed as deleted files in the diff — the PR body
   claims `AdminMailer` itself is KEPT (sent from `Charge::Disputable` and
   `User::LowBalanceFraudCheck`). If the views are deleted but the mailer methods that render them
   are not, that's a `ActionView::MissingTemplate` raised from a background job the moment a real
   dispute/low-balance event fires — silent until it happens, then it eats the whole job. Confirm
   whether these are deletions of the template plus the caller, or an inconsistency.
3. **Payout controllers: was anything read-only they exposed also consumed by `AdminActionTracker`
   dashboards or another surface not itself being deleted in the same commit?** Deleting the
   tracker AND its only readers together is fine; deleting one and leaving the other orphaned is
   not.
4. **Assertions inventoried in the PR body (`AdminActionCallInfo`: 33 calls / 6 distinct actions)
   — are these numbers reproducible from the stated query, not just asserted?** If a script or
   console query backs the count, note whether it's included/reproducible; if not, flag as an
   unverified completeness claim per this shop's standing convention (self-computed numbers must
   be independently verifiable).
5. **Auth/impersonation surface kept correctly scoped.** `Impersonate` concern + `/admin/impersonate`,
   `/admin/unimpersonate` are kept. Confirm the slimmed `Admin::BaseController` that survives still
   carries whatever admin-only auth/session check gated the deleted controllers — i.e. the kept
   impersonate routes aren't left reachable by a weaker guard than before.
6. **Spec deletions matched 1:1 with code deletions**, and no orphaned `require`/`shared_examples`
   references remain pointing at deleted spec support files.
7. **Routes file (`config/routes/admin.rb`) fully reflects the controller deletions** — no route
   entry survives pointing at a deleted controller action (would 500 on request, not at boot).
