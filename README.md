# Provident — Lead Intake API

> **This is the single source of truth for the public lead-intake endpoint**, and the
> version to hand to external developers. The machine-readable twin is
> [`provident-lead-intake-openapi.json`](./provident-lead-intake-openapi.json) next to
> this file — keep the two in step when either changes. (Two earlier write-ups,
> `docs/PUBLIC_LEADS_ENDPOINT.md` and `public-lead-full-example.md`, were folded into
> this document and deleted on 2026-07-31; nothing else describes this endpoint.)

> **Changed 2026-09-06 — read this if you are already integrated.**
> 1. New **`PUT /v2/public/leads/{id}`** (§9) — send details you did not have when you
>    created the lead, most obviously quiz answers the customer finished afterwards. Send
>    only what changed; phones and emails are **added**, never replaced; the lead's stage,
>    status, owner and funnel stay Provident's.
> 2. Sections 9–16 of the previous revision are now 10–17.
>
> **Changed 2026-08-24 — read this if you are already integrated.**
> 1. Every `201` from `POST /v2/public/leads` — **including a merged one** — now carries
>    **`assignedTo`**: the agent the lead landed on, with the phone and email to reach
>    them (§8). Merged responses previously had only three fields.
> 2. New **`GET /v2/public/leads/{id}/assignment`** (§10) tells you who a lead ended up
>    with, and crucially distinguishes *"routing hasn't finished"* from *"nobody took
>    it"*. Read it before assuming an ownerless lead is a failure.
> 3. New **`POST /v2/public/leads/{id}/response-time`** (§11) records how long the agent
>    took to respond.
> 4. Provident can now **call you** when a lead is created or assigned — see
>    **§12, webhooks**. If you take the webhooks you do not need to poll §10 at all.
>
> **Changed 2026-08-19 — read this if you are already integrated.**
> 1. A second enquiry from the same phone/email inside ~24h is now **merged** into the
>    existing lead instead of creating a new one, and that response has a **different,
>    much shorter body**. Branch on `merged` (§7, §8).
> 2. A lead that names a listing now **inherits** that listing's lead type, developer,
>    location, property type, bedrooms, currency and price — into fields you left empty
>    (§4.4).
> 3. `GET /v2/public/developers` moved from `page` to `limit`/`offset`; `page` is now
>    **rejected with `422`**, not ignored (§14.2).
> 4. There is now a standalone locations endpoint (§14.1).
> 5. New optional field `integrationRef` — tag each lead with the integration that
>    produced it (§4.6.1). Worth sending from day one; it is what lets Provident answer
>    "which of your automations sent this" without guessing.

Server-to-server API for pushing leads into the Provident CRM.

Two endpoints are involved:

| # | Purpose | Method & path |
|---|---------|---------------|
| 1 | Get an access token | `POST /v2/oauth2/token` |
| 2 | Create a lead | `POST /v2/public/leads` |
| 3 | Add details you did not have at first | `PUT /v2/public/leads/{id}` |
| 4 | Find out who the lead was assigned to | `GET /v2/public/leads/{id}/assignment` |
| 5 | Record the agent's response time | `POST /v2/public/leads/{id}/response-time` |

Provident can also **call your server** when a lead is created or assigned, which
replaces polling #4 entirely — see §12.

Authentication is **OAuth 2.0 Client Credentials**. There is no user login, no
redirect, no consent screen — your server exchanges a client id + secret for a
bearer token and uses that token to post leads.

---

## 1. Environments

| Environment | Base URL | Use for |
|-------------|----------|---------|
| Staging / dev | `https://devapi.prov.ae/v2` | Integration + testing |
| Production | `https://prodapi.prov.ae/v2` | Live leads |

> **The `/v2` prefix is mandatory.** `https://devapi.prov.ae/public/leads`
> (without `/v2`) returns **404**. Every path in this document already includes it.

All requests and responses are `application/json; charset=utf-8`. Send UTF-8 —
Arabic and other non-ASCII content is fully supported.

### Credentials

You will be issued a separate `client_id` / `client_secret` pair per environment:

| Field | Value |
|-------|-------|
| `client_id` | *(provided by Provident)* |
| `client_secret` | *(provided by Provident)* |

Treat the secret like a password: store it in your server-side configuration or a
secrets manager, never in browser JavaScript, a mobile app bundle, or a public
repository. **This API must only be called from your backend** — calling it from a
browser would expose your credentials and is blocked by CORS.

If your credentials leak, contact Provident and they will be rotated
(the old secret stops working immediately).

---

## 2. Get an access token

```
POST https://devapi.prov.ae/v2/oauth2/token
Content-Type: application/json
```

### Request body

| Field | Required | Value |
|-------|----------|-------|
| `grant_type` | yes | Must be the literal string `client_credentials` — it is the only grant supported. |
| `client_id` | yes | Your client id. |
| `client_secret` | yes | Your client secret. |

```bash
curl -X POST https://devapi.prov.ae/v2/oauth2/token \
  -H "Content-Type: application/json" \
  -d '{
    "grant_type": "client_credentials",
    "client_id": "YOUR_CLIENT_ID",
    "client_secret": "YOUR_CLIENT_SECRET"
  }'
```

### Success — `200 OK`

```jsonc
{
  "access_token": "9f2c1b7d4e8a...",  // opaque token — send as: Authorization: Bearer <access_token>
  "token_type": "Bearer",
  "expires_in": 3600,                  // seconds until expiry (typically 1 hour)
  "scope": ""                          // scopes granted to your client (may be empty)
}
```

The token is an **opaque string**, not a JWT — do not try to decode it.

### Failure — `401 Unauthorized`

```json
{
  "statusCode": 401,
  "code": "UNAUTHORIZED",
  "message": "Invalid client credentials",
  "path": "/v2/oauth2/token",
  "timestamp": "2026-07-27T06:28:41.703Z"
}
```

Causes: wrong `client_id`/`client_secret`, or the client has been deactivated.
A `grant_type` other than `client_credentials` also fails here.

### Token handling rules

- **Cache the token in memory** for `expires_in` seconds (refresh ~60s early).
  Do **not** request a new token for every lead — token calls count against your
  rate limit and create a token record on each call.
- On any `401` from the lead endpoint, fetch a fresh token **once** and retry the
  request. If it fails again with `401`, stop and alert — do not loop.
- Tokens can be revoked server-side; always be prepared to re-authenticate.

---

## 3. Create a lead

```
POST https://devapi.prov.ae/v2/public/leads
Authorization: Bearer <access_token>
Content-Type: application/json
```

### The only hard requirement

> **At least one entry in `leadPhones` or `leadEmails`.**
> Everything else is optional.

Without a phone or an email the request is rejected with `400`, because the CRM
cannot create or match a contact.

### Minimum valid request

```bash
curl -X POST https://devapi.prov.ae/v2/public/leads \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{
    "leadPhones": ["+971501234567"],
    "leadFirstName": "John",
    "leadLastName": "Doe"
  }'
```

### Recommended request (typical web form / ad lead)

```bash
curl -X POST https://devapi.prov.ae/v2/public/leads \
  -H "Authorization: Bearer <access_token>" \
  -H "Content-Type: application/json" \
  -d '{
    "leadPhones": ["+971501234567"],
    "leadEmails": ["john.doe@example.com"],
    "leadFirstName": "John",
    "leadLastName": "Doe",
    "leadType": "Primary",
    "source": "Website",
    "subSource": ["Callback Form"],
    "eventType": "Submit Form",
    "marketingType": "Paid",
    "website": "provident.ae",
    "campaignName": "Spring 2026 Landing Page",
    "developerName": "Sobha Realty",
    "formName": "contact-popup-form",
    "areaOfInterest": "Dubai Marina",
    "propertyTypeInterest": "Apartment",
    "budgetMin": "1000000",
    "budgetMax": "2500000",
    "currency": "AED",
    "initialInquiry": "Looking for a 2BR with sea view, ready Q4.",
    "languages": ["English", "ar"],
    "localeCountry": "AE",
    "pageUrl": "https://prov.ae/en/dubai-marina",
    "pathLocale": "en",
    "gclid": "Cj0KCQ...",
    "utmSource": "google",
    "utmMedium": "cpc",
    "utmCampaign": "spring-2026",
    "utmTerm": "dubai marina apartments",
    "utmContent": "hero-cta"
  }'
```

### Complete request — every supported field

This is the full surface of the endpoint. **Send everything you have** — nothing here
is required except one phone or email, and every field you can fill improves routing,
attribution and reporting on our side. Omit what you don't have (don't send empty
strings or `null` placeholders).

```json
{
  "leadPhones": ["+971501234567", "+971559876543"],
  "leadEmails": ["john.doe@example.com", "j.doe@work.example.com"],
  "leadFirstName": "John",
  "leadMiddleName": "Ahmad",
  "leadSecondName": "A.",
  "leadLastName": "Doe",
  "leadCompanyName": "Acme Real Estate",

  "leadType": "Primary",
  "priority": "High",
  "marketSegment": "Luxury",
  "agentCategory": "A",

  "areaOfInterest": "Dubai Marina",
  "propertyTypeInterest": "Apartment",
  "budgetMin": "1000000",
  "budgetMax": "2500000",
  "currency": "AED",
  "initialInquiry": "Looking for a 2BR with sea view, ready to move in Q4.",
  "languages": ["English", "ar"],

  "listingId": "8f3c1e2a-1122-3344-5566-778899aabbcc",
  "referenceNo": "PR-123456",

  "source": "Website",
  "subSource": ["Callback Form", "Team Page"],
  "marketingType": "Paid",
  "eventType": "Submit Form",
  "campaignName": "Spring 2026 Landing Page",
  "advertisingCampaign": "Google Ads — Q3",
  "developerName": "Sobha Realty",
  "website": "provident.ae",

  "pageUrl": "https://prov.ae/en/dubai-marina?utm_source=google&utm_medium=cpc",
  "pathLocale": "en",
  "gclid": "Cj0KCQjw1234567890",
  "fbclid": "IwAR2abcdefghijklmno",
  "utmSource": "google",
  "utmMedium": "cpc",
  "utmCampaign": "spring-2026",
  "utmTerm": "dubai marina apartments",
  "utmContent": "hero-cta",
  "localeCountry": "AE",

  "formName": "contact-popup-form",
  "adsetName": "test ww",
  "referrer": "https://sobha-city.provident.ae/?utm_source=Google+Ads",
  "ipAddress": "217.165.113.16",
  "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
  "submittedAt": "2026-07-27T13:45:31.728Z",

  "assignedBy": "agent@providentestate.com",

  "metaFacebook": {
    "metaLeadId": "7636865386872307975",
    "metaCreatedAt": "2026-05-06T19:38:09.000Z",
    "platform": "facebook",
    "adId": "120000000000",
    "adName": "Marina Launch — Video",
    "adType": "Video",
    "adgroupId": "930000000000",
    "adgroupName": "TARGETED",
    "metaCampaignId": "230000000000",
    "metaCampaignName": "Marina Q2",
    "formId": "550000000000",
    "formName": "Marina Callback",
    "adAccountId": "act_123456789",
    "businessAccountId": "456789123",
    "sourceAction": "Form",
    "finalPageName": "Thank You",
    "customFields": {
      "هل ترغب في حضور هذا المعرض الحصري؟": "نعم",
      "Preferred call time": "Evening",
      "Ready to buy": "Within 3 months"
    }
  },

  "quiz": {
    "quizKey": "off-plan-investor-2026",
    "quizName": "Off-plan investor quiz",
    "locale": "en",
    "version": "3",
    "answers": [
      {
        "questionKey": "budget",
        "questionLabel": "What is your budget?",
        "optionKey": "2m-5m",
        "answerLabel": "2-5 million",
        "value": 2000000,
        "currency": "AED"
      },
      {
        "questionKey": "purchase_date",
        "questionLabel": "When do you want to buy?",
        "value": "2026-12-01"
      },
      {
        "questionKey": "interests",
        "questionLabel": "Interested in?",
        "optionKey": ["villa", "townhouse"],
        "answerLabel": ["Villa", "Townhouse"]
      }
    ]
  }
}
```

