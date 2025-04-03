# Taxes

## Metadata

_Written by: @curtiseinsmann_

_Last updated: 2025-01-30_

## Purpose

This document is intended to be a reference for Gumroad's tax collection and compliance requirements as of the date of this writing. It will cover:

- A brief history of Gumroad's tax collection requirements
- The current state of Gumroad's tax collection requirements
- The future goals of Gumroad from a tax collection context

## A Brief History of Gumroad's Tax Collection Requirements

Gumroad has collected taxes in a multitude of ways over the years. Each jurisdiction has its own unique requirements and Gumroad has had to adapt to these requirements over time.

Here are some examples of things that Gumroad has supported in the past, that it doesn't anymore, but where ghosts of the past may still haunt the business logic within the codebase:

- Creator tax responsibility
- Taxation based on whether or not a product is recommended
- Allowing creators to set the tax rate for their products
- Allowing creators to decide which tax jurisdictions they'd like to collect taxes from
- Allowing creators to set tax exclusivity for their products
- Having a distinction on whether taxes are Gumroad's responsibility or the creator's responsibility

## The Current State of Gumroad's Tax Collection Requirements

As of 2025, Gumroad is a Merchant of Record. This means that Gumroad is responsible for collecting and remitting taxes on behalf of the creator. Gumroad will collect and remit taxes for all jurisdictions where Gumroad meets certain tax collection requirements. The creator no longer needs to worry about tax collection requirements.

Whether or not Gumroad qualifies for tax collection in a particular jurisdiction varies from jurisdiction to jurisdiction. These requirements can be quite complex, and are outside the scope of this document. Basically, from the engineer's perspective, if Steven Olson tells us that Gumroad needs to start collecting taxes in a particular jurisdiction, we should change Gumroad to do so. Steven Olson is in touch with various tax authorities, and is the point of contact for Gumroad's tax collection requirements.

### Technical Details

#### Tax Collection

One should be encouraged to use the codebase as a source of truth for how Gumroad collects taxes. This section describes the high-level technical details.

The key field on the `Purchase` model is `gumroad_tax_cents`. This field is used to store the tax amount that Gumroad is responsible for. In order to calculate this field, Gumroad uses the `SalesTaxCalculator` class. It is within this class that the logic for tax calculation is implemented. After tax calculation, the result is stored in the `gumroad_tax_cents` field on the `Purchase` model.

The exact logic for tax calculation depends on which jurisdiction the sale goes into. Those will be described in the following jurisdiction-specific sections.

#### Tax Reporting

Gumroad is required to report transactions and taxes to certain authorities, in various different formats. To understand what kinds of reports exist, and how they are generated, see sidekiq_schedule.yml, and the various classes that are scheduled. Searching for `report` case-insensitive within sidekiq_schedule.yml will give you a good starting point.

Up to this point, reporting formats vary, and are not consistent across jurisdictions. Steven Olson has different requirements for different jurisdictions, and thus the result is different reporting formats. As we start adding more jurisdictions, we may want to consider consolidating these reporting formats into a more unified format, so that we can scale as we add more jurisdictions.

For certain states in the United States (Ohio, Wisconsin, North Carolina, New Jersey, Pennsylvania, and Washington), we auto-file taxes through TaxJar. This is done by creating a TaxJar transaction record in an async job called `CreateDiscoverSalesReportsJob`. In 2025, we will need to add more states to this list, as we've started collecting taxes in more states. We will also need to adjust this job to include a broader scope of purchases into these states, because we've started collecting taxes on more types of purchases, rather than just Discover sales.

### United States

Gumroad collects taxes on sales into certain states. These are represented by `TAXABLE_US_STATE_CODES` in the codebase.

Gumroad uses TaxJar to calculate sales tax for the United States. TaxJar is a third-party tax calculation service.

### Canada

Gumroad collects taxes on all sales into Canada. Gumroad uses TaxJar to calculate sales tax for Canada.

### Tax on All Sales In Certain Countries

Gumroad collects taxes on all sales into certain countries. These countries include:

