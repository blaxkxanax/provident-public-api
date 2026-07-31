# Provident — Lead Intake API

> **This is the single source of truth for the public lead-intake endpoint**, and the
> version to hand to external developers. The machine-readable twin is
> [`provident-lead-intake-openapi.json`](./provident-lead-intake-openapi.json) next to
> this file — keep the two in step when either changes. (Two earlier write-ups,
> `docs/PUBLIC_LEADS_ENDPOINT.md` and `public-lead-full-example.md`, were folded into
> this document and deleted on 2026-07-31; nothing else describes this endpoint.)

Server-to-server API for pushing leads into the Provident CRM.

Two endpoints are involved:

| # | Purpose | Method & path |
|---|---------|---------------|
| 1 | Get an access token | `POST /v2/oauth2/token` |
| 2 | Create a lead | `POST /v2/public/leads` |

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
| `leadType` | `string` | 255 | lookup | Display name of the lead type: `Primary`, `Secondary`, `Primary and Secondary`, `Broker`, `Seller`, `Tenant`, `Landlord`, `Owner`, `Mortgages`, … Ask Provident for the current list. The legacy wording `Primary Buyer` / `Secondary Buyer` / `Primary Buyer and Secondary` is accepted and mapped onto the first three, so senders built against the old CRM keep working. |
| `priority` | `string` | 64 | exact | Free text, e.g. `"High"`. |
| `marketSegment` | `string` | 255 | lookup | Marketing's segmentation: `Standard`, `Luxury`, `Super Luxury`. |
| `agentCategory` | `string` | 255 | lookup | Marketing's grading of the lead: `A`, `B`, `C`, `D`. |

### 4.3 Requirement / interest

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `areaOfInterest` | `string` | — | lookup | Location name, e.g. `"Dubai Marina"`. |
| `propertyTypeInterest` | `string` | 255 | lookup | e.g. `"Apartment"`, `"Villa"`. |
| `budgetMin` | `string` \| `number` | — | exact | Numeric; a JSON number is also accepted. |
| `budgetMax` | `string` \| `number` | — | exact | Numeric; a JSON number is also accepted. |
| `currency` | `string` | 3 | lookup | ISO 4217 code — `AED`, `USD`, … |
| `initialInquiry` | `string` | — | exact | The free-text message / callback reason from the form. |
| `languages` | `string[]` | 255 per entry | lookup | Language code or name — `["ar", "English"]`. Unrecognised entries are ignored. |

### 4.4 Listing the lead is about (optional)

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `listingId` | `string` (uuid) | — | lookup | Provident listing UUID. **Takes precedence** if both are sent. |
| `referenceNo` | `string` | 128 | lookup | Listing reference number, e.g. `"PR-123456"`. |

Linking a listing also makes the lead inherit that listing's agent as its owner
where one is set.

### 4.5 Source & attribution

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `source` | `string` | 255 | lookup | Lead source, e.g. `"Website"`. **Send this** — an unrecognised or missing source leaves the lead with no source. |
| `subSource` | `string[]` | 255 per entry | lookup | Sub-sources, e.g. `["Callback Form"]`. Only kept when they belong to the resolved `source`; ignored entirely if `source` did not match. |
| `marketingType` | `string` | 255 | lookup | e.g. `"Organic"`, `"Paid"`. |
| `eventType` | `string` | 255 | lookup | What the user did: `Submit Form`, `Call`, `Whatsapp Click`, `DM`, `Webpush`, `Gamification`. |
| `campaignName` | `string` | 255 | lookup | CRM campaign name. |
| `advertisingCampaign` | `string` | 255 | lookup | Advertising campaign name. |
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
| `submittedAt` | `string` (ISO-8601) | — | exact | When the visitor submitted on **your** side. Distinct from the CRM's own `createdAt`, which is when we received it. An unparseable value is ignored rather than failing the request. |

> Top-level `formName` is your web form. It is unrelated to `metaFacebook.formName`
> (§4.8), which is the Meta lead-form name — send both when both apply.

### 4.7 Assignment (optional)