Field-by-field meaning is in §4. Three notes on the example:

- `listingId` and `referenceNo` both identify a listing — send whichever you have.
  If you send both, `listingId` wins.
- `metaFacebook` is only for leads coming from Meta / Instagram / TikTok lead forms.
  Leave the whole object out for website and other sources.
- `quiz` is only for landing pages that ask a question set. Unlike every other field
  here, its questions do **not** need to be agreed with us in advance — see §4.9.

---

## 4. Field reference

Legend for **Match**:

- **exact** — free text stored as sent.
- **lookup** — matched case-insensitively (after trimming) against a list of
  accepted values configured in the CRM. An unmatched value **does not fail the
  request**; see [Matching behaviour](#5-matching-behaviour-and-intakeunresolved).

### 4.1 Contact identity — *at least one of phone/email required*

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `leadPhones` | `string[]` | 64 per entry | exact | One or more phone numbers. **Use E.164 (`+971501234567`)** for reliable duplicate matching. |
| `leadEmails` | `string[]` | 255 per entry | exact | One or more email addresses. |
| `leadFirstName` | `string` | 255 | exact | |
| `leadMiddleName` | `string` | 255 | exact | |
| `leadSecondName` | `string` | 255 | exact | Second given name (used when a middle name is not supplied). |
| `leadLastName` | `string` | 255 | exact | |
| `leadCompanyName` | `string` | 255 | exact | For corporate enquiries. |

### 4.2 Lead classification

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `leadType` | `string` | 255 | lookup | Display name of the lead type: `Primary Buyer`, `Secondary Buyer`, `Primary Buyer and Secondary Buyer`, `Tenant`, `Landlord`, `Broker`, `Seller`, `Owner`, `Mortgages`, … Ask Provident for the current list. The shorthand `Primary` / `Secondary` / `Primary and Secondary` is accepted as an alias for the corresponding `… Buyer` type, in either direction. **Omit this on a listing enquiry** — it is then derived from the listing, correctly (§4.4). |
| `funnel` | `string` | 255 | lookup | Which CRM funnel the enquiry belongs to. **Omit it for the main sales pipeline** — see below. |
| `priority` | `string` | 64 | exact | Free text, e.g. `"High"`. |
| `marketSegment` | `string` | 255 | lookup | Marketing's segmentation: `Standard`, `Luxury`, `Super Luxury`. |
| `agentCategory` | `string` | 255 | lookup | Marketing's grading of the lead: `A`, `B`, `C`, `D`. |

#### `funnel` — which pipeline the lead lands in

Provident runs several pipelines beside the main sales one. **Leave `funnel` out and the lead
goes to the main sales pipeline**, which is what almost every enquiry wants and what every lead
posted to this API did before the field existed. Send a value only when the enquiry belongs to a
different business line:

| `funnel` | also accepted as |
|---|---|
| `Leasing` | `leasing` |
| `Show Room` | `show_room` |
| `PvH` | `pvh` |
| `Mortgages` | `mortgages` |
| `Property Management` | `property_management` |
| `Landlord/Sellers Listings` | `landlord_sellers_listings` |
| `Provident the Agency` | `provident_the_agency` |
| `Events` | `events` |
| `Recruitment` | `recruitment` |
| `Precision Inspections` | `precision_inspections` |
| `811 services` | `811_services` |
| `Prism` | `prism` |

Matched case-insensitively, ignoring spaces, hyphens and underscores — so `Show Room`,
`show_room` and `showroom` are the same funnel. The lead lands on that funnel's own first stage,
which is not always called the same thing (`New Registration` on Show Room,
`New Seller - Landlord` on Landlord/Sellers Listings).

**`funnel` is not derived from `leadType`, deliberately.** The two do not line up: a `Tenant`
enquiry may belong to Leasing or to PvH, and a `Primary Buyer` to sales, Show Room or Provident
the Agency. Only you know which business line the enquiry came from, so only you can say.

**An unrecognised funnel never fails the request.** The lead is created on the main sales
pipeline and the value you sent comes back in `intakeUnresolved.funnel`. Watch for that — a
typo (`"Leasng"`) is indistinguishable from omitting the field in every other respect, so the
only symptom is a funnel team quietly receiving nothing.

### 4.3 Requirement / interest

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `areaOfInterest` | `string` | — | lookup | Location name, e.g. `"Dubai Marina"`. |
| `propertyTypeInterest` | `string` | 255 | lookup | e.g. `"Apartment"`, `"Villa"`. A regular English plural also matches the singular entry (`"Apartments"` → `Apartment`), so a form offering plural choices needs no mapping on your side. |
| `budgetMin` | `string` \| `number` | — | exact | Numeric; a JSON number is also accepted. |
| `budgetMax` | `string` \| `number` | — | exact | Numeric; a JSON number is also accepted. |
| `currency` | `string` | 3 | lookup | ISO 4217 code — `AED`, `USD`, … |
| `initialInquiry` | `string` | — | exact | The free-text message / callback reason from the form. |
| `languages` | `string[]` | 255 per entry | lookup | Language code or name — `["ar", "English"]`. Unrecognised entries are ignored. |

### 4.4 Listing the lead is about (optional)

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `listingId` | `string` (uuid) | — | lookup | Provident listing UUID. **Takes precedence** if both are sent. |
| `referenceNo` | `string` | 128 | lookup | Listing reference number, e.g. `"PR-123456"`. A reference number that matches **more than one** listing counts as unresolved, and nothing below is inherited. |

**A resolved listing fills in what your form did not ask.** Every field in this table is
taken from the listing **only where your payload left it empty** — anything you send
always wins, and a quiz answer (§4.9) mapped to the same field beats the listing too.

| Lead field | Taken from the listing |
|------------|------------------------|
| `leadType` (§4.2) | Derived from the listing's category **and** offering type: Primary → `Primary Buyer`, Secondary → `Secondary Buyer`, and **any rental listing → `Tenant`** whatever its category. |
| `developerName` / `developerId` | The listing's developer. |
| Location | The listing's own area. This fills the lead's location; it does **not** overwrite `areaOfInterest`, which stays what the enquirer told you. |
| `propertyTypeInterest` | The listing's property type. |
| Bedrooms | The listing's bedroom value (`"Studio"`, `"1"` … `"10+"`). |
| `currency` | The listing's currency. |
| `budgetMin` | The listing price — **unless** the price is on application, or it would exceed a `budgetMax` you sent. `budgetMax` is never derived. |

This matters beyond convenience: lead type, developer and location are all inputs to
Provident's routing, so a lead that names a listing is routed on what it actually is
instead of falling through to a catch-all.

Sending a value we then fail to match (an unknown developer name, say) is **still**
reported in `intakeUnresolved` (§5) even though the listing goes on to fill that field —
the mismatch stays visible so it can be corrected on your side.

Linking a listing also makes the lead inherit that listing's agent as its owner where one
is set; that agent wins over `assignedBy` (§4.7).

### 4.5 Source & attribution

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `source` | `string` | 255 | lookup | Lead source, e.g. `"Website"`. **Send this** — an unrecognised or missing source leaves the lead with no source. |
| `subSource` | `string[]` | 255 per entry | lookup | Sub-sources, e.g. `["Callback Form"]`. Only kept when they belong to the resolved `source`; ignored entirely if `source` did not match. |
| `marketingType` | `string` | 255 | lookup | e.g. `"Organic"`, `"Paid"`. |
| `eventType` | `string` | 255 | lookup | What the user did: `Submit Form`, `Call`, `Whatsapp Click`, `DM`, `Webpush`, `Pop Ups`, `Gamification`. |
| `campaignName` | `string` | 255 | lookup | CRM campaign name. |
| `advertisingCampaign` | `string` | 255 | **created on first sight** | Advertising campaign name. The one field on this endpoint that is *not* a strict lookup: a name Provident has never seen creates the campaign rather than being discarded. Omit it if you send `metaFacebook` — the Meta campaign fills it (§4.8). |
| `developerName` | `string` | 255 | lookup | Developer the enquiry is about — name or slug, e.g. `"Sobha Realty"` / `"sobha-realty"`. Values come from [`GET /v2/public/developers`](#102-developers). |
| `developerId` | `string` (uuid) | — | lookup | Developer UUID from the same endpoint. **Takes precedence** over `developerName`; a non-UUID value here is treated as a name rather than discarded. |
| `website` | `string` | 255 | lookup | Website **name or domain** — either resolves. Prefer the domain (`"provident.ae"`, `"providentestate.com"`): it survives a display-name change. Your domain must exist in the CRM first — **tell Provident which domains you post from before you go live**, otherwise every lead arrives with no website. |

### 4.6 Page context, click ids & UTM

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `pageUrl` | `string` | — | exact | Full URL the submission came from (query string included). |
| `pathLocale` | `string` | 32 | exact | Locale segment of the path, e.g. `"en"`. |
| `gclid` | `string` | 512 | exact | Google Ads click id. |
| `fbclid` | `string` | 512 | exact | Facebook click id. |
| `utmSource` | `string` | 512 | exact | |
| `utmMedium` | `string` | 512 | exact | |
| `utmCampaign` | `string` | 512 | exact | |
| `utmTerm` | `string` | 512 | exact | |
| `utmContent` | `string` | 512 | exact | |
| `localeCountry` | `string` | 255 | lookup | Country code (`"AE"`) or name (`"United Arab Emirates"`). If omitted, the API tries to infer it from a trailing 2-letter segment in `pageUrl`. |

### 4.6.1 Submission provenance

Stored verbatim on the lead — no lookup, nothing here can end up in `intakeUnresolved`.

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `formName` | `string` | 255 | exact | Name of the web form the visitor submitted, e.g. `"contact-popup-form"`. |
| `adsetName` | `string` | 255 | exact | Ad set / ad group name on your side. Free text — **not** the `campaignName` lookup. |
| `referrer` | `string` | — | exact | Referring URL the visitor arrived from. |
| `ipAddress` | `string` | 64 | exact | Submitter IP. IPv4, IPv6 and proxy chains all fit. |
| `userAgent` | `string` | — | exact | Browser user-agent captured at submission. |
| `integrationRef` | `string` | 128 | exact | **Your handle for the specific automation behind this lead** — a Make scenario name, a webhook id, a form build. Free text, kept exactly as sent. See below. |
| `submittedAt` | `string` (ISO-8601) | — | exact | When the visitor submitted on **your** side. Distinct from the CRM's own `createdAt`, which is when we received it. An unparseable value is ignored rather than failing the request. |

> Top-level `formName` is your web form. It is unrelated to `metaFacebook.formName`
> (§4.8), which is the Meta lead-form name — send both when both apply.
>
> **If you send neither, the Meta block fills them.** A lead with no top-level
> `formName` / `adsetName` takes `metaFacebook.formName` and
> `metaFacebook.adgroupName` instead (truncated to 255). So a scenario that just
> forwards Meta verbatim no longer produces leads with an empty ad set — which
> is the column these are reported on. Anything you send at the top level wins.

**About `integrationRef`.** Most senders run more than one thing against this API — several
Make scenarios, a website form and a chatbot, one automation per campaign. When a batch of
leads turns out to be junk, or a field stops mapping, the first question is always *which
one produced these*, and nothing else in the payload answers it: `formName` is the visitor's
form, `source` is marketing attribution, and both are frequently identical across your whole
estate.

- **Keep it stable.** It identifies an integration, not a submission — the same scenario
  sends the same value every time. A per-lead unique id makes it useless for grouping.
- **Make it specific**, e.g. `make:meta-leadgen-eu`, `wp-contact-form-7`, `chatbot-v2`.
- **It is never validated**: nothing to match, so it can never appear in `intakeUnresolved`
  (§5) and can never cost you a lead. An unknown value is simply a new value.
- **Don't put your own name in it.** Who you are is recorded automatically and separately,
  from your access token — see below. Values are only distinguished *within* one sender, so
  two partners can both use `scenario-1` without colliding.

> **You are identified automatically.** Every lead records the OAuth client it was submitted
> with, resolved server-side from your token. There is no field for it and no way to send
> one — attribution a sender can write is not attribution. This is also why a client id and
> secret must never be shared between two integrations that you would want to tell apart:
> use `integrationRef` for that, or ask Provident for a second client.

### 4.7 Assignment (optional)

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `assignedBy` | `string` | 255 | lookup | Assign the lead to a specific Provident agent — **send the agent's email address**. If omitted (or unmatched), Provident's automatic assignment engine routes the lead. Leave it out unless you have been told to use it. |
| `distributionType` | `string` | 64 | lookup | How you would like the lead routed. **A hint, not an instruction** — see below. Leave it out unless you have been told to use it. |

> When the lead also resolves a listing (§4.4) and that listing has an agent of its own,
> **the listing's agent wins** — `assignedBy` is used only when the listing has none.

#### `distributionType` — a routing hint

`distributionType` records **how you would like the lead routed**. It is stored on the lead and
only changes who receives it if Provident has configured a routing rule that reads it. By
default no rule does, so sending one is safe and changes nothing — it is a label you can send
today and Provident can act on later, without you changing anything.

Accepted values, matched case-insensitively after trimming (the leading word on its own also
works, so `campaign` is the same as `Campaign distribution`):

| value | short form |
|---|---|
| `Personal distribution` | `personal` |
| `Campaign distribution` | `campaign` |
| `Developer distribution` | `developer` |
| `Language distribution` | `language` |
| `Default distribution` | `default` |
| `Developer and Area distribution` | — |
| `Area distribution Secondary` | — |
| `Roadshow distribution` | `roadshow` |

**An unrecognised value is stored exactly as you sent it rather than rejected.** A lead is never
lost over this field — it simply matches no rule. That also means a typo fails silently, so
check the value if you expect routing to depend on it.

**`Personal distribution` is the one value with behaviour attached today.** It marks the lead as
having a named owner, and a lead marked that way is never re-assigned automatically — it will
not be taken off its owner by the system for going untouched, and no follow-up clock runs
against it at all.

**It only takes effect together with a resolved `assignedBy`.** The two fields are one
instruction: `assignedBy` names the owner, `Personal distribution` says the owner keeps the
lead. If `assignedBy` is missing, or is an address we cannot match to a current Provident agent,
the lead is still created and routed normally — but the `Personal distribution` marker is
dropped rather than applied, because a lead exempted from follow-up with nobody on it is a lead
nothing chases. When that happens the value you sent comes back in `intakeUnresolved` under
`distributionType`, alongside `assignedBy`, so the mismatch is visible in the response:

```json
"intakeUnresolved": {
  "assignedBy": "ex.agent@providentestate.com",
  "distributionType": "Personal distribution"
}
```

**If you leave `distributionType` out, a Meta lead form can carry it instead.** A
`Distribution` or `Distribution Type` entry in `metaFacebook.customFields` (§4.8) is read as a
fallback and normalised through the same table above. That is there because the value is
usually set by whoever built the ad form, not by whoever posts the lead — so you do not have to
lift it out of the custom fields yourself. A top-level `distributionType` always wins.

### 4.8 `metaFacebook` — Meta / Facebook / Instagram lead ads

Send this object **only** when the lead came from a Meta (or TikTok) lead form.
The standard fields above still drive routing; this block preserves the ad-platform
metadata alongside the lead.

**It is no longer only stored.** Five of these fields are copied onto the lead itself,
where they are searchable, filterable and reportable next to every other lead column:

| You send | Lands on the lead as |
|----------|----------------------|
| `metaCampaignId` + `metaCampaignName` | the lead's **advertising campaign** — matched on the Meta campaign id, and **created if Provident has never seen it**, so you do not have to agree campaign names in advance |
| `finalPageName` | the page the ad ran under |
| `adName` / `adId` | the ad |
| `adgroupName` / `adgroupId` | the ad set (also fills `adsetName`, §4.6.1) |
| `formName` / `formId` | the lead form (also fills `formName`, §4.6.1) |

Matching on the **id** is what makes a rename safe: rename a campaign in Ads Manager and
its leads stay on the one campaign in the CRM, under the name it was first seen with.
`campaignName` (§4.5) is a different thing and is still a strict lookup — it is the CRM's
own campaign, which drives routing.

| Field | Type | Max | Notes |
|-------|------|-----|-------|
| `metaLeadId` | `string` | 64 | Meta's own lead id. **Required for this block to be stored** — without it the whole `metaFacebook` object is discarded. |
| `metaCreatedAt` | `string` (ISO-8601) | — | Submission time reported by Meta, e.g. `"2026-05-06T19:38:09.000Z"`. |
| `platform` | `string` | 32 | `facebook` \| `instagram` \| `tiktok`. **The short forms `fb` and `ig` are accepted** and normalised to those, so a scenario forwarding Meta verbatim needs no translation. Anything else is kept, lowercased. |
| `adId` | `string` | 64 | |
| `adName` | `string` | 512 | |
| `adType` | `string` | 64 | e.g. `"Video"`. |
| `adgroupId` | `string` | 64 | |
| `adgroupName` | `string` | 255 | e.g. `"TARGETED"`, `"BROAD"`. |
| `metaCampaignId` | `string` | 64 | Meta's campaign id (**not** the CRM campaign — that's `campaignName`). |
| `metaCampaignName` | `string` | 512 | |
| `formId` | `string` | 64 | |
| `formName` | `string` | 512 | |
| `adAccountId` | `string` | 64 | |
| `businessAccountId` | `string` | 64 | |
| `sourceAction` | `string` | 64 | e.g. `"Form"`. |
| `finalPageName` | `string` | 255 | The Facebook/Instagram **page** the ad ran under, e.g. `"Provident Real Estate"`. Copied onto the lead. |
| `customFields` | `object` | — | Any extra per-form question/answer pairs. Keys are preserved verbatim (non-ASCII safe). |

```jsonc
"metaFacebook": {
  "metaLeadId": "7636865386872307975",
  "metaCreatedAt": "2026-05-06T19:38:09.000Z",
  "platform": "facebook",
  "adId": "120000000000",
  "adName": "Marina Launch — Video",
  "adgroupName": "TARGETED",
  "metaCampaignName": "Marina Q2",
  "formName": "Marina Callback",
  "sourceAction": "Form",
  "customFields": {
    "هل ترغب في حضور هذا المعرض الحصري؟": "نعم",
    "Preferred call time": "Evening"
  }
}
```

### 4.9 `quiz` — dynamic quiz / survey answers

For landing pages that ask a set of questions ("What is your budget?", "When do you
want to buy?", dropdowns, and so on). Unlike every other field in this document, the
questions do **not** have to be agreed with Provident in advance — a new quiz starts
capturing answers the first time it posts one, with no API change on either side.

Answers are searchable and filterable in the CRM, shown on the lead, and — for
questions Provident maps to a CRM field — used to fill that field on the lead.

#### The one thing you must get right

**Send a stable `questionKey` for every question, and a stable `optionKey` for every
dropdown answer.** These are the only language-independent identity an answer has.
Labels are display text: the same question ships in English and Arabic with different
wording, the same bracket reads `2-5 million` or `٢-٥ مليون`, and copy gets edited.

- Keys must be **stable across languages** — the Arabic and English versions of one
  question send the *same* `questionKey`.
- Keys must be **stable over time** — do not regenerate them when you edit the wording.
- Keys are **scoped to the quiz**, so `budget` in quiz A and `budget` in quiz B are
  independent. You do not need globally unique keys.

If you cannot produce keys, still send the labels: answers are kept and stay visible on
the lead, but each language registers as a separate question until someone at Provident
merges them by hand, and reporting is split until they do.

#### The block

| Field | Type | Max | Notes |
|-------|------|-----|-------|
| `quizKey` | `string` | 128 | Stable identifier for the quiz. **Required** — without it the whole `quiz` object is ignored. |
| `quizName` | `string` | 255 | Display name. Used the first time this `quizKey` is seen. |
| `locale` | `string` | 16 | Language the quiz was answered in (`en`, `ar`, `ru`, …). Labels are stored per locale so the CRM shows what the visitor actually saw. |
| `version` | `string` | 32 | Your version identifier, recorded on each answer. |
| `answers` | `array` | 60 | The answers, in the order asked. See below. |

Each entry in `answers`:

| Field | Type | Max | Notes |
|-------|------|-----|-------|
| `questionKey` | `string` | 128 | Stable machine key. See above. |
| `questionLabel` | `string` | 512 | The question as shown, in the quiz locale. |
| `optionKey` | `string` \| `string[]` | 128 each | The chosen option's stable key. **Send an array for multi-select** — each option becomes its own answer record. |
| `answerLabel` | `string` \| `string[]` | 512 each | The answer as shown. For a dropdown this is the option label; for free text it is the answer itself. |
| `value` | `string` \| `number` \| `boolean` | — | The machine value when you have one. **Trusted over the label** — sending `2000000` removes any dependence on our parsing of `"٢-٥ مليون"`. |
| `currency` | `string` | 3 | ISO 4217 for a monetary answer, when the value doesn't imply it. |

```jsonc
"quiz": {
  "quizKey": "off-plan-investor-2026",
  "quizName": "Off-plan investor quiz",
  "locale": "ar",
  "version": "3",
  "answers": [
    {
      "questionKey": "budget",
      "questionLabel": "ما هي ميزانيتك؟",
      "optionKey": "2m-5m",
      "answerLabel": "٢-٥ مليون",
      "value": 2000000,
      "currency": "AED"
    },
    {
      "questionKey": "purchase_date",
      "questionLabel": "When do you want to buy?",
      "value": "2026-12-01"
    },
    {
      "questionKey": "interests",
      "questionLabel": "Interested in?",
      "optionKey": ["villa", "townhouse"],
      "answerLabel": ["Villa", "Townhouse"]
    }
  ]
}
```

#### How free-text answers are read

Numbers are parsed best-effort, so you do not have to normalize them yourself. All of
these land as **2000000**: `2 million`, `2,000,000`, `2.000.000`, `2 000 000`, `AED 2M`,
`2m aed`, `Dirhams 2M`, `٢ مليون`, `٢٠٠٠٠٠٠`. Ranges keep both ends (`2-5 million`,
`2m to 5m`). Currency words in English and Arabic are recognised and recorded separately.

Dates accept ISO-8601 (`2026-12-01`) and unambiguous text (`1 December 2026`).
**`03/04/2026` is deliberately rejected** — day-first and month-first are both plausible
and guessing would file half your leads under the wrong month. Send ISO-8601 or a `value`.

Yes/no answers are recognised across languages (`yes`/`no`, `نعم`/`لا`, `да`/`нет`, …).

Anything that will not parse is **kept verbatim** and flagged for review at Provident —
it is never dropped, and it never fails your request.

#### Limits

Up to **60 answers per submission** register new questions; anything beyond that is
still recorded and flagged, but does not extend the catalogue. A quiz is capped at 100
questions and a question at 200 options. These exist to stop a malformed submission
growing the catalogue without bound — a real quiz will not come near them.

### 4.10 Extra fields you send

Any field **not** listed above is accepted rather than rejected, so adding a field on
your side will never start failing your requests. It will not populate a structured
CRM field either — if you have data that should drive routing or reporting, ask
Provident to add it to this specification first, or send it through `quiz` (§4.9),
which is designed for exactly that and needs no change on our side.

---

## 5. Matching behaviour and `intakeUnresolved`

Fields marked **lookup** are matched case-insensitively (after trimming) against
lists maintained inside the CRM.

The intake is deliberately forgiving — **a bad lookup value never loses you a lead**:

- Matched → the lead is linked to that record.
- Not matched (or ambiguous) → **the lead is still created (`201`)**, the field is
  left empty, and the original text you sent is echoed back in `intakeUnresolved`
  so it can be reviewed and corrected.

```jsonc
"intakeUnresolved": {
  "source": "Web-Site",              // ← the exact string you sent
  "advertisingCampaign": "Google Ads — Q3",
  // Quiz answers we could not read, namespaced by quiz key then question key:
  "quiz.off-plan-investor-2026.free_budget": "somewhere around a lot"
},
"needsIntakeReview": true
```

**Use this in your integration:** log `intakeUnresolved` whenever it is non-empty.
A field that consistently appears there means your value doesn't match Provident's
list — fix the value on your side or ask for the correct spelling. A lead whose
`source` did not resolve loses its attribution.

`funnel` (§4.2) is the one worth alerting on rather than merely logging. Every other
unmatched lookup leaves a visibly empty field on the lead; an unmatched `funnel` instead
files a perfectly complete lead onto the main sales pipeline, which looks exactly like a
lead that never asked for a funnel at all. `intakeUnresolved.funnel` is the only signal
that a whole business line has stopped receiving its leads.

Quiz entries (§4.9) behave slightly differently from the rest: the answer **is**
stored on the lead regardless, and a Provident admin can map the value once so every
future submission of it resolves automatically. A quiz key appearing here repeatedly
usually means a free-text question that would be better as a dropdown, or a numeric
question where sending `value` would remove the guesswork.

> A **merged** response (§7) carries no `intakeUnresolved` field at all — the enquiry was
> folded into an existing lead rather than creating one. Guard for its absence wherever
> you log this.

---

## 6. How a lead becomes a contact

You never send a contact id. The API resolves the contact for you:

1. Each value in `leadPhones` is normalised and matched against existing contacts.
   First match wins.
2. If no phone matches, each value in `leadEmails` is matched the same way.
3. If nothing matches, a **new contact** is created from the name/company/phone/
   email fields you sent.

Consequence: repeat enquiries from the same person attach to the same contact —
which is exactly what the sales team wants. Send phone numbers in **E.164**
(`+971501234567`) so matching is reliable.

> This is **not** the same question as lead merging (§7). Contact resolution asks "who is
> this?" and always runs; merging asks "is this the same enquiry?" and only applies inside
> the merge window. Two leads a month apart share one contact and stay two leads.

---

## 7. Duplicates, merging and retries — important

**The endpoint is not idempotent at the transport level.** There is no request id or
`Idempotency-Key` header: a retried request can reach us twice, and `metaLeadId` does
**not** protect you — it only stops the Meta metadata block being attached twice.

What does protect you is **intake hygiene**, which runs *before* the lead is created and
decides what a second enquiry from the same person actually is. Matching is on the
**normalised phone first, then the email** — one more reason to send E.164.

| A second enquiry arrives | What happens | Response |
|---|---|---|
| Within **24 hours** of the last one from the same phone / email | **Merged** — no new lead. The existing lead keeps its id, its stage and its agent, your payload is stored verbatim beside it, and the lead's merged-enquiry counter goes up. | `201` with `id` = the **existing** lead id, `merged: true`, and `matchedOn` set to `phone` or `email` |
| **After** that window | A **new lead**, marked as a repeat of the earlier one. It is routed and worked normally — the marker is for the agent and for reporting, never a routing instruction. | Normal `201`, with `isRepeatLead: true` and `repeatOfLeadId` set |
| Nothing earlier matches | A normal new lead. | Normal `201`, `isRepeatLead: false` |

The window is a Provident-side setting (24 hours today). Treat it as "about a day", not as
a constant to hard-code.

**Two consequences you have to handle:**

1. **`id` is not always a new lead.** When `merged` is `true` the id you get back is one
   you already have. Don't record it as a second submission, and don't overwrite the
   original submission's timestamps with this one's.
2. **The merged body is short** — `id`, `merged`, `matchedOn` and nothing else. No
   `contactId`, no `intakeUnresolved`, no `needsIntakeReview`, no `createdAt` (§8).

> **Portal exemption.** Enquiries whose `source` is a property portal (Property Finder,
> Bayut, Dubizzle) are **never** merged: those are listing-driven, so the same person
> legitimately enquires about several properties held by different agents. A website or
> ad-form source is not exempt — if that is you, expect merges.

### Retry policy

- **Never retry a request that returned any `2xx`, `400`, `401`/`403` or `422`** — the
  lead was either already created (or merged) or will never be accepted.
- **Only retry on network timeouts, `429` and `5xx`**, with exponential backoff
  (e.g. 1s, 4s, 15s, max 3 attempts).
- A timeout is ambiguous — the lead may have been created. Retry anyway: inside the merge
  window the retry folds into the first attempt instead of duplicating it, which is
  exactly the case this protects.
- Store the returned lead `id` against your own submission record. It is the key Provident
  will use for any question about a specific lead.

---

## 8. Responses

Both outcomes below return **`201`**. Branch on `merged` before reading anything else.

### `201 Created` — a new lead

| Field | Meaning |
|-------|---------|
| `id` | UUID of the created lead. **Store this.** |
| `merged` | `false` — this is a new lead. |
| `contactId` | UUID of the contact the lead was attached to (existing or newly created). |
| `intakeUnresolved` | `null`, or a map of the values that could not be matched — see §5. |
| `needsIntakeReview` | `true` when `intakeUnresolved` is non-empty. |
| `isRepeatLead` | `true` when this person already had a lead older than the merge window (§7). |
| `repeatOfLeadId` | The earlier lead's UUID when `isRepeatLead` is `true`, otherwise `null`. |
| `isAgentEnquiry` | `true` when the enquiry was recognised as coming from a competing agent rather than a buyer. The lead is still created and worked; the flag keeps it out of lead-volume and cost-per-lead reporting. |
| `agentEnquiryReason` | Why, when `isAgentEnquiry` is `true`: `known_agent`, `prior_lead`, `competitor_domain` or `manual`. `null` otherwise. |
| `assignedTo` | The agent the lead landed on, or `null`. See the caveat below — `null` here does **not** mean nobody will get it. |
| `createdAt` | Creation timestamp (ISO-8601, UTC). |

```jsonc
{
  "id": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
  "merged": false,
  "contactId": "0f1e2d3c-4455-6677-8899-aabbccddeeff",
  "intakeUnresolved": { "advertisingCampaign": "Google Ads — Q3" },
  "needsIntakeReview": true,
  "isRepeatLead": false,
  "repeatOfLeadId": null,
  "isAgentEnquiry": false,
  "agentEnquiryReason": null,
  "assignedTo": {
    "id": "3f2a91c4-7e10-4b8d-9c33-2a5b6d7e8f90",
    "slug": "sarah-ahmed",
    "name": "Sarah Ahmed",
    "email": "sarah.ahmed@providentestate.com",
    "phone": "+971501234567",
    "whatsappPhone": "+971501234567",
    "active": true
  },
  "createdAt": "2026-07-27T06:31:04.512Z"
  // … many further fields are present; ignore them
}
```

#### `assignedTo` — when you can rely on it

`assignedTo` is filled **in the same transaction that creates the lead** in exactly two
cases, and is reliable in both:

- you sent a **`referenceNo`** (or `listingId`) that resolved to a listing — the lead goes
  to that listing's agent;
- you sent **`assignedBy`** with an agent's email.

For every other lead, an assignment engine chooses the agent, and it runs **after** this
response is sent. `assignedTo` will be `null` and that means *"not decided yet"*, **not**
*"nobody"*. Do not treat it as a failure and do not tell the customer anything about it.

To find out who it landed on, either poll **§10** or — better — take the **`lead.assigned`
webhook** in §12 and be told.

The agent object is the same shape everywhere it appears in this API:

| Field | Meaning |
|-------|---------|
| `id` | Portal user id. The **stable, immutable** identifier for an agent — use this to key anything on your side. |
| `slug` | Their website profile segment (`/team/<slug>/`), or `null` if they are not published. Human-readable, but an admin can change it; `id` cannot. |
| `name` | Display name, e.g. `Sarah Ahmed`. Safe to say to a customer. |
| `email` | Work email. |
| `phone` | Work phone. |
| `whatsappPhone` | The number to open a WhatsApp chat on. **Read this field** rather than reusing `phone` — they differ for some agents. |
| `active` | `false` for a deactivated account. Do not route work to them. |

**`active: false` is reachable and you must handle it.** Routing never *assigns* to a
deactivated account, but a lead can be assigned to someone who is deactivated afterwards —
1.4% of leads created in the last 90 days are in that state (read 2026-08-24). The agent is
still returned rather than nulled, because who owns the lead is a fact worth recording. Do
not message them and do not name them to a customer: that promises an introduction nobody
will make. Treat it as you would `assignedTo: null` for messaging purposes, and keep the
details for your own records.

Personal phone numbers are never returned by any endpoint in this API.

The response carries the whole lead record, well beyond the table above. Those extra
fields are not part of this contract, may change at any time, and must not be used in
your logic.

### `201 Created` — merged into an existing lead

When intake hygiene folds the enquiry into a lead created inside the merge window (§7),
the status is still `201` but the body is **only these three fields**:

```json
{
  "id": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
  "merged": true,
  "matchedOn": "phone",
  "assignedTo": {
    "id": "3f2a91c4-7e10-4b8d-9c33-2a5b6d7e8f90",
    "slug": "sarah-ahmed",
    "name": "Sarah Ahmed",
    "email": "sarah.ahmed@providentestate.com",
    "phone": "+971501234567",
    "whatsappPhone": "+971501234567",
    "active": true
  }
}
```

| Field | Meaning |
|-------|---------|
| `id` | UUID of the **existing** lead the enquiry was folded into. |
| `merged` | `true`. |
| `matchedOn` | `"phone"` or `"email"` — which identifier matched. |
| `assignedTo` | The agent who already owns that lead, or `null` if it has none. |

`contactId`, `intakeUnresolved`, `needsIntakeReview` and `createdAt` are **absent** here.
Code that reads them unconditionally breaks on the first repeat enquiry.

`assignedTo` is usually **populated** on a merged response, and more reliably than on a new
one: the lead already exists, so its owner is already known. A merged enquiry is a second
customer message on a lead whose agent may have been notified once already — if you notify
agents, this is who to notify, and you will also receive a `lead.assigned` webhook with
`trigger: "merged"` (§12).

### Error format

Every error uses the same envelope:

```json
{
  "statusCode": 401,
  "code": "OAUTH_TOKEN_MISSING",
  "message": "OAuth token missing",
  "path": "/v2/public/leads",
  "timestamp": "2026-07-27T06:28:41.816Z"
}
```

`422` adds one more key, `errors` — an array naming each field that failed validation.

| Status | `code` | Meaning | What to do |
|--------|--------|---------|------------|
| `400` | `BAD_REQUEST` | `Provide at least one value in leadPhones or leadEmails` | Fix the payload. Never retry as-is. |
| `400` | `INVALID_JSON` | Body was not valid JSON | Fix the serialisation. |
| `401` | `OAUTH_TOKEN_MISSING` | No `Authorization` header | Send `Authorization: Bearer <token>`. |
| `401` | `OAUTH_TOKEN_INVALID` | Token unknown, malformed, or revoked | Get a new token, retry once. |
| `401` | `OAUTH_TOKEN_EXPIRED` | Token past `expires_in` | Get a new token, retry once. |
| `401` | `UNAUTHORIZED` | (Token endpoint) bad client id/secret | Check credentials. Do not retry in a loop. |
| `403` | `FORBIDDEN` | Your IP is not on the allowlist for this client | Send Provident your egress IPs. |
| `422` | `VALIDATION_ERROR` | A parameter or field failed validation — including **an unrecognised query parameter**, which is rejected rather than ignored | Fix the request; the `errors` array names the offender. Never retry as-is. Mostly hit on the reference-data endpoints (§14); lead intake itself is deliberately forgiving and does not use this status. |
| `429` | `RATE_LIMITED` | Daily request quota exceeded | Back off until `Retry-After` seconds, then resume. |
| `5xx` | `INTERNAL_ERROR` | Server-side failure | Retry with backoff. |

---

## 9. Updating a lead — details that arrive later

```
PUT   /v2/public/leads/{id}
PATCH /v2/public/leads/{id}
```

For the case where you do not have the whole enquiry at once: you send the name, email
and phone the moment the customer appears, and the quiz answers, the budget and the area
they actually want arrive minutes or hours later, once they have finished answering.

**Send only what changed.** The field names, the lookups and the `intakeUnresolved`
reporting are exactly those of `POST /v2/public/leads` (§4) — this is the same body, with
three fields removed (below). Everything is optional, including phone and email: an update
that carries nothing but a `quiz` block is normal and expected.

### The four rules

1. **A field you omit is left alone.** This is a PATCH in behaviour whichever verb you
   use; `PUT` does not blank the fields you left out.
2. **A field you send wins** over what the lead already had, including a value an agent
   typed. You are the source; do not send a field you are not authoritative about.
3. **An explicit `null` clears the column.** `"budgetMax": null` empties it; omitting
   `budgetMax` does not.
4. **A value that matches no CRM record leaves the column as it was** and is reported in
   `intakeUnresolved`. A typo'd developer name never erases the developer already on the
   lead.

### Phones and emails are added, never replaced

`leadPhones` and `leadEmails` are **appended**. A number or address the lead already has is
ignored (matching is on the normalised form, so formatting differences do not duplicate);
anything new is added. Nothing is ever deleted, and the primary number only changes when
there was not one before. Re-sending the same phone on every update is therefore free.

### Quiz answers replace, per quiz

Answers for a `quizKey` you send **supersede** whatever that quiz previously recorded on
the lead, so re-sending the same submission is idempotent and a corrected answer replaces
the wrong one. Quizzes you do not mention are untouched. A quiz answer mapped to a lead
field (budget, area, bedrooms…) is promoted onto the lead under the same precedence as on
create: a field you sent explicitly in the same request beats the answer.

### What you cannot change

The lead's **workflow** belongs to Provident and is not writable here, whatever you send:
stage, status, the agent it is assigned to, the funnel board it sits on, and the aging
clock. Three create-only fields are therefore absent from this body:

| Field | Why |
|---|---|
| `assignedBy` | An external system never moves a lead between agents. Who holds it is answered by §10 and by the `lead.assigned` webhook. |
| `funnel` | A lead's stage belongs to its board; moving one without the other leaves it in a pipeline that cannot render it. |
| `distributionType` | A Provident aging rule matches on this column, so changing it moves the lead to a different clock. Send it on create. |

Sending them anyway is not an error — they are ignored, and kept verbatim in the lead's
intake record.

### Routing

New details **do** send a lead **nobody holds** back through the assignment engine — the
answers you just sent (area, developer, lead type, budget, languages) are exactly what it
matches on, so a lead that could not be placed when all we knew was a phone number gets a
second chance. The response says so in `rerouted`, and the outcome is asynchronous: poll
§10 or wait for the `lead.assigned` webhook.

A lead an agent **already holds** is never taken off them by an update.

### The agent is told

Every update that changes something posts a note on the lead's own timeline naming your
integration and what changed, so the agent working it sees that new details arrived rather
than discovering them by chance.

### Request

```http
PUT /v2/public/leads/9f1c2f4e-7a3b-4d21-9e88-4d3f0b7c1a55 HTTP/1.1
Host: prodapi.prov.ae
Authorization: Bearer <access_token>
Content-Type: application/json
```

```json
{
  "budgetMin": "1200000",
  "budgetMax": "1800000",
  "areaOfInterest": "Dubai Marina",
  "quiz": {
    "quizKey": "buyer_qualification_v2",
    "quizName": "Buyer qualification",
    "locale": "en",
    "answers": [
      { "questionKey": "timeframe", "label": "When are you looking to buy?", "optionKeys": ["3_6_months"] },
      { "questionKey": "purpose", "label": "Purpose", "value": "Investment" }
    ]
  }
}
```

### Response — `200 OK`

```json
{
  "id": "9f1c2f4e-7a3b-4d21-9e88-4d3f0b7c1a55",
  "updated": true,
  "updatedFields": ["budgetMin", "budgetMax", "closingAreaId", "quizAnswers"],
  "intakeUnresolved": null,
  "needsIntakeReview": false,
  "rerouted": false,
  "assignedTo": {
    "userId": "1f0b...",
    "name": "Sara Haddad",
    "email": "sara.haddad@provident.ae",
    "phone": "+9715xxxxxxx"
  }
}
```

| Field | Meaning |
|---|---|
| `updated` | `false` when the submission changed nothing — every value sent was already the lead's. Not an error, and not worth retrying. |
| `updatedFields` | The lead columns this submission actually changed, by **CRM** name (`closingAreaId` is what `areaOfInterest` fills). `leadPhones` / `leadEmails` appear when a new one was added, `quizAnswers` when answers were written, `metaFacebook` when the Meta block was stored. |
| `intakeUnresolved` | Values sent on **this** submission that matched no CRM record (§5). Merged with whatever was already unresolved on the lead — an update never clears a flag it did not answer. |
| `rerouted` | `true` when the update sent an ownerless lead back through the assignment engine. |
| `assignedTo` | The agent holding the lead as the response was written, or `null`. Same shape as §10. |

### Errors

| Status | Meaning |
|---|---|
| `400` | Body was not valid JSON, or `{id}` is not a UUID. |
| `401` | Token missing, invalid or expired (§8). |
| `404` | No lead with that id, or it has been deleted. |

There is no `422` here: like `POST /public/leads`, this endpoint does not reject a body over
a field it does not recognise or cannot match.

### Notes worth reading once

- **Use the `id` from the create response** — including a merged one, where the id is the
  *existing* lead you were folded into (§7). Updating it updates that lead, which is
  usually what you want and always what you asked for.
- **This is not a way to avoid the merge window.** If the customer enquires again, POST it;
  a second POST inside the window is merged and keeps both enquiries. An update is for
  more detail about the *same* enquiry, not for a new one.
- **Order does not matter, but time does.** Nothing stops a lead being updated after an
  agent has worked it for a week. Rule 2 still applies — you will overwrite what they
  changed, so only send fields you own.
- Every update is recorded in Provident's audit log with your client, the changed field
  list, and the verbatim body.

---

## 10. Who a lead was assigned to

```
GET /v2/public/leads/{id}/assignment
Authorization: Bearer <access_token>
```

`{id}` is the lead `id` from the create response — a new one or a merged one, both work.

**Why this exists.** For most leads the agent is chosen by a routing engine that runs
*after* `POST /v2/public/leads` has answered you. So a lead with no owner on the create
response is normal, and the question you actually need answered is not "is there an agent"
but "**is there going to be one**". That is what `status` tells you.

### Response — `200 OK`

```json
{
  "leadId": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
  "status": "assigned",
  "agent": {
    "id": "3f2a91c4-7e10-4b8d-9c33-2a5b6d7e8f90",
    "slug": "sarah-ahmed",
    "name": "Sarah Ahmed",
    "email": "sarah.ahmed@providentestate.com",
    "phone": "+971501234567",
    "whatsappPhone": "+971501234567",
    "active": true
  },
  "createdAt": "2026-08-24T09:14:02.881Z",
  "retryAfterSeconds": null
}
```

### The four states — branch on `status`, not on `agent`

| `status` | What it means | What to do |
|----------|---------------|------------|
| `assigned` | A real, active agent owns the lead. `agent` is populated. | Contact them. Name them to the customer. |
| `pending` | Routing has not finished. | Ask again after `retryAfterSeconds`. Tell the customer nothing yet. |
| `unassigned` | Routing ran and **nobody took it**. This is final. | Send your generic reply. Notify no one. |
| `pool` | The lead sits in a shared pool, deliberately ownerless until an agent claims it. | Send your generic reply. Notify no one. |

`agent` is non-null only when `status` is `assigned`. `retryAfterSeconds` is non-null only
when `status` is `pending`.

> **`unassigned` and `pool` are common — roughly 30% of leads.** They are not errors and
> not something to retry your way out of. Treating them as "still routing" leaves a
> customer waiting forever for an introduction that is not coming.

### Polling

If you are not using the webhooks in §12, poll like this:

- First check ~30 seconds after creating the lead. Routing is normally much faster, but
  there is no benefit to asking sooner.
- While `status` is `pending`, wait `retryAfterSeconds` and ask again.
- Stop at ~2 minutes. Past that, `pending` will have resolved to something final on its
  own; a lead still `pending` then is escalating and may take much longer.
- `assigned`, `unassigned` and `pool` are all **final answers** — stop polling.

Assignment can change later (a manual reassignment, an escalation). If you care about
that, take the `lead.assigned` webhook — polling will not tell you.

### What it does **not** return

Only the agent's work contacts and the lead's status. Nothing about the customer, the
enquiry, or the lead's content. If you need those, you already have them — you sent them.

### Errors

| Status | Code | Meaning |
|--------|------|---------|
| `400` | `VALIDATION_ERROR` | `{id}` is not a valid UUID |
| `404` | `NOT_FOUND` | No such lead, or it has been deleted |

---

## 11. Recording the agent's response time

```
POST /v2/public/leads/{id}/response-time
Authorization: Bearer <access_token>
Content-Type: application/json

{ "seconds": 47 }
```

How long the assigned agent took to respond to this lead, in **whole seconds**, measured
from whatever you consider the customer's first contact. Provident reports on this figure,
so send the number you would defend to a manager.

| Field | Type | Rules |
|-------|------|-------|
| `seconds` | integer | Required. `0` or more, at most `2592000` (30 days). |

### Response — `200 OK`

```json
{
  "leadId": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
  "agentResponseSeconds": 47,
  "agentRespondedAt": "2026-08-24T09:15:29.104Z"
}
```

`agentRespondedAt` is set by Provident at the moment of the call, not by you. It is what
distinguishes a genuine 47-second response from a figure backfilled three days later.

**Last write wins.** Calling this twice for the same lead overwrites; it is safe to retry.
Timing is not sensitive — minutes or hours after the fact is fine.

**A lead with no assignee is accepted, not rejected.** A tracking link can be clicked by an
agent who claimed the lead out of the pool, or by a previous owner, and the lead's assignee
at the moment you write is not necessarily who responded. Rejecting those writes would lose
exactly the slowest responses — the ones the metric exists to surface — so the endpoint
records the number regardless of `status`.

### Errors

| Status | Code | Meaning |
|--------|------|---------|
| `400` | `VALIDATION_ERROR` | `{id}` is not a valid UUID |
| `404` | `NOT_FOUND` | No such lead, or it has been deleted |
| `422` | `VALIDATION_ERROR` | `seconds` missing, not an integer, negative, or over the cap |

---

## 12. Webhooks — being told instead of asking

Provident can POST to **your** endpoint when something happens to a lead. This replaces
polling §10 entirely and is the recommended integration.

To switch it on, send Provident:

1. a URL for each event you want (they can be the same URL);
2. whether you want a shared secret, and what to call the header if not the default.

### Authentication

Every call carries the shared secret in a header:

```
X-Provident-Webhook-Secret: <the secret you agreed>
```

Compare it in constant time and reject anything else with `401`. The secret is the only
thing proving the call came from Provident — nothing in the body is authentication.

### The two events

| `event` | Fires when |
|---------|------------|
| `lead.created` | Any lead is created in the CRM, from any channel |
| `lead.assigned` | A lead's owner becomes a real, active agent |

> **Nothing is sent when a lead ends up with no owner.** "Nobody took it" is a state, not
> an event — ask §10 for it. If you are waiting for a `lead.assigned` that never comes,
> that is the answer, and it is why you should still have a timeout.

> **`lead.created` will include the leads you sent us**, unless you ask Provident to
> exclude your API client — which you almost certainly want, or you will greet the same
> customer twice. Say so when you request the webhook.

### `lead.created`

```jsonc
{
  "event": "lead.created",
  "deliveryId": "9f8e7d6c-5b4a-3210-fedc-ba9876543210",
  "occurredAt": "2026-08-24T09:14:03.220Z",
  "lead": {
    "id": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
    "url": "https://portal.prov.ae/en/crm/leads/a1b2c3d4-5566-7788-99aa-bbccddeeff00",
    "pageUrl": "https://providentestate.com/new-projects/the-w-arada-developments-dubai-harbour/",
    "createdAt": "2026-08-24T09:14:02.881Z",
    "stage": "New Lead",
    "source": "Website",
    "leadType": "Primary Buyer",
    "campaign": null,
    "initialInquiry": "Interested in a 2BR",
    "listing": { "id": "…", "referenceNo": "PS-24082614", "title": "2BR in Collective" }
  },
  "customer": {
    "fullName": "Ahmed Khan",
    "firstName": "Ahmed",
    "lastName": "Khan",
    "phones": ["+971501112233"],
    "emails": ["ahmed@example.com"]
  },
  "property": {
    "developer": "Emaar Properties",
    "community": "Dubai Hills Estate",
    "location": "Collective",
    "locationPath": "Dubai, Dubai Hills Estate, Collective",
    "project": "Collective 2.0",
    "propertyType": "Apartment",
    "bedrooms": "2"
  },
  "agent": { "id": "…", "name": "Sarah Ahmed", "whatsappPhone": "+971501234567", "…": "…" },
  "intake": {
    "clientId": "…",
    "clientName": "WhatsApp Bot",
    "integrationRef": "wa-property-inquiry"
  }
}
```

**Everything in `property` is a display name, not an id** — it is meant to go straight into
a message a person reads. `community` is `null` for some leads (the location tree is
uneven), which is why `location` and `locationPath` travel alongside it; fall back to those
rather than leaving a hole in a sentence.

`agent` may be `null`: this event fires when the lead is created, which is often before it
has an owner. Wait for `lead.assigned`.

**`lead.url` and `lead.pageUrl` are not interchangeable.** `url` opens the lead inside the
Provident CRM and is for staff. `pageUrl` is the **public page the enquiry came from** — the
listing or project page the customer was actually looking at — and is the link to put in a
message to an agent. It is `null` when there was no public page (Meta lead-ads, leads
created inside the CRM by staff); render that as "N/A" rather than falling back to `url`,
which an agent may not be able to open.

### `lead.assigned`

Same `lead`, `customer`, `property` and `agent` blocks, plus:

| Field | Meaning |
|-------|---------|
| `trigger` | `created`, `routed`, `reassigned` or `merged` — see below |
| `previousAgentId` | The previous owner's id, or `null` |

`agent` is **always** populated on this event.

| `trigger` | Means |
|-----------|-------|
| `created` | The lead had an owner from the moment it was created — a listing's agent, or an explicit `assignedBy` |
| `routed` | The routing engine placed a lead that had no owner |
| `reassigned` | The lead moved from one agent to another |
| `merged` | A repeat enquiry was folded into an existing lead that already has an owner (§7) |

`merged` is the one worth special-casing: it means a **second** customer message arrived on
a lead whose agent you may already have notified once. The customer is not new; the
enquiry is.

### Your endpoint's contract

- **Answer `2xx` as soon as you have stored the event.** Do the work afterwards. Provident
  waits 10 seconds and no longer.
- **`4xx` is permanent.** Anything other than `408` or `429` is taken as "understood and
  refused" and is never retried. Do not use `400` for a temporary problem.
- **`5xx`, `408`, `429` and timeouts are retried** at 30s, 1m, 5m, 10m, 15m, 30m, then
  given up on. A partner outage of about half an hour loses nothing.
- **Be idempotent on `deliveryId`.** A retry after your `2xx` was lost in transit is
  indistinguishable from a first attempt, so at-least-once is the guarantee — not
  exactly-once.
- **Order is not guaranteed.** A `lead.assigned` that was retried can arrive after a later
  `reassigned` for the same lead. `occurredAt` is stamped when the body was built and is
  what to compare.

---

## 13. Rate limits

Every authenticated request is counted per client, per **UTC day**. The response
carries the current state:

| Header | Meaning |
|--------|---------|
| `X-RateLimit-Limit` | Requests allowed in the current window. |
| `X-RateLimit-Remaining` | Requests left. |
| `X-RateLimit-Reset` | Seconds until the counter resets (end of the UTC day). |

Exceeding it returns `429 Too Many Requests` with a `Retry-After` header (seconds).

The default quota is modest and is raised per client on request — **tell Provident
your expected daily lead volume before go-live** so the limit is set correctly.
Token requests count too, which is another reason to cache the token.

### IP allowlisting (optional)

Provident can restrict a client to a set of source IPs / CIDR ranges. If that is
enabled for you, requests from anywhere else get `403 Forbidden` with the offending
IP in the message. Send your production egress IPs when you request credentials.

---

## 14. Reference data endpoints (optional)

Alongside lead submission you can **read** Provident's locations, developers and
projects. Use them to populate dropdowns on your side, to send `areaOfInterest` /
`propertyTypeInterest` values that match ours, or to show project content on your
landing pages.

All of them:

- use the **same bearer token** as the lead endpoint — no extra credentials,
- are `GET` and read-only,
- **count against the same rate limit**, so cache the results (these lists change
  rarely — a daily refresh is plenty; do not call them per form submission).

| Endpoint | Returns | Paging |
|----------|---------|--------|
| `GET /v2/public/projects/filters` | Locations, developers, property types, statuses — all in one call | — |
| `GET /v2/public/locations/search?search=…` | Community / area type-ahead | `limit` / `offset` |
| `GET /v2/public/locations/{id}` | One community or area | — |
| `GET /v2/public/developers` | Developers | `limit` / `offset` |
| `GET /v2/public/developers/search?q=…` | Developer search by name / slug / description | `limit` / `offset` |
| `GET /v2/public/developers/{id}` | One developer | — |
| `GET /v2/public/projects` | Projects (filterable) | `page` / `limit` |
| `GET /v2/public/projects/{id}` | One project | — |
| `GET /v2/public/projects/map` | Projects inside a map bounding box | — |
| `GET /v2/public/project-statuses` | Project status list | — |

> **The two paging styles are not interchangeable.** Locations and developers take
> `limit` / `offset`; projects still take `page` / `limit`. An unrecognised query
> parameter is **rejected, not ignored** — sending `?page=` to the developers endpoint
> returns `422 VALIDATION_ERROR` (`property page should not exist`), not page 1.

### 14.1 Locations

Two ways in, for two different jobs.

**A type-ahead picker** — search the whole community / area tree:

```bash
curl -H "Authorization: Bearer <access_token>" \
  "https://devapi.prov.ae/v2/public/locations/search?search=marina&limit=20"
```

```jsonc
{
  "data": [
    { "id": "…uuid…", "name": "Dubai Marina", "level": "2", "path": "Dubai, Dubai Marina" },
    { "id": "…uuid…", "name": "Marina", "level": "3", "path": "Ajman, Al Zorah, Marina" }
  ],
  "meta": { "limit": 20, "offset": 0, "total": 350 }
}
```

| Parameter | Meaning |
|-----------|---------|
| `search` | Search term (aliases: `q`, `query`). Omit it to page the whole tree. |
| `limit` | Page size, default `50`, **capped at 200**. |
| `offset` | Records to skip. Default `0`. |
| `sort`, `order` | Ordering. Relevance-ranked by default when a term is given. |

`GET /v2/public/locations/{id}` returns one node in the same shape, for re-displaying a
location the visitor picked earlier.

`path` is the full ancestry (`"Ajman, Al Zorah, Marina"`) and is there because **names are
not unique** — the tree has thousands of nodes and hundreds of repeated leaf names. Show
`path` in your picker so the user can tell two "Marina"s apart.

> **Send the `name`, not the id.** The lead payload has no location-id field:
> `areaOfInterest` (§4.3) is matched by name. And a name that matches **more than one**
> node is treated as unmatched — the lead is still created, the field is left empty and
> the text comes back in `intakeUnresolved` (§5). If your picker offers an area whose
> `name` is not unique, expect that field not to link.

**The bulk lookup lists** — locations, developers, property types and statuses in one
call, which is what you want for pre-populating static dropdowns:

```bash
curl -H "Authorization: Bearer <access_token>" \
  https://devapi.prov.ae/v2/public/projects/filters
```

```jsonc
{
  "filters": {
    "location": {
      "displayName": "Location",
      "values": [
        { "id": "…uuid…", "name": "Dubai Marina", "fullName": "Dubai" }
        // name     → send this as the lead's areaOfInterest
        // fullName → the parent location, for disambiguating similar names
      ]
    },
    "developer": {
      "displayName": "Developer",
      "values": [{ "id": "…uuid…", "name": "Emaar" }]
    },
    "propertyType": {
      "displayName": "Property Type",
      "values": [{ "id": "…uuid…", "name": "Apartment" }]
      // name → send this as the lead's propertyTypeInterest
    },
    "status": {
      "displayName": "Status",
      "values": [{ "id": "…uuid…", "name": "Off-plan", "color": "#0aa" }]
    },
    "campaignType":       { "displayName": "Campaign Type",       "values": ["…"] },
    "ownershipType":      { "displayName": "Ownership Type",      "values": ["…"] },
    "stockAvailability":  { "displayName": "Stock Availability",  "values": ["…"] }
  }
}
```

Note the two lists answer different questions: the filters call returns only the
locations that have projects attached, the search endpoint covers the whole tree.
**Validate `propertyTypeInterest` against the filters call**, and `areaOfInterest`
against whichever of the two you populated your form from.

### 14.2 Developers

```bash
curl -H "Authorization: Bearer <access_token>" \
  "https://devapi.prov.ae/v2/public/developers?limit=50&offset=0&popular=true"
```

> **Changed 2026-08.** This endpoint used to take `page` and return
> `meta: { page, limit, total, totalPages }`. It now takes `limit` / `offset` and returns
> `meta: { limit, offset, total }`. **`page` is no longer accepted at all** — sending it
> returns `422 VALIDATION_ERROR`, it is not ignored. Update any integration written
> against the old shape.

| Parameter | Meaning |
|-----------|---------|
| `limit` | Page size, default `50`, **capped at 200**. `meta.limit` echoes the value actually applied after clamping. |
| `offset` | Records to skip. Default `0`. |
| `search` | Matches name, slug, description and id (aliases: `q`, `query`). A CSV matches any term; a `"quoted"` term is matched exactly. |
| `popular` | `"true"` / `"false"` — filter by the popular flag. Omit for all enabled developers. |
| `sort` | CSV of sort keys, most significant first, each able to carry its own direction: `popular:desc,name:asc` or `-name`. Keys: `id`, `name`, `slug`, `description`, `logoUrl`, `imageUrl`, `popular`, `contactId`, `createdAt`, `updatedAt`, plus `relevance` when searching. Unknown keys are ignored. |
| `order` | Default direction for sort keys that don't carry one (`asc` / `desc`). |

`GET /v2/public/developers/search` is the same endpoint with relevance ranking applied;
it takes exactly the same parameters and falls back to the plain list when no term is
given.

```jsonc
{
  "data": [
    {
      "id": "…uuid…",
      "name": "Emaar",
      "slug": "emaar",
      "logoUrl": "https://media.prov.ae/…",
      "imageUrl": "https://media.prov.ae/…",
      "description": "…",
      "enabled": true,
      "popular": true,
      "contactId": null,
      "createdAt": "2026-07-21T10:09:32.393Z",
      "updatedAt": "2026-07-21T10:09:32.393Z"
    }
  ],
  "meta": { "limit": 50, "offset": 0, "total": 244 }
}
```

Only enabled developers are returned. `GET /v2/public/developers/{id}` returns a
single developer, or `404` if it does not exist or is disabled.

### 14.3 Projects

```bash
curl -H "Authorization: Bearer <access_token>" \
  "https://devapi.prov.ae/v2/public/projects?limit=20&page=1&developerIds=<uuid>&locationIds=<uuid>"
```

Only published projects are returned. Useful query parameters:

| Parameter | Meaning |
|-----------|---------|
| `q` | Free-text search |
| `developerIds` | Comma-separated developer UUIDs (also accepts `developerId`) |
| `locationIds` | Comma-separated location UUIDs (also accepts `locationId`) |
| `statusIds` | Comma-separated status UUIDs (also accepts `statusId`) |
| `propertyTypes` | Comma-separated property-type UUIDs (also accepts `propertyType`) |
| `minPrice`, `maxPrice` | Price range |
| `deliveryFrom`, `deliveryTo` | Handover date range |
| `ownershipType`, `campaignType`, `stockAvailability` | Values from the filters call |
| `page`, `limit`, `offset`, `sort`, `order` | Paging and ordering |
| `simplified` | `true` (default) for the compact shape below; `false` for the full record |

The UUIDs for `developerIds`, `locationIds`, `statusIds` and `propertyTypes` all come
from `GET /v2/public/projects/filters`.

```jsonc
{
  "data": [
    {
      "id": "…uuid…",
      "title": "Marina Heights",
      "slug": "marina-heights",
      "startingPrice": "1200000",
      "deliveryDate": "2027-06-30T00:00:00.000Z",
      "propertyTypes": ["Apartment", "Penthouse"],
      "paymentPlans": ["60/40"],
      "brochure": true,
      "campaignType": "Launch",
      "developer": { "name": "Emaar" },
      "location": {
        "id": "…uuid…",
        "name": "Dubai Marina",
        "fullPath": "Dubai | Dubai Marina",
        "parentName": "Dubai"
      },
      "image": { "url": "https://media.prov.ae/…", "sortOrder": 0 },
      "status": { "id": "…uuid…", "name": "Off-plan" }
    }
  ],
  "meta": { "page": 1, "limit": 20, "total": 84, "totalPages": 5 }
}
```

`GET /v2/public/projects/{id}` returns one project (`?simplified=false` for the full
record), `404` if it is not published. `GET /v2/public/projects/map` takes required
`latMin`, `latMax`, `lngMin`, `lngMax` bounds plus the same filters and returns map
pins.

### 14.4 Attaching this data to a lead

**Developers map directly.** Send the developer's `name` (or `slug`) as
`developerName`, or its UUID as `developerId` — see §4.5. Locations and property
types map by **name only** (there is no id field for either on a lead): send the `name`
from the filters call — or, for locations, from `GET /v2/public/locations/search` — as
`areaOfInterest` and `propertyTypeInterest`. A location name shared by more than one node
in the tree cannot be matched; see §14.1.

**Projects have no top-level field.** Sending `projectId` at the top level is accepted
but ignored (§4.10). Two ways to tie a lead to a project:

- **Via a quiz question (§4.9).** Ask the project as a quiz question and have Provident
  map that question to the project field — the answer then lands on the lead as a real
  project link, with no change to this specification. This is the supported route.
- **Otherwise**, put the project name in `initialInquiry`, `campaignName` or
  `utmCampaign` and it will at least be searchable as text.

> Approved listings are also readable — `GET /v2/public/listings` and
> `GET /v2/public/listings/filters` — which is where the `referenceNo` and
> `listingId` values for a lead come from. Ask Provident if you need that flow.

---

## 15. Reference implementations

### Node.js (18+, built-in `fetch`)

```js
const BASE = 'https://devapi.prov.ae/v2';
const CLIENT_ID = process.env.PROVIDENT_CLIENT_ID;
const CLIENT_SECRET = process.env.PROVIDENT_CLIENT_SECRET;

let cached = { token: null, expiresAt: 0 };

async function getToken() {
  if (cached.token && Date.now() < cached.expiresAt) return cached.token;

  const res = await fetch(`${BASE}/oauth2/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      grant_type: 'client_credentials',
      client_id: CLIENT_ID,
      client_secret: CLIENT_SECRET,
    }),
  });
  if (!res.ok) throw new Error(`Token request failed: ${res.status} ${await res.text()}`);

  const data = await res.json();
  cached = {
    token: data.access_token,
    expiresAt: Date.now() + (data.expires_in - 60) * 1000, // refresh 60s early
  };
  return cached.token;
}