- Australia
- Singapore
- Norway
- Canada
- All countries in the European Union, represented by `EU_VAT_APPLICABLE_COUNTRY_CODES`
- Japan (by way of a feature flag, explained below - activated as of January 1, 2025)
- India (by way of a feature flag, explained below - activated as of January 1, 2025)
- Switzerland (by way of a feature flag, explained below - activated as of January 1, 2025)

Taxes for these countries are calculated by using `ZipTaxRate` entities as a lookup table.

### Tax on All Digital Sales In Certain Countries

Gumroad collects taxes on all _digital_ sales into certain countries. We assume that all sales are digital, except for physical products. Creators can no longer create physical products as of 2025. However, Gumroad still supports the sale of physical products that were created before 2025, and thus needs to support business logic that taxes these sales into account when making calculations.

These countries include:

- South Korea (by way of a feature flag, explained below)
- Mexico (by way of a feature flag, explained below)

Taxes for these countries are calculated by using `ZipTaxRate` entities as a lookup table.

### Stripe Countries (and feature flags)

When we rolled out Merchant of Record on January 1, 2025, the goal was to:

1. Collect taxes on sales into jurisdictions for which Gumroad has responsibility
2. Be prepared to collect taxes on sales into jurisdictions for which Gumroad may have responsibility in the near future

To satisfy (2), we created a feature flag for each country where Gumroad may have responsibility in the near future. We took a snapshot of the [countries listed on Stripe's supported countries](https://docs.stripe.com/tax/supported-countries) page in late December 2024.

The feature flag looks like this: `collect_tax_<country_code>`. For example, the feature flag for Chile is `collect_tax_cl`.

The feature flag is used to determine whether Gumroad should collect taxes on sales into a jurisdiction. The feature flag is used in the `SalesTaxCalculator` class.

When Steven Olson tells us that Gumroad needs to start collecting taxes in a particular jurisdiction, we enable the feature flag for that jurisdiction. For good measure, the engineer should proofread the codebase and understand the implications of enabling the feature flag. Those implications should be confirmed with Steven Olson before the feature flag is enabled.

### Tax Exemption

For certain jurisdictions, customers may be exempt from taxes if they provide some sort of valid tax identification number. To name a couple of examples, this would be the Australian Business Number (ABN) for Australia, or the GST Identification Number for Singapore.

Validation of these tax identification numbers is handled within the `SalesTaxCalculator` class, as well as a few other places. We use different validation services for different jurisdictions. Eventually, we will want to consolidate these validations into a single dependency, probably using Tax ID Pro, which is used for most jurisdictions as of this writing.

## The Future Goals of Gumroad from a Tax Collection Context

The launch of Merchant of Record greatly simplified Gumroad's tax collection requirements, as well as the Gumroad offer to creators. It opened up the door for more simplification of the product. The following sections will enumerate over these opportunities.

All of these opportunities will only be possible if Gumroad is able to somehow remove its dependency on PayPal. PayPal was removed from Gumroad in late 2024, but has since been re-added.

### Migration to Stripe Tax

Stripe Tax is a third-party tax calculation service that Stripe offers. It is a powerful tool that Gumroad could use to simplify its tax collection requirements.

A migration to Stripe Tax would open up the opportunity to:

- Remove tax calculation logic from Gumroad's codebase
- Remove the dependency on TaxJar

### Tax Calculation Accuracy

A migration to Stripe Tax would also provide a better opportunity for more accurate tax calculation. In the current state, Gumroad assumes all products are digital, except for physical products. This is a simplification that may not always be accurate. Stripe Tax provides support for [product tax codes](https://docs.stripe.com/tax/tax-codes). Integrating these tax codes into Gumroad would allow Gumroad to more accurately calculate taxes on sales.

### Removal of creator-owned Merchant Accounts

Merchant of Record opens up the opportunity to remove creator-owned Merchant Account integrations from the platform.

With creator-owned Merchant Accounts removed, all transactions would be processed through Gumroad's Stripe account. This would simplify the Gumroad offer to creators, as well as the Gumroad codebase.
