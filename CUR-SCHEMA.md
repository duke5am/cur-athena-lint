# CUR schema: the columns that actually matter

The Cost and Usage Report is not a normal table. It is a wide, sparse,
configuration-dependent export where **the same concept appears in several
columns** and **the meaning of a column depends on another column's value**.
Most bad AWS cost numbers come from one of those two facts.

This file explains:

1. [Which cost column to use, and why](#1-which-cost-column-to-use)
2. [`line_item_line_item_type` — the column that changes what every other
   column means](#2-line_item_line_item_type)
3. [`line_item_*` columns](#3-line_item-columns)
4. [`bill_*` columns](#4-bill-columns)
5. [`product_*` columns](#5-product-columns)
6. [`resource_tags_*` columns (and the untagged reality)](#6-resource_tags-columns)
7. [`reservation_*` columns](#7-reservation-columns)
8. [`savings_plan_*` columns](#8-savings_plan-columns)
9. [`pricing_*` columns](#9-pricing-columns)
10. [`discount_*` columns](#10-discount-columns)
11. [Column naming: snake_case vs the `lineItem/` header form](#11-column-naming)
12. [How to verify against YOUR table](#12-verify-against-your-table)
13. [About CUR 1.0 vs CUR 2.0](#13-cur-10-vs-cur-20)
14. [What this document verified, and what it did not](#14-verification-notes)

---

## 1. Which cost column to use

There is no column called "cost". There are three, and each answers a
different question.

| Column | What it is | Use it for | Do NOT use it for |
|---|---|---|---|
| `line_item_unblended_cost` | The rate *your account* was charged, multiplied by usage. Amazon defines it as "the UnblendedRate multiplied by the UsageAmount". | "What did we actually get charged?" — cash view | Comparing accounts inside an Organization; anything involving Reserved Instances |
| `line_item_blended_cost` | The blended rate multiplied by usage. Amazon describes the blended rate as "the average cost incurred for each SKU across an organization", calculated at the management account level and used to allocate cost to member accounts. | "What is this member account's *share* of the organization's committed spend?" | "What did we spend?" — it is an allocation figure, and Amazon documents it as blank for line items with a `LineItemType` of `Discount` |
| Amortized cost (derived) | One-time reservation and Savings Plan fees spread across the period they benefit | "What did this month's *usage* cost, including the commitment behind it?" — accrual view | Reading the invoice; it will not match a cash total |

### The problem with unblended cost and Reserved Instances

Amazon states that for EC2 and RDS line items that have an RI discount
applied, **the UnblendedRate is 0**, and those line items have a
`LineItemType` of `DiscountedUsage`. The money does not vanish — it appears
once, as a `RIFee` line for the whole month.

Practical consequence: **sum `line_item_unblended_cost` alone and RI-covered
usage looks nearly free.** An account that buys a large All Upfront RI will
show a *low* unblended cost in the month after purchase and a *high* one in
the month of purchase. Neither is the running cost of the workload.

### Amortization, in Amazon's own words

> "Amortizing is when you distribute one-time reservation costs across the
> billing period that is affected by that cost. Amortizing enables you to see
> your costs in accrual-based accounting as opposed to cash-based accounting.
> For example, if you pay $365 for an All Upfront RI for one year and you have
> a matching instance that uses that RI, that instance costs you $1 a day,
> amortized."

— *Understanding your amortized reservation data*, AWS CUR User Guide.

The documented components are:

* `reservation_amortized_upfront_fee_for_billing_period` — the part of an
  upfront RI fee that belongs to this billing period (populated on `RIFee`
  line items).
* `reservation_amortized_upfront_cost_for_usage` — that upfront fee allocated
  to *this usage* (populated on `DiscountedUsage` line items).
* `reservation_recurring_fee_for_usage` — the recurring fee amortised for
  usage time (partial-upfront and no-upfront RIs; populated on
  `DiscountedUsage` line items).
* `reservation_effective_cost` — "the sum of both the upfront and hourly rate
  of your RI, averaged into an effective hourly rate", calculated as
  amortizedUpfrontCostForUsage plus recurringFeeForUsage.

### ⚠ The important caveat about the "amortized cost" expression

The queries in this pack compute:

```
amortized_cost = line_item_unblended_cost
               + reservation_amortized_upfront_fee_for_billing_period
               + reservation_recurring_fee_for_usage
```

**This is a widely used CUR idiom, not an Amazon-published formula.** Amazon
documents what each component means and what amortization is; it does not
publish `amortized cost = A + B + C`. Treat the expression as a starting
point that you must validate against Cost Explorer for one month before you
rely on it. `queries/15-RECONCILE-TO-COST-EXPLORER.sql` and
`docs/VALIDATION.md` are exactly that procedure.

### Quick decision guide

| Question you are answering | Column to use |
|---|---|
| "Why did the invoice go up?" | `line_item_unblended_cost`, all line item types included |
| "What does this workload cost per month, steady state?" | amortized expression above |
| "What is this member account's share of our EDP commitment?" | `line_item_blended_cost` |
| "What would this have cost without any discount?" | `pricing_public_on_demand_cost` |
| "What did the RI/SP benefit actually save?" | `reservation_effective_cost` / `savings_plan_savings_plan_effective_cost` vs `pricing_public_on_demand_cost` |
| "What did I pay and not use?" | `reservation_unused_*` / `savings_plan_used_commitment` (see §7, §8) |

---

## 2. `line_item_line_item_type`

**This is the single most important column in CUR.** It determines what
`line_item_unblended_cost` means on that row, and whether including the row
in a total double-counts, hides, or correctly represents cost.

The values below are the ones Amazon documents for the CUR line item
`LineItemType` field. (`FlatRateSubscription`, `Discount` and
`BundledDiscount` are documented; see §14 for exactly which page each came
from.)

| Value | What it means | Count it in "what we spent"? | Trap |
|---|---|---|---|
| `Usage` | Usage charged at On-Demand rates | **Yes** | None. This is the baseline row type |
| `DiscountedUsage` | Usage that received a Reserved Instance benefit | **Yes** | `line_item_unblended_cost` is ~0 (UnblendedRate is 0 for these). The real cost is in `reservation_effective_cost`, or in the `RIFee` line |
| `SavingsPlanCoveredUsage` | On-Demand cost covered by a Savings Plan — recorded **at the on-demand list price** | **Yes, but only with the negation** | **Counting this without its `SavingsPlanNegation` DOUBLE-COUNTS the SP-covered spend** |
| `SavingsPlanNegation` | The negative offset that cancels the corresponding covered usage | **Yes** (it is negative) | Dropping it because "it's not real usage" inflates the total by the full SP-covered amount |
| `RIFee` | The monthly recurring fee for reservations (Partial Upfront, No Upfront, and a $0 line for All Upfront) | **Yes** | Skipping it makes all RI spend disappear. A `RIFee` line is also populated at $0 for All Upfront RIs purely to carry reservation columns |
| `SavingsPlanRecurringFee` | Recurring hourly charges for a No Upfront or Partial Upfront Savings Plan | **Yes** | It is *hourly*, unlike the RECURRING RI FEE which is monthly. Do not model them the same way |
| `SavingsPlanUpfrontFee` | One-time upfront fee from purchasing an All Upfront or Partial Upfront Savings Plan | **Yes** | A large one-off. If you plot it as a monthly rate you will misread the trend |
| `Fee` | An upfront annual fee for subscriptions (e.g. the upfront fee on an All Upfront or Partial Upfront RI) | **Yes** | Also used for other subscription fees |
| `Tax` | Tax Amazon applied (VAT, US sales tax) | Depends — include for "what do I pay", exclude for "what did I consume" | Tax rows frequently have a NULL product code, so they hide inside a NULL service in a "cost by service" view |
| `Credit` | Credits Amazon applied to your bill | Include as a **negative** | Amazon may update reports after finalisation when a credit is applied for a previous month |
| `Refund` | Negative charges Amazon refunded | Include as a **negative** | Same late-update behaviour |
| `Discount` | A discount Amazon applied to your usage. Amazon notes the specific line item name **may vary and require parsing**, and points you at `line_item_line_item_description` | Yes — but understand what it represents before netting it off | `line_item_blended_cost` is blank on these rows |
| `BundledDiscount` | A usage-based discount giving free/discounted usage of one service based on usage of another | Yes | Not the same as `Discount`; different mechanism, same field |
| `FlatRateSubscription` | An hourly subscription fee for services with a subscription fee (Amazon's documented example: Kiro Enterprise) | Yes | Recently added; if you hardcoded a list of line item types, it is missing from yours |

### The three ways people get this wrong

1. **Counting `SavingsPlanCoveredUsage` and forgetting the negation.**
   Amazon documents that covered-usage line items "are offset by the
   corresponding Savings Plan negation items". Count one side and you invent
   cost that never existed — often a large fraction of a compute bill.
   Note that one `SavingsPlanNegation` can correspond to *several*
   `SavingsPlanCoveredUsage` rows, because negations are grouped at the hour
   level by Savings Plan ARN, operation, usage type and Availability Zone.
2. **Excluding `RIFee` because the description looks like a fee, not usage.**
   That is the entire cost of your reservations.
3. **Treating `Tax`, `Credit` and `Refund` as noise.** They are not noise if
   you are reconciling to an invoice; they are noise if you are measuring
   workload efficiency. Decide which question you are answering and be
   consistent.

### ⚠ Values that sound plausible but are NOT documented line item types

The task of "include every discount type" tempts people to write
`'EdpDiscount'`, `'PrivateRateDiscount'`, `'ReservedInstance'` or
`'SpotInstances'` into a `WHERE` clause. **None of those is in Amazon's
documented list of line item type values.** Enterprise Discount Program and
private-rate effects surface as `Discount` (with the detail in
`line_item_line_item_description`), not as a line item type. Writing a
non-existent value is not an error — it just silently matches nothing, which
is worse. See §14 for how this was checked.

---

## 3. `line_item_*` columns

Columns under the line item header are documented as **static fields that
appear in all Cost and Usage Reports**.

| Column (Athena name) | Meaning | Notes and traps |
|---|---|---|
| `line_item_usage_start_date` | Start of the line item's usage period, UTC, inclusive. Format `YYYY-MM-DDTHH:mm:ssZ`. **TIMESTAMP** | The column you group by for daily/monthly analysis |
| `line_item_usage_end_date` | End of the usage period, UTC, **exclusive** | Exclusive — so a day's usage is `>= day AND < day+1` |
| `line_item_line_item_type` | See §2 | The meaning-switch for the whole row |
| `line_item_usage_type` | The usage detail, e.g. `USW2-BoxUsage:m2.2xlarge`. **STRING** | Highest-cardinality useful column. The right grain for "what changed" |
| `line_item_operation` | The operation, e.g. `RunInstances` | Often blank for managed services |
| `line_item_product_code` | Billing product code, e.g. `AmazonEC2`. **Not a friendly name** | This is the column to use as "service" |
| `line_item_usage_account_id` | Account ID that used the line item. For Organizations this can be the management account or a member account | Present in all reports |
| `line_item_usage_account_name` | Account *name* that used the line item | A CUR **2.0** column. Not assumed by this pack's queries |
| `line_item_resource_id` | **Optional.** Present only if you chose to include resource IDs. Amazon documents it as blank for usage types not associated with an instantiated host — data transfers, API requests — and for discounts, credits and taxes | The single biggest source of "my report doesn't add up". See §6 and `queries/05-COST-BY-RESOURCE.sql` |
| `line_item_usage_amount` | Amount of usage in the period | Units differ per usage type (GB-Mo, Hrs, Requests). Never sum across usage types. For size-flexible RIs, Amazon says to use `reservation_total_reserved_units` instead. Certain subscription charges have a usage amount of 0 |
| `line_item_unblended_cost` | See §1. **DOUBLE** | |
| `line_item_unblended_rate` | Rate per unit for this account's usage. **STRING** | Documented as 0 for EC2/RDS line items with an RI discount |
| `line_item_blended_cost` | See §1. **DOUBLE** | Blank for `Discount` line items |
| `line_item_blended_rate` | Average cost per SKU across the organization. **STRING** | A management-account-level allocation construct |
| `line_item_currency_code` | Currency of the line item. All AWS customers are billed in USD by default | If this is not `USD`, your numbers are in another currency and any comparison with a USD baseline is wrong |
| `line_item_legal_entity` | Seller of Record for the product or service | Can differ from the invoicing entity for third-party AWS Marketplace transactions |
| `line_item_availability_zone` | AZ hosting the line item, e.g. `us-east-1a` | Blank for regional and global services |
| `line_item_line_item_description` | Free-text description of the line item | **This is where `Discount` detail lives** — Amazon explicitly points here when the discount name varies |
| `line_item_normalization_factor` | Size-flexibility factor for EC2/RDS RIs | Used to spread a size-flexible RI across instance sizes |
| `line_item_normalized_usage_amount` | Usage in normalized units = `usage_amount × normalization_factor` | The comparable unit across sizes |
| `line_item_tax_type` | Type of tax applied | Only populated on tax rows |

### `line_item_net_unblended_cost` — a column this pack deliberately does not use in queries

Amazon documents `line_item_net_unblended_cost` as "the actual after-discount
cost that you're paying for the line item", **included in your report only
when your account has a discount in the applicable billing period**. As the
name implies, it is the post-discount sibling of `line_item_unblended_cost`.

It is deliberately **not** used in this pack's queries, because:

* it is only present when a discount applies in that period, so a query
  referencing it fails on reports/periods where it does not exist;
* the "net" family also includes `line_item_net_unblended_rate`, and
  legacy-header forms do not line up one-to-one with the snake_case form.

If your table has it (check with `DESCRIBE`), it is the right column for an
after-discount cash view. Add it to a copy of the query rather than to the
shipped one. See §14.

---

## 4. `bill_*` columns

Billing-period and payer information. These describe the *invoice document*,
not the usage.

| Column | Meaning | Notes |
|---|---|---|
| `bill_billing_period_start_date` | Start of the billing period. **TIMESTAMP** | Use this instead of calendar months when you need to match the invoice |
| `bill_billing_period_end_date` | End of the billing period. **TIMESTAMP** | |
| `bill_invoice_id` | The invoice this line belongs to | Useful for splitting a report by invoice |
| `bill_payer_account_id` | The payer (management) account | The account that receives the bill |
| `bill_billing_entity` | The AWS entity that issued the bill | |
| `bill_bill_type` | The type of bill | |
| `bill_invoicing_entity` | The entity that invoiced you | Legacy `bill/InvoicingEntity`. In CUR 2.0 this is documented as `bill_billing_entity` |

**Trap:** `bill_invoice_id` and `bill_billing_period_*` are frequently
**blank on non-usage rows** such as credits and refunds that Amazon applied
after the period closed. A query that filters `bill_invoice_id IS NOT NULL`
will silently drop credits. Do not filter on bill columns unless you have
checked what you are dropping.

**Trap:** monthly-granularity reports can place all usage for a resource in
one row for the billing period, with `line_item_usage_start_date` equal to
the period start. Daily grouping on such a report returns one bucket, not
thirty. See `docs/VALIDATION.md`.

---

## 5. `product_*` columns

The `product/` family is the largest in CUR — Amazon's published
attribute-per-service list runs to hundreds of attributes across services.
The Athena column names are `product_<attribute>`, lowercased.

The ones this pack's queries rely on, all of which appear in the standard
export and Amazon's published attribute list:

| Column | Meaning | Notes |
|---|---|---|
| `product_product_name` | Human-readable product name | Similar to but not identical to `line_item_product_code` |
| `product_product_family` | Product family, e.g. `Compute Instance`, `Storage` | |
| `product_instance_type` | Instance type, e.g. `m5.xlarge` | **Lowercase `i`** — the column is `product_instance_type` |
| `product_instance_family` | Instance family, e.g. `m5` | |
| `product_instance_type_family` | Instance type family | Amazon publishes this attribute as `instanceTypeFamily` |
| `product_instance_size` | Instance size, e.g. `xlarge` | |
| `product_tenancy` | `Shared`, `Dedicated`, `Host` | |
| `product_operating_system` | OS, e.g. `Linux`, `Windows` | |
| `product_region` | Region code, e.g. `us-east-1` | |
| `product_location` | Full location name, e.g. `US East (N. Virginia)` | |
| `product_location_type` | `AWS Region`, `Availability Zone` | |
| `product_from_location` / `product_to_location` | Transfer endpoints | Populated for *some* services only |
| `product_from_location_type` / `product_to_location_type` | Transfer endpoint types | Same caveat |
| `product_storage_class` | S3 storage class | Populated only for storage usage types |
| `product_storage_type` | Storage type | |
| `product_servicecode` | Product code | |
| `product_volume_api_name` | EBS volume type API name, e.g. `gp3` | **Lowercase `api`** — `product_volume_api_name` |
| `product_database_engine` | Database engine | |
| `product_licence_model` | Licence model | Spelling follows Amazon's published attribute (`licenseModel` → `product_license_model` in some tables, `product_licence_model` in others). **Both spellings exist in the wild — verify with `DESCRIBE` before using either.** This pack's queries use none of them, for that reason |
| `product_operation` | Product-level operation | Distinct from `line_item_operation` |
| `product_sku` | SKU | |
| `product_usagetype` | Usage type (product-side copy) | Distinct from `line_item_usage_type` |

**Trap:** the `product/` family is why `SELECT *` on CUR is so expensive.
Reading the product columns costs more than reading every cost column, and
most queries need two or three of them. See `docs/COST-CONTROL-ATHENA.md`.

---

## 6. `resource_tags_*` columns

Resource tags appear as `resource_tags_user_<tag_key>`, lowercased, with
separators converted to underscores:

| Your tag key | Athena column |
|---|---|
| `Team` | `resource_tags_user_team` |
| `cost-center` | `resource_tags_user_cost_center` |
| `Environment` | `resource_tags_user_environment` |

### The honest reality: most spend is untagged, and some cannot be tagged

Two separate reasons, and conflating them causes bad decisions:

1. **The tag exists on the resource but was never activated as a cost
   allocation tag**, so it is absent from CUR entirely. A tag can be on every
   resource in the account and still be missing from the report.
2. **The cost has no resource at all.** Amazon documents
   `line_item_resource_id` as blank for usage types "that aren't associated
   with an instantiated host, such as data transfers and API requests, and
   line item types such as discounts, credits, and taxes". No resource means
   no resource tags. This spend is **structurally untaggable** — no amount of
   tagging discipline fixes it. It includes S3 request charges, data
   transfer, Lambda invocations, tax, credits, and every RI and Savings Plan
   fee.

Point 2 is the one people miss. It sets a hard ceiling on tag-based
allocation, and the ceiling is usually well below 100%. The supported route
for attributing that remainder is **cost categories** (the
`cost_category_*` columns), not a cleverer `CASE` expression.

### Other tag traps

* Tags are recorded **as of the time the charge was recorded**, not as of
  today. Re-tagging a resource does not rewrite history.
* Tag **values are case-sensitive**. `Prod` and `prod` are two categories.
* Tags on the *billing* dimension do not exist — you get resource tags only.
* Some reports expose tags as a `MAP` rather than as one column per key
  (Amazon's Athena column type helper treats `resource_tags`, `tags`,
  `cost_category` and `product` as `MAP` in some table definitions). A
  one-column-per-key table and a map-typed table need different SQL. Check
  with `DESCRIBE`.

---

## 7. `reservation_*` columns

Reserved Instance columns. **Amazon is explicit that they are populated by
line item type**: "Not all reservation/ columns are populated for every
Reserved Instance line item. The reservation/ columns in your report are
populated based on the line item type."

| Column | Line items where it is populated | Meaning |
|---|---|---|
| `reservation_reservation_a_r_n` | RI lines | The reservation ARN |
| `reservation_start_time` / `reservation_end_time` | RI subscription (`RIFee`) lines | Term boundaries |
| `reservation_modification_status` | RI subscription lines | Whether the RI was modified/exchanged |
| `reservation_upfront_value` | RI subscription lines | The upfront amount |
| `reservation_number_of_reservations` | RI lines | Count |
| `reservation_units_per_reservation` | RI lines | Units per RI |
| `reservation_total_reserved_units` / `reservation_total_reserved_normalized_units` | RI lines | Reserved quantity |
| `reservation_normalized_units_per_reservation` | RI lines | |
| `reservation_amortized_upfront_fee_for_billing_period` | **`RIFee`** | The part of the upfront fee amortized into this billing period |
| `reservation_unused_amortized_upfront_fee_for_billing_period` | **`RIFee`** | Upfront money that bought nothing this period |
| `reservation_unused_recurring_fee` | **`RIFee`** | "The recurring fees associated with your unused reservation hours for partial upfront and no upfront RIs" |
| `reservation_unused_quantity` | **`RIFee`** | "The number of RI hours that you didn't use during this billing period" |
| `reservation_unused_normalized_unit_quantity` | `RIFee` | Same, normalized |
| `reservation_amortized_upfront_cost_for_usage` | **`DiscountedUsage`** | Upfront fee allocated to *this usage* |
| `reservation_recurring_fee_for_usage` | **`DiscountedUsage`** | Recurring fee amortized for usage time |
| `reservation_effective_cost` | **`DiscountedUsage`** | Upfront + hourly rate averaged into an effective hourly rate |

**Trap:** `reservation_effective_cost` lives on the **usage** line, but the
waste columns live on the **fee** line. A query that filters to only
`DiscountedUsage` can never see unused commitment, and a query that filters to
only `RIFee` can never see what the reservation actually delivered. You need
both, which is why `queries/11-RI-SP-UTILISATION-AND-WASTE.sql` has separate
CTEs for the two.

**Trap:** Amazon notes the `Unused*` columns are not provided for Dedicated
Host reservations at this time. Zero unused-RI cost on a Dedicated Host bill
is a gap, not a saving.

---

## 8. `savings_plan_*` columns

| Column | Line items where it is populated | Meaning |
|---|---|---|
| `savings_plan_savings_plan_a_r_n` | SP lines | The Savings Plan ARN |
| `savings_plan_start_time` / `savings_plan_end_time` | SP lines | Term boundaries |
| `savings_plan_purchase_term` | SP lines | Term length |
| `savings_plan_offering_type` | SP lines | e.g. Compute or EC2 Instance Savings Plan |
| `savings_plan_payment_option` | SP lines | All Upfront / Partial / No Upfront |
| `savings_plan_region` | SP lines | Region scope |
| `savings_plan_instance_type_family` | SP lines | Instance family scope |
| `savings_plan_savings_plan_rate` | **`SavingsPlanCoveredUsage`** | "The Savings Plans rate for the usage" |
| `savings_plan_savings_plan_effective_cost` | **`SavingsPlanCoveredUsage`** | "The proportion of the Savings Plans monthly commitment amount (upfront and recurring) that is allocated to each usage line" |
| `savings_plan_amortized_upfront_commitment_for_billing_period` | **`SavingsPlanRecurringFee`** | The upfront fee this plan costs you for the billing period (0 for No Upfront) |
| `savings_plan_recurring_commitment_for_billing_period` | **`SavingsPlanRecurringFee`** | The monthly recurring fee |
| `savings_plan_used_commitment` | **`SavingsPlanRecurringFee`** | "The total dollar amount of the Savings Plans commitment used. (SavingsPlanRate multiplied by usage)" |
| `savings_plan_total_commitment_to_date` | **`SavingsPlanRecurringFee`** | "The total amortized upfront commitment and recurring commitment **to date**, for that hour" |

### ⚠ `savings_plan_total_commitment_to_date` is cumulative — do not divide by it

It is the most natural-looking denominator for a utilisation percentage and it
is the wrong one, because it accumulates. Divide used commitment by it and
every month looks nearly fully utilised, which is worse than no number at all
because it is reassuring. Use `amortized_upfront_commitment_for_billing_period
+ recurring_commitment_for_billing_period` as the period denominator — which
is what `queries/11-RI-SP-UTILISATION-AND-WASTE.sql` does.

### The Savings Plan asymmetry

A Savings Plan is an **hourly** commitment. The recurring RI fee is a
**monthly** charge. Amazon documents this contrast directly. Modelling them
with the same period logic produces subtly wrong utilisation.

Also note: a Savings Plan covers compute across services, so the SP benefit
on Lambda and Fargate lands under those product codes. Filtering to
`AmazonEC2` to measure "coverage" understates it.

---

## 9. `pricing_*` columns

| Column | Meaning | Notes |
|---|---|---|
| `pricing_public_on_demand_cost` | What the usage would have cost at public On-Demand rates (**DOUBLE**) | The list-price baseline. Ignores every discount you hold |
| `pricing_public_on_demand_rate` | Public On-Demand rate per unit | |
| `pricing_term` | `OnDemand`, `Reserved`, `SavingsPlan` etc. | Useful for splitting a mixed bill |
| `pricing_unit` | Unit of the rate, e.g. `Hrs`, `GB-Mo` | |
| `pricing_rate_id` | Rate identifier | |
| `pricing_rate_code` | Rate code | Legacy `pricing/RateCode` |
| `pricing_lease_contract_length` | RI term, e.g. `1yr`, `3yr` | RI lines |
| `pricing_offering_class` | `standard` / `convertible` | RI lines. Amazon lists `OfferingClass` under pricing and product both — **verify with `DESCRIBE`** |
| `pricing_purchase_option` | `All Upfront` / `Partial Upfront` / `No Upfront` | Amazon lists `PurchaseOption` under pricing and product both — **verify with `DESCRIBE`** |

**Trap:** `pricing_public_on_demand_cost` is not a "savings" column and it is
not what you would have paid. It prices usage at public rates regardless of
the private pricing, EDP discounts, or commitments you hold. It is useful in
exactly one role: as the numerator of a discount ratio, with the amortized
cost as the denominator. That is what `queries/10-EC2-RI-SP-COVERAGE.sql`
does with it.

**Trap:** Amazon's published attribute list places `OfferingClass` and
`PurchaseOption` under both the `Pricing` and `Product` column types. That
means `pricing_offering_class` / `product_offering_class` and
`pricing_purchase_option` / `product_purchase_option` may both exist in your
table, or only one. **This pack's queries avoid both families** rather than
guess. See §14.

---

## 10. `discount_*` columns

Amazon documents the `discount/` header as included in CUR **only when the
account has a discount applied during the report's billing period**:

| Column | Meaning |
|---|---|
| `discount_bundled_discount` | The bundled discount applied to the line item — a usage-based discount giving free or discounted usage of one service based on usage of another. Amazon's documented examples include AWS Shield Advanced bundling AWS WAF, and a NAT gateway with AWS Network Firewall waiving standard NAT gateway processing and hourly charges |
| `discount_total_discount` | The sum of all discount columns for that line item |
| `discount` | The discount as a map/aggregate in some CUR 2.0 table definitions (Amazon's Athena column-type helper treats `discount` as `MAP`) |

**Trap:** because these columns exist only for accounts with a discount,
a query referencing `discount_total_discount` **fails on a report for an
account that has no discount**. This pack references no `discount_*` column
in any shipped query, on purpose. If you have them, they are the clean way to
separate "list price minus discount" from "what I paid".

---

## 11. Column naming

The report file's header form and the Athena table's column name are **not
the same string**:

| Report header (CUR 1.0 style) | Athena column name |
|---|---|
| `lineItem/UnblendedCost` | `line_item_unblended_cost` |
| `lineItem/LineItemType` | `line_item_line_item_type` |
| `lineItem/ResourceId` | `line_item_resource_id` |
| `bill/PayerAccountId` | `bill_payer_account_id` |
| `product/instanceType` | `product_instance_type` |
| `resourceTags/user:Team` | `resource_tags_user_team` |
| `reservation/EffectiveCost` | `reservation_effective_cost` |
| `savingsPlan/SavingsPlanEffectiveCost` | `savings_plan_savings_plan_effective_cost` |
| `pricing/publicOnDemandCost` | `pricing_public_on_demand_cost` |

The transformation is: split on `/`, replace `:` with `_`, split camelCase
into `_`-separated lowercase, join with `_`.

Note the double prefix on Savings Plan columns: the header family is
`savingsPlan/` and the attribute is `SavingsPlanEffectiveCost`, giving
`savings_plan_savings_plan_effective_cost`. That is not a typo.

Similarly `reservation_reservation_a_r_n` comes from
`reservation/ReservationARN` — camelCase splitting turns `ARN` into
`a_r_n`. Again, not a typo.

This is why *every* query in this pack tells you to run `DESCRIBE` first
rather than trusting a column name from a blog post, including this file.

---

## 12. Verify against YOUR table

Run these three statements before you run anything that costs money. None of
them reads your CUR data.

```sql
-- 1. Do the columns a query needs actually exist, and what are their types?
DESCRIBE your_database.your_cur_table;

-- 2. What are the real tag column names? Look for the resource_tags_user_ prefix.
SHOW COLUMNS IN your_database.your_cur_table;

-- 3. What are the partition keys, what format are the values, and how far
--    does the data go?
SHOW PARTITIONS your_database.your_cur_table;
```

Additionally worth doing once:

```sql
-- What distinct line item types does my table actually contain, and how much
-- does each contribute? This one DOES read data - run it for a single month.
SELECT
    line_item_line_item_type,
    COUNT(*)                                     AS line_items,
    ROUND(SUM(line_item_unblended_cost), 2)      AS unblended_cost
FROM your_database.your_cur_table
WHERE year = 'YYYY'
  AND month = 'MM'
GROUP BY 1
ORDER BY 3 DESC;
```

Compare that output against §2's table. If you find a line item type that is
not in Amazon's documented list, that is a finding worth knowing about —
and it means your report configuration is producing something the public
documentation does not describe.

---

## 13. CUR 1.0 vs CUR 2.0

Two report generations are in circulation, and the schema is **not
identical**:

| | Legacy CUR (1.0) | CUR 2.0 (AWS Data Exports) |
|---|---|---|
| Export API | Cost and Usage Reports | AWS Data Exports |
| Report header form | `lineItem/UnblendedCost` | `line_item_unblended_cost` |
| Delivery | CSV or Parquet, S3 | Parquet, S3 |
| `line_item_usage_account_name` | not documented | documented |
| `line_item_net_unblended_cost` | legacy header `lineItem/NetUnblendedCost` exists | documented snake_case |
| Some line item type spellings | `SavingsPlanNegation`, `RIFee` | same documented list; note that at least one published Amazon document spells a type with a hyphen (`SavingsPlanNegation`) |
| Athena table | **the report itself ships a `CREATE TABLE` statement in your S3 bucket** | created/registered differently; commonly via Glue or a data-export integration |

**What this pack targets:** the **Athena column naming used by the
console-generated CUR DDL** — `line_item_unblended_cost`,
`line_item_line_item_type`, `resource_tags_user_*`, and so on. That naming is
shared by legacy CUR loaded into Athena and by CUR 2.0 loaded into Athena,
which is why the queries work on both. What differs between the two is the
**set of columns present**, not the spelling of the shared ones.

**Practical stance:** do not guess which generation you have from the
console page you happen to be looking at. Run `DESCRIBE` and compare against
the tables in this document. If a column is missing, the query fails loudly.
That is the designed behaviour.

---

## 14. Verification notes

This document was written from primary Amazon documentation, not from
memory. Here is exactly what was fetched and what each source established.

**Fetched (2026, `docs.aws.amazon.com` and the `aws-samples` GitHub
organisation):**

| Source | What it established |
|---|---|
| `cur/latest/userguide/data-dictionary.html` | The dictionary structure, and the pointer to Amazon's own machine-readable column list (see next row) |
| `cur/latest/userguide/samples/Column_Attribute_Service.zip` (downloaded and parsed — an `.xlsx` with 5,278 rows) | **The authoritative attribute-per-column-type list.** Established the exact attribute name sets for Bill, Identity, LineItem, Pricing, Product, Reservation, and confirmed which attributes exist at all. Notably confirmed `lineItem/NetUnblendedCost`, `reservation/NetEffectiveCost`, `savingsPlan/UsedCommitment`, `savingsPlan/TotalCommitmentToDate`, `discount/BundledDiscount`, `discount/TotalDiscount`, `product/instanceType`, `product/instanceTypeFamily`, and `reservation/UnusedAmortizedUpfrontFeeForBillingPeriod` |
| `cur/latest/userguide/Lineitem-columns.html` | `lineItem/UnblendedCost`, `BlendedCost`, `NetUnblendedCost`, `LineItemType` and its **complete** documented value list; the statement that **UnblendedRate is 0** for EC2/RDS RI-discounted line items and that those lines have `LineItemType` = `DiscountedUsage`; the statement that `BlendedCost` is blank for `Discount` line items; the statement that `ResourceId` is optional and blank for transfers/requests/discounts/credits/taxes |
| `cur/latest/userguide/billing-columns.html` | The `bill/` column set including `InvoicingEntity` |
| `cur/latest/userguide/identity-columns.html` | `identity/LineItemId`, `identity/TimeInterval` |
| `cur/latest/userguide/reservation-columns.html` | Every `reservation/` column definition, its documented **"Line items applicable"** value, and the Dedicated Host gap |
| `cur/latest/userguide/savingsplans-columns.html` | `savingsPlan/SavingsPlanEffectiveCost`, `UsedCommitment`, `TotalCommitmentToDate` (and the word "to date"), `AmortizedUpfrontCommitmentForBillingPeriod`, `RecurringCommitmentForBillingPeriod`, and their documented line-item applicability |
| `cur/latest/userguide/pricing-columns.html` | The `pricing/` column set, including that `OfferingClass` and `PurchaseOption` appear under both Pricing and Product |
| `cur/latest/userguide/product-columns.html` | The `product/` attribute spellings cited in §5 |
| `cur/latest/userguide/resource-tags-columns.html` | The `resourceTags/user:` header form and the cost-allocation-tag caveat |
| `cur/latest/userguide/discount-details.html` | `discount/BundledDiscount` and `discount/TotalDiscount`, and that the header is included only when a discount applies |
| `cur/latest/userguide/amortized-reservation.html` | The **definition of amortization** quoted in §1, and which columns are populated on `RIFee` versus `DiscountedUsage` |
| `cur/latest/userguide/cur-sp.html` | Savings Plan line item semantics: that `SavingsPlanCoveredUsage` shows the on-demand cost and is offset by `SavingsPlanNegation`; that one negation may correspond to multiple covered-usage lines; that the SP recurring fee is hourly while the RI recurring fee is monthly |
| `cur/latest/userguide/cur-ate-manual.html`, `create-manual-table.html`, `upload-report-partitions.html` | That **the report itself ships the `CREATE TABLE` SQL in your S3 bucket**, and that partitions must be loaded before querying |
| `cur/latest/userguide/table-dictionary-cur2-line-item.html` | The CUR 2.0 line item dictionary, including `line_item_net_unblended_cost`, `line_item_usage_account_name`, and the CUR 2.0 line item type list |
| `raw.githubusercontent.com/aws-samples/aws-cudos-framework-deployment` → `cid/helpers/cur.py` | **The Athena snake_case column names.** This is the AWS Cloud Intelligence Dashboards CUR helper. Its `cur_minimal_required_columns` and its `ri_required_columns` / `sp_required_columns` "does this CUR have RI/SP data" probe lists gave independent confirmation of: `resource_tags_user_*` style tag naming, `line_item_*` snake_case, **`reservation_reservation_a_r_n`** (the `a_r_n` split), **`savings_plan_savings_plan_a_r_n`** and `savings_plan_savings_plan_effective_cost` (the double prefix), `savings_plan_used_commitment`, and the DOCUMENT/`MAP` typing of `cost_category`, `discount`, `product`, `resource_tags` |

### Columns deliberately OMITTED as unverifiable

These were considered and left out of every shipped query. Omitting them is
the point: a wrong column name in a query that costs money to run is the
worst possible outcome.

| Omitted column | Why it was omitted |
|---|---|
| `line_item_net_unblended_cost` | Documented, but present **only when a discount applies in that period**. A query referencing it fails on reports/periods without one. Use it only after confirming with `DESCRIBE` |
| `line_item_net_unblended_rate` | Same conditional-presence problem |
| `line_item_iam_principal` | CUR 2.0 column, populated only when IAM principal data is enabled, and documented as currently supported for Amazon Bedrock **only**. Too narrow and too configuration-dependent to ship a query against |
| `line_item_user_identifier` | CUR 2.0 column for IAM Identity Center workforce users. Narrow and configuration-dependent |
| `pricing_offering_class` / `product_offering_class` | Amazon's own attribute list places `OfferingClass` under **both** Pricing and Product. Which one your table has is a configuration question this pack cannot answer for you |
| `pricing_purchase_option` / `product_purchase_option` | Same conflict: `PurchaseOption` appears under both column types in Amazon's list |
| `product_license_model` / `product_licence_model` | The two spellings both appear in Amazon's published material. Rather than pick one and be wrong for half of buyers, this pack picks neither |
| `reservation_net_effective_cost`, `reservation_net_unused_recurring_fee`, `reservation_net_amortized_upfront_fee_for_billing_period`, `reservation_net_unused_amortized_upfront_fee_for_billing_period`, `reservation_net_upfront_value`, `reservation_net_recurring_fee_for_usage`, `reservation_net_amortized_upfront_cost_for_usage` | These exist in the published attribute list under the legacy `reservation/` header, but there is **no confirmed Athena snake_case form** for the legacy-CUR case, and their presence is discount-dependent. The non-`net` equivalents are used instead |
| `savings_plan_net_*` family | Same reasoning as the `reservation_net_*` family |
| `cost_category_*` columns | These only exist if you have created cost categories. This pack mentions them as the *supported route* for attributing untaggable spend but ships no query that references them, so nothing breaks if you have none |
| `split_line_item_*` columns | Only exist when split cost allocation data is enabled (EKS/ECS). Out of scope for a general pack |
| `line_item_legal_entity` | **Present and verified** — but the shipped queries do not need it, and it is only interesting for AWS Marketplace. It is documented in §3 rather than used |
| `product_operation`, `product_sku`, `product_usagetype`, `product_volume_api_name`, `product_database_engine`, `product_instance_size`, `product_instance_family`, `product_tenancy`, `product_operating_system`, `product_location`, `product_location_type`, `product_product_family`, `product_servicecode`, `product_storage_type` | All verified as published attributes, but the shipped queries use `line_item_product_code` and `line_item_usage_type` instead, which are narrower and cheaper to read. They are listed in §5 for buyers who want them |
| `bill_invoicing_entity` | Verified in the legacy `bill/` dictionary, but **CUR 2.0 documents `bill_billing_entity` instead**. The shipped queries use no bill column other than none at all |

### What is NOT claimed in this document

* No savings percentages, no "typical" discount figures, no industry
  benchmarks and no dollar amounts. Every number in this pack is either a
  column value you provide or arithmetic performed on it.
* No claim that the amortized-cost expression is Amazon's formula. It is a
  documented-component idiom, and §1 says so.
* No claim that any query in this pack has been executed. See
  `../VALIDATION.md` and `../README.md`.
