# Bloomington Babysitting Co-op Ledger - Backend
Created for Cloudflare Pages + Supabase + Resend.

## Setup
### Link to Remote Project
```
npx supabase link --project-ref <your-project-ref>
```

### Local Development
1. Clone this repo
2. [Install Supabase CLI](https://supabase.com/docs/guides/local-development/cli/getting-started)
   ```
   npm i -D supabase@latest
   ```
3. Ensure Docker Desktop is running
4. Start the local Supabase stack
   ```
   npx supabase start
   ```
5. Open a browser to http://localhost:54323 to view Supabase Studio

## Deploy
1. Push this folder to GitHub.
2. Create migrations locally with `npx supabase migration new <name>`.
3. Push migrations to remote with `npx supabase db push`.