async function createLead(lead, retryOn401 = true) {
  const res = await fetch(`${BASE}/public/leads`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${await getToken()}`,
    },
    body: JSON.stringify(lead),
  });

  if (res.status === 401 && retryOn401) {
    cached = { token: null, expiresAt: 0 };   // force refresh, retry exactly once
    return createLead(lead, false);
  }
  if (!res.ok) throw new Error(`Lead create failed: ${res.status} ${await res.text()}`);

  const created = await res.json();

  // Always branch on `merged` first (§7/§8). A merged response carries only
  // id / merged / matchedOn — reading contactId or intakeUnresolved here is a bug.
  if (created.merged) {
    console.info(`Merged into existing lead ${created.id} (matched on ${created.matchedOn})`);
    return created.id;
  }

  if (created.needsIntakeReview) {
    console.warn('Unmatched intake values:', created.intakeUnresolved);
  }
  return created.id;
}

// usage
await createLead({
  leadPhones: ['+971501234567'],
  leadEmails: ['john.doe@example.com'],
  leadFirstName: 'John',
  leadLastName: 'Doe',
  source: 'Website',
  eventType: 'Submit Form',
  pageUrl: 'https://prov.ae/en/dubai-marina',
  utmSource: 'google',
});
```

### Python

```python
import os, time, requests

BASE = "https://devapi.prov.ae/v2"
_token, _expires_at = None, 0

def get_token():
    global _token, _expires_at
    if _token and time.time() < _expires_at:
        return _token
    r = requests.post(f"{BASE}/oauth2/token", json={
        "grant_type": "client_credentials",
        "client_id": os.environ["PROVIDENT_CLIENT_ID"],
        "client_secret": os.environ["PROVIDENT_CLIENT_SECRET"],
    }, timeout=15)
    r.raise_for_status()
    data = r.json()
    _token, _expires_at = data["access_token"], time.time() + data["expires_in"] - 60
    return _token

def create_lead(lead):
    r = requests.post(
        f"{BASE}/public/leads",
        json=lead,
        headers={"Authorization": f"Bearer {get_token()}"},
        timeout=30,
    )
    r.raise_for_status()
    body = r.json()

    # Branch on `merged` first (§7/§8): a merged response carries only
    # id / merged / matchedOn, and body["id"] is a lead you already have.
    if body.get("merged"):
        print("Merged into existing lead", body["id"], "matched on", body.get("matchedOn"))
        return body["id"]

    if body.get("needsIntakeReview"):
        print("Unmatched intake values:", body.get("intakeUnresolved"))
    return body["id"]
```

### PHP (cURL)

```php
<?php
$base = 'https://devapi.prov.ae/v2';

function provident_post(string $url, array $payload, array $headers = []): array {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_POST           => true,
        CURLOPT_POSTFIELDS     => json_encode($payload, JSON_UNESCAPED_UNICODE),
        CURLOPT_HTTPHEADER     => array_merge(['Content-Type: application/json'], $headers),
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT        => 30,
    ]);
    $body   = curl_exec($ch);
    $status = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($status < 200 || $status >= 300) {
        throw new RuntimeException("HTTP $status: $body");
    }
    return json_decode($body, true);
}

$token = provident_post("$base/oauth2/token", [
    'grant_type'    => 'client_credentials',
    'client_id'     => getenv('PROVIDENT_CLIENT_ID'),
    'client_secret' => getenv('PROVIDENT_CLIENT_SECRET'),
])['access_token'];

$lead = provident_post("$base/public/leads", [
    'leadPhones'    => ['+971501234567'],
    'leadFirstName' => 'John',
    'leadLastName'  => 'Doe',
    'source'        => 'Website',
], ["Authorization: Bearer $token"]);

// A merged enquiry (§7) returns only id / merged / matchedOn — $lead['id'] is then
// an existing lead, and contactId / intakeUnresolved are absent from the response.
if (!empty($lead['merged'])) {
    error_log("Merged into existing lead {$lead['id']} on {$lead['matchedOn']}");
}

echo $lead['id'];
```

---

## 16. Go-live checklist

- [ ] Integration built and tested against **`https://devapi.prov.ae/v2`**.
- [ ] Credentials stored server-side only (env vars / secrets manager), never in
      client-side code or version control.
- [ ] Access token cached in memory and reused until ~60s before expiry.
- [ ] `401` triggers exactly one token refresh + retry; no retry loops.
- [ ] Retries only on timeout / `429` / `5xx`, with exponential backoff.
- [ ] Returned lead `id` stored against your own submission record.
- [ ] **`merged` checked on every `201`** before reading `contactId`, `intakeUnresolved`,
      `needsIntakeReview` or `createdAt` — a merged response has none of them (§7, §8).
- [ ] A merged `id` recognised as an **existing** lead, not recorded as a new one.
- [ ] **`assignedTo: null` on a `201` understood as "not decided yet", not "nobody"** — the
      routing engine runs after the response is sent (§8).
- [ ] If you notify agents: either the `lead.assigned` webhook is wired up (§12) **or** you
      poll `GET /leads/{id}/assignment` (§10) — and in either case you branch on all four
      `status` values, with `unassigned` and `pool` handled as final answers rather than
      retried.
- [ ] If you take webhooks: your endpoint verifies `X-Provident-Webhook-Secret`, answers
      `2xx` within 10 seconds before doing any work, and is idempotent on `deliveryId`.
- [ ] If you take `lead.created`: you asked Provident to exclude your own API client, so
      the leads you submit are not sent back to you.
- [ ] `intakeUnresolved` logged and reviewed — no field appearing there routinely.
- [ ] Phone numbers sent in E.164 format (`+9715…`).
- [ ] `source`, `subSource`, `eventType`, `marketingType` values confirmed against
      Provident's accepted lists.
- [ ] Reference-data calls (§14) use the right paging for each endpoint — `limit`/`offset`
      for locations and developers, `page`/`limit` for projects. An unknown query
      parameter is rejected with `422`, not ignored.
- [ ] If you send `quiz` (§4.9): every question has a **stable `questionKey`** and every
      dropdown answer a **stable `optionKey`**, identical across languages and unchanged
      when the wording is edited. Confirm this before launch — retrofitting keys after
      leads have arrived means merging the duplicates by hand.
- [ ] If you send `quiz`: numeric and date answers send a machine `value` where you have
      one, rather than relying on us parsing the label.
- [ ] Expected daily volume communicated so the rate limit is sized correctly.
- [ ] Production egress IPs shared (if IP allowlisting will be enabled).
- [ ] Production credentials issued and base URL switched to
      **`https://prodapi.prov.ae/v2`**.

---

## 17. Support

Send Provident the following when reporting a problem:

- Environment (dev / prod) and full request URL
- Timestamp (UTC) of the request
- The `code`, `message` and `path` from the error response
- The lead `id` if one was returned
- The request body with personal data redacted

A machine-readable specification of both endpoints is supplied alongside this
document as **`provident-lead-intake-openapi.json`** (OpenAPI 3.0.3) — import it
into Postman, Insomnia, or a client generator.