| Field | Type | Max | Match | Notes |
|-------|------|-----|-------|-------|
| `assignedBy` | `string` | 255 | lookup | Assign the lead to a specific Provident agent — **send the agent's email address**. If omitted (or unmatched), Provident's automatic assignment engine routes the lead. Leave it out unless you have been told to use it. |

### 4.8 `metaFacebook` — Meta / Facebook / Instagram lead ads

Send this object **only** when the lead came from a Meta (or TikTok) lead form.
The standard fields above still drive routing; this block preserves the ad-platform
metadata alongside the lead.

| Field | Type | Max | Notes |
|-------|------|-----|-------|
| `metaLeadId` | `string` | 64 | Meta's own lead id. **Required for this block to be stored** — without it the whole `metaFacebook` object is discarded. |
| `metaCreatedAt` | `string` (ISO-8601) | — | Submission time reported by Meta, e.g. `"2026-05-06T19:38:09.000Z"`. |
| `platform` | `string` | 32 | `facebook` \| `instagram` \| `tiktok`. |
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
| `finalPageName` | `string` | 255 | |
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

Quiz entries (§4.9) behave slightly differently from the rest: the answer **is**
stored on the lead regardless, and a Provident admin can map the value once so every
future submission of it resolves automatically. A quiz key appearing here repeatedly
usually means a free-text question that would be better as a dropdown, or a numeric
question where sending `value` would remove the guesswork.

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

---

## 7. Duplicates and retries — important

**The endpoint is not idempotent.** Posting the same payload twice creates **two
leads** (both attached to the same contact). There is no de-duplication window,
and `metaLeadId` does **not** prevent a duplicate lead — it only prevents the Meta
metadata block from being attached twice.

So:

- **Never retry a request that returned any `2xx`, `400`, or `401`/`403`** —
  the lead was either already created or will never be accepted.
- **Only retry on network timeouts, `429`, and `5xx`**, with exponential backoff
  (e.g. 1s, 4s, 15s, max 3 attempts).
- A timeout is ambiguous — the lead may have been created. Prefer a retry (a
  duplicate is recoverable, a lost lead is not), and keep your own record of which
  submissions you have sent.
- Store the returned lead `id` against your own submission record. It is the key
  Provident will use for any question about a specific lead.

---

## 8. Responses

### `201 Created`

The lead was created. These are the fields to read:

| Field | Meaning |
|-------|---------|
| `id` | UUID of the created lead. **Store this.** |
| `contactId` | UUID of the contact the lead was attached to (existing or newly created). |
| `intakeUnresolved` | `null`, or a map of the values that could not be matched — see §5. |
| `needsIntakeReview` | `true` when `intakeUnresolved` is non-empty. |
| `createdAt` | Creation timestamp (ISO-8601, UTC). |

```jsonc
{
  "id": "a1b2c3d4-5566-7788-99aa-bbccddeeff00",
  "contactId": "0f1e2d3c-4455-6677-8899-aabbccddeeff",
  "intakeUnresolved": { "advertisingCampaign": "Google Ads — Q3" },
  "needsIntakeReview": true,
  "createdAt": "2026-07-27T06:31:04.512Z"
  // … further fields may be present; ignore them
}
```

The response carries additional fields beyond the table above. They are not part of
this contract, may change at any time, and must not be used in your logic.

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

| Status | `code` | Meaning | What to do |
|--------|--------|---------|------------|
| `400` | `BAD_REQUEST` | `Provide at least one value in leadPhones or leadEmails` | Fix the payload. Never retry as-is. |
| `400` | `INVALID_JSON` | Body was not valid JSON | Fix the serialisation. |
| `401` | `OAUTH_TOKEN_MISSING` | No `Authorization` header | Send `Authorization: Bearer <token>`. |
| `401` | `OAUTH_TOKEN_INVALID` | Token unknown, malformed, or revoked | Get a new token, retry once. |
| `401` | `OAUTH_TOKEN_EXPIRED` | Token past `expires_in` | Get a new token, retry once. |
| `401` | `UNAUTHORIZED` | (Token endpoint) bad client id/secret | Check credentials. Do not retry in a loop. |
| `403` | `FORBIDDEN` | Your IP is not on the allowlist for this client | Send Provident your egress IPs. |
| `429` | `RATE_LIMITED` | Daily request quota exceeded | Back off until `Retry-After` seconds, then resume. |
| `5xx` | `INTERNAL_ERROR` | Server-side failure | Retry with backoff. |

