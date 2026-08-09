# Team Directory

A Vercel-hosted submission and moderation workflow.

## Pages
- `/` — public profile submission form
- `/about-us.html` — public list of accepted profiles
- `/review.html` — password-protected moderation area: pending, accepted, and rejected profiles

## Vercel configuration
1. In the Vercel project, create a **Blob** store and connect it to this project. This provides `BLOB_READ_WRITE_TOKEN` automatically.
2. Add an `ADMIN_PASSWORD` environment variable for Production (and Preview if desired). This protects review actions.
3. Redeploy after configuring the environment variables.

Photos and profile record JSON files are stored as public Vercel Blob objects. Profiles are pending until accepted by an administrator. Rejected profiles retain the entered reason in the private review UI.
