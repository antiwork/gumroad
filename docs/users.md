# Users & authentication

## Users

Running `bin/rails db:prepare` seeds the database with the following users:

| Email                           | Password   | Team Role  | Internal Admin |
| ------------------------------- | ---------- | ---------- | -------------- |
| `seller@gumroad.com`            | `password` | Owner      | ✔             |
| `seller+admin@gumroad.com`      | `password` | Admin      | ✘              |
| `seller+marketing@gumroad.com`  | `password` | Marketing  | ✘              |
| `seller+support@gumroad.com`    | `password` | Support    | ✘              |
| `seller+accountant@gumroad.com` | `password` | Accountant | ✘              |

### Primary user

The primary user is `seller@gumroad.com`. This user also:

- is an internal admin (can visit `/admin`)
- has payout privilege
- has risk privilege
- is eligible to create service products (has an account older than `User::MIN_AGE_FOR_SERVICE_PRODUCTS`)

### Team users

The other users allow testing specific team roles on primary user's store: admin, marketing, support, and accountant. They have no internal admin access and no special privileges.

(Note: `seller+admin@gumroad.com` is a store admin, not an internal admin.)

## Two-factor authentication

All non-production environments accept `000000` as a two-factor authentication code.