---

## 9. Rate limits

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

## 10. Reference data endpoints (optional)

Alongside lead submission you can **read** Provident's locations, developers and
projects. Use them to populate dropdowns on your side, to send `areaOfInterest` /
`propertyTypeInterest` values that match ours, or to show project content on your
landing pages.

All of them:

- use the **same bearer token** as the lead endpoint — no extra credentials,
- are `GET` and read-only,
- **count against the same rate limit**, so cache the results (these lists change
  rarely — a daily refresh is plenty; do not call them per form submission).

| Endpoint | Returns |
|----------|---------|
| `GET /v2/public/projects/filters` | Locations, developers, property types, statuses — all in one call |
| `GET /v2/public/developers` | Paginated developers |
| `GET /v2/public/developers/search?q=…` | Developer search by name / slug / description |
| `GET /v2/public/developers/{id}` | One developer |
| `GET /v2/public/projects` | Paginated projects (filterable) |
| `GET /v2/public/projects/{id}` | One project |
| `GET /v2/public/projects/map` | Projects inside a map bounding box |
| `GET /v2/public/project-statuses` | Project status list |

### 10.1 Locations (and the other lookup lists)

There is no standalone locations endpoint — locations come from the project filters
call, together with the developer, property-type and status lists:

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

**This is the list to validate against.** Sending an `areaOfInterest` or
`propertyTypeInterest` that appears here guarantees the lead is linked rather than
landing in `intakeUnresolved` (§5).

### 10.2 Developers

```bash
curl -H "Authorization: Bearer <access_token>" \
  "https://devapi.prov.ae/v2/public/developers?page=1&limit=50&popular=true"
```

Query parameters: `page` (1-indexed), `limit`, `popular` (`true` / `false` — omit for
all). `GET /v2/public/developers/search` takes the same parameters plus `q` (aliases:
`search`, `query`) and ranks exact-name matches first.

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
      "popular": true
      // further fields may be present — ignore them
    }
  ],
  "meta": { "page": 1, "limit": 50, "total": 120, "totalPages": 3 }
}
```

Only enabled developers are returned. `GET /v2/public/developers/{id}` returns a
single developer, or `404` if it does not exist or is disabled.

### 10.3 Projects

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

### 10.4 Attaching this data to a lead

**Developers map directly.** Send the developer's `name` (or `slug`) as
`developerName`, or its UUID as `developerId` — see §4.5. Locations and property
types map the same way: send the `name` from the filters call as `areaOfInterest`
and `propertyTypeInterest`.

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

## 11. Reference implementations

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

echo $lead['id'];
```

---

## 12. Go-live checklist

- [ ] Integration built and tested against **`https://devapi.prov.ae/v2`**.
- [ ] Credentials stored server-side only (env vars / secrets manager), never in
      client-side code or version control.
- [ ] Access token cached in memory and reused until ~60s before expiry.
- [ ] `401` triggers exactly one token refresh + retry; no retry loops.
- [ ] Retries only on timeout / `429` / `5xx`, with exponential backoff.
- [ ] Returned lead `id` stored against your own submission record.
- [ ] `intakeUnresolved` logged and reviewed — no field appearing there routinely.
- [ ] Phone numbers sent in E.164 format (`+9715…`).
- [ ] `source`, `subSource`, `eventType`, `marketingType` values confirmed against
      Provident's accepted lists.
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

## 13. Support

Send Provident the following when reporting a problem:

- Environment (dev / prod) and full request URL
- Timestamp (UTC) of the request
- The `code`, `message` and `path` from the error response
- The lead `id` if one was returned
- The request body with personal data redacted

A machine-readable specification of both endpoints is supplied alongside this
document as **`provident-lead-intake-openapi.json`** (OpenAPI 3.0.3) — import it
into Postman, Insomnia, or a client generator.
