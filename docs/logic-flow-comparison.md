# LFL Logic Comparison

This diagram compares the current LFL pipeline with the alternative placement-level monitor. It assumes both start from the same source population; source filters and data-quality exclusions are intentionally omitted from the comparison.

```mermaid
flowchart LR
  subgraph A[Current LFL pipeline: position-level renewal and raw ROL]
    A0[Source participation rows]
    A1[01 Parameters]
    A2[02 Group geometry by stack + cedant + year<br/>Attachment, then height<br/>0.5% chained gaps]
    A3[03 Clean multi-row positions<br/>Exact attachment, full limit, client limit<br/>Premium duplicates within 0.5% counted once]
    A4[04 Effective cedant positions<br/>Sum counted premium and limits;<br/>use largest limit if total exceeds full limit]
    A5[05 Candidates<br/>Same stack + cedant, t to t+1<br/>Attachment and height each within 5%;<br/>ROL ratio within 1/1.9 to 1.9]
    A6[06 One-to-one mutual-best matching<br/>Geometry score; 4 rounds]
    A7[07 Layer IDs across cedants/years<br/>Renewal inherits; otherwise scan prior geometry;<br/>remaining positions form new layers]
    A8[08 Output: one row per source policy_id<br/>row_role and counted contributions;<br/>position and renewal values repeat per position]
    A9[Measure: premium / client limit<br/>Raw rate-on-line change]
    A0 --> A2
    A1 --> A2
    A2 --> A3 --> A4 --> A5 --> A6 --> A7 --> A8 --> A9
    A1 --> A3
    A1 --> A5
    A1 --> A7
  end

  subgraph B[Alternative: placement-level renewal and exposure-adjusted Fisher rate]
    B0[CasualtyExposure participation rows]
    B1[Reference data<br/>Parameters, subclass mapping, aliases,<br/>inferred-premium list, severity index]
    B2[policy_row<br/>Normalize insured/cedant, attachment/retention;<br/>exclude ineligible rows; group effective policies]
    B3[layer<br/>Price layers and group market placements<br/>by effective attachment, modeled exposure,<br/>100% premium and inception]
    B4[renewal_link<br/>Within-cedant evidence plus cross-cedant candidates;<br/>premium, anniversary and structure gates;<br/>4 mutual-best rounds]
    B5[fct_renewal_item<br/>One item per accepted market-placement pair;<br/>sums all member layers on each side]
    B6[Price using premium / loss potential<br/>Primary: share x limit<br/>Excess: share x Lomax layer exposure]
    B7[Aggregate slices with additive measures<br/>Fisher index of sums: pc_deflated, premiums,<br/>pp_inflated; filter valid items]
    B8[fct_cedant_link<br/>Cedant-level and like-for-like rates]
    B9[fct_company_year<br/>Company versus market, coverage,<br/>trust and outlier stability]
    B0 --> B2
    B1 --> B2
    B1 --> B3
    B2 --> B3 --> B4
    B1 --> B4
    B3 --> B5
    B4 --> B5
    B3 --> B6
    B5 --> B7
    B6 --> B7
    B7 --> B9
    B4 --> B8
    B3 --> B8
  end
```

## What the diagram highlights

- **Renewal unit:** A matches an effective cedant position within the same stack. B matches a market placement and can accept cross-cedant renewals.
- **Order:** A matches positions before assigning longitudinal layer IDs. B first builds same-year market placements, then links placements across years.
- **Cross-cedant role:** A's geometry scan can carry a layer ID but is not itself an accepted renewal. B's cross-cedant candidate can be an accepted market-placement renewal.
- **Rate measure:** A reports raw premium per client limit. B adjusts price for modeled loss-potential changes, then uses a Fisher aggregation for valid renewal items.
- **Output grain:** A's published detail is one row per source policy, with repeated position-level fields. B publishes placement items, cedant links and company-year summaries as separate grains.

The alternative's severity-index values in the supplied specification are all 1.0, so its exposure adjustment is structural, not an applied inflation adjustment. Both methods use chained-neighbour grouping, but their grouping keys, fields and tolerances differ.
