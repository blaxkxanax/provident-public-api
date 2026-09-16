# provident-public-api

The public documentation site for Provident's **Lead Intake API** — the handbook we hand
to external developers, plus its OpenAPI twin. Published with [Mintlify](https://mintlify.com);
every push to `main` redeploys the site.

## This repo is a mirror, not the source

Both documents are authored in the private API repo, `provident-broker-api`, under
`docs/public-api/`:

| Here | Source of truth |
| --- | --- |
| `api-reference/openapi.json` | `docs/public-api/provident-lead-intake-openapi.json` |
| `provident-lead-intake-openapi.json` | the same file — kept at the root so older raw links still resolve |
| `lead-intake-api.mdx` | `docs/public-api/PROVIDENT_LEAD_INTAKE_API.md` |

**Edit them there, not here.** Anything changed directly in this repo is overwritten by
the next sync. Everything else — `docs.json`, `introduction.mdx`, the logo — is owned here.

### Syncing

With a checkout of `provident-broker-api` sitting next to this one:

```bash
./sync.sh                          # or: ./sync.sh /path/to/provident-broker-api
```

It copies the spec byte for byte, and turns the handbook into `lead-intake-api.mdx` by
swapping its H1 for Mintlify frontmatter and repointing the one relative link to the spec.
It is idempotent — re-running with an unchanged source leaves the tree clean. Review the
diff, then commit and push.

## Layout

```
docs.json               Mintlify config — theme, navigation, branding
introduction.mdx        Landing page (owned here)
lead-intake-api.mdx     The handbook (synced)
api-reference/
  openapi.json          The spec (synced) — every endpoint page is generated from it
logo/, favicon.svg      The Provident mark
sync.sh                 Pulls both synced files out of provident-broker-api
```

The **API Reference** tab is generated from `api-reference/openapi.json` at build time, so
a new endpoint in the spec becomes a new page with no change to `docs.json`.

> One consequence worth knowing: a generated page's URL comes from the operation's
> `summary`, so rewording a summary changes that page's URL. Avoid it once a link is public.

## Working on the site locally

```bash
npx mint@latest dev            # preview on http://localhost:3000
npx mint@latest broken-links   # what CI runs on every push
```

## Publishing

Mintlify's GitHub App watches `main` and redeploys on push. The connection is made once,
in the Mintlify dashboard (Settings → Git). Nothing in this repo triggers the deploy.

## Support

[it@provident.ae](mailto:it@provident.ae)
